"""Privacy-safe diagnostic formatting and bounded warning frequency."""

from __future__ import annotations

import logging
import re
import time

_DEVICE_ADDRESS = re.compile(
    r"(?<![0-9a-f])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f])"
    r"|\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b"
    # Linux BlueZ object paths embed the address with underscores instead of
    # colons (/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF); Bleak and dbus errors
    # carry that full path, so the underscore form must be redacted too.
    r"|\bdev_(?:[0-9a-f]{2}_){5}[0-9a-f]{2}\b"
    r"|(?<![0-9a-f_])(?:[0-9a-f]{2}_){5}[0-9a-f]{2}(?![0-9a-f_])",
    re.IGNORECASE,
)


def redact_devices(value: object) -> str:
    """Remove MAC addresses and platform BLE UUIDs, including those in exceptions."""
    return _DEVICE_ADDRESS.sub("<device>", str(value))


class PrivateFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        # Format first so third-party messages and traceback text are covered too.
        return redact_devices(super().format(record))


class WarningLimiter:
    """One warning category per instance; report a count at most once per minute."""

    def __init__(self) -> None:
        self._last: float | None = None
        self._count = 0

    def warning(self, logger: logging.Logger, message: str, *args: object) -> None:
        self._count += 1
        now = time.monotonic()
        if self._last is None or now - self._last >= 60.0:
            logger.warning(message + " (%d occurrences since last report)", *args, self._count)
            self._last = now
            self._count = 0
