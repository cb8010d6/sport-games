from pathlib import Path
import sys

root = Path(SPECPATH).resolve().parents[1]
sys.path.insert(0, str(root / "tools"))
from freeze_inventory import capture_bundle

a = Analysis([str(root / "tools/release_launcher.py")])
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, a.binaries, a.datas, [], name="SportGames", console=False,
          debug=False, strip=False, upx=False)
capture_bundle("launcher", root, pyz, exe)
