"""docs/protocol.md must document every wire key the hub actually uses (#50).

The key sets are extracted from the hub sources, so adding a message,
command or roster field without documenting it fails this test.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HUB = ROOT / "hub" / "regina_hub"
DOC = (ROOT / "docs" / "protocol.md").read_text(encoding="utf-8")


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _web_message_types() -> set[str]:
    src = _read(HUB / "sources" / "web.py")
    handled = set(re.findall(r't == "(\w+)"', src))            # client -> hub
    sent = set(re.findall(r'"t":\s*"(\w+)"', src))             # hub -> client
    sent |= set(re.findall(r'\{"t":\s*"(\w+)"', _read(HUB / "sources" / "web.py")))
    return handled | sent


def _game_commands() -> set[str]:
    src = _read(HUB / "hub.py")
    return set(re.findall(r'cmd == "(\w+)"', src))


def _roster_keys() -> set[str]:
    src = _read(HUB / "controller.py")
    entry = src[src.index("def roster_entry"):]
    keys = set(re.findall(r'"(\w+)":', entry[: entry.index("**self.extra")]))
    for path in HUB.rglob("*.py"):
        keys |= set(re.findall(r'extra\["(\w+)"\]\s*=', _read(path)))
        keys |= set(re.findall(r'on_status\([^)]*?(\w+)=', _read(path)))
    return keys


def test_protocol_doc_covers_web_message_types():
    missing = [t for t in sorted(_web_message_types()) if f'"t":"{t}"' not in DOC and f'"t": "{t}"' not in DOC]
    assert not missing, f"protocol.md is missing WebSocket message types: {missing}"


def test_protocol_doc_covers_game_commands():
    missing = [c for c in sorted(_game_commands()) if f'"cmd":"{c}"' not in DOC]
    assert not missing, f"protocol.md is missing game commands: {missing}"


def test_protocol_doc_covers_roster_keys():
    missing = [k for k in sorted(_roster_keys()) if f'"{k}"' not in DOC]
    assert not missing, f"protocol.md is missing roster keys: {missing}"
