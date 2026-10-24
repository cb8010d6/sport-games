"""Start game instances at the same time and check ControllerHub's UDP ports.

Usage: python tools/test_hub_port.py --godot /path/to/godot
UDP 47800 stays occupied throughout: test-mode instances must not need it, and a
normal-mode instance must still try to bind it.
"""
from __future__ import annotations

import argparse
import os
import re
import socket
import tempfile
from pathlib import Path

from engine_process import run_engine, run_engines, silence_native_crash_dialogs
from smoke_test import engine_errors
from test_game import ROOT, find_godot

GAME_PORT = 47800
MARKER = re.compile(r"^RS_HUB_PORT_TESTS: [1-9]\d* checks, 0 failures$", re.MULTILINE)
PORT = re.compile(r"^RS_HUB_PORT: (\d+)$", re.MULTILINE)


def udp(port: int, exclusive: bool = False) -> socket.socket:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if exclusive and os.name == "nt":
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
    try:
        sock.bind(("127.0.0.1", port))
    except OSError:
        sock.close()
        raise
    return sock


def occupy_game_port() -> socket.socket | None:
    """Hold 47800; None when another process already holds it, which serves equally."""
    try:
        return udp(GAME_PORT, exclusive=True)
    except OSError:
        return None


def fake_hub() -> socket.socket:
    """A hub socket on N whose game port N - 1 is free, for --hub-port=N."""
    for _ in range(20):
        hub = udp(0)
        try:
            udp(hub.getsockname()[1] - 1).close()
            hub.settimeout(0.5)
            return hub
        except OSError:
            hub.close()
    raise OSError("No free adjacent UDP port pair")


def instance_port(name: str, output: str, returncode: int) -> int:
    errors, _environment = engine_errors(output)
    ports = PORT.findall(output)
    if returncode or errors or not MARKER.search(output) or len(ports) != 1:
        print(output)
        raise AssertionError(f"{name}: hub port suite failed (exit {returncode})")
    return int(ports[0])


def main() -> int:
    silence_native_crash_dialogs()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    args = parser.parse_args()
    godot = find_godot(args.godot)
    held = occupy_game_port()
    hub = fake_hub()
    try:
        hub_port = hub.getsockname()[1]
        with tempfile.TemporaryDirectory(prefix="rs-hub-port-") as temp:
            base = dict(os.environ, APPDATA=temp, XDG_DATA_HOME=temp, XDG_CONFIG_HOME=temp, XDG_CACHE_HOME=temp)
            env = dict(base, RS_TEST_MODE="1")
            scene = [godot, "--headless", "--path", str(ROOT / "game"), "res://tests/test_hub_port.tscn"]
            names = ["first", "second", "hub-port"]
            commands = [scene + ["--log-file", str(Path(temp) / f"{name}.log")] for name in names]
            commands[2] += ["--", f"--hub-port={hub_port}"]
            results = run_engines(commands, env=env, timeout=60)
            ports = [instance_port(name, result.stdout + result.stderr, result.returncode)
                     for name, result in zip(names, results)]
            if ports[0] == ports[1] or GAME_PORT in ports[:2]:
                raise AssertionError(f"Concurrent test instances share or use a fixed port: {ports[:2]}")
            if ports[2] != hub_port - 1:
                raise AssertionError(f"--hub-port={hub_port} listened on {ports[2]}")
            hello, source = hub.recvfrom(4096)
            if hello != b'{"cmd":"hello"}' or source != ("127.0.0.1", hub_port - 1):
                raise AssertionError(f"--hub-port instance sent {hello!r} from {source}")
            print(f"Concurrent test instances bound {ports[0]} and {ports[1]}; --hub-port={hub_port} paired {ports[2]}")

            # Normal play must still claim 47800, so it reports the port this runner holds.
            normal_env = {key: value for key, value in base.items() if key != "RS_TEST_MODE"}
            result = run_engine([godot, "--headless", "--path", str(ROOT / "game"), "--quit-after", "30",
                                 "--log-file", str(Path(temp) / "normal.log"), "--", "--static-menu"],
                                env=normal_env, timeout=60)
            output = result.stdout + result.stderr
            if f"ControllerHub: cannot bind UDP {GAME_PORT}" not in output:
                print(output)
                raise AssertionError("Normal mode did not try to bind UDP 47800")
            print("Normal mode still binds UDP 47800")
    finally:
        hub.close()
        if held:
            held.close()
    print("RS_HUB_PORT: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
