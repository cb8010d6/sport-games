"""Serial, rendered Godot benchmarks; raw evidence and strict validation, no dependencies."""
from __future__ import annotations

import argparse
import itertools
import json
import math
import os
import re
import statistics
import subprocess
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from engine_process import run_engine
from test_game import find_godot

ROOT = Path(__file__).resolve().parents[1]
GAMES = ("plane", "archery", "bowling", "skate", "ski", "basketball")
RESOLUTIONS = ("1600x900", "1920x1080", "2560x1440", "2560x1080", "3840x2160")
DIAGNOSTIC = re.compile(r"ERROR:|SCRIPT ERROR|Parse Error|FATAL|CRASH|leaked at exit|still in use at exit", re.IGNORECASE)


@dataclass(frozen=True)
class Case:
    game: str
    map: int
    players: int
    quality: int
    repeat: int

    @property
    def name(self) -> str:
        return f"{self.game}-m{self.map}-p{self.players}-q{self.quality}-r{self.repeat}"


def finite(value: Any, minimum: float = 0, *, positive: bool = False) -> bool:
    return (type(value) in (int, float) and math.isfinite(value)
            and (value > minimum if positive else value >= minimum))


def number(value: str) -> float:
    parsed = float(value)
    if not finite(parsed):
        raise argparse.ArgumentTypeError("must be finite and nonnegative")
    return parsed


def natural(value: str) -> int:
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be nonnegative")
    return parsed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", help="Godot executable (otherwise REGINA_GODOT / local discovery)")
    parser.add_argument("--games", nargs="+", choices=GAMES, default=list(GAMES))
    parser.add_argument("--maps", nargs="+", type=natural, default=[0])
    parser.add_argument("--players", nargs="+", type=int, choices=(1, 2, 4), default=[1, 2, 4])
    parser.add_argument("--quality", nargs="+", type=int, choices=range(4), default=[2])
    parser.add_argument("--repeat", type=natural, default=3)
    parser.add_argument("--warmup", type=number, default=10.0)
    parser.add_argument("--duration", type=number, default=30.0)
    parser.add_argument("--timeout", type=number, help="per-process seconds, including loading and warmup")
    parser.add_argument("--gpu-index", type=natural)
    parser.add_argument("--expect-gpu", help="required case-insensitive substring of the actual GPU name")
    parser.add_argument("--seed", type=natural, default=20261023)
    parser.add_argument("--resolution", choices=RESOLUTIONS, default=RESOLUTIONS[0],
                        help="windowed client size; the run fails if the display cannot hold it")
    parser.add_argument("--output", type=Path, default=ROOT / "audit-output" / "bench")
    return parser


def expand_matrix(args: argparse.Namespace) -> list[Case]:
    axes = [dict.fromkeys(getattr(args, key)) for key in ("games", "maps", "players", "quality")]
    return [Case(*values, repeat) for values in itertools.product(*axes) for repeat in range(1, args.repeat + 1)]


def summarize_samples(samples: list[dict[str, Any]]) -> dict[str, Any]:
    times = sorted(sample["frame_ms"] for sample in samples)
    n = len(times)

    def percentile(p: float) -> float:
        position = (n - 1) * p
        lower = math.floor(position)
        return times[lower] + (times[math.ceil(position)] - times[lower]) * (position - lower)

    gpu = [sample["gpu_ms"] for sample in samples if sample["gpu_ms"] is not None]
    return {"avg_fps": 1000 * n / math.fsum(times), "frame_ms_p50": percentile(.50),
            "frame_ms_p95": percentile(.95), "frame_ms_p99": percentile(.99), "frame_ms_worst": times[-1],
            "one_percent_low_fps": 1000 / statistics.mean(times[-math.ceil(n * .01):]),
            "cpu_process_ms_avg": statistics.mean(sample["cpu_process_ms"] for sample in samples),
            "gpu_ms_avg": statistics.mean(gpu) if gpu else None, "gpu_samples": len(gpu),
            "draw_calls_avg": statistics.mean(sample["draw_calls"] for sample in samples),
            "video_memory_bytes_max": max(sample["video_memory_bytes"] for sample in samples),
            "nodes_max": max(sample["nodes"] for sample in samples)}


def resolution(args: argparse.Namespace) -> list[int]:
    return [int(value) for value in args.resolution.split("x")]


