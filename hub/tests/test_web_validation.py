"""Malformed WebSocket input is discarded without losing a usable controller connection."""

import asyncio
import json
import struct

import aiohttp
import pytest
from aiohttp.test_utils import TestServer

from regina_hub import protocol as P
from regina_hub.hub import Hub
from regina_hub.sources.web import MAX_PENDING_WS_MESSAGES, WebSource, WsTransport


def sample(timestamp=1000.0, gyro=0.0, accel=9.80665):
    return [timestamp, 0.0, gyro, 0.0, 0.0, accel, 0.0]


async def sync_socket(ws, marker):
    await ws.send_json({"t": "ping", "c": marker})
    while True:
        reply = await ws.receive_json(timeout=2)
        if reply.get("t") == "pong" and reply.get("c") == marker:
            return


async def test_malformed_messages_preserve_connection_and_game_forwarding():
    hub = Hub()
    source = WebSource(hub)
    datagrams = []
    hub.game.send = datagrams.append
    async with TestServer(source.app) as server, aiohttp.ClientSession() as session:
        async with session.ws_connect(server.make_url("/ws"), origin=str(server.make_url("/" )).rstrip("/")) as ws:
            await ws.send_json({"t": "hello", "kind": "sim", "client_id": "validation", "token": source.pairing_token})
            welcome = await ws.receive_json(timeout=2)
            assert welcome["t"] == "welcome"
            controller = hub.controllers[welcome["id"]]
            malformed = [
                {"t": "in", "d": {}},
                {"t": "in", "d": {"0": 1, "1": 2}},
                {"t": "in", "d": [float("inf"), 0]},
                {"t": "in", "d": [0]},
                {"t": "in", "d": [1.5, 0]},
                {"t": "in", "d": [-32769, 0]},
                {"t": "in", "d": [32768, 0]},
                {"t": "in", "b": 256},
                {"t": "in", "b": -1},
                {"t": "in", "b": True},
                {"t": "in", "b": "1"},
                {"t": "in", "an": {}},
                {"t": "in", "an": [float("nan"), 0]},
                {"t": "in", "an": [float("inf"), 0]},
                {"t": "in", "an": [1e200, 0]},
                {"t": "in", "an": [2, 0]},
                {"t": "m", "s": "invalid"},
                {"t": "m", "s": {"0": sample()}},
                {"t": "m", "s": [sample(gyro=1e200)]},
                {"t": "m", "s": [sample(accel=1e200)]},
                {"t": "m", "s": [sample(gyro=35.01)]},
                {"t": "m", "s": [sample(accel=160.01)]},
                {"t": "m", "s": [sample(timestamp=float("inf"))]},
                {"t": "m", "s": [sample(timestamp=1e200)]},
                {"t": "m", "s": [sample(timestamp=-1)]},
                {"t": "m", "s": [sample(timestamp=True)]},
                {"t": "m", "s": [[1000, 0, 0]]},
                {"t": "m", "s": [sample(gyro=10 ** 1000)]},
            ]
            for message in malformed:
                await ws.send_json(message)
            # json.loads can also reject a valid JSON integer exceeding Python's digit limit.
            await ws.send_str('{"t":"in","b":' + "1" * 5000 + "}")
            await ws.send_str("[" * 2000 + "0" + "]" * 2000)
            await sync_socket(ws, "after-invalid")
            assert controller.buttons == 0
            assert controller.pipeline._last_t is None
            assert not any(data[:1] in (bytes([P.MSG_INPUT]), bytes([P.MSG_SAMPLES])) for data in datagrams)

            await ws.send_json({"t": "m", "frame": "canonical", "s": [sample(1000), sample(1010)]})
            await ws.send_json({"t": "in", "b": 255, "d": [-32768, 32767], "an": [-1, 1]})
            await sync_socket(ws, "after-valid")
            samples = [data for data in datagrams if data[0] == P.MSG_SAMPLES]
            inputs = [data for data in datagrams if data[0] == P.MSG_INPUT]
            assert len(P.parse_game_samples(samples[-1])[1]) == 1
            assert struct.unpack("<BBBBhhff", inputs[-1]) == (P.MSG_INPUT, P.GAME_PROTO_VERSION, controller.id, 255, -32768, 32767, -1, 1)
            assert controller.connected


