"""Archive only the portable package, reject private/generated runtime files, write SHA-256."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN = {".certs", ".git", ".venv", "__pycache__", "node_modules"}
PRIVATE_SUFFIXES = {".pem", ".key", ".p12", ".pfx", ".jsonl", ".log"}


def validate_package(root: Path) -> list[Path]:
    for required in ["SportGames.exe", "game/SportGames.exe", "game/SportGames.pck", "hub/sport-hub.exe", "hub/config.json", "licenses/LICENSE", "BUILD_INFO.json"]:
        if not (root / required).is_file():
            raise RuntimeError("Incomplete package: " + required)
    files = sorted(p for p in root.rglob("*") if p.is_file())
    for file in files:
        if file.is_symlink() or set(file.relative_to(root).parts) & FORBIDDEN or file.suffix.lower() in PRIVATE_SUFFIXES or ".pck-" in file.name.lower():
            raise RuntimeError("Private or unsupported file in release: " + file.relative_to(root).as_posix())
    return files


def main() -> None:
    name = json.loads((ROOT / "tools/release_config.json").read_text())["packageName"]
    package = ROOT / "dist" / name
    files = validate_package(package)
    archive = ROOT / "dist" / (name + ".zip")
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as output:
        for file in files:
            output.write(file, name + "/" + file.relative_to(package).as_posix())
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    archive.with_suffix(".zip.sha256").write_text(digest + "  " + archive.name + "\n", encoding="ascii")
    print("Checked and archived", len(files), "files.")


if __name__ == "__main__":
    main()
