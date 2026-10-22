"""tools/check_conventions.py: each rule fires on a minimal bad file and stays quiet on good code.

unittest style, so it runs under both `pytest` and `python -m unittest`."""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_conventions as cc  # noqa: E402


class ConventionTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def write(self, rel: str, text: str, uid: bool = True) -> None:
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
        if uid and p.suffix == ".gd":
            p.with_name(p.name + ".uid").write_text("uid://example\n", encoding="utf-8")

    def rules(self) -> list[str]:
        return sorted(f.rule for f in cc.run(self.root) if not f.warning)

    def test_clean_code_passes(self) -> None:
        self.write("game/core/good.gd", "class_name RSGood\nextends RefCounted\n\n"
                   "static func add(a: int, b := 2,\n\t\tc: Array[int] = []) -> int:\n\treturn a + b\n")
        self.assertEqual(self.rules(), [])

    def test_typing_rules(self) -> None:
        self.write("game/core/bad.gd", "class_name Bad\nextends Node\n\nfunc f(a, b: int):\n\tpass\n", uid=False)
        self.assertEqual(self.rules(), ["GD-CLASS", "GD-PARAM", "GD-RET", "GD-UID"])

    def test_allow_comment_needs_the_rule_id(self) -> None:
        self.write("game/core/x.gd", "func f(v) -> void:  # allow: GD-PARAM Variant from JSON\n\tpass\n")
        self.assertEqual(self.rules(), [])
        self.write("game/core/x.gd", "func f(v) -> void:  # allow: GD-RET wrong id\n\tpass\n")
        self.assertEqual(self.rules(), ["GD-PARAM"])

    def test_layering(self) -> None:
        self.write("game/scenes/skate/skater.gd", "class_name RSSkater\nextends Node3D\n")
        self.write("game/scenes/ski/skier.gd", "extends Node3D\nvar s: RSSkater\n")
        self.write("game/scenes/menu/menu.gd", "extends Control\nvar s: RSSkater\n")
        self.write("game/core/party.gd", "extends Node\n# RSSkater in a comment is fine\nvar s: RSSkater\n")
        self.assertEqual(self.rules(), ["ARCH-CORE", "ARCH-GAME"])

    def test_services_stay_in_core(self) -> None:
        self.write("game/scenes/golf/golf.gd", "extends Node\n"
                   "func f() -> void:\n"
                   "\tvar cf := 'user://golf.cfg'\n"
                   "\tvar a := OS.get_cmdline_user_args()\n"
                   "\tControllerHub.vibrate(1, 60)\n"
                   "\tadd_child(AudioStreamPlayer3D.new())\n")
        self.write("game/core/sfx.gd", "extends Node\nfunc f() -> void:\n\tadd_child(AudioStreamPlayer.new())\n")
        self.write("game/scenes/debug/dbg.gd", "extends Node\nfunc f() -> void:\n\tControllerHub.vibrate(1, 60)\n")
        self.assertEqual(self.rules(), ["ARCH-ARGS", "ARCH-AUDIO", "ARCH-HAPTIC", "ARCH-SAVE"])

    def test_machine_paths(self) -> None:
        # Built from pieces so neither this checker nor the publication audit flags this file itself.
        drive, home = "D" + ":/SteamLibrary", "/" + "Users/example/"
        self.write("tools/x.py", f"GODOT = '{drive}/godot.exe'\n")
        self.write("hub/y.py", f"HOME = '{home}'\n")
        self.write("tools/ok.py", "URL = 'res://scenes/menu/main_menu.tscn'  # C: drive is mentioned in prose only\n")
        self.assertEqual(self.rules(), ["SRC-PATH", "SRC-PATH"])

    def test_size_is_only_a_warning(self) -> None:
        self.write("game/scenes/big/big.gd", "extends Node\n" + "var x := 1\n" * (cc.SIZE_WARN + 1))
        found = cc.run(self.root)
        self.assertEqual([(f.rule, f.warning) for f in found], [("SIZE", True)])

    def test_downloaded_toolchain_is_not_project_source(self) -> None:
        vendor_path = "C" + ":/Program Files/Vendor"
        self.write("tools/_dl/vendor/setup.py", f"TOOLCHAIN = '{vendor_path}'\n")
        self.assertEqual(self.rules(), [])


if __name__ == "__main__":
    unittest.main()
