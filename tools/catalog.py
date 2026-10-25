"""The game catalog for tools: every game/scenes/<id>/<id>_module.tres (RSGameModule), read without Godot.

The game discovers the same manifests in RSCatalog (game/core/catalog.gd); tools take their game
and map lists from here instead of keeping their own. `--compare` checks this parser against the
JSON written by the game itself (`-- --dump-catalog=<file>`, also from an exported build).

    python tools/catalog.py                 # menu games and their maps as JSON
    python tools/catalog.py --ids --hidden  # one ID per line, hidden (ready = false) games too
    python tools/catalog.py --check         # every ready game is complete (CI)
    python tools/catalog.py --compare F     # F (from --dump-catalog) matches these manifests
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from functools import cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAME = ROOT / "game"
# Keep in sync with the @export defaults of game/core/game_module.gd.
DEFAULTS = {"id": "", "name": "", "oled": "", "scene": "", "desc": "", "maps_script": "", "lessons": [],
            "solo_goals": [], "players": [1, 4], "mode": "individual", "ambience": "", "preview": "",
            "ready": False, "order": 100, "benchmark": False}
MODES = ("individual", "versus", "teams")
STRING = r'"((?:[^"\\]|\\.)*)"'
ESCAPES = {"n": "\n", "t": "\t", '"': '"', "\\": "\\"}


def _unescape(text: str) -> str:
    return re.sub(r"\\(.)", lambda m: ESCAPES.get(m.group(1), m.group(1)), text)


def _value(raw: str) -> object:
    raw = raw.strip()
    if raw.startswith('"'):
        return _unescape(raw[1:-1])
    if raw in ("true", "false"):
        return raw == "true"
    if re.fullmatch(r"-?\d+", raw):
        return int(raw)
    packed = re.fullmatch(r"(PackedStringArray|PackedInt32Array|Vector2i)\((.*)\)", raw, re.S)
    if packed:
        if packed.group(1) == "PackedStringArray":
            return [_unescape(s) for s in re.findall(STRING, packed.group(2))]
        return [int(n) for n in re.findall(r"-?\d+", packed.group(2))]
    return None   # ExtResource(...) and anything this catalog does not use


def parse_module(path: Path) -> dict:
    """The [resource] properties of one manifest, defaults filled in, as RSCatalog sees them."""
    text = path.read_text(encoding="utf-8")
    body = text.split("[resource]", 1)[1] if "[resource]" in text else ""
    module = json.loads(json.dumps(DEFAULTS))
    # key = value, where a string value may span lines (Godot writes multiline text verbatim).
    for key, raw in re.findall(r'(?m)^(\w+) = ("(?:[^"\\]|\\.)*"|[^\n]*)', body):
        if key in DEFAULTS:
            module[key] = _value(raw)
    return module


def _res(path: str) -> Path:
    return GAME / path.removeprefix("res://")


def problem(module: dict, folder: str) -> str:
    """The reason RSCatalog._problem() rejects a manifest, or ''. Mirrors catalog.gd."""
    oled = module["oled"]
    if module["id"] != folder:
        return "id must equal the folder name"
    if not module["name"] or not module["desc"]:
        return "missing name or desc"
    if not oled or len(oled) > 10 or oled != oled.upper() or any(not 32 <= ord(c) <= 126 for c in oled):
        return "oled must be ASCII capitals, at most 10 characters"
    if not _res(module["scene"]).is_file():
        return "scene not found"
    if module["maps_script"] and not _res(module["maps_script"]).is_file():
        return "maps_script not found"
    low, high = module["players"]
    if low < 1 or high > 4 or low > high:
        return "players must lie within 1-4"
    if module["mode"] not in MODES:
        return "unknown mode"
    return ""


@cache
def _all_modules() -> tuple[dict, ...]:
    found = []
    for path in sorted((GAME / "scenes").glob("*/*_module.tres")):
        folder = path.parent.name
        if path.name != folder + "_module.tres":
            continue
        module = parse_module(path)
        reason = problem(module, folder)
        if reason:
            raise ValueError(f"Invalid game module {path.relative_to(ROOT).as_posix()}: {reason}")
        module["maps"] = maps_of(module)
        found.append(module)
    return tuple(sorted(found, key=lambda m: (m["order"], m["id"])))


def modules(include_hidden: bool = False) -> list[dict]:
    """Manifests in menu order; only ready games unless include_hidden."""
    return [m for m in _all_modules() if include_hidden or m["ready"]]


def module(game_id: str) -> dict:
    for m in _all_modules():
        if m["id"] == game_id:
            return m
    raise KeyError(game_id)


def game_ids(include_hidden: bool = False) -> tuple[str, ...]:
    return tuple(m["id"] for m in modules(include_hidden))


def benchmark_ids() -> tuple[str, ...]:
    """The games of the settings benchmark (RSBenchmarkMenu), in menu order."""
    return tuple(m["id"] for m in modules() if m["benchmark"])


def map_count(game_id: str) -> int:
    return max(len(module(game_id)["maps"]), 1)


def maps_of(module_row: dict) -> list[dict]:
    """[{name, en}] of the MAPS constant in the manifest's maps_script; [] for one map."""
    if not module_row["maps_script"]:
        return []
    text = _res(module_row["maps_script"]).read_text(encoding="utf-8")
    start = re.search(r"(?m)^const MAPS(?:\s*:\s*\w+)?\s*:?=\s*\[", text)
    if not start:
        raise ValueError("maps_script has no MAPS array: " + module_row["maps_script"])
    entries, depth, begin, i = [], 1, -1, start.end()
    while depth:
        char = text[i]
        if char == '"':
            i += 1
            while text[i] != '"':
                i += 2 if text[i] == "\\" else 1
        elif char == "#":
            i = text.index("\n", i) - 1
        elif char in "[{(":
            if depth == 1 and char == "{":
                begin = i
            depth += 1
        elif char in "]})":
            depth -= 1
            if depth == 1 and char == "}":
                entries.append(text[begin:i + 1])
        i += 1

    def field(entry: str, key: str) -> str:
        found = re.search(rf'"{key}"\s*:\s*{STRING}', entry)
        return _unescape(found.group(1)) if found else ""

    return [{"name": field(entry, "name"), "en": field(entry, "en")} for entry in entries]


