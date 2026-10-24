"""Bounded, project-serialized Godot subprocesses, including Windows descendants."""
from __future__ import annotations

import math
import os
import signal
import subprocess
from contextlib import contextmanager
from pathlib import Path


def silence_native_crash_dialogs() -> None:
    """Change only this process's inherited error mode, preserving existing flags."""
    if os.name == "nt":
        import ctypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.GetErrorMode.restype = ctypes.c_uint
        kernel.SetErrorMode(kernel.GetErrorMode() | 0x0002 | 0x8000)


@contextmanager
def project_lock(command: list[str]):
    """Reject overlapping automated imports/tests before they touch the same cache."""
    if "--path" not in command:
        yield
        return
    project = Path(command[command.index("--path") + 1]).resolve()
    cache = project / ".godot"
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / "rs-runner.lock").open("a+b") as lock:
        lock.seek(0, os.SEEK_END)
        if lock.tell() == 0:
            lock.write(b"0")
            lock.flush()
        lock.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            raise OSError(f"Another automated Godot run is using {project}; wait for it to finish.") from exc
        try:
            yield
        finally:
            lock.seek(0)
            if os.name == "nt":
                msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


class WindowsJob:
    """Own the engine tree before its first instruction, without global OS changes."""

    def __init__(self):
        import ctypes as C
        from ctypes import wintypes as W
        self.C, self.W = C, W
        self.kernel = k = C.WinDLL("kernel32", use_last_error=True)

        class BasicLimits(C.Structure):
            _fields_ = [("process_time", C.c_longlong), ("job_time", C.c_longlong),
                        ("flags", W.DWORD), ("min_working_set", C.c_size_t),
                        ("max_working_set", C.c_size_t), ("active_processes", W.DWORD),
                        ("affinity", C.c_size_t), ("priority", W.DWORD), ("scheduling", W.DWORD)]

        class ExtendedLimits(C.Structure):
            _fields_ = [("basic", BasicLimits), ("io", C.c_ulonglong * 6),
                        ("process_memory", C.c_size_t), ("job_memory", C.c_size_t),
                        ("peak_process_memory", C.c_size_t), ("peak_job_memory", C.c_size_t)]

        k.CreateJobObjectW.argtypes = [C.c_void_p, W.LPCWSTR]
        k.CreateJobObjectW.restype = W.HANDLE
        k.SetInformationJobObject.argtypes = [W.HANDLE, C.c_int, C.c_void_p, W.DWORD]
        k.AssignProcessToJobObject.argtypes = [W.HANDLE, W.HANDLE]
        k.TerminateJobObject.argtypes = [W.HANDLE, W.UINT]
        k.CloseHandle.argtypes = [W.HANDLE]
        k.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]
        k.OpenProcess.restype = W.HANDLE
        self.handle = k.CreateJobObjectW(None, None)
        if not self.handle:
            raise C.WinError(C.get_last_error())
        limits = ExtendedLimits()
        # KILL_ON_JOB_CLOSE | DIE_ON_UNHANDLED_EXCEPTION. Children inherit membership.
        limits.basic.flags = 0x2000 | 0x0400
        if not k.SetInformationJobObject(self.handle, 9, C.byref(limits), C.sizeof(limits)):
            error = C.WinError(C.get_last_error())
            self.close()
            raise error

    def attach_and_resume(self, pid: int) -> None:
        C, W, k = self.C, self.W, self.kernel
        handle = k.OpenProcess(0x0101, False, pid)  # SET_QUOTA | TERMINATE
        if not handle:
            raise C.WinError(C.get_last_error())
        try:
            if not k.AssignProcessToJobObject(self.handle, handle):
                raise C.WinError(C.get_last_error())
        finally:
            k.CloseHandle(handle)

        class ThreadEntry(C.Structure):
            _fields_ = [("size", W.DWORD), ("usage", W.DWORD), ("tid", W.DWORD),
                        ("pid", W.DWORD), ("base_priority", W.LONG),
                        ("delta_priority", W.LONG), ("flags", W.DWORD)]

        k.CreateToolhelp32Snapshot.argtypes = [W.DWORD, W.DWORD]
        k.CreateToolhelp32Snapshot.restype = W.HANDLE
        k.Thread32First.argtypes = [W.HANDLE, C.POINTER(ThreadEntry)]
        k.Thread32Next.argtypes = [W.HANDLE, C.POINTER(ThreadEntry)]
        k.OpenThread.argtypes = [W.DWORD, W.BOOL, W.DWORD]
        k.OpenThread.restype = W.HANDLE
        k.ResumeThread.argtypes = [W.HANDLE]
        k.ResumeThread.restype = W.DWORD
        snapshot = k.CreateToolhelp32Snapshot(0x0004, 0)
        if snapshot == C.c_void_p(-1).value:
            raise C.WinError(C.get_last_error())
        try:
            entry = ThreadEntry()
            entry.size = C.sizeof(entry)
            valid = k.Thread32First(snapshot, C.byref(entry))
            while valid:
                if entry.pid == pid:
                    thread = k.OpenThread(0x0002, False, entry.tid)
                    if not thread:
                        raise C.WinError(C.get_last_error())
                    try:
                        if k.ResumeThread(thread) == 0xFFFFFFFF:
                            raise C.WinError(C.get_last_error())
                        return
                    finally:
                        k.CloseHandle(thread)
                valid = k.Thread32Next(snapshot, C.byref(entry))
            raise OSError(f"Cannot find suspended engine thread for PID {pid}")
        finally:
            k.CloseHandle(snapshot)

    def terminate(self) -> None:
        if not self.kernel.TerminateJobObject(self.handle, 1):
            raise self.C.WinError(self.C.get_last_error())

    def close(self) -> None:
        if self.handle:
            self.kernel.CloseHandle(self.handle)
            self.handle = None


