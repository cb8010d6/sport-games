"""Disposable ready-gated process trees; Windows uses native PowerShell, not AppX.

PID records scope emergency cleanup to this fixture. Creation times guard against
PID reuse on Windows and Linux. Descendants retain inherited pipes until release;
a 30s watchdog bounds leaks even if the test process itself dies.
"""
from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from pathlib import Path

ROLES = ("wrapper", "child", "grandchild")
WATCHDOG_SECONDS = 30


def tree_command(directory: Path, startup_delay: float = 0) -> list[str]:
    if os.name == "nt":
        executable = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        if not executable.is_file():
            raise FileNotFoundError(f"Required native Windows fixture: {executable.name}")
        return [str(executable), "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                "-File", str(Path(__file__).with_suffix(".ps1")), "-Stage", "wrapper", "-Directory", str(directory),
                "-StartupDelaySeconds", str(startup_delay), "-WatchdogSeconds", str(WATCHDOG_SECONDS)]
    return [sys.executable, "-u", str(Path(__file__)), "wrapper", str(directory), str(startup_delay)]


def tree_ready(directory: Path) -> bool:
    """Require all three initialized roles and an actually exited root process."""
    return (all((directory / f"{role}.ready").is_file() for role in ROLES)
            and not _role_alive(directory, "wrapper"))


def tree_survivors(directory: Path) -> list[str]:
    """Query recorded process identities, independent of stdout and survival sleeps."""
    return [role for role in ROLES[1:] if _role_alive(directory, role)]


def _role_alive(directory: Path, role: str) -> bool:
    pid, created = (int(value) for value in (directory / f"{role}.pid").read_text(encoding="ascii").split())
    if os.name == "nt":
        return _windows_process(pid, created)
    try:
        stat = Path(f"/proc/{pid}/stat")
        if stat.is_file():
            fields = stat.read_text().rsplit(")", 1)[1].split()
            return fields[0] != "Z" and int(fields[19]) == created
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except FileNotFoundError:
        return False


def cleanup_tree(directory: Path) -> None:
    """Reclaim only this fixture if a timeout assertion or its mutation fails."""
    if os.name == "nt":
        for role in reversed(ROLES):
            record = directory / f"{role}.pid"
            if record.is_file():
                pid, created = (int(value) for value in record.read_text(encoding="ascii").split())
                _windows_process(pid, created, terminate=True)
    else:
        record = directory / "wrapper.pid"
        if record.is_file():
            try:
                os.killpg(int(record.read_text(encoding="ascii").split()[0]), signal.SIGKILL)
            except ProcessLookupError:
                pass


def _windows_process(pid: int, created: int, *, terminate: bool = False) -> bool:
    import ctypes as C
    from ctypes import wintypes as W

    kernel = C.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]
    kernel.OpenProcess.restype = W.HANDLE
    kernel.GetProcessTimes.argtypes = [W.HANDLE] + [C.POINTER(W.FILETIME)] * 4
    kernel.WaitForSingleObject.argtypes = [W.HANDLE, W.DWORD]
    kernel.WaitForSingleObject.restype = W.DWORD
    kernel.TerminateProcess.argtypes = [W.HANDLE, W.UINT]
    kernel.CloseHandle.argtypes = [W.HANDLE]
    handle = kernel.OpenProcess(0x1000 | 0x100000 | (1 if terminate else 0), False, pid)
    if not handle:
        if C.get_last_error() == 87:  # Already exited.
            return False
        raise C.WinError(C.get_last_error())
    try:
        times = [W.FILETIME() for _ in range(4)]
        if not kernel.GetProcessTimes(handle, *(C.byref(value) for value in times)):
            raise C.WinError(C.get_last_error())
        actual = (times[0].dwHighDateTime << 32) | times[0].dwLowDateTime
        if actual != created:
            return False
        state = kernel.WaitForSingleObject(handle, 0)
        if state == 0:
            return False
        if state != 258:
            raise C.WinError(C.get_last_error())
        if terminate:
            if not kernel.TerminateProcess(handle, 1):
                error = C.WinError(C.get_last_error())
                if kernel.WaitForSingleObject(handle, 2000) != 0:
                    raise error
            if kernel.WaitForSingleObject(handle, 2000) != 0:
                raise TimeoutError("Disposable fixture did not terminate")
            return False
        return True
    finally:
        kernel.CloseHandle(handle)


def _wait_ready(directory: Path, role: str, deadline: float) -> None:
    while not (directory / f"{role}.ready").is_file():
        if time.monotonic() >= deadline:
            raise TimeoutError(f"Fixture watchdog expired waiting for {role}")
        time.sleep(0.02)


def main(role: str, directory: Path, startup_delay: float) -> None:
    deadline = time.monotonic() + WATCHDOG_SECONDS
    stat = Path("/proc/self/stat")
    created = int(stat.read_text().rsplit(")", 1)[1].split()[19]) if stat.is_file() else 0
    record = directory / f"{role}.pid"
    temporary = record.with_suffix(".tmp")
    temporary.write_text(f"{os.getpid()} {created}", encoding="ascii")
    temporary.replace(record)
    if role == "child":
        time.sleep(startup_delay)
    print(role.upper(), flush=True)
    if role != "grandchild":
        next_role = ROLES[ROLES.index(role) + 1]
        subprocess.Popen([sys.executable, "-u", str(Path(__file__)), next_role, str(directory), str(startup_delay)])
        _wait_ready(directory, next_role, deadline)
    (directory / f"{role}.ready").touch()
    if role != "wrapper":
        while not (directory / "release").is_file() and time.monotonic() < deadline:
            time.sleep(0.02)


if __name__ == "__main__":
    main(sys.argv[1], Path(sys.argv[2]), float(sys.argv[3]))
