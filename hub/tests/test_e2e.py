"""End-to-end: simulator WebSocket client -> hub -> UDP 'game' socket, and game commands back."""

import asyncio
import json
import math
import socket
import time

import aiohttp

from regina_hub import protocol as P
from regina_hub.hub import Hub
from regina_hub.sources.web import WebSource

G = 9.80665


def free_port(kind=socket.SOCK_DGRAM) -> int:
    s = socket.socket(socket.AF_INET, kind)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class GameSocket(asyncio.DatagramProtocol):
    def __init__(self):
        self.samples: list[tuple] = []
        self.inputs: list[bytes] = []
        self.json: list[dict] = []
        self.transport = None

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        if data[:1] == b"{":
            self.json.append(json.loads(data))
        elif data[0] == P.MSG_SAMPLES:
            self.samples.extend(P.parse_game_samples(data)[1])
        elif data[0] == P.MSG_INPUT:
            self.inputs.append(data)


async def wait_for(pred, timeout=3.0):
    loop = asyncio.get_running_loop()
    end = loop.time() + timeout
    while loop.time() < end:
        if pred():
            return True
        await asyncio.sleep(0.02)
    return False


async def test_sim_to_game_roundtrip():
    game_port, hub_port, http_port = free_port(), free_port(), free_port(socket.SOCK_STREAM)
    hub = Hub(game_port=game_port, hub_port=hub_port)
    await hub.start()
    web = WebSource(hub)
    await web.start("127.0.0.1", http_port, None, None)
    runner = asyncio.create_task(hub.run_forever())

    loop = asyncio.get_running_loop()
    game = GameSocket()
    gtransport, _ = await loop.create_datagram_endpoint(lambda: game, local_addr=("127.0.0.1", game_port))
    gtransport.sendto(json.dumps({"cmd": "hello"}).encode(), ("127.0.0.1", hub_port))

    try:
        async with aiohttp.ClientSession() as session:
            async with session.ws_connect(f"http://127.0.0.1:{http_port}/ws", origin=f"http://127.0.0.1:{http_port}") as ws:
                await ws.send_json({"t": "hello", "kind": "sim", "name": "pytest", "client_id": "abc", "token": web.pairing_token})
                welcome = await ws.receive_json(timeout=2)
                assert welcome["t"] == "welcome" and welcome["player"] == 1
                cid = welcome["id"]

                # 2 s still (calibration) then 0.5 s of 90 deg/s yaw, all in canonical frame, 100 Hz.
                t_ms = 1000.0
                batch = []
                for i in range(250):
                    yaw_rate = math.radians(90) if i >= 200 else 0.0
                    batch.append([t_ms, 0.0, yaw_rate, 0.0, 0.0, G, 0.0])
                    t_ms += 10.0
                    if len(batch) == 5:
                        await ws.send_json({"t": "m", "frame": "canonical", "s": batch})
                        batch = []
                await ws.send_json({"t": "in", "b": 1, "d": [2, -1], "an": [0.25, 0]})

                ok = await wait_for(lambda: len(game.samples) >= 240)
                assert ok
                assert await wait_for(lambda: len(game.inputs) >= 1)
                t, qx, qy, qz, qw, *_ = game.samples[-1]
                yaw = math.degrees(2 * math.atan2(qy, qw))
                assert abs(yaw - 45.0) < 3.0, yaw
                assert any(m.get("type") == "event" and m.get("name") == "calibrated" for m in game.json)

                _, _, inp_cid, b, small, big, a0, _ = __import__("struct").unpack("<BBBBhhff", game.inputs[-1])
                assert (inp_cid, b, small, big) == (cid, 1, 2, -1) and abs(a0 - 0.25) < 1e-6

                assert await wait_for(lambda: any(m.get("type") == "roster" and m["controllers"] for m in game.json))
                roster = [m for m in game.json if m.get("type") == "roster"][-1]
                entry = roster["controllers"][0]
                assert entry["kind"] == "sim" and entry["player"] == 1 and entry["calibrated"]

                # Game -> hub -> controller UI
                gtransport.sendto(
                    json.dumps({"cmd": "ui", "controller": cid, "ui": {"clear": True, "title": "TEST", "legends": ["GO"]}}).encode(),
                    ("127.0.0.1", hub_port),
                )
                got_ui = None
                for _ in range(20):
                    msg = await ws.receive_json(timeout=2)
                    if msg.get("t") == "ui" and msg.get("title") == "TEST":
                        got_ui = msg
                        break
                assert got_ui is not None and got_ui["legends"][0] == "GO"

                # Player reassignment
                gtransport.sendto(json.dumps({"cmd": "set_player", "controller": cid, "player": 3}).encode(), ("127.0.0.1", hub_port))
                for _ in range(20):
                    msg = await ws.receive_json(timeout=2)
                    if msg.get("t") == "player":
                        assert msg["player"] == 3
                        break
                else:
                    raise AssertionError("no player message")

            # Disconnect emits an event and keeps the player slot for reconnection.
            assert await wait_for(lambda: any(m.get("name") == "disconnected" for m in game.json if m.get("type") == "event"))
            async with session.ws_connect(f"http://127.0.0.1:{http_port}/ws", origin=f"http://127.0.0.1:{http_port}") as ws:
                await ws.send_json({"t": "hello", "kind": "sim", "name": "pytest", "client_id": "abc", "token": web.pairing_token})
                welcome = await ws.receive_json(timeout=2)
                assert welcome["id"] == cid and welcome["player"] == 3
    finally:
        runner.cancel()
        gtransport.close()
        await web.stop()
        hub.close()


class _FlakySock:
    """Socket stub: first recv fails like Windows does after an ICMP port-unreachable."""

    def __init__(self) -> None:
        self.calls = 0

    def recvfrom(self, n: int):
        self.calls += 1
        if self.calls == 1:
            raise ConnectionResetError(10054, "port unreachable")
        if self.calls == 2:
            return b'{"cmd":"hello"}', ("127.0.0.1", 47800)
        time.sleep(0.01)
        raise TimeoutError()

    def close(self) -> None:
        pass


async def test_game_link_keeps_receiving_after_socket_error():
    hub = Hub()
    sock = _FlakySock()
    hub.game.start(sock, asyncio.get_running_loop())  # type: ignore[arg-type]
    try:
        assert await wait_for(lambda: hub.game.game_present)
    finally:
        hub.game.close()
