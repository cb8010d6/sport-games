"""Check independent fixed-input golf physics, finite hazards and expected invalid-state failures."""
from __future__ import annotations

import argparse
import os
import re
import subprocess
from pathlib import Path

from engine_process import run_engine
from smoke_test import decode, engine_errors
from test_game import ROOT, find_godot

REJECTIONS = {
    "nan": "RSGolfBall: finite bounded shot inputs required",
    "penetration": "RSGolfWorld: sphere starts inside terrain",
    "water": "RSGolfWorld: invalid water geometry",
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    parser.add_argument("--output", type=Path, default=ROOT / "audit-output/golf-physics")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        parser.error("--output must be a new directory; preserve prior attempts")
    output.mkdir(parents=True)
    for invalid in ("", *REJECTIONS):
        case = invalid or "physics"
        userdata = output / "user-data" / case
        env = dict(os.environ, RS_TEST_MODE="1", RS_GOLF_PHYSICS_INVALID=invalid)
        for key in ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
            directory = userdata / key.lower()
            directory.mkdir(parents=True)
            env[key] = str(directory)
        command = [find_godot(args.godot), "--headless", "--audio-driver", "Dummy", "--fixed-fps", "60",
                   "--quit-after", "3600", "--log-file", str(output / f"{case}-engine.log"),
                   "--path", str(ROOT / "game"), "res://tests/test_golf_physics.tscn"]
        try:
            result = run_engine(command, env=env, timeout=90)
        except subprocess.TimeoutExpired as exc:
            log = decode(exc.stdout) + decode(exc.stderr)
            (output / f"{case}.log").write_text(log, encoding="utf-8")
            print(log)
            print(f"{case}: timed out; owned engine tree stopped; evidence retained")
            return 1
        log = result.stdout + result.stderr
        (output / f"{case}.log").write_text(log, encoding="utf-8")
        errors, environment = engine_errors(log)
        marker = "RS_GOLF_PHYSICS_REJECTION:" if invalid else "RS_GOLF_PHYSICS_TESTS:"
        markers = [line for line in log.splitlines() if line.startswith(marker)]
        expected = ["ERROR: " + REJECTIONS[invalid]] if invalid else []
        if (result.returncode != int(bool(invalid)) or errors != expected or environment
                or list(userdata.rglob("records.cfg*")) or len(markers) != 1
                or not re.fullmatch(re.escape(marker) + r" [1-9][0-9]* checks, 0 failures", markers[0])):
            print(log)
            print(f"{case}: failed; evidence retained")
            return 1
        print(f"{case}: {markers[0]}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
