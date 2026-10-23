"""Measurement contracts and failure paths, without launching Godot or touching a GPU."""
import json
import math
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bench


def arguments(*extra):
    return bench.build_parser().parse_args(["--games", "ski", "--players", "2", "--repeat", "1",
                                           "--duration", "1", "--warmup", "0", *extra])


def report():
    sample = {"frame_ms": 10.0, "cpu_process_ms": 2.0, "gpu_ms": None, "draw_calls": 20,
              "video_memory_bytes": 1024, "nodes": 42, "gpu_viewports_ms": {"root": None, "player1": 1.2},
              "cpu_render_viewports_ms": {"root": 0.0, "player1": 0.2}}
    return {"schema_version": 1, "status": "PASS", "game": "ski", "map": 0, "players": 2, "quality": 2,
            "warmup_seconds": 0.0, "duration_seconds": 1.0, "elapsed_seconds": 1.0, "frames": 100,
            "samples": [dict(sample) for _ in range(100)], "errors": [],
            "metadata": {"gpu": "AMD Radeon 780M Graphics", "driver": None, "rendering_method": "forward_plus",
                         "rendering_driver": "vulkan", "godot_version": "4.7.2.stable.official",
                         "resolution": [1600, 900], "seed": 20261023, "reproducibility": {"seed_scope": "global"}}}


