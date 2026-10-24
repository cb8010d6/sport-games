"""Wire formats. Keep in sync with docs/protocol.md, firmware/main/protocol.h and game/autoload/controller_hub.gd."""

from __future__ import annotations

import math
import struct
from dataclasses import dataclass, field
from typing import Any

# ---------------------------------------------------------------- BLE (Regina) ----

SERVICE_UUID = "5253a000-6a2e-4c1f-9b7e-726567696e61"
IMU_CHAR_UUID = "5253a001-6a2e-4c1f-9b7e-726567696e61"
INPUT_CHAR_UUID = "5253a002-6a2e-4c1f-9b7e-726567696e61"
STATUS_CHAR_UUID = "5253a003-6a2e-4c1f-9b7e-726567696e61"
CMD_CHAR_UUID = "5253a004-6a2e-4c1f-9b7e-726567696e61"
DEVICE_NAME_PREFIX = "Regina-"

# Original Regina firmware (Forairaaaaa/Regina): 20 Hz float accel/gyro, no timestamps.
LEGACY_NAME = "Reginaaaa:)"
LEGACY_SERVICE_UUID = "00002333-0000-1000-8000-00805f9b34fb"
LEGACY_INPUT_UUID = "00002334-0000-1000-8000-00805f9b34fb"
LEGACY_ACCEL_UUID = "00002335-0000-1000-8000-00805f9b34fb"
LEGACY_GYRO_UUID = "00002336-0000-1000-8000-00805f9b34fb"

PKT_IMU = 0x01
PKT_INPUT = 0x02
PKT_STATUS = 0x03

OP_SET_PLAYER = 0x01
OP_BEEP = 0x04
OP_VIBRATE = 0x05
OP_SET_ROTATION = 0x06
OP_UI = 0x10

UI_CLEAR = 0x00
UI_TITLE = 0x01
UI_MAIN = 0x02
UI_SUB = 0x03
UI_BAR = 0x04
UI_LEGEND_A = 0x05
UI_TOAST = 0x09
UI_BAR_HIDDEN = 255
UI_MAX_STR = 40

ACCEL_RANGES_G = (2.0, 4.0, 8.0, 16.0)
GYRO_RANGES_DPS = (2000.0, 1000.0, 500.0, 250.0, 125.0)

BTN_A, BTN_B, BTN_C, BTN_D = 1, 2, 4, 8

_IMU_HDR = struct.Struct("<BBBBI")
_IMU_SAMPLE = struct.Struct("<Hhhhhhh")
_INPUT = struct.Struct("<BBhhI")
_STATUS = struct.Struct("<BBBBBB")


@dataclass
class RawImuSample:
    t_us: int                      # device clock, 32-bit wrapping
    accel_g: tuple[float, float, float]
    gyro_dps: tuple[float, float, float]


@dataclass
class ImuPacket:
    seq: int
    samples: list[RawImuSample]


@dataclass
class InputPacket:
    buttons: int
    dial_small: int
    dial_big: int
    t_us: int


@dataclass
class StatusPacket:
    battery: int | None
    charging: bool
    imu_ok: bool
    imu_irq: bool
    fw: tuple[int, int]
    player: int


def parse_imu(data: bytes) -> ImuPacket:
    typ, seq, n, ranges, t0 = _IMU_HDR.unpack_from(data, 0)
    if typ != PKT_IMU:
        raise ValueError(f"not an IMU packet: type {typ:#x}")
    need = _IMU_HDR.size + n * _IMU_SAMPLE.size
    if len(data) < need:
        raise ValueError(f"IMU packet too short: {len(data)} < {need}")
    a_scale = ACCEL_RANGES_G[ranges & 0x3] / 32768.0
    g_scale = GYRO_RANGES_DPS[min((ranges >> 2) & 0x7, len(GYRO_RANGES_DPS) - 1)] / 32768.0
    out: list[RawImuSample] = []
    t = t0
    off = _IMU_HDR.size
    for i in range(n):
        dt, ax, ay, az, gx, gy, gz = _IMU_SAMPLE.unpack_from(data, off)
        off += _IMU_SAMPLE.size
        if i > 0:
            t = (t + dt) & 0xFFFFFFFF
        out.append(
            RawImuSample(
                t_us=t,
                accel_g=(ax * a_scale, ay * a_scale, az * a_scale),
                gyro_dps=(gx * g_scale, gy * g_scale, gz * g_scale),
            )
        )
    return ImuPacket(seq=seq, samples=out)


