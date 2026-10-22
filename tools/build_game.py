"""Cross-export the Windows Godot game on Linux; Windows CI tests the resulting EXE."""
import json
from pathlib import Path

from smoke_game import checked_run, smoke_game

ROOT = Path(__file__).resolve().parents[1]
config = json.loads((ROOT / "tools/release_config.json").read_text())
godot = ROOT / "tools/godot" / f"Godot_v{config['godotVersion']}-stable_linux.x86_64"
target = ROOT / "build/game"
target.mkdir(parents=True, exist_ok=True)
checked_run([str(godot), "--headless", "--path", str(ROOT / "game"), "--editor", "--import"], timeout=2400)
smoke_game(godot, ROOT / "game")
output = checked_run([str(godot), "--headless", "--path", str(ROOT / "game"), "--export-release",
                      config["exportPreset"], str(target / "SportGames.exe")], timeout=1200)
(ROOT / "build/game-export.log").write_text(output, encoding="utf-8")
for name in ["SportGames.exe", "SportGames.pck"]:
    if not (target / name).is_file():
        raise SystemExit("Godot export is incomplete: " + name)
print("Windows game exported; final EXE is tested in the Windows job.")
