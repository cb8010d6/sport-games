"""Check headless renderer RID ownership using concurrent native resource allocation.

python tools/test_engine.py --godot /path/to/godot --runs 3
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
from pathlib import Path

from smoke_test import decode, engine_errors
from test_game import ROOT, find_godot, run_engine


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--kinds", nargs="+", choices=("mesh", "material", "texture"),
                        default=["mesh", "material", "texture"])
    parser.add_argument("--output", type=Path, default=ROOT / "audit-output/engine-regression")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be at least 1")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    rows = []
    (output / "results.json").unlink(missing_ok=True)
    for kind in args.kinds:
        for index in range(args.runs):
            with tempfile.TemporaryDirectory(prefix="rs-engine-test-") as temp:
                env = dict(os.environ, APPDATA=temp, XDG_DATA_HOME=temp,
                           XDG_CONFIG_HOME=temp, XDG_CACHE_HOME=temp)
                command = [find_godot(args.godot), "--headless", "--path", str(ROOT / "tools/engine_tests"),
                           "--script", "res://threaded_dummy.gd", "--", f"--kind={kind}"]
                try:
                    result = run_engine(command, env=env, timeout=30)
                    log = result.stdout + result.stderr
                    code = result.returncode
                except subprocess.TimeoutExpired as exc:
                    log = decode(exc.stdout) + decode(exc.stderr) + "\nERROR: Engine timed out"
                    code = -1
                errors, environment = engine_errors(log)
                passed = code == 0 and f"RS_ENGINE_STRESS_DONE: {kind}" in log.splitlines() and not errors
                (output / f"{kind}-{index + 1}.log").write_text(log, encoding="utf-8")
                row = {"kind": kind, "run": index + 1, "passed": passed, "exit_code": code,
                       "exit_hex": f"0x{code & 0xFFFFFFFF:08X}", "errors": len(errors),
                       "environment_warnings": environment}
                rows.append(row)
                (output / "results.json").write_text(json.dumps(rows, indent=2), encoding="utf-8")
                print(f"{kind} {index + 1}: {'PASS' if passed else 'FAIL'}; exit {row['exit_hex']}; {len(errors)} errors", flush=True)
    return 0 if all(row["passed"] for row in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
