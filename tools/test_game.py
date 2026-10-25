"""Run game shell regression tests without touching the player's profiles or records.

Usage: python tools/test_game.py --godot /path/to/godot
Requires the managed import step first: python tools/import_game.py --godot /path/to/godot
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import catalog
from engine_process import run_engine, silence_native_crash_dialogs
from test_storage import run_storage

ROOT = Path(__file__).resolve().parent.parent


def suite_passed(output: str, returncode: int, marker: str) -> bool:
    return (returncode == 0 and marker in output.splitlines()
            and not re.search(r"^(?:ERROR:|SCRIPT ERROR:|WARNING:.*leaked at exit)", output, re.MULTILINE))


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


def run_party_recovery(godot: str, output: Path) -> int:
    """Retain independent real-scene 2/4-player normal, missing-entrant and exit cases."""
    for players in (2, 4):
        for mode in ("normal", "missing", "exit"):
            case = output / f"{mode}-{players}p"
            case.mkdir()
            env = dict(os.environ, RS_TEST_MODE="1", RS_PARTY_RECOVERY_MODE=mode, RS_PARTY_PLAYERS=str(players))
            for key in ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
                directory = case / "user-data" / key.lower()
                directory.mkdir(parents=True)
                env[key] = str(directory)
            try:
                result = run_engine([godot, "--headless", "--fixed-fps", "60", "--path", str(ROOT / "game"),
                                     "res://tests/test_party_flow.tscn", "--log-file", str(case / "engine.log"),
                                     "--", f"--demo={players}", "--round=5"], env=env, timeout=180)
            except (subprocess.TimeoutExpired, OSError) as exc:
                log = str(exc)
                if isinstance(exc, subprocess.TimeoutExpired):
                    for stream in (exc.stdout, exc.stderr):
                        log += stream.decode("utf-8", errors="replace") if isinstance(stream, bytes) else (stream or "")
                (case / "stdout.log").write_text(log, encoding="utf-8")
                (case / "result.json").write_text(json.dumps({"status": "FAIL", "error": type(exc).__name__}), encoding="utf-8")
                print(f"party {mode} {players}p: FAIL; evidence retained", flush=True)
                return 1
            log = result.stdout + result.stderr
            (case / "stdout.log").write_text(log, encoding="utf-8")
            passed = suite_passed(log, result.returncode, "RS_PARTY_FLOW: PASS")
            passed = passed and not list((case / "user-data").rglob("records.cfg*"))
            (case / "result.json").write_text(json.dumps({"status": "PASS" if passed else "FAIL",
                "mode": mode, "players": players, "exit_code": result.returncode}), encoding="utf-8")
            print(f"party {mode} {players}p: {'PASS' if passed else 'FAIL'}", flush=True)
            if not passed:
                print(log)
                return 1
    return 0


def main() -> int:
    silence_native_crash_dialogs()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    parser.add_argument("--party", action="store_true", help="also run the complete three-event party flow")
    parser.add_argument("--party-recovery", action="store_true", help="also run 2/4-player missing-entrant and exit recovery")
    parser.add_argument("--party-output", type=Path, default=ROOT / "audit-output/party-recovery",
                        help="new retained evidence directory for --party-recovery")
    args = parser.parse_args()
    if args.party_recovery:
        args.party_output = args.party_output.resolve()
        if args.party_output.exists():
            parser.error("--party-output must be a new directory; preserve prior attempts")
        args.party_output.mkdir(parents=True)
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
        if not suite_passed(output, result.returncode, "RS_SHELL_TESTS: 0 failures"):
            return 1
        # The game's own manifest discovery (RSCatalog) must match what the tools read (tools/catalog.py).
        dump = Path(temp) / "catalog.json"
        result = run_engine([find_godot(args.godot), "--headless", "--path", str(ROOT / "game"),
                             "--log-file", str(Path(temp) / "catalog.log"), "--", f"--dump-catalog={dump}"],
                            env=env, timeout=60)
        output = result.stdout + result.stderr
        if not suite_passed(output, result.returncode, f"RS_CATALOG_DONE: {len(catalog.modules(True))}"):
            print(output)
            return 1
        errors = catalog.compare(json.loads(dump.read_text(encoding="utf-8")))
        print("\n".join(errors) or "RS_CATALOG: game and tools agree")
        if errors:
            return 1
    if run_storage(find_godot(args.godot)) != 0:
        return 1
    if args.party_recovery:
        return run_party_recovery(find_godot(args.godot), args.party_output)
    if args.party:
        with tempfile.TemporaryDirectory(prefix="rs-party-tests-") as temp:
            env = dict(os.environ, RS_TEST_MODE="1", APPDATA=temp, XDG_DATA_HOME=temp,
                       XDG_CONFIG_HOME=temp, XDG_CACHE_HOME=temp)
            result = run_engine([find_godot(args.godot), "--headless", "--fixed-fps", "60", "--path", str(ROOT / "game"),
                                     "res://tests/test_party_flow.tscn", "--log-file", str(Path(temp) / "game.log"), "--", "--demo=2", "--round=5"],
                                    env=env, timeout=120)
            output = result.stdout + result.stderr
            print(output)
            return 0 if suite_passed(output, result.returncode, "RS_PARTY_FLOW: PASS") else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
