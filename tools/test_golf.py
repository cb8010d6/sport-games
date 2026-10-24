"""Run golf rules and both maps with 1/2/4 bots using retained isolated user data."""
from __future__ import annotations

import argparse
import os
import re
import subprocess
from pathlib import Path

from engine_process import run_engine
from smoke_test import decode, engine_errors
from test_game import ROOT, find_godot


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    parser.add_argument("--output", type=Path, default=ROOT / "audit-output/golf-m1")
    parser.add_argument("--maps", type=int, nargs="+", choices=(0, 1), default=(0, 1))
    parser.add_argument("--players", type=int, nargs="+", choices=(1, 2, 4), default=(1, 2, 4))
    args = parser.parse_args()
    executable = find_godot(args.godot)
    output = args.output.resolve()
    if output.exists():
        parser.error("--output must be a new directory; preserve prior attempts")
    output.mkdir(parents=True)
    cases = [(index, count, "") for index in dict.fromkeys(args.maps) for count in dict.fromkeys(args.players)]
    cases += [(0, 1, kind) for kind in ("negative", "nan")]
    for map_index, players, invalid in cases:
        case = f"invalid-{invalid}" if invalid else f"map-{map_index}-players-{players}"
        userdata = output / "user-data" / case
        env = dict(os.environ, RS_TEST_MODE="1", RS_GOLF_INVALID_DELTA=invalid)
        for key in ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
            directory = userdata / key.lower()
            directory.mkdir(parents=True)
            env[key] = str(directory)
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
            print(f"{case}: timed out; owned engine tree stopped; evidence retained")
            return 1
        log = result.stdout + result.stderr
        (output / f"{case}.log").write_text(log, encoding="utf-8")
        errors, environment = engine_errors(log)
        marker = "RS_GOLF_INVALID_DELTA:" if invalid else "RS_GOLF_TESTS:"
        markers = [line for line in log.splitlines() if line.startswith(marker)]
        records = list(userdata.rglob("records.cfg*"))
        expected_errors = ["ERROR: RSGolfGame: delta must be finite and nonnegative"] if invalid else []
        expected_exit = 1 if invalid else 0
        if (result.returncode != expected_exit or errors != expected_errors or environment or records or len(markers) != 1
                or not re.fullmatch(re.escape(marker) + r" [1-9][0-9]* checks, 0 failures", markers[0])):
            print(log)
            print(f"{case}: failed (record files: {len(records)})")
            return 1
        suffix = "; expected rejection exit=1" if invalid else ""
        print(f"{case}: {markers[0]} (environment notes: {len(environment)}{suffix})", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
