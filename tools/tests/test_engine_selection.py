"""Explicit user choices win; otherwise use the locally repaired engine."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import test_game


class EngineSelectionTests(unittest.TestCase):
    def test_explicit_engine_and_environment_override_local_fix(self):
        with mock.patch.dict(os.environ, {"REGINA_GODOT": "chosen-by-env"}), \
             mock.patch.object(test_game.shutil, "which", return_value="global-godot"):
            self.assertEqual(test_game.find_godot("chosen-explicitly"), "chosen-explicitly")
            self.assertEqual(test_game.find_godot(None), "chosen-by-env")

    def test_installed_fix_is_preferred_and_missing_fix_falls_back(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "tools/engine_patches").mkdir(parents=True)
            (root / "tools/engine_patches/build-lock.json").write_text(json.dumps({"output_binary": "patched.exe"}))
            (root / "tools/godot").mkdir()
            patched = root / "tools/godot/patched.exe"
            with mock.patch.object(test_game, "ROOT", root), \
                 mock.patch.object(test_game.sys, "platform", "win32"), \
                 mock.patch.dict(os.environ, {"REGINA_GODOT": ""}), \
                 mock.patch.object(test_game.shutil, "which", return_value="global-godot"):
                self.assertEqual(test_game.find_godot(None), "global-godot")
                patched.touch()
                self.assertEqual(test_game.find_godot(None), str(patched.resolve()))
                with mock.patch.object(test_game.sys, "platform", "linux"):
                    self.assertEqual(test_game.find_godot(None), "global-godot")


if __name__ == "__main__":
    unittest.main()
