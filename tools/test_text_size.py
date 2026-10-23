"""Verify text sizes, process reload and real bilingual split-screen HUDs.

python tools/test_text_size.py --screenshots
CI can use --ui-only with the sparse art checkout. Import the project first.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import tempfile
import time
from pathlib import Path

from smoke_test import discover_cases, engine_errors, png_size
from test_game import ROOT, find_godot, run_engine


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    parser.add_argument("--ui-only", action="store_true")
    parser.add_argument("--screenshots", action="store_true")
    parser.add_argument("--players", nargs="+", type=int, choices=(1, 2, 3, 4), default=[2, 4])
    parser.add_argument("--games", nargs="+", choices=("plane", "archery", "bowling", "skate", "ski", "basketball"),
                        default=["plane", "archery", "bowling", "skate", "ski", "basketball"])
    parser.add_argument("--output", type=Path, default=ROOT / "audit-output/text-size")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix="_text-data-", dir=output)).resolve()
    try:
        cases = [("", 0, language, verify) for language in (0, 1) for verify in (False, True)]
        if not args.ui_only:
            env = dict(os.environ, APPDATA=str(temporary), XDG_DATA_HOME=str(temporary),
                       XDG_CONFIG_HOME=str(temporary), XDG_CACHE_HOME=str(temporary))
            games = discover_cases(find_godot(args.godot), env, output, args.games)
            cases += [(f"{case['game']}:{case['map']}", players, language, False)
                      for case in games for players in args.players for language in (0, 1)]
        for game, players, language, verify in cases:
            game, _, map_index = game.partition(":")
            map_index = int(map_index or 0)
            name = f"{game or 'menu'}-{map_index}-{players}-{language}" + ("-reload" if verify else "")
            data = temporary / f"{game or 'menu'}-{map_index}-{players}-{language}"
            user = data / ("Godot/app_userdata/Regina Sports" if os.name == "nt" else "godot/app_userdata/Regina Sports")
            user.mkdir(parents=True, exist_ok=True)
            if not verify:
                (user / "settings.cfg").write_text(f"[general]\nlanguage={language}\n[display]\nquality=1\n", encoding="utf-8")
            picture = output / f"{name}.png"
            graphical = args.screenshots and not verify
            env = dict(os.environ, RS_TEST_MODE="1", APPDATA=str(data), XDG_DATA_HOME=str(data),
                       XDG_CONFIG_HOME=str(temporary), XDG_CACHE_HOME=str(temporary), RS_TEXT_GAME=game,
                       RS_TEXT_VERIFY="1" if verify else "0", RS_TEXT_SCREENSHOT=str(picture) if graphical else "")
            command = [find_godot(args.godot), "--path", str(ROOT / "game"),
                       "res://tests/test_text_size.tscn", "--resolution", "1600x900"]
            if not graphical:
                command += ["--headless", "--fixed-fps", "60"]
            command += ["--", f"--demo={players}", f"--map={map_index}"] if game else ["--", "--static-menu"]
            result = run_engine(command, env=env, timeout=120)
            log = result.stdout + result.stderr
            (output / f"{name}.log").write_text(log, encoding="utf-8")
            markers = [line for line in log.splitlines() if line.startswith("RS_TEXT_SIZE:")]
            errors, environment = engine_errors(log)
            if result.returncode or errors or len(markers) != 1 or not re.fullmatch(r"RS_TEXT_SIZE: [1-9][0-9]* checks, 0 failures", markers[0]):
                print(log)
                return 1
            if graphical:
                suffixes = ["play", "results", "tutorial"] if game else ["settings", "menu", "players", "solo", "party", "records", "credits"]
                if game == "basketball":
                    suffixes.append("feedback")
                if any(png_size((output / f"{name}-{suffix}.png").read_bytes()) != (1600, 900) for suffix in suffixes):
                    raise ValueError("Wrong screenshot dimensions")
            print(f"{name}: {markers[0]} (environment notes: {len(environment)})", flush=True)
    finally:
        if temporary.parent != output or not temporary.name.startswith("_text-data-"):
            raise ValueError("Refusing cleanup outside test output")
        for attempt in range(4):
            try:
                shutil.rmtree(temporary)
                break
            except FileNotFoundError:
                break
            except OSError:
                time.sleep(0.2 * (attempt + 1))
        else:
            print("Cleanup warning: graphics cache retained in " + temporary.name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
