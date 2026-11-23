"""--ble-selftest must fail the release when the BLE backend was not bundled, but tolerate a machine without Bluetooth."""
import importlib.metadata
import re
import sys

import pytest
from bleak.exc import BleakBluetoothNotAvailableError, BleakBluetoothNotAvailableReason, BleakError

from regina_hub import ble_selftest
from regina_hub.__main__ import main, parse_args


def test_success_and_missing_modules_are_told_apart():
    assert ble_selftest.classify(None)[0] == ble_selftest.OK
    missing = ModuleNotFoundError("No module named 'winrt.windows.foundation.collections'")
    assert ble_selftest.classify(missing)[0] == ble_selftest.MISSING
    assert ble_selftest.classify(ImportError("DLL load failed while importing _winrt"))[0] == ble_selftest.MISSING


@pytest.mark.parametrize("error", [
    BleakBluetoothNotAvailableError("no radio", BleakBluetoothNotAvailableReason.NO_BLUETOOTH),
    BleakError("No Bluetooth adapters found."),
    OSError("The device is not ready: Bluetooth radio unavailable"),
])
def test_no_adapter_on_the_build_machine_is_accepted(error):
    assert ble_selftest.classify(error)[0] == ble_selftest.OK


@pytest.mark.parametrize("error", [RuntimeError("boom"), BleakError("unexpected state"), OSError("access denied")])
def test_unexplained_errors_fail(error):
    assert ble_selftest.classify(error)[0] == ble_selftest.FAILED


def test_every_winrt_projection_bleak_requires_is_checked():
    names = [re.match(r"[A-Za-z0-9_.-]+", r).group(0).lower() for r in importlib.metadata.requires("bleak") or []]
    required = [n for n in names if n.startswith("winrt-windows-")]
    assert required, "bleak no longer lists its WinRT projections; update WINDOWS_BACKEND"
    for distribution in required:
        assert "winrt." + distribution.removeprefix("winrt-").replace("-", ".") in ble_selftest.WINDOWS_BACKEND


def test_missing_backend_module_fails_the_run(monkeypatch, capsys):
    # What a frozen build that did not bundle the WinRT projections looks like.
    for name in [m for m in sys.modules if m.startswith("bleak.backends.winrt")]:
        monkeypatch.delitem(sys.modules, name)
    monkeypatch.setitem(sys.modules, "winrt.windows.devices.bluetooth", None)
    monkeypatch.setattr(ble_selftest.sys, "platform", "win32")
    assert ble_selftest.run() == ble_selftest.MISSING
    assert "ModuleNotFoundError" in capsys.readouterr().out


def test_selftest_flag_exits_with_the_classified_code(monkeypatch):
    assert parse_args(["--ble-selftest"]).ble_selftest
    monkeypatch.setattr(ble_selftest, "run", lambda: ble_selftest.MISSING)
    with pytest.raises(SystemExit) as stopped:
        main(["--ble-selftest"])
    assert stopped.value.code == ble_selftest.MISSING