async def test_timestamp_spikes_do_not_poison_following_samples():
    hub = Hub()
    source = WebSource(hub)
    datagrams = []
    hub.game.send = datagrams.append
    async with TestServer(source.app) as server, aiohttp.ClientSession() as session:
        async with session.ws_connect(server.make_url("/ws"), origin=str(server.make_url("/" )).rstrip("/")) as ws:
            await ws.send_json({"t": "hello", "kind": "sim", "client_id": "clock", "token": source.pairing_token})
            welcome = await ws.receive_json(timeout=2)
            controller = hub.controllers[welcome["id"]]
            await ws.send_json({"t": "m", "frame": "canonical", "s": [
                sample(1000), sample(1010), sample(1010), sample(990),
                sample(10 ** 12), sample(1010.00000001), sample(1020), sample(1030),
            ]})
            await sync_socket(ws, "clock-checked")
            samples = [data for data in datagrams if data[0] == P.MSG_SAMPLES]
            assert sum(len(P.parse_game_samples(data)[1]) for data in samples) == 3
            assert controller.pipeline._last_t == 1.03
            assert controller.connected


class SlowWebSocket:
    closed = False

    def __init__(self):
        self.started = asyncio.Event()
        self.release = asyncio.Event()
        self.sent = []
        self.cancelled = False

    async def send_str(self, text):
        self.started.set()
        try:
            await self.release.wait()
        except asyncio.CancelledError:
            self.cancelled = True
            raise
        self.sent.append(json.loads(text))


async def test_slow_websocket_has_one_sender_and_bounded_latest_feedback():
    ws = SlowWebSocket()
    transport = WsTransport(ws)
    transport.send_ui({"main": "first"})
    await asyncio.wait_for(ws.started.wait(), timeout=2)
    sender = transport._sender
    for i in range(MAX_PENDING_WS_MESSAGES * 3):
        transport.beep(i, 20)
    assert transport._sender is sender
    assert transport._pending.qsize() == MAX_PENDING_WS_MESSAGES
    ws.release.set()
    await asyncio.wait_for(transport._pending.join(), timeout=2)
    assert ws.sent[0]["main"] == "first"
    assert [message["freq"] for message in ws.sent[1:]] == list(
        range(MAX_PENDING_WS_MESSAGES * 2, MAX_PENDING_WS_MESSAGES * 3)
    )
    await transport.close()
    assert sender.done()
    transport.send_ui({"main": "after-close"})
    assert transport._pending.empty()


async def test_slow_websocket_preserves_player_and_incremental_ui_state():
    ws = SlowWebSocket()
    transport = WsTransport(ws)
    transport.beep(1000, 20)
    await asyncio.wait_for(ws.started.wait(), timeout=2)
    transport.set_player(2)
    transport.send_ui({"title": "ROUND", "main": "READY", "legends": ["GO", "BACK", None, None]})
    transport.send_ui({"legends": [None, None, "MENU", None]})
    for i in range(MAX_PENDING_WS_MESSAGES * 3):
        transport.send_ui({"bar": {"pct": i, "label": "POWER"}})
        transport.beep(2000 + i, 20)
    assert transport._pending.qsize() <= MAX_PENDING_WS_MESSAGES
    ws.release.set()
    await asyncio.wait_for(transport._pending.join(), timeout=2)
    assert [message["player"] for message in ws.sent if message["t"] == "player"] == [2]
    ui = [message for message in ws.sent if message["t"] == "ui"][-1]
    assert ui == {"t": "ui", "clear": True, "title": "ROUND", "main": "READY",
                  "legends": ["GO", "BACK", "MENU", None], "bar": {"pct": 95, "label": "POWER"}}
    await transport.close()


async def test_pending_ui_clear_and_player_reassignment_replace_obsolete_state():
    ws = SlowWebSocket()
    transport = WsTransport(ws)
    transport.beep(1000, 20)
    await asyncio.wait_for(ws.started.wait(), timeout=2)
    transport.set_player(2)
    transport.send_ui({"title": "OLD", "legends": ["OLD", None, None, None]})
    transport.set_player(3)
    transport.send_ui({"clear": True, "title": "NEW"})
    ws.release.set()
    await asyncio.wait_for(transport._pending.join(), timeout=2)
    assert ws.sent[1:] == [{"t": "player", "player": 3}, {"t": "ui", "clear": True, "title": "NEW"}]
    await transport.close()


async def test_transport_close_cancels_blocked_send_and_releases_queue():
    ws = SlowWebSocket()
    transport = WsTransport(ws)
    transport.send_ui({"main": "blocked"})
    await asyncio.wait_for(ws.started.wait(), timeout=2)
    transport.send_ui({"main": "pending"})
    await asyncio.wait_for(transport.close(), timeout=2)
    assert ws.cancelled
    assert transport._sender.done()
    assert transport._pending.empty()
    await transport.close()


@pytest.mark.parametrize("failure", [ConnectionResetError, RuntimeError])
async def test_transport_observes_send_failure(failure):
    class FailedWebSocket:
        closed = False

        async def send_str(self, _text):
            raise failure("closed transport")

    transport = WsTransport(FailedWebSocket())
    transport.beep(1000, 20)
    await asyncio.wait_for(transport._pending.join(), timeout=2)
    assert transport._sender.done()
    assert transport._sender.exception() is None
    await transport.close()
