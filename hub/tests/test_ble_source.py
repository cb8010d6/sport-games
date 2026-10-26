"""BLE scanning and other controllers keep working when one backend operation stalls."""

import asyncio
import contextlib
import json
import sys
from types import SimpleNamespace

import pytest

from regina_hub import protocol as P
from regina_hub.controller import NullTransport
from regina_hub.hub import Hub
from regina_hub.sources import ble


async def wait_for(predicate, timeout=1):
    async with asyncio.timeout(timeout):
        while not predicate():
            await asyncio.sleep(0.001)


def advertisement(address, name="Regina-Fixture", uuids=None):
    return (SimpleNamespace(address=address, name=name),
            SimpleNamespace(local_name=name, service_uuids=uuids or []))


class FakeClient:
    def __init__(self, device, disconnected_callback, timeout, *, block=None):
        self.device = device
        self.on_disconnect = disconnected_callback
        self.mtu_size = 247
        self.block = block
        self.callbacks = {}
        self.disconnected = False
        self.started = set()

    async def operation(self, name):
        self.started.add(name)
        if self.block == name:
            await asyncio.Event().wait()

    async def connect(self):
        await self.operation("connect")

    async def disconnect(self):
        self.disconnected = True
        self.on_disconnect(self)

    async def start_notify(self, uuid, callback):
        await self.operation("notify:" + uuid)
        self.callbacks[uuid] = callback

    async def read_gatt_char(self, uuid):
        await self.operation("read:" + uuid)
        if uuid == P.STATUS_CHAR_UUID:
            return P.build_status(80, False, True, True, (1, 0), 1)
        return P.build_input(0, 0, 0, 0)

    async def write_gatt_char(self, _uuid, _data, response):
        await self.operation("write")


class Backend:
    def __init__(self, monkeypatch, plan, blocks=None):
        self.rounds = 0
        self.clients = []
        self.plan = plan
        self.blocks = blocks or {}
        backend = self

        class Scanner:
            def __init__(self, detection_callback):
                self.detect = detection_callback

            async def __aenter__(self):
                index = backend.rounds
                backend.rounds += 1
                batch = backend.plan[min(index, len(backend.plan) - 1)]
                if isinstance(batch, Exception):
                    raise batch
                for device, adv in batch:
                    self.detect(device, adv)
                return self

            async def __aexit__(self, *_args):
                pass

        def client(*args, **kwargs):
            created = FakeClient(*args, **kwargs, block=self.blocks.get(args[0].address))
            self.clients.append(created)
            return created

        monkeypatch.setitem(sys.modules, "bleak", SimpleNamespace(BleakScanner=Scanner, BleakClient=client))
        # Advertisements arrive synchronously in __aenter__, so a real scan
        # timer only couples this fake to the independently shortened GATT budget.
        for name, value in {
            "SCAN_DURATION_S": 0, "SCAN_PAUSE_S": 0.005, "CONNECTED_SCAN_PAUSE_S": 0.005,
            "SCAN_RETRY_S": 0.005, "GATT_TIMEOUT_S": 0.05, "DISCONNECT_TIMEOUT_S": 0.01,
        }.items():
            monkeypatch.setattr(ble, name, value)


async def stop(task):
    task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await asyncio.wait_for(task, 1)


async def test_stalled_subscription_does_not_block_other_device_or_scanning(monkeypatch, caplog):
    first = [advertisement("blocked"), advertisement("healthy")]
    backend = Backend(monkeypatch, [first, [advertisement("healthy")]], {"blocked": "notify:" + P.IMU_CHAR_UUID})
    hub = Hub()
    source = ble.ReginaBleSource(hub)
    task = asyncio.create_task(source.run())
    try:
        await wait_for(lambda: "healthy" in source._connected)
        assert "blocked" in source._connecting
        await wait_for(lambda: backend.rounds >= 3)
        assert "blocked" in source._connecting
        await wait_for(lambda: "blocked" not in source._connecting)
        assert "blocked" not in source._active
        assert source._connected == {"healthy"}
        assert hub.ble_state == "connected"
        healthy = next(c for c in backend.clients if c.device.address == "healthy")
        assert not healthy.disconnected
        assert "connection setup failed or timed out" in caplog.text
    finally:
        await stop(task)
    assert not source._active and not source._connecting and hub.ble_state == "disabled"
    assert all(client.disconnected for client in backend.clients)


async def test_pending_connections_have_an_explicit_bound(monkeypatch):
    devices = [advertisement(f"fixture-{i}") for i in range(10)]
    backend = Backend(monkeypatch, [devices], {d.address: "connect" for d, _ in devices})
    monkeypatch.setattr(ble, "MAX_PENDING_CONNECTIONS", 2)
    monkeypatch.setattr(ble, "GATT_TIMEOUT_S", 0.5)
    source = ble.ReginaBleSource(Hub())
    task = asyncio.create_task(source.run())
    try:
        await wait_for(lambda: backend.rounds >= 4)
        assert len(source._connecting) == len(backend.clients) == 2
    finally:
        await stop(task)
    assert not source._connecting and not source._active


