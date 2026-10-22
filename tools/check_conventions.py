"""Check the machine-checkable rules of docs/CODING_STANDARDS.md.

Usage: python tools/check_conventions.py [--root DIR] [--list-rules]

Each finding names a rule ID from the standards (e.g. GD-RET, ARCH-CORE). A justified exception is
written on the offending line as `# allow: RULE-ID <reason>`; reviewers grep for "allow:" to audit
them. Exit code 1 when any error is found; warnings never fail the run.
Standard library only, so it runs before any dependency is installed.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

RULES = {
    "GD-RET": "every GDScript function declares its return type (-> void / -> T)",
    "GD-PARAM": "every GDScript parameter has a type (name: T or name := default)",
    "GD-CLASS": "class_name starts with RS",
    "GD-UID": "every .gd file has its .gd.uid sidecar committed",
    "ARCH-CORE": "game/core and game/autoload never use classes defined under game/scenes",
    "ARCH-GAME": "a game folder never uses classes from another game's folder (menu and debug may)",
    "ARCH-SAVE": "user:// files are read and written only by game/core",
    "ARCH-ARGS": "command-line arguments are parsed only by party_game.gd and main_menu.gd",
    "ARCH-HAPTIC": "games vibrate through RSPartyGame.haptic(), never ControllerHub directly",
    "ARCH-AUDIO": "audio players are created only in game/core (RSSfx / RSAudio route them to a bus)",
    "SRC-PATH": "no machine-specific absolute paths in source files",
    "SIZE": "(warning) a script over 1000 lines should be split when it is next changed",
}

SIZE_WARN = 1000
ALLOW = re.compile(r"#\s*allow:\s*([A-Z]+-?[A-Z]*)")
FUNC = re.compile(r"^\s*(?:static\s+)?func\s+(\w+)\s*\(")
CLASS_NAME = re.compile(r"^class_name\s+(\w+)", re.M)
ABS_PATH = re.compile(r"(?<![\w/])[A-Za-z]:[\\/](?:Users|Program Files|SteamLibrary|Regina)|[\\/]Users[\\/][^\\/\s\"']+[\\/]", re.I)
SOURCE_SUFFIXES = {".gd", ".py", ".mjs", ".js", ".html", ".gdshader", ".tscn"}
SKIP_DIRS = {".godot", ".venv", "node_modules", "__pycache__", ".git", "assets", "audit-output", "build", "dist", "_dl"}


@dataclass
class Finding:
    rule: str
    path: str
    line: int
    text: str
    warning: bool = False

    def __str__(self) -> str:
        kind = "warning" if self.warning else "error"
        return f"{self.path}:{self.line}: {kind} {self.rule}: {self.text}"


def _allowed(line: str, rule: str) -> bool:
    return any(m.group(1) == rule for m in ALLOW.finditer(line))


def _strip_comment(line: str) -> str:
    # Good enough for this code base: '#' inside strings is rare in signatures and API calls.
    out, quote = [], ""
    for ch in line:
        if quote:
            if ch == quote:
                quote = ""
        elif ch in "\"'":
            quote = ch
        elif ch == "#":
            break
        out.append(ch)
    return "".join(out)


def _signature(lines: list[str], i: int) -> tuple[str, int]:
    """The whole `func ...:` header starting at line i (may span lines), and its last line index."""
    text, depth, j = "", 0, i
    while j < len(lines):
        part = _strip_comment(lines[j])
        text += part + " "
        depth += part.count("(") - part.count(")")
        if depth <= 0 and part.rstrip().endswith(":"):
            return text, j
        j += 1
    return text, j


def _params(sig: str) -> list[str]:
    start = sig.index("(") + 1
    depth, cur, out = 0, "", []
    for ch in sig[start:]:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            if depth == 0:
                break
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    return [p.strip() for p in out if p.strip()]


def check_gd_file(path: Path, rel: str, lines: list[str], findings: list[Finding]) -> None:
    for i, raw in enumerate(lines):
        if not FUNC.match(raw):
            continue
        sig, last = _signature(lines, i)
        full_raw = " ".join(lines[i:last + 1])
        if "->" not in sig and not _allowed(full_raw, "GD-RET"):
            findings.append(Finding("GD-RET", rel, i + 1, "missing return type: " + raw.strip()))
        for p in _params(sig):
            name = p.split("=")[0].split(":")[0].strip()
            if ":" not in p.split("=")[0] and ":=" not in p and not _allowed(full_raw, "GD-PARAM"):
                findings.append(Finding("GD-PARAM", rel, i + 1, f"untyped parameter '{name}'"))
    text = "\n".join(lines)
    m = CLASS_NAME.search(text)
    if m and not m.group(1).startswith("RS"):
        findings.append(Finding("GD-CLASS", rel, text[:m.start()].count("\n") + 1, f"class_name {m.group(1)}"))
    if not path.with_name(path.name + ".uid").exists():
        findings.append(Finding("GD-UID", rel, 1, "missing " + path.name + ".uid (open the project once in Godot 4.7)"))
    if len(lines) > SIZE_WARN:
        findings.append(Finding("SIZE", rel, 1, f"{len(lines)} lines", warning=True))


def _scene_owner(rel: str) -> str:
    """'skate' for game/scenes/skate/..., '' for anything else."""
    parts = rel.split("/")
    return parts[2] if len(parts) > 3 and parts[0] == "game" and parts[1] == "scenes" else ""


def check_game(root: Path, findings: list[Finding]) -> None:
    game = root / "game"
    files = sorted(p for p in game.rglob("*.gd") if not (SKIP_DIRS & set(p.relative_to(game).parts[:-1])))
    texts = {p: p.read_text(encoding="utf-8").splitlines() for p in files}
    # Which game folder defines each class.
    owner_of: dict[str, str] = {}
    for p, lines in texts.items():
        rel = p.relative_to(root).as_posix()
        m = CLASS_NAME.search("\n".join(lines))
        if m and _scene_owner(rel):
            owner_of[m.group(1)] = _scene_owner(rel)
    word = re.compile(r"\b(" + "|".join(sorted(owner_of)) + r")\b") if owner_of else None

    for p, lines in texts.items():
        rel = p.relative_to(root).as_posix()
        check_gd_file(p, rel, lines, findings)
        here = _scene_owner(rel)
        is_core = rel.startswith(("game/core/", "game/autoload/"))
        is_test = rel.startswith("game/tests/")
        for n, raw in enumerate(lines, 1):
            code = _strip_comment(raw)
            if not code.strip():
                continue
            if word:
                for m in word.finditer(code):
                    other = owner_of[m.group(1)]
                    if is_core and not _allowed(raw, "ARCH-CORE"):
                        findings.append(Finding("ARCH-CORE", rel, n, f"core uses {m.group(1)} from scenes/{other}"))
                    elif here and other != here and here not in ("menu", "debug") and not _allowed(raw, "ARCH-GAME"):
                        findings.append(Finding("ARCH-GAME", rel, n, f"scenes/{here} uses {m.group(1)} from scenes/{other}"))
            if "user://" in raw and not is_core and not is_test and not _allowed(raw, "ARCH-SAVE"):
                findings.append(Finding("ARCH-SAVE", rel, n, "user:// outside game/core"))
            if "get_cmdline_user_args" in code and not is_test and rel not in (
                    "game/core/party_game.gd", "game/scenes/menu/main_menu.gd") and not _allowed(raw, "ARCH-ARGS"):
                findings.append(Finding("ARCH-ARGS", rel, n, "parse arguments in RSPartyGame._parse_arg() instead"))
            if re.search(r"ControllerHub\.(vibrate|vibrate_pattern|haptic)\(", code) and not is_core \
                    and here != "debug" and not _allowed(raw, "ARCH-HAPTIC"):
                findings.append(Finding("ARCH-HAPTIC", rel, n, "use haptic(p, name) from RSPartyGame"))
            if re.search(r"AudioStreamPlayer(2D|3D)?\.new\(", code) and not is_core and not _allowed(raw, "ARCH-AUDIO"):
                findings.append(Finding("ARCH-AUDIO", rel, n, "use RSSfx.play / RSSfx.loop (or an RSAudio bus)"))


def check_paths(root: Path, findings: list[Finding]) -> None:
    for top in ("game", "hub", "tools", "firmware/main"):
        base = root / top
        if not base.exists():
            continue
        for p in base.rglob("*"):
            if p.suffix not in SOURCE_SUFFIXES or not p.is_file():
                continue
            if SKIP_DIRS & set(p.relative_to(root).parts[:-1]) or p.name == "check_conventions.py":
                continue
            rel = p.relative_to(root).as_posix()
            for n, raw in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                if ABS_PATH.search(raw) and not _allowed(raw, "SRC-PATH"):
                    findings.append(Finding("SRC-PATH", rel, n, raw.strip()[:100]))


def run(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    check_game(root, findings)
    check_paths(root, findings)
    return findings


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    ap.add_argument("--list-rules", action="store_true")
    args = ap.parse_args(argv)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    if args.list_rules:
        for rule, text in RULES.items():
            print(f"{rule:12} {text}")
        return 0
    findings = run(args.root)
    for f in findings:
        print(f)
    errors = sum(not f.warning for f in findings)
    warnings = len(findings) - errors
    print(f"conventions: {errors} error(s), {warnings} warning(s) — rules in docs/CODING_STANDARDS.md")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
