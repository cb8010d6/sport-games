"""Phone controller page, desktop simulator page and their WebSocket endpoint (aiohttp)."""

from __future__ import annotations

import asyncio
import ipaddress
import json
import logging
import secrets
import ssl
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from aiohttp import WSMsgType, web

from ..controller import Controller
from ..frames import CANONICAL_AXIS_MAP, PHONE_AXIS_MAP, make_remap
from ..hub import Hub
from ..protocol import UiState

log = logging.getLogger("web")

STATIC_DIR = Path(__file__).resolve().parent.parent / "web"
MAX_SAMPLES_PER_MSG = 64
MAX_PENDING_WS_MESSAGES = 32
MAX_GYRO_RAD_S = 35.0
MAX_ACCEL_M_S2 = 160.0
MAX_TIMESTAMP_MS = (1 << 53) - 1   ## JavaScript's exact integer range
MIN_SAMPLE_INTERVAL_MS = 0.001   ## 1 MHz ceiling, well above browser sensor rates
TIMESTAMP_GAP_ALLOWANCE_MS = 1000.0
PHONE_PREDICT_S = 0.03          ## phones: Wi-Fi + browser event delay, roughly


class WsTransport:
    def __init__(self, ws: web.WebSocketResponse):
        self._ws = ws
        self._pending: asyncio.Queue[tuple[str, str]] = asyncio.Queue(maxsize=MAX_PENDING_WS_MESSAGES)
        self._ui = UiState()
        self._sender: asyncio.Task[None] | None = None
        self._closing = False

    def _send(self, obj: dict[str, Any]) -> None:
        if self._closing or self._ws.closed:
            return
        kind = obj["t"]
        if kind in ("ui", "player") or self._pending.full():
            pending = []
            while not self._pending.empty():
                previous = self._pending.get_nowait()
                self._pending.task_done()
                if kind not in ("ui", "player") or previous[0] != kind:
                    pending.append(previous)
            if len(pending) == MAX_PENDING_WS_MESSAGES:
                # Only feedback is disposable. There is at most one queued UI/player state.
                oldest_feedback = next(i for i, (k, _) in enumerate(pending) if k not in ("ui", "player"))
                pending.pop(oldest_feedback)
            for previous in pending:
                self._pending.put_nowait(previous)
        self._pending.put_nowait((kind, json.dumps(obj, separators=(",", ":"))))
        if self._sender is None or self._sender.done():
            self._sender = asyncio.create_task(self._send_pending())

    async def _send_pending(self) -> None:
        try:
            while True:
                _, text = await self._pending.get()
                try:
                    await self._ws.send_str(text)
                finally:
                    self._pending.task_done()
        except (ConnectionError, RuntimeError):
            pass

    async def close(self) -> None:
        self._closing = True
        if self._sender is not None:
            self._sender.cancel()
            await asyncio.gather(self._sender, return_exceptions=True)
        while not self._pending.empty():
            self._pending.get_nowait()
            self._pending.task_done()

    def send_ui(self, ui: dict[str, Any]) -> None:
        # Queue a complete persistent state so coalescing never loses an earlier title/legend.
        self._ui.apply(ui)
        message = {"t": "ui", **self._ui.snapshot()}
        if "toast" in ui:
            message["toast"] = ui["toast"]
        self._send(message)

    def beep(self, freq: int, ms: int) -> None:
        self._send({"t": "beep", "freq": freq, "ms": ms})

    def vibrate(self, pattern: list[int]) -> None:
        # "ms" too, for a phone still running an older page.
        self._send({"t": "vibrate", "pattern": pattern, "ms": pattern[0]})

    def set_player(self, player: int) -> None:
        self._send({"t": "player", "player": player})

    def notify_event(self, name: str) -> None:
        self._send({"t": "event", "name": name})


def _number_in_range(value: Any, minimum: float, maximum: float) -> bool:
    # Comparing first also rejects NaN/Infinity and huge ints without float conversion.
    return type(value) in (int, float) and minimum <= value <= maximum


def _integer_in_range(value: Any, minimum: int, maximum: int) -> bool:
    return type(value) is int and minimum <= value <= maximum


def _pair(value: Any) -> bool:
    return isinstance(value, list) and len(value) == 2


def clean_profile_name(value: Any, limit: int = 20) -> str:
    """A plain-text nickname, shared by the phone and local game profile.

    Strips control/non-printable characters so a name can never smuggle a
    newline or escape sequence into the roster, the game UI or logs. Rich
    text is escaped at the game UI boundary, not modified in storage.
    """
    if not isinstance(value, str):
        return ""
    return "".join(ch for ch in value if ch.isprintable()).strip()[:limit]


