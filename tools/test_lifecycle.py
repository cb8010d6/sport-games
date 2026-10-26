"""Check real scene controls with synthetic loopback controllers, optionally capture layouts.

python tools/test_lifecycle.py
python tools/test_lifecycle.py --screenshots --all-maps --languages zh en
Real BLE/phone hardware, haptics and HDR still need device validation.
"""
from __future__ import annotations

import argparse
import html
import json
import math
import os
import shutil
import subprocess
import tempfile
import time
from contextlib import nullcontext
from pathlib import Path

from smoke_test import GAMES, decode, discover_cases, engine_errors, png_size
from test_game import ROOT, find_godot, run_engine


def validate_report(report: object, game: str, players: int, layout_only: bool, recovery_mode: str = "") -> None:
    if not isinstance(report, dict) or report.get("game") != game or type(report.get("players")) is not int or report["players"] != players:
        raise ValueError("Lifecycle report has the wrong game or player count")
    if report.get("layout_only") is not layout_only or report.get("errors") != []:
        raise ValueError("Lifecycle checks failed or the wrong mode ran")
    if type(report.get("checks")) is not int or report["checks"] < (6 if layout_only else 18):
        raise ValueError("Lifecycle checks did not complete")
    if recovery_mode:
        elapsed = report.get("recovery_elapsed_seconds")
        if report.get("recovery_mode") != recovery_mode or type(elapsed) not in (int, float) or not math.isfinite(elapsed) or not 0 < elapsed <= 260:
            raise ValueError("Round recovery did not complete the requested bounded real-scene journey")


def isolated_env(root: Path) -> dict:
    env = dict(os.environ, RS_TEST_MODE="1")
    for key in ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
        directory = root / key.lower()
        directory.mkdir(parents=True, exist_ok=True)
        env[key] = str(directory)
    temporary = root / "temp"
    temporary.mkdir(parents=True, exist_ok=True)
    env.update(TEMP=str(temporary), TMP=str(temporary))
    return env


def write_gallery(out: Path, rows: list[dict], status: str) -> None:
    cards = []
    for row in rows:
        folder = row["folder"]
        pictures = []
        for name in ("play", "tutorial"):
            if (out / folder / (name + ".png")).is_file():
                path = html.escape(f"{folder}/{name}.png", quote=True)
                pictures.append(f'<a href="{path}"><img src="{path}" alt="{name}"></a>')
        title = html.escape(folder + (": PASS" if row["passed"] else ": FAIL"))
        errors = html.escape("\n".join(row["errors"]))
        cards.append(f'<article><h2>{title}</h2>{"".join(pictures)}<pre>{errors}</pre></article>')
    page = '<!doctype html><meta charset="utf-8"><title>Lifecycle validation</title><style>body{background:#101521;color:#eee;font:16px system-ui;padding:24px}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(480px,1fr));gap:20px}img{width:100%}pre{white-space:pre-wrap}h2{font-size:18px}</style>'
    (out / "index.html").write_text(page + f'<h1>Lifecycle validation: {status}</h1><main>' + "".join(cards) + '</main>', encoding="utf-8")


