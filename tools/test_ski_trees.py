"""Compare ski tree data with the pre-LOD generator; does not measure rendering/FPS.

Run after importing script classes: python tools/test_ski_trees.py --godot <Godot>
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
from pathlib import Path

from capture_previews import temporary_data
from smoke_test import decode, engine_errors
from test_game import ROOT, find_godot, run_engine


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    parser.add_argument("--renderer-check", action="store_true",
                        help="require sampled MultiMesh upload readbacks; launch only on a hidden desktop")
    parser.add_argument("--output", type=Path, default=ROOT / "audit-output/ski-trees")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with temporary_data(output) as temporary:
        env = dict(os.environ, RS_TEST_MODE="1", APPDATA=temporary, LOCALAPPDATA=temporary, XDG_DATA_HOME=temporary,
                   XDG_CONFIG_HOME=temporary, XDG_CACHE_HOME=temporary,
                   RS_SKI_TREE_RENDERER_CHECK="1" if args.renderer_check else "0")
        command = [find_godot(args.godot), "--path", str(ROOT / "game"), "res://tests/test_ski_trees.tscn"]
        if not args.renderer_check:
            command.append("--headless")
        try:
            result = run_engine(command, env=env, timeout=120)
        except subprocess.TimeoutExpired as exc:
            log = decode(exc.stdout) + decode(exc.stderr)
            (output / "ski-trees.log").write_text(log, encoding="utf-8")
            print(f"Ski tree tests timed out; complete log retained: {output / 'ski-trees.log'}")
            return 1
        log = result.stdout + result.stderr
        (output / "ski-trees.log").write_text(log, encoding="utf-8")
        errors, _environment = engine_errors(log)
        markers = re.findall(r"^RS_SKI_TREES_TESTS: [1-9]\d* checks, 0 failures$", log, re.MULTILINE)
        if result.returncode or errors or len(markers) != 1:
            print(log[-18000:])
            print(f"Complete failure log retained: {output / 'ski-trees.log'}")
            return 1
        for line in log.splitlines():
            if line.startswith("RS_SKI_TREES_RENDERER_READBACKS:"):
                print(line)
        print(markers[0])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
