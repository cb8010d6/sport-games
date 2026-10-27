"""Install Godot inputs pinned by the reviewed repository, including offline use."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _matches(path: Path, expected: str, size: int | None, algorithm: str = "sha512") -> bool:
    if path.is_symlink() or not path.is_file() or (size is not None and path.stat().st_size != size):
        return False
    with path.open("rb") as source:
        return hashlib.file_digest(source, algorithm).hexdigest() == expected


def download(url: str, target: Path, expected: str | None = None, *,
             size: int | None = None, offline: bool = False) -> None:
    if expected is None or not re.fullmatch(r"[0-9a-f]{128}", expected):
        raise RuntimeError("A pinned SHA-512 checksum is required")
    if _matches(target, expected, size):
        return
    if offline:
        raise RuntimeError(f"Offline cache missing or invalid: {target.name}")
    if target.is_symlink():
        raise RuntimeError(f"Cache symlink refused: {target.name}")
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(target.suffix + ".part")
    if temporary.is_symlink():
        raise RuntimeError(f"Partial-download symlink refused: {target.name}")
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "sport-games-build/1.0"})
        with urllib.request.urlopen(request, timeout=180) as response, temporary.open("wb") as output:
            count = 0
            while chunk := response.read(1024 * 1024):
                count += len(chunk)
                if size is not None and count > size:
                    raise RuntimeError(f"Godot size mismatch: {target.name}")
                output.write(chunk)
        if not _matches(temporary, expected, size):
            raise RuntimeError(f"Godot checksum or size mismatch: {target.name}")
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)


def extract_archive(archive: Path, target: Path) -> None:
    target.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as source:
        for entry in source.infolist():
            dest = (target / entry.filename).resolve()
            if ("\\" in entry.filename or ":" in entry.filename or
                    not dest.is_relative_to(target.resolve()) or stat.S_ISLNK(entry.external_attr >> 16)):
                raise RuntimeError("Archive entry escapes the tool directory")
        source.extractall(target)


def read_config(root: Path = ROOT) -> dict:
    config = json.loads((root / "tools/release_config.json").read_text(encoding="utf-8"))
    version = config.get("godotVersion", "")
    godot = config.get("godot", {})
    if (type(config.get("supplyChainSchema")) is not int or config["supplyChainSchema"] != 1 or
            not re.fullmatch(r"\d+\.\d+\.\d+", version) or
            godot.get("releaseRepository") != "godotengine/godot-builds" or
            not re.fullmatch(r"[0-9a-f]{40}", godot.get("sourceCommit", ""))):
        raise RuntimeError("Invalid Godot supply-chain configuration")
    tag = version + "-stable"
    names = {"linux": f"Godot_v{tag}_linux.x86_64.zip", "windows": f"Godot_v{tag}_win64.exe.zip",
             "templates": f"Godot_v{tag}_export_templates.tpz"}
    artifacts = godot.get("artifacts", {})
    if set(artifacts) != set(names):
        raise RuntimeError("Godot artifact configuration is incomplete")
    for key, expected_name in {"sums": "SHA512-SUMS.txt", **names}.items():
        item = godot.get("sums", {}) if key == "sums" else artifacts[key]
        if (item.get("name") != expected_name or type(item.get("size")) is not int or item["size"] <= 0 or
                not re.fullmatch(r"[0-9a-f]{128}", item.get("sha512", ""))):
            raise RuntimeError(f"Missing or invalid Godot pin: {key}")
    verified_notices(config, root)
    return config


def verified_notices(config: dict, root: Path = ROOT) -> dict[str, Path]:
    notices = config.get("godot", {}).get("notices", {})
    if set(notices) != {"LICENSE.txt", "COPYRIGHT.txt"}:
        raise RuntimeError("Godot notice configuration is incomplete")
    result = {}
    for name, item in notices.items():
        expected_path = f"tools/licenses/godot/{config['godotVersion']}/{name}"
        if (item.get("path") != expected_path or item.get("sourcePath") != name or
                type(item.get("size")) is not int or item["size"] <= 0 or
                not re.fullmatch(r"[0-9a-f]{64}", item.get("sha256", ""))):
            raise RuntimeError(f"Missing or invalid Godot notice pin: {name}")
        path = root / expected_path
        if not path.resolve().is_relative_to(root.resolve()) or not _matches(
                path, item["sha256"], item["size"], "sha256"):
            raise RuntimeError(f"Godot notice checksum mismatch: {name}")
        result[name] = path
    return result


def parse_sums(text: str, artifacts: dict) -> dict[str, str]:
    hashes = {}
    for line in text.splitlines():
        match = re.fullmatch(r"([0-9a-fA-F]{128}) [ *]([^/\\\s:]+)", line)
        if not match or match[2] in hashes:
            raise RuntimeError("Malformed or duplicate Godot checksum entry")
        hashes[match[2]] = match[1].lower()
    for item in artifacts.values():
        if hashes.get(item["name"]) != item["sha512"]:
            raise RuntimeError(f"Godot checksum entry missing or changed: {item['name']}")
    return hashes


def _install_editor(archive: Path, target: Path, platform: str, tag: str) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="godot-editor-", dir=target.parent) as temp:
        staging = Path(temp)
        extract_archive(archive, staging)
        names = ([f"Godot_v{tag}_win64.exe", f"Godot_v{tag}_win64_console.exe"] if platform == "windows"
                 else [f"Godot_v{tag}_linux.x86_64"])
        if sorted(p.name for p in staging.iterdir()) != sorted(names):
            raise RuntimeError("Godot editor archive has unexpected contents")
        target.mkdir(parents=True, exist_ok=True)
        # This directory also holds separately built development engines. Own
        # only official editor filenames for this platform, never their files.
        suffix = r"win64(?:_console)?\.exe" if platform == "windows" else r"linux\.x86_64"
        owned = [p for p in target.iterdir() if re.fullmatch(r"Godot_v\d+\.\d+\.\d+-stable_" + suffix, p.name)]
        if any(p.is_symlink() or not p.is_file() for p in owned):
            raise RuntimeError("Managed Godot editor path is not a regular file")
        backup = staging / "previous"
        backup.mkdir()
        installed = []
        for name in names:
            source = staging / name
            if not source.is_file():
                raise RuntimeError("Godot editor archive is incomplete")
            if platform == "linux":
                source.chmod(0o755)
        try:
            for old in owned:
                old.replace(backup / old.name)
            for name in names:
                (staging / name).replace(target / name)
                installed.append(target / name)
        except OSError:
            for path in installed:
                path.unlink()
            for old in backup.iterdir():
                old.replace(target / old.name)
            raise


def _install_templates(archive: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink():
        raise RuntimeError("Template destination symlink refused")
    with tempfile.TemporaryDirectory(prefix="godot-templates-", dir=destination.parent) as temp:
        staging = Path(temp)
        extract_archive(archive, staging / "new")
        source = staging / "new/templates"
        if not source.is_dir():
            raise RuntimeError("Godot template archive is incomplete")
        backup = staging / "previous"
        if destination.exists():
            destination.replace(backup)
        try:
            source.replace(destination)
        except OSError:
            if backup.exists():
                backup.replace(destination)
            raise


def install(root: Path, platform: str, templates: bool = False, offline: bool = False) -> None:
    config = read_config(root)  # Validate every pin and both local notices before any network access.
    godot = config["godot"]
    version = config["godotVersion"]
    tag = version + "-stable"
    base = f"https://github.com/{godot['releaseRepository']}/releases/download/{tag}"
    cache = root / "tools/_dl/godot" / tag
    if any(not path.resolve().is_relative_to(root.resolve()) for path in (cache, root / "tools/godot")):
        raise RuntimeError("Godot tool directory escapes the repository")
    def acquire(item: dict) -> Path:
        path = cache / item["name"]
        download(base + "/" + item["name"], path, item["sha512"], size=item["size"], offline=offline)
        return path
    sums = acquire(godot["sums"])
    parse_sums(sums.read_text(encoding="utf-8"), godot["artifacts"])
    editor = acquire(godot["artifacts"][platform])
    template = acquire(godot["artifacts"]["templates"]) if templates else None
    _install_editor(editor, root / "tools/godot", platform, tag)
    if template is not None:
        data = (Path(os.environ.get("APPDATA", "")) if sys.platform == "win32" else
                Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")))
        destination = data / ("Godot" if sys.platform == "win32" else "godot") / "export_templates" / (version + ".stable")
        _install_templates(template, destination)
    print(f"Verified Godot {tag} installed in tools/godot")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=["windows", "linux"], default="windows" if sys.platform == "win32" else "linux")
    parser.add_argument("--templates", action="store_true")
    parser.add_argument("--offline", action="store_true", help="Require verified cached inputs; never contact the network")
    args = parser.parse_args()
    try:
        install(ROOT, args.platform, args.templates, args.offline)
    except (RuntimeError, ValueError, KeyError, TypeError) as exc:
        parser.exit(1, f"Godot input verification failed: {exc}\n")
    except OSError:
        parser.exit(1, "Godot input installation failed; check file permissions and network availability.\n")


if __name__ == "__main__":
    main()