def _step_names() -> set[str]:
    text = (GAME / "core/tutorial.gd").read_text(encoding="utf-8")
    return set(re.findall(r'(?m)^const ([A-Z_]+) := \{"kind"', text))


def check() -> list[str]:
    """Problems of ready manifests: preview, lessons, solo goals and English text (CI rule)."""
    english = json.loads((GAME / "i18n/en.json").read_text(encoding="utf-8"))
    steps = _step_names()
    previews = GAME / "assets/previews"
    manifest = previews / "manifest.json"
    images = json.loads(manifest.read_text(encoding="utf-8"))["images"] if manifest.is_file() else None
    errors = []
    for m in modules():
        name = m["id"]
        if m["preview"] != f"res://assets/previews/{name}.jpg":
            errors.append(f"{name}: preview must be res://assets/previews/{name}.jpg")
        elif images is not None and (name not in images or not _res(m["preview"]).is_file()):
            errors.append(f"{name}: preview image missing (python tools/capture_previews.py --games {name})")
        if not m["lessons"] or any(step not in steps for step in m["lessons"]):
            errors.append(f"{name}: lessons must name RSTutorial step constants")
        goals = m["solo_goals"]
        if len(goals) != 3 or goals[0] <= 0 or sorted(set(goals)) != goals:
            errors.append(f"{name}: solo_goals must be three ascending positive scores")
        for key in ("name", "desc"):
            if not english.get(m[key]):
                errors.append(f"{name}: {key} has no English text in game/i18n/en.json")
        if any(not row["en"] or not row["name"] for row in m["maps"]):
            errors.append(f"{name}: every map needs a name and an English name (en)")
    return errors


def compare(dump: dict) -> list[str]:
    """Differences between the game's --dump-catalog JSON and this parser."""
    if not isinstance(dump, dict) or not isinstance(dump.get("games"), list):
        return ["dump has no games list"]
    theirs = {row.get("id"): row for row in dump["games"] if isinstance(row, dict)}
    ours = {m["id"]: m for m in modules(include_hidden=True)}
    errors = [f"{game}: only in {'the game' if game in theirs else 'the manifests'}"
              for game in sorted(set(theirs) ^ set(ours))]
    if [row.get("id") for row in dump["games"]] != [m["id"] for m in modules(include_hidden=True)]:
        errors.append("game order differs")
    for game in sorted(set(theirs) & set(ours)):
        errors += [f"{game}: {key} differs" for key in (*DEFAULTS, "maps") if theirs[game].get(key) != ours[game][key]]
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--hidden", action="store_true", help="include games with ready = false")
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--ids", action="store_true", help="print one game ID per line")
    action.add_argument("--check", action="store_true", help="validate every ready manifest")
    action.add_argument("--compare", type=Path, metavar="DUMP", help="compare with the game's --dump-catalog JSON")
    args = parser.parse_args(argv)
    if args.check or args.compare:
        errors = check() if args.check else compare(json.loads(args.compare.read_text(encoding="utf-8")))
        for error in errors:
            print(error, file=sys.stderr)
        print(f"{len(modules(True))} game modules, {len(errors)} problems")
        return 1 if errors else 0
    if args.ids:
        print("\n".join(game_ids(args.hidden)))
    else:
        print(json.dumps(modules(args.hidden), ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
