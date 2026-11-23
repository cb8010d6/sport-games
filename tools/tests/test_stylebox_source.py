"""StyleBoxFlat construction lives in RSUi (game/core/ui_kit.gd) (#57).

Menus and games take their theme styles from the RSUi factories so appearance
stays in one place. This scans the game sources and fails if a new private
`StyleBoxFlat.new()` appears outside the allowed files.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GAME = ROOT / "game"

ALLOWED = {
    # RSUi itself: every style factory builds its StyleBoxFlat here.
    "game/core/ui_kit.gd",
    # RSPartyGame's immediate-mode draw helpers share one scratch stylebox
    # (_box, next to the RSUi-built _pill/_chip/_lean) whose colour and radius
    # are set per draw call; it is never a Control theme style.
    "game/core/party_game.gd",
    # The controller debug overlay has its own local _panel_style() factory;
    # it is a diagnostics screen, deliberately outside the game's theme.
    "game/scenes/debug/controller_debug.gd",
}


class StyleBoxSourceTest(unittest.TestCase):
    def test_stylebox_flat_new_only_in_allowed_files(self):
        offenders = []
        for path in sorted(GAME.rglob("*.gd")):
            rel = path.relative_to(ROOT).as_posix()
            if rel in ALLOWED:
                continue
            for lineno, line in enumerate(
                path.read_text(encoding="utf-8").splitlines(), start=1
            ):
                if line.lstrip().startswith("#"):
                    continue
                if "StyleBoxFlat.new()" in line:
                    offenders.append(f"{rel}:{lineno}")
        self.assertEqual(offenders, [], "private StyleBoxFlat.new() outside RSUi: " + ", ".join(offenders))


if __name__ == "__main__":
    unittest.main()
