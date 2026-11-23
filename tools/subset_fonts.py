"""Rebuild the bundled Noto Sans SC subset from the upstream variable font.

Usage: python tools/subset_fonts.py <NotoSansSC[wght].ttf from google/fonts>  (needs fonttools)

Keeps every character the game's own text uses plus the 3755 common characters of GB 2312
level 1 (player names), Latin-1, punctuation and the symbols the UI draws. Anything else
falls back to the system CJK font at runtime (RSUi.font()).
"""
import sys
from pathlib import Path

from fontTools import subset

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "game/assets/fonts/NotoSansSC-RS.ttf"


def game_text() -> set[str]:
    chars: set[str] = set()
    for pattern in ("*.gd", "*.json", "*.tscn", "*.tres"):
        for path in (ROOT / "game").rglob(pattern):
            if ".godot" in path.parts:
                continue
            chars.update(path.read_text(encoding="utf-8", errors="ignore"))
    return chars


def gb2312_level1() -> set[str]:
    chars: set[str] = set()
    for hi in range(0xB0, 0xD8):
        for lo in range(0xA1, 0xFF):
            try:
                chars.add(bytes([hi, lo]).decode("gb2312"))
            except UnicodeDecodeError:
                pass
    return chars


def main() -> None:
    src = Path(sys.argv[1])
    chars = game_text() | gb2312_level1()
    chars |= {chr(c) for c in range(0x20, 0x7F)} | {chr(c) for c in range(0xA0, 0x180)}
    for lo, hi in ((0x2000, 0x206F), (0x2190, 0x21FF), (0x25A0, 0x25FF), (0x2600, 0x2606),
                   (0x3000, 0x303F), (0xFF00, 0xFFEF)):
        chars |= {chr(c) for c in range(lo, hi + 1)}
    chars = {c for c in chars if c.isprintable() or c == " "}
    options = subset.Options()
    options.hinting = False
    options.desubroutinize = True
    options.layout_features = ["*"]
    options.name_IDs = ["*"]
    options.notdef_outline = True
    font = subset.load_font(str(src), options)
    sub = subset.Subsetter(options)
    sub.populate(text="".join(sorted(chars)))
    sub.subset(font)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    subset.save_font(font, str(OUT), options)
    print(f"{OUT.relative_to(ROOT)}: {len(chars)} characters, {OUT.stat().st_size // 1024} KiB")


if __name__ == "__main__":
    main()
