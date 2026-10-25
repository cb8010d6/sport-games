import builtins
import itertools
import json
import sys
from pathlib import Path

import pytest

from regina_hub import axis_wizard
from regina_hub.__main__ import load_config
from regina_hub.axis_wizard import _invert, resolve_paths, solve
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


def test_resolve_paths_follows_the_hub_rule(tmp_path):
    base, overlay = resolve_paths(tmp_path / "custom.json")
    assert (base, overlay) == (tmp_path / "custom.json", tmp_path / "config.local.json")
    # The overlay passed directly (the wizard's old --config meaning) resolves
    # to the same pair instead of being treated as the base.
    base, overlay = resolve_paths(tmp_path / "config.local.json")
    assert (base, overlay) == (tmp_path / "config.json", tmp_path / "config.local.json")


def test_wizard_reads_hub_precedence_and_writes_the_winning_overlay(tmp_path, monkeypatch, capsys):
    """With `hub --config custom.json` plus a sibling overlay, the wizard must
    invert the hub's *effective* map (the overlay's, not the base file's) and
    write the result to that overlay -- the layer that still wins after a
    restart, as the wizard's message promises (#51 review)."""
    maps = list(_proper_maps())
    base_map, overlay_map, target_map = maps[2], maps[0], maps[5]
    custom = tmp_path / "custom.json"
    overlay = tmp_path / "config.local.json"
    custom.write_text(json.dumps({"regina_axis_map": base_map}), encoding="utf-8")
    overlay.write_text(json.dumps({"regina_axis_map": overlay_map, "lan_ip": "203.0.113.8"}), encoding="utf-8")

    class FakeListener:
        roster = {"controllers": [{"id": 7, "kind": "regina", "name": "R", "connected": True}]}

        def poll(self, seconds, on_sample=None):
            pass

    # Canonical-frame readings the hub would stream if the chip were mounted
    # per target_map while the hub remaps with the effective (overlay) map.
    readings = iter([
        make_remap(overlay_map)(_invert(target_map)((0.0, G, 0.0))),
        make_remap(overlay_map)(_invert(target_map)((0.0, 0.0, -G))),
    ])
    monkeypatch.setattr(axis_wizard, "Listener", lambda *args: FakeListener())
    monkeypatch.setattr(axis_wizard, "capture_gravity", lambda listener, cid: next(readings))
    monkeypatch.setattr(builtins, "input", lambda prompt="": "")
    monkeypatch.setattr(sys, "argv", ["axis_wizard", "--config", str(custom)])

    axis_wizard.main()

    out = capsys.readouterr().out
    assert f"{overlay_map}  ->  {target_map}" in out  # current = the overlay's map, not the base file's
    written = json.loads(overlay.read_text(encoding="utf-8"))
    assert written["regina_axis_map"] == target_map
    assert written["lan_ip"] == "203.0.113.8"  # other overlay keys are preserved
    assert json.loads(custom.read_text(encoding="utf-8"))["regina_axis_map"] == base_map  # base untouched
    # And the restart claim holds: the hub now loads the wizard's result.
    assert load_config(custom)["regina_axis_map"] == target_map
    assert Path(overlay).name == "config.local.json"