class WebSource:
    def __init__(self, hub: Hub, phone_axis_map: Any = PHONE_AXIS_MAP):
        self.hub = hub
        self.pairing_token = secrets.token_urlsafe(32)
        self.remaps = {"device": make_remap(phone_axis_map), "canonical": make_remap(CANONICAL_AXIS_MAP)}
        self.app = web.Application(middlewares=[self._local_access])
        self.app.add_routes(
            [
                web.get("/", self._page("phone.html")),
                web.get("/sim", self._page("sim.html")),
                web.get("/ws", self._ws),
                web.get("/api/status", self._status),
                web.get("/api/qr", self._qr),
                web.get("/api/pairing", self._pairing),
                web.static("/static", STATIC_DIR),
            ]
        )
        self.phone_app = web.Application(middlewares=[self._phone_access])
        self.phone_app.add_routes([
            web.get("/", self._page("phone.html")),
            web.get("/ws", self._ws),
            web.static("/static", STATIC_DIR),
        ])
        self._runner: web.AppRunner | None = None
        self._phone_runner: web.AppRunner | None = None

    @staticmethod
    def _ip(value: str) -> ipaddress.IPv4Address | ipaddress.IPv6Address:
        parsed = ipaddress.ip_address(value)
        return parsed.ipv4_mapped if isinstance(parsed, ipaddress.IPv6Address) and parsed.ipv4_mapped else parsed

    def _request_origin(self, request: web.Request) -> tuple[str, str, int]:
        """Trust the listener socket and IP literal, never a supplied public Host name."""
        hosts = request.headers.getall("Host", [])
        if len(hosts) != 1:
            raise web.HTTPForbidden()
        host = hosts[0]
        if any(ch.isspace() for ch in host) or any(ch in host for ch in "/\\?#@,"):
            raise web.HTTPForbidden()
        try:
            parsed = urlsplit("//" + host)
            hostname, port = parsed.hostname, parsed.port
            if hostname is None:
                raise ValueError("missing host")
            socket_name = request.transport.get_extra_info("sockname") if request.transport else None
            if socket_name is None:
                raise ValueError("missing listener")
            local_ip = self._ip(socket_name[0])
            port = port if port is not None else (443 if request.secure else 80)
            if port != socket_name[1]:
                raise ValueError("wrong listener port")
            if hostname == "localhost":
                if not local_ip.is_loopback:
                    raise ValueError("localhost on public interface")
            elif self._ip(hostname) != local_ip:
                raise ValueError("wrong listener address")
        except ValueError:
            raise web.HTTPForbidden() from None
        return request.scheme, hostname, port

    def _same_origin(self, request: web.Request, *, required: bool) -> None:
        expected = self._request_origin(request)
        origins = request.headers.getall("Origin", [])
        if not origins and not required:
            return
        if len(origins) != 1:
            raise web.HTTPForbidden()
        origin = origins[0]
        try:
            parsed = urlsplit(origin)
            if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password:
                raise ValueError("invalid origin")
            if parsed.path or parsed.query or parsed.fragment or any(ch.isspace() for ch in origin):
                raise ValueError("invalid origin")
            port = parsed.port if parsed.port is not None else (443 if parsed.scheme == "https" else 80)
            if (parsed.scheme, parsed.hostname, port) != expected:
                raise ValueError("cross origin")
        except ValueError:
            raise web.HTTPForbidden() from None

    @web.middleware
    async def _local_access(self, request: web.Request, handler: Any) -> web.StreamResponse:
        try:
            if not request.remote or not self._ip(request.remote).is_loopback:
                raise ValueError("non-loopback peer")
        except ValueError:
            raise web.HTTPForbidden() from None
        self._same_origin(request, required=False)
        response = await handler(request)
        if request.path.startswith("/api/"):
            response.headers["Cache-Control"] = "no-store"
            response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    @web.middleware
    async def _phone_access(self, request: web.Request, handler: Any) -> web.StreamResponse:
        self._request_origin(request)
        return await handler(request)

    def _page(self, name: str):
        async def handler(_req: web.Request) -> web.StreamResponse:
            return web.FileResponse(STATIC_DIR / name, headers={"Cache-Control": "no-cache"})

        return handler

    async def _status(self, _req: web.Request) -> web.Response:
        return web.json_response(self.hub.roster())

    async def _qr(self, _req: web.Request) -> web.Response:
        return web.json_response(self.hub.qr or {})

    async def _pairing(self, _req: web.Request) -> web.Response:
        return web.json_response({"token": self.pairing_token}, headers={"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"})

    async def start(self, http_host: str, http_port: int, https_port: int | None, ssl_ctx: ssl.SSLContext | None,
                    https_host: str = "0.0.0.0") -> None:
        try:
            self._runner = web.AppRunner(self.app, access_log=None)
            await self._runner.setup()
            await web.TCPSite(self._runner, http_host, http_port).start()
            log.info("simulator: http://%s:%d/sim", http_host, http_port)
            if https_port is not None and ssl_ctx is not None:
                self._phone_runner = web.AppRunner(self.phone_app, access_log=None)
                await self._phone_runner.setup()
                await web.TCPSite(self._phone_runner, https_host, https_port, ssl_context=ssl_ctx).start()
                log.info("phone controller: https://<lan-ip>:%d/", https_port)
        except BaseException:
            await self.stop()
            raise

    async def stop(self) -> None:
        if self._phone_runner is not None:
            await self._phone_runner.cleanup()
        if self._runner is not None:
            await self._runner.cleanup()

    async def _ws(self, request: web.Request) -> web.StreamResponse:
        self._same_origin(request, required=True)
        ws = web.WebSocketResponse(heartbeat=5.0, max_msg_size=1 << 20)
        await ws.prepare(request)
        transport = WsTransport(ws)
        controller: Controller | None = None
        last_sample_ms: float | None = None
        last_sample_arrival = 0.0
        loop = asyncio.get_running_loop()
        try:
            async for msg in ws:
                if msg.type != WSMsgType.TEXT:
                    if msg.type == WSMsgType.ERROR:
                        break
                    continue
                try:
                    data = json.loads(msg.data)
                except (ValueError, RecursionError):
                    continue
                if not isinstance(data, dict):
                    continue
                t = data.get("t")
                if t == "hello" and controller is None:
                    token = data.get("token")
                    if not isinstance(token, str) or not token.isascii() or not secrets.compare_digest(token, self.pairing_token):
                        await ws.close(code=1008, message=b"pairing required")
                        break
                    kind = "sim" if data.get("kind") == "sim" else "phone"
                    client_id = str(data.get("client_id") or id(ws))[:64]
                    name = clean_profile_name(str(data.get("name") or kind), limit=32) or kind
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
                    samples = data.get("s")
                    if not isinstance(samples, list):
                        continue
                    items = []
                    arrival = loop.time()
                    for s in samples[:MAX_SAMPLES_PER_MSG]:
                        if not isinstance(s, list) or len(s) != 7:
                            continue
                        if not _number_in_range(s[0], 0, MAX_TIMESTAMP_MS):
                            continue
                        if not all(_number_in_range(v, -MAX_GYRO_RAD_S, MAX_GYRO_RAD_S) for v in s[1:4]):
                            continue
                        if not all(_number_in_range(v, -MAX_ACCEL_M_S2, MAX_ACCEL_M_S2) for v in s[4:7]):
                            continue
                        timestamp = float(s[0])
                        if last_sample_ms is not None:
                            gap = timestamp - last_sample_ms
                            # Allow a backgrounded tab's real pause, but reject clock spikes.
                            maximum_gap = (arrival - last_sample_arrival) * 1000.0 + TIMESTAMP_GAP_ALLOWANCE_MS
                            if gap < MIN_SAMPLE_INTERVAL_MS or gap > maximum_gap:
                                continue
                        last_sample_ms = timestamp
                        last_sample_arrival = arrival
                        items.append((timestamp * 1000.0, remap((s[1], s[2], s[3])), remap((s[4], s[5], s[6]))))
                    self.hub.on_imu(controller, items)
                elif t == "in":
                    buttons = data.get("b", 0)
                    dials = data.get("d", [0, 0])
                    an = data.get("an", [0.0, 0.0])
                    if not _integer_in_range(buttons, 0, 255) or not _pair(dials) or not _pair(an):
                        continue
                    if not all(_integer_in_range(v, -32768, 32767) for v in dials):
                        continue
                    if not all(_number_in_range(v, -1.0, 1.0) for v in an):
                        continue
                    self.hub.on_input(controller, buttons, dials[0], dials[1], (float(an[0]), float(an[1])))
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
            await transport.close()
        return ws
