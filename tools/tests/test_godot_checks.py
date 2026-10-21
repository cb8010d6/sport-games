import sys

import pytest

from tools.smoke_game import checked_run


@pytest.mark.parametrize("error", ["SCRIPT ERROR: bad script", "ERROR: Missing texture", "Parse Error: bad syntax"])
def test_godot_zero_exit_does_not_hide_errors(error):
    with pytest.raises(RuntimeError):
        checked_run([sys.executable, "-c", f"print({error!r})"])


def test_shutdown_diagnostic_remains_visible(capsys):
    checked_run([sys.executable, "-c", "print('ERROR: 9 resources still in use at exit (run with --verbose for details).')"])
    assert "retained at shutdown" in capsys.readouterr().out
