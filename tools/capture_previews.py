"""Render sport preview art from real game cameras, with no HUD or external images.

Requires a graphics-capable Godot and imported full assets. Uses disposable player data.
python tools/capture_previews.py --output game/assets/previews
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import struct
import tempfile
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

import catalog
from smoke_test import GAMES, engine_errors
from test_game import ROOT, find_godot, run_engine


def jpeg_size(data: bytes) -> tuple[int, int]:
    if not data.startswith(b"\xff\xd8") or not data.endswith(b"\xff\xd9"):
        raise ValueError("Incomplete JPEG")
    at = 2
    while at + 4 < len(data):
        if data[at] != 0xFF:
            raise ValueError("Invalid JPEG marker")
        while at < len(data) and data[at] == 0xFF:
            at += 1
        if at >= len(data):
            break
        marker = data[at]
        at += 1
        if marker == 0xDA:
            break
        size = struct.unpack_from(">H", data, at)[0]
        if size < 2 or at + size > len(data):
            raise ValueError("Invalid JPEG segment")
        if marker in (0xC0, 0xC1, 0xC2):
            if size < 8:
                raise ValueError("Invalid JPEG frame")
            height, width = struct.unpack_from(">HH", data, at + 3)
            return width, height
        at += size
    raise ValueError("Missing JPEG dimensions")


@contextmanager
def temporary_data(output: Path) -> Iterator[str]:
    directory = Path(tempfile.mkdtemp(prefix="_run_data-", dir=output)).resolve()
    try:
        yield str(directory)
    finally:
        if directory.parent != output.resolve() or not directory.name.startswith("_run_data-"):
            raise ValueError("Refusing cleanup outside this capture output")
        for attempt in range(4):
            try:
                shutil.rmtree(directory)
                break
            except FileNotFoundError:
                break
            except OSError:
                time.sleep(0.2 * (attempt + 1))
        else:
            print("Cleanup warning: capture cache retained in " + directory.name)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    parser.add_argument("--games", nargs="+", choices=catalog.game_ids(include_hidden=True), default=list(GAMES))
    parser.add_argument("--output", type=Path, default=ROOT / "game/assets/previews")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    logs = ROOT / "audit-output/preview-generation"
    logs.mkdir(parents=True, exist_ok=True)
    manifest_path = out / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.is_file() else {"source": "project camera render", "map": 0, "quality": 1, "images": {}}
    with temporary_data(logs) as temp:
        for game in dict.fromkeys(args.games):
            data = Path(temp) / game
            user = data / ("Godot/app_userdata/Regina Sports" if os.name == "nt" else "godot/app_userdata/Regina Sports")
            user.mkdir(parents=True)
            (user / "settings.cfg").write_text('[display]\nquality=1\n', encoding="utf-8")
            picture = out / (game + ".jpg")
            pending = logs / (game + ".pending.jpg")
            pending.unlink(missing_ok=True)
            env = dict(os.environ, RS_TEST_MODE="1", APPDATA=str(data), XDG_DATA_HOME=str(data),
                       XDG_CONFIG_HOME=temp, XDG_CACHE_HOME=temp, RS_PREVIEW_GAME=game, RS_PREVIEW_OUTPUT=str(pending))
            result = run_engine([find_godot(args.godot), "--path", str(ROOT / "game"),
                                 "res://tests/capture_preview.tscn", "--fixed-fps", "60", "--resolution", "1600x900",
                                 "--", "--demo=1", "--map=0"], env=env, timeout=240)
            log = result.stdout + result.stderr
            (logs / (game + ".log")).write_text(log, encoding="utf-8")
            errors, environment = engine_errors(log)
            if result.returncode or errors or f"RS_PREVIEW_DONE: {game} 1600x900" not in log.splitlines():
                print(f"{game}: failed; see audit-output/preview-generation/{game}.log")
                return 1
            encoded = pending.read_bytes()
            if jpeg_size(encoded) != (1600, 900):
                raise ValueError("Unexpected preview resolution")
            pending.replace(picture)
            manifest["images"][game] = {"file": picture.name, "bytes": len(encoded), "sha256": hashlib.sha256(encoded).hexdigest(), "width": 1600, "height": 900}
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8", newline="\n")
            print(f"{game}: PASS ({len(encoded)} bytes; environment notes: {len(environment)})", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