def validate_report(report: Any, case: Case, args: argparse.Namespace) -> None:
    """Reject incomplete, mismatched or invented measurements before computing any statistic."""
    def require(condition: bool, message: str) -> None:
        if not condition:
            raise ValueError(message)

    require(isinstance(report, dict), "report must be an object")
    require(type(report.get("schema_version")) is int and report["schema_version"] == 1, "schema_version must be 1")
    require(report.get("status") == "PASS" and report.get("errors") == [], "runner did not report an error-free PASS")
    for key in ("game", "map", "players", "quality"):
        expected = getattr(case, key)
        require(type(report.get(key)) is type(expected) and report[key] == expected, f"mismatched {key}")
    for key, expected in (("warmup_seconds", args.warmup), ("duration_seconds", args.duration)):
        require(finite(report.get(key)) and math.isclose(report[key], expected, abs_tol=1e-6), f"mismatched {key}")
    elapsed = report.get("elapsed_seconds")
    require(finite(elapsed, positive=True) and elapsed >= args.duration, "measurement ended before requested duration")
    require(elapsed <= args.duration + max(2, args.duration * .1), "measurement duration overshot excessively")
    samples = report.get("samples")
    require(isinstance(samples, list) and len(samples) >= 2, "at least two frame samples required")
    require(type(report.get("frames")) is int and report["frames"] == len(samples), "frames must equal sample count")
    for index, sample in enumerate(samples):
        require(isinstance(sample, dict), f"sample {index} must be an object")
        for key in ("frame_ms", "cpu_process_ms", "gpu_ms"):
            value = sample.get(key)
            require(key in sample and (key == "gpu_ms" and value is None or finite(value, positive=key != "cpu_process_ms")),
                    f"invalid sample {index} {key}; unavailable GPU timings must be null")
        for key in ("draw_calls", "video_memory_bytes", "nodes"):
            value = sample.get(key)
            require(finite(value) and value == int(value), f"invalid sample {index} {key}")
        for key in ("gpu_viewports_ms", "cpu_render_viewports_ms"):
            values = sample.get(key)
            require(isinstance(values, dict) and all(isinstance(name, str) and name for name in values),
                    f"invalid sample {index} {key}")
            require(all(value is None or finite(value, positive=key == "gpu_viewports_ms") for value in values.values()),
                    f"invalid sample {index} {key} timing")
    measured = math.fsum(sample["frame_ms"] for sample in samples) / 1000
    require(abs(measured - elapsed) <= max(.05, elapsed * .02), "sample time does not match elapsed time")
    metadata = report.get("metadata")
    require(isinstance(metadata, dict), "metadata must be an object")
    for key in ("gpu", "rendering_method", "rendering_driver", "godot_version"):
        require(isinstance(metadata.get(key), str) and bool(metadata[key].strip()), f"missing metadata {key}")
    require(metadata.get("driver") is None or isinstance(metadata["driver"], str), "invalid driver metadata")
    require(metadata["rendering_driver"].lower() not in ("dummy", "headless"), "benchmark requires actual rendering")
    require(metadata.get("resolution") == resolution(args) and all(type(x) is int for x in metadata["resolution"]),
            f"actual resolution must be {args.resolution}")
    require(type(metadata.get("seed")) is int and metadata["seed"] == args.seed, "mismatched seed")
    require(isinstance(metadata.get("reproducibility"), dict), "missing reproducibility conditions")
    require(not args.expect_gpu or args.expect_gpu.casefold() in metadata["gpu"].casefold(), "actual GPU does not match --expect-gpu")


def power_status() -> dict[str, Any]:
    """Read Windows power state without changing any system setting."""
    if os.name != "nt":
        return {"ac": "UNKNOWN", "battery_percent": None}
    import ctypes

    class Power(ctypes.Structure):
        _fields_ = [("ac", ctypes.c_ubyte), ("flags", ctypes.c_ubyte), ("percent", ctypes.c_ubyte),
                    ("reserved", ctypes.c_ubyte), ("life", ctypes.c_uint32), ("full", ctypes.c_uint32)]

    value = Power()
    if not ctypes.windll.kernel32.GetSystemPowerStatus(ctypes.byref(value)):
        return {"ac": "UNKNOWN", "battery_percent": None}
    return {"ac": {0: "OFFLINE", 1: "ONLINE"}.get(value.ac, "UNKNOWN"),
            "battery_percent": value.percent if value.percent <= 100 else None}


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def json_float(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed):
        raise ValueError(f"nonfinite JSON number: {value}")
    return parsed


def decode(value: str | bytes | None) -> str:
    return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value or ""


def source_revision() -> dict[str, Any]:
    try:
        command = ["git", "-c", f"safe.directory={ROOT.as_posix()}", "-C", str(ROOT)]
        revision = subprocess.run([*command, "rev-parse", "HEAD"], capture_output=True, text=True, check=True, timeout=5)
        dirty = subprocess.run([*command, "status", "--porcelain"], capture_output=True, text=True, check=True, timeout=5)
        return {"source_commit": revision.stdout.strip(), "source_dirty": bool(dirty.stdout.strip())}
    except (OSError, subprocess.SubprocessError):
        return {"source_commit": None, "source_dirty": None}


