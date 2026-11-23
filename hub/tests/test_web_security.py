"""Pairing credentials and loopback administration are enforced on real HTTP/WS listeners."""

import asyncio
import contextlib
import json
import socket
import ssl

import aiohttp
import pytest
from aiohttp import WSMsgType
from aiohttp.test_utils import TestServer

from regina_hub import __main__ as entry
from regina_hub.hub import Hub
from regina_hub.netutil import ensure_cert, ssl_context
from regina_hub.sources.web import WebSource


def origin(server):
    return str(server.make_url("/")).rstrip("/")


async def hello(session, server, source, **fields):
    ws = await session.ws_connect(server.make_url("/ws"), origin=origin(server))
    await ws.send_json({"t": "hello", "kind": "phone", "client_id": "security-fixture",
                        "token": source.pairing_token, **fields})
    return ws


@pytest.mark.parametrize("bad_token", [None, "wrong", "é", {}, 0, True])
async def test_bad_pairing_hello_never_allocates_and_valid_reconnect_works(bad_token, caplog):
    hub = Hub()
    source = WebSource(hub)
    async with TestServer(source.app) as server, aiohttp.ClientSession() as session:
        async with session.ws_connect(server.make_url("/ws"), origin=origin(server)) as ws:
            message = {"t": "hello", "kind": "phone", "client_id": "security-fixture"}
            if bad_token is not None:
                message["token"] = bad_token
            await ws.send_json(message)
            response = await ws.receive(timeout=2)
            assert response.type == WSMsgType.CLOSE and response.data == 1008
        assert hub.roster()["controllers"] == [] and hub._next_id == 1

        async with await hello(session, server, source) as ws:
            welcome = await ws.receive_json(timeout=2)
            assert welcome["t"] == "welcome" and welcome["id"] == 1
        # A client_id remembers a player, not proof of pairing.
        async with session.ws_connect(server.make_url("/ws"), origin=origin(server)) as ws:
            await ws.send_json({"t": "hello", "kind": "phone", "client_id": "security-fixture"})
            assert (await ws.receive(timeout=2)).data == 1008
        async with await hello(session, server, source) as ws:
            welcome = await ws.receive_json(timeout=2)
            assert welcome["id"] == 1 and welcome["player"] == 1
    assert source.pairing_token not in caplog.text


@pytest.mark.parametrize("header", [None, "null", "https://example.invalid", "http://127.0.0.1:1",
                                   "http://127.0.0.1:2/path", "http://user@127.0.0.1:3"])
async def test_ws_requires_one_matching_origin_before_upgrade(header):
    source = WebSource(Hub())
    async with TestServer(source.app) as server, aiohttp.ClientSession() as session:
        kwargs = {} if header is None else {"origin": header}
        with pytest.raises(aiohttp.WSServerHandshakeError) as caught:
            await session.ws_connect(server.make_url("/ws"), **kwargs)
        assert caught.value.status == 403
        assert not source.hub.controllers


async def test_duplicate_origin_and_rebinding_host_are_rejected():
    source = WebSource(Hub())
    async with TestServer(source.app) as server, aiohttp.ClientSession() as session:
        with pytest.raises(aiohttp.WSServerHandshakeError) as caught:
            await session.ws_connect(server.make_url("/ws"), headers=[("Origin", origin(server)), ("Origin", origin(server))])
        assert caught.value.status == 403
        hostile = f"rebound.example.invalid:{server.port}"
        for path in ("/sim", "/api/status", "/api/qr", "/api/pairing"):
            async with session.get(server.make_url(path), headers={"Host": hostile}) as response:
                assert response.status == 403
                assert source.pairing_token not in await response.text()
        with pytest.raises(aiohttp.WSServerHandshakeError) as caught:
            await session.ws_connect(server.make_url("/ws"), headers={"Host": hostile, "Origin": f"http://{hostile}"})
        assert caught.value.status == 403


async def test_loopback_bootstrap_is_same_origin_and_not_cacheable():
    source = WebSource(Hub())
    async with TestServer(source.app) as server, aiohttp.ClientSession() as session:
        async with session.get(server.make_url("/api/pairing")) as response:
            assert response.status == 200
            assert await response.json() == {"token": source.pairing_token}
            assert response.headers["Cache-Control"] == "no-store"
            assert response.headers["X-Content-Type-Options"] == "nosniff"
            assert "Access-Control-Allow-Origin" not in response.headers
        async with session.get(server.make_url("/api/pairing"), headers={"Origin": "https://example.invalid"}) as response:
            assert response.status == 403
        async with session.get(server.make_url("/api/pairing"), headers={"Host": f"localhost:{server.port}",
                                                                       "Origin": f"http://localhost:{server.port}"}) as response:
            assert response.status == 200
        with pytest.raises(aiohttp.WSServerHandshakeError) as caught:
            await session.ws_connect(server.make_url("/ws"), origin=origin(server), headers={"Host": f"localhost:{server.port}"})
        assert caught.value.status == 403