def run_engine(command: list[str], env: dict[str, str], timeout: float) -> subprocess.CompletedProcess:
    """Capture failures and stop all owned children on timeout, interruption or exit."""
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("Engine timeout must be finite and greater than zero")
    silence_native_crash_dialogs()
    with project_lock(command):
        return _run_owned(command, env, timeout)


def run_engines(commands: list[list[str]], env: dict[str, str], timeout: float) -> list[subprocess.CompletedProcess]:
    """Run instances of one project at the same time under a single project lock."""
    if not commands or not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("Engine commands must be non-empty and the timeout finite and greater than zero")
    from concurrent.futures import ThreadPoolExecutor
    silence_native_crash_dialogs()
    with project_lock(commands[0]), ThreadPoolExecutor(len(commands)) as pool:
        futures = [pool.submit(_run_owned, command, env, timeout) for command in commands]
        return [future.result() for future in futures]


def _run_owned(command: list[str], env: dict[str, str], timeout: float) -> subprocess.CompletedProcess:
    job = WindowsJob() if os.name == "nt" else None
    process = None
    try:
        process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, encoding="utf-8", errors="replace",
                                   start_new_session=os.name != "nt",
                                   creationflags=0x0004 | 0x08000000 if job else 0)
        if job:
            # CREATE_SUSPENDED prevents the console wrapper spawning an unowned child.
            job.attach_and_resume(process.pid)
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            if job:
                job.terminate()
            else:
                _kill_group(process.pid)
            stdout, stderr = process.communicate(timeout=5)
            raise subprocess.TimeoutExpired(command, timeout, stdout, stderr) from exc
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    finally:
        if job:
            job.close()
        elif process:
            _kill_group(process.pid)
        if process:
            if process.poll() is None:
                process.kill()
            # Drain pipes even after an attachment failure or KeyboardInterrupt.
            process.communicate(timeout=5)


def _kill_group(pid: int) -> None:
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
