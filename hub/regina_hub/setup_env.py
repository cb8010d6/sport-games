"""Create or refresh hub/.venv from the hashed runtime lock (run_hub.bat, tools/start.ps1).

Standard library only, and old-Python friendly syntax: it must be able to tell a Python 3.10 user what is wrong.
Run from the hub folder with the venv's python when it exists, otherwise the system python:
    python -m regina_hub.setup_env           install or refresh as needed
    python -m regina_hub.setup_env --check   0 = ready, 10 = install needed, 1 = unusable Python
"""
from __future__ import annotations

import hashlib
import os
import subprocess
import sys
import venv
from pathlib import Path

HUB = Path(__file__).resolve().parents[1]
VENV = HUB / ".venv"
LOCK = HUB / "requirements-runtime.txt"
STAMP_NAME = "requirements-runtime.sha256"
MINIMUM = (3, 11)
TESTED = ((3, 11), (3, 12))  # the CI matrix
READY, UNUSABLE, NEEDS_INSTALL = 0, 1, 10


def venv_python(folder: Path = VENV) -> Path:
    return folder / ("Scripts/python.exe" if os.name == "nt" else "bin/python")


def lock_digest(lock: Path = LOCK) -> str:
    return hashlib.sha256(lock.read_bytes()).hexdigest()


def version_problem(version: tuple[int, int]) -> tuple[int, str] | None:
    """(exit code, message) for a Python we refuse or have not tested; None when it is a CI-tested version."""
    shown = f"{version[0]}.{version[1]}"
    if version < MINIMUM:
        return UNUSABLE, (f"hub 需要 Python 3.11 或更新版本，当前是 {shown}。请安装 Python 3.11/3.12，"
                          f"删除 hub\\.venv 后重新启动。 (The hub needs Python 3.11+; found {shown}.)")
    if version not in TESTED:
        return READY, f"提示：Python {shown} 未经测试（CI 只测 3.11 和 3.12），如遇问题请换用 3.12。 (Untested Python {shown}.)"
    return None


def up_to_date(folder: Path = VENV, lock: Path = LOCK) -> bool:
    """The venv exists and was last installed from exactly this lock file."""
    stamp = folder / STAMP_NAME
    return venv_python(folder).is_file() and stamp.is_file() and stamp.read_text(encoding="utf-8").strip() == lock_digest(lock)


def install(folder: Path = VENV, lock: Path = LOCK) -> int:
    if not venv_python(folder).is_file():
        print(f"创建 Python 环境 {folder} ...", flush=True)
        venv.EnvBuilder(with_pip=True).create(folder)
    print(f"按 {lock.name} 安装依赖（带哈希校验）...", flush=True)
    result = subprocess.run([str(venv_python(folder)), "-m", "pip", "install", "--require-hashes", "-r", str(lock)])
    if result.returncode:
        print(f"安装依赖失败（pip 退出码 {result.returncode}），检查网络后重试。", flush=True)
        return UNUSABLE
    # Written only after a complete install, so an interrupted one is retried on the next start.
    (folder / STAMP_NAME).write_text(lock_digest(lock) + "\n", encoding="utf-8")
    return READY


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if hasattr(sys.stdout, "reconfigure"):  # a piped cp1252 stdout must not turn the message into a traceback
        sys.stdout.reconfigure(errors="replace")
    problem = version_problem(tuple(sys.version_info[:2]))
    if problem:
        print(problem[1], flush=True)
        if problem[0] != READY:
            return problem[0]
    if up_to_date():
        return READY
    if "--check" in args:
        return NEEDS_INSTALL
    return install()


if __name__ == "__main__":
    raise SystemExit(main())
