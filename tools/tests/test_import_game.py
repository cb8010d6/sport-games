import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import import_game


class ImportGameTests(unittest.TestCase):
    def test_gltf_preflight_checks_external_buffers_and_images(self):
        with tempfile.TemporaryDirectory() as temp:
            project = Path(temp)
            source = project / "model.gltf"
            source.write_text(json.dumps({"buffers": [{"uri": "mesh.bin"}],
                                          "images": [{"uri": "a%20b.png"}, {"uri": "data:image/png;base64,AA=="}, {"bufferView": 0}]}))
            self.assertEqual(len(import_game.missing_gltf_dependencies(project)), 2)
            (project / "mesh.bin").touch()
            (project / "a b.png").touch()
            self.assertEqual(import_game.missing_gltf_dependencies(project), [])

    def test_native_failure_or_import_error_never_passes(self):
        for code, output, expected in [(0, "Done", 0), (0, "ERROR: Import failed", 1),
                                       (0xC0000005, "Done", 1)]:
            with self.subTest(code=code, output=output), tempfile.TemporaryDirectory() as temp:
                project = Path(temp)
                (project / "project.godot").touch()
                log = project / "import.log"
                log.write_text("old success")
                with mock.patch.object(sys, "argv", ["import_game", "--project", temp, "--log", str(log)]), \
                     mock.patch.object(import_game, "find_godot", return_value="godot"), \
                     mock.patch.object(import_game, "run_engine", return_value=subprocess.CompletedProcess([], code, output, "")) as engine:
                    self.assertEqual(import_game.main(), expected)
                    command = engine.call_args.args[0]
                    self.assertIn("--import", command)
                    self.assertEqual(command[command.index("--display-driver") + 1], "headless")
                    self.assertNotIn("--quit", command)
                    self.assertNotEqual(engine.call_args.kwargs["env"]["APPDATA"], os.environ.get("APPDATA"))
                self.assertEqual(log.read_text(), output)

    def test_missing_assets_do_not_start_engine_or_leave_stale_success(self):
        with tempfile.TemporaryDirectory() as temp:
            project = Path(temp)
            (project / "project.godot").touch()
            (project / "model.gltf").write_text('{"buffers":[{"uri":"missing.bin"}]}')
            log = project / "import.log"
            log.write_text("old success")
            with mock.patch.object(sys, "argv", ["import_game", "--project", temp, "--log", str(log)]), \
                 mock.patch.object(import_game, "run_engine") as engine:
                self.assertEqual(import_game.main(), 1)
                engine.assert_not_called()
            self.assertIn("Missing glTF dependencies", log.read_text())


if __name__ == "__main__":
    unittest.main()
