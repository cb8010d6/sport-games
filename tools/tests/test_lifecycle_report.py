"""A positive lifecycle result needs the correct case, mode and completed assertions."""
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from test_lifecycle import cleanup_data, validate_report


class LifecycleReportTests(unittest.TestCase):
    def test_incomplete_or_wrong_case_is_rejected(self) -> None:
        good = dict(game="plane", players=4, checks=30, errors=[], layout_only=False)
        validate_report(good, "plane", 4, False)
        for change in ({"game": "ski"}, {"players": 2}, {"players": 4.0}, {"checks": 0}, {"checks": True},
                       {"errors": ["pause failed"]}, {"layout_only": True}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate_report(good | change, "plane", 4, False)

    def test_cache_cleanup_retries_windows_write_races(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with mock.patch("test_lifecycle.shutil.rmtree", side_effect=[OSError("busy"), None]) as remove, \
                 mock.patch("test_lifecycle.time.sleep"):
                cleanup_data(root / "_run_data-fixture", root)
                self.assertEqual(remove.call_count, 2)

    def test_cache_cleanup_cannot_delete_outside_its_run(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with mock.patch("test_lifecycle.shutil.rmtree") as remove:
                with self.assertRaises(ValueError):
                    cleanup_data(root / "outside", root / "reports")
                remove.assert_not_called()
