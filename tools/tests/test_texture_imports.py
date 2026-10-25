"""Texture import rules, header-only estimates, and line-preserving fixes."""
from __future__ import annotations

import io
import os
import struct
import tempfile
import unittest
import zlib
from contextlib import redirect_stdout
from pathlib import Path

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


class TextureImportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="rs-texture-tests-")))
        self.output = io.StringIO()
        self.enterContext(redirect_stdout(self.output))

    def test_filename_and_directory_rules(self) -> None:
        cases = [
            ("characters/body_normal.png.import", True, "2048"),
            ("shared/characters/person_eyebrow.png.import", False, "1024"),
            ("characters/person_eyelashes.png.import", False, "1024"),
            ("characters/person_eye.png.import", False, "1024"),
            ("shared/materials/brick_nor_gl_2k.jpg.import", True, None),
            ("shared/materials/brick_diff_2k.jpg.import", False, None),
        ]
        for name, normal, limit in cases:
            with self.subTest(name=name):
                result = textures.rules(Path(name))
                self.assertEqual(result["compress/mode"], "2")
                self.assertEqual(result["mipmaps/generate"], "true")
                self.assertEqual(result.get("compress/normal_map"), "1" if normal else None)
                self.assertEqual(result.get("process/size_limit"), limit)

    def test_apply_preserves_other_lines_and_sections(self) -> None:
        for newline, folder in [("\n", "lf"), ("\r\n", "crlf")]:
            with self.subTest(newline=repr(newline)):
                path = self.temp / folder / "characters/body_normal.png.import"
                path.parent.mkdir(parents=True)
                original = newline.join([
                    "[remap]", 'path="unchanged.ctex"', 'metadata={"vram_texture": false}',
                    "[params]", "  compress/mode = 0 ; keep comment", "compress/normal_map=0",
                    "process/channel_remap/red=2", "unrelated=\"a=b\"", "", "[other]", "compress/mode=0", "",
                ])
                path.write_bytes(original.encode())
                self.assertEqual(textures.main(["--check", str(path)]), 1)
                self.assertEqual(path.read_bytes(), original.encode())
                self.assertEqual(textures.main(["--apply", str(path)]), 0)
                updated = path.read_bytes()
                expected = original.replace("  compress/mode = 0 ;", "  compress/mode = 2 ;").replace(
                    "compress/normal_map=0", "compress/normal_map=1").replace(
                    "[other]", f"mipmaps/generate=true{newline}process/size_limit=2048{newline}[other]")
                self.assertEqual(updated, expected.encode())
                self.assertEqual(textures.main(["--check", str(path)]), 0)
                self.assertEqual(textures.main(["--apply", str(path)]), 0)
                self.assertEqual(path.read_bytes(), updated)

    def test_apply_missing_section_and_final_newline(self) -> None:
        self.assertEqual(textures.apply_rules("[remap]\nx=1", {"compress/mode": "2"}),
                         "[remap]\nx=1\n[params]\ncompress/mode=2\n")
        self.assertEqual(textures.apply_rules("[params]\nx=1", {"compress/mode": "2"}),
                         "[params]\nx=1\ncompress/mode=2\n")

    def test_png_headers(self) -> None:
        for color, transparent, alpha in [(2, False, False), (6, False, True), (4, False, True), (3, True, True)]:
            with self.subTest(color=color, transparent=transparent):
                path = self.temp / "fixture.png"
                png(path, color=color, transparent=transparent)
                self.assertEqual(textures.image_info(path), (1, 1, alpha))

    def test_jpeg_header_skips_metadata(self) -> None:
        for marker in [0xC0, 0xC2]:
            with self.subTest(marker=marker):
                path = self.temp / "fixture.jpg"
                path.write_bytes(b"\xff\xd8\xff\xe0\x00\x06test" + bytes((0xFF, marker))
                                 + struct.pack(">HBHHB", 8, 8, 32, 64, 3))
                self.assertEqual(textures.image_info(path), (64, 32, False))

    def test_bad_header_fails_cleanly(self) -> None:
        for data in [b"", b"not an image", b"\xff\xd8\xff\xd9", b"\xff\xd8\xff\xe0\x00\x01"]:
            with self.subTest(data=data):
                path = self.temp / "bad.png"
                path.write_bytes(data)
                with self.assertRaises(ValueError):
                    textures.image_info(path)

    def test_estimate_bc1_bc3_bc5_and_size_limit(self) -> None:
        cases = [(False, False, False, False, 4), (False, False, True, False, 0.5),
                 (True, False, True, True, 1), (False, True, True, True, 1)]
        for alpha, normal, compressed, mips, per_pixel in cases:
            with self.subTest(alpha=alpha, normal=normal, compressed=compressed, mips=mips):
                settings = {"compress/mode": "2" if compressed else "0", "compress/normal_map": "1" if normal else "0",
                            "mipmaps/generate": "true" if mips else "false", "process/size_limit": "2048"}
                self.assertAlmostEqual(textures.estimate((4096, 2048, alpha), settings),
                                       2048 * 1024 * per_pixel * (4 / 3 if mips else 1) / 1024**2)

    def test_report_deduplicates_paths_and_keeps_inputs(self) -> None:
        image = self.temp / "characters/body.png"
        png(image, 4, 2)
        path = image.with_suffix(".png.import")
        original = b"[params]\ncompress/mode=0\nmipmaps/generate=false\n"
        path.write_bytes(original)
        (image.parent / "ignored.jpeg.import").write_text("not selected")
        self.assertEqual(textures.import_paths([image.parent, path]), [path.resolve()])
        self.assertEqual(textures.main(["--report", str(image.parent), str(path)]), 0)
        self.assertEqual(self.output.getvalue().splitlines()[-1],
                         "RS_TEXTURE_VRAM: 0.000 MiB -> 0.000 MiB (1 textures)")
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(textures.main(["--check", str(self.temp / "missing")]), 1)
        image.unlink()
        self.assertEqual(textures.main(["--report", str(path)]), 1)

    def test_repository_texture_imports_follow_rules(self) -> None:
        # Process-tool CI deliberately checks out fonts only; full checkouts must
        # exercise both real asset directories, including partially missing trees.
        if os.environ.get("RS_SPARSE_ASSETS") == "1" and all(not path.exists() for path in textures.DEFAULT_PATHS):
            self.skipTest("Texture assets are absent from this sparse checkout")
        self.assertEqual(textures.main(["--check"]), 0, self.output.getvalue())
