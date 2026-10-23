"""只用合成报告验证校验器；这些测试不启动 Godot，也不构成 LAN 实测证据。"""
from __future__ import annotations

import copy
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lan_report import MAX_BYTES, SCHEMA, load_report, main, validate_reports


def reports(scenario: str = "normal") -> list[dict]:
    """四位合成玩家，两机本地槽允许同为 P1；完赛顺序与积分排名不同。"""
    roster = [dict(seat=seat, peer_id=1 if seat <= 2 else 2, local_slot=seat if seat <= 2 else seat - 2,
                   name=f"测试玩家{seat}", bot=True) for seat in range(1, 5)]
    finishes = [dict(seat=5 - place, event_id=f"finish-{place}", place=place, bonus_count=1)
                for place in range(1, 5)]
    results = [dict(seat=seat, score=score, rank=rank, place=5 - seat)
               for seat, score, rank in ((1, 100, 1), (2, 100, 1), (3, 50, 3), (4, 10, 4))]
    value = dict(schema_version=SCHEMA, protocol_version=1, session_id="a" * 32, round_id=1,
                 scenario=scenario, peer_id=1, host_id=1, game="ski", map_index=0,
                 content_hash="b" * 64, complete=True, errors=[], last_error="", roster=roster,
                 active_seats=[1, 2, 3, 4], finishes=finishes, results=results, disconnects=[],
                 phases=[dict(phase=phase, at_ms=time) for phase, time in
                         zip(("LOBBY", "COUNTDOWN", "PLAY", "RESULTS", "LOBBY"), (0, 100, 3100, 8000, 9000), strict=True)],
                 injection=dict(latency_ms=0, jitter_ms=0, loss=0, seed=23, layer="application"),
                 metrics=dict(snapshot_hz=20, sent_snapshots=100, received_snapshots=98, ghosts_seen=2,
                              clock_samples=8, window_ms=5000, max_clock_error_ms=2,
                              event_latency_p99_ms=5, max_remote_jump_m=0.5,
                              rtt_ms=dict(p50=1, p95=2, p99=3), jitter_ms=dict(p50=0, p95=1, p99=2),
                              offset_ms=dict(p50=-2, p95=-1, p99=0)))
    pair = [copy.deepcopy(value), copy.deepcopy(value)]
    pair[1]["peer_id"] = 2
    if scenario != "normal":
        for index, report in enumerate(pair):
            report["disconnects"] = [dict(peer_id=2 if scenario == "client_left" else 1,
                                          at_ms=4000, reason="测试受控离开")]
            if scenario == "client_left" and index == 0:
                report["active_seats"] = [1, 2]
                report["results"] = report["results"][:2]
            else:
                report["phases"] = report["phases"][:3] + [dict(phase="CLOSED" if index == 0 else "MENU", at_ms=4100)]
                report["active_seats"] = []
                report["results"] = []
                report["last_error"] = "测试受控离开"
    return pair


