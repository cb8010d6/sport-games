"""Check capture validation and the provenance of committed preview images."""
from __future__ import annotations

import hashlib
import json
import os
import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from capture_previews import jpeg_size

ROOT = Path(__file__).resolve().parents[2]


class PreviewImageTests(unittest.TestCase):
    def test_missing_truncated_and_wrong_headers_are_rejected(self) -> None:
        valid = b"\xff\xd8\xff\xc0" + struct.pack(">HBHHB", 8, 8, 900, 1600, 1) + b"\xff\xd9"
        self.assertEqual(jpeg_size(valid), (1600, 900))
        for data in (b"", valid[:-1], b"PNG", b"\xff\xd8\xff\xe0\0\1\xff\xd9",
                     b"\xff\xd8\xff\xda\0\2\xff\xd9"):
            with self.subTest(data=data), self.assertRaises(ValueError):
                jpeg_size(data)

    def test_committed_images_match_capture_manifest(self) -> None:
        folder = ROOT / "game/assets/previews"
        if not (folder / "manifest.json").is_file():
            # Only the lightweight process-tool CI (RS_SPARSE_ASSETS=1) omits the art tree; elsewhere the folder is lost.
            if os.environ.get("RS_SPARSE_ASSETS") != "1":
                self.fail(f"{folder} has no manifest.json (RS_SPARSE_ASSETS=1 is only for sparse checkouts)")
            self.skipTest("Preview assets are absent from this sparse checkout")
        manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(set(manifest["images"]), {"plane", "archery", "bowling", "skate", "ski", "basketball"})
        for game, row in manifest["images"].items():
            with self.subTest(game=game):
                encoded = (folder / (game + ".jpg")).read_bytes()
                self.assertEqual(jpeg_size(encoded), (1600, 900))
                self.assertEqual(hashlib.sha256(encoded).hexdigest(), row["sha256"])
                self.assertEqual(len(encoded), row["bytes"])
