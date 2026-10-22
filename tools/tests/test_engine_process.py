"""Exercise real process ownership, native failure and contention without Godot."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from engine_process import project_lock, run_engine


class EngineProcessTests(unittest.TestCase):
    def test_exit_status_and_both_streams_are_preserved(self):
        result = run_engine([sys.executable, "-c", "import sys; print('out'); print('err', file=sys.stderr); sys.exit(7)"],
                            env=dict(os.environ), timeout=10)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout.strip(), "out")
        self.assertEqual(result.stderr.strip(), "err")

    def test_timeout_kills_child_after_wrapper_already_exited(self):
        # The child keeps inherited pipes open after its parent exits. Killing the parent's
        # PID with taskkill /T no longer reaches it. A delayed marker detects survivors.
        with tempfile.TemporaryDirectory() as temp:
            marker = Path(temp) / "survived"
            child = "import pathlib,time; print('CHILD', flush=True); time.sleep(4); pathlib.Path(" + repr(str(marker)) + ").touch()"
            parent = "import subprocess,sys; subprocess.Popen([sys.executable, '-c', " + repr(child) + "]); print('WRAPPER', flush=True)"
            start = time.monotonic()
            with self.assertRaises(subprocess.TimeoutExpired) as caught:
                run_engine([sys.executable, "-c", parent], env=dict(os.environ), timeout=2)
            self.assertIn("CHILD", caught.exception.stdout)
            self.assertIn("WRAPPER", caught.exception.stdout)
            self.assertLess(time.monotonic() - start, 7)
            time.sleep(4)
            self.assertFalse(marker.exists(), "Orphaned engine child survived the timeout")

    def test_lock_rejects_second_process_then_releases(self):
        with tempfile.TemporaryDirectory() as temp:
            command = ["unused", "--path", temp]
            script = ("import sys; sys.path.insert(0, " + repr(str(Path(__file__).resolve().parents[1])) + "); "
                      "from engine_process import project_lock\nwith project_lock(" + repr(command) + "): print('LOCKED')")
            with project_lock(command):
                blocked = run_engine([sys.executable, "-c", script], env=dict(os.environ), timeout=10)
                self.assertNotEqual(blocked.returncode, 0)
                self.assertIn("Another automated Godot run", blocked.stderr)
            released = run_engine([sys.executable, "-c", script], env=dict(os.environ), timeout=10)
            self.assertEqual(released.returncode, 0, released.stderr)
            self.assertIn("LOCKED", released.stdout)

    @unittest.skipUnless(os.name == "nt", "Win32 native exception and Job Object")
    def test_unhandled_native_access_violation_returns_without_debugger(self):
        # Deliberately fault only the disposable fixture's native thread. ctypes would
        # catch an AV on its calling thread, so create a separate thread at address 0.
        script = """import ctypes
k = ctypes.WinDLL('kernel32')
k.CreateThread.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p]
k.CreateThread.restype = ctypes.c_void_p
print('NATIVE_FIXTURE', flush=True)
assert k.CreateThread(None, 0, None, None, 0, None)
k.Sleep(10000)
"""
        result = run_engine([sys.executable, "-c", script], env=dict(os.environ), timeout=5)
        self.assertEqual(result.returncode & 0xFFFFFFFF, 0xC0000005)
        self.assertIn("NATIVE_FIXTURE", result.stdout)


if __name__ == "__main__":
    unittest.main()
