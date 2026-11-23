"""Check the game's English translation (game/i18n/en.json) against the code.

The Chinese text in the scripts is the key (see game/core/lang.gd). This lists every Chinese
string literal in game/**/*.gd and game/scenes/*/*_module.tres that has no English entry, and every entry no script uses any
more. Lines marked `# no-i18n` are skipped (mesh names, bilingual signs, ...).

    hub/.venv/Scripts/python -I tools/i18n_check.py            # report, exit 1 if anything is missing
    hub/.venv/Scripts/python -I tools/i18n_check.py --todo F   # also write the missing keys to F (JSON)
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "game"
EN = ROOT / "i18n" / "en.json"
CJK = re.compile("[一-鿿　-〿＀-￯]")
STRLIT = re.compile(r'"((?:[^"\\]|\\.)*)"')
ESCAPES = {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'"}


def code_part(line: str) -> str:
    """The line without a trailing # comment (a # inside a string is kept)."""
    in_str = False
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == "\\" and in_str:
            i += 2
            continue
        if ch == '"':
            in_str = not in_str
        elif ch == "#" and not in_str:
            return line[:i]
        i += 1
    return line


def unescape(s: str) -> str:
    """A GDScript string literal's text as the game sees it."""
    return re.sub(r"\\(.)", lambda m: ESCAPES.get(m.group(1), m.group(0)), s)


def scan(root: Path = ROOT) -> list[tuple[str, int, str]]:
    """(file, line, text) for every Chinese string literal."""
    out = []
    for f in sorted([*root.rglob("*.gd"), *root.rglob("*_module.tres")]):   # + game manifests
        if ".godot" in f.parts:
            continue
        for i, line in enumerate(f.read_text(encoding="utf-8").splitlines()):
            if line.lstrip().startswith("#") or "no-i18n" in line:
                continue
            for m in STRLIT.finditer(code_part(line)):
                if CJK.search(m.group(1)):
                    out.append((f.relative_to(root).as_posix(), i + 1, unescape(m.group(1))))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--todo", type=Path, help="write the missing keys here as a JSON list")
    args = ap.parse_args()
    found = scan()
    en = json.loads(EN.read_text(encoding="utf-8")) if EN.exists() else {}
    missing: dict[str, tuple[str, int]] = {}
    for f, line, text in found:
        if text not in en:
            missing.setdefault(text, (f, line))
    used = {t for _, _, t in found}
    unused = [k for k in en if k not in used]
    for text, (f, line) in missing.items():
        print(f"missing  {f}:{line}  {text!r}")
    for k in unused:
        print(f"unused   {k!r}")
    print(f"{len(used)} texts, {len(missing)} missing, {len(unused)} unused")
    if args.todo:
        args.todo.write_text(json.dumps(list(missing), ensure_ascii=False, indent=1), encoding="utf-8")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main())