async def test_https_listener_exposes_only_phone_static_and_authenticated_ws(tmp_path):
    source = WebSource(Hub())
    cert, key = ensure_cert(tmp_path / "certs", ["127.0.0.1"])
    trust = ssl.create_default_context(cafile=str(cert))
    server = TestServer(source.phone_app)
    await server.start_server(ssl=ssl_context(cert, key))
    try:
        async with aiohttp.ClientSession(connector=aiohttp.TCPConnector(ssl=trust)) as session:
            for path in ("/sim", "/api/status", "/api/qr", "/api/pairing"):
                async with session.get(server.make_url(path)) as response:
                    assert response.status == 404
            for path in ("/", "/static/common.js"):
                async with session.get(server.make_url(path)) as response:
                    assert response.status == 200
                    assert source.pairing_token not in await response.text()
            async with await hello(session, server, source) as ws:
                assert (await ws.receive_json(timeout=2))["t"] == "welcome"
    finally:
        await server.close()


def test_pairing_token_rotates_between_hub_lifetimes():
    first, second = WebSource(Hub()), WebSource(Hub())
    assert len(first.pairing_token) >= 43
    assert first.pairing_token != second.pairing_token


async def test_selected_ip_binding_and_qr_keep_pairing_secret_out_of_output(tmp_path, monkeypatch, capsys):
    captured = []
    real_web = WebSource

    def web_source(*args, **kwargs):
        source = real_web(*args, **kwargs)
        captured.append(source)
        return source

    monkeypatch.setattr(entry, "WebSource", web_source)
    monkeypatch.setattr(entry, "lan_ips", lambda: ["192.0.2.25", "127.0.0.1"])
    requested_ips = []
    real_cert = entry.ensure_cert

    def selected_cert(directory, ips):
        requested_ips.append(ips)
        return real_cert(directory, ips)

    monkeypatch.setattr(entry, "ensure_cert", selected_cert)
    config = tmp_path / "config.json"
    config.write_text(json.dumps({"https_host": "127.0.0.2"}), encoding="utf-8")
    args = entry.parse_args(["--config", str(config), "--data-dir", str(tmp_path),
                             "--no-ble", "--hub-port", "0", "--http-port", "0", "--https-port", "0",
                             "--https-host", "127.0.0.1"])
    task = asyncio.create_task(entry.amain(args))
    try:
        async with asyncio.timeout(3):
            while not captured or captured[0]._phone_runner is None or not captured[0]._phone_runner.addresses:
                await asyncio.sleep(0.01)
        source = captured[0]
        assert requested_ips == [["127.0.0.1"]]
        assert source.hub.phone_url.endswith("/#k=" + source.pairing_token)
        assert source.hub.qr["url"] == source.hub.phone_url
        assert source._phone_runner.addresses[0][0] == "127.0.0.1"
        assert source.pairing_token not in capsys.readouterr().out
    finally:
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task


async def test_second_listener_bind_failure_closes_first_listener_and_hub(tmp_path, monkeypatch):
    captured_hubs, captured_sources = [], []
    real_hub, real_web = Hub, WebSource

    def hub_factory(**kwargs):
        hub = real_hub(**kwargs)
        captured_hubs.append(hub)
        return hub

    def web_factory(*args, **kwargs):
        source = real_web(*args, **kwargs)
        captured_sources.append(source)
        return source

    monkeypatch.setattr(entry, "Hub", hub_factory)
    monkeypatch.setattr(entry, "WebSource", web_factory)
    monkeypatch.setattr(entry, "lan_ips", lambda: ["127.0.0.1"])
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as occupied:
        occupied.bind(("127.0.0.1", 0))
        occupied.listen()
        options = entry.parse_args(["--config", str(tmp_path / "absent.json"), "--data-dir", str(tmp_path),
                                   "--no-ble", "--hub-port", "0", "--http-port", "0",
                                   "--https-port", str(occupied.getsockname()[1]), "--https-host", "127.0.0.1"])
        with pytest.raises(OSError):
            await entry.amain(options)
    assert not captured_hubs[0].game._thread.is_alive()
    assert not captured_sources[0]._runner.addresses
    assert not captured_sources[0]._phone_runner.addresses


async def test_management_app_rejects_nonloopback_peer_even_if_bound_to_all_interfaces():
    # A management listener misconfiguration must still fail closed.
    address = socket.gethostbyname(socket.gethostname())
    if address.startswith("127."):
        pytest.skip("host has no non-loopback address")
    source = WebSource(Hub())
    server = TestServer(source.app, host="0.0.0.0")
    await server.start_server()
    try:
        async with aiohttp.ClientSession() as session:
            for path in ("/sim", "/api/status", "/api/pairing"):
                async with session.get(f"http://{address}:{server.port}{path}") as response:
                    assert response.status == 403
    finally:
        await server.close()
