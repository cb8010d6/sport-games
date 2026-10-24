"""Diagnostic output and recordings must not expose persistent device identities."""

import asyncio
import io
import json
import logging
import sys
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from regina_hub import diagnostics
from regina_hub.controller import NullTransport
from regina_hub.diagnostics import PrivateFormatter, WarningLimiter
from regina_hub.hub import Hub
from regina_hub.recorder import Recorder, replay
from regina_hub.sources import ble

ADDRESS = ":".join(f"{n:02X}" for n in range(10, 16))
PLATFORM_ID = "-".join(["a" * 8, "b" * 4, "c" * 4, "d" * 4, "e" * 12])


def test_formatter_redacts_interpolated_messages_and_tracebacks():
    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    handler.setFormatter(PrivateFormatter("%(message)s"))
    logger = logging.Logger("privacy-test", logging.DEBUG)
    logger.addHandler(handler)
    logger.debug("device %s %s %s", ADDRESS, ADDRESS.lower().replace(":", "-"), PLATFORM_ID)
    try:
        raise RuntimeError(ADDRESS)
    except RuntimeError:
        logger.exception("backend failure")
    text = stream.getvalue()
    assert "backend failure" in text and "RuntimeError: <device>" in text
    assert text.count("<device>") == 4
    assert ADDRESS not in text and PLATFORM_ID not in text


def test_warning_limiter_counts_suppressed_messages(caplog, monkeypatch):
    now = [0.0]
    monkeypatch.setattr(diagnostics, "time", SimpleNamespace(monotonic=lambda: now[0]))
    limiter = WarningLimiter()
    logger = logging.getLogger("warning-test")
    limiter.warning(logger, "scan failed: %s", "off")
    for _ in range(20):
        now[0] += 2
        limiter.warning(logger, "scan failed: %s", "off")
    assert len(caplog.records) == 1
    now[0] = 60
    limiter.warning(logger, "scan failed: %s", "off")
    assert len(caplog.records) == 2
    assert "21 occurrences" in caplog.messages[-1]


@pytest.mark.parametrize("legacy,failed", [(False, False), (True, False), (False, True)])
async def test_mock_ble_lifecycle_never_logs_address_or_name(caplog, monkeypatch, legacy, failed):
    caplog.set_level(logging.DEBUG)
    clients = []

    class Client:
        mtu_size = 185

        def __init__(self, device, disconnected_callback, timeout):
            self.disconnected = disconnected_callback
            clients.append(self)

        async def connect(self):
            if failed:
                raise RuntimeError(f"backend cannot connect {ADDRESS} / {PLATFORM_ID}")

        async def start_notify(self, *args):
            pass

        async def read_gatt_char(self, *args):
            return b""

        async def disconnect(self):
            self.disconnected(self)

        async def write_gatt_char(self, *args, **kwargs):
            pass

    monkeypatch.setitem(sys.modules, "bleak", SimpleNamespace(BleakClient=Client))
    hub = Hub()
    source = ble.ReginaBleSource(hub)
    try:
        await source._connect(SimpleNamespace(address=ADDRESS), "private-device-name-" + ADDRESS, legacy)
        if not failed:
            c = next(iter(hub.controllers.values()))
            assert c.key == f"regina:{ADDRESS}"  # Runtime identity/pairing is unchanged.
            clients[0].disconnected(clients[0])
            assert not c.connected
        assert "private-device-name" not in caplog.text
        assert ADDRESS not in caplog.text and PLATFORM_ID not in caplog.text
    finally:
        hub.close()
        await asyncio.sleep(0)


async def test_scan_failures_are_redacted_and_rate_limited(caplog, monkeypatch):
    class Scanner:
        def __init__(self, **kwargs):
            pass

        async def __aenter__(self):
            raise RuntimeError(f"adapter off {ADDRESS}")

        async def __aexit__(self, *args):
            pass

    calls = 0

    async def sleep(_seconds):
        nonlocal calls
        calls += 1
        if calls == 5:
            raise asyncio.CancelledError

    monkeypatch.setitem(sys.modules, "bleak", SimpleNamespace(BleakScanner=Scanner))
    monkeypatch.setattr(ble, "asyncio", SimpleNamespace(sleep=sleep, gather=asyncio.gather))
    monkeypatch.setattr(diagnostics, "time", SimpleNamespace(monotonic=lambda: 0))
    with pytest.raises(asyncio.CancelledError):
        await ble.ReginaBleSource(Hub()).run()
    assert calls == 5
    assert len(caplog.records) == 1 and "scan failed" in caplog.text
    assert ADDRESS not in caplog.text


async def test_command_queue_overflow_is_rate_limited(caplog):
    transport = ble.ReginaTransport(SimpleNamespace(write_gatt_char=AsyncMock()))
    try:
        for _ in range(1000):
            transport._put(b"fixture")
        assert len(caplog.records) == 1
        assert "command queue full" in caplog.text
    finally:
        transport.close()
        await asyncio.sleep(0)


async def test_anonymous_recording_reconnect_append_and_replay(tmp_path):
    path = tmp_path / "recording.jsonl"
    hub = Hub()
    try:
        rec = Recorder(path)
        first = hub.attach("regina", f"regina:{ADDRESS}", ADDRESS, NullTransport(), 200, 32)
        phone = hub.attach("phone", "phone:private-client-id", "private-client-id", NullTransport(), 60, None)
        rec.input(first, 3, 2, -1, (0.25, 0.5))
        rec.imu(first, [(1000, (1, 2, 3), (4, 5, 6))])
        rec.input(phone, 1, 0, 0, (0, 0))
        hub.detach(first)
        reconnect = hub.attach("regina", first.key, first.name, NullTransport(), 200, 32)
        rec.input(reconnect, 0, 0, 0, (0, 0))
        rec.close()
        other_session = Recorder(path)
        other_session.input(first, 0, 0, 0, (0, 0))
        other_session.close()
        text = path.read_text(encoding="utf-8")
        assert ADDRESS not in text and "private-client-id" not in text
        rows = [json.loads(line) for line in text.splitlines()]
        assert rows[0]["c"] == rows[1]["c"] == rows[3]["c"]
        assert rows[0]["c"] != rows[2]["c"] and rows[0]["c"] != rows[4]["c"]
        assert [r["n"] for r in rows] == ["regina-1", "regina-1", "phone-2", "regina-1", "regina-1"]
        hub.on_imu = lambda c, samples: received.append((c.id, samples))
        received = []
        await replay(hub, path, loop_forever=False, speed=1000)
        assert received[0][1] == [(1000, (1, 2, 3), (4, 5, 6))]
        virtual = [c for c in hub.controllers.values() if c.kind == "replay"]
        assert len(virtual) == 3 and all(not c.connected for c in virtual)
        assert virtual[1].buttons == 1
    finally:
        hub.close()


async def test_original_recording_format_still_replays(tmp_path):
    path = tmp_path / "old.jsonl"
    path.write_text(json.dumps({"k": "in", "c": f"regina:{ADDRESS}", "n": "old device", "h": 0,
                                "b": 3, "d": [2, -1], "an": [0.25, 0]}) + "\n", encoding="utf-8")
    hub = Hub()
    try:
        await replay(hub, path, loop_forever=False)
        c = next(iter(hub.controllers.values()))
        assert c.buttons == 3 and c.dial_small == 2 and c.analog == (0.25, 0)
        assert not c.connected
    finally:
        hub.close()
