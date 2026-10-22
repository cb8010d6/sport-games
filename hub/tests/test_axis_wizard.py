import itertools

import pytest
from regina_hub.axis_wizard import _invert, solve
from regina_hub.frames import handedness, make_remap

G = 9.81


def _proper_maps():
    for perm in itertools.permutations("xyz"):
        for signs in itertools.product("+-", repeat=3):
            m = [("-" if s == "-" else "") + a for s, a in zip(signs, perm, strict=False)]
            if handedness(m) > 0:
                yield m


@pytest.mark.parametrize("true_map", list(_proper_maps()))
def test_solve_recovers_any_mounting(true_map):
    # Raw chip readings that a chip mounted per `true_map` would give in the two poses.
    to_raw = _invert(true_map)
    up_raw = to_raw((0.0, G, 0.0))          # flat, screen up: gravity reaction along canonical +Y
    fwd_raw = to_raw((0.0, 0.0, -G))        # tip up: reaction along canonical -Z (forward)
    new_map, quality = solve(up_raw, fwd_raw)
    assert new_map == true_map
    assert quality > 0.99


def test_invert_roundtrip():
    m = ["-z", "x", "-y"]
    v = (1.0, 2.0, 3.0)
    assert make_remap(m)(_invert(m)(v)) == pytest.approx(v)


def test_same_axis_rejected():
    with pytest.raises(ValueError):
        solve((0, 0, G), (0, 0.5, G))
