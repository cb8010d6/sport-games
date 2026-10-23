"""Reject false-positive smoke results without requiring Godot or downloaded artwork."""
import base64
import json
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import smoke_test as smoke

PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")


def result():
    return {"game": "ski", "map": 1, "phase": "results", "players": [{"slot": 2, "score": 100}, {"slot": 1, "score": 50}]}


def catalog():
    return [{"game": "ski", "scene": "res://scenes/ski/ski_game.tscn", "map": i, "map_name": f"Map {i}"} for i in range(4)]


def row(**changes):
    return {"game": "ski", "map": 0, "map_name": 'Snow & <script>"', "players": 2,
            "passed": True, "errors": [], "environment_warnings": [], "screenshot": "ski.png", **changes}


class SmokeValidationTests(unittest.TestCase):
    def test_ranked_results_accept_out_of_slot_order(self):
        smoke.validate_result(result(), "ski", 1, 2)

    def test_rejects_wrong_game_map_or_phase(self):
        for key, value in [("game", "plane"), ("map", 0), ("map", True), ("phase", "play")]:
            with self.subTest(key=key, value=value):
                report = result()
                report[key] = value
                with self.assertRaises(ValueError):
                    smoke.validate_result(report, "ski", 1, 2)

    def test_rejects_missing_duplicate_or_out_of_range_players(self):
        for slots in ([], [1], [1, 1], [0, 2], [1, 3], [True, 2], [1, 2, 3]):
            with self.subTest(slots=slots):
                report = result()
                report["players"] = [{"slot": slot, "score": 10} for slot in slots]
                with self.assertRaises(ValueError):
                    smoke.validate_result(report, "ski", 1, 2)

    def test_rejects_malformed_and_non_finite_scores(self):
        for score in (None, True, "100", float("nan"), float("inf"), float("-inf")):
            with self.subTest(score=score):
                report = result()
                report["players"][0]["score"] = score
                with self.assertRaises(ValueError):
                    smoke.validate_result(report, "ski", 1, 2)
        for report in (None, [], {}, {**result(), "players": [None, None]}):
            with self.assertRaises(ValueError):
                smoke.validate_result(report, "ski", 1, 2)

    def test_catalog_requires_each_game_and_contiguous_unique_maps(self):
        self.assertEqual(len(smoke.validate_catalog(catalog(), ["ski"])), 4)
        invalid = [[], catalog()[:1] + catalog()[:1], catalog()[1:], catalog()[:1] + catalog()[2:]]
        invalid += [[{**catalog()[0], "game": []}], [{**catalog()[0], "scene": "res://other.tscn"}]]
        invalid += [[{**catalog()[0], "map": True}], [{**catalog()[0], "map_name": ""}]]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                smoke.validate_catalog(value, ["ski"])
        with self.assertRaises(ValueError):
            smoke.validate_catalog(catalog(), ["ski", "plane"])

    def test_certificates_are_separate_but_game_errors_and_leaks_fail(self):
        cert = "ERROR: Failed to read the root certificate store."
        failure = "SCRIPT ERROR: Invalid call"
        leak = "WARNING: 2 ObjectDB instances were leaked at exit"
        errors, environment = smoke.engine_errors("\n".join([cert, failure, leak]))
        self.assertEqual(errors, [failure, leak])
        self.assertEqual(environment, [cert])

    def test_png_rejects_truncation_and_bad_crc(self):
        self.assertEqual(smoke.png_size(PNG), (1, 1))
        corrupt = bytearray(PNG)
        corrupt[30] ^= 1
        for data in (b"not PNG", PNG[:33], PNG[:-1], bytes(corrupt)):
            with self.assertRaises(ValueError):
                smoke.png_size(data)

    def test_contact_sheet_embeds_captures_and_escapes_labels(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)
            (output / "ski.png").write_bytes(PNG)
            rows = [row(), row(map=1, passed=False, screenshot=None, errors=["<error>"])]
            smoke.write_reports(output, rows, True, 2)
            svg = ET.parse(output / "contact-sheet.svg").getroot()
            images = svg.findall("{http://www.w3.org/2000/svg}image")
            self.assertEqual(len(images), 1)
            self.assertEqual(base64.b64decode(images[0].attrib["href"].split(",", 1)[1]), PNG)
            markup = (output / "index.html").read_text(encoding="utf-8")
            self.assertIn("&lt;script&gt;", markup)
            self.assertNotIn("<script>", markup)
            self.assertEqual(json.loads((output / "run.json").read_text())["status"], "FAIL")

    def test_partial_run_is_not_a_pass_and_headless_removes_old_sheet(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)
            (output / "contact-sheet.svg").write_text("old PASS")
            smoke.write_reports(output, [row(screenshot=None)], False, 2)
            self.assertFalse((output / "contact-sheet.svg").exists())
            state = json.loads((output / "run.json").read_text())
            self.assertEqual(state, {"status": "RUNNING", "expected": 2, "completed": 1})

    def test_discovery_failure_removes_previous_pass_summary(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)
            for name in ("run.json", "summary.json", "index.html", "contact-sheet.svg"):
                (output / name).write_text("old PASS")
            with mock.patch.object(sys, "argv", ["smoke_test", "--output", temp]), \
                 mock.patch.object(smoke, "find_godot", return_value="godot"), \
                 mock.patch.object(smoke, "discover_cases", side_effect=ValueError("invalid catalog")):
                self.assertEqual(smoke.main(), 1)
            self.assertFalse((output / "summary.json").exists())

    def test_runner_requires_valid_report_marker_and_exit_code(self):
        valid = {**result(), "map": 0}
        scenarios = [(json.dumps(valid), "RS_SMOKE_DONE: ski", 0, 0),
                     (None, "RS_SMOKE_DONE: ski", 0, 1),
                     ("{", "RS_SMOKE_DONE: ski", 0, 1),
                     (json.dumps(result()), "RS_SMOKE_DONE: ski", 0, 1),
                     (json.dumps(valid), "", 0, 1),
                     (json.dumps(valid), "RS_SMOKE_DONE: ski", 1, 1)]
        for payload, marker, code, expected in scenarios:
            with self.subTest(payload=payload, marker=marker, code=code), tempfile.TemporaryDirectory() as temp:
                output = Path(temp)
                # An old valid report must not turn a missing current report into a pass.
                (output / "ski.json").write_text(json.dumps(valid))

                def engine(command, payload=payload, marker=marker, code=code, **_kwargs):
                    path = Path(next(arg.split("=", 1)[1] for arg in command if arg.startswith("--smoke-report=")))
                    if payload is not None:
                        path.write_text(payload)
                    return subprocess.CompletedProcess(command, code, marker, "")

                with mock.patch.object(sys, "argv", ["smoke_test", "--games", "ski", "--output", temp]), \
                     mock.patch.object(smoke, "find_godot", return_value="godot"), \
                     mock.patch.object(smoke, "discover_cases", return_value=catalog()[:1]), \
                     mock.patch.object(smoke, "run_engine", side_effect=engine):
                    self.assertEqual(smoke.main(), expected)
                self.assertEqual(json.loads((output / "run.json").read_text())["status"], "PASS" if expected == 0 else "FAIL")

    def test_runner_rejects_stale_screenshot_and_records_timeout(self):
        for timeout in (False, True):
            with self.subTest(timeout=timeout), tempfile.TemporaryDirectory() as temp:
                output = Path(temp)
                (output / "ski.png").write_bytes(PNG)

                def engine(command, timed_out=timeout, output=output, **_kwargs):
                    if timed_out:
                        raise subprocess.TimeoutExpired(command, 1, b"timeout output", b"error output")
                    (output / "ski.json").write_text(json.dumps({**result(), "map": 0}))
                    return subprocess.CompletedProcess(command, 0, "RS_SMOKE_DONE: ski", "")

                with mock.patch.object(sys, "argv", ["smoke_test", "--games", "ski", "--screenshots", "--output", temp]), \
                     mock.patch.object(smoke, "find_godot", return_value="godot"), \
                     mock.patch.object(smoke, "discover_cases", return_value=catalog()[:1]), \
                     mock.patch.object(smoke, "run_engine", side_effect=engine):
                    self.assertEqual(smoke.main(), 1)
                summary = json.loads((output / "summary.json").read_text())[0]
                self.assertIsNone(summary["screenshot"])
                self.assertEqual(summary["timeout"], timeout)
                self.assertFalse((output / "ski.png").exists())


if __name__ == "__main__":
    unittest.main()
