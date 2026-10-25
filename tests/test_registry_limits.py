"""Controller registry limits (#45 C): the registry must not grow without bound.

Covers id recycling in 1..255, eviction of long-disconnected controllers,
refusal when every slot is connected, the roster datagram size guard and the
WebSocket connection cap.
"""

import json
import socket
import time

import aiohttp

from regina_hub import hub as hub_mod
from regina_hub.controller import NullTransport
from regina_hub.hub import Hub
from regina_hub.sources import web as web_mod
from regina_hub.sources.web import WebSource


def _attach(hub: Hub, key: str):
    return hub.attach("phone", key, key, NullTransport(), rate_hint_hz=60.0, wrap_bits=None)


def test_registry_stays_bounded_over_300_connect_cycles():
    hub = Hub()
    last = None
    for i in range(300):
        last = _attach(hub, f"phone:client-{i}")
        assert last is not None
        hub.detach(last)
    assert len(hub.controllers) <= hub_mod.MAX_CONTROLLERS
    assert len(hub._ids_by_key) <= hub_mod.MAX_CONTROLLERS
    # A fresh controller can still attach, is assigned an in-range id and its
    # input still flows (packing must not raise).
    c = _attach(hub, "phone:fresh")
    assert c is not None and 1 <= c.id <= hub_mod.MAX_CONTROLLER_ID
    hub.on_input(c, 1, 0, 0)
    hub.on_imu(c, [(1000.0, (0.0, 0.0, 0.0), (0.0, 0.0, 9.81))])


def test_player_pref_cache_bounded_under_churn():
    hub = Hub()
    for i in range(hub_mod.MAX_PLAYER_PREFS + 200):
        c = _attach(hub, f"phone:churn-{i}")
        assert c is not None
        hub.detach(c)
    assert len(hub.controllers) <= hub_mod.MAX_CONTROLLERS
    assert len(hub._ids_by_key) <= hub_mod.MAX_CONTROLLERS
    assert len(hub._players_by_key) <= hub_mod.MAX_PLAYER_PREFS
    assert "phone:churn-0" not in hub._players_by_key  # least recently attached go first
    assert f"phone:churn-{hub_mod.MAX_PLAYER_PREFS + 199}" in hub._players_by_key


def test_player_pref_restores_player_number_within_window():
    hub = Hub()
    first = _attach(hub, "phone:first")
    regular = _attach(hub, "phone:regular")
    assert first is not None and regular is not None and regular.player != first.player
    hub.detach(regular)
    regular.disconnected_at = time.monotonic() - hub_mod.REGISTRY_IDLE_EVICT_S - 1.0
    for i in range(50):  # the registry forgets "regular"; the preference stays
        c = _attach(hub, f"phone:passer-{i}")
        assert c is not None
        hub.detach(c)
    assert "phone:regular" not in hub._ids_by_key
    again = _attach(hub, "phone:regular")
    assert again is not None and again.player == regular.player


def test_player_pref_pinned_while_key_in_registry():
    hub = Hub()
    resident = _attach(hub, "phone:resident")  # never detaches: oldest preference of all
    assert resident is not None
    for i in range(hub_mod.MAX_PLAYER_PREFS + 100):
        c = _attach(hub, f"phone:churn-{i}")
        assert c is not None
        hub.detach(c)
    assert hub._players_by_key.get("phone:resident") == resident.player
    assert len(hub._players_by_key) <= hub_mod.MAX_PLAYER_PREFS


def test_id_is_recycled_after_eviction():
    hub = Hub()
    a = _attach(hub, "phone:a")
    assert a is not None
    first_id = a.id
    hub.detach(a)
    a.disconnected_at = time.monotonic() - hub_mod.REGISTRY_IDLE_EVICT_S - 1.0
    b = _attach(hub, "phone:b")
    assert b is not None
    assert b.id == first_id  # smallest free id is reused
    assert "phone:a" not in hub._ids_by_key
    # ... but the evicted device's player assignment is remembered.
    assert hub._players_by_key.get("phone:a") == a.player


