"""Build a portable Windows game + controller hub; never include runtime user data."""
from __future__ import annotations

import argparse
import importlib.metadata
import json
import os
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

from package_archive import FONT_LICENSES
from smoke_game import checked_run

ROOT = Path(__file__).resolve().parents[1]


def run(command: list[str], **options) -> None:
    print("Running", command[0], flush=True)
    subprocess.run(command, cwd=ROOT, check=True, **options)


def collect_notices(target: Path, version: str) -> None:
    target.mkdir(parents=True, exist_ok=True)
    for name in ["LICENSE.txt", "COPYRIGHT.txt"]:
        url = f"https://raw.githubusercontent.com/godotengine/godot/{version}-stable/{name}"
        with urllib.request.urlopen(url, timeout=60) as response:
            (target / ("Godot-" + name)).write_bytes(response.read())
    stdlib_license = Path(sys.base_prefix) / "LICENSE.txt"
    if stdlib_license.is_file():
        shutil.copy2(stdlib_license, target / "Python-LICENSE.txt")
    for distribution in importlib.metadata.distributions():
        package = distribution.metadata.get("Name", "unknown")
        for file in distribution.files or []:
            if "dist-info" not in str(file) or not any("license" in p.lower() or "copying" in p.lower() for p in file.parts):
                continue
            source = Path(distribution.locate_file(file))
            if source.is_file():
                dest = target / "python" / package / file.name
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, dest)


def main() -> None:
    if sys.platform != "win32":
        raise SystemExit("Windows packages must be built on Windows.")
    config = json.loads((ROOT / "tools/release_config.json").read_text())
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", type=Path, default=ROOT / "tools/godot" / f"Godot_v{config['godotVersion']}-stable_win64_console.exe")
    parser.add_argument("--game-input", type=Path, help="Checked Godot Windows export from the game job")
    args = parser.parse_args()
    out = ROOT / "dist" / config["packageName"]
    if out.exists():
        raise SystemExit("Build output already exists. Use a fresh checkout or choose a clean build workspace.")
    (out / "game").mkdir(parents=True)
    work = ROOT / "build/pyinstaller"
    shared = [sys.executable, "-m", "PyInstaller", "--noconfirm", "--noupx", "--clean", "--specpath", str(work), "--workpath", str(work / "cache")]
    run(shared + ["--onedir", "--name", "sport-hub", "--distpath", str(work / "output"),
                  "--paths", str(ROOT / "hub"), "--add-data", f"{ROOT / 'hub/regina_hub/web'}:regina_hub/web",
                  "--collect-submodules", "bleak.backends.winrt", "--collect-submodules", "winrt",
                  str(ROOT / "tools/hub_entry.py")])
    shutil.copytree(work / "output/sport-hub", out / "hub")
    shutil.copy2(ROOT / "hub/config.json", out / "hub/config.json")
    run(shared + ["--onefile", "--windowed", "--name", "SportGames", "--distpath", str(out),
                  str(ROOT / "tools/release_launcher.py")])
    if args.game_input:
        for name in ["SportGames.exe", "SportGames.pck"]:
            if not (args.game_input / name).is_file():
                raise SystemExit("Game artifact is incomplete: " + name)
        shutil.copytree(args.game_input, out / "game", dirs_exist_ok=True)
    else:
        checked_run([str(args.godot), "--headless", "--path", str(ROOT / "game"), "--editor", "--import"], timeout=2400)
        checked_run([str(args.godot), "--headless", "--path", str(ROOT / "game"), "--export-release", config["exportPreset"], str(out / "game/SportGames.exe")], timeout=1200)
    notices = out / "licenses"
    collect_notices(notices, config["godotVersion"])
    for name in ["LICENSE", "docs/THIRD_PARTY.md", "docs/ASSET_PROVENANCE.md", "game/assets/polyhaven/CREDITS.md"]:
        shutil.copy2(ROOT / name, notices / Path(name).name)
    # OFL 1.1 requires the full license text to travel with the bundled fonts; .txt never reaches the pck.
    for font_license in FONT_LICENSES:
        shutil.copy2(font_license, notices / font_license.name)
    shutil.copy2(ROOT / "game/assets/fonts/CREDITS.md", notices / "FONTS.md")
    (out / "README.txt").write_text(
        "Sport Games / 体感运动小游戏\n\n解压整个压缩包，双击 SportGames.exe。\n"
        "首次运行时请允许控制器中枢访问你信任的专用局域网。手机和电脑连接同一 Wi-Fi，在游戏大厅扫码。\n"
        "中枢证书和日志保存在当前用户的 SportGames 数据目录。中枢配置位于 hub/config.json。\n"
        "游戏设置保存在 Godot 的用户数据目录。发行包不含本机证书和日志。\n"
        "无需安装 Godot、Python、Node.js 或下载素材。\n\n"
        "Extract the entire archive, then run SportGames.exe. Use the same Wi-Fi for phone controllers.\n"
        "This initial prerelease has automated startup/network checks; controller hardware and GPU performance need real-device testing.\n",
        encoding="utf-8")
    info = {"godot": config["godotVersion"], "python": sys.version.split()[0], "commit": os.environ.get("GITHUB_SHA", "local-build"),
            "dependencies": {d.metadata["Name"]: d.version for d in importlib.metadata.distributions()}}
    (out / "BUILD_INFO.json").write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
    print("Portable package built:", out.name)


if __name__ == "__main__":
    main()
