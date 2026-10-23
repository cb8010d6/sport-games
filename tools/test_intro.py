"""Check opening geometry, pause/restart and real bilingual map flyovers.

python tools/test_intro.py --screenshots
Use --math-only in the lightweight source CI after importing script classes.
"""
from __future__ import annotations

import argparse
import os
import re
from pathlib import Path

from capture_previews import temporary_data
from smoke_test import discover_cases, engine_errors, png_size
from test_game import ROOT, find_godot, run_engine


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    parser.add_argument("--math-only", action="store_true")
    parser.add_argument("--screenshots", action="store_true")
    parser.add_argument("--games", nargs="+", choices=("skate", "ski", "basketball"),
                        default=["skate", "ski", "basketball"])
    parser.add_argument("--players", nargs="+", type=int, choices=(1, 2, 3, 4), default=[2, 4])
    parser.add_argument("--output", type=Path, default=ROOT / "audit-output/intro")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with temporary_data(output) as temporary:
        base_env = dict(os.environ, RS_TEST_MODE="1", APPDATA=temporary, XDG_DATA_HOME=temporary,
                        XDG_CONFIG_HOME=temporary, XDG_CACHE_HOME=temporary)
        cases = [("", 0, 0, 0)]
        if not args.math_only:
            maps = discover_cases(find_godot(args.godot), base_env, output, args.games)
            cases += [(case["game"], case["map"], players, language)
                      for case in maps for players in args.players for language in (0, 1)]
        for game, map_index, players, language in cases:
            name = f"{game}-{map_index}-{players}-{language}" if game else "math"
            data = Path(temporary) / name
            user = data / ("Godot/app_userdata/Regina Sports" if os.name == "nt" else "godot/app_userdata/Regina Sports")
            user.mkdir(parents=True)
            (user / "settings.cfg").write_text(f"[general]\nlanguage={language}\n[display]\nquality=1\n", encoding="utf-8")
            graphical = bool(args.screenshots and game)
            prefix = output / name
            env = dict(base_env, APPDATA=str(data), XDG_DATA_HOME=str(data), RS_INTRO_GAME=game,
                       RS_INTRO_SCREENSHOT=str(prefix) if graphical else "")
            command = [find_godot(args.godot), "--path", str(ROOT / "game"),
                       "res://tests/test_intro.tscn", "--resolution", "1600x900"]
            if not graphical:
                command += ["--headless", "--fixed-fps", "60"]
            if game:
                command += ["--", f"--demo={players}", f"--map={map_index}"]
            result = run_engine(command, env=env, timeout=150)
            log = result.stdout + result.stderr
            (output / (name + ".log")).write_text(log, encoding="utf-8")
            errors, environment = engine_errors(log)
            markers = [line for line in log.splitlines() if line.startswith("RS_INTRO_TESTS:")]
            if result.returncode or errors or len(markers) != 1 or not re.fullmatch(r"RS_INTRO_TESTS: [1-9][0-9]* checks, 0 failures", markers[0]):
                print(log)
                return 1
            if graphical:
                for suffix in ("start", "middle", "end"):
                    if png_size((output / f"{name}-{suffix}.png").read_bytes()) != (1600, 900):
                        raise ValueError("Wrong opening screenshot dimensions")
            print(f"{name}: {markers[0]} (environment notes: {len(environment)})", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