async def test_failed_devices_cannot_starve_a_waiting_healthy_controller(monkeypatch):
    devices = [advertisement("blocked-1"), advertisement("blocked-2"), advertisement("healthy")]
    backend = Backend(monkeypatch, [devices], {"blocked-1": "connect", "blocked-2": "connect"})
    monkeypatch.setattr(ble, "MAX_PENDING_CONNECTIONS", 2)
    # Both bad attempts finish before the next fixed-order advertisement batch.
    # Rebuilding the queue every scan would therefore select those two forever.
    monkeypatch.setattr(ble, "GATT_TIMEOUT_S", 0.005)
    monkeypatch.setattr(ble, "SCAN_PAUSE_S", 0.02)
    source = ble.ReginaBleSource(Hub())
    task = asyncio.create_task(source.run())
    try:
        await wait_for(lambda: "healthy" in source._connected)
        attempts = [client.device.address for client in backend.clients]
        assert attempts[:2] == ["blocked-1", "blocked-2"]
        assert attempts.count("blocked-1") == attempts.count("blocked-2") == 1
        assert attempts.count("healthy") == 1
        assert backend.rounds >= 2
        assert len(source._connecting) <= 2
    finally:
        await stop(task)


async def test_pending_candidate_memory_is_bounded_and_old_adverts_expire(monkeypatch):
    devices = [advertisement(f"fixture-{i}") for i in range(20)]
    backend = Backend(monkeypatch, [devices, []], {device.address: "connect" for device, _ in devices})
    monkeypatch.setattr(ble, "MAX_CANDIDATES", 3)
    monkeypatch.setattr(ble, "MAX_PENDING_CONNECTIONS", 1)
    monkeypatch.setattr(ble, "GATT_TIMEOUT_S", 0.5)
    monkeypatch.setattr(ble, "CANDIDATE_TTL_S", 0.025)
    source = ble.ReginaBleSource(Hub())
    task = asyncio.create_task(source.run())
    try:
        await wait_for(lambda: len(backend.clients) == 1)
        assert len(source._candidates) == 2
        assert len(source._candidates) <= ble.MAX_CANDIDATES
        await wait_for(lambda: backend.rounds >= 5 and not source._candidates)
        assert len(backend.clients) == 1
    finally:
        await stop(task)
    assert not source._candidates and not source._retry_after


@pytest.mark.parametrize("clock_resolution", [None, 0.03125], ids=["native-clock", "coarse-clock"])
async def test_failed_device_waits_for_backoff_then_recovers(monkeypatch, caplog, clock_resolution):
    if clock_resolution is not None:
        # Coalesce the scan sleep and its deadline in one loop iteration, as a
        # coarse Windows clock can do even while the fake scanner is healthy.
        monkeypatch.setattr(asyncio.get_running_loop(), "_clock_resolution", clock_resolution)
    backend = Backend(monkeypatch, [[advertisement("fixture")]], {"fixture": "connect"})
    monkeypatch.setattr(ble, "GATT_TIMEOUT_S", 0.01)
    monkeypatch.setattr(ble, "CONNECTION_RETRY_S", 0.08)
    source = ble.ReginaBleSource(Hub())
    task = asyncio.create_task(source.run())
    try:
        await wait_for(lambda: "fixture" in source._retry_after)
        assert len(backend.clients) == 1
        await asyncio.sleep(0.03)
        assert len(backend.clients) == 1
        backend.blocks.clear()
        await wait_for(lambda: "fixture" in source._connected)
        assert len(backend.clients) == 2
        assert "fixture" not in source._retry_after
        await backend.clients[-1].disconnect()
        await wait_for(lambda: "fixture" in source._connected)
        assert len(backend.clients) == 3
        assert "BLE scanning unavailable" not in caplog.text
    finally:
        await stop(task)


async def test_failed_device_backoff_memory_is_bounded(monkeypatch):
    devices = [advertisement(f"fixture-{i}") for i in range(12)]
    backend = Backend(monkeypatch, [[device] for device in devices],
                      {device.address: "connect" for device, _ in devices})
    monkeypatch.setattr(ble, "MAX_CANDIDATES", 3)
    monkeypatch.setattr(ble, "GATT_TIMEOUT_S", 0.004)
    source = ble.ReginaBleSource(Hub())
    task = asyncio.create_task(source.run())
    try:
        await wait_for(lambda: len(backend.clients) >= 10)
        assert len(source._retry_after) <= ble.MAX_CANDIDATES
        assert len(source._candidates) <= ble.MAX_CANDIDATES
    finally:
        await stop(task)
    assert not source._retry_after


