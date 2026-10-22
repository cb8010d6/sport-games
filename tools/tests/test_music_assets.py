"""Validate the committed PCM files and their retained generation record."""
from __future__ import annotations

from array import array
import hashlib
import json
import math
from pathlib import Path
import sys
import unittest
import wave

ROOT = Path(__file__).resolve().parents[2]


class MusicAssetTests(unittest.TestCase):
    def test_cues_match_manifest_and_have_safe_loop_boundaries(self) -> None:
        folder = ROOT / "game/assets/music"
        # Lightweight process-tool CI intentionally omits the game art tree.
        if not (folder / "manifest.json").is_file():
            self.skipTest("Music assets are absent from this sparse checkout")
        manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(set(manifest["tracks"]), {"menu", "lobby", "victory"})
        for track, metadata in manifest["tracks"].items():
            with self.subTest(track=track):
                path = folder / (track + ".wav")
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), metadata["sha256"])
                with wave.open(str(path)) as reader:
                    self.assertEqual((reader.getnchannels(), reader.getsampwidth(), reader.getframerate()), (1, 2, 22050))
                    pcm = array("h", reader.readframes(reader.getnframes()))
                if sys.byteorder != "little":
                    pcm.byteswap()
                self.assertLess(max(abs(value) for value in pcm), 32767)
                self.assertGreater(math.sqrt(sum(value * value for value in pcm) / len(pcm)) / 32767, 0.05)
                self.assertLess(abs(sum(pcm) / len(pcm) / 32767), 0.005)
                self.assertEqual(pcm[0], pcm[-1])
                self.assertLess(abs(pcm[-1] - pcm[-2]), 20)
                self.assertAlmostEqual(len(pcm) / 22050, metadata["seconds"], places=5)
