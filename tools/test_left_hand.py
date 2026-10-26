"""Verify per-player hand preferences, mirrored samples and six real game input paths.

python tools/test_left_hand.py --screenshots
CI can use --ui-only with the sparse art checkout. Import the project first.
"""
from __future__ import annotations

import argparse
import os
import shutil
import tempfile
import time
from pathlib import Path

import catalog
from smoke_test import engine_errors, png_size
from test_game import ROOT, find_godot, run_engine


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    parser.add_argument("--ui-only", action="store_true")
    parser.add_argument("--screenshots", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "audit-output/left-hand")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix="_hand-data-", dir=output)).resolve()
    try:
        cases = [("", 0, language, verify) for language in (0, 1) for verify in (False, True)]
        if not args.ui_only:
            cases += [(game, players, 0, False) for game in catalog.game_ids() for players in (2, 4)]
        for game, players, language, verify in cases:
            name = f"{game or 'menu'}-{players}-{language}" + ("-reload" if verify else "")
            data = temporary / f"{game or 'menu'}-{players}-{language}"
            user = data / ("Godot/app_userdata/Regina Sports" if os.name == "nt" else "godot/app_userdata/Regina Sports")
            user.mkdir(parents=True, exist_ok=True)
            if not verify:
                (user / "settings.cfg").write_text(f"[general]\nlanguage={language}\n[display]\nquality=1\n", encoding="utf-8")
            picture = output / f"{name}.png"
            graphical = args.screenshots and not game and not verify
            env = dict(os.environ, RS_TEST_MODE="1", APPDATA=str(data), XDG_DATA_HOME=str(data),
                       XDG_CONFIG_HOME=str(temporary), XDG_CACHE_HOME=str(temporary), RS_HAND_GAME=game,
                       RS_HAND_VERIFY="1" if verify else "0", RS_HAND_SCREENSHOT=str(picture) if graphical else "")
            command = [find_godot(args.godot), "--path", str(ROOT / "game"),
                       "res://tests/test_left_hand.tscn", "--resolution", "1600x900",
                       "--log-file", str(output / (name + ".native.log"))]
            if not graphical:
                command += ["--headless", "--fixed-fps", "60"]
            command += ["--", f"--demo={players}"] if game else ["--", "--static-menu"]
            result = run_engine(command, env=env, timeout=120)
            log = result.stdout + result.stderr
            (output / f"{name}.log").write_text(log, encoding="utf-8")
            markers = [line for line in log.splitlines() if line.startswith("RS_LEFT_HAND:")]
            errors, environment = engine_errors(log)
            if result.returncode or errors or len(markers) != 1 or not markers[0].endswith(", 0 failures"):
                print(log)
                return 1
            if graphical and png_size(picture.read_bytes()) != (1600, 900):
                raise ValueError("Wrong settings screenshot dimensions")
            print(f"{name}: {markers[0]} (environment notes: {len(environment)})", flush=True)
    finally:
        if temporary.parent != output or not temporary.name.startswith("_hand-data-"):
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
