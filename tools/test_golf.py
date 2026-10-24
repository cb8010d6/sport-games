"""Run G2 golf rules and both maps with 1/2/4 bots using disposable user data."""
from __future__ import annotations

import argparse
import os
import re
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
    executable = find_godot(args.godot)
    output = ROOT / "audit-output/golf-g2"
    output.mkdir(parents=True, exist_ok=True)
    cases = [(index, count, "") for index in (0, 1) for count in (1, 2, 4)]
    cases += [(0, 1, kind) for kind in ("negative", "nan")]
    for map_index, players, invalid in cases:
        case = f"invalid-{invalid}" if invalid else f"map-{map_index}-players-{players}"
        with tempfile.TemporaryDirectory(prefix="rs-golf-") as temp:
            env = dict(os.environ, RS_TEST_MODE="1", RS_GOLF_INVALID_DELTA=invalid, APPDATA=temp,
                       XDG_DATA_HOME=temp, XDG_CONFIG_HOME=temp, XDG_CACHE_HOME=temp)
            command = [executable, "--headless", "--audio-driver", "Dummy", "--fixed-fps", "60",
                       "--quit-after", "36000", "--log-file", str(output / f"{case}-engine.log"),
                       "--path", str(ROOT / "game"), "res://tests/test_golf.tscn", "--",
                       f"--demo={players}", f"--map={map_index}"]
            try:
                result = run_engine(command, env=env, timeout=180)
            except subprocess.TimeoutExpired as exc:
                log = decode(exc.stdout) + decode(exc.stderr)
                (output / f"{case}.log").write_text(log, encoding="utf-8")
                print(log)
                print(f"{case}: timed out; owned engine tree stopped")
                return 1
            log = result.stdout + result.stderr
            (output / f"{case}.log").write_text(log, encoding="utf-8")
            errors, environment = engine_errors(log)
            marker = "RS_GOLF_INVALID_DELTA:" if invalid else "RS_GOLF_TESTS:"
            markers = [line for line in log.splitlines() if line.startswith(marker)]
            records = list(Path(temp).rglob("records.cfg"))
            expected_errors = ["ERROR: RSGolfGame: delta must be finite and nonnegative"] if invalid else []
            expected_exit = 1 if invalid else 0
            if (result.returncode != expected_exit or errors != expected_errors or records or len(markers) != 1
                    or not re.fullmatch(re.escape(marker) + r" [1-9][0-9]* checks, 0 failures", markers[0])):
                print(log)
                print(f"{case}: failed (record files: {len(records)})")
                return 1
            suffix = "; expected rejection exit=1" if invalid else ""
            print(f"{case}: {markers[0]} (environment notes: {len(environment)}{suffix})", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
