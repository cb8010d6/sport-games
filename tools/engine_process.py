"""Bounded, project-serialized Godot subprocesses, including Windows descendants."""
from __future__ import annotations

import math
import os
import signal
import subprocess
import sys
import time
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
def project_lock(command: list[str], *, cwd: str | Path | None = None):
    """Reject overlapping automated imports/tests before they touch the same cache."""
    if "--path" not in command:
        yield
        return
    project = Path(command[command.index("--path") + 1])
    if cwd is not None and not project.is_absolute():
        project = Path(cwd) / project
    project = project.resolve()
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
        self.members: list[tuple[int, int]] = []
        self.cleanup_deadline: float | None = None

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
        k.QueryInformationJobObject.argtypes = [W.HANDLE, C.c_int, C.c_void_p, W.DWORD, C.c_void_p]
        k.WaitForSingleObject.argtypes = [W.HANDLE, W.DWORD]
        k.WaitForSingleObject.restype = W.DWORD
        k.CloseHandle.argtypes = [W.HANDLE]
        k.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]
        k.OpenProcess.restype = W.HANDLE
        k.IsProcessInJob.argtypes = [W.HANDLE, W.HANDLE, C.POINTER(W.BOOL)]
        self.handle = k.CreateJobObjectW(None, None)
        if not self.handle:
            raise C.WinError(C.get_last_error())
        limits = ExtendedLimits()
        # KILL_ON_JOB_CLOSE | DIE_ON_UNHANDLED_EXCEPTION. Children inherit membership.
        limits.basic.flags = 0x2000 | 0x0400
        if not k.SetInformationJobObject(self.handle, 9, C.byref(limits), C.sizeof(limits)):
            error = C.WinError(C.get_last_error())
            try:
                self.close()
            except OSError as exc:
                error.add_note(f"Cannot close failed engine Job: {exc}")
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
        self.cleanup_deadline = time.monotonic() + 5
        failure = None
        try:
            self._capture_members(self.cleanup_deadline)
        except Exception as exc:
            failure = exc
        if not self.kernel.TerminateJobObject(self.handle, 1):
            error = self.C.WinError(self.C.get_last_error())
            if failure is None:
                raise error
            failure.add_note(f"Cannot terminate engine Job: {error}")
        if failure is not None:
            raise failure

    def _capture_members(self, deadline: float) -> None:
        """Retain waitable identities before termination removes PIDs from Job accounting."""
        C, W = self.C, self.W
        capacity = 32
        while True:
            class ProcessIds(C.Structure):
                _fields_ = [("assigned", W.DWORD), ("count", W.DWORD), ("pids", C.c_size_t * capacity)]

            ids = ProcessIds()
            ok = self.kernel.QueryInformationJobObject(self.handle, 3, C.byref(ids), C.sizeof(ids), None)
            if not ok and C.get_last_error() != 234:  # ERROR_MORE_DATA
                raise C.WinError(C.get_last_error())
            if ok and ids.count == ids.assigned:
                break
            if time.monotonic() >= deadline:
                raise TimeoutError("Engine Job process list did not stabilize within 5s")
            capacity = max(capacity * 2, ids.assigned)
        for pid in ids.pids[:ids.count]:
            if time.monotonic() >= deadline:
                raise TimeoutError("Engine Job process capture exceeded the cleanup deadline")
            # SYNCHRONIZE | QUERY_LIMITED_INFORMATION; never terminate by PID.
            handle = self.kernel.OpenProcess(0x101000, False, pid)
            if handle:
                member = W.BOOL()
                if not self.kernel.IsProcessInJob(handle, self.handle, C.byref(member)):
                    error = C.WinError(C.get_last_error())
                    if not self.kernel.CloseHandle(handle):
                        error.add_note(f"Cannot close process wait handle: {C.WinError(C.get_last_error())}")
                    raise error
                if member.value:
                    self.members.append((pid, handle))
                elif not self.kernel.CloseHandle(handle):
                    raise C.WinError(C.get_last_error())
            elif C.get_last_error() != 87:  # ERROR_INVALID_PARAMETER: process already gone.
                raise C.WinError(C.get_last_error())

    def wait_empty(self, timeout: float = 5) -> None:
        """Wait for captured member handles to signal and Job accounting to reach zero."""
        C, W = self.C, self.W

        class Accounting(C.Structure):
            # JOBOBJECT_BASIC_ACCOUNTING_INFORMATION, queried with information class 1.
            _fields_ = [("user_time", C.c_longlong), ("kernel_time", C.c_longlong),
                        ("period_user_time", C.c_longlong), ("period_kernel_time", C.c_longlong),
                        ("page_faults", W.DWORD), ("total_processes", W.DWORD),
                        ("active_processes", W.DWORD), ("terminated_processes", W.DWORD)]

        accounting = Accounting()
        deadline = time.monotonic() + timeout
        if self.cleanup_deadline is not None:
            deadline = min(deadline, self.cleanup_deadline)
        for pid, handle in self.members:
            milliseconds = max(0, math.ceil((deadline - time.monotonic()) * 1000))
            state = self.kernel.WaitForSingleObject(handle, milliseconds)
            if state == 258:  # WAIT_TIMEOUT
                raise TimeoutError(f"Engine process {pid} did not finish terminating within {timeout}s")
            if state != 0:
                raise C.WinError(C.get_last_error())
        while True:
            if not self.kernel.QueryInformationJobObject(self.handle, 1, C.byref(accounting), C.sizeof(accounting), None):
                raise C.WinError(C.get_last_error())
            if accounting.active_processes == 0:
                return
            if time.monotonic() >= deadline:
                raise TimeoutError(f"Engine Job still has {accounting.active_processes} active processes after {timeout}s")
            time.sleep(0.02)

    def close(self) -> None:
        error = None
        if self.handle:
            handle = self.handle
            self.handle = None
            if not self.kernel.CloseHandle(handle):
                error = self.C.WinError(self.C.get_last_error())
        members, self.members = self.members, []
        for _pid, handle in members:
            if not self.kernel.CloseHandle(handle) and error is None:
                error = self.C.WinError(self.C.get_last_error())
        if error is not None:
            raise error


