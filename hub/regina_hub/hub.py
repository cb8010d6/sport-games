"""Controller registry, player assignment, game link and event routing."""

from __future__ import annotations

import asyncio
import json
import logging
import socket
import struct
import sys
import threading
import time
from typing import Any

from . import protocol as P
from .controller import Controller, Transport
from .fusion import FusedSample
from .quat import Vec3, q_from_rotvec, q_mul, q_normalize, v_scale

log = logging.getLogger("hub")

MAX_PLAYERS = 4
BAD_COMMAND_WARNING_S = 60.0

EVENT_FEEDBACK = {
    # event -> (toast text, beep freq, beep ms)
    "recentered": ("RECENTER OK", 2400, 60),
    "calibrated": ("CALIBRATED", 1800, 60),
    "calibrate_failed": ("HOLD STILL!", 600, 200),
    "low_battery": ("LOW BATTERY", 800, 300),
}


def _now() -> float:
    return time.monotonic()


class GameLink:
    """UDP link to the Godot game on localhost.

    Receives on a plain blocking socket in a thread instead of an asyncio datagram endpoint:
    on Windows the Proactor transport stops reading for good after the first "port
    unreachable" error, which happens every time the game exits while samples are streaming.
    """

    def __init__(self, hub: Hub, game_addr: tuple[str, int]):
        self.hub = hub
        self.game_addr = game_addr
        self.sock: socket.socket | None = None
        self.last_hello = 0.0
        self.sent = 0
        self._loop: asyncio.AbstractEventLoop | None = None
        self._thread: threading.Thread | None = None
        self._closing = False

    def start(self, sock: socket.socket, loop: asyncio.AbstractEventLoop) -> None:
        self.sock = sock
        self._loop = loop
        self._thread = threading.Thread(target=self._recv_loop, name="game-link-rx", daemon=True)
        self._thread.start()

    def close(self) -> None:
        self._closing = True
        if self.sock is not None:
            self.sock.close()
        if self._thread is not None:
            self._thread.join(timeout=1.0)

    def _recv_loop(self) -> None:
        assert self.sock is not None and self._loop is not None
        while not self._closing:
            try:
                data, addr = self.sock.recvfrom(65536)
            except TimeoutError:
                continue
            except OSError:
                if self._closing:
                    return
                continue  # ICMP port unreachable etc. -- the socket is still usable
            try:
                self._loop.call_soon_threadsafe(self.datagram_received, data, addr)
            except RuntimeError:  # loop closed
                return

    def datagram_received(self, data: bytes, addr: tuple[str, int]) -> None:
        try:
            msg = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            log.warning("bad datagram from %s", addr)
            return
        if isinstance(msg, dict):
            self.hub.handle_game_command(msg)

    @property
    def game_present(self) -> bool:
        return _now() - self.last_hello < 6.0

    def send(self, data: bytes) -> None:
        if self.sock is None:
            return
        try:
            self.sock.sendto(data, self.game_addr)
            self.sent += 1
        except OSError:
            pass  # game not running / buffer full: drop, the stream is real-time anyway

    def send_json(self, obj: dict[str, Any]) -> None:
        self.send(json.dumps(obj, separators=(",", ":")).encode("utf-8"))


def make_udp_socket(host: str, port: int) -> socket.socket:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if sys.platform == "win32" and hasattr(socket, "SIO_UDP_CONNRESET"):
        sock.ioctl(socket.SIO_UDP_CONNRESET, False)  # type: ignore[attr-defined]
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
    sock.bind((host, port))
    sock.settimeout(0.25)  # blocking recv in GameLink's thread; wakes up to notice close()
    return sock


