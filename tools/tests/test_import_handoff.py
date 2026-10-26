import os
import subprocess
import tempfile
import unittest
from contextlib import chdir
from pathlib import Path
from unittest import mock

from tools import find_import_artifact as handoff


def merge_fixture(tmp_path: Path, *, extra: bool = False) -> str:
    def git(*args):
        return subprocess.check_output(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture", *args],
                                       cwd=tmp_path, stderr=subprocess.DEVNULL, text=True).strip()

    git("init", "-b", "main")
    (tmp_path / "game.txt").write_text("initial")
    git("add", ".")
    git("commit", "-m", "initial")
    git("switch", "-c", "dev")
    (tmp_path / "game.txt").write_text("validated")
    git("commit", "-am", "feature")
    source = git("rev-parse", "HEAD")
    git("switch", "main")
    git("merge", "--no-ff", "--no-commit", "dev")
    if extra:
        (tmp_path / "extra.txt").write_text("changed during merge")
        git("add", ".")
    git("commit", "-m", "merge")
    return source


class ImportHandoffTests(unittest.TestCase):
    def test_only_matching_trusted_unexpired_imports_are_selected(self):
        for fork, expired, expected in [(False, False, "42"), (True, False, ""), (False, True, "")]:
            with self.subTest(fork=fork, expired=expired), tempfile.TemporaryDirectory() as temp:
                source = merge_fixture(Path(temp))

                def api(endpoint, *, fork=fork, expired=expired, source=source):
                    if endpoint.endswith("/artifacts"):
                        self.assertFalse(fork)
                        return {"artifacts": [{"name": "Godot-imports", "expired": expired}]}
                    return {"workflow_runs": [{"id": 42, "head_sha": source, "head_branch": "dev",
                                              "event": "pull_request", "conclusion": "success",
                                              "head_repository": {"full_name": "example-fork/game-fixture"
                                                                  if fork else "example-owner/game-fixture"}}]}

                with chdir(temp), \
                     mock.patch.dict(os.environ, {"GITHUB_REF": "refs/heads/main",
                                                  "GITHUB_REPOSITORY": "example-owner/game-fixture"}), \
                     mock.patch.object(handoff, "gh_json", side_effect=api):
                    self.assertEqual(handoff.find_run(), expected)

    def test_merge_changes_require_normal_import(self):
        with tempfile.TemporaryDirectory() as temp:
            merge_fixture(Path(temp), extra=True)
            with chdir(temp), \
                 mock.patch.dict(os.environ, {"GITHUB_REF": "refs/heads/main",
                                              "GITHUB_REPOSITORY": "example-owner/game-fixture"}), \
                 mock.patch.object(handoff, "gh_json",
                                   side_effect=AssertionError("Changed merge trees must not reuse PR imports")):
                self.assertEqual(handoff.find_run(), "")


if __name__ == "__main__":
    unittest.main()
