"""Load every shipped map and basketball split-screen with the real Godot runtime."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
from contextlib import contextmanager
from pathlib import Path

if __package__:
    from . import catalog
    from .engine_process import run_engine
else:
    import catalog
    from engine_process import run_engine

ROOT = Path(__file__).resolve().parents[1]
ERROR = re.compile(
    r"^\s*(?:(?:ERROR|SCRIPT ERROR|SHADER ERROR|UNKNOWN ERROR|FATAL|CRASH):|Parse Error:|"
    r"(?:CrashHandlerException|handle_crash): Program crashed\b|Dumping the backtrace\.|"
    r"-- END OF C\+\+ BACKTRACE --|GDScript backtrace \(most recent call first\):)|"
    r"leaked at exit|still in use at exit", re.IGNORECASE | re.MULTILINE)
SHUTDOWN_RESOURCES = re.compile(
    r"(?m)^ERROR: \d+ resources still in use at exit \(run with --verbose for details\)\.(?:\r?\n|$)"
    r"(?: +at: clear \(core/io/resource\.cpp:\d+\)(?:\r?\n|$))?")
SHUTDOWN_OBJECTS = re.compile(
    r"(?m)^WARNING: \d+ ObjectDB instances were leaked at exit \(run with `--verbose` for details\)\.(?:\r?\n|\Z)"
    r"(?: +at: cleanup \((?:\./)?core/object/object\.cpp:\d+\)(?:\r?\n|\Z))?"
    r"(?![ \t]+at:)")


def _stage_export_templates(parent_env: dict[str, str], env: dict[str, str]) -> None:
    """Copy only this build's installed templates; never expose player/editor settings."""
    version = json.loads((ROOT / "tools/release_config.json").read_text(encoding="utf-8"))["godotVersion"] + ".stable"
    if os.name == "nt":
        if not parent_env.get("APPDATA"):
            return
        source = Path(parent_env["APPDATA"]) / "Godot/export_templates" / version
        target = Path(env["APPDATA"]) / "Godot/export_templates" / version
    else:
        data = Path(parent_env.get("XDG_DATA_HOME") or Path.home() / ".local/share")
        source = data / "godot/export_templates" / version
        target = Path(env["XDG_DATA_HOME"]) / "godot/export_templates" / version
    if source.is_dir():
        shutil.copytree(source, target)


def _streams(stdout: str | bytes | None, stderr: str | bytes | None) -> str:
    def decode(value: str | bytes | None) -> str:
        return value.decode("utf-8", "replace") if isinstance(value, bytes) else (value or "")
    return "stdout:\n" + decode(stdout) + "\nstderr:\n" + decode(stderr)


@contextmanager
def _temporary_user_data():
    temporary = tempfile.TemporaryDirectory(prefix="rs-godot-check-")
    try:
        yield temporary.name
    except BaseException as exc:
        try:
            temporary.cleanup()
        except OSError as cleanup_error:
            exc.add_note(f"Cannot remove temporary Godot user data at {temporary.name}: {cleanup_error}")
        raise
    else:
        temporary.cleanup()


def _check_result(result: subprocess.CompletedProcess, allow_shutdown_resources: bool) -> str:
    shutdown_count = 0
    for stream in (result.stdout, result.stderr):
        checked_output = stream
        # --quit-after bypasses the game's orderly shutdown. This startup-only allowance
        # says nothing about clean shutdown; import/export and complete lifecycle checks stay strict.
        if allow_shutdown_resources:
            checked_output, count = SHUTDOWN_RESOURCES.subn("", stream)
            shutdown_count += count
            if count:
                # Real forced exits can report this precise companion in the same stream.
                checked_output = SHUTDOWN_OBJECTS.sub("", checked_output)
        if ERROR.search(checked_output):
            raise RuntimeError(f"Godot check failed: exit {result.returncode}\n" + _streams(result.stdout, result.stderr))
    if result.returncode:
        raise RuntimeError(f"Godot check failed: exit {result.returncode} "
                           f"(0x{result.returncode & 0xFFFFFFFF:08X})\n" + _streams(result.stdout, result.stderr))
    if shutdown_count:
        print("Warning: Godot reported retained resources or objects at forced --quit-after exit; "
              "startup check does not verify clean shutdown.", flush=True)
    return result.stdout + result.stderr


def checked_run(command: list[str], *, timeout: int = 180, allow_shutdown_resources: bool = False) -> str:
    """Run an isolated check; only forced startup smoke may exempt known retained resources."""
    parent_env = dict(os.environ)
    result = None
    try:
        with _temporary_user_data() as temp:
            # Separate writable roots keep Godot away from both player data and editor settings.
            env = dict(parent_env, RS_TEST_MODE="1")
            for key, name in (("APPDATA", "roaming"), ("LOCALAPPDATA", "local"), ("XDG_DATA_HOME", "data"),
                              ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache")):
                directory = Path(temp) / name
                directory.mkdir()
                env[key] = str(directory)
            engine_args = command[:command.index("--")] if "--" in command else command
            if any(flag in engine_args for flag in ("--export-release", "--export-debug", "--export-pack")):
                _stage_export_templates(parent_env, env)
            try:
                result = run_engine(command, env=env, timeout=timeout, cwd=ROOT)
            except subprocess.TimeoutExpired as exc:
                # Keep the exception type/streams while making complete evidence visible in CLI tracebacks.
                exc.add_note(f"Godot check timed out after {timeout}s.\n" +
                             _streams(exc.stdout, exc.stderr))
                raise
            return _check_result(result, allow_shutdown_resources and "--quit-after" in engine_args)
    except OSError as exc:
        if result is not None:
            exc.add_note(_streams(result.stdout, result.stderr))
        raise


def smoke_game(executable: Path, project: Path | None = None) -> None:
    command = [str(executable.resolve()), "--headless", "--fixed-fps", "60", "--quit-after", "600"]
    if project:
        command += ["--path", str(project.resolve())]
    cases = [("menu/main_menu", 0, 0)]
    for game in catalog.game_ids(include_hidden=True):   # every module and map; basketball also split-screen
        cases += [(f"{game}/{game}_game", index, players) for index in range(catalog.map_count(game))
                  for players in ([1, 2, 4] if game == "basketball" else [1])]
    for scene, index, players in cases:
        game_id = scene.split("/", 1)[0]
        args = ["--", f"--game={game_id}", f"--demo={players}", f"--map={index}"] if players else []
        output = checked_run(command + args, allow_shutdown_resources=True)
        if players and f"CLI game: {game_id}" not in output:
            raise RuntimeError("Game menu did not select the requested game: " + game_id)
        print(f"Passed: {scene}, map={index}, players={players or 'menu'}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("executable", type=Path)
    parser.add_argument("--project", type=Path)
    args = parser.parse_args()
    smoke_game(args.executable, args.project)