class BenchTests(unittest.TestCase):
    def test_matrix_defaults_and_deduplication(self):
        cases = bench.expand_matrix(bench.build_parser().parse_args([]))
        self.assertEqual(len(cases), 54)
        self.assertEqual(len(set(cases)), 54)
        self.assertEqual(cases[0], bench.Case("plane", 0, 1, 2, 1))
        args = arguments("--maps", "0", "1", "0", "--players", "2", "2", "4", "--quality", "1", "2")
        self.assertEqual(len(bench.expand_matrix(args)), 8)

    def test_cli_rejects_invalid_or_unrendered_options(self):
        for flags in (("--duration", "nan"), ("--warmup", "inf"), ("--maps", "-1"),
                      ("--players", "3"), ("--quality", "4"), ("--gpu-index", "-1"),
                      ("--headless",), ("--fixed-fps", "60"), ("--duration", "0"), ("--repeat", "0")):
            with self.subTest(flags=flags), mock.patch("sys.stderr"), self.assertRaises(SystemExit):
                bench.main(list(flags))

    def test_statistics_weight_frame_time_and_slow_tail(self):
        samples = report()["samples"][:4]
        for sample, value in zip(samples, (1, 2, 3, 94), strict=True):
            sample["frame_ms"] = value
        stats = bench.summarize_samples(samples)
        self.assertEqual(stats["avg_fps"], 40)
        self.assertEqual(stats["frame_ms_p50"], 2.5)
        self.assertAlmostEqual(stats["frame_ms_p95"], 80.35)
        self.assertAlmostEqual(stats["frame_ms_p99"], 91.27)
        self.assertAlmostEqual(stats["one_percent_low_fps"], 1000 / 94)
        self.assertIsNone(stats["gpu_ms_avg"])
        samples = report()["samples"] + [report()["samples"][0]]
        samples[0]["frame_ms"], samples[1]["frame_ms"] = 40, 20
        self.assertAlmostEqual(bench.summarize_samples(samples)["one_percent_low_fps"], 1000 / 30)

    def test_rejects_wrong_identity_incomplete_time_and_invalid_metrics(self):
        bench.validate_report(report(), bench.Case("ski", 0, 2, 2, 1), arguments("--expect-gpu", "radeon"))
        changes = [("schema_version", True), ("game", "skate"), ("map", True), ("players", 4), ("quality", 1),
                   ("warmup_seconds", 1), ("duration_seconds", 2), ("elapsed_seconds", .9), ("elapsed_seconds", 4),
                   ("frames", 99), ("samples", []), ("status", "FAIL"), ("errors", ["early RESULTS"])]
        for key, value in changes:
            payload = report()
            payload[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                bench.validate_report(payload, bench.Case("ski", 0, 2, 2, 1), arguments())
        for key, value in (("frame_ms", 0), ("frame_ms", math.inf), ("cpu_process_ms", -1),
                           ("gpu_ms", 0), ("gpu_ms", math.nan), ("draw_calls", True), ("nodes", .5),
                           ("gpu_viewports_ms", {"root": 0}), ("cpu_render_viewports_ms", {"root": -1})):
            payload = report()
            payload["samples"][0][key] = value
            with self.subTest(metric=key, value=value), self.assertRaises(ValueError):
                bench.validate_report(payload, bench.Case("ski", 0, 2, 2, 1), arguments())
        for key, value in (("resolution", [800, 450]), ("seed", 1), ("gpu", "NVIDIA RTX 4060"),
                           ("rendering_driver", "headless"), ("reproducibility", None)):
            payload = report()
            payload["metadata"][key] = value
            with self.subTest(metadata=key), self.assertRaises(ValueError):
                bench.validate_report(payload, bench.Case("ski", 0, 2, 2, 1), arguments("--expect-gpu", "780M"))
        payload = report()
        payload["samples"][0]["frame_ms"] = 1000
        with self.assertRaisesRegex(ValueError, "sample time"):
            bench.validate_report(payload, bench.Case("ski", 0, 2, 2, 1), arguments())

    def run_fake(self, output, *, code=0, text="RS_BENCH_DONE: ski", payload=None, failure=None, paths=None,
                 power_states=None, engine_calls=None):
        def engine(command, env, timeout):
            if engine_calls is not None:
                engine_calls.append(command)
            self.assertNotIn("--headless", command)
            self.assertNotIn("--fixed-fps", command)
            self.assertEqual(command[command.index("--resolution") + 1], "1600x900")
            self.assertEqual(command[command.index("--gpu-index") + 1], "1")
            self.assertEqual(env["RS_TEST_MODE"], "1")
            self.assertTrue(Path(env["APPDATA"]).is_dir())
            self.assertTrue(Path(env["APPDATA"]).is_relative_to(Path(env["RS_BENCH_USER_ROOT"])))
            self.assertNotEqual(env["APPDATA"], env["LOCALAPPDATA"])
            if paths is not None:
                paths.append(env["APPDATA"])
            if failure:
                raise failure
            path = Path(next(arg.split("=", 1)[1] for arg in command if arg.startswith("--bench-output=")))
            if payload != "missing":
                path.write_text(json.dumps(report() if payload is None else payload), encoding="utf-8")
            return subprocess.CompletedProcess(command, code, text, "")
        with mock.patch.object(bench, "run_engine", side_effect=engine), \
             mock.patch.object(bench, "find_godot", return_value="fake-godot"), \
             mock.patch.object(bench, "source_revision", return_value={"source_commit": "a" * 40, "source_dirty": True}), \
             mock.patch.object(bench, "power_status", side_effect=power_states,
                               return_value={"ac": "ONLINE", "battery_percent": 95}):
            return bench.main(["--games", "ski", "--players", "2", "--repeat", "2" if paths is not None else "1",
                               "--duration", "1", "--warmup", "0", "--gpu-index", "1", "--expect-gpu", "780M", "--output", str(output)])

    def test_offline_before_launch_rejects_without_starting_engine(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)
            # A previous successful report must not survive the rejected retry.
            self.assertEqual(self.run_fake(output), 0)
            calls = []
            self.assertEqual(self.run_fake(output, engine_calls=calls,
                                          power_states=[{"ac": "OFFLINE", "battery_percent": 60}] * 2), 1)
            self.assertEqual(calls, [])
            summary = json.loads((output / "summary.json").read_text())
            row = summary["runs"][0]
            raw = json.loads((output / row["raw"]).read_text())
            self.assertEqual(raw["status"], "FAIL")
            self.assertTrue(any("OFFLINE" in error and "before" in error for error in raw["errors"]))
            self.assertEqual(raw["samples"], [])
            self.assertIsNone(raw["runner_status"])
            self.assertIsNone(raw["exit_code"])
            self.assertEqual(raw["metadata"]["source_commit"], "a" * 40)
            self.assertEqual(raw["metadata"]["power_before"]["ac"], "OFFLINE")
            self.assertIsNone(raw["metadata"]["power_after"])
            self.assertFalse(raw["metadata"]["power_endpoints_online"])
            self.assertEqual((raw["game"], raw["map"], raw["players"], raw["quality"]), ("ski", 0, 2, 2))
            self.assertIsNone(row["statistics"])
            self.assertEqual(summary["groups"][0]["target_status"], "INVALID")
            self.assertFalse((output / "ski-m0-p2-q2-r1/engine-output.txt").exists())

    def test_offline_after_launch_rejects_valid_engine_samples(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)
            calls = []
            self.assertEqual(self.run_fake(output, engine_calls=calls, power_states=[
                {"ac": "ONLINE", "battery_percent": 95}, {"ac": "OFFLINE", "battery_percent": 94}]), 1)
            self.assertEqual(len(calls), 1)
            summary = json.loads((output / "summary.json").read_text())
            row = summary["runs"][0]
            raw = json.loads((output / row["raw"]).read_text())
            self.assertEqual(raw["status"], "FAIL")
            self.assertEqual(raw["runner_status"], "PASS")
            self.assertEqual(raw["samples"], report()["samples"])
            self.assertTrue(any("OFFLINE" in error and "after" in error for error in raw["errors"]))
            self.assertEqual(raw["metadata"]["power_before"]["ac"], "ONLINE")
            self.assertEqual(raw["metadata"]["power_after"]["ac"], "OFFLINE")
            self.assertFalse(raw["metadata"]["power_endpoints_online"])
            self.assertIsNone(row["statistics"])
            self.assertIsNone(summary["groups"][0]["statistics"])
            self.assertEqual(summary["groups"][0]["target_status"], "INVALID")

    def test_unavailable_power_is_recorded_without_claiming_online(self):
        for state in ("UNKNOWN", "UNAVAILABLE"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as temp:
                output = Path(temp)
                power = {"ac": state, "battery_percent": None}
                self.assertEqual(self.run_fake(output, power_states=[power, power]), 0)
                summary = json.loads((output / "summary.json").read_text())
                row = summary["runs"][0]
                self.assertEqual(row["metadata"]["power_before"], power)
                self.assertEqual(row["metadata"]["power_after"], power)
                self.assertFalse(row["metadata"]["power_endpoints_online"])
                self.assertIsNotNone(row["statistics"])

    def test_success_preserves_samples_isolates_each_repeat_and_reports_targets(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)
            paths = []
            self.assertEqual(self.run_fake(output, paths=paths), 0)
            self.assertEqual(len(set(paths)), 2)
            self.assertTrue(all(not Path(path).exists() for path in paths))
            summary = json.loads((output / "summary.json").read_text())
            self.assertEqual(summary["status"], "PASS")
            self.assertEqual(summary["groups"][0]["target_status"], "MET")
            raw = json.loads((output / summary["runs"][0]["raw"]).read_text())
            self.assertEqual(raw["samples"], report()["samples"])
            self.assertEqual(raw["metadata"]["power_before"]["ac"], "ONLINE")
            self.assertTrue(raw["metadata"]["power_endpoints_online"])
            self.assertIsNone(raw["samples"][0]["gpu_ms"])
            self.assertIn("Repeat FPS range", (output / "summary.md").read_text(encoding="utf-8"))

    def test_failure_cannot_reuse_or_publish_a_pass(self):
        scenarios = [{"code": 1}, {"text": ""}, {"text": "RS_BENCH_DONE: ski\nERROR: shutdown resources still in use"},
                     {"text": "RS_BENCH_DONE: ski\nWARNING: ObjectDB instances leaked at exit"},
                     {"payload": "missing"}, {"payload": []}, {"payload": {**report(), "elapsed_seconds": .1}},
                     {"failure": subprocess.TimeoutExpired("fake", 1, b"partial", b"timeout")},
                     {"failure": OSError("no executable")}]
        for scenario in scenarios:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temp:
                output = Path(temp)
                self.assertEqual(self.run_fake(output), 0)
                self.assertEqual(self.run_fake(output, **scenario), 1)
                summary = json.loads((output / "summary.json").read_text())
                raw = json.loads((output / "ski-m0-p2-q2-r1/raw.json").read_text())
                self.assertEqual(summary["status"], "FAIL")
                self.assertEqual(raw["status"], "FAIL")
                self.assertTrue(raw["errors"])
                self.assertIsNone(summary["runs"][0]["statistics"])
                self.assertEqual(summary["groups"][0]["target_status"], "INVALID")

    def test_discovery_failure_invalidates_previous_pass(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)
            self.assertEqual(self.run_fake(output), 0)
            with mock.patch.object(bench, "find_godot", side_effect=SystemExit("Godot not found")):
                self.assertEqual(bench.main(["--output", temp]), 1)
            self.assertEqual(json.loads((output / "summary.json").read_text())["status"], "FAIL")
            self.assertIn("Godot not found", (output / "summary.md").read_text(encoding="utf-8"))

    def test_strict_json_and_valid_below_target_are_distinct_from_failure(self):
        for value in ("NaN", "Infinity", "1e999"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                json.loads(value, parse_constant=bench.json_float, parse_float=bench.json_float)
        payload = report()
        payload["samples"] = payload["samples"][:25]
        payload["frames"] = 25
        for sample in payload["samples"]:
            sample["frame_ms"] = 40
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)
            self.assertEqual(self.run_fake(output, payload=payload), 0)
            summary = json.loads((output / "summary.json").read_text())
            self.assertEqual(summary["status"], "PASS")
            self.assertEqual(summary["groups"][0]["target_status"], "BELOW_TARGET")


if __name__ == "__main__":
    unittest.main()
