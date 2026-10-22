"""Check real music players, bus controls and scene lifecycle with isolated settings."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import tempfile

from engine_process import run_engine
from test_game import ROOT, find_godot


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="rs-music-tests-") as temp:
        env = dict(os.environ, RS_TEST_MODE="1", APPDATA=temp, XDG_DATA_HOME=temp,
                   XDG_CONFIG_HOME=temp, XDG_CACHE_HOME=temp)
        result = run_engine([find_godot(args.godot), "--headless", "--path", str(ROOT / "game"),
                             "res://tests/test_music.tscn", "--log-file", str(Path(temp) / "game.log"),
                             "--", "--static-menu"], env=env, timeout=60)
        output = result.stdout + result.stderr
        print(output)
        passed = result.returncode == 0 and re.search(r"^RS_MUSIC_TESTS: [1-9]\d* checks, 0 failures$", output, re.MULTILINE)
        return 0 if passed and not re.search(r"^(?:ERROR:|SCRIPT ERROR:|WARNING:.*leaked at exit)", output, re.MULTILINE) else 1


if __name__ == "__main__":
    raise SystemExit(main())
