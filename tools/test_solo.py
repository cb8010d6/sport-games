"""Run formal human/CPU matches and challenge boundaries on real scenes.

python tools/test_solo.py --all-maps
python tools/test_solo.py --screenshots --language en --levels 1
Synthetic controller tests do not certify physical controller feel or difficulty balance.
"""
from __future__ import annotations

import argparse
import html
import json
import os
import shutil
import subprocess
import tempfile
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

from smoke_test import GAMES, decode, discover_cases, engine_errors, png_size
from test_game import ROOT, find_godot, run_engine, silence_native_crash_dialogs


def validate_report(value: object, game: str, level: int, map_index: int, layout: bool) -> None:
    if not isinstance(value, dict) or value.get("passed") is not True or value.get("errors") != []:
        raise ValueError("Missing or failed solo report")
    if (value.get("game"), value.get("level"), value.get("slot"), value.get("map"), value.get("layout_only")) != (
            game, level, (1, 3, 4)[level], map_index, layout):
        raise ValueError("Unexpected game/difficulty/slot/map/mode")
    if type(value.get("checks")) is not int or value["checks"] < 25:
        raise ValueError("Incomplete interaction checks")
    for key in ("human_score", "cpu_score"):
        if type(value.get(key)) is not int or value[key] < 0:
            raise ValueError("Invalid final score")


@contextmanager
def suite_data(output: Path) -> Iterator[str]:
    directory = Path(tempfile.mkdtemp(prefix="_run_data-", dir=output))
    try:
        yield str(directory)
    finally:
        target = directory.resolve()
        if target.parent != output.resolve() or not target.name.startswith("_run_data-"):
            raise ValueError("Refusing cleanup outside the suite output")
        for attempt in range(4):
            try:
                shutil.rmtree(target)
                break
            except FileNotFoundError:
                break
            except OSError:
                time.sleep(0.2 * (attempt + 1))
        else:
            print("Cleanup warning: suite GPU cache retained in " + target.name, flush=True)


def write_gallery(output: Path, rows: list[dict]) -> None:
    cards = []
    for row in rows:
        stem = row["case"]
        pictures = []
        for name in ("menu", "lobby", "play", "results"):
            path = f"{stem}/{name}.png"
            if (output / path).is_file():
                pictures.append(f'<a href="{path}"><img src="{path}" alt="{name}"></a>')
        cards.append(f'<article><h2>{html.escape(stem)}: {"PASS" if row["passed"] else "FAIL"}</h2>'
                     + "".join(pictures) + "</article>")
    (output / "index.html").write_text('<!doctype html><meta charset="utf-8"><title>Solo layouts</title>'
                                     '<style>body{background:#101521;color:white;font:18px system-ui}article{margin:20px}img{width:48%}</style>'
                                     + "".join(cards), encoding="utf-8")


def main() -> int:
    silence_native_crash_dialogs()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    parser.add_argument("--games", nargs="+", choices=GAMES, default=list(GAMES))
    parser.add_argument("--levels", nargs="+", type=int, choices=(0, 1, 2), default=[0, 1, 2])
    parser.add_argument("--all-maps", action="store_true")
    parser.add_argument("--screenshots", action="store_true", help="layout checks, skips full CPU round")
    parser.add_argument("--verbose", action="store_true", help="include native leak diagnostics")
    parser.add_argument("--language", choices=("zh", "en"), default="zh")
    parser.add_argument("--output", type=Path, default=ROOT / "audit-output/solo")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    summary = output / "summary.json"
    summary.unlink(missing_ok=True)
    (output / "index.html").unlink(missing_ok=True)
    godot = find_godot(args.godot)
    rows = []
    with suite_data(output) as temp:
        env = dict(os.environ, RS_TEST_MODE="1", APPDATA=temp, XDG_DATA_HOME=temp,
                   XDG_CONFIG_HOME=temp, XDG_CACHE_HOME=temp)
        cases = discover_cases(godot, env, output, list(dict.fromkeys(args.games)))
        if not args.all_maps:
            cases = [case for case in cases if case["map"] == 0]
        expected = len(cases) * len(set(args.levels))
        for case in cases:
            for level in dict.fromkeys(args.levels):
                stem = f'{case["game"]}-map{case["map"]}-level{level}'
                report = output / f"{stem}.json"
                report.unlink(missing_ok=True)
                capture = output / stem
                if args.screenshots:
                    capture.mkdir(exist_ok=True)
                    for filename in ("menu.png", "lobby.png", "play.png", "results.png"):
                        (capture / filename).unlink(missing_ok=True)
                # Fresh player data per case, with one suite-local GPU cache to avoid
                # recompiling shaders for every language/game screenshot.
                user_data = Path(temp) / stem
                user = user_data / ("Godot/app_userdata/Regina Sports" if os.name == "nt" else "godot/app_userdata/Regina Sports")
                user.mkdir(parents=True)
                (user / "settings.cfg").write_text(f'[general]\nlanguage={int(args.language == "en")}\n[display]\nquality=0\n', encoding="utf-8")
                case_env = dict(env, APPDATA=str(user_data), XDG_DATA_HOME=str(user_data),
                                RS_SOLO_GAME=case["game"], RS_SOLO_LEVEL=str(level), RS_SOLO_REPORT=str(report),
                                RS_SOLO_CAPTURE=str(capture) if args.screenshots else "")
                command = [godot, "--path", str(ROOT / "game"), "res://tests/test_solo.tscn", "--fixed-fps", "60"]
                if args.verbose:
                    command.append("--verbose")
                command += ["--resolution", "1600x900"] if args.screenshots else ["--headless"]
                command += ["--", "--static-menu", f'--map={case["map"]}']
                errors = []
                try:
                    result = run_engine(command, env=case_env, timeout=240)
                    log = result.stdout + result.stderr
                    errors, environment = engine_errors(log)
                    if result.returncode or "RS_SOLO_TEST: PASS" not in log.splitlines():
                        errors.append(f"No successful completion (exit {result.returncode})")
                except (OSError, subprocess.TimeoutExpired) as exc:
                    log = decode(getattr(exc, "stdout", "")) + decode(getattr(exc, "stderr", ""))
                    errors, environment = [str(exc)], []
                (output / f"{stem}.log").write_text(log, encoding="utf-8")
                value = None
                try:
                    value = json.loads(report.read_text(encoding="utf-8"))
                    validate_report(value, case["game"], level, case["map"], args.screenshots)
                    if args.screenshots:
                        for filename in ("menu.png", "lobby.png", "play.png", "results.png"):
                            if png_size((capture / filename).read_bytes()) != (1600, 900):
                                raise ValueError("Screenshot is not 1600x900")
                except (OSError, ValueError) as exc:
                    errors.append(str(exc))
                rows.append({"case": stem, "passed": not errors, "errors": errors,
                             "environment_warnings": environment, "report": value})
                summary.write_text(json.dumps({"expected": expected, "completed": len(rows), "cases": rows,
                                               "status": "PASS" if len(rows) == expected and all(row["passed"] for row in rows) else "INCOMPLETE_OR_FAILED"},
                                              indent=2, ensure_ascii=False), encoding="utf-8")
                print(f'{stem}: {"PASS" if not errors else "FAIL"}', flush=True)
                if args.screenshots:
                    write_gallery(output, rows)
    return 0 if all(row["passed"] for row in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
