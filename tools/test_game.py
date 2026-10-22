"""Run game shell regression tests without touching the player's profiles or records.

Usage: python tools/test_game.py --godot /path/to/godot
Requires the managed import step first: python tools/import_game.py --godot /path/to/godot
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

from engine_process import run_engine, silence_native_crash_dialogs
from test_storage import run_storage


ROOT = Path(__file__).resolve().parent.parent


def find_godot(explicit: str | None) -> str:
    candidate = explicit or os.environ.get("REGINA_GODOT")
    if not candidate and sys.platform == "win32":
        lock = ROOT / "tools/engine_patches/build-lock.json"
        if lock.is_file():
            name = json.loads(lock.read_text(encoding="utf-8"))["output_binary"]
            patched = ROOT / "tools/godot" / name
            if patched.is_file():
                candidate = str(patched)
    if not candidate:
        candidate = shutil.which("godot")
    if not candidate:
        local = list((ROOT / "tools" / "godot").glob("*console.exe"))
        if local:
            candidate = str(local[0])
    if not candidate:
        raise SystemExit("Godot not found; use --godot or REGINA_GODOT.")
    return str(Path(candidate).resolve()) if Path(candidate).exists() else candidate


def main() -> int:
    silence_native_crash_dialogs()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    parser.add_argument("--party", action="store_true", help="also run the complete three-event party flow")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="rs-shell-tests-") as temp:
        env = dict(os.environ, RS_TEST_MODE="1", APPDATA=temp, XDG_DATA_HOME=temp,
                   XDG_CONFIG_HOME=temp, XDG_CACHE_HOME=temp)
        result = run_engine([find_godot(args.godot), "--headless", "--path", str(ROOT / "game"),
                                 "res://tests/test_shell.tscn", "--log-file", str(Path(temp) / "game.log")],
                                env=env, timeout=60)
        print(result.stdout)
        print(result.stderr)
        # Godot sometimes returns 0 after a script error; also require our explicit completion marker.
        output = result.stdout + result.stderr
        if result.returncode != 0 or "RS_SHELL_TESTS: 0 failures" not in output or "SCRIPT ERROR" in output:
            return 1
    if run_storage(find_godot(args.godot)) != 0:
        return 1
    if args.party:
        with tempfile.TemporaryDirectory(prefix="rs-party-tests-") as temp:
            env = dict(os.environ, RS_TEST_MODE="1", APPDATA=temp, XDG_DATA_HOME=temp,
                       XDG_CONFIG_HOME=temp, XDG_CACHE_HOME=temp)
            result = run_engine([find_godot(args.godot), "--headless", "--fixed-fps", "60", "--path", str(ROOT / "game"),
                                     "res://tests/test_party_flow.tscn", "--log-file", str(Path(temp) / "game.log"), "--", "--demo=2", "--round=5"],
                                    env=env, timeout=120)
            output = result.stdout + result.stderr
            print(output)
            return 0 if result.returncode == 0 and "RS_PARTY_FLOW: PASS" in output and "SCRIPT ERROR" not in output else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
