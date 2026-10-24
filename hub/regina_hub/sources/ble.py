"""Regina controllers over BLE (bleak). Scans, connects, auto-reconnects."""

from __future__ import annotations

import asyncio
import logging
import math
from collections.abc import Sequence
from typing import Any

from .. import protocol as P
from ..controller import Controller
from ..diagnostics import WarningLimiter, redact_devices
from ..frames import REGINA_DEFAULT_AXIS_MAP, make_remap
from ..hub import Hub

log = logging.getLogger("ble")

DEG2RAD = math.pi / 180.0
G = 9.80665


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
        self._candidates: dict[str, tuple[Any, str, bool]] = {}
        self._scan_warning = WarningLimiter()

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

    async def _connect(self, device: Any, name: str, legacy: bool = False) -> None:
        from bleak import BleakClient

        addr = device.address
        controller: Controller | None = None
        transport: ReginaTransport | None = None

        def on_disconnect(_client: Any) -> None:
            log.info("Regina controller disconnected")
            self._active.pop(addr, None)
            if transport is not None:
                transport.close()
            if controller is not None:
                self.hub.detach(controller)

        client = BleakClient(device, disconnected_callback=on_disconnect, timeout=15.0)
        self._active[addr] = client
        try:
            log.info("connecting Regina controller")
            await client.connect()
            if legacy:
                controller = await self._setup_legacy(client, addr, name)
                return
            transport = ReginaTransport(client)
            transport.set_rotation(self.screen_rotation)
            controller = self.hub.attach("regina", f"regina:{addr}", name, transport, rate_hint_hz=200.0, wrap_bits=32)
            controller.extra["mtu"] = client.mtu_size
            c = controller

            def on_imu(_char: Any, data: bytearray) -> None:
                try:
                    pkt = P.parse_imu(bytes(data))
                except ValueError as exc:
                    log.debug("bad imu packet: %s", exc)
                    return
                items = [
                    (
                        float(s.t_us),
                        self.remap((s.gyro_dps[0] * DEG2RAD, s.gyro_dps[1] * DEG2RAD, s.gyro_dps[2] * DEG2RAD)),
                        self.remap((s.accel_g[0] * G, s.accel_g[1] * G, s.accel_g[2] * G)),
                    )
                    for s in pkt.samples
                ]
                self.hub.on_imu(c, items, seq=pkt.seq)

            def on_input(_char: Any, data: bytearray) -> None:
                try:
                    pkt = P.parse_input(bytes(data))
                except (ValueError, Exception):  # noqa: BLE001
                    return
                self.hub.on_input(c, pkt.buttons, pkt.dial_small, pkt.dial_big)

            def on_status(_char: Any, data: bytearray) -> None:
                try:
                    st = P.parse_status(bytes(data))
                except (ValueError, Exception):  # noqa: BLE001
                    return
                self.hub.on_status(c, st.battery, st.charging, imu_ok=st.imu_ok, imu_irq=st.imu_irq, fw=f"{st.fw[0]}.{st.fw[1]}")

            await client.start_notify(P.IMU_CHAR_UUID, on_imu)
            await client.start_notify(P.INPUT_CHAR_UUID, on_input)
            await client.start_notify(P.STATUS_CHAR_UUID, on_status)
            on_status(None, await client.read_gatt_char(P.STATUS_CHAR_UUID))
            on_input(None, await client.read_gatt_char(P.INPUT_CHAR_UUID))
            log.info("controller %d ready (mtu %s)", c.id, client.mtu_size)
        except Exception as exc:  # noqa: BLE001
            log.warning("Regina connection failed: %s", redact_devices(str(exc).replace(addr, "<device>")))
            self._active.pop(addr, None)
            if transport is not None:
                transport.close()
            if controller is not None:
                self.hub.detach(controller)
            try:
                await client.disconnect()
            except Exception:  # noqa: BLE001
                pass

    async def _setup_legacy(self, client: Any, addr: str, name: str) -> Controller:
        """Original Regina firmware: ~20 Hz float accel (g) + gyro (dps), no timestamps or downlink."""
        import time

        from ..controller import NullTransport

        controller = self.hub.attach("regina", f"regina:{addr}", name, NullTransport(), rate_hint_hz=20.0, wrap_bits=None)
        controller.extra["fw"] = "legacy"
        c = controller
        last_accel: list[tuple[float, float, float] | None] = [None]

        def on_accel(_char: Any, data: bytearray) -> None:
            ax, ay, az = P.parse_legacy_vec3(bytes(data))
            last_accel[0] = (ax * G, ay * G, az * G)

        def on_gyro(_char: Any, data: bytearray) -> None:
            if last_accel[0] is None:
                return
            gx, gy, gz = P.parse_legacy_vec3(bytes(data))
            # No device clock: timestamp on arrival (BLE jitter goes straight into the integration).
            t_us = time.monotonic() * 1e6
            self.hub.on_imu(c, [(t_us, self.remap((gx * DEG2RAD, gy * DEG2RAD, gz * DEG2RAD)), self.remap(last_accel[0]))])

        def on_input(_char: Any, data: bytearray) -> None:
            try:
                pkt = P.parse_legacy_input(bytes(data))
            except Exception:  # noqa: BLE001
                return
            self.hub.on_input(c, pkt.buttons, pkt.dial_small, pkt.dial_big)

        await client.start_notify(P.LEGACY_ACCEL_UUID, on_accel)
        await client.start_notify(P.LEGACY_GYRO_UUID, on_gyro)
        await client.start_notify(P.LEGACY_INPUT_UUID, on_input)
        log.info("controller %d ready (original firmware, ~20 Hz; flash firmware/ for 200 Hz)", c.id)
        return controller
