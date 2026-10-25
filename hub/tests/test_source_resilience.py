"""Optional sources cannot take down the real WebSocket/UDP bridge."""

import asyncio
import contextlib
import json
import socket

import aiohttp
import pytest

from regina_hub import __main__ as entry
from regina_hub import protocol as P
from regina_hub.hub import Hub
from regina_hub.sources.ble import ReginaBleSource
from regina_hub.sources.web import WebSource


async def _wait_for(predicate):
    async with asyncio.timeout(3):
        while not predicate():
            await asyncio.sleep(0.01)


def _capture_runtime(monkeypatch):
    hubs, sources = [], []

    def make_hub(**kwargs):
        hub = Hub(**kwargs)
        hubs.append(hub)
        return hub

    def make_web(*args, **kwargs):
        source = WebSource(*args, **kwargs)
        sources.append(source)
        return source

    monkeypatch.setattr(entry, "Hub", make_hub)
    monkeypatch.setattr(entry, "WebSource", make_web)
    return hubs, sources


async def test_source_failures_leave_web_and_game_running(tmp_path, monkeypatch, caplog):
    hubs, sources = _capture_runtime(monkeypatch)

    async def missing_ble(_self):
        raise ImportError("test dependency unavailable")

    monkeypatch.setattr(ReginaBleSource, "run", missing_ble)
    recording = tmp_path / "broken.jsonl"
    recording.write_text("\n".join(json.dumps(line) for line in [
        {"k": "in", "c": "fixture", "h": 0, "b": 0, "d": [0, 0], "an": [0, 0]},
        {"k": "in", "c": "fixture", "h": 0, "b": 0, "d": {}},
    ]), encoding="utf-8")

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as game:
        game.bind(("127.0.0.1", 0))
        game.setblocking(False)
        options = entry.parse_args([
            "--config", str(tmp_path / "unused.json"), "--no-https", "--hub-port", "0",
            "--http-port", "0", "--game-port", str(game.getsockname()[1]), "--replay", str(recording),
        ])
        task = asyncio.create_task(entry.amain(options))
        try:
            await _wait_for(lambda: "BLE source disabled" in caplog.text and "replay source stopped" in caplog.text)
            assert not task.done()
            hub, source = hubs[0], sources[0]
            assert all(not c.connected for c in hub.controllers.values() if c.kind == "replay")
            port = source._runner.addresses[0][1]
            async with aiohttp.ClientSession() as session:
                async with session.ws_connect(f"http://127.0.0.1:{port}/ws", origin=f"http://127.0.0.1:{port}") as ws:
                    await ws.send_json({"t": "hello", "kind": "sim", "client_id": "source-fixture", "token": source.pairing_token})
                    welcome = await ws.receive_json(timeout=2)
                    assert welcome["t"] == "welcome" and welcome["player"] == 1
                    await ws.send_json({"t": "in", "b": 1, "d": [2, -1], "an": [0.25, 0]})
                    async with asyncio.timeout(3):
                        while True:
                            packet = await asyncio.get_running_loop().sock_recv(game, 65536)
                            if packet[:1] == bytes([P.MSG_INPUT]) and packet[2] == welcome["id"]:
                                assert packet == P.build_game_input(welcome["id"], 1, 2, -1, 0.25, 0)
                                break

                    # A malformed game UI command also leaves the reverse path available.
                    hub_addr = hub.game.sock.getsockname()
                    for ui in ({"bar": 5}, {"title": "AFTER ERROR"}):
                        game.sendto(json.dumps({"cmd": "ui", "ui": ui}).encode(), hub_addr)
                    async with asyncio.timeout(3):
                        while True:
                            reply = await ws.receive_json()
                            if reply.get("t") == "ui" and reply.get("title") == "AFTER ERROR":
                                break
        finally:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
        assert not hubs[0].game._thread.is_alive()


async def test_transient_source_failure_retries_and_cancels_cleanly(monkeypatch, caplog):
    monkeypatch.setattr(entry, "SOURCE_RETRY_INITIAL_S", 0.01)
    started = asyncio.Event()
    stopped = asyncio.Event()
    calls = 0

    async def source():
        nonlocal calls
        calls += 1
        if calls == 1:
            raise RuntimeError("test source failure")
        started.set()
        try:
            await asyncio.Event().wait()
        finally:
            stopped.set()

    task = asyncio.create_task(entry._run_optional_source("test", source, retry=True))
    await asyncio.wait_for(started.wait(), 2)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert calls == 2 and stopped.is_set()
    assert "retrying" in caplog.text


async def test_core_failure_still_propagates_and_closes_runtime(tmp_path, monkeypatch):
    hubs, _ = _capture_runtime(monkeypatch)

    async def failed_core(_self):
        raise RuntimeError("core failed")

    monkeypatch.setattr(Hub, "run_forever", failed_core)
    options = entry.parse_args([
        "--config", str(tmp_path / "unused.json"), "--no-https", "--no-ble",
        "--hub-port", "0", "--http-port", "0",
    ])
    with pytest.raises(RuntimeError, match="core failed"):
        await asyncio.wait_for(entry.amain(options), 3)
    assert not hubs[0].game._thread.is_alive()
