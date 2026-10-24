"""Malformed BLE notifications do not escape callbacks or poison the next valid input."""

import asyncio
import json
import math
import struct
import sys
from types import SimpleNamespace

import pytest

from regina_hub import protocol as P
from regina_hub.hub import Hub
from regina_hub.sources import ble


class FakeClient:
    def __init__(self, device, disconnected_callback, timeout):
        self.device = device
        self.disconnected_callback = disconnected_callback
        self.callbacks = {}
        self.mtu_size = 247
        self.connected = False
        self.disconnect_error = False
        self.disconnect_hang = False
        self.block_notify = False
        self.notify_started = asyncio.Event()

    async def connect(self):
        self.connected = True

    async def disconnect(self):
        self.connected = False
        if self.disconnect_hang:
            await asyncio.Event().wait()
        if self.disconnect_error:
            raise RuntimeError("fixture backend failure")
        self.disconnected_callback(self)

    async def start_notify(self, uuid, callback):
        self.callbacks[uuid] = callback
        self.notify_started.set()
        if self.block_notify:
            await asyncio.Event().wait()

    async def read_gatt_char(self, uuid):
        if uuid == P.STATUS_CHAR_UUID:
            return P.build_status(80, False, True, True, (1, 0), 1)
        return P.build_input(0, 0, 0, 0)

    async def write_gatt_char(self, _uuid, _data, response):
        pass

    def notify(self, uuid, data):
        self.callbacks[uuid](None, bytearray(data))


@pytest.fixture
def fake_bleak(monkeypatch):
    clients = []

    def make_client(*args, **kwargs):
        client = FakeClient(*args, **kwargs)
        clients.append(client)
        return client

    scanning = asyncio.Event()

    class FakeScanner:
        def __init__(self, detection_callback):
            pass

        async def __aenter__(self):
            scanning.set()
            return self

        async def __aexit__(self, *_args):
            pass

    monkeypatch.setitem(sys.modules, "bleak", SimpleNamespace(BleakClient=make_client, BleakScanner=FakeScanner))
    return clients, scanning


def make_source():
    hub = Hub()
    sent = []
    hub.game.send = sent.append
    return ble.ReginaBleSource(hub), hub, sent


def fixture_device():
    return SimpleNamespace(address="fixture-regina", name="Regina-Fixture")


async def test_modern_callbacks_reject_short_packets_then_forward_valid_data(fake_bleak, caplog):
    source, hub, sent = make_source()
    await source._connect(fixture_device(), "Regina-Fixture")
    client = fake_bleak[0][0]
    controller = hub.controllers[1]
    sent.clear()
    try:
        for _ in range(20):
            for uuid in (P.IMU_CHAR_UUID, P.INPUT_CHAR_UUID, P.STATUS_CHAR_UUID):
                client.notify(uuid, b"\x01\x00\x01")
        assert controller.connected and controller.battery == 80
        assert sent == []
        warnings = [record.message for record in caplog.records if record.name == "ble"]
        assert warnings == ["discarded invalid IMU packet from controller 1"]

        client.notify(P.IMU_CHAR_UUID, P.build_imu(0, 0, [(5000, 0, 0, 4096, 0, 0, 0)] * 3))
        client.notify(P.INPUT_CHAR_UUID, P.build_input(P.BTN_A, -4, 8, 10000))
        client.notify(P.STATUS_CHAR_UUID, P.build_status(75, True, True, False, (2, 1), 1))
        assert any(packet[0] == P.MSG_SAMPLES for packet in sent)
        assert any(packet[0] == P.MSG_INPUT for packet in sent)
        assert (controller.buttons, controller.dial_small, controller.dial_big) == (P.BTN_A, -4, 8)
        assert controller.battery == 75 and controller.charging
    finally:
        await client.disconnect()
        await asyncio.sleep(0)


