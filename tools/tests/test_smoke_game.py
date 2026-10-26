"""Exercise smoke/build isolation with disposable real subprocesses, without Godot."""
import contextlib
import io
import json
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

from tools import smoke_game as smoke
from tools.engine_process import project_lock

sys.path.insert(0, str(Path(__file__).resolve().parent / "fixtures"))
from process_tree import cleanup_tree, tree_command, tree_ready, tree_survivors

USER_ROOTS = ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME")


class SmokeGameIsolationTests(unittest.TestCase):
    def test_user_roots_are_disposable_and_parent_environment_is_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            parent = Path(temp)
            values = {key: str(parent / key) for key in USER_ROOTS}
            for directory in values.values():
                Path(directory).mkdir()
                (Path(directory) / "settings.cfg").write_bytes(b"player settings")
            script = ("import json,os,pathlib\n"
                      f"keys={USER_ROOTS!r}\n"
                      "roots={key:os.environ[key] for key in keys}\n"
                      "assert all(pathlib.Path(value).is_dir() for value in roots.values())\n"
                      "assert all(not (pathlib.Path(value)/'settings.cfg').exists() for value in roots.values())\n"
                      "for value in roots.values(): (pathlib.Path(value)/'settings.cfg').write_bytes(b'test settings')\n"
                      "print(json.dumps(dict(roots=roots,cwd=os.getcwd(),test=os.environ['RS_TEST_MODE'],"
                      "keep=os.environ['RS_SMOKE_SENTINEL'])))")
            with mock.patch.dict(os.environ, {**values, "RS_TEST_MODE": "parent", "RS_SMOKE_SENTINEL": "keep me"}):
                before = dict(os.environ)
                output = smoke.checked_run([sys.executable, "-c", script])
                self.assertEqual(dict(os.environ), before)
            result = json.loads(output)
            self.assertEqual(Path(result["cwd"]), smoke.ROOT)
            self.assertEqual(result["test"], "1")
            self.assertEqual(result["keep"], "keep me")
            self.assertEqual(len(set(result["roots"].values())), len(USER_ROOTS))
            for key, directory in result["roots"].items():
                self.assertNotEqual(directory, values[key])
                self.assertFalse(Path(directory).exists(), "Successful check left its user directory behind")
                self.assertEqual((Path(values[key]) / "settings.cfg").read_bytes(), b"player settings")

    def test_failed_check_removes_user_data_after_process_exit(self):
        with tempfile.TemporaryDirectory() as temp:
            record = Path(temp) / "user-root.txt"
            script = ("import os,pathlib\n"
                      f"pathlib.Path({str(record)!r}).write_text(os.environ['APPDATA'])\n"
                      "print('ERROR: test failure')")
            with self.assertRaises(RuntimeError):
                smoke.checked_run([sys.executable, "-c", script])
            self.assertFalse(Path(record.read_text()).exists())

    def test_user_data_cleanup_failure_preserves_original_failure(self):
        leaked = []

        def fail_cleanup(directory):
            directory._finalizer.detach()
            leaked.append(Path(directory.name))
            raise PermissionError("fixture busy directory")

        scenarios = ((RuntimeError, None, "ERROR: original diagnostic"),
                     (subprocess.TimeoutExpired, subprocess.TimeoutExpired(["fixture"], 1, "timeout out", "timeout err"), ""),
                     (PermissionError, None, "success"))
        try:
            for expected, timeout, output in scenarios:
                with self.subTest(expected=expected), \
                     mock.patch.object(tempfile.TemporaryDirectory, "cleanup", fail_cleanup), \
                     contextlib.ExitStack() as stack:
                    if timeout is not None:
                        stack.enter_context(mock.patch.object(smoke, "run_engine", side_effect=timeout))
                    with self.assertRaises(expected) as caught:
                        smoke.checked_run([sys.executable, "-c", f"print({output!r})"])
                    if expected is not PermissionError:
                        self.assertIn("fixture busy directory", "\n".join(caught.exception.__notes__))
                    else:
                        self.assertIn("success", "\n".join(caught.exception.__notes__))
                    if timeout is not None:
                        self.assertIs(caught.exception, timeout)
                        self.assertEqual(timeout.stdout, "timeout out")
                        self.assertEqual(timeout.stderr, "timeout err")
                    elif expected is RuntimeError:
                        self.assertIn(output, str(caught.exception))
        finally:
            for directory in leaked:
                shutil.rmtree(directory)

    def test_export_sees_only_copied_current_templates_and_cannot_change_source(self):
        version = json.loads((smoke.ROOT / "tools/release_config.json").read_text())["godotVersion"] + ".stable"
        with tempfile.TemporaryDirectory() as temp:
            parent = Path(temp)
            data_key, folder = ("APPDATA", "Godot") if os.name == "nt" else ("XDG_DATA_HOME", "godot")
            godot = parent / folder
            templates = godot / "export_templates" / version
            templates.mkdir(parents=True)
            template = templates / "windows_release_x86_64.exe"
            template.write_bytes(b"installed template")
            historical = godot / "export_templates/old.stable/old.exe"
            historical.parent.mkdir()
            historical.write_bytes(b"old template")
            editor = godot / "editor_settings-4.tres"
            editor.write_bytes(b"private editor configuration")
            player = godot / "app_userdata/Regina Sports/settings.cfg"
            player.parent.mkdir(parents=True)
            player.write_bytes(b"private player configuration")
            script = ("import json,os,pathlib\n"
                      f"root=pathlib.Path(os.environ[{data_key!r}]); godot=root/{folder!r}\n"
                      f"templates=godot/'export_templates'/{version!r}; template=templates/'windows_release_x86_64.exe'\n"
                      "print(json.dumps(dict(root=str(root),template=template.read_text(),"
                      "versions=sorted(p.name for p in templates.parent.iterdir()),"
                      "editor=(godot/'editor_settings-4.tres').exists(),"
                      "player=(godot/'app_userdata/Regina Sports/settings.cfg').exists())))\n"
                      "template.write_bytes(b'changed disposable template')")
            with mock.patch.dict(os.environ, {data_key: str(parent)}):
                output = smoke.checked_run([sys.executable, "-c", script, "--export-release", "Windows Desktop", "unused.exe"])
                # Import is isolated too, but does not need an expensive template copy.
                imported = smoke.checked_run([sys.executable, "-c",
                                              f"import os,pathlib; print((pathlib.Path(os.environ[{data_key!r}])/{folder!r}/'export_templates').exists())",
                                              "--editor", "--import"])
            result = json.loads(output)
            self.assertEqual(result["template"], "installed template")
            self.assertEqual(result["versions"], [version])
            self.assertFalse(result["editor"])
            self.assertFalse(result["player"])
            self.assertFalse(Path(result["root"]).exists())
            self.assertEqual(imported.strip(), "False")
            self.assertEqual(template.read_bytes(), b"installed template")
            self.assertEqual(editor.read_bytes(), b"private editor configuration")
            self.assertEqual(player.read_bytes(), b"private player configuration")
            self.assertEqual(historical.read_bytes(), b"old template")

    def test_checked_run_uses_the_project_lock_and_releases_it(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            marker, release = directory / "ready", directory / "release"
            script = ("import pathlib,time\n"
                      f"pathlib.Path({str(marker)!r}).touch(); release=pathlib.Path({str(release)!r})\n"
                      "end=time.monotonic()+8\n"
                      "while not release.exists() and time.monotonic()<end: time.sleep(0.02)\n"
                      "print('DONE')")
            command = [sys.executable, "-c", script, "--path", temp]
            with ThreadPoolExecutor(max_workers=1) as pool:
                future = pool.submit(smoke.checked_run, command, timeout=10)
                try:
                    deadline = time.monotonic() + 5
                    while not marker.exists() and not future.done() and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertTrue(marker.exists(), "First smoke process did not start")
                    with self.assertRaisesRegex(OSError, "Another automated Godot run"):
                        smoke.checked_run(command)
                finally:
                    release.touch()
                self.assertEqual(future.result(timeout=10).strip(), "DONE")
            with project_lock(command):
                pass

    def test_timeout_stops_descendants_before_removing_their_user_data(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            record = directory / "user-root.txt"
            command = tree_command(directory)
            real_engine = smoke.run_engine

            def recording_engine(command, **kwargs):
                record.write_text(kwargs["env"]["APPDATA"])
                return real_engine(command, **kwargs)

            with ThreadPoolExecutor(max_workers=1) as pool, mock.patch.object(smoke, "run_engine", recording_engine):
                start = time.monotonic()
                future = pool.submit(smoke.checked_run, command, timeout=14)
                try:
                    while not tree_ready(directory) and not future.done() and time.monotonic() < start + 12:
                        time.sleep(0.02)
                    if future.done():
                        future.result()
                    self.assertTrue(tree_ready(directory), "Fixture did not become ready before the deadline")
                    self.assertEqual(tree_survivors(directory), ["child", "grandchild"])
                    with self.assertRaises(subprocess.TimeoutExpired) as caught:
                        future.result(timeout=16)
                    self.assertIn("WRAPPER", caught.exception.stdout)
                    self.assertEqual(caught.exception.stderr, "")
                    expected = "Captured engine Job members are signaled" if os.name == "nt" else "Sent SIGKILL"
                    self.assertIn(expected, "\n".join(caught.exception.__notes__))
                    self.assertEqual(tree_survivors(directory), [])
                    self.assertFalse(Path(record.read_text()).exists(), "Timeout returned before temporary data cleanup")
                finally:
                    cleanup_tree(directory)

    def test_smoke_calls_explicitly_allow_only_the_forced_startup_diagnostic(self):
        def completed(command, **_kwargs):
            game = next((arg.split("=", 1)[1] for arg in command if arg.startswith("--game=")), "menu")
            return "CLI game: " + game

        with mock.patch.object(smoke, "checked_run", side_effect=completed) as checked, \
             contextlib.redirect_stdout(io.StringIO()):
            smoke.smoke_game(Path(sys.executable))
        self.assertTrue(checked.call_args_list)
        for call in checked.call_args_list:
            self.assertIn("--quit-after", call.args[0])
            self.assertTrue(call.kwargs["allow_shutdown_resources"])


if __name__ == "__main__":
    unittest.main()
