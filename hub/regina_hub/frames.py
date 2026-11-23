"""Axis remapping from each source's sensor frame into the canonical controller body frame.

Canonical body frame (see docs/protocol.md section 1): +X right, +Y up (screen side), -Z forward (tip).
An axis map is three strings, one per canonical axis, naming the source axis that feeds it,
e.g. ["x", "z", "-y"] means canonical X = +src.x, Y = +src.z, Z = -src.y.
"""

from __future__ import annotations

from collections.abc import Callable, Sequence

from .quat import Vec3

# Phone W3C device frame: x right, y toward the top of the screen, z out of the screen.
# Held like a TV remote (top toward the TV, screen facing up): forward = +y, up = +z.
PHONE_AXIS_MAP = ("x", "z", "-y")

# Assumed BMI270 placement on the Regina PCB: same convention as a phone lying screen-up
# with its top as the controller tip. Verify with the Godot debug scene and override with
# "regina_axis_map" in hub/config.json if the model moves the wrong way.
REGINA_DEFAULT_AXIS_MAP = ("x", "z", "-y")

CANONICAL_AXIS_MAP = ("x", "y", "z")

_INDEX = {"x": 0, "y": 1, "z": 2}


def make_remap(axis_map: Sequence[str]) -> Callable[[Vec3], Vec3]:
    if len(axis_map) != 3:
        raise ValueError(f"axis map needs 3 entries, got {axis_map!r}")
    picks: list[tuple[int, float]] = []
    for entry in axis_map:
        e = entry.strip().lower()
        sign = -1.0 if e.startswith("-") else 1.0
        name = e.lstrip("+-")
        if name not in _INDEX:
            raise ValueError(f"bad axis {entry!r} in {axis_map!r}")
        picks.append((_INDEX[name], sign))
    if sorted(i for i, _ in picks) != [0, 1, 2]:
        raise ValueError(f"axis map must use x, y and z exactly once: {axis_map!r}")
    (i0, s0), (i1, s1), (i2, s2) = picks

    def remap(v: Vec3) -> Vec3:
        return (s0 * v[i0], s1 * v[i1], s2 * v[i2])

    return remap


def handedness(axis_map: Sequence[str]) -> float:
    """+1 for a proper rotation, -1 for a mirroring map (which would be a configuration error)."""
    remap = make_remap(axis_map)
    ex, ey, ez = remap((1.0, 0.0, 0.0)), remap((0.0, 1.0, 0.0)), remap((0.0, 0.0, 1.0))
    det = (
        ex[0] * (ey[1] * ez[2] - ey[2] * ez[1])
        - ey[0] * (ex[1] * ez[2] - ex[2] * ez[1])
        + ez[0] * (ex[1] * ey[2] - ex[2] * ey[1])
    )
    return 1.0 if det > 0 else -1.0
