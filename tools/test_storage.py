"""Exercise real ConfigFile migration and recovery with isolated player data."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import tempfile

from engine_process import run_engine, silence_native_crash_dialogs


ROOT = Path(__file__).resolve().parent.parent
EXPECTED_ERRORS = (
    r"^ERROR: ConfigFile parse error at user://save-tests/syntax\.cfg:0: Unexpected EOF while parsing simple tag\.$",
    r"^ERROR: RSProfiles: cannot save profiles \(File unrecognized\)$",
)


def valid_output(output: str, returncode: int) -> bool:
    """Permit only the two deliberate fault diagnostics, each exactly once."""
    if returncode != 0 or "SCRIPT ERROR" in output:
        return False
    if not re.search(r"^RS_STORAGE_TESTS: [1-9]\d* checks, 0 failures$", output, re.MULTILINE):
        return False
    remaining = output
    for pattern in EXPECTED_ERRORS:
        remaining, count = re.subn(pattern, "", remaining, flags=re.MULTILINE)
        if count != 1:
            return False
    return not re.search(r"^\s*(?:ERROR:|FATAL|CRASH|WARNING:.*leaked at exit)", remaining, re.MULTILINE)


def run_storage(godot: str) -> int:
    with tempfile.TemporaryDirectory(prefix="rs-storage-tests-") as temp:
        env = dict(os.environ, RS_TEST_MODE="1", APPDATA=temp, XDG_DATA_HOME=temp,
                   XDG_CONFIG_HOME=temp, XDG_CACHE_HOME=temp)
        result = run_engine([godot, "--headless", "--path", str(ROOT / "game"),
                             "res://tests/test_storage.tscn", "--log-file", str(Path(temp) / "game.log")],
                            env=env, timeout=60)
        output = result.stdout + result.stderr
        print(output)
        if not valid_output(output, result.returncode):
            return 1
        # Reuse only this suite's isolated user data to exercise a real cold start,
        # including Godot's early project-settings override reader.
        env["RS_STORAGE_REOPEN"] = "1"
        reopened = run_engine([godot, "--headless", "--path", str(ROOT / "game"),
                               "res://tests/test_storage.tscn", "--log-file", str(Path(temp) / "reopen.log")],
                              env=env, timeout=60)
        output = reopened.stdout + reopened.stderr
        print(output)
        return 0 if (reopened.returncode == 0 and "RS_STORAGE_REOPEN: PASS" in output
                     and not re.search(r"^(?:ERROR:|SCRIPT ERROR:|WARNING:.*leaked at exit)", output, re.MULTILINE)) else 1


def main() -> int:
    from test_game import find_godot

    silence_native_crash_dialogs()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    args = parser.parse_args()
    return run_storage(find_godot(args.godot))


if __name__ == "__main__":
    raise SystemExit(main())
