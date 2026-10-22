"""Import project assets through the same bounded runner used by regression tests.

Usage: python tools/import_game.py --godot /path/to/godot
"""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile
from urllib.parse import unquote

from smoke_test import decode, engine_errors
from test_game import ROOT, find_godot, run_engine


def missing_gltf_dependencies(project: Path) -> list[str]:
    missing = []
    # CI may omit the entire art tree. Existing descriptors must have their dependencies.
    for source in sorted(project.rglob("*.gltf")):
        if ".godot" in source.relative_to(project).parts:
            continue
        data = json.loads(source.read_text(encoding="utf-8"))
        for resource in data.get("buffers", []) + data.get("images", []):
            uri = resource.get("uri", "")
            if not uri or uri.startswith("data:"):
                continue
            target = source.parent / unquote(uri)
            if not target.is_file():
                missing.append(f"{source.relative_to(project).as_posix()}: {uri}")
    return missing


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    parser.add_argument("--project", type=Path, default=ROOT / "game")
    parser.add_argument("--timeout", type=float, default=900)
    parser.add_argument("--log", type=Path, default=ROOT / "audit-output" / "import.log")
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and greater than zero")
    project = args.project.resolve()
    if not (project / "project.godot").is_file():
        parser.error(f"Missing project.godot in {project}")
    log = args.log.resolve()
    log.parent.mkdir(parents=True, exist_ok=True)
    # Replace old successful logs even when preflight fails.
    log.write_text("", encoding="utf-8")
    try:
        missing = missing_gltf_dependencies(project)
        if missing:
            message = "Missing glTF dependencies; run node tools/sync_assets.mjs first:\n" + "\n".join(missing)
            log.write_text(message + "\n", encoding="utf-8")
            print(message)
            return 1
        with tempfile.TemporaryDirectory(prefix="rs-import-") as temp:
            env = dict(os.environ, APPDATA=temp, XDG_DATA_HOME=temp,
                       XDG_CONFIG_HOME=temp, XDG_CACHE_HOME=temp)
            # Use forwardable flags: an editor restart must remain windowless and silent.
            command = [find_godot(args.godot), "--display-driver", "headless", "--audio-driver", "Dummy",
                       "--path", str(project), "--editor", "--import", "--log-file", str(log)]
            result = run_engine(command, env=env, timeout=args.timeout)
        output = result.stdout + result.stderr
        log.write_text(output, encoding="utf-8")
        errors, environment = engine_errors(output)
        for warning in environment:
            print(warning)
        if result.returncode or errors:
            print(f"Import failed: exit {result.returncode} (0x{result.returncode & 0xFFFFFFFF:08X}); see {log}")
            return 1
        print(f"Import passed; see {log}")
        return 0
    except subprocess.TimeoutExpired as exc:
        log.write_text(decode(exc.stdout) + decode(exc.stderr), encoding="utf-8")
        print(f"Import timed out after {args.timeout}s; engine tree stopped. See {log}")
        return 1
    except (OSError, ValueError) as exc:
        log.write_text(f"Import failed: {exc}\n", encoding="utf-8")
        print(f"Import failed: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
