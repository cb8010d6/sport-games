# Development setup

## Repository boundary

The repository root is `regina-sports/`. Only this directory belongs in the GitHub repository.
The separate Regina hardware application, its dependencies, editor installations and backups
in the parent directory must not be imported into this repository.

## Game and hub

- Godot **4.7.2** standard build. Open `game/project.godot`, or run `godot --path game`.
- Python **3.11+**, plus the hashed dependencies in `hub/requirements-dev.txt`.
- Node.js **22.23.4+ or 24.22.1+** (the 2026-10-21 security releases; Node 20 is end-of-life) for restoring upstream assets: run `node tools/sync_assets.mjs` and
  `node tools/sync_assets.mjs --check` from the repository root before opening Godot.
  Generated assets are ordinary Git files; no Git LFS or npm packages are required.
  See [ASSETS.md](ASSETS.md) and [PUBLICATION_AUDIT.md](PUBLICATION_AUDIT.md).

From the repository root on Windows:

```powershell
python -m venv hub/.venv
hub/.venv/Scripts/python -m pip install --require-hashes -r hub/requirements-dev.txt
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
hub/.venv/Scripts/python -m ruff check --config hub/pyproject.toml hub tools
hub/.venv/Scripts/python -m pytest -q tools/tests
node tools/publication_audit.mjs --strict --write audit-output
```

Node.js is a setup/developer dependency, not a game/runtime dependency. The audit scans publishable
source and supported embedded metadata, reports relative filenames without secret values,
and creates ignored `audit-output/privacy-scan.json` and `asset-manifest.json`.
CI tests the downloader without contacting upstream hosts; it does not restore ignored raw assets.
Run `node --test tools/tests/asset_sync.test.mjs` to verify downloader behavior locally.

Game changes require a visual check and a complete affected round. Headless startup alone
does not verify rendering, controller feel or performance.

## Updating Python dependencies

`hub/pyproject.toml` owns the runtime and development minimum versions.
`hub/requirements.txt` mirrors those inputs for pip/Dependabot; keep both in sync.
`hub/requirements-windows.in` also pins the existing PyInstaller version from
`tools/release_config.json`. The generated locks include transitive dependencies,
platform/Python markers and distribution hashes. CI uses `--require-hashes` on both
Python 3.11 and 3.12; Windows packaging uses its own lock with the same hash enforcement.
The locks use `requirements-*.txt` names so Dependabot's pip updater discovers the
actual installed pins and hashes as well as the input requirements.

Install **uv 0.13.5** in a tooling environment, then run these commands from the repository root:

```powershell
python -m pip install uv==0.13.5
uv pip compile hub/pyproject.toml --extra dev --universal --python-version 3.11 --generate-hashes --no-header --output-file hub/requirements-dev.txt
uv pip compile hub/requirements-windows.in --universal --python-version 3.11 --generate-hashes --no-header --output-file hub/requirements-windows.txt
```

These commands reuse existing pins. Add `--upgrade` for an intentional full update or
`--upgrade-package <name>` for a targeted update. Review and commit both regenerated
locks, then test installation with `python -m pip install --require-hashes -r <lock>`.
Dependabot checks Actions and `/hub` weekly against `dev`, grouping each ecosystem's
updates into one PR. If a bot PR changes input requirements without updating a lock,
regenerate and commit the affected locks before merging; the bot PR still needs CI.

Ruff targets Python 3.11 and starts with `E`, `F`, `W`, `I`, `UP` and `B`.
The nominal line width is 120; `E501` is ignored to preserve existing long lines.
Pass `--config hub/pyproject.toml` when checking both `hub` and sibling `tools`.
This migration uses lint fixes only; it does not run `ruff format`.

## Actions upgrade notes

All six official Actions are pinned to full commit SHAs with version comments.
The [official release pages](https://github.com/actions/checkout/releases) were
checked on 2026-10-22; the intermediate major-release notes were reviewed too:

| Action | Previous | Pinned release | Compatibility notes |
|---|---|---|---|
| checkout | v4 | [v7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1) | v5 uses Node 24 (runner 2.327.1+); v6 moves persisted credentials under runner temp (container Git needs runner 2.329.0+); v7 uses ESM and blocks unsafe fork checkout in privileged `pull_request_target`/`workflow_run` events. Our workflows use ordinary push/PR events. |
| setup-python | v5 | [v7.1.0](https://github.com/actions/setup-python/releases/tag/v7.1.0) | v6 uses Node 24; v7 uses ESM and removes `pip-install`, which we do not use. |
| setup-node | v4 | [v7.1.0](https://github.com/actions/setup-node/releases/tag/v7.1.0) | v5 adds automatic package-manager caching and Node 24; v6 limits automatic caching to npm; v7 uses ESM and removes the dummy `NODE_AUTH_TOKEN`. We explicitly disable package-manager caching; our scripts have no npm dependencies. |
| cache | v4 | [v6.1.0](https://github.com/actions/cache/releases/tag/v6.1.0) | v5 uses Node 24; v6 uses ESM. The Godot cache path/key stay the same. |
| upload-artifact | v4 | [v7.0.2](https://github.com/actions/upload-artifact/releases/tag/v7.0.2) | v5 adds preliminary Node 24 support; v6 defaults to Node 24; v7 adds optional direct single-file uploads and ESM. We retain zipped multi-file artifacts, names, paths, overwrite and hidden-import inclusion. |
| download-artifact | v4 | [v8.0.2](https://github.com/actions/download-artifact/releases/tag/v8.0.2) | v5 extracts a single artifact ID directly into `path`; all our downloads already use names, whose paths are unchanged. v6 adds preliminary Node 24 support; v7 defaults to Node 24; v8 adds ESM/direct-download support and fails digest mismatches by default. We retain normal extraction and the default separate-directory behavior for multiple artifacts. |

The workflows use hosted runners supporting Node 24. Each Node setup requests `'24'`
with `check-latest: true` to receive the patched 24.22.1+ line. Source-check names
`hub (3.11)`, `hub (3.12)`, `privacy` and release jobs `game`, `windows` are unchanged.

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
