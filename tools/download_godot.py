"""Install the exact official editor/templates after verifying the vendor's SHA-512 sums."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def download(url: str, target: Path, expected: str | None = None) -> None:
    if target.exists() and expected:
        with target.open("rb") as source:
            if hashlib.file_digest(source, "sha512").hexdigest() == expected:
                return
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(target.suffix + ".part")
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "sport-games-build/1.0"})
        with urllib.request.urlopen(request, timeout=180) as response, temporary.open("wb") as output:
            shutil.copyfileobj(response, output)
        if expected:
            with temporary.open("rb") as source:
                if hashlib.file_digest(source, "sha512").hexdigest() != expected:
                    raise RuntimeError("Official Godot checksum mismatch")
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)


def extract_archive(archive: Path, target: Path) -> None:
    target.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as source:
        for entry in source.infolist():
            dest = (target / entry.filename).resolve()
            if not dest.is_relative_to(target.resolve()):
                raise RuntimeError("Archive entry escapes the tool directory")
        source.extractall(target)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=["windows", "linux"], default="windows" if sys.platform == "win32" else "linux")
    parser.add_argument("--templates", action="store_true")
    args = parser.parse_args()
    version = json.loads((ROOT / "tools/release_config.json").read_text())["godotVersion"]
    tag = version + "-stable"
    base = f"https://github.com/godotengine/godot-builds/releases/download/{tag}"
    cache = ROOT / "tools/_dl/godot" / tag
    sums = cache / "SHA512-SUMS.txt"
    download(base + "/SHA512-SUMS.txt", sums)
    hashes = {parts[1].lstrip("*"): parts[0] for line in sums.read_text().splitlines() if len(parts := line.split()) == 2}
    editor = f"Godot_v{tag}_" + ("win64.exe.zip" if args.platform == "windows" else "linux.x86_64.zip")
    if editor not in hashes:
        raise RuntimeError("Requested editor is absent from official checksums")
    download(base + "/" + editor, cache / editor, hashes[editor])
    tools = ROOT / "tools/godot"
    extract_archive(cache / editor, tools)
    if args.platform == "linux":
        (tools / f"Godot_v{tag}_linux.x86_64").chmod(0o755)
    if args.templates:
        name = f"Godot_v{tag}_export_templates.tpz"
        download(base + "/" + name, cache / name, hashes[name])
        staging = cache / "export"
        extract_archive(cache / name, staging)
        data = Path(os.environ.get("APPDATA", "")) if sys.platform == "win32" else Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
        destination = data / "Godot/export_templates" / (version + ".stable") if sys.platform == "win32" else data / "godot/export_templates" / (version + ".stable")
        shutil.copytree(staging / "templates", destination, dirs_exist_ok=True)
    print(f"Verified Godot {tag} installed in tools/godot")


if __name__ == "__main__":
    main()
