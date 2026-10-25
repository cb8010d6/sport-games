"""A slow or failing ATT writer cannot lose the latest persistent controller state."""

import asyncio

import pytest

from regina_hub import protocol as P
from regina_hub.sources import ble


class FirmwareUi:
    """The firmware's UI_CLEAR resets UiModel, including the active toast deadline."""

    def __init__(self):
        self.persistent = P.UiState()
        self.has_content = False
        self.toast = None
        self.toast_until_ms = 0
        self.now_ms = 100

    def apply(self, packet):
        if packet[0] != P.OP_UI:
            return
        update = P.decode_ui_tlv(packet)
        if update.get("clear"):
            self.has_content = False
            self.toast = None
            self.toast_until_ms = 0
        self.persistent.apply(update)
        if "toast" in update:
            self.toast = update["toast"]["text"]
            self.toast_until_ms = self.now_ms + update["toast"]["ms"]
        # display_ui::apply_tlv sets has_content for any non-toast field, including clear.
        if any(key != "toast" for key in update):
            self.has_content = True


class FakeWriter:
    def __init__(self, mtu=23, *, blocked_first=False, failure=None, failed_attempts=()):
        self.mtu_size = mtu
        self.blocked_first = blocked_first
        self.failure = failure
        self.failed_attempts = set(failed_attempts)
        self.started = asyncio.Event()
        self.release = asyncio.Event()
        self.attempts = []
        self.written = []
        self.cancelled = 0
        self.ui = FirmwareUi()

    async def write_gatt_char(self, uuid, data, *, response):
        assert uuid == P.CMD_CHAR_UUID
        assert response is False
        assert len(data) <= self.mtu_size - 3
        self.attempts.append(bytes(data))
        self.started.set()
        try:
            if self.blocked_first and len(self.attempts) == 1:
                await self.release.wait()
            if len(self.attempts) in self.failed_attempts:
                if self.failure == "hang":
                    await asyncio.Event().wait()
                raise ConnectionError("fixture write failure")
        except asyncio.CancelledError:
            self.cancelled += 1
            raise
        self.written.append(bytes(data))
        self.ui.apply(bytes(data))


def applied_state(packets):
    ui = P.UiState()
    player = rotation = toast = None
    for packet in packets:
        if packet[0] == P.OP_UI:
            # Inspect the actual writes, not just the standalone serializer result.
            offset = 1
            while offset < len(packet):
                assert offset + 2 <= len(packet)
                offset += 2 + packet[offset + 1]
                assert offset <= len(packet)
            assert offset == len(packet)
            update = P.decode_ui_tlv(packet)
            ui.apply(update)
            if update.get("clear"):
                toast = None
            if "toast" in update:
                toast = update["toast"]
        elif packet[0] == P.OP_SET_PLAYER:
            player = packet[1]
        elif packet[0] == P.OP_SET_ROTATION:
            rotation = packet[1]
    return ui.snapshot(), player, rotation, toast


async def stop(transport):
    transport.close()
    await asyncio.gather(transport._task, return_exceptions=True)
    assert transport._task.done()
    assert transport._queue.empty()
    await asyncio.wait_for(transport._queue.join(), 1)


@pytest.mark.parametrize("mtu", [23, 247])
async def test_real_writes_fit_mtu_and_restore_every_oled_field(mtu):
    client = FakeWriter(mtu)
    transport = ble.ReginaTransport(client)
    try:
        transport.set_player(2)
        transport.set_rotation(3)
        transport.send_ui({
            "clear": True, "title": "LONG TITLE HERE", "main": "123456789012345",
            "sub": "SUBTITLE HERE", "bar": {"pct": 85, "label": "LONG POWER LABEL"},
            "legends": ["FIRST ACTION", "SECOND ACTION", "THIRD ACTION", "FOURTH ACTION"],
            "toast": {"ms": 850, "text": "LONG COMPLETION MESSAGE"},
        })
        await asyncio.wait_for(transport._queue.join(), 2)
        ui, player, rotation, toast = applied_state(client.written)
        assert (player, rotation) == (2, 3)
        assert ui == {
            "clear": True, "title": "LONG TITLE", "main": "1234567890", "sub": "SUBTITLE H",
            "bar": {"pct": 85, "label": "LONG POWER"},
            "legends": ["FIRST AC", "SECOND A", "THIRD AC", "FOURTH A"],
        }
        assert toast == {"ms": 850, "text": "LONG COMPLETION MESSAGE"[:min(20, mtu - 8)]}
    finally:
        await stop(transport)


