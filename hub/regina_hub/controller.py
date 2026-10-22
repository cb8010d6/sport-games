"""One connected controller (Regina, phone, simulator or replay), source-agnostic."""

from __future__ import annotations

import math
from typing import Any, Protocol

from .fusion import FusedSample, ImuPipeline, TimeMapper
from .protocol import BTN_D, UiState
from .quat import Vec3

RECENTER_HOLD_S = 1.0
LOW_BATTERY_PCT = 15


class Transport(Protocol):
    """Downlink to the physical device. Implementations must not block (schedule work instead)."""

    def send_ui(self, ui: dict[str, Any]) -> None: ...
    def beep(self, freq: int, ms: int) -> None: ...
    def vibrate(self, pattern: list[int]) -> None: ...   # [on, off, on, ...] ms
    def set_player(self, player: int) -> None: ...
    def notify_event(self, name: str) -> None: ...


class NullTransport:
    def send_ui(self, ui: dict[str, Any]) -> None:
        pass

    def beep(self, freq: int, ms: int) -> None:
        pass

    def vibrate(self, pattern: list[int]) -> None:
        pass

    def set_player(self, player: int) -> None:
        pass

    def notify_event(self, name: str) -> None:
        pass


class Controller:
    def __init__(self, cid: int, kind: str, key: str, name: str, transport: Transport, rate_hint_hz: float, wrap_bits: int | None):
        self.id = cid
        self.kind = kind
        self.key = key
        self.name = name
        self.transport = transport
        self.player = 0
        self.connected = True
        self.battery: int | None = None
        self.charging = False
        self.buttons = 0
        self.dial_small = 0
        self.dial_big = 0
        self.analog = (0.0, 0.0)
        self.ui = UiState()
        self.pipeline = ImuPipeline(rate_hint_hz)
        self.clock = TimeMapper(wrap_bits=wrap_bits)
        self.extra: dict[str, Any] = {}
        self.predict_s = 0.0           ## orientation sent this far ahead (hides link latency)
        self._d_since: float | None = None
        self._d_fired = False
        self._low_batt_sent = False
        self._last_seq: int | None = None
        self.packets = 0
        self.lost_packets = 0

    # ------------------------------------------------------------------ uplink ----

    def note_seq(self, seq: int) -> None:
        if self._last_seq is not None:
            gap = (seq - self._last_seq - 1) & 0xFF
            if gap < 128:
                self.lost_packets += gap
        self._last_seq = seq
        self.packets += 1

    @property
    def loss_ratio(self) -> float:
        total = self.packets + self.lost_packets
        return self.lost_packets / total if total else 0.0

    def ingest_imu(self, items: list[tuple[float, Vec3, Vec3]], hub_now: float) -> list[FusedSample]:
        """items: (device_time_us, gyro rad/s canonical, accel m/s^2 canonical)."""
        out: list[FusedSample] = []
        if not items:
            return out
        dev_times = [self.clock.device_seconds(raw_us) for raw_us, _, _ in items]
        self.clock.observe(dev_times[-1], hub_now)
        for dev_s, (_, gyro, accel) in zip(dev_times, items, strict=False):
            if not all(math.isfinite(v) for v in (*gyro, *accel)):
                continue
            # Integrate on the device clock (exact dt); only the reported time is hub-mapped.
            s = self.pipeline.push(dev_s, gyro, accel)
            if s is not None:
                s.t = self.clock.to_hub(dev_s)
                out.append(s)
        return out

    def ingest_input(self, buttons: int, small: int, big: int, analog: tuple[float, float], now: float) -> None:
        was_d = bool(self.buttons & BTN_D)
        self.buttons = buttons
        self.dial_small = small
        self.dial_big = big
        self.analog = analog
        is_d = bool(buttons & BTN_D)
        if is_d and not was_d:
            self._d_since = now
            self._d_fired = False
        elif not is_d:
            self._d_since = None
            self._d_fired = False

    def ingest_status(self, battery: int | None, charging: bool) -> list[str]:
        self.battery = battery
        self.charging = charging
        events: list[str] = []
        if battery is not None and not charging and battery < LOW_BATTERY_PCT:
            if not self._low_batt_sent:
                self._low_batt_sent = True
                events.append("low_battery")
        elif battery is not None and (charging or battery >= LOW_BATTERY_PCT + 5):
            self._low_batt_sent = False
        return events

    def tick(self, now: float) -> list[str]:
        """Periodic housekeeping; returns events (e.g. long-press recenter)."""
        if self._d_since is not None and not self._d_fired and now - self._d_since >= RECENTER_HOLD_S:
            self._d_fired = True
            self.pipeline.recenter()
        events = list(self.pipeline.events)
        self.pipeline.events.clear()
        return events

    # ---------------------------------------------------------------- downlink ----

    def apply_ui(self, ui: dict[str, Any]) -> None:
        self.ui.apply(ui)
        self.transport.send_ui(ui)

    def roster_entry(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "kind": self.kind,
            "name": self.name,
            "player": self.player,
            "connected": self.connected,
            "battery": self.battery,
            "charging": self.charging,
            "calibrated": self.pipeline.bias.calibrated,
            "calibrating": self.pipeline.bias.calibrating,
            "stationary": self.pipeline.bias.stationary,
            "rate_hz": round(self.pipeline.rate_hz, 1),
            "loss": round(self.loss_ratio, 4),
            **self.extra,
        }