def run_engine(command: list[str], env: dict[str, str], timeout: float, *,
               cwd: str | Path | None = None) -> subprocess.CompletedProcess:
    """Capture failures and stop all owned children on timeout, interruption or exit."""
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("Engine timeout must be finite and greater than zero")
    silence_native_crash_dialogs()
    with project_lock(command, cwd=cwd):
        return _run_owned(command, env, timeout, cwd=cwd)


def run_engines(commands: list[list[str]], env: dict[str, str], timeout: float) -> list[subprocess.CompletedProcess]:
    """Run instances of one project at the same time under a single project lock."""
    if not commands or not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("Engine commands must be non-empty and the timeout finite and greater than zero")
    from concurrent.futures import ThreadPoolExecutor
    silence_native_crash_dialogs()
    with project_lock(commands[0]), ThreadPoolExecutor(len(commands)) as pool:
        futures = [pool.submit(_run_owned, command, env, timeout) for command in commands]
        return [future.result() for future in futures]


def _run_owned(command: list[str], env: dict[str, str], timeout: float, *,
               cwd: str | Path | None = None) -> subprocess.CompletedProcess:
    job = WindowsJob() if os.name == "nt" else None
    process = None
    stdout = stderr = ""
    try:
        process = subprocess.Popen(command, env=env, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, encoding="utf-8", errors="replace",
                                   start_new_session=os.name != "nt",
                                   creationflags=0x0004 | 0x08000000 if job else 0)
        if job:
            # CREATE_SUSPENDED prevents the console wrapper spawning an unowned child.
            job.attach_and_resume(process.pid)
        stdout, stderr = process.communicate(timeout=timeout)
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    finally:
        failure = sys.exception()
        cleanup_errors = []
        try:
            if job:
                job.terminate()
                job.wait_empty()
            elif process:
                _kill_group(process.pid)
        except Exception as exc:
            cleanup_errors.append(exc)
        finally:
            try:
                if job:
                    try:
                        job.close()
                    except Exception as exc:
                        cleanup_errors.append(exc)
            finally:
                if process:
                    try:
                        if process.poll() is None:
                            process.kill()
                    except OSError as exc:
                        cleanup_errors.append(exc)
                    try:
                        # Drain pipes even after an attachment failure or KeyboardInterrupt.
                        stdout, stderr = process.communicate(timeout=5)
                        if isinstance(failure, subprocess.TimeoutExpired):
                            failure.output, failure.stderr = stdout, stderr
                    except Exception as exc:
                        if isinstance(exc, subprocess.TimeoutExpired):
                            if exc.stdout is not None:
                                stdout = exc.stdout
                            if exc.stderr is not None:
                                stderr = exc.stderr
                            if isinstance(failure, subprocess.TimeoutExpired):
                                failure.output, failure.stderr = stdout, stderr
                        cleanup_errors.append(exc)
        if cleanup_errors:
            details = "Engine tree cleanup could not be confirmed: " + "; ".join(str(exc) for exc in cleanup_errors)
            details += f"\nstdout:\n{stdout}\nstderr:\n{stderr}"
            if failure is not None:
                failure.add_note(details)
            else:
                cleanup_errors[0].add_note(details)
                raise cleanup_errors[0]
        elif isinstance(failure, subprocess.TimeoutExpired):
            failure.add_note("Captured engine Job members are signaled; Job active-process accounting is zero."
                             if job else "Sent SIGKILL to the engine process group; parent capture drained.")


def _kill_group(pid: int) -> None:
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
