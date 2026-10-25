"""Texture import rules, header-only estimates, and line-preserving fixes."""
from __future__ import annotations

import struct
import zlib
from pathlib import Path

import pytest

from tools import texture_imports as textures


def png(path: Path, width: int = 1, height: int = 1, color: int = 2, transparent: bool = False) -> None:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    path.parent.mkdir(parents=True, exist_ok=True)
    header = struct.pack(">IIBBBBB", width, height, 8, color, 0, 0, 0)
    palette = chunk(b"PLTE", b"\x00\x00\x00") if color == 3 else b""
    alpha = chunk(b"tRNS", b"\x00") if transparent else b""
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color]
    pixels = (b"\x00" + b"\x00" * width * channels) * height
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + palette + alpha
                     + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


@pytest.mark.parametrize(("name", "normal", "limit"), [
    ("characters/body_normal.png.import", True, "2048"),
    ("shared/characters/person_eyebrow.png.import", False, "1024"),
    ("characters/person_eyelashes.png.import", False, "1024"),
    ("characters/person_eye.png.import", False, "1024"),
    ("shared/materials/brick_nor_gl_2k.jpg.import", True, None),
    ("shared/materials/brick_diff_2k.jpg.import", False, None),
])
def test_filename_and_directory_rules(name: str, normal: bool, limit: str | None) -> None:
    result = textures.rules(Path(name))
    assert result["compress/mode"] == "2"
    assert result["mipmaps/generate"] == "true"
    assert result.get("compress/normal_map") == ("1" if normal else None)
    assert result.get("process/size_limit") == limit


@pytest.mark.parametrize("newline", ["\n", "\r\n"])
def test_apply_preserves_other_lines_and_sections(tmp_path: Path, newline: str) -> None:
    path = tmp_path / "characters/body_normal.png.import"
    path.parent.mkdir()
    original = newline.join([
        "[remap]", 'path="unchanged.ctex"', 'metadata={"vram_texture": false}',
        "[params]", "  compress/mode = 0 ; keep comment", "compress/normal_map=0",
        "process/channel_remap/red=2", "unrelated=\"a=b\"", "", "[other]", "compress/mode=0", "",
    ])
    path.write_bytes(original.encode())
    assert textures.main(["--check", str(path)]) == 1
    assert path.read_bytes() == original.encode()
    assert textures.main(["--apply", str(path)]) == 0
    updated = path.read_bytes()
    expected = original.replace("  compress/mode = 0 ;", "  compress/mode = 2 ;").replace(
        "compress/normal_map=0", "compress/normal_map=1").replace(
        "[other]", f"mipmaps/generate=true{newline}process/size_limit=2048{newline}[other]")
    assert updated == expected.encode()
    assert textures.main(["--check", str(path)]) == 0
    assert textures.main(["--apply", str(path)]) == 0
    assert path.read_bytes() == updated


def test_apply_missing_section_and_final_newline() -> None:
    assert textures.apply_rules("[remap]\nx=1", {"compress/mode": "2"}) == (
        "[remap]\nx=1\n[params]\ncompress/mode=2\n")
    assert textures.apply_rules("[params]\nx=1", {"compress/mode": "2"}) == (
        "[params]\nx=1\ncompress/mode=2\n")


@pytest.mark.parametrize(("color", "transparent", "alpha"), [(2, False, False), (6, False, True),
                                                                   (4, False, True), (3, True, True)])
def test_png_headers(tmp_path: Path, color: int, transparent: bool, alpha: bool) -> None:
    path = tmp_path / "fixture.png"
    png(path, color=color, transparent=transparent)
    assert textures.image_info(path) == (1, 1, alpha)


@pytest.mark.parametrize("marker", [0xC0, 0xC2])
def test_jpeg_header_skips_metadata(tmp_path: Path, marker: int) -> None:
    path = tmp_path / "fixture.jpg"
    path.write_bytes(b"\xff\xd8\xff\xe0\x00\x06test" + bytes((0xFF, marker))
                     + struct.pack(">HBHHB", 8, 8, 32, 64, 3))
    assert textures.image_info(path) == (64, 32, False)


@pytest.mark.parametrize("data", [b"", b"not an image", b"\xff\xd8\xff\xd9", b"\xff\xd8\xff\xe0\x00\x01"])
def test_bad_header_fails_cleanly(tmp_path: Path, data: bytes) -> None:
    path = tmp_path / "bad.png"
    path.write_bytes(data)
    with pytest.raises(ValueError):
        textures.image_info(path)


@pytest.mark.parametrize(("alpha", "normal", "compressed", "mips", "per_pixel"), [
    (False, False, False, False, 4), (False, False, True, False, 0.5),
    (True, False, True, True, 1), (False, True, True, True, 1),
])
def test_estimate_bc1_bc3_bc5_and_size_limit(alpha: bool, normal: bool, compressed: bool,
                                           mips: bool, per_pixel: float) -> None:
    settings = {"compress/mode": "2" if compressed else "0", "compress/normal_map": "1" if normal else "0",
                "mipmaps/generate": "true" if mips else "false", "process/size_limit": "2048"}
    assert textures.estimate((4096, 2048, alpha), settings) == pytest.approx(
        2048 * 1024 * per_pixel * (4 / 3 if mips else 1) / 1024**2)


def test_report_deduplicates_paths_and_keeps_inputs(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    image = tmp_path / "characters/body.png"
    png(image, 4, 2)
    path = image.with_suffix(".png.import")
    original = b"[params]\ncompress/mode=0\nmipmaps/generate=false\n"
    path.write_bytes(original)
    (image.parent / "ignored.jpeg.import").write_text("not selected")
    assert textures.import_paths([image.parent, path]) == [path.resolve()]
    assert textures.main(["--report", str(image.parent), str(path)]) == 0
    assert capsys.readouterr().out.splitlines()[-1] == "RS_TEXTURE_VRAM: 0.000 MiB -> 0.000 MiB (1 textures)"
    assert path.read_bytes() == original
    assert textures.main(["--check", str(tmp_path / "missing")]) == 1
    image.unlink()
    assert textures.main(["--report", str(path)]) == 1


def test_repository_texture_imports_follow_rules() -> None:
    assert textures.main(["--check"]) == 0
