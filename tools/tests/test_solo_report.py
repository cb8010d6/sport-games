"""Reject incomplete or mismatched formal-mode reports."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from test_solo import validate_report


class SoloReportTests(unittest.TestCase):
    def test_result_identity_and_completeness(self) -> None:
        value = {"game": "ski", "level": 2, "slot": 4, "map": 3, "layout_only": False,
                 "checks": 27, "passed": True, "errors": [], "cpu_score": 10, "human_score": 0}
        validate_report(value, "ski", 2, 3, False)
        for field, replacement in (("passed", False), ("errors", ["bad"]), ("game", "plane"),
                                   ("level", 1), ("slot", 1), ("map", 0), ("layout_only", True),
                                   ("checks", 2), ("cpu_score", -1), ("human_score", True)):
            with self.subTest(field=field):
                invalid = dict(value, **{field: replacement})
                with self.assertRaises(ValueError):
                    validate_report(invalid, "ski", 2, 3, False)
        with self.assertRaises(ValueError):
            validate_report(None, "ski", 2, 3, False)
