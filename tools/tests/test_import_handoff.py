from pathlib import Path
import subprocess

import pytest

from tools import find_import_artifact as handoff


def merge_fixture(tmp_path, monkeypatch, *, extra=False):
    monkeypatch.chdir(tmp_path)
    def git(*args):
        return subprocess.check_output(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture", *args], stderr=subprocess.DEVNULL, text=True).strip()
    git("init", "-b", "main")
    Path("game.txt").write_text("initial")
    git("add", ".")
    git("commit", "-m", "initial")
    git("switch", "-c", "dev")
    Path("game.txt").write_text("validated")
    git("commit", "-am", "feature")
    source = git("rev-parse", "HEAD")
    git("switch", "main")
    git("merge", "--no-ff", "--no-commit", "dev")
    if extra:
        Path("extra.txt").write_text("changed during merge")
        git("add", ".")
    git("commit", "-m", "merge")
    monkeypatch.setenv("GITHUB_REF", "refs/heads/main")
    monkeypatch.setenv("GITHUB_REPOSITORY", "example-owner/game-fixture")
    return source


@pytest.mark.parametrize("fork,expired,expected", [(False, False, "42"), (True, False, ""), (False, True, "")])
def test_only_matching_trusted_unexpired_imports_are_selected(tmp_path, monkeypatch, fork, expired, expected):
    source = merge_fixture(tmp_path, monkeypatch)
    def api(endpoint):
        if endpoint.endswith("/artifacts"):
            assert not fork
            return {"artifacts": [{"name": "Godot-imports", "expired": expired}]}
        return {"workflow_runs": [{"id": 42, "head_sha": source, "head_branch": "dev", "event": "pull_request", "conclusion": "success",
                                  "head_repository": {"full_name": "example-fork/game-fixture" if fork else "example-owner/game-fixture"}}]}
    monkeypatch.setattr(handoff, "gh_json", api)
    assert handoff.find_run() == expected


def test_merge_changes_require_normal_import(tmp_path, monkeypatch):
    merge_fixture(tmp_path, monkeypatch, extra=True)
    def api(_):
        raise AssertionError("Changed merge trees must not reuse PR imports")
    monkeypatch.setattr(handoff, "gh_json", api)
    assert handoff.find_run() == ""
