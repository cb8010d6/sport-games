"""Build, verify and install the pinned Windows Godot RID fix inside this workspace.

python tools/build_godot.py --jobs 12
Downloads and build products stay under tools/_dl; the official engine is preserved.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.request
import venv
import zipfile

from engine_process import WindowsJob
from test_game import ROOT


PATCH_DIR = ROOT / "tools/engine_patches"
LOCK = json.loads((PATCH_DIR / "build-lock.json").read_text(encoding="utf-8"))
OPTIONS = ["platform=windows", "target=editor", "arch=x86_64", "use_mingw=yes", "use_llvm=yes",
           "lto=none", "d3d12=no", "angle=no", "accesskit=no", "winrt=no", "debug_symbols=yes",
           "scu_build=yes", "scu_limit=8"]


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def prepare_toolchain(cache: Path) -> Path:
    archive = cache / LOCK["toolchain_archive"]
    if not archive.is_file():
        print("Downloading pinned portable LLVM-MinGW...", flush=True)
        partial = archive.with_suffix(".part")
        with urllib.request.urlopen(LOCK["toolchain_url"], timeout=120) as response, partial.open("wb") as target:
            shutil.copyfileobj(response, target)
        if sha256(partial) != LOCK["toolchain_sha256"]:
            raise RuntimeError("Toolchain SHA256 mismatch")
        partial.replace(archive)
    if sha256(archive) != LOCK["toolchain_sha256"]:
        raise RuntimeError(f"Toolchain SHA256 mismatch: {archive}")
    directory = cache / archive.stem
    stamp = directory / ".regina-toolchain-sha256"
    if not stamp.is_file() or stamp.read_text().strip() != LOCK["toolchain_sha256"]:
        print("Extracting verified toolchain...", flush=True)
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(cache)
        stamp.write_text(LOCK["toolchain_sha256"] + "\n")
    return directory / "bin"


def prepare_source(cache: Path) -> Path:
    source = cache / "godot-src-4.7.2"
    if not source.exists():
        subprocess.run(["git", "clone", "--depth", "1", "--branch", LOCK["godot_ref"],
                        "https://github.com/godotengine/godot.git", str(source)], check=True, timeout=600)
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if commit != LOCK["godot_commit"]:
        raise RuntimeError(f"Engine source must be {LOCK['godot_commit']}, found {commit}")
    patch = str(PATCH_DIR / "dummy-rid-thread-safety.patch")
    check = subprocess.run(["git", "apply", "--reverse", "--check", patch], cwd=source,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if check.returncode:
        subprocess.run(["git", "apply", "--check", patch], cwd=source, check=True)
        subprocess.run(["git", "apply", patch], cwd=source, check=True)
    # Keep the custom editor's settings beside the engine rather than in the user's profile.
    (source / "bin").mkdir(exist_ok=True)
    (source / "bin/_sc_").touch()
    return source


def prepare_scons(cache: Path) -> Path:
    environment = cache / "engine-build-env"
    python = environment / "Scripts/python.exe"
    if not python.exists():
        venv.EnvBuilder(with_pip=True).create(environment)
    installed = subprocess.run([str(python), "-c", "import importlib.metadata; print(importlib.metadata.version('scons'))"],
                               capture_output=True, text=True)
    if installed.returncode or installed.stdout.strip() != LOCK["scons"]:
        subprocess.run([str(python), "-m", "pip", "install", f"scons=={LOCK['scons']}"], check=True, timeout=300)
    return python


def compile_engine(source: Path, python: Path, toolchain: Path, jobs: int, log: Path) -> Path:
    env = dict(os.environ, BUILD_NAME=LOCK["build_name"], PYTHONIOENCODING="utf-8")
    env["PATH"] = str(toolchain) + os.pathsep + env["PATH"]
    command = [str(python), "-m", "SCons", *OPTIONS, f"-j{jobs}"]
    print(f"Compiling Godot; live log: {log}", flush=True)
    # SCons itself spawns compilers. Own those too if the build fails or is interrupted.
    job = WindowsJob()
    process = None
    try:
        with log.open("w", encoding="utf-8") as stream:
            process = subprocess.Popen(command, cwd=source, env=env, stdout=stream, stderr=subprocess.STDOUT,
                                       creationflags=0x0004 | 0x08000000)
            job.attach_and_resume(process.pid)
            if process.wait(timeout=7200):
                raise RuntimeError(f"Engine build failed; see {log}")
    finally:
        job.close()
        if process:
            process.wait(timeout=5)
    binary = source / "bin/godot.windows.editor.x86_64.llvm.exe"
    if not binary.is_file():
        raise RuntimeError(f"Missing engine output: {binary}")
    return binary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=min(6, os.cpu_count() or 1))
    parser.add_argument("--no-install", action="store_true", help="build and verify without changing the preferred local engine")
    args = parser.parse_args()
    if os.name != "nt" or sys.maxsize < 2**32:
        parser.error("This portable build recipe requires 64-bit Windows")
    if args.jobs < 1:
        parser.error("--jobs must be greater than zero")
    cache = ROOT / "tools/_dl"
    cache.mkdir(parents=True, exist_ok=True)
    output = ROOT / "audit-output"
    output.mkdir(exist_ok=True)
    try:
        toolchain = prepare_toolchain(cache)
        source = prepare_source(cache)
        python = prepare_scons(cache)
        binary = compile_engine(source, python, toolchain, args.jobs, output / "engine-build-llvm.log")
        package = output / "engine-package"
        package.mkdir(exist_ok=True)
        runtime = package / LOCK["output_binary"]
        shutil.copy2(binary, runtime)
        # Keep the original symbol-bearing executable for address-to-source diagnosis.
        subprocess.run([str(toolchain / "llvm-strip.exe"), "--strip-debug", str(runtime)], check=True, timeout=120)
        print("Verifying mesh, material and texture allocation on five concurrent threads...", flush=True)
        subprocess.run([sys.executable, str(ROOT / "tools/test_engine.py"), "--godot", str(runtime),
                        "--runs", "3", "--output", str(output / "engine-patched")], check=True, timeout=300)
        if args.no_install:
            print(f"Verified engine: {runtime}; full symbols: {binary}")
            return 0
        destination = ROOT / "tools/godot"
        destination.mkdir(parents=True, exist_ok=True)
        target = destination / LOCK["output_binary"]
        # A launcher must never see a partially copied executable.
        staged = target.with_suffix(".exe.part")
        shutil.copy2(runtime, staged)
        staged.replace(target)
        (destination / "_sc_").touch()
        shutil.copy2(source / "LICENSE.txt", destination / "LICENSE.regina-engine.txt")
        shutil.copy2(source / "COPYRIGHT.txt", destination / "COPYRIGHT.regina-engine.txt")
        manifest = {**LOCK, "binary_sha256": sha256(target),
                    "patch_sha256": sha256(PATCH_DIR / "dummy-rid-thread-safety.patch"), "build_options": OPTIONS,
                    "regression": "3 kinds x 3 runs passed",
                    "symbols_binary": binary.relative_to(ROOT).as_posix()}
        (destination / "regina-engine.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        print(f"Verified engine installed: {target}")
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"Engine build failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