def build_imu(seq: int, t0_us: int, samples: list[tuple[int, int, int, int, int, int, int]], ranges: int = 0x02) -> bytes:
    """Test helper / reference encoder: samples are (dt_us, ax, ay, az, gx, gy, gz) raw LSB."""
    out = bytearray(_IMU_HDR.pack(PKT_IMU, seq & 0xFF, len(samples), ranges, t0_us & 0xFFFFFFFF))
    for s in samples:
        out += _IMU_SAMPLE.pack(*s)
    return bytes(out)


def parse_input(data: bytes) -> InputPacket:
    typ, buttons, small, big, t = _INPUT.unpack_from(data, 0)
    if typ != PKT_INPUT:
        raise ValueError(f"not an input packet: type {typ:#x}")
    return InputPacket(buttons=buttons, dial_small=small, dial_big=big, t_us=t)


def build_input(buttons: int, small: int, big: int, t_us: int) -> bytes:
    return _INPUT.pack(PKT_INPUT, buttons, small, big, t_us & 0xFFFFFFFF)


def parse_status(data: bytes) -> StatusPacket:
    typ, batt, flags, major, minor, player = _STATUS.unpack_from(data, 0)
    if typ != PKT_STATUS:
        raise ValueError(f"not a status packet: type {typ:#x}")
    return StatusPacket(
        battery=None if batt == 255 else batt,
        charging=bool(flags & 1),
        imu_ok=bool(flags & 2),
        imu_irq=bool(flags & 4),
        fw=(major, minor),
        player=player,
    )


def build_status(battery: int | None, charging: bool, imu_ok: bool, imu_irq: bool, fw: tuple[int, int], player: int) -> bytes:
    flags = (1 if charging else 0) | (2 if imu_ok else 0) | (4 if imu_irq else 0)
    return _STATUS.pack(PKT_STATUS, 255 if battery is None else battery, flags, fw[0], fw[1], player)


def cmd_set_player(player: int) -> bytes:
    return struct.pack("<BB", OP_SET_PLAYER, player & 0xFF)


def cmd_beep(freq: int, ms: int) -> bytes:
    return struct.pack("<BHH", OP_BEEP, max(0, min(20000, int(freq))), max(0, min(5000, int(ms))))


def cmd_vibrate(ms: int) -> bytes:
    return struct.pack("<BH", OP_VIBRATE, max(0, min(5000, int(ms))))


VIBE_MAX_STEPS = 16
VIBE_MAX_TOTAL_MS = 3000


def normalize_vibe(msg: dict[str, Any]) -> list[int]:
    """A game's vibrate command as a pattern: [on, off, on, ...] in ms, like the web's
    navigator.vibrate. Takes "pattern" if given, else a single "ms" pulse (default 60).
    Clamped to 16 steps, 1 s a step and 3 s in all; [] when there is nothing to play."""
    raw = msg.get("pattern")
    if not isinstance(raw, list):
        raw = [msg.get("ms", 60)]
    out: list[int] = []
    total = 0
    for v in raw[:VIBE_MAX_STEPS]:
        try:
            ms = max(0, min(1000, int(v)))
        except (TypeError, ValueError):
            ms = 0
        ms = min(ms, VIBE_MAX_TOTAL_MS - total)
        out.append(ms)
        total += ms
    while out and (out[-1] == 0 or len(out) % 2 == 0):
        out.pop()        # a pattern ends on a pulse
    return out