class Hub:
    def __init__(self, game_port: int = P.GAME_PORT, hub_port: int = P.HUB_PORT, recorder: Any = None):
        self.controllers: dict[int, Controller] = {}
        self._ids_by_key: dict[str, int] = {}
        self._players_by_key: dict[str, int] = {}
        self._next_id = 1
        self.game = GameLink(self, ("127.0.0.1", game_port))
        self.hub_port = hub_port
        self.recorder = recorder
        self.phone_url: str | None = None
        self.qr: dict[str, Any] | None = None
        self.ble_state = "disabled"
        self._roster_dirty = True
        self._last_bad_command_warning: float | None = None

    # ------------------------------------------------------------- lifecycle ----

    async def start(self) -> None:
        loop = asyncio.get_running_loop()
        self.game.start(make_udp_socket("127.0.0.1", self.hub_port), loop)
        log.info("game link: listening udp 127.0.0.1:%d, sending to %s:%d", self.hub_port, *self.game.game_addr)

    async def run_forever(self) -> None:
        last_roster = 0.0
        while True:
            now = _now()
            for c in list(self.controllers.values()):
                if c.connected:
                    self._dispatch_events(c, c.tick(now))
            if self._roster_dirty or now - last_roster > 0.5:
                self._roster_dirty = False
                last_roster = now
                self.game.send_json(self.roster())
            await asyncio.sleep(0.05)

    def close(self) -> None:
        self.game.close()

    def set_ble_state(self, state: str) -> None:
        """Optional BLE diagnostic; older game clients can ignore the roster field."""
        if state not in ("disabled", "scanning", "connected", "no_adverts", "unavailable"):
            raise ValueError("unknown BLE state")
        if state != self.ble_state:
            self.ble_state = state
            self._roster_dirty = True

    # ------------------------------------------------------------ registry ----

    def attach(self, kind: str, key: str, name: str, transport: Transport, rate_hint_hz: float, wrap_bits: int | None) -> Controller:
        cid = self._ids_by_key.get(key)
        if cid is None:
            cid = self._next_id
            self._next_id += 1
            self._ids_by_key[key] = cid
        old = self.controllers.get(cid)
        c = Controller(cid, kind, key, name, transport, rate_hint_hz, wrap_bits)
        if old is not None:
            c.ui = old.ui
        self.controllers[cid] = c

        wanted = self._players_by_key.get(key, 0)
        taken = {o.player for o in self.controllers.values() if o is not c and o.connected}
        if wanted and wanted not in taken:
            c.player = wanted
        else:
            c.player = next((p for p in range(1, MAX_PLAYERS + 1) if p not in taken), 0)
        self._players_by_key[key] = c.player

        log.info("controller %d attached: %s (player %d)", cid, kind, c.player)
        transport.set_player(c.player)
        if c.ui.fields:
            transport.send_ui(c.ui.snapshot())
        self._emit_event(c, "connected")
        self._roster_dirty = True
        return c

    def detach(self, c: Controller) -> None:
        if self.controllers.get(c.id) is not c or not c.connected:
            return
        c.connected = False
        log.info("controller %d detached", c.id)
        self._emit_event(c, "disconnected")
        self._roster_dirty = True

    def assign_player(self, cid: int, player: int) -> None:
        c = self.controllers.get(cid)
        if c is None or not (0 <= player <= MAX_PLAYERS):
            return
        if player:
            for other in self.controllers.values():
                if other is not c and other.player == player:
                    other.player = c.player  # swap
                    self._players_by_key[other.key] = other.player
                    other.transport.set_player(other.player)
        c.player = player
        self._players_by_key[c.key] = player
        c.transport.set_player(player)
        self._roster_dirty = True

    # ---------------------------------------------------------------- uplink ----

    def on_imu(self, c: Controller, items: list[tuple[float, Vec3, Vec3]], seq: int | None = None) -> list[FusedSample]:
        if seq is not None:
            c.note_seq(seq)
        if self.recorder is not None:
            self.recorder.imu(c, items)
        fused = c.ingest_imu(items, _now())
        if c.predict_s > 0.0:
            # Turn each orientation on by the current rate for the link's latency, so the game
            # sees where the controller is now rather than where it was when the sample left.
            for s in fused:
                s.q = q_normalize(q_mul(s.q, q_from_rotvec(v_scale(s.gyro, c.predict_s))))
        if fused:
            for dgram in P.build_game_samples(c.id, fused):
                self.game.send(dgram)
        self._dispatch_events(c, c.tick(_now()))
        return fused

    def on_input(self, c: Controller, buttons: int, small: int, big: int, analog: tuple[float, float] = (0.0, 0.0)) -> None:
        if self.recorder is not None:
            self.recorder.input(c, buttons, small, big, analog)
        c.ingest_input(buttons, small, big, analog, _now())
        self.game.send(P.build_game_input(c.id, buttons, small, big, analog[0], analog[1]))

    def on_status(self, c: Controller, battery: int | None, charging: bool, **extra: Any) -> None:
        events = c.ingest_status(battery, charging)
        c.extra.update(extra)
        self._dispatch_events(c, events)
        self._roster_dirty = True

    # -------------------------------------------------------------- events ----

    def _dispatch_events(self, c: Controller, events: list[str]) -> None:
        for ev in events:
            self._emit_event(c, ev)
            fb = EVENT_FEEDBACK.get(ev)
            if fb is not None:
                text, freq, ms = fb
                c.transport.send_ui({"toast": {"ms": 900, "text": text}})
                c.transport.beep(freq, ms)
            c.transport.notify_event(ev)
            if ev in ("calibrated", "calibrate_failed"):
                self._roster_dirty = True

    def _emit_event(self, c: Controller, name: str) -> None:
        log.info("event %s: controller %d", name, c.id)
        self.game.send_json({"type": "event", "controller": c.id, "name": name})

    # ------------------------------------------------------------ game cmds ----

    def _targets(self, msg: dict[str, Any]) -> list[Controller]:
        cid = int(msg.get("controller", 0) or 0)
        if cid == 0:
            return [c for c in self.controllers.values() if c.connected]
        c = self.controllers.get(cid)
        return [c] if c is not None and c.connected else []

    def handle_game_command(self, msg: dict[str, Any]) -> None:
        cmd = msg.get("cmd")
        try:
            if cmd == "hello":
                first = not self.game.game_present
                self.game.last_hello = _now()
                if first:
                    log.info("game connected")
                    self._roster_dirty = True
                    if self.qr is not None:
                        self.game.send_json(self.qr)
            elif cmd == "set_player":
                self.assign_player(int(msg["controller"]), int(msg["player"]))
            elif cmd == "recenter":
                for c in self._targets(msg):
                    c.pipeline.recenter()
                    self._dispatch_events(c, c.tick(_now()))
            elif cmd == "calibrate":
                for c in self._targets(msg):
                    c.pipeline.request_calibration()
                    c.transport.send_ui({"toast": {"ms": 1500, "text": "HOLD STILL"}})
                    self._roster_dirty = True
            elif cmd == "beep":
                for c in self._targets(msg):
                    c.transport.beep(int(msg.get("freq", 2000)), int(msg.get("ms", 80)))
            elif cmd == "vibrate":
                pattern = P.normalize_vibe(msg)
                if pattern:
                    for c in self._targets(msg):
                        c.transport.vibrate(pattern)
            elif cmd == "ui":
                ui = P.normalize_ui(msg.get("ui") or {})
                for c in self._targets(msg):
                    c.apply_ui(ui)
            elif cmd == "qr":
                if self.qr is not None:
                    self.game.send_json(self.qr)
            else:
                log.warning("unknown game command: %r", msg)
        except (KeyError, TypeError, ValueError, OverflowError, struct.error) as exc:
            now = _now()
            if self._last_bad_command_warning is None or now - self._last_bad_command_warning >= BAD_COMMAND_WARNING_S:
                self._last_bad_command_warning = now
                log.warning("invalid game command ignored (%s)", type(exc).__name__)

    def roster(self) -> dict[str, Any]:
        return {
            "type": "roster",
            "controllers": [c.roster_entry() for c in sorted(self.controllers.values(), key=lambda c: c.id)],
            "phone_url": self.phone_url,
            "ble_state": self.ble_state,
        }