def run_case(godot: str, case: Case, args: argparse.Namespace, output: Path) -> dict[str, Any]:
    directory = output / case.name
    directory.mkdir(parents=True, exist_ok=True)
    raw_path = directory / "raw.json"
    # A new RUNNING document invalidates any previous PASS even if launch is interrupted.
    write_json(raw_path, {"status": "RUNNING", **asdict(case)})
    pending = directory / "engine.json"
    for name in ("engine.json", "engine-output.txt", "engine.log", "run.log"):
        (directory / name).unlink(missing_ok=True)
    command = [godot, "--path", str(ROOT / "game"), "--resolution", args.resolution,
               "--script", "res://tests/bench_runner.gd", "--log-file", str(directory / "engine.log")]
    if args.gpu_index is not None:
        command += ["--gpu-index", str(args.gpu_index)]
    command += ["--", f"--bench-game={case.game}", f"--demo={case.players}", f"--map={case.map}",
                f"--bench-quality={case.quality}", f"--bench-warmup={args.warmup}",
                f"--bench-duration={args.duration}", f"--bench-output={pending}", f"--bench-seed={args.seed}",
                f"--bench-resolution={args.resolution}"]
    errors: list[str] = []
    before = power_status()
    if before.get("ac") == "OFFLINE":
        errors.append("AC power is OFFLINE before launch; engine was not started")
        metadata = {**source_revision(), "power_before": before, "power_after": None,
                    "power_endpoints_online": False, "requested_gpu_index": args.gpu_index}
        write_json(raw_path, {"schema_version": 1, "status": "FAIL", "runner_status": None,
                              "runner_errors": None, "errors": errors, "exit_code": None, "timeout": False,
                              **asdict(case), "warmup_seconds": args.warmup, "duration_seconds": args.duration,
                              "elapsed_seconds": 0.0, "frames": 0, "samples": [], "metadata": metadata})
        (directory / "run.log").write_text(errors[0] + "\n", encoding="utf-8")
        return {**asdict(case), "status": "FAIL", "errors": errors, "raw": f"{case.name}/raw.json",
                "log": f"{case.name}/run.log", "metadata": metadata,
                "expected_repeats": args.repeat, "statistics": None}
    stdout = stderr = ""
    exit_code = None
    timed_out = False
    with tempfile.TemporaryDirectory(prefix="regina-bench-") as userdata:
        env = {**os.environ, "RS_TEST_MODE": "1", "RS_BENCH_USER_ROOT": userdata}
        for key, child in (("APPDATA", "roaming"), ("LOCALAPPDATA", "local"), ("XDG_DATA_HOME", "data"),
                           ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache")):
            target = Path(userdata) / child
            target.mkdir()
            env[key] = str(target)
        try:
            result = run_engine(command, env=env, timeout=args.timeout or args.warmup + args.duration + 120)
            stdout, stderr, exit_code = decode(result.stdout), decode(result.stderr), result.returncode
            if exit_code != 0:
                errors.append(f"engine exited with code {exit_code}")
        except subprocess.TimeoutExpired as exc:
            stdout, stderr, timed_out = decode(exc.stdout), decode(exc.stderr), True
            errors.append("engine timed out")
        except OSError as exc:
            errors.append(f"engine launch failed: {exc}")
    log = stdout + "\n" + stderr
    if (directory / "engine.log").exists():
        log += "\n" + (directory / "engine.log").read_text(encoding="utf-8", errors="replace")
    (directory / "run.log").write_text(log, encoding="utf-8")
    errors.extend(dict.fromkeys(line.strip() for line in log.splitlines() if DIAGNOSTIC.search(line)))
    if f"RS_BENCH_DONE: {case.game}" not in stdout.splitlines():
        errors.append("missing completion marker")
    report: dict[str, Any] = {}
    try:
        text = pending.read_text(encoding="utf-8")
        (directory / "engine-output.txt").write_text(text, encoding="utf-8")
        payload = json.loads(text, parse_constant=json_float, parse_float=json_float)
        if isinstance(payload, dict):
            report = payload
        validate_report(payload, case, args)
    except (OSError, ValueError) as exc:
        errors.append(f"invalid runner report: {exc}")
    finally:
        pending.unlink(missing_ok=True)
    metadata = report.get("metadata") if isinstance(report.get("metadata"), dict) else {}
    report["metadata"] = metadata
    after = power_status()
    if after.get("ac") == "OFFLINE":
        errors.append("AC power is OFFLINE after engine run; measurement is invalid")
    metadata.update({**source_revision(), "power_before": before, "power_after": after,
                     "power_endpoints_online": before.get("ac") == "ONLINE" and after.get("ac") == "ONLINE",
                     "requested_gpu_index": args.gpu_index})
    runner_status, runner_errors = report.get("status"), report.get("errors")
    report.update({"schema_version": 1, "status": "FAIL" if errors else "PASS", "runner_status": runner_status,
                   "runner_errors": runner_errors, "errors": errors, "exit_code": exit_code, "timeout": timed_out, **asdict(case)})
    write_json(raw_path, report)
    return {**asdict(case), "status": report["status"], "errors": errors, "raw": f"{case.name}/raw.json",
            "log": f"{case.name}/run.log", "metadata": metadata,
            "expected_repeats": args.repeat, "statistics": summarize_samples(report["samples"]) if not errors else None}


def write_reports(output: Path, rows: list[dict[str, Any]], expected: int, *, fatal: str | None = None) -> None:
    status = "FAIL" if fatal or any(row["status"] == "FAIL" for row in rows) else "PASS" if len(rows) == expected else "RUNNING"
    groups = []
    for key, members in itertools.groupby(sorted(rows, key=lambda row: tuple(row[k] for k in ("game", "map", "players", "quality"))),
                                         key=lambda row: tuple(row[k] for k in ("game", "map", "players", "quality"))):
        runs = list(members)
        valid = [run for run in runs if run["statistics"] is not None]
        fps = [run["statistics"]["avg_fps"] for run in valid]
        samples = list(itertools.chain.from_iterable(json.loads((output / run["raw"]).read_text(encoding="utf-8"))["samples"] for run in valid))
        stats = summarize_samples(samples) if samples else None
        target = {2: 60, 4: 45}.get(key[2])
        required = runs[0]["expected_repeats"]
        groups.append({**dict(zip(("game", "map", "players", "quality"), key, strict=True)),
                       "valid_runs": len(valid), "completed_runs": len(runs), "statistics": stats,
                       "expected_runs": required,
                       "repeat_fps_min": min(fps) if fps else None, "repeat_fps_max": max(fps) if fps else None,
                       "target_fps": target, "target_status": "INVALID" if len(valid) != required
                       else "N/A" if target is None else "MET" if min(fps) >= target else "BELOW_TARGET"})
    write_json(output / "summary.json", {"schema_version": 1, "status": status, "expected": expected,
                                         "completed": len(rows), "errors": [fatal] if fatal else [], "runs": rows, "groups": groups})
    lines = [f"# Rendered benchmark: {status}", "", "Reference targets: Radeon 780M, 2p 60 fps / 4p 45 fps. Actual devices are recorded per run.",
             "A PASS means valid measurement, independent of the performance target. Every repeat must meet its target.",
             "R7 frame-time percentiles; 1% low = 1000 / mean(slowest ceil(N*0.01) frame ms). GPU null means unavailable.",
             "", "| Game/map/players/quality | Valid runs | Avg FPS | 1% low | p95 ms | p99 ms | Worst ms | Repeat FPS range | Target |",
             "|---|---:|---:|---:|---:|---:|---:|---|---|"]
    for group in groups:
        stats = group["statistics"]
        values = [f"{stats[key]:.2f}" if stats else "—" for key in
                  ("avg_fps", "one_percent_low_fps", "frame_ms_p95", "frame_ms_p99", "frame_ms_worst")]
        span = f"{group['repeat_fps_min']:.2f}–{group['repeat_fps_max']:.2f}" if stats else "—"
        lines.append(f"| {group['game']}/{group['map']}/{group['players']}/{group['quality']} | {group['valid_runs']}/{group['expected_runs']} | "
                     + " | ".join(values) + f" | {span} | {group['target_status']} |")
    for row in rows:
        if row["errors"]:
            lines += ["", f"- {row['raw']}: " + "; ".join(row["errors"])]
    if fatal:
        lines += ["", fatal]
    (output / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.repeat == 0 or args.duration == 0 or args.timeout == 0 or args.expect_gpu == "":
        parser.error("repeat, duration and timeout must be positive; expect-gpu must not be empty")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    cases = expand_matrix(args)
    rows: list[dict[str, Any]] = []
    write_reports(output, rows, len(cases))
    try:
        godot = find_godot(args.godot)
        for case in cases:
            print(f"Benchmark {case.name}", flush=True)
            rows.append(run_case(godot, case, args, output))
            write_reports(output, rows, len(cases))
    except (OSError, ValueError, KeyboardInterrupt, SystemExit) as exc:
        write_reports(output, rows, len(cases), fatal=str(exc) or "interrupted")
        return 1
    return int(any(row["status"] != "PASS" for row in rows))


if __name__ == "__main__":
    raise SystemExit(main())
