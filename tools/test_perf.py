"""Run the #53 performance guards: indexed course lookups, ride sub-step cap, split shadow tier."""
from __future__ import annotations

import argparse
import os
import re
import tempfile
from pathlib import Path

from engine_process import run_engine, silence_native_crash_dialogs

ROOT = Path(__file__).resolve().parent.parent


def valid_output(output: str, returncode: int) -> bool:
    return (returncode == 0
            and re.search(r"^RS_PERF_TESTS: [1-9]\d* checks, 0 failures$", output, re.MULTILINE) is not None
            and not re.search(r"^\s*(?:ERROR:|SCRIPT ERROR|FATAL|CRASH|WARNING:.*leaked at exit)", output, re.MULTILINE))


def run_perf(godot: str) -> int:
    with tempfile.TemporaryDirectory(prefix="rs-perf-tests-") as temp:
        env = dict(os.environ, RS_TEST_MODE="1", APPDATA=temp, XDG_DATA_HOME=temp,
                   XDG_CONFIG_HOME=temp, XDG_CACHE_HOME=temp)
        result = run_engine([godot, "--headless", "--path", str(ROOT / "game"),
                             "res://tests/test_perf.tscn", "--log-file", str(Path(temp) / "game.log")],
                            env=env, timeout=180)
        output = result.stdout + result.stderr
        print(output)
        return 0 if valid_output(output, result.returncode) else 1


def main() -> int:
    from test_game import find_godot

    silence_native_crash_dialogs()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    args = parser.parse_args()
    return run_perf(find_godot(args.godot))


if __name__ == "__main__":
    raise SystemExit(main())
