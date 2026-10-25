"""Test real menu preview navigation in both languages with isolated user data.

python tools/test_menu_preview.py --screenshots --backdrop
Omit --screenshots for the headless CI check; assets must be imported first.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path

import catalog
from capture_previews import temporary_data
from smoke_test import engine_errors, png_size
from test_game import ROOT, find_godot, run_engine


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    parser.add_argument("--screenshots", action="store_true")
    parser.add_argument("--backdrop", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "audit-output/menu-previews")
    args = parser.parse_args()
    if args.backdrop and not args.screenshots:
        parser.error("--backdrop needs --screenshots and the full art tree")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with temporary_data(output) as temp:
        for language in (0, 1):
            code = ("zh", "en")[language]
            data = Path(temp) / code
            user = data / ("Godot/app_userdata/Regina Sports" if os.name == "nt" else "godot/app_userdata/Regina Sports")
            user.mkdir(parents=True)
            (user / "settings.cfg").write_text(f"[general]\nlanguage={language}\n[display]\nquality=1\n", encoding="utf-8")
            pictures = output / code
            pictures.mkdir(exist_ok=True)
            env = dict(os.environ, RS_TEST_MODE="1", APPDATA=str(data), XDG_DATA_HOME=str(data),
                       XDG_CONFIG_HOME=temp, XDG_CACHE_HOME=temp,
                       RS_MENU_PREVIEW_OUTPUT=str(pictures) if args.screenshots else "")
            command = [find_godot(args.godot), "--path", str(ROOT / "game"),
                       "res://tests/test_menu_preview.tscn", "--resolution", "1600x900", "--audio-driver", "Dummy"]
            if not args.screenshots:
                command.append("--headless")
            else:
                # A software OpenGL renderer is sufficient to inspect these 2D overlays in CI.
                command += ["--rendering-method", "gl_compatibility"]
            command.append("--")
            if not args.backdrop:
                command.append("--static-menu")
            result = run_engine(command, env=env, timeout=120)
            log = result.stdout + result.stderr
            (output / (code + ".log")).write_text(log, encoding="utf-8")
            errors, environment = engine_errors(log)
            markers = [line for line in log.splitlines() if line.startswith("RS_MENU_PREVIEW_TESTS:")]
            if result.returncode or errors or len(markers) != 1 or not markers[0].endswith(", 0 failures"):
                print(log)
                return 1
            if args.screenshots:
                for game in catalog.game_ids():
                    if png_size((pictures / (game + ".png")).read_bytes()) != (1600, 900):
                        raise ValueError("Unexpected screenshot dimensions")
                for state in ("no_adverts", "unavailable"):
                    for screen in ("menu", "players"):
                        if png_size((pictures / f"ble_{state}_{screen}.png").read_bytes()) != (1600, 900):
                            raise ValueError("Unexpected BLE diagnostic screenshot dimensions")
            print(f"{code}: {markers[0]} (environment notes: {len(environment)})", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
