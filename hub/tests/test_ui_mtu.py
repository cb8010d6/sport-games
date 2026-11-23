"""OLED partial commands preserve whole fields within the negotiated ATT write size."""

import pytest

from regina_hub import protocol as P


def decode_packets(packets, mtu):
    state = P.UiState()
    toast = None
    clear_at = []
    for index, packet in enumerate(packets):
        assert packet[0] == P.OP_UI
        assert 1 < len(packet) <= min(mtu - 3, 256)
        offset = 1
        while offset < len(packet):
            assert offset + 2 <= len(packet)
            size = packet[offset + 1]
            assert offset + 2 + size <= len(packet)
            if packet[offset] == P.UI_CLEAR:
                clear_at.append(index)
            offset += 2 + size
        assert offset == len(packet)
        update = P.decode_ui_tlv(packet)
        state.apply(update)
        if "toast" in update:
            toast = update["toast"]
    return state.snapshot(), toast, clear_at


@pytest.mark.parametrize("mtu", [23, 247])
@pytest.mark.parametrize("rotation", [0, 1, 2, 3])
def test_full_oled_state_reassembles_from_complete_tlvs(mtu, rotation):
    ui = {
        "clear": True, "title": "T" * 40, "main": "M" * 40, "sub": "S" * 40,
        "bar": {"pct": 87, "label": "B" * 40},
        "legends": ["A" * 40, "B" * 40, "C" * 40, "D" * 40],
        "toast": {"ms": 1234, "text": "Z" * 40},
    }
    packets = P.encode_ui_packets(ui, mtu, rotation)
    state, toast, clears = decode_packets(packets, mtu)
    portrait = bool(rotation & 1)
    body_limit = min(10 if portrait else 20, mtu - 6)
    assert state == {
        "clear": True,
        "title": "T" * (10 if portrait else 14),
        "main": "M" * body_limit,
        "sub": "S" * body_limit,
        "bar": {"pct": 87, "label": "B" * min(10 if portrait else 20, mtu - 7)},
        "legends": [letter * (8 if portrait else 9) for letter in "ABCD"],
    }
    assert toast == {"ms": 1234, "text": "Z" * min(20, mtu - 8)}
    assert clears == [0]
    assert len(packets) > 1 if mtu == 23 else len(packets) == 1


@pytest.mark.parametrize("mtu", [23, 247])
def test_partial_updates_do_not_clear_other_fields(mtu):
    state = P.UiState()
    state.apply({"title": "KEEP", "main": "OLD", "bar": {"pct": 80, "label": "POWER"},
                 "legends": ["A", "B", "C", "D"]})
    packets = P.encode_ui_packets({"main": "", "bar": None, "legends": [None, "", None, "ZERO"]}, mtu)
    for packet in packets:
        update = P.decode_ui_tlv(packet)
        assert "clear" not in update
        state.apply(update)
    assert state.snapshot() == {
        "clear": True, "title": "KEEP", "main": "", "bar": None,
        "legends": ["A", "", "C", "ZERO"],
    }


def test_ble_truncation_does_not_change_general_ui_encoding_or_input():
    ui = {"title": "射箭" + "T" * 38, "legends": ["L" * 40, None, "", "X"]}
    original = {"title": ui["title"], "legends": list(ui["legends"])}
    encoded = P.encode_ui_tlv(ui)
    state, _, _ = decode_packets(P.encode_ui_packets(ui, 23), 23)
    assert state["title"] == "??" + "T" * 8
    assert state["legends"] == ["L" * 8, None, "", "X"]
    assert len(P.decode_ui_tlv(encoded)["title"]) == 40
    assert ui == original


def test_clear_only_and_empty_updates():
    assert P.encode_ui_packets({}, 23) == []
    assert P.encode_ui_packets({"clear": True}, 23) == [bytes([P.OP_UI, P.UI_CLEAR, 0])]


@pytest.mark.parametrize("mtu", [None, True, 22, 518, 23.0])
def test_invalid_mtu_is_rejected(mtu):
    with pytest.raises(ValueError):
        P.encode_ui_packets({"title": "TEST"}, mtu)


def test_all_supported_mtu_sizes_keep_complete_fields():
    ui = {"clear": True, "title": "T" * 40, "main": "M" * 40,
          "bar": {"pct": 100, "label": "B" * 40},
          "legends": ["L" * 40] * 4, "toast": {"ms": 900, "text": "Z" * 40}}
    for mtu in range(23, 518):
        state, toast, clears = decode_packets(P.encode_ui_packets(ui, mtu), mtu)
        assert state["title"] == "T" * 10
        assert state["bar"] == {"pct": 100, "label": "B" * 10}
        assert toast["ms"] == 900
        assert clears == [0]
