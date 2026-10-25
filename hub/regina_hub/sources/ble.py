"""Regina controllers over BLE (bleak). Scans, connects, auto-reconnects."""

from __future__ import annotations

import asyncio
import logging
import math
import struct
import time
from collections.abc import Callable, Sequence
from typing import Any

from .. import protocol as P
from ..controller import Controller
from ..frames import REGINA_DEFAULT_AXIS_MAP, make_remap
from ..hub import Hub

log = logging.getLogger("ble")

DEG2RAD = math.pi / 180.0
G = 9.80665
MAX_GYRO_RAD_S = 35.0
MAX_ACCEL_M_S2 = 160.0
BAD_PACKET_LOG_INTERVAL_S = 60.0
DISCONNECT_TIMEOUT_S = 5.0
GATT_TIMEOUT_S = 10.0
SCAN_DURATION_S = 3.0
SCAN_PAUSE_S = 2.0
CONNECTED_SCAN_PAUSE_S = 8.0
SCAN_RETRY_S = 5.0
NO_ADVERT_ROUNDS = 5
DIAGNOSTIC_INTERVAL_S = 60.0
MAX_PENDING_CONNECTIONS = 4
MAX_CANDIDATES = 64
CONNECTION_RETRY_S = 10.0
CANDIDATE_TTL_S = 30.0
WRITE_RETRY_S = 1.0
MAX_PENDING_COMMANDS = 64


def _sensor_vector(values: tuple[float, float, float], scale: float, limit: float) -> tuple[float, float, float]:
    scaled = (values[0] * scale, values[1] * scale, values[2] * scale)
    if any(not math.isfinite(value) or abs(value) > limit for value in scaled):
        raise ValueError("sensor value outside supported range")
    return scaled


class ReginaTransport:
    """Bounded serial writes; persistent OLED/player state survives a slow device."""

    def __init__(self, client: Any):
        self._client = client
        self._queue: asyncio.Queue[tuple[str, Any]] = asyncio.Queue(maxsize=MAX_PENDING_COMMANDS)
        self._ui = P.UiState()
        self._clear_generation = 0
        self._applied_clear_generation = 0
        self._resync_ui = False
        self._rotation = 3
        self._latest: dict[str, Any] = {}
        self._closed = False
        self._warning_at: dict[str, float] = {}
        self._task = asyncio.create_task(self._writer())

    def _warn(self, kind: str, message: str) -> None:
        now = time.monotonic()
        if now - self._warning_at.get(kind, float("-inf")) >= DIAGNOSTIC_INTERVAL_S:
            self._warning_at[kind] = now
            log.warning(message)

    async def _writer(self) -> None:
        while True:
            kind, value = await self._queue.get()
            try:
                if kind == "ui":
                    generation = self._clear_generation
                    update = dict(self._ui.fields)
                    if self._resync_ui or generation > self._applied_clear_generation:
                        update["clear"] = True
                    if value[0] == generation and value[1] is not None:
                        update["toast"] = value[1]
                    packets = P.encode_ui_packets(update, self._client.mtu_size, self._rotation)
                else:
                    packets = [value]
                for data in packets:
                    await asyncio.wait_for(self._client.write_gatt_char(P.CMD_CHAR_UUID, data, response=False), GATT_TIMEOUT_S)
                if kind == "ui":
                    self._applied_clear_generation = generation
                    self._resync_ui = False
            except Exception:  # noqa: BLE001 - backend failures must not kill the writer
                self._warn("write", "BLE write failed or timed out; check the controller connection")
                # A partial OLED write needs one clear on recovery. Ordinary updates must
                # not clear: the firmware would erase an active toast and its default page.
                if kind in self._latest:
                    if kind == "ui" and any(key != "toast" for key in update):
                        self._resync_ui = True
                    await asyncio.sleep(WRITE_RETRY_S)
                    self._put(kind, self._latest[kind])
            finally:
                self._queue.task_done()

    def _put(self, kind: str, data: Any) -> None:
        if self._closed:
            return
        persistent = kind in ("ui", "player", "rotation")
        if persistent:
            self._latest[kind] = data
        if persistent or self._queue.full():
            pending = []
            while not self._queue.empty():
                old = self._queue.get_nowait()
                self._queue.task_done()
                if not persistent or old[0] != kind:
                    pending.append(old)
            if len(pending) == MAX_PENDING_COMMANDS:
                disposable = next(i for i, (k, _) in enumerate(pending) if k not in self._latest)
                pending.pop(disposable)
                self._warn("queue", "BLE feedback queue full; retaining the latest player and OLED state")
            for old in pending:
                self._queue.put_nowait(old)
        self._queue.put_nowait((kind, data))

    def close(self) -> None:
        self._closed = True
        self._task.cancel()
        while not self._queue.empty():
            self._queue.get_nowait()
            self._queue.task_done()

    def send_ui(self, ui: dict[str, Any]) -> None:
        if ui.get("clear"):
            self._clear_generation += 1
        self._ui.apply(ui)
        self._put("ui", (self._clear_generation, ui.get("toast")))

    def beep(self, freq: int, ms: int) -> None:
        self._put("beep", P.cmd_beep(freq, ms))

    def vibrate(self, pattern: list[int]) -> None:
        # The firmware takes one pulse (and has no motor yet): send the longest.
        self._put("vibrate", P.cmd_vibrate(max(pattern[0::2])))

    def set_player(self, player: int) -> None:
        self._put("player", P.cmd_set_player(player))

    def set_rotation(self, rotation: int) -> None:
        self._rotation = rotation & 3
        self._put("rotation", P.cmd_set_rotation(rotation))
        if self._ui.fields:
            self._put("ui", (self._clear_generation, None))

    def notify_event(self, name: str) -> None:
        pass


