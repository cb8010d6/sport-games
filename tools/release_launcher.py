"""Native release launcher. Starts only its own hub and stops it when the game closes."""
from __future__ import annotations

import ctypes
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def hub_running() -> bool:
    try:
        with urllib.request.urlopen("http://127.0.0.1:47802/api/status", timeout=0.5) as response:
            status = json.load(response)
        return status.get("type") == "roster" and isinstance(status.get("controllers"), list)
    except (OSError, ValueError, urllib.error.URLError):
        return False


def run_package(root: Path, *, smoke: bool = False) -> None:
    game = root / "game/SportGames.exe"
    hub = root / "hub/sport-hub.exe"
    if not game.is_file() or not hub.is_file():
        raise RuntimeError("Package is incomplete. Extract the entire ZIP before starting.")
    data = Path(os.environ.get("SPORT_GAMES_DATA_DIR", Path(os.environ.get("LOCALAPPDATA", root)) / "SportGames"))
    data.mkdir(parents=True, exist_ok=True)
    owned: subprocess.Popen | None = None
    with (data / "hub.log").open("a", encoding="utf-8") as log:
        try:
            if not hub_running():
                owned = subprocess.Popen([str(hub), "--data-dir", str(data), *(["--no-ble"] if smoke else [])],
                                         cwd=root / "hub", stdout=log, stderr=subprocess.STDOUT,
                                         creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0)
                deadline = time.monotonic() + 20
                while not hub_running():
                    if owned.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("Controller hub could not start. Check the hub log in your SportGames data folder.")
                    time.sleep(0.2)
            command = [str(game)] + (["--headless", "--quit-after", "120"] if smoke else [])
            subprocess.run(command, cwd=root / "game", check=True)
        finally:
            if owned and owned.poll() is None:
                owned.terminate()
                try:
                    owned.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    owned.kill()
                    owned.wait(timeout=5)


def main() -> None:
    root = Path(sys.executable).resolve().parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parents[1]
    try:
        run_package(root, smoke="--smoke-test" in sys.argv)
    except Exception as error:
        if sys.platform == "win32" and "--smoke-test" not in sys.argv:
            ctypes.windll.user32.MessageBoxW(None, str(error), "Sport Games", 0x10)
        else:
            print(str(error), file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
