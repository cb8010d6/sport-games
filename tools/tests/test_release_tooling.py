"""Release safety: private runtime files and invalid tool downloads cannot be shipped."""
import hashlib
import json
import tempfile
import unittest
import zipfile
from io import BytesIO
from pathlib import Path
from unittest import mock

from tools import download_godot
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


class GodotSupplyChainTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = json.loads((download_godot.ROOT / "tools/release_config.json").read_text(encoding="utf-8"))
        self.cache = self.root / "tools/_dl/godot/4.7.2-stable"
        self.cache.mkdir(parents=True)
        self.inputs = {}
        for key, item in self.config["godot"]["artifacts"].items():
            buffer = BytesIO()
            with zipfile.ZipFile(buffer, "w") as archive:
                names = {"linux": ["Godot_v4.7.2-stable_linux.x86_64"],
                         "windows": ["Godot_v4.7.2-stable_win64.exe", "Godot_v4.7.2-stable_win64_console.exe"],
                         "templates": ["templates/version.txt"]}[key]
                for name in names:
                    archive.writestr(name, b"verified fixture")
            data = buffer.getvalue()
            item.update(size=len(data), sha512=hashlib.sha512(data).hexdigest())
            self.inputs[item["name"]] = data
        for name, item in self.config["godot"]["notices"].items():
            data = ("upstream notice " + name).encode()
            path = self.root / item["path"]
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            item.update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
        self.set_sums("".join(f"{i['sha512']}  {i['name']}\n" for i in self.config["godot"]["artifacts"].values()))
        self.save_config()
        for name, data in self.inputs.items():
            (self.cache / name).write_bytes(data)

    def save_config(self):
        (self.root / "tools/release_config.json").write_text(json.dumps(self.config), encoding="utf-8")

    def set_sums(self, text):
        data = text.encode()
        sums = self.config["godot"]["sums"]
        sums.update(size=len(data), sha512=hashlib.sha512(data).hexdigest())
        self.inputs[sums["name"]] = data
        (self.cache / sums["name"]).write_bytes(data)

    def test_reviewed_config_and_both_notices_are_valid_offline(self):
        with mock.patch("urllib.request.urlopen", side_effect=AssertionError("no network")):
            config = download_godot.read_config()
            self.assertEqual(set(download_godot.verified_notices(config)), {"LICENSE.txt", "COPYRIGHT.txt"})

    def test_warm_cache_installs_verified_editor_without_network(self):
        target = self.root / "tools/godot"
        target.mkdir()
        (target / "Godot_v4.7.2-stable_linux.x86_64").write_bytes(b"untrusted extracted file")
        (target / "Godot_v4.6.0-stable_linux.x86_64").write_bytes(b"old managed editor")
        (target / "Godot_v4.7.2-regina-ridfix1.exe").write_bytes(b"separate development engine")
        with mock.patch("urllib.request.urlopen", side_effect=AssertionError("no network")):
            download_godot.install(self.root, "linux", offline=True)
        self.assertEqual((target / "Godot_v4.7.2-stable_linux.x86_64").read_bytes(), b"verified fixture")
        self.assertFalse((target / "Godot_v4.6.0-stable_linux.x86_64").exists())
        self.assertEqual((target / "Godot_v4.7.2-regina-ridfix1.exe").read_bytes(), b"separate development engine")

    def test_bad_or_missing_pins_fail_before_any_network(self):
        for key in ("linux", "windows", "templates"):
            item = self.config["godot"]["artifacts"][key]
            digest = item.pop("sha512")
            self.save_config()
            with self.subTest(key=key), mock.patch("urllib.request.urlopen", side_effect=AssertionError("no network")), \
                    self.assertRaisesRegex(RuntimeError, "pin"):
                download_godot.install(self.root, "linux")
            item["sha512"] = digest
        self.config["supplyChainSchema"] = 2
        self.save_config()
        with self.assertRaisesRegex(RuntimeError, "configuration"):
            download_godot.read_config(self.root)

    def test_individually_tampered_inputs_fail_offline(self):
        for name in self.inputs:
            if name == self.config["godot"]["artifacts"]["windows"]["name"]:
                continue
            path = self.cache / name
            original = path.read_bytes()
            path.write_bytes(b"tampered")
            with self.subTest(name=name), mock.patch("urllib.request.urlopen", side_effect=AssertionError("no network")), \
                    self.assertRaisesRegex(RuntimeError, "Offline cache"):
                download_godot.install(self.root, "linux", templates=True, offline=True)
            path.write_bytes(original)
        for item in self.config["godot"]["notices"].values():
            path = self.root / item["path"]
            original = path.read_bytes()
            path.write_bytes(b"tampered")
            with self.subTest(notice=path.name), self.assertRaisesRegex(RuntimeError, "notice checksum"):
                download_godot.install(self.root, "linux", offline=True)
            path.write_bytes(original)

    def test_offline_missing_input_never_falls_back_to_network(self):
        (self.cache / self.config["godot"]["artifacts"]["linux"]["name"]).unlink()
        with mock.patch("urllib.request.urlopen", side_effect=AssertionError("no network")), \
                self.assertRaisesRegex(RuntimeError, "Offline cache"):
            download_godot.install(self.root, "linux", offline=True)

    def test_verified_sums_must_contain_exact_independent_pins(self):
        original = self.inputs["SHA512-SUMS.txt"].decode()
        variants = [original.splitlines()[0] + "\n", original + original,
                    original.replace(original[:128], "0" * 128, 1), "not a checksum\n"]
        for text in variants:
            self.set_sums(text)
            self.save_config()
            with self.subTest(text=text[:20]), mock.patch("urllib.request.urlopen", side_effect=AssertionError("no network")), \
                    self.assertRaisesRegex(RuntimeError, "checksum"):
                download_godot.install(self.root, "linux", offline=True)

    def test_cold_download_is_verified_and_then_installs_offline(self):
        for path in self.cache.iterdir():
            path.unlink()
        def fixture(request, **kwargs):
            return BytesIO(self.inputs[request.full_url.rsplit("/", 1)[1]])
        with mock.patch("urllib.request.urlopen", side_effect=fixture) as network:
            download_godot.install(self.root, "windows")
            self.assertEqual(network.call_count, 2)
        with mock.patch("urllib.request.urlopen", side_effect=AssertionError("no network")):
            download_godot.install(self.root, "windows", offline=True)

    def test_replacing_vendor_sums_and_archive_cannot_change_repository_pins(self):
        item = self.config["godot"]["artifacts"]["linux"]
        changed = b"replaced editor"
        sums = self.inputs["SHA512-SUMS.txt"].replace(item["sha512"].encode(), hashlib.sha512(changed).hexdigest().encode())
        (self.cache / item["name"]).write_bytes(changed)
        (self.cache / "SHA512-SUMS.txt").write_bytes(sums)
        with mock.patch("urllib.request.urlopen", return_value=BytesIO(sums)) as network, \
                self.assertRaisesRegex(RuntimeError, "checksum"):
            download_godot.install(self.root, "linux")
        self.assertEqual(network.call_count, 1)
        self.assertFalse((self.root / "tools/godot").exists())
        self.assertFalse((self.cache / "SHA512-SUMS.txt.part").exists())

    def test_template_install_replaces_owned_directory_without_stale_files(self):
        destination = self.root / "user-data/templates/4.7.2.stable"
        destination.mkdir(parents=True)
        (destination / "stale.bin").write_bytes(b"old")
        archive = self.cache / self.config["godot"]["artifacts"]["templates"]["name"]
        download_godot._install_templates(archive, destination)
        self.assertEqual([p.name for p in destination.iterdir()], ["version.txt"])

    def test_editor_install_rolls_back_owned_files_on_install_failure(self):
        target = self.root / "tools/godot"
        target.mkdir()
        previous = target / "Godot_v4.6.0-stable_linux.x86_64"
        previous.write_bytes(b"previous valid editor")
        replace = Path.replace
        def fail_install(source, destination):
            if source.parent.name.startswith("godot-editor-") and source.name.endswith("linux.x86_64"):
                raise OSError("fixture installation failure")
            return replace(source, destination)
        archive = self.cache / self.config["godot"]["artifacts"]["linux"]["name"]
        with mock.patch.object(Path, "replace", fail_install), self.assertRaises(OSError):
            download_godot._install_editor(archive, target, "linux", "4.7.2-stable")
        self.assertEqual(previous.read_bytes(), b"previous valid editor")
        self.assertEqual([p.name for p in target.iterdir()], [previous.name])


if __name__ == "__main__":
    unittest.main()
