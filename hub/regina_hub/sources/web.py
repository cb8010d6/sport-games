"""Phone controller page, desktop simulator page and their WebSocket endpoint (aiohttp)."""

from __future__ import annotations

import asyncio
import json
import logging
import math
import ssl
from pathlib import Path
from typing import Any

from aiohttp import WSMsgType, web

from ..controller import Controller
from ..frames import CANONICAL_AXIS_MAP, PHONE_AXIS_MAP, make_remap
from ..hub import Hub

log = logging.getLogger("web")

STATIC_DIR = Path(__file__).resolve().parent.parent / "web"
MAX_SAMPLES_PER_MSG = 64
PHONE_PREDICT_S = 0.03          ## phones: Wi-Fi + browser event delay, roughly


class WsTransport:
    def __init__(self, ws: web.WebSocketResponse):
        self._ws = ws

    def _send(self, obj: dict[str, Any]) -> None:
        if self._ws.closed:
            return
        asyncio.ensure_future(self._safe_send(json.dumps(obj, separators=(",", ":"))))

    async def _safe_send(self, text: str) -> None:
        try:
            await self._ws.send_str(text)
        except (ConnectionError, RuntimeError):
            pass

    def send_ui(self, ui: dict[str, Any]) -> None:
        self._send({"t": "ui", **ui})

    def beep(self, freq: int, ms: int) -> None:
        self._send({"t": "beep", "freq": freq, "ms": ms})

    def vibrate(self, pattern: list[int]) -> None:
        # "ms" too, for a phone still running an older page.
        self._send({"t": "vibrate", "pattern": pattern, "ms": pattern[0]})

    def set_player(self, player: int) -> None:
        self._send({"t": "player", "player": player})

    def notify_event(self, name: str) -> None:
        self._send({"t": "event", "name": name})


def _finite(vals: list[Any]) -> bool:
    return all(isinstance(v, (int, float)) and math.isfinite(v) for v in vals)


def clean_profile_name(value: Any) -> str:
    """A plain-text nickname, shared by the phone and local game profile."""
    if not isinstance(value, str):
        return ""
    return "".join(ch for ch in value if ch.isprintable()).strip()[:20]


class WebSource:
    def __init__(self, hub: Hub, phone_axis_map: Any = PHONE_AXIS_MAP):
        self.hub = hub
        self.remaps = {"device": make_remap(phone_axis_map), "canonical": make_remap(CANONICAL_AXIS_MAP)}
        self.app = web.Application()
        self.app.add_routes(
            [
                web.get("/", self._page("phone.html")),
                web.get("/sim", self._page("sim.html")),
                web.get("/ws", self._ws),
                web.get("/api/status", self._status),
                web.get("/api/qr", self._qr),
                web.static("/static", STATIC_DIR),
            ]
        )
        self._runner: web.AppRunner | None = None

    def _page(self, name: str):
        async def handler(_req: web.Request) -> web.StreamResponse:
            return web.FileResponse(STATIC_DIR / name, headers={"Cache-Control": "no-cache"})

        return handler

    async def _status(self, _req: web.Request) -> web.Response:
        return web.json_response(self.hub.roster())

    async def _qr(self, _req: web.Request) -> web.Response:
        return web.json_response(self.hub.qr or {})

    async def start(self, http_host: str, http_port: int, https_port: int | None, ssl_ctx: ssl.SSLContext | None) -> None:
        self._runner = web.AppRunner(self.app, access_log=None)
        await self._runner.setup()
        await web.TCPSite(self._runner, http_host, http_port).start()
        log.info("simulator: http://%s:%d/sim", http_host, http_port)
        if https_port is not None and ssl_ctx is not None:
            await web.TCPSite(self._runner, "0.0.0.0", https_port, ssl_context=ssl_ctx).start()
            log.info("phone controller: https://<lan-ip>:%d/", https_port)

    async def stop(self) -> None:
        if self._runner is not None:
            await self._runner.cleanup()

    async def _ws(self, request: web.Request) -> web.StreamResponse:
        ws = web.WebSocketResponse(heartbeat=5.0, max_msg_size=1 << 20)
        await ws.prepare(request)
        transport = WsTransport(ws)
        controller: Controller | None = None
        try:
            async for msg in ws:
                if msg.type != WSMsgType.TEXT:
                    if msg.type == WSMsgType.ERROR:
                        break
                    continue
                try:
                    data = json.loads(msg.data)
                except json.JSONDecodeError:
                    continue
                if not isinstance(data, dict):
                    continue
                t = data.get("t")
                if t == "hello" and controller is None:
                    kind = "sim" if data.get("kind") == "sim" else "phone"
                    client_id = str(data.get("client_id") or id(ws))[:64]
                    name = str(data.get("name") or kind)[:32]
                    controller = self.hub.attach(kind, f"{kind}:{client_id}", name, transport, rate_hint_hz=60.0 if kind == "phone" else 100.0, wrap_bits=None)
                    controller.extra["profile_name"] = clean_profile_name(data.get("profile_name"))
                    if kind == "phone":
                        controller.predict_s = PHONE_PREDICT_S
                    await ws.send_str(json.dumps({"t": "welcome", "id": controller.id, "player": controller.player}))
                elif t == "ping":
                    await ws.send_str(json.dumps({"t": "pong", "c": data.get("c")}))
                elif controller is None:
                    continue
                elif t == "profile":
                    nickname = clean_profile_name(data.get("name"))
                    controller.extra["profile_name"] = nickname
                    self.hub.on_status(controller, controller.battery, controller.charging)
                    await ws.send_json({"t": "profile", "name": nickname})
                elif t == "m":
                    remap = self.remaps.get(str(data.get("frame", "device")), self.remaps["device"])
                    items = []
                    for s in (data.get("s") or [])[:MAX_SAMPLES_PER_MSG]:
                        if isinstance(s, list) and len(s) == 7 and _finite(s):
                            items.append((float(s[0]) * 1000.0, remap((s[1], s[2], s[3])), remap((s[4], s[5], s[6]))))
                    self.hub.on_imu(controller, items)
                elif t == "in":
                    dials = data.get("d") or [0, 0]
                    an = data.get("an") or [0.0, 0.0]
                    try:
                        self.hub.on_input(controller, int(data.get("b", 0)), int(dials[0]), int(dials[1]), (float(an[0]), float(an[1])))
                    except (TypeError, ValueError, IndexError):
                        pass
                elif t == "recenter":
                    self.hub.handle_game_command({"cmd": "recenter", "controller": controller.id})
                elif t == "calibrate":
                    self.hub.handle_game_command({"cmd": "calibrate", "controller": controller.id})
                elif t == "st":
                    batt = data.get("battery")
                    battery = int(batt) if isinstance(batt, (int, float)) and 0 <= batt <= 100 else None
                    self.hub.on_status(controller, battery, bool(data.get("charging", False)))
        finally:
            if controller is not None:
                self.hub.detach(controller)
        return ws
