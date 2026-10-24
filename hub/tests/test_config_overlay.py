"""Personal overrides in config.local.json overlay the tracked config.json (#51)."""

import json

import pytest

from regina_hub.__main__ import load_config


def _write(path, data):
    path.write_text(json.dumps(data), encoding="utf-8")


def test_local_config_overlays_base(tmp_path):
    _write(tmp_path / "config.json", {"regina_screen_rotation": 1, "lan_ip": "10.0.0.8"})
    _write(tmp_path / "config.local.json", {"regina_screen_rotation": 2})
    cfg = load_config(tmp_path / "config.json")
    assert cfg["regina_screen_rotation"] == 2
    assert cfg["lan_ip"] == "10.0.0.8"


def test_no_local_config_is_fine(tmp_path):
    _write(tmp_path / "config.json", {"regina_screen_rotation": 1})
    assert load_config(tmp_path / "config.json")["regina_screen_rotation"] == 1


def test_explicit_local_config_is_not_overlaid_twice(tmp_path):
    _write(tmp_path / "config.local.json", {"regina_screen_rotation": 0})
    assert load_config(tmp_path / "config.local.json")["regina_screen_rotation"] == 0


def test_mirrored_local_axis_map_is_rejected(tmp_path):
    _write(tmp_path / "config.local.json", {"regina_axis_map": ["-x", "z", "-y"]})
    with pytest.raises(SystemExit):
        load_config(tmp_path / "config.json")
