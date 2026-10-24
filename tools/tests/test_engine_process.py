"""Exercise real process ownership, native failure and contention without Godot."""
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent / "fixtures"))
import engine_process
from engine_process import project_lock, run_engine, run_engines
from process_tree import cleanup_tree, tree_command


class EngineProcessTests(unittest.TestCase):
    def test_exit_status_and_both_streams_are_preserved(self):
        result = run_engine([sys.executable, "-c", "import sys; print('out'); print('err', file=sys.stderr); sys.exit(7)"],
                            env=dict(os.environ), timeout=10)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout.strip(), "out")
        self.assertEqual(result.stderr.strip(), "err")

    def test_timeout_kills_child_after_wrapper_already_exited(self):
        # Native Windows descendants inherit Job ownership; Store Python's AppX activation
        # does not model Godot. Both descendants keep the exited wrapper's pipes open.
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            try:
                start = time.monotonic()
                with self.assertRaises(subprocess.TimeoutExpired) as caught:
                    run_engine(tree_command(directory), env=dict(os.environ), timeout=3)
                self.assertIn("WRAPPER", caught.exception.stdout)
                # Native hidden-console descendants retain the pipes, while Console.WriteLine
                # need not reach them. Their own PID records prove all three stages executed.
                for role in ("wrapper", "child", "grandchild"):
                    self.assertTrue((directory / f"{role}.pid").is_file(), f"Fixture did not start {role}")
                self.assertLess(time.monotonic() - start, 8)
                time.sleep(4)
                survivors = [role for role in ("child", "grandchild") if (directory / f"{role}.survived").exists()]
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
            result = run_engine([sys.executable, str(target),
                                 "EngineProcessTests.test_timeout_kills_child_after_wrapper_already_exited"],
                                env=dict(os.environ), timeout=30)
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
