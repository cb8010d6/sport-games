"""Malformed wire data must reach callers through their documented ValueError guard."""

import math
import struct

import pytest

from regina_hub import protocol as P


@pytest.mark.parametrize(
    ("parse", "valid"),
    [
        (P.parse_imu, P.build_imu(0, 0, [(0, 0, 0, 4096, 0, 0, 0)])),
        (P.parse_input, P.build_input(0, 0, 0, 0)),
        (P.parse_status, P.build_status(50, False, True, False, (1, 0), 1)),
        (P.parse_legacy_input, struct.pack("<????BBhh", False, False, False, False, 0, 0, 0, 0)),
        (P.parse_legacy_vec3, struct.pack("<fff", 0, 0, 1)),
    ],
)
def test_every_truncated_packet_raises_value_error(parse, valid):
    for end in range(len(valid)):
        with pytest.raises(ValueError):
            parse(valid[:end])
    assert parse(valid) is not None


@pytest.mark.parametrize(
    "ui",
    [
        [],
        "screen",
        {"bar": 5},
        {"bar": []},
        {"bar": {"pct": math.inf}},
        {"bar": {"pct": math.nan}},
        {"bar": {"pct": {}}},
        {"legends": "ABCD"},
        {"legends": {"A": "GO"}},
        {"toast": 5},
        {"toast": []},
        {"toast": {"ms": math.inf}},
        {"toast": {"ms": math.nan}},
        {"toast": {"ms": {}}},
    ],
)
def test_malformed_ui_raises_value_error(ui):
    with pytest.raises(ValueError):
        P.normalize_ui(ui)


def test_ui_normalization_keeps_existing_optional_fields_and_clamps():
    assert P.normalize_ui({"bar": None, "legends": None, "toast": None}) == {
        "bar": None,
        "legends": [None] * 4,
    }
    ui = P.normalize_ui({
        "bar": {"pct": "175", "label": "POWER"},
        "legends": ["GO", None, "BACK", "", "ignored"],
        "toast": {"ms": "20000", "text": "START"},
    })
    assert ui == {
        "bar": {"pct": 100, "label": "POWER"},
        "legends": ["GO", None, "BACK", ""],
        "toast": {"ms": 10000, "text": "START"},
    }
    assert P.decode_ui_tlv(P.encode_ui_tlv(ui)) == ui
