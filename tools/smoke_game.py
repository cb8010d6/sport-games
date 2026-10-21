"""Load every shipped map and basketball split-screen with the real Godot runtime."""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ERROR = re.compile(r"(?:SCRIPT ERROR:|(?:^|\n)ERROR:|Parse Error:)")
SHUTDOWN_RESOURCES = re.compile(r"(?m)^ERROR: \d+ resources still in use at exit \(run with --verbose for details\)\.\n(?: +at: clear \(core/io/resource.cpp:\d+\)\n)?")


def checked_run(command: list[str], *, timeout: int = 180) -> str:
    result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, encoding="utf-8",
                            errors="replace", timeout=timeout)
    # Static resource caches currently emit this shutdown diagnostic. Keep it visible;
    # it is separate from the scene-load/runtime errors this startup check rejects.
    checked_output, shutdown_count = SHUTDOWN_RESOURCES.subn("", result.stdout)
    if result.returncode or ERROR.search(checked_output):
        raise RuntimeError("Godot check failed:\n" + result.stdout[-18000:])
    if shutdown_count:
        print("Warning: Godot reported resources retained at shutdown; startup check excludes this diagnostic.", flush=True)
    return result.stdout


def smoke_game(executable: Path, project: Path | None = None) -> None:
    command = [str(executable.resolve()), "--headless", "--fixed-fps", "60", "--quit-after", "600"]
    if project:
        command += ["--path", str(project.resolve())]
    cases = [("menu/main_menu", 0, 0)]
    cases += [(f"{game}/{game}_game", 0, 1) for game in ["plane", "archery", "bowling", "skate"]]
    cases += [("ski/ski_game", index, 1) for index in range(4)]
    cases += [("basketball/basketball_game", index, players) for index in range(2) for players in [1, 2, 4]]
    for scene, index, players in cases:
        args = ["--", f"--demo={players}", f"--map={index}"] if players else []
        checked_run(command + [f"res://scenes/{scene}.tscn"] + args)
        print(f"Passed: {scene}, map={index}, players={players or 'menu'}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("executable", type=Path)
    parser.add_argument("--project", type=Path)
    args = parser.parse_args()
    smoke_game(args.executable, args.project)
