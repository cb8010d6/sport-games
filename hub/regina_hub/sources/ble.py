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
from ..diagnostics import WarningLimiter, redact_devices
from ..frames import REGINA_DEFAULT_AXIS_MAP, make_remap
from ..hub import Hub

log = logging.getLogger("ble")

DEG2RAD = math.pi / 180.0
G = 9.80665
MAX_GYRO_RAD_S = 35.0
MAX_ACCEL_M_S2 = 160.0
BAD_PACKET_LOG_INTERVAL_S = 60.0
DISCONNECT_TIMEOUT_S = 5.0


def _sensor_vector(values: tuple[float, float, float], scale: float, limit: float) -> tuple[float, float, float]:
    scaled = (values[0] * scale, values[1] * scale, values[2] * scale)
    if any(not math.isfinite(value) or abs(value) > limit for value in scaled):
        raise ValueError("sensor value outside supported range")
    return scaled


class ReginaTransport:
    """Serializes GATT writes to one device through a queue."""

    def __init__(self, client: Any):
        self._client = client
        self._queue: asyncio.Queue[bytes] = asyncio.Queue(maxsize=64)
        self._full_warning = WarningLimiter()
        self._task = asyncio.create_task(self._writer())

    async def _writer(self) -> None:
        while True:
            data = await self._queue.get()
            try:
                await self._client.write_gatt_char(P.CMD_CHAR_UUID, data, response=False)
            except Exception as exc:  # noqa: BLE001 - device may have dropped
                log.debug("write failed: %s", redact_devices(exc))

    def _put(self, data: bytes) -> None:
        try:
            self._queue.put_nowait(data)
        except asyncio.QueueFull:
            self._full_warning.warning(log, "command queue full, dropping %d bytes", len(data))

    def close(self) -> None:
        self._task.cancel()

    def send_ui(self, ui: dict[str, Any]) -> None:
        self._put(P.encode_ui_tlv(ui))

    def beep(self, freq: int, ms: int) -> None:
        self._put(P.cmd_beep(freq, ms))

    def vibrate(self, pattern: list[int]) -> None:
        # The firmware takes one pulse (and has no motor yet): send the longest.
        self._put(P.cmd_vibrate(max(pattern[0::2])))

    def set_player(self, player: int) -> None:
        self._put(P.cmd_set_player(player))

    def set_rotation(self, rotation: int) -> None:
        self._put(P.cmd_set_rotation(rotation))

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
        self._candidates: dict[str, tuple[Any, str, bool]] = {}
        self._scan_warning = WarningLimiter()
        self._bad_packet_log_at = float("-inf")

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

        def on_detect(device: Any, adv: Any) -> None:
            match = self._matches(device, adv)
            if match and device.address not in self._active:
                self._candidates[device.address] = (device, match[0], match[1])

        log.info("scanning for Regina controllers")
        try:
            while True:
                self._candidates.clear()
                try:
                    async with BleakScanner(detection_callback=on_detect):
                        await asyncio.sleep(3.0)
                except Exception as exc:  # noqa: BLE001 - adapter off / busy
                    self._scan_warning.warning(log, "scan failed: %s (is Bluetooth on?)", redact_devices(exc))
                    await asyncio.sleep(5.0)
                    continue
                for addr, (device, name, legacy) in list(self._candidates.items()):
                    if addr not in self._active:
                        await self._connect(device, name, legacy)
                await asyncio.sleep(2.0 if not self._active else 8.0)
        finally:
            clients = list(self._active.values())
            for close in list(self._close_connections.values()):
                close()
            await asyncio.gather(*(self._disconnect(client) for client in clients))

    async def _disconnect(self, client: Any) -> None:
        try:
            await asyncio.wait_for(client.disconnect(), DISCONNECT_TIMEOUT_S)
        except Exception:  # noqa: BLE001 - backend failure must not interrupt local cleanup
            log.warning("BLE disconnect failed; local connection state was cleared")

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
            if transport is not None:
                transport.close()
            if controller is not None:
                self.hub.detach(controller)

        def on_disconnect(_client: Any) -> None:
            log.info("Regina controller disconnected")
            close_connection()

        client = BleakClient(device, disconnected_callback=on_disconnect, timeout=15.0)
        self._active[addr] = client
        self._close_connections[addr] = close_connection
        try:
            log.info("connecting Regina controller")
            await client.connect()
            if closed:
                return
            if legacy:
                controller = await self._setup_legacy(client, addr, name)
                if closed:
                    self.hub.detach(controller)
                return
            transport = ReginaTransport(client)
            transport.set_rotation(self.screen_rotation)
            controller = self.hub.attach("regina", f"regina:{addr}", name, transport, rate_hint_hz=200.0, wrap_bits=32)
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

            await client.start_notify(P.IMU_CHAR_UUID, on_imu)
            await client.start_notify(P.INPUT_CHAR_UUID, on_input)
            await client.start_notify(P.STATUS_CHAR_UUID, on_status)
            on_status(None, await client.read_gatt_char(P.STATUS_CHAR_UUID))
            on_input(None, await client.read_gatt_char(P.INPUT_CHAR_UUID))
            log.info("controller %d ready (mtu %s)", c.id, client.mtu_size)
        except asyncio.CancelledError:
            close_connection()
            await self._disconnect(client)
            raise
        except Exception as exc:  # noqa: BLE001
            log.warning("Regina connection failed: %s", redact_devices(str(exc).replace(addr, "<device>")))
            close_connection()
            await self._disconnect(client)

    async def _setup_legacy(self, client: Any, addr: str, name: str) -> Controller:
        """Original Regina firmware: ~20 Hz float accel (g) + gyro (dps), no timestamps or downlink."""
        from ..controller import NullTransport

        controller = self.hub.attach("regina", f"regina:{addr}", name, NullTransport(), rate_hint_hz=20.0, wrap_bits=None)
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
            await client.start_notify(P.LEGACY_ACCEL_UUID, on_accel)
            await client.start_notify(P.LEGACY_GYRO_UUID, on_gyro)
            await client.start_notify(P.LEGACY_INPUT_UUID, on_input)
        except BaseException:
            # The caller only receives this controller after all subscriptions are ready.
            self.hub.detach(controller)
            raise
        log.info("controller %d ready (original firmware, ~20 Hz; flash firmware/ for 200 Hz)", c.id)
        return controller
