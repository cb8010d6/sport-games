from pathlib import Path
import sys

from PyInstaller.utils.hooks import collect_submodules

root = Path(SPECPATH).resolve().parents[1]
sys.path.insert(0, str(root / "tools"))
from freeze_inventory import capture_bundle

a = Analysis([str(root / "tools/hub_entry.py")], pathex=[str(root / "hub")],
             datas=[(str(root / "hub/regina_hub/web"), "regina_hub/web")],
             hiddenimports=collect_submodules("bleak.backends.winrt") + collect_submodules("winrt"))
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name="sport-hub", console=True,
          debug=False, strip=False, upx=False)
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name="sport-hub")
capture_bundle("hub", root, pyz, exe, coll)
