"""Phone nicknames survive reconnects and reach the roster without changing device identity."""

import socket

import aiohttp
import pytest

from regina_hub.hub import Hub
from regina_hub.sources.web import WebSource, clean_profile_name


@pytest.mark.parametrize("value, expected", [
    (None, ""), (12, ""), ("  Example\nPlayer\x00  ", "ExamplePlayer"),
    ("x" * 100, "x" * 20), ("[b]Example", "[b]Example"),
])
def test_clean_profile_name(value, expected):
    # Rich text is escaped at the game UI boundary, not modified in storage.
    assert clean_profile_name(value) == expected


async def test_phone_profile_roster_and_reconnect():
    hub = Hub()
    source = WebSource(hub)
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    await source.start("127.0.0.1", port, None, None)
    try:
        async with aiohttp.ClientSession() as session:
            for nickname in ("Example One", "Example Two"):
                async with session.ws_connect(f"http://127.0.0.1:{port}/ws", origin=f"http://127.0.0.1:{port}") as ws:
                    await ws.send_json({"t": "hello", "kind": "phone", "name": "Example Device", "token": source.pairing_token,
                                        "client_id": "example-test-device", "profile_name": nickname})
                    welcome = await ws.receive_json(timeout=2)
                    assert welcome["t"] == "welcome"
                    entry = hub.roster()["controllers"][0]
                    assert entry["name"] == "Example Device"
                    assert entry["profile_name"] == nickname
                    assert entry["player"] == 1
                    await ws.send_json({"t": "profile", "name": "  Example Updated\n  "})
                    while True:
                        reply = await ws.receive_json(timeout=2)
                        if reply["t"] == "profile":
                            break
                    assert reply["name"] == "Example Updated"
                    assert hub.roster()["controllers"][0]["profile_name"] == "Example Updated"
    finally:
        await source.stop()
