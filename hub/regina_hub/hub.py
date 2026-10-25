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

# Registry limits (#45): the registry used to grow without bound -- every new
# client_id kept its entry (and its ever-increasing id) forever, until ids no
# longer fit the u8 game protocol and the roster JSON outgrew one UDP datagram.
MAX_CONTROLLERS = 32            ## live + recently disconnected controllers kept in the registry
MAX_CONTROLLER_ID = 255         ## game protocol packs controller ids as u8
REGISTRY_IDLE_EVICT_S = 300.0   ## a disconnected controller is forgotten after 5 minutes
ROSTER_MAX_BYTES = 60000        ## roster JSON stays below the 65507-byte UDP datagram limit

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
        # The id the next attach would hand out: ids are recycled smallest-free
        # (#45), so this is a derived hint, refreshed whenever ids are taken or
        # freed (the pairing tests assert a refused hello never advances it).
        self._next_id = 1
        self._players_by_key: dict[str, int] = {}
        self._roster_trim_warned_at = 0.0
        self.game = GameLink(self, ("127.0.0.1", game_port))
        self.hub_port = hub_port
        self.recorder = recorder
        self.phone_url: str | None = None
        self.qr: dict[str, Any] | None = None
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
            self._prune_registry(now)
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

    # ------------------------------------------------------------ registry ----

    def attach(self, kind: str, key: str, name: str, transport: Transport, rate_hint_hz: float, wrap_bits: int | None) -> Controller | None:
        """Returns None when the registry is full and no disconnected entry can be
        evicted; callers must refuse the connection gracefully (#45)."""
        cid = self._ids_by_key.get(key)
        if cid is None:
            self._prune_registry()
            if len(self.controllers) >= MAX_CONTROLLERS:
                log.warning("attach refused for %s: registry full (%d controllers)", key, len(self.controllers))
                return None
            used = set(self.controllers)
            cid = next((i for i in range(1, MAX_CONTROLLER_ID + 1) if i not in used), None)
            if cid is None:
                log.warning("attach refused for %s: no free controller id in 1..%d", key, MAX_CONTROLLER_ID)
                return None
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

        self._refresh_next_id()
        log.info("controller %d attached: %s %s (player %d)", cid, kind, name, c.player)
        transport.set_player(c.player)
        if c.ui.fields:
            transport.send_ui(c.ui.snapshot())
        self._emit_event(c, "connected")
        self._roster_dirty = True
        return c

    def detach(self, c: Controller) -> None:
        if self.controllers.get(c.id) is not c:
            return
        c.connected = False
        c.disconnected_at = _now()
        log.info("controller %d detached: %s", c.id, c.name)
        self._emit_event(c, "disconnected")
        self._roster_dirty = True

    def _refresh_next_id(self) -> None:
        used = set(self.controllers)
        self._next_id = next((i for i in range(1, MAX_CONTROLLER_ID + 1) if i not in used), MAX_CONTROLLER_ID + 1)

    def _evict(self, c: Controller) -> None:
        """Forget a disconnected controller entirely. The game already received its
        disconnected event at detach time; the entry simply stops appearing in the
        roster. _players_by_key is deliberately kept, so a returning device gets
        its old player number back."""
        self.controllers.pop(c.id, None)
        if self._ids_by_key.get(c.key) == c.id:
            del self._ids_by_key[c.key]
        self._refresh_next_id()
        log.info("controller %d forgotten: %s (disconnected)", c.id, c.key)
        self._roster_dirty = True

    def _prune_registry(self, now: float | None = None) -> None:
        """Evict disconnected controllers past REGISTRY_IDLE_EVICT_S; if the registry
        is still at MAX_CONTROLLERS, evict longest-disconnected first (#45)."""
        now = _now() if now is None else now
        for c in list(self.controllers.values()):
            if not c.connected and c.disconnected_at is not None and now - c.disconnected_at > REGISTRY_IDLE_EVICT_S:
                self._evict(c)
        if len(self.controllers) >= MAX_CONTROLLERS:
            disconnected = sorted(
                (c for c in self.controllers.values() if not c.connected),
                key=lambda c: c.disconnected_at or 0.0,
            )
            for c in disconnected:
                if len(self.controllers) < MAX_CONTROLLERS:
                    break
                self._evict(c)

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
        if fused and not c.pack_failed:
            try:
                datagrams = P.build_game_samples(c.id, fused)
            except (struct.error, OverflowError, ValueError) as exc:
                self._drop_bad_packer(c, exc)
                return fused
            for dgram in datagrams:
                self.game.send(dgram)
        self._dispatch_events(c, c.tick(_now()))
        return fused

    def on_input(self, c: Controller, buttons: int, small: int, big: int, analog: tuple[float, float] = (0.0, 0.0)) -> None:
        if self.recorder is not None:
            self.recorder.input(c, buttons, small, big, analog)
        c.ingest_input(buttons, small, big, analog, _now())
        if c.pack_failed:
            return
        try:
            packet = P.build_game_input(c.id, buttons, small, big, analog[0], analog[1])
        except (struct.error, OverflowError, ValueError) as exc:
            self._drop_bad_packer(c, exc)
            return
        self.game.send(packet)

    def _drop_bad_packer(self, c: Controller, exc: Exception) -> None:
        """A controller whose state cannot be packed for the game (e.g. an out-of-range
        id) must not take its source down with an exception per message (#45). Warn
        once and detach it; the source notices the disconnect through its usual path."""
        c.pack_failed = True
        log.warning("controller %d (%s): game packet packing failed (%s); detaching", c.id, c.key, exc)
        if c.connected:
            self.detach(c)

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
        controllers = sorted(self.controllers.values(), key=lambda c: c.id)
        entries = [c.roster_entry() for c in controllers]
        payload: dict[str, Any] = {"type": "roster", "controllers": entries, "phone_url": self.phone_url}
        size = len(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
        if size > ROSTER_MAX_BYTES:
            # One oversized datagram would be dropped whole and the game would lose
            # every controller; disconnected entries are the expendable part (#45).
            payload = {
                "type": "roster",
                "controllers": [e for c, e in zip(controllers, entries, strict=True) if c.connected],
                "phone_url": self.phone_url,
            }
            now = _now()
            if now - self._roster_trim_warned_at > 60.0:
                self._roster_trim_warned_at = now
                log.warning("roster of %d bytes trimmed to connected controllers only (%d of %d entries)",
                            size, len(payload["controllers"]), len(entries))
        return payload
