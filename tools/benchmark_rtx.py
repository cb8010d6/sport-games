"""Run raster/RTX comparisons without publishing a headless run as GPU evidence."""
import argparse
import json
import subprocess
from pathlib import Path

from smoke_game import checked_run

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("godot", type=Path)
parser.add_argument("--output", type=Path, default=ROOT / "audit-output/rtx")
parser.add_argument("--driver", choices=["vulkan", "d3d12"], default="vulkan")
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
for map_index in range(2):
    for players in [1, 2, 4]:
        for mode in ["raster", "rtx"]:
            report = (args.output / f"map{map_index}-{players}p-{mode}.json").resolve()
            report.unlink(missing_ok=True)
            command = [str(args.godot.resolve()), "--path", str(ROOT / "game"),
                       "--rendering-method", "forward_plus", "--rendering-driver", args.driver,
                       "--resolution", "1600x900", "res://experiments/rtx/basketball_rtx.tscn", "--",
                       f"--demo={players}", f"--map={map_index}", f"--render-mode={mode}",
                       "--warmup=12", "--duration=20", f"--report={report.as_posix()}"]
            try:
                output = checked_run(command, timeout=150)
            except (RuntimeError, subprocess.TimeoutExpired) as error:
                report.with_suffix(".txt").write_text(str(error), encoding="utf-8")
                raise SystemExit("Benchmark stopped: inspect the isolated report/log.") from error
            report.with_suffix(".txt").write_text(output, encoding="utf-8")
            data = json.loads(report.read_text()) if report.exists() else {"status": "failed_no_report"}
            print(report.name, data["status"], flush=True)
            if data.get("status") != "measured":
                raise SystemExit("Benchmark stopped: inspect local report/log; no successful RTX result is claimed.")
