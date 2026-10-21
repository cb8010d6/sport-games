"""Exercise frozen hub HTTP/HTTPS/WebSocket and the exported game before packaging."""
from __future__ import annotations

import argparse
import asyncio
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import time
import urllib.request

import aiohttp

from smoke_game import smoke_game


def free_port(kind: int = socket.SOCK_STREAM) -> int:
    with socket.socket(socket.AF_INET, kind) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


async def check_websocket(url: str) -> None:
    async with aiohttp.ClientSession() as session:
        async with session.ws_connect(url) as ws:
            await ws.send_json({"t": "hello", "kind": "sim", "client_id": "release-check", "name": "Release Check"})
            answer = await ws.receive_json(timeout=5)
            if answer.get("t") != "welcome":
                raise RuntimeError("Frozen hub did not welcome a controller")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("package", type=Path)
    args = parser.parse_args()
    root = args.package.resolve()
    http, https = free_port(), free_port()
    with tempfile.TemporaryDirectory(prefix="sport-games-smoke-") as temporary:
        data = Path(temporary)
        command = [str(root / "hub/sport-hub.exe"), "--no-ble", "--data-dir", str(data), "--lan-ip", "127.0.0.1",
                   "--http-port", str(http), "--https-port", str(https),
                   "--hub-port", str(free_port(socket.SOCK_DGRAM)), "--game-port", str(free_port(socket.SOCK_DGRAM))]
        with (data / "hub-output.txt").open("w", encoding="utf-8") as log:
            process = subprocess.Popen(command, cwd=root / "hub", stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 30
                while True:
                    try:
                        with urllib.request.urlopen(f"http://127.0.0.1:{http}/api/status", timeout=1) as response:
                            assert json.load(response)["type"] == "roster"
                        break
                    except OSError:
                        if process.poll() is not None or time.monotonic() >= deadline:
                            raise RuntimeError((data / "hub-output.txt").read_text(encoding="utf-8"))
                        time.sleep(0.2)
                with urllib.request.urlopen(f"http://127.0.0.1:{http}/sim", timeout=5) as response:
                    assert b"<html" in response.read().lower()
                tls = ssl.create_default_context(cafile=str(data / ".certs/cert.pem"))
                with urllib.request.urlopen(f"https://127.0.0.1:{https}/", context=tls, timeout=5) as response:
                    assert b"<html" in response.read().lower()
                asyncio.run(check_websocket(f"http://127.0.0.1:{http}/ws"))
            finally:
                process.terminate()
                process.wait(timeout=15)
        environment = {**os.environ, "SPORT_GAMES_DATA_DIR": str(data / "launcher")}
        subprocess.run([str(root / "SportGames.exe"), "--smoke-test"], cwd=root, env=environment, check=True, timeout=120)
        smoke_game(root / "game/SportGames.exe")
    print("Frozen hub HTTP, trusted local HTTPS, WebSocket, launcher and exported-game startup passed.")


if __name__ == "__main__":
    main()
