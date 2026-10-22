"""Packaging must not write certificates into the frozen distribution directory."""
from regina_hub.__main__ import parse_args


def test_data_directory_is_explicit_and_does_not_change_config(tmp_path):
    config = tmp_path / "custom.json"
    data = tmp_path / "runtime-data"
    options = parse_args(["--config", str(config), "--data-dir", str(data), "--no-ble"])
    assert options.config == config
    assert options.data_dir == data
    assert options.no_ble
