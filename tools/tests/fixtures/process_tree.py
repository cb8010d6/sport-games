"""Disposable wrapper/child/grandchild fixtures; Windows uses native PowerShell.

Only tests import this module. PID records scope emergency cleanup to this fixture;
Windows creation times guard against PID reuse. Every descendant also exits after 4s.
"""
from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from pathlib import Path

ROLES = ("wrapper", "child", "grandchild")


def tree_command(directory: Path) -> list[str]:
    if os.name == "nt":
        executable = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        if not executable.is_file():
            raise FileNotFoundError(f"Required native Windows fixture: {executable.name}")
        return [str(executable), "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                "-File", str(Path(__file__).with_suffix(".ps1")), "-Stage", "wrapper", "-Directory", str(directory)]
    return [sys.executable, "-u", str(Path(__file__)), "wrapper", str(directory)]


def cleanup_tree(directory: Path) -> None:
    """Reclaim only this fixture if a timeout assertion or its mutation fails."""
    if os.name == "nt":
        for role in reversed(ROLES):
            record = directory / f"{role}.pid"
            if record.is_file():
                pid, created = (int(value) for value in record.read_text(encoding="ascii").split())
                _stop_windows_process(pid, created)
    else:
        record = directory / "wrapper.pid"
        if record.is_file():
            try:
                os.killpg(int(record.read_text(encoding="ascii")), signal.SIGKILL)
            except ProcessLookupError:
                pass


def _stop_windows_process(pid: int, created: int) -> None:
    import ctypes as C
    from ctypes import wintypes as W

    kernel = C.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]
    kernel.OpenProcess.restype = W.HANDLE
    kernel.GetProcessTimes.argtypes = [W.HANDLE] + [C.POINTER(W.FILETIME)] * 4
    kernel.WaitForSingleObject.argtypes = [W.HANDLE, W.DWORD]
    kernel.TerminateProcess.argtypes = [W.HANDLE, W.UINT]
    kernel.CloseHandle.argtypes = [W.HANDLE]
    handle = kernel.OpenProcess(0x1000 | 0x100000 | 1, False, pid)  # QUERY_LIMITED | SYNCHRONIZE | TERMINATE
    if not handle:
        if C.get_last_error() == 87:  # Already exited.
            return
        raise C.WinError(C.get_last_error())
    try:
        times = [W.FILETIME() for _ in range(4)]
        if not kernel.GetProcessTimes(handle, *(C.byref(value) for value in times)):
            raise C.WinError(C.get_last_error())
        actual = (times[0].dwHighDateTime << 32) | times[0].dwLowDateTime
        if actual == created and kernel.WaitForSingleObject(handle, 0) == 258:
            if not kernel.TerminateProcess(handle, 1):
                raise C.WinError(C.get_last_error())
            if kernel.WaitForSingleObject(handle, 2000) != 0:
                raise TimeoutError("Disposable fixture did not terminate")
    finally:
        kernel.CloseHandle(handle)


def main(role: str, directory: Path) -> None:
    (directory / f"{role}.pid").write_text(str(os.getpid()), encoding="ascii")
    print(role.upper(), flush=True)
    if role != "grandchild":
        subprocess.Popen([sys.executable, "-u", str(Path(__file__)), ROLES[ROLES.index(role) + 1], str(directory)])
    if role != "wrapper":
        time.sleep(4)
        (directory / f"{role}.survived").touch()


if __name__ == "__main__":
    main(sys.argv[1], Path(sys.argv[2]))
