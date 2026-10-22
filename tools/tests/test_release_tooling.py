"""Release safety: private runtime files and invalid tool downloads cannot be shipped."""
import hashlib
import zipfile
from io import BytesIO
from pathlib import Path

import pytest

from tools.download_godot import download, extract_archive
from tools.package_archive import validate_package


def package(tmp_path: Path) -> Path:
    root = tmp_path / "package"
    for name in ["SportGames.exe", "game/SportGames.exe", "game/SportGames.pck", "hub/sport-hub.exe", "hub/config.json", "licenses/LICENSE", "BUILD_INFO.json"]:
        file = root / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(b"fixture")
    return root


def test_incomplete_package_is_rejected(tmp_path):
    root = package(tmp_path)
    (root / "game/SportGames.pck").unlink()
    with pytest.raises(RuntimeError, match="Incomplete package"):
        validate_package(root)


@pytest.mark.parametrize("name", ["data/.certs/private.key", "data/cert.pem", "hub.log", "samples.jsonl", ".git/config", "game/SportGames.pck-leftover"])
def test_runtime_private_files_are_rejected(tmp_path, name):
    root = package(tmp_path)
    file = root / name
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_bytes(b"fixture")
    with pytest.raises(RuntimeError, match="Private"):
        validate_package(root)


def test_complete_package_can_be_enumerated(tmp_path):
    root = package(tmp_path)
    assert len(validate_package(root)) == 7


def test_archive_cannot_escape_tool_directory(tmp_path):
    archive = tmp_path / "download.zip"
    with zipfile.ZipFile(archive, "w") as output:
        output.writestr("../escape.txt", "fixture")
    with pytest.raises(RuntimeError, match="escapes"):
        extract_archive(archive, tmp_path / "tools")
    assert not (tmp_path / "escape.txt").exists()


def test_bad_checksum_never_replaces_cached_tool(tmp_path, monkeypatch):
    target = tmp_path / "tool.zip"
    target.write_bytes(b"previous version")
    monkeypatch.setattr("urllib.request.urlopen", lambda *args, **kwargs: BytesIO(b"invalid data"))
    with pytest.raises(RuntimeError, match="checksum"):
        download("https://github.com/godotengine/godot-builds", target, hashlib.sha512(b"expected").hexdigest())
    assert target.read_bytes() == b"previous version"
    assert not target.with_suffix(".zip.part").exists()


def test_verified_cache_is_offline(tmp_path, monkeypatch):
    target = tmp_path / "tool.zip"
    target.write_bytes(b"verified")
    def no_network(*args, **kwargs):
        raise AssertionError("verified cache must not use network")
    monkeypatch.setattr("urllib.request.urlopen", no_network)
    download("https://github.com/godotengine/godot-builds", target, hashlib.sha512(b"verified").hexdigest())
