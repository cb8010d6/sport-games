"""Native release launcher. Starts only its own hub and stops it when the game closes."""
from __future__ import annotations

import ctypes
import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

LOG_BYTES = 1024 * 1024
LOG_BACKUPS = 2


class HubLog:
    """Binary child-output sink: each file <= 1 MiB, current plus two backups."""

    def __init__(self, path: Path):
        self.path = path
        # Bound logs left by earlier launcher versions before retaining them.
        for file in [path, *(self._backup(i) for i in range(1, LOG_BACKUPS + 1))]:
            if file.exists() and file.stat().st_size > LOG_BYTES:
                with file.open("r+b") as stream:
                    stream.seek(-LOG_BYTES, os.SEEK_END)
                    tail = stream.read(LOG_BYTES)
                    stream.seek(0)
                    stream.write(tail)
                    stream.truncate()
        self._file = path.open("ab")
        self.write(time.strftime("\n--- Hub session %Y-%m-%d %H:%M:%S ---\n").encode("ascii"))

    def _backup(self, number: int) -> Path:
        return self.path.with_name(f"{self.path.name}.{number}")

    def write(self, data: bytes) -> None:
        while data:
            remaining = LOG_BYTES - self._file.tell()
            if remaining == 0:
                self._file.close()
                self._backup(LOG_BACKUPS).unlink(missing_ok=True)
                for i in range(LOG_BACKUPS - 1, 0, -1):
                    if self._backup(i).exists():
                        self._backup(i).replace(self._backup(i + 1))
                self.path.replace(self._backup(1))
                self._file = self.path.open("ab")
                remaining = LOG_BYTES
            self._file.write(data[:remaining])
            self._file.flush()
            data = data[remaining:]

    def close(self) -> None:
        self._file.close()


def drain_hub_output(process: subprocess.Popen, log: HubLog, errors: list[OSError]) -> None:
    """Keep draining even if the disk fails, so the hub cannot block on a full pipe."""
    assert process.stdout is not None
    try:
        with process.stdout:
            while chunk := process.stdout.read1(8192):
                if not errors:
                    try:
                        log.write(chunk)
                    except OSError as exc:
                        errors.append(exc)
    except OSError as exc:
        if not errors:
            errors.append(exc)
    finally:
        try:
            log.close()
        except OSError as exc:
            if not errors:
                errors.append(exc)


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
    log: HubLog | None = None
    reader: threading.Thread | None = None
    errors: list[OSError] = []
    try:
        if not hub_running():
            log = HubLog(data / "hub.log")
            owned = subprocess.Popen([str(hub), "--data-dir", str(data), *(["--no-ble"] if smoke else [])],
                                     cwd=root / "hub", stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0)
            reader = threading.Thread(target=drain_hub_output, args=(owned, log, errors), daemon=True)
            reader.start()
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
        if reader is not None:
            reader.join(timeout=5)
        if log is not None and reader is None:
            log.close()
    if errors:
        raise RuntimeError("Could not write the hub log. Check free disk space and data-folder permissions.") from errors[0]


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