async def test_saturated_feedback_queue_retains_player_rotation_and_complete_latest_ui(caplog):
    client = FakeWriter(blocked_first=True)
    transport = ble.ReginaTransport(client)
    try:
        transport.beep(900, 20)
        await asyncio.wait_for(client.started.wait(), 1)
        writer = transport._task
        transport.set_player(2)
        transport.set_rotation(0)
        transport.send_ui({"clear": True, "title": "KEEP TITLE", "main": "KEEP MAIN", "legends": ["GO", None, None, None]})
        transport.send_ui({"legends": [None, "BACK", "", "ZERO"]})
        for i in range(ble.MAX_PENDING_COMMANDS * 3):
            transport.send_ui({"bar": {"pct": i % 101, "label": "LATEST"}})
            transport.beep(1000 + i, 20)
            assert transport._queue.qsize() <= ble.MAX_PENDING_COMMANDS
        assert transport._task is writer
        client.release.set()
        await asyncio.wait_for(transport._queue.join(), 2)
        ui, player, rotation, _ = applied_state(client.written)
        assert (player, rotation) == (2, 0)
        assert ui == {
            "clear": True, "title": "KEEP TITLE", "main": "KEEP MAIN",
            "bar": {"pct": (ble.MAX_PENDING_COMMANDS * 3 - 1) % 101, "label": "LATEST"},
            "legends": ["GO", "BACK", "", "ZERO"],
        }
        assert sum("feedback queue full" in record.message for record in caplog.records) == 1
    finally:
        await stop(transport)


@pytest.mark.parametrize("failure", ["error", "hang"])
@pytest.mark.parametrize("failed_attempts", [(1, 2), (2, 3)])
async def test_failed_writes_retry_latest_complete_ui_and_rate_limit_diagnostics(monkeypatch, caplog, failure, failed_attempts):
    monkeypatch.setattr(ble, "GATT_TIMEOUT_S", 0.01)
    monkeypatch.setattr(ble, "WRITE_RETRY_S", 0.001)
    client = FakeWriter(failure=failure, failed_attempts=failed_attempts)
    transport = ble.ReginaTransport(client)
    try:
        transport.send_ui({"clear": True, "title": "KEEP", "main": "OLD", "legends": ["GO", None, None, None]})
        await asyncio.wait_for(client.started.wait(), 1)
        transport.send_ui({"main": "NEW", "bar": {"pct": 95, "label": "POWER"}, "legends": [None, "BACK", "", "ZERO"]})
        await asyncio.wait_for(transport._queue.join(), 2)
        ui, _, _, _ = applied_state(client.written)
        assert ui == {
            "clear": True, "title": "KEEP", "main": "NEW", "bar": {"pct": 95, "label": "POWER"},
            "legends": ["GO", "BACK", "", "ZERO"],
        }
        assert len(client.attempts) > 2
        assert sum("write failed or timed out" in record.message for record in caplog.records) == 1
        if failure == "hang":
            assert client.cancelled == 2
    finally:
        await stop(transport)


async def test_close_cancels_inflight_write_and_drains_pending_commands():
    client = FakeWriter(blocked_first=True)
    transport = ble.ReginaTransport(client)
    transport.beep(1000, 10)
    await asyncio.wait_for(client.started.wait(), 1)
    transport.set_player(3)
    transport.send_ui({"title": "PENDING"})
    await stop(transport)
    assert client.cancelled == 1
    attempts = len(client.attempts)
    transport.send_ui({"title": "AFTER CLOSE"})
    transport.set_player(4)
    transport.beep(2000, 20)
    await asyncio.sleep(0)
    assert len(client.attempts) == attempts
    assert transport._queue.empty()
    transport.close()


def clear_count(packets):
    return sum(bool(P.decode_ui_tlv(packet).get("clear")) for packet in packets if packet[0] == P.OP_UI)


async def test_toast_only_does_not_replace_the_firmware_default_page():
    client = FakeWriter()
    transport = ble.ReginaTransport(client)
    try:
        transport.send_ui({"toast": {"ms": 900, "text": "HIT"}})
        await asyncio.wait_for(transport._queue.join(), 1)
        assert client.ui.toast == "HIT" and client.ui.toast_until_ms == 1000
        assert not client.ui.has_content
        assert not client.ui.persistent.fields
        assert clear_count(client.written) == 0
    finally:
        await stop(transport)


@pytest.mark.parametrize("failure", ["error", "hang"])
async def test_toast_retry_also_preserves_the_firmware_default_page(monkeypatch, failure):
    monkeypatch.setattr(ble, "GATT_TIMEOUT_S", 0.01)
    monkeypatch.setattr(ble, "WRITE_RETRY_S", 0.001)
    client = FakeWriter(failure=failure, failed_attempts=(1,))
    transport = ble.ReginaTransport(client)
    try:
        transport.send_ui({"toast": {"ms": 900, "text": "HIT"}})
        await asyncio.wait_for(transport._queue.join(), 1)
        assert client.ui.toast == "HIT" and client.ui.toast_until_ms == 1000
        assert not client.ui.has_content and not client.ui.persistent.fields
        assert clear_count(client.written) == 0
    finally:
        await stop(transport)


