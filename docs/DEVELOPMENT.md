# Development setup

## Repository boundary

The repository root is `regina-sports/`. Only this directory belongs in the GitHub repository.
The separate Regina hardware application, its dependencies, editor installations and backups
in the parent directory must not be imported into this repository.

## Game and hub

- Godot **4.7.2** standard build. Open `game/project.godot`, or run `godot --path game`.
- Python **3.11+**, plus dependencies from `hub/requirements.txt`.
- Node.js **22.23.4+ or 24.22.1+** (the 2026-10-21 security releases; Node 20 is end-of-life) for restoring upstream assets: run `node tools/sync_assets.mjs` and
  `node tools/sync_assets.mjs --check` from the repository root before opening Godot.
  Generated assets are ordinary Git files; no Git LFS or npm packages are required.
  See [ASSETS.md](ASSETS.md) and [PUBLICATION_AUDIT.md](PUBLICATION_AUDIT.md).

From the repository root on Windows:

```powershell
python -m venv hub/.venv
hub/.venv/Scripts/python -m pip install -r hub/requirements.txt
```

Then enter `hub`, so Python can locate the source package:

```powershell
Set-Location hub
.venv/Scripts/python -m regina_hub --no-ble
```

Use `--no-ble` for phone/simulator-only development. Set `REGINA_GODOT` to your Godot
executable, add `godot` to PATH, or put the executable in ignored `tools/godot/`;
then `start.bat` launches both processes. The launcher also recognises the optional legacy
sibling engine installation, but that installation is not part of this repository.

Phone controllers load the local HTTPS page and stream through WSS. Certificates are
generated locally and must not be committed. Keep personal device allowlists or network
overrides in ignored `hub/config.local.json`, passed through `--config config.local.json`.

## Checks

```powershell
Set-Location hub
.venv/Scripts/python -m pytest -q
```

From the repository root:

```powershell
python tools/check_conventions.py
python tools/i18n_check.py
node tools/publication_audit.mjs --strict --write audit-output
```

Node.js is a setup/developer dependency, not a game/runtime dependency. The audit scans publishable
source and supported embedded metadata, reports relative filenames without secret values,
and creates ignored `audit-output/privacy-scan.json` and `asset-manifest.json`.
CI tests the downloader without contacting upstream hosts; it does not restore ignored raw assets.
Run `node --test tools/tests/asset_sync.test.mjs` to verify downloader behavior locally.

Game changes require a visual check and a complete affected round. Headless startup alone
does not verify rendering, controller feel or performance.

## Optional firmware

Building/using the game with phones does not require the firmware toolchain.
For Regina firmware, install ESP-IDF 5.1.x for ESP32-C6 and set `IDF_PATH`; optionally set
`IDF_TOOLS_PATH`. Do not commit local `sdkconfig` or tool environments.

The firmware also needs separately obtained M5GFX and M5Unified components. Preserve their
upstream licenses. These are external dependencies, not code copied from the parent project:

- M5GFX: <https://github.com/Forairaaaaa/M5GFX>, `regina-bk` branch used by the existing build.
- M5Unified: <https://github.com/m5stack/M5Unified>, version `0.1.14` used by the existing build.

Place them in ignored `third_party/M5GFX` and `third_party/M5Unified`, or set
`REGINA_M5GFX_DIR` and `REGINA_M5UNIFIED_DIR` to their component roots. The original sibling
driver locations remain a local compatibility fallback. Reproducible release builds should
record exact dependency commits after validating the toolchain.

```powershell
firmware/build.ps1                  # build
firmware/build.ps1 -Port COM5        # example port: build and flash
```

## Optional art tools

`tools/blender/` contains project export/processing scripts. Blender, MPFB, original source
downloads and private Blender settings are not distributed here. Use the official CC0
MakeHuman system assets when regenerating the supplied characters; third-party add-on asset
packs may have different licenses. See [THIRD_PARTY.md](THIRD_PARTY.md).

## Initial GitHub publication

After the reviewed files are committed on `main`, Windows maintainers can run
`powershell -NoProfile -File tools/publish_github.ps1` from a terminal with GitHub network access.
The script checks privacy and asset integrity, offers normal GitHub CLI web sign-in if needed,
creates the public `sport-games` repository under the authenticated account, pushes and verifies
the commit. It does not overwrite an existing repository's unrelated history or change global Git settings.
