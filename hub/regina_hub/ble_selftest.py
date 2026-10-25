"""--ble-selftest: prove the (frozen) hub can load its BLE backend without starting a scan."""

from __future__ import annotations

import asyncio
import importlib
import sys

OK = 0
MISSING = 2  # backend modules were not bundled: the release would silently lose Regina support
FAILED = 3  # anything else we cannot explain as "no Bluetooth here"

# Imported by name on purpose: a literal import would let PyInstaller trace and bundle these modules for the
# self-test itself, hiding exactly the packaging gap (--collect-submodules) this check exists to catch.
# The winrt projections are bleak's Windows requirements; some (e.g. foundation.collections) are only imported by
# native code once a scan or connection returns data, so constructing a scanner alone would not notice them missing.
WINDOWS_BACKEND = (
    "bleak.backends.winrt.scanner",
    "bleak.backends.winrt.client",
    "winrt.system",
    "winrt.windows.devices.bluetooth",
    "winrt.windows.devices.bluetooth.advertisement",
    "winrt.windows.devices.bluetooth.genericattributeprofile",
    "winrt.windows.devices.enumeration",
    "winrt.windows.devices.radios",
    "winrt.windows.foundation",
    "winrt.windows.foundation.collections",
    "winrt.windows.storage.streams",
)
UNAVAILABLE_WORDS = ("adapter", "bluetooth", "radio")


def bluetooth_unavailable(exc: BaseException) -> bool:
    """A clear "this machine has no usable Bluetooth" error; the backend itself loaded fine."""
    if any(cls.__name__ == "BleakBluetoothNotAvailableError" for cls in type(exc).__mro__):
        return True
    is_bleak_error = any(cls.__name__ == "BleakError" for cls in type(exc).__mro__)
    if not (is_bleak_error or isinstance(exc, OSError)):
        return False
    text = str(exc).lower()
    return any(word in text for word in UNAVAILABLE_WORDS)


def classify(exc: BaseException | None) -> tuple[int, str]:
    if exc is None:
        return OK, "BLE backend loaded and BleakScanner constructed"
    if isinstance(exc, ImportError):  # includes ModuleNotFoundError and "DLL load failed"
        return MISSING, f"BLE backend missing from this build: {type(exc).__name__}: {exc}"
    if bluetooth_unavailable(exc):
        return OK, f"BLE backend loaded; Bluetooth unavailable on this machine: {exc}"
    return FAILED, f"BLE self-test failed: {type(exc).__name__}: {exc}"


async def _construct_scanner() -> None:
    if sys.platform == "win32":
        for name in WINDOWS_BACKEND:
            importlib.import_module(name)
    bleak = importlib.import_module("bleak")
    bleak.BleakScanner()  # constructing selects and builds the platform backend; it does not scan


def run() -> int:
    try:
        asyncio.run(_construct_scanner())
        error = None
    except Exception as exc:  # classified below; nothing else may escape as a traceback
        error = exc
    code, message = classify(error)
    print(message, flush=True)
    return code
