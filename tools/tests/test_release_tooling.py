"""Release safety: private runtime files and invalid tool downloads cannot be shipped."""
import hashlib
import tempfile
import unittest
import zipfile
from io import BytesIO
from pathlib import Path
from unittest import mock

from tools.download_godot import download, extract_archive
from tools.package_archive import FONT_LICENSES, REQUIRED, validate_package


def package(tmp_path: Path) -> Path:
    root = tmp_path / "package"
    for name in REQUIRED:
        file = root / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(b"fixture")
    return root


class ReleaseToolingTests(unittest.TestCase):
    def test_incomplete_package_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = package(Path(temp))
            (root / "game/SportGames.pck").unlink()
            with self.assertRaisesRegex(RuntimeError, "Incomplete package"):
                validate_package(root)

    def test_runtime_private_files_are_rejected(self):
        for name in ["data/.certs/private.key", "data/cert.pem", "hub.log", "samples.jsonl",
                     ".git/config", "game/SportGames.pck-leftover"]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temp:
                root = package(Path(temp))
                file = root / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(b"fixture")
                with self.assertRaisesRegex(RuntimeError, "Private"):
                    validate_package(root)

    def test_bundled_font_licenses_are_required(self):
        self.assertGreaterEqual({f.name for f in FONT_LICENSES}, {"OFL-BarlowCondensed.txt", "OFL-NotoSansSC.txt"})
        with tempfile.TemporaryDirectory() as temp:
            root = package(Path(temp))
            (root / "licenses" / FONT_LICENSES[0].name).unlink()
            with self.assertRaisesRegex(RuntimeError, "Incomplete package"):
                validate_package(root)

    def test_complete_package_can_be_enumerated(self):
        with tempfile.TemporaryDirectory() as temp:
            root = package(Path(temp))
            self.assertEqual(len(validate_package(root)), len(REQUIRED))

    def test_archive_cannot_escape_tool_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            tmp_path = Path(temp)
            archive = tmp_path / "download.zip"
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("../escape.txt", "fixture")
            with self.assertRaisesRegex(RuntimeError, "escapes"):
                extract_archive(archive, tmp_path / "tools")
            self.assertFalse((tmp_path / "escape.txt").exists())

    def test_bad_checksum_never_replaces_cached_tool(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / "tool.zip"
            target.write_bytes(b"previous version")
            with mock.patch("urllib.request.urlopen", return_value=BytesIO(b"invalid data")), \
                 self.assertRaisesRegex(RuntimeError, "checksum"):
                download("https://github.com/godotengine/godot-builds", target,
                         hashlib.sha512(b"expected").hexdigest())
            self.assertEqual(target.read_bytes(), b"previous version")
            self.assertFalse(target.with_suffix(".zip.part").exists())

    def test_verified_cache_is_offline(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / "tool.zip"
            target.write_bytes(b"verified")
            with mock.patch("urllib.request.urlopen",
                            side_effect=AssertionError("verified cache must not use network")):
                download("https://github.com/godotengine/godot-builds", target,
                         hashlib.sha512(b"verified").hexdigest())


if __name__ == "__main__":
    unittest.main()
