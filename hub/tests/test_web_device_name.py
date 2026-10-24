"""Device names from the WebSocket hello are sanitized before they reach the roster (#50).

The roster name becomes the game's display_name, so control characters and
newlines must never survive; rich-text markup is left in storage and escaped
at the game UI boundary instead (see RSProfiles.bbcode).
"""

import socket

import aiohttp

from regina_hub.hub import Hub
from regina_hub.sources.web import WebSource, clean_profile_name


def test_clean_profile_name_limit():
    assert clean_profile_name("x" * 100) == "x" * 20
    assert clean_profile_name("x" * 100, limit=32) == "x" * 32
    assert clean_profile_name("a\nb\x00c") == "abc"


async def _attach_name(name):
    hub = Hub()
    source = WebSource(hub)
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    await source.start("127.0.0.1", port, None, None)
    try:
        async with aiohttp.ClientSession() as session:
            async with session.ws_connect(f"http://127.0.0.1:{port}/ws") as ws:
                await ws.send_json({"t": "hello", "kind": "phone", "name": name,
                                    "client_id": "device-name-test", "profile_name": "Player"})
                welcome = await ws.receive_json(timeout=2)
                assert welcome["t"] == "welcome"
                return hub.roster()["controllers"][0]["name"]
    finally:
        await source.stop()


async def test_device_name_control_characters_stripped():
    name = await _attach_name("Evil\n[b]Phone\x00\r\n")
    assert name == "Evil[b]Phone"
    assert "\n" not in name and "\x00" not in name


async def test_device_name_truncated_to_32():
    name = await _attach_name("N" * 100)
    assert name == "N" * 32


async def test_device_name_blank_falls_back_to_kind():
    name = await _attach_name("\n\x00 ")
    assert name == "phone"
