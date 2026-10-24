"""Real pipe draining, strict disk bounds and launcher process ownership."""

import io
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from tools import release_launcher as launcher
from tools.package_archive import REQUIRED, validate_package


class LauncherLogTests(unittest.TestCase):
    def test_rotated_logs_cannot_be_published(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name in REQUIRED:
                file = root / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.touch()
            for name in ("hub.log.1", "hub.log.2", "HUB.LOG.1", "inputs.jsonl.backup"):
                with self.subTest(name=name):
                    file = root / name
                    file.write_bytes(b"private fixture")
                    try:
                        with self.assertRaisesRegex(RuntimeError, "Private"):
                            validate_package(root)
                    finally:
                        file.unlink()

    def test_rotation_bounds_existing_and_new_logs_and_preserves_tail(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(launcher, "LOG_BYTES", 128):
            path = Path(temp) / "hub.log"
            for suffix in ("", ".1", ".2"):
                path.with_name(path.name + suffix).write_bytes(b"old" * 1000)
            log = launcher.HubLog(path)
            data = bytes(range(256)) * 5
            try:
                log.write(data)
            finally:
                log.close()
            files = [path.with_name("hub.log" + suffix) for suffix in (".2", ".1", "")]
            self.assertTrue(all(file.stat().st_size <= 128 for file in files))
            retained = b"".join(file.read_bytes() for file in files)
            self.assertTrue(data.endswith(retained))
            self.assertEqual(len(list(Path(temp).iterdir())), 3)

    def test_actual_child_stdout_and_stderr_do_not_block_and_stay_bounded(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "hub.log"
            log = launcher.HubLog(path)
            process = subprocess.Popen([sys.executable, "-c",
                                        "import sys; sys.stdout.buffer.write(b'x' * (4 * 1024 * 1024)); "
                                        "sys.stdout.flush(); sys.stderr.write('end-marker')"],
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            errors = []
            reader = threading.Thread(target=launcher.drain_hub_output, args=(process, log, errors), daemon=True)
            reader.start()
            try:
                self.assertEqual(process.wait(timeout=15), 0)
                reader.join(timeout=5)
                self.assertFalse(reader.is_alive())
                self.assertEqual(errors, [])
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
                reader.join(timeout=5)
                log.close()
            self.assertTrue(path.read_bytes().endswith(b"end-marker"))
            self.assertLessEqual(sum(f.stat().st_size for f in Path(temp).iterdir()), 3 * launcher.LOG_BYTES)

    def test_disk_failure_still_drains_the_pipe(self):
        output = io.BytesIO(b"x" * 50000)
        log = Mock()
        log.write.side_effect = OSError("disk full")
        errors = []
        launcher.drain_hub_output(SimpleNamespace(stdout=output), log, errors)
        self.assertEqual(len(errors), 1)
        self.assertEqual(log.write.call_count, 1)
        self.assertTrue(output.closed)

    def test_game_failure_stops_only_owned_hub_and_collects_last_output(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name in ("game/SportGames.exe", "hub/sport-hub.exe"):
                file = root / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.touch()
            data = root / "data"
            process = Mock(stdout=io.BytesIO(b"last hub diagnostic\n"))
            process.poll.return_value = None
            with patch.dict(os.environ, {"SPORT_GAMES_DATA_DIR": str(data)}), \
                    patch.object(launcher, "hub_running", side_effect=[False, True]), \
                    patch.object(launcher.subprocess, "Popen", return_value=process), \
                    patch.object(launcher.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "game")):
                with self.assertRaises(subprocess.CalledProcessError):
                    launcher.run_package(root)
            process.terminate.assert_called_once()
            self.assertIn(b"Hub session", (data / "hub.log").read_bytes())
            self.assertTrue((data / "hub.log").read_bytes().endswith(b"last hub diagnostic\n"))
            # File handles must be closed after both success and failure (also on Windows).
            (data / "hub.log").unlink()

    def test_existing_hub_is_neither_stopped_nor_given_a_new_log(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name in ("game/SportGames.exe", "hub/sport-hub.exe"):
                file = root / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.touch()
            with patch.dict(os.environ, {"SPORT_GAMES_DATA_DIR": str(root / "data")}), \
                    patch.object(launcher, "hub_running", return_value=True), \
                    patch.object(launcher.subprocess, "Popen") as popen, \
                    patch.object(launcher.subprocess, "run") as run:
                launcher.run_package(root)
            popen.assert_not_called()
            run.assert_called_once()
            self.assertFalse((root / "data/hub.log").exists())
