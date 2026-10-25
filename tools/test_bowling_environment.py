"""Check B1 hall resources, unchanged physics and 2/4-player lifecycle in isolated data.

Use --screenshots only on an isolated graphical desktop; default runs are headless.
"""
from __future__ import annotations

import argparse
import os
import re
import tempfile
from pathlib import Path

from smoke_test import engine_errors, png_size
from test_game import ROOT, find_godot, run_engine


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    parser.add_argument("--gpu-index", type=int, help="explicit Godot rendering-device index")
    parser.add_argument("--quality", type=int, choices=(0, 1, 2, 3), default=2)
    parser.add_argument("--text-size", nargs="+", type=int, choices=(100, 125), default=[100, 125])
    parser.add_argument("--screenshots", action="store_true")
    parser.add_argument("--players", nargs="+", type=int, choices=(2, 4), default=[2, 4])
    parser.add_argument("--output", type=Path, default=ROOT / "audit-output/bowling-environment")
    args = parser.parse_args()
    if args.gpu_index is not None and args.gpu_index < 0:
        parser.error("--gpu-index must be a non-negative integer")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    for players in args.players:
        for language, text_size in ((language, size) for language in (0, 1) for size in args.text_size):
            name = f"bowling-{players}-{language}-{text_size}"
            prefix = output / name
            with tempfile.TemporaryDirectory(prefix="rs-bowling-b1-") as temporary:
                user = Path(temporary) / ("Godot/app_userdata/Regina Sports" if os.name == "nt"
                                          else "godot/app_userdata/Regina Sports")
                user.mkdir(parents=True)
                (user / "settings.cfg").write_text(
                    f"[general]\nlanguage={language}\n[display]\nquality={args.quality}\n"
                    f"[accessibility]\ntext_size={int(text_size == 125)}\n", encoding="utf-8")
                env = dict(os.environ, RS_TEST_MODE="1", APPDATA=temporary, XDG_DATA_HOME=temporary,
                           XDG_CONFIG_HOME=temporary, XDG_CACHE_HOME=temporary,
                           RS_BOWLING_SCREENSHOT=str(prefix) if args.screenshots else "")
                command = [find_godot(args.godot), "--path", str(ROOT / "game"),
                           "res://tests/test_bowling_environment.tscn", "--resolution", "1600x900"]
                if args.gpu_index is not None:
                    command += ["--gpu-index", str(args.gpu_index)]
                if not args.screenshots:
                    command += ["--headless", "--fixed-fps", "60"]
                command += ["--", f"--demo={players}"]
                result = run_engine(command, env=env, timeout=150)
            log = result.stdout + result.stderr
            (output / f"{name}.log").write_text(log, encoding="utf-8")
            errors, environment = engine_errors(log)
            errors += [line for line in log.splitlines() if line.startswith("SHADER ERROR:")]
            markers = [line for line in log.splitlines() if line.startswith("RS_BOWLING_ENVIRONMENT_TESTS:")]
            if result.returncode or errors or len(markers) != 1 or not re.fullmatch(
                    r"RS_BOWLING_ENVIRONMENT_TESTS: [1-9][0-9]* checks, 0 failures", markers[0]):
                print(log)
                return 1
            if args.screenshots:
                for suffix in ("intro", "play", "hall"):
                    if png_size((output / f"{name}-{suffix}.png").read_bytes()) != (1600, 900):
                        raise ValueError("Wrong B1 screenshot dimensions")
            print(f"{name}: {markers[0]} (environment notes: {len(environment)})", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
