"""The game catalog parser (tools/catalog.py) and the CI rule for ready game manifests."""
from __future__ import annotations

import copy
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import catalog

LEGACY = ("plane", "archery", "bowling", "skate", "ski", "basketball")


class CatalogTests(unittest.TestCase):
    def test_ready_manifests_are_complete(self) -> None:
        # CI rule: preview, lessons, solo goals and English text for every menu game.
        self.assertEqual(catalog.check(), [])

    def test_existing_games_keep_ids_order_and_maps(self) -> None:
        self.assertEqual(catalog.game_ids(), LEGACY)
        self.assertEqual([catalog.map_count(game) for game in LEGACY], [1, 1, 1, 1, 4, 2])
        self.assertEqual(catalog.benchmark_ids(), ("skate", "ski", "basketball"))
        self.assertEqual(catalog.module("ski")["maps"][3]["en"], "GLACIER STORM")
        self.assertEqual(catalog.module("basketball")["solo_goals"], [800, 2000, 3500])
        for game in LEGACY:
            self.assertEqual(catalog.module(game)["scene"], f"res://scenes/{game}/{game}_game.tscn")

    def test_tres_values_and_defaults(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "x_module.tres"
            path.write_text('[gd_resource type="Resource" format=3]\n\n[resource]\nscript = ExtResource("1")\n'
                            'id = "x"\ndesc = "line one\nsays \\"hi\\""\nlessons = PackedStringArray("AIM", "THROW")\n'
                            'solo_goals = PackedInt32Array(1, 2, 3)\nplayers = Vector2i(2, 4)\nready = true\n',
                            encoding="utf-8")
            module = catalog.parse_module(path)
        self.assertEqual(module["desc"], 'line one\nsays "hi"')
        self.assertEqual((module["lessons"], module["solo_goals"], module["players"]), (["AIM", "THROW"], [1, 2, 3], [2, 4]))
        self.assertEqual((module["ready"], module["order"], module["mode"], module["benchmark"]), (True, 100, "individual", False))

    def test_maps_parser_skips_nested_values_strings_and_comments(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            script = Path(temp) / "maps.gd"
            script.write_text('const OTHER := [{"name": "no"}]\nconst MAPS := [\n\t# {"name": "comment"}\n'
                              '\t{"name": "甲", "en": "A [1]", "nested": {"name": "inner"}, "p": [[0, 1]]},\n'
                              '\t{"en": "B \\"}\\"", "name": "乙", "c": Color(1, 0, 0)},\n]\n', encoding="utf-8")
            with mock.patch.object(catalog, "_res", return_value=script):
                maps = catalog.maps_of({"maps_script": "res://maps.gd"})
        self.assertEqual(maps, [{"name": "甲", "en": "A [1]"}, {"name": "乙", "en": 'B "}"'}])
        self.assertEqual(catalog.maps_of({"maps_script": ""}), [])

    def test_invalid_manifests_are_rejected(self) -> None:
        good = copy.deepcopy(catalog.module("ski"))
        self.assertEqual(catalog.problem(good, "ski"), "")
        for change, folder in (({}, "skate"), ({"oled": "Ski"}, "ski"), ({"oled": "滑雪"}, "ski"),
                               ({"players": [0, 4]}, "ski"), ({"mode": "solo"}, "ski"), ({"desc": ""}, "ski"),
                               ({"scene": "res://scenes/ski/missing.tscn"}, "ski")):
            with self.subTest(change=change):
                self.assertNotEqual(catalog.problem({**good, **change}, folder), "")

    def test_check_reports_incomplete_ready_games(self) -> None:
        broken = copy.deepcopy(catalog.modules())
        broken[0].update(lessons=["NOT_A_STEP"], solo_goals=[5, 1, 9], name="未翻译的名字", preview="")
        with mock.patch.object(catalog, "modules", return_value=broken):
            errors = "\n".join(catalog.check())
        for part in ("lessons", "solo_goals", "English", "preview"):
            self.assertIn(part, errors)

    def test_compare_with_the_game_dump(self) -> None:
        dump = {"version": 1, "games": copy.deepcopy(catalog.modules(include_hidden=True))}
        self.assertEqual(catalog.compare(dump), [])
        dump["games"][0]["order"] = -1
        dump["games"].pop()
        self.assertEqual(len(catalog.compare(dump)), 3)
        self.assertEqual(catalog.compare({}), ["dump has no games list"])


if __name__ == "__main__":
    unittest.main()
