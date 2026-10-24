"""Check coarse golf extraction against portable numeric samples and emitted triangles."""
from __future__ import annotations

import argparse
import os
import re
import socket
import subprocess
import tempfile
from pathlib import Path

from engine_process import run_engine
from smoke_test import decode, engine_errors
from test_game import ROOT, find_godot


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    args = parser.parse_args()
    output = ROOT / "audit-output/golf-g3-a"
    output.mkdir(parents=True, exist_ok=True)
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.bind(("127.0.0.1", 47800))
    except OSError:
        print("UDP 47800 is occupied; wait for the other game instance. No process was stopped.")
        return 1
    with tempfile.TemporaryDirectory(prefix="rs-golf-surface-") as temp:
        env = dict(os.environ, RS_TEST_MODE="1", APPDATA=temp, XDG_DATA_HOME=temp,
                   XDG_CONFIG_HOME=temp, XDG_CACHE_HOME=temp)
        command = [find_godot(args.godot), "--headless", "--audio-driver", "Dummy", "--fixed-fps", "60",
                   "--quit-after", "36000", "--log-file", str(output / "surface-engine.log"),
                   "--path", str(ROOT / "game"), "res://tests/test_golf_surface.tscn"]
        try:
            result = run_engine(command, env=env, timeout=180)
        except subprocess.TimeoutExpired as exc:
            log = decode(exc.stdout) + decode(exc.stderr)
            (output / "surface.log").write_text(log, encoding="utf-8")
            print(log)
            print("Surface test timed out; owned engine tree stopped")
            return 1
        log = result.stdout + result.stderr
        (output / "surface.log").write_text(log, encoding="utf-8")
        errors, environment = engine_errors(log)
        markers = [line for line in log.splitlines() if line.startswith("RS_GOLF_SURFACE_TESTS:")]
        records = list(Path(temp).rglob("records.cfg"))
        print(log, end="")
        if (result.returncode or errors or records or len(markers) != 1
                or not re.fullmatch(r"RS_GOLF_SURFACE_TESTS: [1-9][0-9]* checks, 0 failures", markers[0])):
            print(f"Surface test failed (record files: {len(records)})")
            return 1
        print(f"Surface test passed (environment notes: {len(environment)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
