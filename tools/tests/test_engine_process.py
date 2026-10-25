"""Exercise real process ownership, native failure and contention without Godot."""
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent / "fixtures"))
import engine_process
from engine_process import project_lock, run_engine, run_engines
from process_tree import cleanup_tree, tree_command, tree_ready, tree_survivors

STARTUP_TIMEOUT = 12
ORPHAN_TIMEOUT = 2
TREE_TIMEOUT = STARTUP_TIMEOUT + ORPHAN_TIMEOUT


class EngineProcessTests(unittest.TestCase):
    def test_exit_status_and_both_streams_are_preserved(self):
        result = run_engine([sys.executable, "-c", "import sys; print('out'); print('err', file=sys.stderr); sys.exit(7)"],
                            env=dict(os.environ), timeout=10)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout.strip(), "out")
        self.assertEqual(result.stderr.strip(), "err")

    def test_explicit_cwd_and_relative_project_lock_use_the_same_directory(self):
        parent_cwd = Path.cwd()
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            script = "import pathlib; print(pathlib.Path.cwd()); print(pathlib.Path('project/.godot/rs-runner.lock').is_file())"
            command = [sys.executable, "-c", script, "--path", "project"]
            result = run_engine(command, env=dict(os.environ), timeout=10, cwd=directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), [str(directory), "True"])
            self.assertEqual(Path.cwd(), parent_cwd)
            with project_lock(command, cwd=directory), self.assertRaisesRegex(OSError, "Another automated Godot run"):
                run_engine(command, env=dict(os.environ), timeout=10, cwd=directory)

    def test_normal_exit_stops_descendants_before_their_directory_is_removed(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp) / "owned"
            directory.mkdir()
            command = tree_command(directory)
            with ThreadPoolExecutor(max_workers=1) as pool:
                future = pool.submit(run_engine, command, env=dict(os.environ), timeout=TREE_TIMEOUT)
                try:
                    deadline = time.monotonic() + STARTUP_TIMEOUT
                    while not tree_ready(directory) and not future.done() and time.monotonic() < deadline:
                        time.sleep(0.02)
                    if future.done():
                        future.result()
                    self.assertTrue(tree_ready(directory))
                    self.assertEqual(tree_survivors(directory), ["child", "grandchild"])
                    # Native descendants retain the wrapper's pipes until released.
                    (directory / "release").touch()
                    result = future.result(timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("WRAPPER", result.stdout)
                    self.assertEqual(tree_survivors(directory), [], "Normal return left owned descendants alive")
                    shutil.rmtree(directory)
                    self.assertFalse(directory.exists())
                finally:
                    if directory.exists():
                        cleanup_tree(directory)

    @unittest.skipUnless(os.name == "nt", "Win32 Job accounting failure")
    def test_cleanup_failure_rejects_success_with_complete_streams(self):
        wait_empty = engine_process.WindowsJob.wait_empty

        def failed_wait(job):
            wait_empty(job)
            raise OSError("fixture accounting failure")

        with mock.patch.object(engine_process.WindowsJob, "wait_empty", failed_wait), \
             self.assertRaisesRegex(OSError, "fixture accounting failure") as caught:
            run_engine([sys.executable, "-c", "import sys; print('out'); print('err', file=sys.stderr)"],
                       env=dict(os.environ), timeout=10)
        notes = "\n".join(caught.exception.__notes__)
        self.assertIn("stdout:\nout", notes)
        self.assertIn("stderr:\nerr", notes)

    @unittest.skipUnless(os.name == "nt", "Win32 Job accounting failure")
    def test_cleanup_failure_preserves_original_timeout_and_streams(self):
        wait_empty = engine_process.WindowsJob.wait_empty

        def bounded_wait(job):
            wait_empty(job, timeout=0.1)

        started = time.monotonic()
        # A real native process remains alive until close; the accounting wait must
        # fail within its deadline while retaining the original process timeout.
        with mock.patch.object(engine_process.WindowsJob, "terminate", return_value=None), \
             mock.patch.object(engine_process.WindowsJob, "wait_empty", bounded_wait), \
             self.assertRaises(subprocess.TimeoutExpired) as caught:
            command = [tree_command(Path.cwd())[0], "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
                       "[Console]::WriteLine('out'); [Console]::Error.WriteLine('err'); Start-Sleep -Seconds 10"]
            run_engine(command,
                       env=dict(os.environ), timeout=2)
        self.assertEqual(caught.exception.timeout, 2)
        self.assertIn("out", caught.exception.stdout)
        self.assertIn("err", caught.exception.stderr)
        self.assertIn("active processes after 0.1s", "\n".join(caught.exception.__notes__))
        self.assertLess(time.monotonic() - started, 4)

    def test_timeout_kills_child_after_wrapper_already_exited(self):
        self._assert_timeout_kills_tree(startup_delay=0)

    def test_timeout_kills_child_after_slow_startup(self):
        # The old fixed 3s timeout raced real native child initialization on cold CI.
        self._assert_timeout_kills_tree(startup_delay=4)

    def _assert_timeout_kills_tree(self, startup_delay: float) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            with ThreadPoolExecutor(max_workers=1) as pool:
                start = time.monotonic()
                future = pool.submit(run_engine, tree_command(directory, startup_delay=startup_delay),
                                     env=dict(os.environ), timeout=TREE_TIMEOUT)
                try:
                    # Readiness must precede the overall deadline by at least ORPHAN_TIMEOUT.
                    # Descendants keep their pipes open until released (30s watchdog).
                    while not tree_ready(directory) and time.monotonic() < start + STARTUP_TIMEOUT:
                        if future.done():
                            future.result()  # Preserve a real launch failure instead of hiding it as readiness.
                            self.fail("Fixture exited before all descendants were ready")
                        time.sleep(0.02)
                    self.assertTrue(tree_ready(directory), "Fixture startup deadline exceeded before wrapper exit")
                    self.assertLess(time.monotonic() - start, STARTUP_TIMEOUT, "Fixture startup deadline exceeded")
                    self.assertEqual(tree_survivors(directory), ["child", "grandchild"], "Ready descendants exited early")
                    # Observe real exit by the original timeout plus a 2s Job termination grace.
                    # A mutant retains both descendants; release its pipes before the runner's
                    # secondary 5s drain expires, then assert the recorded ownership failure.
                    exit_deadline = start + TREE_TIMEOUT + 2
                    while time.monotonic() < exit_deadline:
                        if future.done() and not tree_survivors(directory):
                            break
                        time.sleep(0.02)
                    survivors = tree_survivors(directory)
                    (directory / "release").touch()
                    with self.assertRaises(subprocess.TimeoutExpired) as caught:
                        future.result(timeout=5)
                    self.assertEqual(caught.exception.timeout, TREE_TIMEOUT)
                    self.assertIn("WRAPPER", caught.exception.stdout)
                    self.assertLess(time.monotonic() - start, TREE_TIMEOUT + 5)
                    self.assertEqual(survivors, [], "Orphaned engine descendants survived the timeout")
                finally:
                    cleanup_tree(directory)

    def test_timeout_assertions_reject_unowned_descendants(self):
        # Run the same real assertion against a private mutant. Nothing in the checkout's
        # production module is changed, and no fake runner/result substitutes for execution.
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            source = Path(engine_process.__file__).read_text(encoding="utf-8")
            before, after = (("k.AssignProcessToJobObject(self.handle, handle)", "True") if os.name == "nt"
                             else ("os.killpg(pid, signal.SIGKILL)", "None"))
            self.assertEqual(source.count(before), 1, "ownership mutation must hit exactly one real syscall")
            (directory / "engine_process.py").write_text(source.replace(before, after), encoding="utf-8")
            tests = directory / "tests"
            fixtures = tests / "fixtures"
            fixtures.mkdir(parents=True)
            target = tests / Path(__file__).name
            shutil.copyfile(__file__, target)
            for name in ("process_tree.py", "process_tree.ps1"):
                shutil.copyfile(Path(__file__).parent / "fixtures" / name, fixtures / name)
            for method in ("test_timeout_kills_child_after_wrapper_already_exited",
                           "test_timeout_kills_child_after_slow_startup"):
                with self.subTest(method=method):
                    result = run_engine([sys.executable, str(target), f"EngineProcessTests.{method}"],
                                        env=dict(os.environ), timeout=40)
                    self.assertNotEqual(result.returncode, 0, "missing ownership must fail the actual timeout assertion")
                    self.assertIn("Orphaned engine descendants survived the timeout", result.stderr)
                    self.assertIn("['child', 'grandchild']", result.stderr)

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

    def test_parallel_instances_share_one_project_lock(self):
        # Each instance waits for the other's marker, so a serial runner would time out.
        script = ("import pathlib,sys,time\nd=pathlib.Path(sys.argv[1]); (d/sys.argv[2]).touch(); end=time.monotonic()+8\n"
                  "while not (d/sys.argv[3]).exists() and time.monotonic()<end: time.sleep(0.05)\n"
                  "print('MET' if (d/sys.argv[3]).exists() else 'ALONE')")
        with tempfile.TemporaryDirectory() as temp:
            # The trailing --path names the project the lock guards; the script ignores it.
            commands = [[sys.executable, "-c", script, temp, mine, other, "--path", temp]
                        for mine, other in (("a", "b"), ("b", "a"))]
            results = run_engines(commands, env=dict(os.environ), timeout=10)
            self.assertEqual([r.stdout.strip() for r in results], ["MET", "MET"])
            with project_lock(commands[0]):
                pass  # released after the batch

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