@pytest.mark.parametrize("bad", [math.nan, math.inf, -math.inf, 1e30, -1e30])
async def test_legacy_callbacks_drop_invalid_vectors_and_recover(fake_bleak, bad, monkeypatch):
    # Legacy arrival timestamps need to advance at the real 20 Hz cadence,
    # independently of platform clock resolution and callback execution speed.
    ticks = iter(range(1000))
    monkeypatch.setattr(ble, "time", SimpleNamespace(monotonic=lambda: 1000.0 + next(ticks) * 0.05))
    source, hub, sent = make_source()
    await source._connect(fixture_device(), "Regina-Fixture", legacy=True)
    client = fake_bleak[0][0]
    controller = hub.controllers[1]
    sent.clear()
    def vector(x, y, z):
        return struct.pack("<fff", x, y, z)

    try:
        client.notify(P.LEGACY_ACCEL_UUID, vector(0, 0, 1))
        client.notify(P.LEGACY_GYRO_UUID, b"bad")
        client.notify(P.LEGACY_GYRO_UUID, vector(bad, 0, 0))
        client.notify(P.LEGACY_INPUT_UUID, b"bad")
        client.notify(P.LEGACY_ACCEL_UUID, b"bad")
        client.notify(P.LEGACY_GYRO_UUID, vector(0, 0, 0))
        client.notify(P.LEGACY_ACCEL_UUID, vector(0, bad, 0))
        client.notify(P.LEGACY_GYRO_UUID, vector(0, 0, 0))
        assert controller.pipeline._last_t is None
        assert sent == []

        client.notify(P.LEGACY_ACCEL_UUID, vector(0, 0, 1))
        client.notify(P.LEGACY_GYRO_UUID, vector(0, 0, 0))
        client.notify(P.LEGACY_GYRO_UUID, vector(0, 0, 0))
        client.notify(P.LEGACY_INPUT_UUID, struct.pack("<????BBhh", True, False, False, False, 0, 0, 3, -7))
        assert controller.connected
        assert any(packet[0] == P.MSG_SAMPLES for packet in sent)
        assert (controller.buttons, controller.dial_small, controller.dial_big) == (P.BTN_A, 3, -7)
        assert all(math.isfinite(value) for value in controller.pipeline.orientation)
    finally:
        await client.disconnect()


@pytest.mark.parametrize("disconnect_mode", ["ok", "error", "hang"])
async def test_source_cancellation_clears_connections_even_if_backend_disconnect_fails(fake_bleak, monkeypatch, disconnect_mode):
    source, hub, sent = make_source()
    await source._connect(fixture_device(), "Regina-Fixture")
    client = fake_bleak[0][0]
    client.disconnect_error = disconnect_mode == "error"
    client.disconnect_hang = disconnect_mode == "hang"
    monkeypatch.setattr(ble, "DISCONNECT_TIMEOUT_S", 0.01)
    controller = hub.controllers[1]
    task = asyncio.create_task(source.run())
    await asyncio.wait_for(fake_bleak[1].wait(), 1)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await asyncio.wait_for(task, 1)
    await asyncio.sleep(0)
    assert not source._active and not source._close_connections
    assert not controller.connected and controller.transport._task.done()
    disconnected = [json.loads(packet) for packet in sent if packet.startswith(b"{")
                    and json.loads(packet).get("name") == "disconnected"]
    assert len(disconnected) == 1


@pytest.mark.parametrize("legacy", [False, True])
async def test_connection_cancellation_during_subscription_detaches_controller(fake_bleak, legacy):
    source, hub, _sent = make_source()
    original_client = sys.modules["bleak"].BleakClient

    def blocked_client(*args, **kwargs):
        new_client = original_client(*args, **kwargs)
        new_client.block_notify = True
        return new_client

    sys.modules["bleak"].BleakClient = blocked_client
    connect = asyncio.create_task(source._connect(fixture_device(), "Regina-Fixture", legacy=legacy))
    await asyncio.sleep(0)
    client = fake_bleak[0][-1]
    await asyncio.wait_for(client.notify_started.wait(), 1)
    connect.cancel()
    with pytest.raises(asyncio.CancelledError):
        await connect
    await asyncio.sleep(0)
    assert not source._active and not source._close_connections
    assert not hub.controllers[1].connected and not client.connected