def cmd_set_rotation(rotation: int) -> bytes:
    """OLED rotation 0..3 (LovyanGFX convention); 1 and 3 are portrait."""
    return struct.pack("<BB", OP_SET_ROTATION, int(rotation) & 3)


# ------------------------------------------------------------------- UI model ----


def _ascii(s: Any) -> bytes:
    text = "" if s is None else str(s)
    return text.encode("ascii", "replace")[:UI_MAX_STR]


def normalize_ui(ui: dict[str, Any]) -> dict[str, Any]:
    """Validate a game-supplied UI dict; returns only known keys with sane types."""
    out: dict[str, Any] = {}
    if ui.get("clear"):
        out["clear"] = True
    for key in ("title", "main", "sub"):
        if key in ui:
            out[key] = "" if ui[key] is None else str(ui[key])[:UI_MAX_STR]
    if "bar" in ui:
        bar = ui["bar"]
        if bar is None:
            out["bar"] = None
        else:
            pct = int(max(0, min(100, float(bar.get("pct", 0)))))
            out["bar"] = {"pct": pct, "label": str(bar.get("label", ""))[:UI_MAX_STR]}
    if "legends" in ui:
        leg = list(ui["legends"] or [])[:4]
        leg += [None] * (4 - len(leg))
        out["legends"] = [None if v is None else str(v)[:UI_MAX_STR] for v in leg]
    if "toast" in ui and ui["toast"]:
        t = ui["toast"]
        out["toast"] = {"ms": int(max(100, min(10000, int(t.get("ms", 1000))))), "text": str(t.get("text", ""))[:UI_MAX_STR]}
    return out


def encode_ui_tlv(ui: dict[str, Any]) -> bytes:
    """Encode a normalized UI dict as the BLE OLED command (opcode + TLVs). Non-ASCII becomes '?'."""
    out = bytearray([OP_UI])

    def tlv(tag: int, payload: bytes) -> None:
        out.append(tag)
        out.append(len(payload))
        out.extend(payload)

    if ui.get("clear"):
        tlv(UI_CLEAR, b"")
    for key, tag in (("title", UI_TITLE), ("main", UI_MAIN), ("sub", UI_SUB)):
        if key in ui:
            tlv(tag, _ascii(ui[key]))
    if "bar" in ui:
        bar = ui["bar"]
        if bar is None:
            tlv(UI_BAR, bytes([UI_BAR_HIDDEN]))
        else:
            tlv(UI_BAR, bytes([bar["pct"]]) + _ascii(bar.get("label", "")))
    if "legends" in ui:
        for i, text in enumerate(ui["legends"]):
            if text is not None:
                tlv(UI_LEGEND_A + i, _ascii(text))
    if "toast" in ui:
        t = ui["toast"]
        tlv(UI_TOAST, struct.pack("<H", t["ms"]) + _ascii(t["text"]))
    return bytes(out)


def decode_ui_tlv(data: bytes) -> dict[str, Any]:
    """Reference decoder (mirrors the firmware parser); used by tests."""
    if not data or data[0] != OP_UI:
        raise ValueError("not a UI command")
    ui: dict[str, Any] = {}
    i = 1
    while i + 2 <= len(data):
        tag, ln = data[i], data[i + 1]
        payload = data[i + 2 : i + 2 + ln]
        i += 2 + ln
        if tag == UI_CLEAR:
            ui["clear"] = True
        elif tag in (UI_TITLE, UI_MAIN, UI_SUB):
            ui[{UI_TITLE: "title", UI_MAIN: "main", UI_SUB: "sub"}[tag]] = payload.decode("ascii")
        elif tag == UI_BAR:
            ui["bar"] = None if payload[0] == UI_BAR_HIDDEN else {"pct": payload[0], "label": payload[1:].decode("ascii")}
        elif UI_LEGEND_A <= tag <= UI_LEGEND_A + 3:
            ui.setdefault("legends", [None] * 4)[tag - UI_LEGEND_A] = payload.decode("ascii")
        elif tag == UI_TOAST:
            ui["toast"] = {"ms": struct.unpack_from("<H", payload)[0], "text": payload[2:].decode("ascii")}
    return ui


