"""A success marker cannot conceal errors emitted during shutdown."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from test_game import suite_passed


class GameCompletionTests(unittest.TestCase):
    def test_shutdown_errors_and_incomplete_markers_fail(self) -> None:
        marker = "RS_PARTY_FLOW: PASS"
        self.assertTrue(suite_passed(marker, 0, marker))
        for diagnostic in ("ERROR: late audio failure", "SCRIPT ERROR: bad call",
                           "WARNING: 2 ObjectDB instances were leaked at exit", marker + " incomplete"):
            with self.subTest(diagnostic=diagnostic):
                output = diagnostic if diagnostic.startswith(marker) else marker + "\n" + diagnostic
                self.assertFalse(suite_passed(output, 0, marker))
        self.assertFalse(suite_passed(marker, 1, marker))
