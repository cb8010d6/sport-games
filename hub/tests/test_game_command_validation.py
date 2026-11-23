"""Malformed game commands are rejected without corrupting later valid UI."""

import pytest

from regina_hub.controller import NullTransport
from regina_hub.hub import Hub


@pytest.mark.parametrize("command", [
    {"cmd": "ui", "ui": {"bar": 5}},
    {"cmd": "ui", "ui": {"toast": "invalid"}},
    {"cmd": "set_player", "controller": float("inf"), "player": 1},
    {"cmd": "recenter", "controller": float("inf")},
    {"cmd": "beep", "freq": float("inf")},
])
def test_bad_command_then_valid_ui(command, caplog):
    hub = Hub()
    controller = hub.attach("sim", "fixture", "fixture", NullTransport(), 100, None)
    for _ in range(5):
        hub.handle_game_command(command)
    assert sum("invalid game command" in r.message for r in caplog.records) == 1
    hub.handle_game_command({"cmd": "ui", "ui": {"title": "STILL OK"}})
    assert controller.ui.snapshot()["title"] == "STILL OK"
