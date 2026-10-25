"""Check texture import rules and estimate VRAM from PNG/JPEG headers (#53-05)."""
from __future__ import annotations

import argparse
import re
import struct
from pathlib import Path
from typing import BinaryIO

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PATHS = (ROOT / "game/assets/characters", ROOT / "game/assets/shared")
PARAM = re.compile(r"^(\s*([^\s=;]+)\s*=\s*)([^;\r\n]*?)([ \t]*(?:;[^\r\n]*)?)(\r?\n|\r)?$")
SOF = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}


def import_paths(paths: list[Path] | tuple[Path, ...]) -> list[Path]:
    """Expand directories and deduplicate overlapping input paths."""
    found = set()
    for path in paths:
        if not path.exists():
            raise ValueError(f"Path does not exist: {path}")
        candidates = path.rglob("*.import") if path.is_dir() else [path]
        found.update(p.resolve() for p in candidates if p.name.lower().endswith((".png.import", ".jpg.import")))
    return sorted(found)


def rules(path: Path) -> dict[str, str]:
    expected = {"compress/mode": "2", "mipmaps/generate": "true"}
    name = path.name.lower()
    if "_normal" in name or "_nor_gl_" in name:
        expected["compress/normal_map"] = "1"
    if "characters" in (part.lower() for part in path.parts[:-1]):
        expected["process/size_limit"] = "1024" if any(word in name for word in ("eye", "eyebrow", "eyelash")) else "2048"
    return expected


def params(text: str) -> dict[str, str]:
    result = {}
    section = ""
    for line in text.splitlines(keepends=True):
        if line.strip().startswith("["):
            section = line.strip()
        match = PARAM.fullmatch(line) if section == "[params]" else None
        if match:
            result[match[2]] = match[3].strip()
    return result


def apply_rules(text: str, expected: dict[str, str]) -> str:
    """Keep every non-target line byte-for-byte, including section ordering."""
    newline = "\r\n" if "\r\n" in text else "\n"
    lines = text.splitlines(keepends=True)
    start = next((i + 1 for i, line in enumerate(lines) if line.strip() == "[params]"), None)
    if start is None:
        return text + (newline if text and not text.endswith(("\n", "\r")) else "") + "[params]" + newline + "".join(
            f"{key}={value}{newline}" for key, value in expected.items())
    end = next((i for i in range(start, len(lines)) if lines[i].strip().startswith("[")), len(lines))
    seen = set()
    for i in range(start, end):
        match = PARAM.fullmatch(lines[i])
        if match and match[2] in expected:
            seen.add(match[2])
            lines[i] = match[1] + expected[match[2]] + match[4] + (match[5] or "")
    missing = [f"{key}={value}{newline}" for key, value in expected.items() if key not in seen]
    if missing and end and not lines[end - 1].endswith(("\n", "\r")):
        lines[end - 1] += newline
    lines[end:end] = missing
    return "".join(lines)


def read_exact(stream: BinaryIO, count: int) -> bytes:
    data = stream.read(count)
    if len(data) != count:
        raise ValueError("Truncated image header")
    return data


def image_info(path: Path) -> tuple[int, int, bool]:
    """Read dimensions and alpha presence without decoding pixel data."""
    with path.open("rb") as stream:
        if read_exact(stream, 2) == b"\xff\xd8":
            while True:
                if read_exact(stream, 1) != b"\xff":
                    raise ValueError("Invalid JPEG marker")
                marker = read_exact(stream, 1)[0]
                while marker == 0xFF:
                    marker = read_exact(stream, 1)[0]
                if marker in (0xD9, 0xDA):
                    raise ValueError("JPEG has no size header")
                if marker in (0x01, *range(0xD0, 0xD9)):
                    continue
                size = struct.unpack(">H", read_exact(stream, 2))[0]
                if size < 2:
                    raise ValueError("Invalid JPEG segment length")
                if marker in SOF:
                    if size < 8:
                        raise ValueError("Invalid JPEG size header")
                    _, height, width = struct.unpack(">BHH", read_exact(stream, 5))
                    break
                stream.seek(size - 2, 1)
            alpha = False
        else:
            stream.seek(0)
            if read_exact(stream, 8) != b"\x89PNG\r\n\x1a\n":
                raise ValueError("Expected PNG or JPEG header")
            if read_exact(stream, 8) != b"\x00\x00\x00\rIHDR":
                raise ValueError("Invalid PNG size header")
            width, height, _, color, _, _, _ = struct.unpack(">IIBBBBB", read_exact(stream, 13))
            if color not in (0, 2, 3, 4, 6):
                raise ValueError("Invalid PNG color type")
            alpha = color in (4, 6)
            stream.seek(4, 1)  # IHDR CRC; transparency chunks precede pixel data.
            while not alpha:
                size, chunk = struct.unpack(">I4s", read_exact(stream, 8))
                if chunk == b"tRNS":
                    alpha = True
                if chunk in (b"tRNS", b"IDAT", b"IEND"):
                    break
                stream.seek(size + 4, 1)
        if width <= 0 or height <= 0:
            raise ValueError("Image dimensions must be positive")
        return width, height, alpha


def estimate(info: tuple[int, int, bool], settings: dict[str, str]) -> float:
    width, height, alpha = info
    limit = int(settings.get("process/size_limit", "0"))
    if 0 < limit < max(width, height):
        scale = limit / max(width, height)
        width, height = max(1, int(width * scale)), max(1, int(height * scale))
    compressed = settings.get("compress/mode", "0") == "2"
    normal = settings.get("compress/normal_map", "0") == "1"
    # The task's offline model uses bytes/pixel, not padded GPU block allocation.
    per_pixel = (1 if alpha or normal else 0.5) if compressed else 4
    mipmaps = 4 / 3 if settings.get("mipmaps/generate", "false") == "true" else 1
    return width * height * per_pixel * mipmaps / 1024**2


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    for action in ("check", "apply", "report"):
        mode.add_argument("--" + action, action="store_true")
    parser.add_argument("paths", type=Path, nargs="*")
    args = parser.parse_args(argv)
    errors = 0
    current_total = target_total = 0.0
    try:
        paths = import_paths(args.paths or DEFAULT_PATHS)
    except (OSError, ValueError) as exc:
        print(exc)
        return 1
    for path in paths:
        try:
            with path.open(encoding="utf-8", newline="") as stream:
                text = stream.read()
            current, expected = params(text), rules(path)
            label = path.relative_to(ROOT).as_posix() if path.is_relative_to(ROOT) else str(path)
            if args.report:
                info = image_info(path.with_suffix(""))
                before, after = estimate(info, current), estimate(info, current | expected)
                current_total += before
                target_total += after
                print(f"{label}: {before:.3f} MiB -> {after:.3f} MiB")
            elif args.apply:
                updated = apply_rules(text, expected)
                if updated != text:
                    with path.open("w", encoding="utf-8", newline="") as stream:
                        stream.write(updated)
                    print(f"Updated {label}")
            else:
                for key, value in expected.items():
                    if current.get(key) != value:
                        print(f"{label}: {key}={current.get(key, '<missing>')} (expected {value})")
                        errors += 1
        except (OSError, ValueError) as exc:
            print(f"{path}: {exc}")
            errors += 1
    if args.report:
        print(f"RS_TEXTURE_VRAM: {current_total:.3f} MiB -> {target_total:.3f} MiB ({len(paths)} textures)")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