async def test_scan_diagnostics_count_all_adverts_and_recover(monkeypatch, caplog):
    unrelated = [advertisement("unrelated", name="Different Device")]
    backend = Backend(monkeypatch, [[], [], [], [], [], [], unrelated, OSError("adapter"), OSError("adapter"), unrelated])
    monkeypatch.setattr(ble, "SCAN_PAUSE_S", 0.025)
    monkeypatch.setattr(ble, "SCAN_RETRY_S", 0.025)
    hub = Hub()
    source = ble.ReginaBleSource(hub)
    task = asyncio.create_task(source.run())
    try:
        await wait_for(lambda: hub.ble_state == "no_adverts")
        assert hub.roster()["ble_state"] == "no_adverts"
        await wait_for(lambda: backend.rounds >= 7 and hub.ble_state == "scanning")
        assert not backend.clients and source._empty_scans == 0
        await wait_for(lambda: hub.ble_state == "unavailable")
        await wait_for(lambda: backend.rounds >= 10 and hub.ble_state == "scanning")
        warnings = [r.message for r in caplog.records if r.name == "ble"]
        assert sum("No Bluetooth advertisements" in message for message in warnings) == 1
        assert sum("BLE scanning unavailable" in message for message in warnings) == 1
    finally:
        await stop(task)


@pytest.mark.parametrize("blocked", [
    "connect", "notify:" + P.IMU_CHAR_UUID, "notify:" + P.INPUT_CHAR_UUID,
    "notify:" + P.STATUS_CHAR_UUID, "read:" + P.STATUS_CHAR_UUID, "read:" + P.INPUT_CHAR_UUID,
    "notify:" + P.LEGACY_ACCEL_UUID, "notify:" + P.LEGACY_GYRO_UUID, "notify:" + P.LEGACY_INPUT_UUID,
])
async def test_each_setup_operation_times_out_and_same_controller_can_reconnect(monkeypatch, blocked):
    backend = Backend(monkeypatch, [[]], {"fixture": blocked})
    monkeypatch.setattr(ble, "GATT_TIMEOUT_S", 0.01)
    hub = Hub()
    source = ble.ReginaBleSource(hub)
    device, _ = advertisement("fixture")
    legacy = "notify:" + P.LEGACY_ACCEL_UUID == blocked or "notify:" + P.LEGACY_GYRO_UUID == blocked or "notify:" + P.LEGACY_INPUT_UUID == blocked
    await asyncio.wait_for(source._connect(device, "Regina-Fixture", legacy), 0.2)
    assert backend.clients[0].disconnected
    assert not source._active and not source._connected
    assert all(not c.connected for c in hub.controllers.values())
    backend.blocks.clear()
    await asyncio.wait_for(source._connect(device, "Regina-Fixture", legacy), 0.2)
    try:
        assert source._connected == {"fixture"}
        assert hub.controllers[1].connected and hub.controllers[1].player == 1
        assert len(hub.controllers) == 1
    finally:
        await backend.clients[-1].disconnect()
        await asyncio.sleep(0)


def test_matching_allowlist_and_duplicate_detach():
    hub = Hub()
    sent = []
    hub.game.send = sent.append
    source = ble.ReginaBleSource(hub, allow=["fixture-one"])
    device, adv = advertisement("fixture-one")
    assert source._matches(device, adv) == ("Regina-Fixture", False)
    other, other_adv = advertisement("fixture-two")
    assert source._matches(other, other_adv) is None
    service, service_adv = advertisement("fixture-one", name="", uuids=[P.SERVICE_UUID.upper()])
    assert source._matches(service, service_adv) is not None
    old, old_adv = advertisement("fixture-one", name=P.LEGACY_NAME)
    assert source._matches(old, old_adv)[1] is True
    c = hub.attach("regina", "fixture", "Regina-Fixture", NullTransport(), 200, 32)
    hub.detach(c)
    hub.detach(c)
    events = [json.loads(packet) for packet in sent if packet.startswith(b"{")]
    assert sum(event.get("name") == "disconnected" for event in events) == 1


def test_ble_state_changes_dirty_roster_without_changing_controller_schema():
    hub = Hub()
    assert hub.roster()["ble_state"] == "disabled"
    hub._roster_dirty = False
    hub.set_ble_state("scanning")
    assert hub._roster_dirty and hub.roster()["ble_state"] == "scanning"
    hub._roster_dirty = False
    hub.set_ble_state("scanning")
    assert not hub._roster_dirty
    with pytest.raises(ValueError):
        hub.set_ble_state("invalid")