class LanReportTests(unittest.TestCase):
    def test_valid_cases_and_host_order(self) -> None:
        for scenario in ("normal", "client_left", "host_left"):
            pair = reports(scenario)
            validate_reports(pair)
            validate_reports(list(reversed(pair)))

    def test_zero_based_maps_match_current_catalogue(self) -> None:
        for game, maps in (("skate", range(1)), ("ski", range(4))):
            for map_index in maps:
                pair = reports()
                for report in pair:
                    report.update(game=game, map_index=map_index)
                validate_reports(pair)
        for game, map_index in (("skate", 1), ("ski", 4), ("ski", -1), ("ski", True)):
            pair = reports()
            pair[0].update(game=game, map_index=map_index)
            with self.subTest(game=game, map_index=map_index), self.assertRaises(ValueError):
                validate_reports(pair)

    def test_high_rate_and_injection_do_not_claim_reliable_event_deadline(self) -> None:
        for hz in (20, 60, 120):
            for latency in (0, 30, 80):
                pair = reports()
                for report in pair:
                    report["metrics"].update(snapshot_hz=hz, sent_snapshots=hz * 5, event_latency_p99_ms=900)
                    report["injection"].update(latency_ms=latency, jitter_ms=10, loss=0.05, layer="transport")
                validate_reports(pair)

    def test_every_root_field_is_required(self) -> None:
        for field in reports()[0]:
            pair = reports()
            del pair[0][field]
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_reports(pair)

    def test_every_nested_field_is_required(self) -> None:
        for field in ("roster", "phases", "results", "finishes", "disconnects", "injection", "metrics"):
            template = reports("client_left")[0][field]
            row = template[0] if type(template) is list else template
            for key in row:
                pair = reports("client_left")
                target = pair[0][field][0] if type(pair[0][field]) is list else pair[0][field]
                del target[key]
                with self.subTest(field=field, key=key), self.assertRaises(ValueError):
                    validate_reports(pair)

    def test_empty_wrong_types_and_unexpected_fields_are_rejected(self) -> None:
        for value in (None, {}, [], True, "报告", 4):
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_reports([value, reports()[1]])
        for pair in ([], reports()[:1], reports() + reports()):
            with self.assertRaises(ValueError):
                validate_reports(pair)
        changes = dict(schema_version=1, protocol_version=True, session_id="", round_id=False,
                       scenario=[], peer_id=1.0, host_id=0, game=[], complete=1, errors=["错误"],
                       last_error=None, roster={}, active_seats=[1, 1], phases=[], results=[],
                       finishes={}, disconnects={}, injection={}, metrics={}, content_hash="c" * 63)
        for field, value in changes.items():
            pair = reports()
            pair[0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_reports(pair)
        pair = reports()
        pair[0]["typo"] = 1
        with self.assertRaises(ValueError):
            validate_reports(pair)

    def test_cross_report_identity_and_content_must_match(self) -> None:
        for field, value in dict(session_id="c" * 32, round_id=2, protocol_version=2,
                                 peer_id=1, host_id=2, map_index=1, content_hash="c" * 64).items():
            pair = reports()
            pair[1][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_reports(pair)
        pair = reports()
        pair[1]["roster"][0]["name"] = "另一位合成玩家"
        with self.assertRaises(ValueError):
            validate_reports(pair)

    def test_roster_uniqueness_local_mapping_and_types(self) -> None:
        changes = ((1, "seat", 1), (1, "local_slot", 1), (0, "seat", True), (0, "peer_id", 0),
                   (0, "local_slot", 5), (0, "bot", 1), (0, "name", ""), (0, "name", "测" * 17),
                   (0, "name", "\ud800"), (0, "name", "名字\n"))
        for index, field, value in changes:
            pair = reports()
            pair[0]["roster"][index][field] = value
            with self.subTest(field=field, index=index), self.assertRaises(ValueError):
                validate_reports(pair)
        pair = reports()
        for row in pair[0]["roster"]:
            row["peer_id"] = 2
        with self.assertRaises(ValueError):
            validate_reports(pair)

    def test_finish_idempotency_and_score_ranking_are_distinct(self) -> None:
        changes = (("finishes", 1, "seat", 4), ("finishes", 1, "event_id", "finish-1"),
                   ("finishes", 1, "place", 1), ("finishes", 1, "bonus_count", 2),
                   ("finishes", 1, "bonus_count", True), ("results", 1, "rank", 2),
                   ("results", 0, "place", 1), ("results", 0, "score", -1),
                   ("results", 0, "score", True), ("results", 0, "score", 1 << 63))
        for field, index, key, value in changes:
            pair = reports()
            pair[0][field][index][key] = value
            with self.subTest(field=field, key=key), self.assertRaises(ValueError):
                validate_reports(pair)
        for change in (lambda r: r["results"].reverse(), lambda r: r["finishes"].pop(0),
                       lambda r: r["results"].pop()):
            pair = reports()
            change(pair[0])
            with self.assertRaises(ValueError):
                validate_reports(pair)
        pair = reports()
        pair[1]["results"][0]["score"] = 101
        pair[1]["results"][1]["rank"] = 2
        with self.assertRaises(ValueError):
            validate_reports(pair)

    def test_phase_clock_and_disconnect_invariants(self) -> None:
        for field, value in (("at_ms", 201), ("at_ms", True), ("phase", "RESULTS")):
            pair = reports()
            pair[1]["phases"][1][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                validate_reports(pair)
        for field, value in (("peer_id", 1), ("at_ms", 9999), ("reason", "")):
            pair = reports("client_left")
            pair[0]["disconnects"][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_reports(pair)
        for scenario in ("client_left", "host_left"):
            pair = reports(scenario)
            pair[1]["last_error"] = ""
            with self.assertRaises(ValueError):
                validate_reports(pair)
        pair = reports("client_left")
        pair[0]["active_seats"] = [1, 2, 3, 4]
        with self.assertRaises(ValueError):
            validate_reports(pair)

    def test_late_lobby_join_only_compares_synchronized_phases(self) -> None:
        pair = reports()
        for report in pair:
            for phase in report["phases"][1:]:
                phase["at_ms"] += 4000
        pair[1]["phases"][0]["at_ms"] = 3000
        validate_reports(pair)

    def test_disconnect_observation_can_wait_for_timeout(self) -> None:
        pair = reports("host_left")
        pair[1]["disconnects"][0]["at_ms"] = 8500
        pair[1]["phases"][-1]["at_ms"] = 8600
        validate_reports(pair)
        pair[1]["disconnects"][0]["at_ms"] = 9001
        pair[1]["phases"][-1]["at_ms"] = 9100
        with self.assertRaises(ValueError):
            validate_reports(pair)
        for report in pair:
            report["injection"].update(latency_ms=30, jitter_ms=10)
        validate_reports(pair)

    def test_metrics_reject_missing_work_nonfinite_and_wrong_types(self) -> None:
        changes = dict(snapshot_hz=30, sent_snapshots=1, received_snapshots=0, ghosts_seen=1,
                       clock_samples=7, window_ms=0, max_clock_error_ms=2.1, rtt_ms={},
                       max_remote_jump_m=-1)
        for field, value in changes.items():
            pair = reports()
            pair[0]["metrics"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_reports(pair)
        for value in (float("nan"), float("inf"), -float("inf"), True, "1", 10 ** 1000):
            for field in ("window_ms", "event_latency_p99_ms", "max_clock_error_ms"):
                pair = reports()
                pair[0]["metrics"][field] = value
                with self.subTest(field=field), self.assertRaises(ValueError):
                    validate_reports(pair)
        pair = reports()
        pair[0]["metrics"]["offset_ms"]["p50"] = 1
        with self.assertRaises(ValueError):
            validate_reports(pair)

    def test_file_loader_and_cli_success_failure_without_traceback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / f"报告{index}.json" for index in (1, 2)]
            for path, report in zip(paths, reports(), strict=True):
                path.write_text(json.dumps(report, ensure_ascii=False), encoding="utf-8")
            output = io.StringIO()
            with redirect_stdout(output):
                self.assertEqual(main([str(path) for path in paths]), 0)
            self.assertIn("不是实际 LAN", output.getvalue())
            invalid = (b"", b"null", b"[]", b"{}", b"\xff", b"{", b'{"key":1,"key":2}',
                       b'{"outer":{"key":1,"key":2}}', b'{"number":NaN}', b'{"number":Infinity}',
                       b"[" * 2000 + b"]" * 2000, b" " * (MAX_BYTES + 1))
            for data in invalid:
                paths[0].write_bytes(data)
                error = io.StringIO()
                with self.subTest(prefix=data[:20]), redirect_stderr(error):
                    self.assertEqual(main([str(path) for path in paths]), 1)
                    self.assertNotIn("Traceback", error.getvalue())
                    self.assertNotIn(directory, error.getvalue())
            paths[0].unlink()
            with redirect_stderr(io.StringIO()):
                self.assertEqual(main([str(path) for path in paths]), 1)
            paths[0].write_text('{"key":1,"key":2}', encoding="utf-8")
            with self.assertRaises(ValueError):
                load_report(paths[0])
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
            main([])
        self.assertEqual(caught.exception.code, 2)

    def test_cli_ascii_pipes_preserve_success_and_failure_exit_codes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / f"report-{index}.json" for index in (1, 2)]
            for path, report in zip(paths, reports(), strict=True):
                path.write_text(json.dumps(report), encoding="utf-8")
            command = [sys.executable, str(Path(__file__).resolve().parents[1] / "lan_report.py"),
                       *(str(path) for path in paths)]
            env = dict(os.environ, PYTHONIOENCODING="ascii")
            good = subprocess.run(command, capture_output=True, env=env, timeout=15)
            self.assertEqual(good.returncode, 0, good.stderr)
            self.assertTrue(good.stdout)
            self.assertNotIn(b"Traceback", good.stderr)
            paths[0].write_text("{}", encoding="utf-8")
            bad = subprocess.run(command, capture_output=True, env=env, timeout=15)
            self.assertEqual(bad.returncode, 1, bad.stderr)
            self.assertNotIn(b"Traceback", bad.stderr)


if __name__ == "__main__":
    unittest.main()