# ------------------------------------------------------------ hub -> game (UDP) ----

GAME_PORT = 47800
HUB_PORT = 47801
HTTP_PORT = 47802
HTTPS_PORT = 47843

MSG_SAMPLES = 0x53  # 'S'
MSG_INPUT = 0x49    # 'I'
GAME_PROTO_VERSION = 1

_GS_HDR = struct.Struct("<BBBB")
_GS_SAMPLE = struct.Struct("<d4f3f3f3f")
_GI = struct.Struct("<BBBBhhff")
MAX_SAMPLES_PER_DATAGRAM = 16


def build_game_samples(controller_id: int, samples: list[Any]) -> list[bytes]:
    """samples: FusedSample-like objects. Splits into datagrams of at most MAX_SAMPLES_PER_DATAGRAM."""
    out: list[bytes] = []
    for start in range(0, len(samples), MAX_SAMPLES_PER_DATAGRAM):
        chunk = samples[start : start + MAX_SAMPLES_PER_DATAGRAM]
        buf = bytearray(_GS_HDR.pack(MSG_SAMPLES, GAME_PROTO_VERSION, controller_id, len(chunk)))
        for s in chunk:
            w, x, y, z = s.q
            buf += _GS_SAMPLE.pack(s.t, x, y, z, w, *s.gyro, *s.accel, *s.lin_world)
        out.append(bytes(buf))
    return out


def parse_game_samples(data: bytes) -> tuple[int, list[tuple[float, ...]]]:
    typ, ver, cid, n = _GS_HDR.unpack_from(data, 0)
    if typ != MSG_SAMPLES or ver != GAME_PROTO_VERSION:
        raise ValueError("not a samples datagram")
    return cid, [_GS_SAMPLE.unpack_from(data, _GS_HDR.size + i * _GS_SAMPLE.size) for i in range(n)]


def build_game_input(controller_id: int, buttons: int, small: int, big: int, analog0: float = 0.0, analog1: float = 0.0) -> bytes:
    def clamp16(v: int) -> int:
        return max(-32768, min(32767, int(v)))

    a0 = 0.0 if not math.isfinite(analog0) else float(analog0)
    a1 = 0.0 if not math.isfinite(analog1) else float(analog1)
    return _GI.pack(MSG_INPUT, GAME_PROTO_VERSION, controller_id, buttons & 0xFF, clamp16(small), clamp16(big), a0, a1)


SAMPLE_DATAGRAM_SIZE = _GS_SAMPLE.size
INPUT_DATAGRAM_SIZE = _GI.size


@dataclass
class UiState:
    """Last full UI per controller, so a reconnecting device gets its screen back."""

    fields: dict[str, Any] = field(default_factory=dict)

    def apply(self, ui: dict[str, Any]) -> None:
        if ui.get("clear"):
            self.fields = {}
        for k, v in ui.items():
            if k in ("clear", "toast"):
                continue
            if k == "legends":
                cur = list(self.fields.get("legends", [None] * 4))
                for i, text in enumerate(v):
                    if text is not None:
                        cur[i] = text
                self.fields["legends"] = cur
            else:
                self.fields[k] = v

    def snapshot(self) -> dict[str, Any]:
        snap = {"clear": True}
        snap.update(self.fields)
        return snap


def parse_legacy_input(data: bytes) -> InputPacket:
    a, b, c, d, _va, _vb, small, big = struct.unpack_from("<????BBhh", data, 0)
    buttons = (BTN_A if a else 0) | (BTN_B if b else 0) | (BTN_C if c else 0) | (BTN_D if d else 0)
    return InputPacket(buttons=buttons, dial_small=small, dial_big=big, t_us=0)


def parse_legacy_vec3(data: bytes) -> tuple[float, float, float]:
    return struct.unpack_from("<fff", data, 0)
