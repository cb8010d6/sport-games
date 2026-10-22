"""Run complete bot rounds on real maps and validate their results.

python tools/smoke_test.py --players 2 --all-maps
python tools/smoke_test.py --games ski --map 3 --players 4
python tools/smoke_test.py --screenshots --players 4 --language en
JSON/HTML reports go to audit-output/smoke/. Screenshot mode embeds captures in one SVG.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import html
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import time

from test_game import ROOT, find_godot, run_engine, silence_native_crash_dialogs

GAMES = ("plane", "archery", "bowling", "skate", "ski", "basketball")


def engine_errors(log: str) -> tuple[list[str], list[str]]:
    errors = [line for line in log.splitlines() if line.startswith(("ERROR:", "SCRIPT ERROR:"))]
    errors += [line for line in log.splitlines() if line.startswith("WARNING:") and "leaked at exit" in line]
    # Windows sandboxes can deny the system certificate store; report this separately.
    environment = [line for line in errors if "Failed to read the root certificate store" in line]
    return [line for line in errors if line not in environment], environment


def validate_catalog(value: object, games: list[str]) -> list[dict]:
    if not isinstance(value, list) or not value:
        raise ValueError("Smoke catalog must be a non-empty list")
    seen: dict[str, list[int]] = {game: [] for game in games}
    for case in value:
        if not isinstance(case, dict) or not isinstance(case.get("game"), str) or case["game"] not in seen:
            raise ValueError("Unexpected game in smoke catalog")
        game = case["game"]
        index = case.get("map")
        if type(index) is not int or index < 0 or index in seen[game]:
            raise ValueError("Invalid or duplicate map in smoke catalog")
        if case.get("scene") != f"res://scenes/{game}/{game}_game.tscn":
            raise ValueError("Unexpected scene in smoke catalog")
        if not isinstance(case.get("map_name"), str) or not case["map_name"]:
            raise ValueError("Missing map name in smoke catalog")
        seen[game].append(index)
    if any(not maps or sorted(maps) != list(range(len(maps))) for maps in seen.values()):
        raise ValueError("Smoke catalog has missing games or non-contiguous maps")
    return value


def validate_result(value: object, game: str, map_index: int, players: int) -> None:
    if not isinstance(value, dict) or value.get("game") != game or value.get("phase") != "results":
        raise ValueError("Report does not describe the requested game's results")
    if type(value.get("map")) is not int or value["map"] != map_index:
        raise ValueError("Report map does not match the requested map")
    scores = value.get("players")
    if not isinstance(scores, list) or len(scores) != players:
        raise ValueError("Report player count does not match the requested count")
    slots = []
    for player in scores:
        if not isinstance(player, dict) or type(player.get("slot")) is not int:
            raise ValueError("Invalid player slot in report")
        score = player.get("score")
        if type(score) not in (int, float) or (type(score) is float and not math.isfinite(score)):
            raise ValueError("Invalid or non-finite score in report")
        slots.append(player["slot"])
    if sorted(slots) != list(range(1, players + 1)):
        raise ValueError("Report player slots are missing, duplicated or out of range")


def png_size(data: bytes) -> tuple[int, int]:
    if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[8:16] != b"\0\0\0\rIHDR":
        raise ValueError("Screenshot is not a PNG image")
    width, height = struct.unpack(">II", data[16:24])
    if width < 1 or height < 1:
        raise ValueError("Screenshot has invalid dimensions")
    at, has_pixels = 8, False
    while at + 12 <= len(data):
        length = struct.unpack(">I", data[at:at + 4])[0]
        end = at + length + 12
        if end > len(data):
            break
        kind = data[at + 4:at + 8]
        if binascii.crc32(data[at + 4:end - 4]) != struct.unpack(">I", data[end - 4:end])[0]:
            raise ValueError("Screenshot has a corrupt PNG chunk")
        has_pixels = has_pixels or (kind == b"IDAT" and length > 0)
        if kind == b"IEND":
            if length == 0 and has_pixels and end == len(data):
                return width, height
            break
        at = end
    raise ValueError("Screenshot PNG is incomplete")


def write_reports(output: Path, rows: list[dict], screenshots: bool, total: int) -> None:
    complete = len(rows) == total
    status = ("PASS" if all(row["passed"] for row in rows) else "FAIL") if complete else "RUNNING"
    (output / "run.json").write_text(json.dumps({"status": status, "expected": total, "completed": len(rows)}), encoding="utf-8")
    (output / "summary.json").write_text(json.dumps(rows, indent=2, ensure_ascii=False), encoding="utf-8")
    cards, svg = [], []
    columns, card_w, card_h = 2, 800, 510
    for i, row in enumerate(rows):
        title = f'{row["game"]} / map {row["map"]}: {row["map_name"]} / {row["players"]} players'
        status = "PASS" if row["passed"] else "FAIL"
        shot = row["screenshot"]
        image = f'<img src="{html.escape(shot, quote=True)}" alt="{html.escape(title, quote=True)}">' if shot else ""
        errors = html.escape("\n".join(row["errors"]))
        warnings = html.escape("\n".join(row["environment_warnings"]))
        cards.append(f'<article><h2>{html.escape(title)}: {status}</h2>{image}<pre>{errors}</pre><details><summary>Environment warnings</summary><pre>{warnings}</pre></details></article>')
        if screenshots:
            x, y = (i % columns) * card_w, (i // columns) * card_h + 50
            color = "#86efac" if row["passed"] else "#fca5a5"
            svg.append(f'<text x="{x + 16}" y="{y + 24}" fill="{color}" font-size="18">{html.escape(title)}: {status}</text>')
            if shot:
                encoded = base64.b64encode((output / shot).read_bytes()).decode("ascii")
                svg.append(f'<image x="{x + 12}" y="{y + 40}" width="776" height="450" preserveAspectRatio="xMidYMid meet" href="data:image/png;base64,{encoded}"/>')
            else:
                svg.append(f'<text x="{x + 16}" y="{y + 80}" fill="#fca5a5" font-size="24">NO SCREENSHOT</text>')
    montage_link = '<p><a href="contact-sheet.svg">Self-contained screenshot contact sheet</a></p>' if screenshots else ""
    heading = f"Regina Sports smoke tests: {status} ({len(rows)}/{total})"
    (output / "index.html").write_text('<!doctype html><meta charset="utf-8"><title>Regina Sports smoke tests</title><style>body{background:#101521;color:#eee;font:16px system-ui;padding:24px}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(360px,1fr));gap:20px}img{width:100%}pre{white-space:pre-wrap}</style><h1>' + heading + '</h1>' + montage_link + '<main>' + "".join(cards) + '</main>', encoding="utf-8")
    montage = output / "contact-sheet.svg"
    if screenshots:
        height = ((len(rows) + columns - 1) // columns) * card_h + 50
        montage.write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="{height}" viewBox="0 0 1600 {height}"><rect width="100%" height="100%" fill="#101521"/><text x="16" y="30" fill="white" font-size="24">{heading}</text>' + "".join(svg) + '</svg>', encoding="utf-8")
    else:
        montage.unlink(missing_ok=True)


def decode(value: bytes | str | None) -> str:
    return value.decode("utf-8", "replace") if isinstance(value, bytes) else (value or "")


def discover_cases(godot: str, env: dict, output: Path, games: list[str]) -> list[dict]:
    catalog = output / "cases.json"
    catalog.unlink(missing_ok=True)
    command = [godot, "--headless", "--path", str(ROOT / "game"), "res://tests/smoke_catalog.tscn",
               "--", f"--catalog-output={catalog}", "--games=" + ",".join(games)]
    try:
        result = run_engine(command, env=env, timeout=60)
    except subprocess.TimeoutExpired as exc:
        (output / "catalog.log").write_text(decode(exc.stdout) + decode(exc.stderr), encoding="utf-8")
        raise ValueError("Map discovery timed out; see catalog.log") from exc
    log = result.stdout + result.stderr
    (output / "catalog.log").write_text(log, encoding="utf-8")
    errors, _ = engine_errors(log)
    if result.returncode or "RS_SMOKE_CATALOG_DONE" not in log or errors:
        raise ValueError("Map discovery failed; see catalog.log (import the project first)")
    return validate_catalog(json.loads(catalog.read_text(encoding="utf-8")), games)


def main() -> int:
    silence_native_crash_dialogs()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    parser.add_argument("--players", type=int, choices=(1, 2, 3, 4), default=2)
    parser.add_argument("--games", nargs="+", choices=GAMES, default=list(GAMES))
    maps = parser.add_mutually_exclusive_group()
    maps.add_argument("--all-maps", action="store_true")
    maps.add_argument("--map", type=int, default=0, dest="map_index")
    parser.add_argument("--language", choices=("zh", "en"), default="zh")
    parser.add_argument("--screenshots", action="store_true")
    parser.add_argument("--timeout", type=float, default=240)
    parser.add_argument("--output", type=Path, default=ROOT / "audit-output" / "smoke")
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and greater than zero")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Clear reports before discovery so a failed run cannot leave an old PASS summary.
    for filename in ("run.json", "summary.json", "index.html", "contact-sheet.svg"):
        (output / filename).unlink(missing_ok=True)
    godot = find_godot(args.godot)
    games = list(dict.fromkeys(args.games))
    with tempfile.TemporaryDirectory(prefix="rs-catalog-") as temp:
        env = dict(os.environ, APPDATA=temp, XDG_DATA_HOME=temp, XDG_CONFIG_HOME=temp, XDG_CACHE_HOME=temp)
        try:
            cases = discover_cases(godot, env, output, games)
        except (ValueError, OSError, subprocess.TimeoutExpired) as exc:
            print(f"Catalog failed: {exc}")
            return 1
    if not args.all_maps:
        cases = [case for case in cases if case["map"] == args.map_index]
        missing = set(games) - {case["game"] for case in cases}
        if missing:
            parser.error(f'--map {args.map_index} is unavailable for: {", ".join(sorted(missing))}')
    print(f"Discovered {len(cases)} cases for {args.players} players", flush=True)
    rows = []
    write_reports(output, rows, args.screenshots, len(cases))
    for case in cases:
        game, index = case["game"], case["map"]
        stem = game if index == 0 else f"{game}-map{index}"
        report = output / f"{stem}.json"
        shot = output / f"{stem}.png"
        report.unlink(missing_ok=True)
        shot.unlink(missing_ok=True)
        with tempfile.TemporaryDirectory(prefix="rs-smoke-") as temp:
            env = dict(os.environ, APPDATA=temp, XDG_DATA_HOME=temp, XDG_CONFIG_HOME=temp, XDG_CACHE_HOME=temp)
            user = Path(temp) / ("Godot/app_userdata/Regina Sports" if os.name == "nt" else "godot/app_userdata/Regina Sports")
            user.mkdir(parents=True, exist_ok=True)
            (user / "settings.cfg").write_text(f'[general]\nlanguage={int(args.language == "en")}\n[display]\nquality=0\n', encoding="utf-8")
            command = [godot, "--path", str(ROOT / "game"), case["scene"]]
            command += ["--resolution", "1600x900"] if args.screenshots else ["--headless", "--fixed-fps", "60"]
            command += ["--", f"--demo={args.players}", f"--map={index}", f"--smoke-report={report}"]
            if args.screenshots:
                command.append(f"--smoke-shot={shot}")
            start = time.monotonic()
            timed_out = False
            try:
                result = run_engine(command, env=env, timeout=args.timeout)
                log = result.stdout + result.stderr
                code = result.returncode
            except subprocess.TimeoutExpired as exc:
                timed_out = True
                log = decode(exc.stdout) + decode(exc.stderr)
                code = -1
            except OSError as exc:
                log = f"ERROR: Cannot start engine: {exc}"
                code = -1
            (output / f"{stem}.log").write_text(log, encoding="utf-8")
            errors, environment = engine_errors(log)
            if code != 0:
                errors.append(f"Engine timed out after {args.timeout}s" if timed_out else f"Engine exited with code {code}")
            if f"RS_SMOKE_DONE: {game}" not in log.splitlines():
                errors.append("Engine did not emit the completion marker")
            try:
                validate_result(json.loads(report.read_text(encoding="utf-8")), game, index, args.players)
            except (ValueError, OSError) as exc:
                errors.append(f"Invalid result report: {exc}")
            valid_shot = None
            if args.screenshots:
                try:
                    dimensions = png_size(shot.read_bytes())
                    if dimensions != (1600, 900):
                        raise ValueError(f"Expected 1600x900 screenshot, got {dimensions}")
                    valid_shot = shot.name
                except (ValueError, OSError) as exc:
                    errors.append(f"Invalid screenshot: {exc}")
            row = {**case, "players": args.players, "passed": not errors, "timeout": timed_out,
                   "seconds": round(time.monotonic() - start, 2), "errors": errors,
                   "environment_warnings": environment, "screenshot": valid_shot}
            rows.append(row)
            print(f'{stem}: {"PASS" if row["passed"] else "FAIL"} ({row["seconds"]}s)', flush=True)
            write_reports(output, rows, args.screenshots, len(cases))
    return 0 if all(row["passed"] for row in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