async def test_normal_bar_update_does_not_cancel_an_active_toast():
    client = FakeWriter()
    transport = ble.ReginaTransport(client)
    try:
        transport.send_ui({"clear": True, "title": "GAME"})
        await asyncio.wait_for(transport._queue.join(), 1)
        transport.send_ui({"toast": {"ms": 900, "text": "HIT"}})
        await asyncio.wait_for(transport._queue.join(), 1)
        deadline = client.ui.toast_until_ms
        client.ui.now_ms += 100
        transport.send_ui({"bar": {"pct": 50, "label": "POWER"}})
        await asyncio.wait_for(transport._queue.join(), 1)
        assert client.ui.toast == "HIT" and client.ui.toast_until_ms == deadline
        assert client.ui.now_ms < deadline
        assert client.ui.persistent.fields["bar"] == {"pct": 50, "label": "POWER"}
        assert clear_count(client.written) == 1
    finally:
        await stop(transport)


async def test_coalesced_clear_is_applied_once_before_later_incremental_updates():
    client = FakeWriter(blocked_first=True)
    client.ui.persistent.apply({"title": "OLD", "legends": ["OLD", None, None, None]})
    transport = ble.ReginaTransport(client)
    try:
        transport.beep(1000, 10)
        await asyncio.wait_for(client.started.wait(), 1)
        transport.send_ui({"clear": True, "title": "NEW"})
        transport.send_ui({"bar": {"pct": 10, "label": "POWER"}})
        transport.send_ui({"main": "LATEST"})
        client.release.set()
        await asyncio.wait_for(transport._queue.join(), 1)
        assert client.ui.persistent.fields == {
            "title": "NEW", "main": "LATEST", "bar": {"pct": 10, "label": "POWER"},
        }
        assert clear_count(client.written) == 1
        transport.send_ui({"toast": {"ms": 900, "text": "HIT"}})
        await asyncio.wait_for(transport._queue.join(), 1)
        transport.send_ui({"sub": "SCORE"})
        await asyncio.wait_for(transport._queue.join(), 1)
        assert clear_count(client.written) == 1
        assert client.ui.toast == "HIT" and client.ui.toast_until_ms == 1000
    finally:
        await stop(transport)


@pytest.mark.parametrize("inflight_clear", [False, True])
async def test_new_clear_during_an_inflight_update_cannot_be_lost(inflight_clear):
    client = FakeWriter(blocked_first=True)
    transport = ble.ReginaTransport(client)
    try:
        transport.send_ui({"title": "OLD", "clear": inflight_clear})
        await asyncio.wait_for(client.started.wait(), 1)
        transport.send_ui({"clear": True, "main": "NEW"})
        transport.send_ui({"sub": "CURRENT"})
        client.release.set()
        await asyncio.wait_for(transport._queue.join(), 1)
        assert client.ui.persistent.fields == {"main": "NEW", "sub": "CURRENT"}
        assert clear_count(client.written) == 1 + int(inflight_clear)
    finally:
        await stop(transport)


async def test_partial_write_recovery_clears_once_then_preserves_new_toast(monkeypatch):
    monkeypatch.setattr(ble, "WRITE_RETRY_S", 0.001)
    client = FakeWriter(failed_attempts=(2,))
    transport = ble.ReginaTransport(client)
    try:
        transport.send_ui({"clear": True, "title": "TITLE", "main": "MAIN", "sub": "SUB",
                           "bar": {"pct": 25, "label": "POWER"}, "legends": ["GO", "BACK", "", "ZERO"]})
        await asyncio.wait_for(transport._queue.join(), 1)
        assert clear_count(client.written) == 2
        assert client.ui.persistent.fields == {
            "title": "TITLE", "main": "MAIN", "sub": "SUB", "bar": {"pct": 25, "label": "POWER"},
            "legends": ["GO", "BACK", "", "ZERO"],
        }
        transport.send_ui({"toast": {"ms": 900, "text": "HIT"}})
        await asyncio.wait_for(transport._queue.join(), 1)
        transport.send_ui({"bar": {"pct": 50, "label": "POWER"}})
        await asyncio.wait_for(transport._queue.join(), 1)
        assert clear_count(client.written) == 2
        assert client.ui.toast == "HIT" and client.ui.toast_until_ms == 1000
    finally:
        await stop(transport)
