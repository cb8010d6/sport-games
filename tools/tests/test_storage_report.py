"""Fault diagnostics must not conceal unrelated engine failures."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from test_storage import valid_output

GOOD = "\n".join((
    "ERROR: ConfigFile parse error at user://save-tests/syntax.cfg:0: Unexpected EOF while parsing simple tag.",
    "ERROR: RSProfiles: cannot save profiles (File unrecognized)",
    "RS_STORAGE_TESTS: 60 checks, 0 failures",
))


class StorageReportTests(unittest.TestCase):
    def test_expected_faults_only(self) -> None:
        self.assertTrue(valid_output(GOOD, 0))
        for extra in ("ERROR: unexpected engine error", "SCRIPT ERROR: bad type", "FATAL", "CRASH"):
            with self.subTest(extra=extra):
                self.assertFalse(valid_output(GOOD + "\n" + extra, 0))

    def test_missing_duplicate_or_failed_completion(self) -> None:
        for output in (GOOD.replace("RS_STORAGE_TESTS:", "INCOMPLETE:"),
                       GOOD.replace("0 failures", "1 failures"),
                       GOOD + "\nERROR: RSProfiles: cannot save profiles (File unrecognized)",
                       GOOD.replace("ERROR: RSProfiles:", "WARNING: RSProfiles:")):
            with self.subTest(output=output):
                self.assertFalse(valid_output(output, 0))
        self.assertFalse(valid_output(GOOD, 1))
