"""Isolated in-game benchmark acceptance, including real 2/4-player short UI runs.

Only --unit-only uses headless mode. Rendered acceptance is not a performance baseline.
Import the project first; no imports or engine downloads are triggered by this runner.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import catalog
from engine_process import run_engine, silence_native_crash_dialogs
from smoke_test import png_size
from test_game import ROOT, find_godot

DIAGNOSTIC = re.compile(r"ERROR:|SCRIPT ERROR|Parse Error|FATAL|CRASH|leaked at exit|still in use at exit", re.IGNORECASE)
MARKER = re.compile(r"^RS_BENCHMARK_TEST: (unit|core|ui) players=(2|4) language=(0|1) checks=(\d+) failures=0$")


def player_files(user: Path) -> dict[str, str]:
    result = {}
    for path in user.rglob("*"):
        relative = path.relative_to(user)
        if not path.is_file() or relative.parts[0] in {"logs", "shader_cache"}:
            continue
        # Godot writes its device-specific pipeline cache at normal renderer shutdown.
        if relative.parent == Path("vulkan") and path.name.startswith("pipelines.") and path.suffix == ".cache":
            continue
        if relative.parts[0] == "benchmarks" and path.name in {"results.json", "samples.csv"}:
            continue
        result[relative.as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def install_sentinels(user: Path, language: int) -> dict[str, str]:
    user.mkdir(parents=True)
    configs = {
        "settings.cfg": f"[general]\nlanguage={language}\n[display]\nquality=1\nframe_rate=60\nwindow=0\nupscale=1\n",
        "override.cfg": '[benchmark_test]\nsentinel="preserve"\n',
        "profiles.cfg": '[benchmark_test]\nsentinel="profile-preserve"\n',
        "records.cfg": '[benchmark_test]\nsentinel="record-preserve"\n',
    }
    for name, text in configs.items():
        for suffix in ("", ".bak", ".tmp"):
            (user / (name + suffix)).write_text(text + f"; sentinel {name}{suffix}\n", encoding="utf-8")
    return player_files(user)


def validate_fixture_export(directory: Path) -> None:
    fixture = json.loads((directory / "results.json").read_text(encoding="utf-8"))
    samples = fixture["runs"][0]["samples"]
    stats = fixture["runs"][0]["statistics"]
    if not math.isclose(stats["avg_fps"], 40) or not math.isclose(stats["one_percent_low_fps"], 1000 / 94):
        raise ValueError("exported statistics differ from the known fixture")
    if [sample["frame_ms"] for sample in samples] != [1, 2, 3, 94] or any(sample["gpu_ms"] is not None for sample in samples):
        raise ValueError("fixture export changed the known samples or unavailable GPU values")
    with (directory / "samples.csv").open(encoding="utf-8", newline="") as stream:
        rows = list(csv.DictReader(stream))
    if len(rows) != 8:
        raise ValueError("CSV must retain four frames and both viewport rows")
    for row in rows:
        if row["viewport"] == "root" and row["gpu_viewport_ms"] != "":
            raise ValueError("unavailable GPU must remain empty in CSV")
        if row["viewport"] == "player_1" and float(row["gpu_viewport_ms"]) != 1.2:
            raise ValueError("CSV viewport timing differs from JSON")


def run_case(godot: str, output: Path, mode: str, players: int, language: int, screenshots: bool,
             gpu_index: int | None, full_duration: bool = False) -> dict[str, object]:
    name = f"{mode}-p{players}-{'zh' if language == 0 else 'en'}"
    directory = output / name
    directory.mkdir(parents=True, exist_ok=True)
    # Explicitly invalidate evidence from a previous invocation before launching.
    for stale in ("test-report.json", "options.png", "results.png", "results-end.png", "engine.log", "run.log", "ui-results.json", "ui-samples.csv"):
        (directory / stale).unlink(missing_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix="_benchmark-test-", dir=directory)).resolve()
    errors: list[str] = []
    outcome: dict[str, object] = {"case": name, "status": "FAIL", "errors": errors,
                                 "log": f"{name}/run.log", "report": f"{name}/test-report.json", "baseline": False,
                                 "full_duration": full_duration and mode == "ui"}
    try:
        env = {**os.environ, "RS_TEST_MODE": "1", "RS_BENCH_TEST_MODE": mode,
               "RS_BENCH_TEST_PLAYERS": str(players), "RS_BENCH_TEST_LANGUAGE": str(language),
               "RS_BENCH_TEST_OUTPUT": str(directory), "RS_BENCH_TEST_SCREENSHOTS": "1" if screenshots else "0",
               "RS_BENCH_TEST_FULL_DURATION": "1" if full_duration and mode == "ui" else "0"}
        for key, child in (("APPDATA", "roaming"), ("LOCALAPPDATA", "local"), ("XDG_DATA_HOME", "data"),
                           ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache")):
            target = temporary / child
            target.mkdir()
            env[key] = str(target)
        base = temporary / ("roaming/Godot" if os.name == "nt" else "data/godot")
        user = base / "app_userdata/Regina Sports"
        before = install_sentinels(user, language)
        env["RS_BENCH_TEST_USER"] = str(user)
        command = [godot, "--path", str(ROOT / "game"), "res://tests/test_benchmark.tscn",
                   "--resolution", "1600x900", "--log-file", str(directory / "engine.log")]
        if mode == "unit":
            command += ["--headless"]
        elif gpu_index is not None:
            command += ["--gpu-index", str(gpu_index)]
        log = ""
        exit_code = None
        try:
            # Three scenes each allow 120 s startup, plus warmup/sampling and cleanup.
            result = run_engine(command, env=env, timeout=(660 if full_duration else 540) if mode == "ui" else 240)
            log, exit_code = result.stdout + result.stderr, result.returncode
        except subprocess.TimeoutExpired as exc:
            def decode(value: str | bytes | None) -> str:
                return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value or ""
            log = decode(exc.stdout) + decode(exc.stderr)
            errors.append("engine timed out")
        except OSError as exc:
            errors.append(f"engine launch failed: {exc}")
        engine_log = directory / "engine.log"
        if engine_log.exists():
            log += "\n" + engine_log.read_text(encoding="utf-8", errors="replace")
        (directory / "run.log").write_text(log, encoding="utf-8")
        errors.extend(dict.fromkeys(line for line in log.splitlines() if DIAGNOSTIC.search(line)))
        # Engine log can duplicate stdout; require exactly one marker in stdout itself.
        markers = [MARKER.fullmatch(line) for line in (result.stdout.splitlines() if exit_code is not None else [])]
        matches = [match for match in markers if match]
        if (exit_code != 0 or len(matches) != 1 or int(matches[0][4]) < 10
                or matches[0].group(1, 2, 3) != (mode, str(players), str(language))):
            errors.append("missing successful, nonempty acceptance marker or nonzero exit")
        after = player_files(user)
        (directory / "protected-files.json").write_text(json.dumps({"before": before, "after": after}, indent=2), encoding="utf-8")
        if after != before:
            errors.append("player sentinels changed or an unexpected business file was created")
        try:
            report = json.loads((directory / "test-report.json").read_text(encoding="utf-8"))
            if not isinstance(report, dict):
                raise TypeError("acceptance report must be an object")
            if (report.get("mode"), report.get("players"), report.get("language"), report.get("failures"), report.get("baseline")) != (mode, players, language, 0, False):
                raise ValueError("acceptance report does not match requested case")
            if len(matches) != 1 or report.get("checks") != int(matches[0][4]):
                raise ValueError("report assertion count does not match process marker")
            validate_fixture_export(directory / "fixture-export")
            if mode == "ui":
                measured = json.loads((directory / "ui-results.json").read_text(encoding="utf-8"))["runs"]
                if [run["game"] for run in measured] != list(catalog.benchmark_ids()):
                    raise ValueError("retained UI export lost the actual three-scene sequence")
                for run in measured:
                    elapsed = sum(sample["frame_ms"] for sample in run["samples"]) / 1000
                    if (run["status"] != "PASS" or run["players"] != players or len(run["samples"]) < 2
                            or abs(elapsed - run["elapsed_seconds"]) > .00001
                            or run["duration_seconds"] != (30 if full_duration else .3)
                            or run["warmup_seconds"] != (10 if full_duration else .1)
                            or run["quality"] != (2 if full_duration else 0)):
                        raise ValueError("retained UI export differs from the requested measured case")
            if screenshots:
                for picture in ("options.png", "results.png", "results-end.png"):
                    if png_size((directory / picture).read_bytes()) != (1600, 900):
                        raise ValueError("wrong real UI screenshot resolution")
        except (OSError, ValueError, KeyError, TypeError, IndexError) as exc:
            errors.append(f"invalid acceptance evidence: {exc}")
        outcome["status"] = "FAIL" if errors else "PASS"
        return outcome
    finally:
        if temporary.parent != directory.resolve() or not temporary.name.startswith("_benchmark-test-"):
            raise ValueError("refusing cleanup outside disposable test data")
        for attempt in range(4):
            try:
                shutil.rmtree(temporary)
                break
            except FileNotFoundError:
                break
            except OSError:
                time.sleep(.1 * (attempt + 1))
        else:
            errors.append("isolated test data could not be removed")
        if errors:
            outcome["status"] = "FAIL"


def main() -> int:
    silence_native_crash_dialogs()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    parser.add_argument("--screenshots", action="store_true")
    parser.add_argument("--unit-only", action="store_true")
    parser.add_argument("--full-duration", action="store_true", help="UI cases use shipping 10/30 s windows at high quality")
    parser.add_argument("--players", type=int, nargs="+", choices=(2, 4), default=[2, 4])
    parser.add_argument("--gpu-index", type=int)
    parser.add_argument("--output", type=Path, default=ROOT / "audit-output/benchmark-tests")
    args = parser.parse_args()
    if sys.platform not in {"win32", "linux"}:
        parser.error("this runner isolates Windows APPDATA or Linux XDG user data only")
    if args.unit_only and args.screenshots:
        parser.error("screenshots require real rendered UI cases")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    (output / "summary.json").write_text(json.dumps({"status": "RUNNING", "baseline": False, "runs": []}) + "\n", encoding="utf-8")
    godot = find_godot(args.godot)
    cases = [("unit", 2, 0, False)]
    if not args.unit_only:
        cases += [("core", players, 0, False) for players in dict.fromkeys(args.players)]
        cases += [("ui", players, language, args.screenshots) for players in dict.fromkeys(args.players)
                  for language in ((0, 1) if args.screenshots else (0,))]
    rows = []
    for mode, players, language, screenshots in cases:
        row = run_case(godot, output, mode, players, language, screenshots, args.gpu_index, args.full_duration)
        rows.append(row)
        status = "FAIL" if any(row["status"] == "FAIL" for row in rows) else "PASS" if len(rows) == len(cases) else "RUNNING"
        (output / "summary.json").write_text(json.dumps({"status": status, "baseline": False, "runs": rows}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"{row['case']}: {row['status']}", flush=True)
        if row["errors"]:
            print("\n".join(row["errors"]))
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