def cleanup_data(path: Path, out: Path) -> None:
    # Windows GPU drivers can finish cache writes just after the process exits.
    target = path.resolve()
    if target.parent != out.resolve() or not target.name.startswith("_run_data-"):
        raise ValueError("Refusing to remove a directory outside this run's output")
    for attempt in range(4):
        try:
            shutil.rmtree(target)
            return
        except FileNotFoundError:
            return
        except OSError:
            time.sleep(0.2 * (attempt + 1))
    print("Cleanup warning: temporary GPU cache retained in " + target.name, flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    parser.add_argument("--games", nargs="+", choices=GAMES, default=list(GAMES))
    parser.add_argument("--players", nargs="+", type=int, choices=(2, 4), default=[2, 4])
    parser.add_argument("--languages", nargs="+", choices=("zh", "en"), default=["zh"])
    parser.add_argument("--screenshots", action="store_true", help="capture play/tutorial layouts instead of the full control journey")
    parser.add_argument("--all-maps", action="store_true")
    parser.add_argument("--round-recovery", choices=("idle", "disconnected"), default="",
                        help="real archery/bowling deadline and bounded PLAY-to-RESULTS regression")
    parser.add_argument("--output", type=Path, default=ROOT / "audit-output/lifecycle")
    args = parser.parse_args()
    args.players = list(dict.fromkeys(args.players))
    args.languages = list(dict.fromkeys(args.languages))
    if args.round_recovery and (args.screenshots or any(game not in ("archery", "bowling") for game in args.games)):
        parser.error("--round-recovery requires --games archery/bowling without --screenshots")
    out = args.output.resolve()
    if args.round_recovery and out.exists():
        parser.error("--round-recovery requires a new output directory; preserve earlier results")
    out.mkdir(parents=True, exist_ok=True)
    godot = find_godot(args.godot)
    rows = []
    # Replace a previous PASS before discovery or a failed first case.
    summary = out / "summary.json"
    summary.write_text(json.dumps({"status": "RUNNING", "cases": []}), encoding="utf-8")
    write_gallery(out, [], "RUNNING")
    with tempfile.TemporaryDirectory(prefix="rs-lifecycle-catalog-") as temp:
        env = isolated_env(Path(temp))
        cases = discover_cases(godot, env, out, list(dict.fromkeys(args.games)))
    if not args.all_maps:
        cases = [case for case in cases if case["map"] == 0]
    expected = len(cases) * len(args.players) * len(args.languages)
    # All cases share only this suite's disposable user data, including the expensive GPU cache.
    cache = Path(tempfile.mkdtemp(prefix="_run_data-", dir=out))
    for case in cases:
        for players in args.players:
            for language in args.languages:
                stem = f'{case["game"]}-map{case["map"]}-{players}p-{language}'
                folder = out / stem
                folder.mkdir(exist_ok=True)
                report = folder / "result.json"
                for stale in (report, folder / "play.png", folder / "tutorial.png"):
                    stale.unlink(missing_ok=True)
                errors = []
                with nullcontext(cache) as temp:
                    env = isolated_env(Path(temp))
                    user = Path(env["APPDATA"] if os.name == "nt" else env["XDG_DATA_HOME"]) / ("Godot" if os.name == "nt" else "godot") / "app_userdata/Regina Sports"
                    user.mkdir(parents=True, exist_ok=True)
                    (user / "settings.cfg").write_text(f'[general]\nlanguage={int(language == "en")}\n[display]\nquality=0\n', encoding="utf-8")
                    command = [godot, "--path", str(ROOT / "game"), "res://tests/test_lifecycle.tscn", "--fixed-fps", "60",
                               "--log-file", str(folder / "engine-live.log")]
                    command += ["--resolution", "1600x900"] if args.screenshots else ["--headless"]
                    command += ["--", f'--lifecycle-game={case["game"]}', f"--lifecycle-players={players}",
                                f"--lifecycle-report={report}", f'--map={case["map"]}', "--static-menu"]
                    if args.screenshots:
                        command += ["--layout-only", f"--capture-output={folder}"]
                    if args.round_recovery:
                        command.append(f"--round-recovery={args.round_recovery}")
                    print("Starting " + stem, flush=True)
                    try:
                        result = run_engine(command, env=env, timeout=240)
                        log = result.stdout + result.stderr
                        if result.returncode:
                            errors.append(f"Engine exit: {result.returncode}")
                    except subprocess.TimeoutExpired as exc:
                        log = decode(exc.stdout) + decode(exc.stderr)
                        errors.append("Engine timed out")
                    except OSError as exc:
                        log = "ERROR: Cannot start engine: " + str(exc)
                    (folder / "game.log").write_text(log, encoding="utf-8")
                    engine, warnings = engine_errors(log)
                    errors += engine
                    if f'RS_LIFECYCLE_DONE: {case["game"]}/{players}' not in log.splitlines():
                        errors.append("Missing completion marker")
                    try:
                        validate_report(json.loads(report.read_text(encoding="utf-8")), case["game"], players, args.screenshots, args.round_recovery)
                        if any(Path(temp).rglob("records.cfg*")):
                            raise ValueError("Lifecycle wrote a records.cfg file or recovery copy")
                        if args.screenshots:
                            for name in (["play", "tutorial"] if players == 4 else ["play"]):
                                if png_size((folder / (name + ".png")).read_bytes()) != (1600, 900):
                                    raise ValueError("Expected a 1600x900 screenshot")
                    except (OSError, ValueError) as exc:
                        errors.append(str(exc))
                rows.append({**case, "players": players, "language": language, "passed": not errors,
                             "errors": errors, "environment_warnings": warnings, "folder": stem})
                status = "RUNNING" if len(rows) < expected else ("PASS" if all(r["passed"] for r in rows) else "FAIL")
                summary.write_text(json.dumps({"status": status, "expected": expected, "cases": rows}, ensure_ascii=False, indent=2), encoding="utf-8")
                write_gallery(out, rows, status)
                print(f'{stem}: {"PASS" if not errors else "FAIL"}', flush=True)
                if errors:
                    print("\n".join(errors), flush=True)
    if rows and all(row["passed"] for row in rows):
        cleanup_data(cache, out)
    else:
        print("Failed lifecycle data retained in " + cache.name, flush=True)
    return 0 if rows and all(row["passed"] for row in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
