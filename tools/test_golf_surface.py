"""Check conforming golf terrain with emitted triangles, physics rays and invalid inputs."""
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
    "unbuilt": "query needs a built surface and finite coordinates",
    "nan-query": "query needs a built surface and finite coordinates",
    "inf-query": "query needs a built surface and finite coordinates",
    "bad-cell": "invalid cell query",
    "bad-triangle": "invalid triangle query",
    "bad-chunk": "invalid chunk query",
    "bad-patch": "invalid refinement patch",
    "overflow-patch": "invalid refinement patch",
    "huge-domain": "invalid terrain domain or sampler",
    "inf-domain": "invalid terrain domain or sampler",
    "nan-sample": "invalid terrain sample",
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    args = parser.parse_args()
    output = ROOT / "audit-output/golf-g3-b"
    output.mkdir(parents=True, exist_ok=True)
    for invalid in ("", *REJECTIONS):
        case = f"invalid-{invalid}" if invalid else "surface"
        with tempfile.TemporaryDirectory(prefix="rs-golf-surface-") as temp:
            env = dict(os.environ, RS_TEST_MODE="1", RS_GOLF_SURFACE_INVALID=invalid,
                       APPDATA=temp, LOCALAPPDATA=temp, XDG_DATA_HOME=temp, XDG_CONFIG_HOME=temp, XDG_CACHE_HOME=temp)
            command = [find_godot(args.godot), "--headless", "--audio-driver", "Dummy", "--fixed-fps", "60",
                       "--quit-after", "36000", "--log-file", str(output / f"{case}-engine.log"),
                       "--path", str(ROOT / "game"), "res://tests/test_golf_surface.tscn"]
            try:
                result = run_engine(command, env=env, timeout=180)
            except subprocess.TimeoutExpired as exc:
                log = decode(exc.stdout) + decode(exc.stderr)
                (output / f"{case}.log").write_text(log, encoding="utf-8")
                print(log)
                print(f"{case}: timed out; owned engine tree stopped")
                return 1
            log = result.stdout + result.stderr
            (output / f"{case}.log").write_text(log, encoding="utf-8")
            errors, environment = engine_errors(log)
            marker = "RS_GOLF_SURFACE_REJECTION:" if invalid else "RS_GOLF_SURFACE_TESTS:"
            markers = [line for line in log.splitlines() if line.startswith(marker)]
            records = list(Path(temp).rglob("records.cfg"))
            expected_errors = ["ERROR: RSGolfSurface: " + REJECTIONS[invalid]] if invalid else []
            if (result.returncode != int(bool(invalid)) or errors != expected_errors or environment or records
                    or len(markers) != 1
                    or not re.fullmatch(re.escape(marker) + r" [1-9][0-9]* checks, 0 failures", markers[0])):
                print(log)
                print(f"{case}: failed (record files: {len(records)})")
                return 1
            metrics = [line for line in log.splitlines() if line.startswith((
                "RS_GOLF_SURFACE_TRIANGLES:", "RS_GOLF_SURFACE_MESH_NORMAL:", "RS_GOLF_SURFACE_NORMAL_CODEC:"))]
            print(f"{case}: {markers[0]} (environment notes: {len(environment)})", flush=True)
            for line in metrics:
                print(line, flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
