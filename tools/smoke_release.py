"""Exercise frozen hub HTTP/HTTPS/WebSocket and the exported game before packaging."""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import socket
import ssl
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

import aiohttp
from smoke_game import smoke_game


def free_port(kind: int = socket.SOCK_STREAM) -> int:
    with socket.socket(socket.AF_INET, kind) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


async def check_websocket(url: str) -> None:
    parts = urlsplit(url)
    origin = f"{parts.scheme}://{parts.netloc}"
    async with aiohttp.ClientSession() as session:
        async with session.get(origin + "/api/pairing") as response:
            response.raise_for_status()
            token = (await response.json())["token"]
        async with session.ws_connect(url, origin=origin) as ws:
            await ws.send_json({"t": "hello", "kind": "sim", "client_id": "release-check", "name": "Release Check", "token": token})
            answer = await ws.receive_json(timeout=5)
            if answer.get("t") != "welcome":
                raise RuntimeError("Frozen hub did not welcome a controller")


def check_ble_backend(hub: Path) -> None:
    """The network smoke runs with --no-ble; this proves the WinRT BLE backend was bundled (no scan, no adapter needed)."""
    result = subprocess.run([str(hub), "--ble-selftest"], cwd=hub.parent, capture_output=True, text=True, timeout=60)
    print(result.stdout.strip() or result.stderr.strip(), flush=True)
    if result.returncode != 0:
        raise RuntimeError(f"Frozen hub BLE self-test failed ({result.returncode}): {result.stdout}{result.stderr}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("package", type=Path)
    args = parser.parse_args()
    root = args.package.resolve()
    check_ble_backend(root / "hub/sport-hub.exe")
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
                    except OSError as exc:
                        if process.poll() is not None or time.monotonic() >= deadline:
                            raise RuntimeError((data / "hub-output.txt").read_text(encoding="utf-8")) from exc
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
    print("Frozen hub BLE backend, HTTP, trusted local HTTPS, WebSocket, launcher and exported-game startup passed.")


if __name__ == "__main__":
    main()
