"""Check private golf mip preparation, source preservation, cache reuse and visible errors."""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import tempfile
from pathlib import Path

from engine_process import run_engine
from smoke_test import decode, engine_errors
from test_game import ROOT, find_godot

REJECTIONS = {
    "missing": "missing texture: res://tests/missing-golf-texture.png",
    "type": "expected Texture2D: res://tests/test_golf_surface.tscn",
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    args = parser.parse_args()
    output = ROOT / "audit-output/golf-mips"
    output.mkdir(parents=True, exist_ok=True)
    for invalid in ("", *REJECTIONS):
        case = invalid or "textures"
        with tempfile.TemporaryDirectory(prefix="rs-golf-mips-") as temp:
            env = dict(os.environ, RS_TEST_MODE="1", RS_GOLF_TEXTURE_INVALID=invalid,
                       APPDATA=temp, LOCALAPPDATA=temp, XDG_DATA_HOME=temp,
                       XDG_CONFIG_HOME=temp, XDG_CACHE_HOME=temp)
            command = [find_godot(args.godot), "--headless", "--audio-driver", "Dummy", "--fixed-fps", "60",
                       "--quit-after", "3600", "--log-file", str(output / f"{case}-engine.log"),
                       "--path", str(ROOT / "game"), "res://tests/test_golf_textures.tscn"]
            try:
                result = run_engine(command, env=env, timeout=60)
            except subprocess.TimeoutExpired as exc:
                log = decode(exc.stdout) + decode(exc.stderr)
                (output / f"{case}.log").write_text(log, encoding="utf-8")
                print(log)
                print(f"{case}: timed out; owned engine tree stopped")
                return 1
            log = result.stdout + result.stderr
            (output / f"{case}.log").write_text(log, encoding="utf-8")
            errors, environment = engine_errors(log)
            marker = "RS_GOLF_TEXTURE_REJECTION:" if invalid else "RS_GOLF_TEXTURE_TESTS:"
            markers = [line for line in log.splitlines() if line.startswith(marker)]
            expected = ["ERROR: RSGolfTextures: " + REJECTIONS[invalid]] if invalid else []
            if (result.returncode != int(bool(invalid)) or errors != expected or environment
                    or list(Path(temp).rglob("records.cfg")) or len(markers) != 1
                    or not re.fullmatch(re.escape(marker) + r" [1-9][0-9]* checks, 0 failures", markers[0])):
                print(log)
                print(f"{case}: failed")
                return 1
            print(f"{case}: {markers[0]}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
