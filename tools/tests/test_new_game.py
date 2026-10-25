"""tools/new_game.py writes a complete, catalog-valid scaffold and removes it again cleanly."""
from __future__ import annotations

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import catalog
import new_game


class NewGameTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.game = Path(temp.name) / "game"
        (self.game / "i18n").mkdir(parents=True)
        (self.game / "tests").mkdir()
        (self.game / "scenes/old").mkdir(parents=True)
        self.english = '{\n "旧": "Old",\n  "旧二": "Old 2"\n}\n'
        (self.game / "i18n/en.json").write_text(self.english, encoding="utf-8")
        for target, name, value in ((new_game, "GAME", self.game), (new_game, "EN", self.game / "i18n/en.json"),
                                    (new_game, "ROOT", self.game.parent)):
            patcher = mock.patch.object(target, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_scaffold_is_a_valid_hidden_module_and_removes_cleanly(self) -> None:
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(new_game.main(["pong_ball", "--name", "乒乓", "--en", "Pong"]), 0)
        manifest = catalog.parse_module(self.game / "scenes/pong_ball/pong_ball_module.tres")
        self.assertEqual((manifest["id"], manifest["oled"], manifest["ready"]), ("pong_ball", "PONG_BALL", False))
        self.assertEqual(manifest["scene"], "res://scenes/pong_ball/pong_ball_game.tscn")
        self.assertEqual(len(manifest["solo_goals"]), 3)
        for path in new_game.files("pong_ball"):
            self.assertTrue(path.is_file(), path)
            self.assertNotIn("{id}", path.read_text(encoding="utf-8"))
        self.assertIn('"乒乓": "Pong"', (self.game / "i18n/en.json").read_text(encoding="utf-8"))
        with self.assertRaises(SystemExit):
            new_game.create("pong_ball", "乒乓", "Pong")
        with contextlib.redirect_stdout(io.StringIO()):
            new_game.main(["pong_ball", "--remove"])
        self.assertFalse((self.game / "scenes/pong_ball").exists())
        self.assertEqual(list((self.game / "tests").iterdir()), [])
        self.assertEqual((self.game / "i18n/en.json").read_text(encoding="utf-8"), self.english)

    def test_bad_ids_and_foreign_folders_are_refused(self) -> None:
        for bad in ("Pong", "1x", "x", "a-b"):
            with self.subTest(bad=bad), self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                new_game.main([bad, "--name", "乒乓", "--en", "Pong"])
        with self.assertRaises(SystemExit):
            new_game.remove("old")


if __name__ == "__main__":
    unittest.main()