class ReginaBleSource:
    def __init__(self, hub: Hub, axis_map: Sequence[str] = REGINA_DEFAULT_AXIS_MAP, name_prefix: str = P.DEVICE_NAME_PREFIX,
                 allow: Sequence[str] = (), screen_rotation: int = 3):
        self.hub = hub
        self.screen_rotation = screen_rotation
        self.remap = make_remap(axis_map)
        self.name_prefix = name_prefix
        self.allow = {a.upper() for a in allow}
        self._active: dict[str, Any] = {}      # address -> BleakClient (connected or connecting)
        self._close_connections: dict[str, Callable[[], None]] = {}
        self._candidates: dict[str, tuple[Any, str, bool, float]] = {}
        self._retry_after: dict[str, float] = {}
        self._connecting: dict[str, asyncio.Task[None]] = {}
        self._connected: set[str] = set()
        self._empty_scans = 0
        self._scan_failed = False
        self._diagnostic_at: dict[str, float] = {}
        self._bad_packet_log_at = float("-inf")

    def _diagnostic(self, kind: str, message: str) -> None:
        now = time.monotonic()
        if now - self._diagnostic_at.get(kind, float("-inf")) >= DIAGNOSTIC_INTERVAL_S:
            self._diagnostic_at[kind] = now
            log.warning(message)

    def _refresh_state(self) -> None:
        if self._scan_failed:
            state = "unavailable"
        elif self._connected:
            state = "connected"
        elif self._empty_scans >= NO_ADVERT_ROUNDS:
            state = "no_adverts"
        else:
            state = "scanning"
        self.hub.set_ble_state(state)

    def _connection_done(self, addr: str, task: asyncio.Task[None]) -> None:
        if self._connecting.get(addr) is task:
            self._connecting.pop(addr, None)
        if task.cancelled():
            return
        if addr in self._connected:
            self._retry_after.pop(addr, None)
        else:
            if addr not in self._retry_after and len(self._retry_after) >= MAX_CANDIDATES:
                self._retry_after.pop(next(iter(self._retry_after)))
            self._retry_after[addr] = time.monotonic() + CONNECTION_RETRY_S
        if task.exception() is not None:
            self._diagnostic("connect", "BLE connection setup failed; scanning will continue")

    def _prune_candidates(self) -> None:
        now = time.monotonic()
        for addr, (_, _, _, seen) in list(self._candidates.items()):
            if now - seen >= CANDIDATE_TTL_S:
                self._candidates.pop(addr, None)
        for addr, retry_at in list(self._retry_after.items()):
            if retry_at <= now:
                self._retry_after.pop(addr, None)

    def _bad_packet(self, kind: str, controller: Controller) -> None:
        # Do not let a corrupt notification stream flood logs or persist payloads / addresses.
        now = time.monotonic()
        if now - self._bad_packet_log_at >= BAD_PACKET_LOG_INTERVAL_S:
            self._bad_packet_log_at = now
            log.warning("discarded invalid %s packet from controller %d", kind, controller.id)

    def _matches(self, device: Any, adv: Any) -> tuple[str, bool] | None:
        """Returns (display name, is_legacy_firmware) for Regina devices."""
        name = adv.local_name or device.name or ""
        uuids = [u.lower() for u in (adv.service_uuids or [])]
        legacy = name == P.LEGACY_NAME or P.LEGACY_SERVICE_UUID in uuids
        if not (legacy or name.startswith(self.name_prefix) or P.SERVICE_UUID in uuids):
            return None
        if self.allow and device.address.upper() not in self.allow and name.upper() not in self.allow:
            return None
        if legacy:
            return "Regina-" + device.address.replace(":", "")[-4:] + " (old fw)", True
        return name or device.address, False

    async def run(self) -> None:
        from bleak import BleakScanner

        adverts = 0

        def on_detect(device: Any, adv: Any) -> None:
            nonlocal adverts
            adverts += 1
            match = self._matches(device, adv)
            now = time.monotonic()
            addr = device.address
            if (match and addr not in self._active and addr not in self._connecting
                    and self._retry_after.get(addr, 0.0) <= now
                    and (addr in self._candidates or len(self._candidates) < MAX_CANDIDATES)):
                # Updating an existing dict entry retains its FIFO position across scans.
                self._candidates[addr] = (device, match[0], match[1], now)

        log.info("scanning for Regina controllers; allowlist %s", f"enabled ({len(self.allow)} entries)" if self.allow else "disabled")
        self.hub.set_ble_state("scanning")
        try:
            while True:
                self._prune_candidates()
                adverts = 0
                try:
                    async with asyncio.timeout(SCAN_DURATION_S + 2 * GATT_TIMEOUT_S):
                        async with BleakScanner(detection_callback=on_detect):
                            await asyncio.sleep(SCAN_DURATION_S)
                except Exception:  # noqa: BLE001 - adapter off / busy
                    self._scan_failed = True
                    self._refresh_state()
                    self._diagnostic("scan", "BLE scanning unavailable; check the adapter and try turning Bluetooth off and on")
                    await asyncio.sleep(SCAN_RETRY_S)
                    continue
                self._scan_failed = False
                self._empty_scans = self._empty_scans + 1 if adverts == 0 and not self._connected else 0
                if self._empty_scans >= NO_ADVERT_ROUNDS:
                    self._diagnostic("empty", "No Bluetooth advertisements seen; try turning Bluetooth off and on")
                self._prune_candidates()
                for addr, (device, name, legacy, _seen) in list(self._candidates.items()):
                    if len(self._connecting) >= MAX_PENDING_CONNECTIONS:
                        break
                    if addr not in self._active and addr not in self._connecting:
                        self._candidates.pop(addr, None)
                        task = asyncio.create_task(self._connect(device, name, legacy))
                        self._connecting[addr] = task
                        task.add_done_callback(lambda done, address=addr: self._connection_done(address, done))
                self._refresh_state()
                await asyncio.sleep(CONNECTED_SCAN_PAUSE_S if self._connected else SCAN_PAUSE_S)
        finally:
            tasks = list(self._connecting.values())
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            clients = list(self._active.values())
            for close in list(self._close_connections.values()):
                close()
            await asyncio.gather(*(self._disconnect(client) for client in clients))
            self._candidates.clear()
            self._retry_after.clear()
            self.hub.set_ble_state("disabled")

    async def _disconnect(self, client: Any) -> None:
        try:
            await asyncio.wait_for(client.disconnect(), DISCONNECT_TIMEOUT_S)
        except Exception:  # noqa: BLE001 - backend failure must not interrupt local cleanup
            self._diagnostic("disconnect", "BLE disconnect failed; local connection state was cleared")

    async def _connect(self, device: Any, name: str, legacy: bool = False) -> None:
        from bleak import BleakClient

        addr = device.address
        controller: Controller | None = None
        transport: ReginaTransport | None = None
        closed = False

        def close_connection() -> None:
            nonlocal closed
            if closed:
                return
            closed = True
            self._active.pop(addr, None)
            self._close_connections.pop(addr, None)
            self._connected.discard(addr)
            if transport is not None:
                transport.close()
            if controller is not None:
                self.hub.detach(controller)
            self._refresh_state()

        def check_connected() -> None:
            if closed:
                raise ConnectionError("controller disconnected during setup")

        def on_disconnect(_client: Any) -> None:
            log.info("Regina controller disconnected")
            close_connection()

        client = BleakClient(device, disconnected_callback=on_disconnect, timeout=GATT_TIMEOUT_S)
        self._active[addr] = client
        self._close_connections[addr] = close_connection
        try:
            log.info("connecting Regina controller")
            await asyncio.wait_for(client.connect(), GATT_TIMEOUT_S)
            check_connected()
            if legacy:
                controller = await self._setup_legacy(client, addr, name)
                if controller is None:
                    close_connection()
                    await self._disconnect(client)
                elif closed:
                    self.hub.detach(controller)
                else:
                    self._connected.add(addr)
                    self._empty_scans = 0
                    self._scan_failed = False
                    self._refresh_state()
                return
            transport = ReginaTransport(client)
            transport.set_rotation(self.screen_rotation)
            controller = self.hub.attach("regina", f"regina:{addr}", name, transport, rate_hint_hz=200.0, wrap_bits=32)
            if controller is None:
                log.warning("Regina controller refused: controller registry full")
                close_connection()
                await self._disconnect(client)
                return
            controller.extra["mtu"] = client.mtu_size
            c = controller

            def on_imu(_char: Any, data: bytearray) -> None:
                try:
                    pkt = P.parse_imu(bytes(data))
                    items = [
                        (
                            float(s.t_us),
                            self.remap(_sensor_vector(s.gyro_dps, DEG2RAD, MAX_GYRO_RAD_S)),
                            self.remap(_sensor_vector(s.accel_g, G, MAX_ACCEL_M_S2)),
                        )
                        for s in pkt.samples
                    ]
                    self.hub.on_imu(c, items, seq=pkt.seq)
                except (ValueError, OverflowError, struct.error):
                    self._bad_packet("IMU", c)
                    return

            def on_input(_char: Any, data: bytearray) -> None:
                try:
                    pkt = P.parse_input(bytes(data))
                    self.hub.on_input(c, pkt.buttons, pkt.dial_small, pkt.dial_big)
                except (ValueError, OverflowError, struct.error):
                    self._bad_packet("input", c)
                    return

            def on_status(_char: Any, data: bytearray) -> None:
                try:
                    st = P.parse_status(bytes(data))
                    self.hub.on_status(c, st.battery, st.charging, imu_ok=st.imu_ok, imu_irq=st.imu_irq, fw=f"{st.fw[0]}.{st.fw[1]}")
                except (ValueError, OverflowError, struct.error):
                    self._bad_packet("status", c)
                    return

            await asyncio.wait_for(client.start_notify(P.IMU_CHAR_UUID, on_imu), GATT_TIMEOUT_S)
            check_connected()
            await asyncio.wait_for(client.start_notify(P.INPUT_CHAR_UUID, on_input), GATT_TIMEOUT_S)
            check_connected()
            await asyncio.wait_for(client.start_notify(P.STATUS_CHAR_UUID, on_status), GATT_TIMEOUT_S)
            check_connected()
            status = await asyncio.wait_for(client.read_gatt_char(P.STATUS_CHAR_UUID), GATT_TIMEOUT_S)
            check_connected()
            on_status(None, status)
            buttons = await asyncio.wait_for(client.read_gatt_char(P.INPUT_CHAR_UUID), GATT_TIMEOUT_S)
            check_connected()
            on_input(None, buttons)
            self._connected.add(addr)
            self._empty_scans = 0
            self._scan_failed = False
            self._refresh_state()
            log.info("controller %d ready (mtu %s)", c.id, client.mtu_size)
        except asyncio.CancelledError:
            close_connection()
            await self._disconnect(client)
            raise
        except Exception:  # noqa: BLE001 - only this device setup fails
            self._diagnostic("connect", "BLE connection setup failed or timed out; scanning will continue")
            close_connection()
            await self._disconnect(client)

    async def _setup_legacy(self, client: Any, addr: str, name: str) -> Controller | None:
        """Original Regina firmware: ~20 Hz float accel (g) + gyro (dps), no timestamps or downlink."""
        from ..controller import NullTransport

        controller = self.hub.attach("regina", f"regina:{addr}", name, NullTransport(), rate_hint_hz=20.0, wrap_bits=None)
        if controller is None:
            log.warning("Regina controller refused: controller registry full")
            return None
        controller.extra["fw"] = "legacy"
        c = controller
        last_accel: list[tuple[float, float, float] | None] = [None]

        def on_accel(_char: Any, data: bytearray) -> None:
            try:
                last_accel[0] = _sensor_vector(P.parse_legacy_vec3(bytes(data)), G, MAX_ACCEL_M_S2)
            except (ValueError, OverflowError, struct.error):
                last_accel[0] = None
                self._bad_packet("legacy accel", c)

        def on_gyro(_char: Any, data: bytearray) -> None:
            if last_accel[0] is None:
                return
            try:
                gyro = _sensor_vector(P.parse_legacy_vec3(bytes(data)), DEG2RAD, MAX_GYRO_RAD_S)
                # No device clock: timestamp on arrival (BLE jitter goes straight into the integration).
                t_us = time.perf_counter() * 1e6  # monotonic() ticks every ~16 ms on Windows
                self.hub.on_imu(c, [(t_us, self.remap(gyro), self.remap(last_accel[0]))])
            except (ValueError, OverflowError, struct.error):
                self._bad_packet("legacy gyro", c)

        def on_input(_char: Any, data: bytearray) -> None:
            try:
                pkt = P.parse_legacy_input(bytes(data))
                self.hub.on_input(c, pkt.buttons, pkt.dial_small, pkt.dial_big)
            except (ValueError, OverflowError, struct.error):
                self._bad_packet("legacy input", c)
                return

        try:
            await asyncio.wait_for(client.start_notify(P.LEGACY_ACCEL_UUID, on_accel), GATT_TIMEOUT_S)
            await asyncio.wait_for(client.start_notify(P.LEGACY_GYRO_UUID, on_gyro), GATT_TIMEOUT_S)
            await asyncio.wait_for(client.start_notify(P.LEGACY_INPUT_UUID, on_input), GATT_TIMEOUT_S)
        except BaseException:
            # The caller only receives this controller after all subscriptions are ready.
            self.hub.detach(controller)
            raise
        log.info("controller %d ready (original firmware, ~20 Hz; flash firmware/ for 200 Hz)", controller.id)
        return controller
