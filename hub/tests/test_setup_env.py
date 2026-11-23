"""run_hub.bat / start.ps1 install from the hashed runtime lock, refresh when it changes and refuse old Pythons."""
import re
import tomllib
from pathlib import Path

from regina_hub import setup_env

HUB = Path(__file__).resolve().parents[1]


def pins(lock: Path) -> dict[str, str]:
    return dict(re.findall(r"^([a-z0-9][a-z0-9._-]*)==(\S+)", lock.read_text(encoding="utf-8"), re.MULTILINE))


def test_old_python_is_refused_and_untested_python_only_warned():
    code, message = setup_env.version_problem((3, 10))
    assert code == setup_env.UNUSABLE and "3.11" in message and "3.10" in message
    assert setup_env.version_problem((3, 11)) is None
    assert setup_env.version_problem((3, 12)) is None
    code, message = setup_env.version_problem((3, 14))
    assert code == setup_env.READY and "3.14" in message


def test_stamp_must_match_the_current_lock(tmp_path):
    lock = tmp_path / "requirements-runtime.txt"
    lock.write_text("aiohttp==1\n", encoding="utf-8")
    folder = tmp_path / ".venv"
    assert not setup_env.up_to_date(folder, lock)
    setup_env.venv_python(folder).parent.mkdir(parents=True)
    setup_env.venv_python(folder).write_bytes(b"")
    (folder / setup_env.STAMP_NAME).write_text(setup_env.lock_digest(lock) + "\n", encoding="utf-8")
    assert setup_env.up_to_date(folder, lock)
    lock.write_text("aiohttp==2\n", encoding="utf-8")  # a dependency update must trigger a reinstall
    assert not setup_env.up_to_date(folder, lock)


def test_check_reports_install_needed_without_installing(monkeypatch):
    monkeypatch.setattr(setup_env, "up_to_date", lambda: False)
    monkeypatch.setattr(setup_env, "install", lambda: (_ for _ in ()).throw(AssertionError("--check installed")))
    monkeypatch.setattr(setup_env.sys, "version_info", (3, 12, 0))
    assert setup_env.main(["--check"]) == setup_env.NEEDS_INSTALL


def test_old_python_stops_before_touching_the_venv(monkeypatch, capsys):
    monkeypatch.setattr(setup_env, "install", lambda: (_ for _ in ()).throw(AssertionError("installed on 3.10")))
    monkeypatch.setattr(setup_env.sys, "version_info", (3, 10, 4))
    assert setup_env.main([]) == setup_env.UNUSABLE
    assert "3.10" in capsys.readouterr().out


def test_failed_install_leaves_no_stamp(tmp_path, monkeypatch):
    lock = tmp_path / "requirements-runtime.txt"
    lock.write_text("", encoding="utf-8")
    folder = tmp_path / ".venv"
    setup_env.venv_python(folder).parent.mkdir(parents=True)
    setup_env.venv_python(folder).write_bytes(b"")
    monkeypatch.setattr(setup_env.subprocess, "run", lambda *a, **k: type("R", (), {"returncode": 1})())
    assert setup_env.install(folder, lock) == setup_env.UNUSABLE
    assert not (folder / setup_env.STAMP_NAME).exists()


def test_runtime_lock_has_no_dev_tools_and_matches_the_dev_lock():
    project = tomllib.loads((HUB / "pyproject.toml").read_text(encoding="utf-8"))["project"]
    runtime, dev = pins(HUB / "requirements-runtime.txt"), pins(HUB / "requirements-dev.txt")
    for requirement in project["dependencies"]:
        assert re.match(r"[a-z0-9_-]+", requirement).group(0) in runtime
    for tool in ("pytest", "pytest-asyncio", "ruff"):
        assert tool not in runtime
        assert tool not in pins(HUB / "requirements-windows.txt")
    # Players and developers run the same versions; only the dev extras differ.
    assert {name: version for name, version in dev.items() if name in runtime} == runtime