def test_connected_controllers_are_never_evicted_and_attach_is_refused_when_full():
    hub = Hub()
    kept = [_attach(hub, f"phone:keep-{i}") for i in range(hub_mod.MAX_CONTROLLERS)]
    assert all(c is not None for c in kept)
    assert _attach(hub, "phone:one-too-many") is None
    assert len(hub.controllers) == hub_mod.MAX_CONTROLLERS


def test_roster_datagram_stays_below_udp_limit():
    hub = Hub()
    for i in range(300):
        c = _attach(hub, f"phone:client-{i}")
        assert c is not None
        hub.detach(c)
    payload = json.dumps(hub.roster(), separators=(",", ":")).encode("utf-8")
    assert len(payload) < 65507


def test_oversized_roster_is_trimmed_to_connected_entries():
    hub = Hub()
    connected_ids = set()
    for i in range(hub_mod.MAX_CONTROLLERS):
        c = _attach(hub, f"phone:blob-{i}")
        assert c is not None
        if i % 2:
            c.extra["blob"] = "x" * 4000  # only disconnected entries are expendable
            hub.detach(c)
        else:
            connected_ids.add(c.id)
    payload = hub.roster()
    size = len(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    assert size < 65507
    assert {e["id"] for e in payload["controllers"]} == connected_ids


def test_packing_failure_detaches_instead_of_raising(monkeypatch):
    hub = Hub()
    c = _attach(hub, "phone:bad")
    assert c is not None

    original_build = hub_mod.P.build_game_input

    def boom(*args, **kwargs):
        raise ValueError("cannot pack")

    monkeypatch.setattr(hub_mod.P, "build_game_input", boom)
    hub.on_input(c, 1, 0, 0)  # must not raise
    assert c.pack_failed
    assert not c.connected
    hub.on_input(c, 1, 0, 0)  # and must stay quiet on later messages
    monkeypatch.setattr(hub_mod.P, "build_game_input", original_build)


def _free_port() -> int:
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


async def test_websocket_connection_cap():
    hub = Hub()
    source = WebSource(hub)
    port = _free_port()
    await source.start("127.0.0.1", port, None, None)
    sessions = []
    sockets = []
    try:
        for _ in range(web_mod.MAX_WS_CONNECTIONS):
            session = aiohttp.ClientSession()
            ws = await session.ws_connect(f"http://127.0.0.1:{port}/ws", origin=f"http://127.0.0.1:{port}")
            sessions.append(session)
            sockets.append(ws)
        extra = aiohttp.ClientSession()
        sessions.append(extra)
        refused = await extra.ws_connect(f"http://127.0.0.1:{port}/ws", origin=f"http://127.0.0.1:{port}")
        msg = await refused.receive(timeout=2)
        assert msg.type == aiohttp.WSMsgType.CLOSE and msg.data == 1013
    finally:
        for ws in sockets:
            await ws.close()
        for session in sessions:
            await session.close()
        await source.stop()
    assert source._ws_count == 0


async def test_hello_refused_gracefully_when_registry_full():
    hub = Hub()
    for i in range(hub_mod.MAX_CONTROLLERS):
        assert _attach(hub, f"phone:keep-{i}") is not None
    source = WebSource(hub)
    port = _free_port()
    await source.start("127.0.0.1", port, None, None)
    try:
        async with aiohttp.ClientSession() as session:
            async with session.ws_connect(f"http://127.0.0.1:{port}/ws", origin=f"http://127.0.0.1:{port}") as ws:
                await ws.send_json({"t": "hello", "kind": "phone", "name": "Late",
                                    "client_id": "late-device", "profile_name": "Late",
                                    "token": source.pairing_token})
                reply = await ws.receive_json(timeout=2)
                assert reply["t"] == "error"
    finally:
        await source.stop()
