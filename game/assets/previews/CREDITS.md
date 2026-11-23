# Sport preview images

Captured for this project by Codex using the retained `tools/capture_previews.py`
and `game/tests/capture_preview.gd` workflow, 2026-10-22.

The six JPEG files are direct 1600×900 exports of the sports' actual player-camera
3D viewports, on map 1 with a demo player and medium graphics settings. HUD controls
are outside those viewports and are not included. No external picture, AI image
generation, photo editing, real player data or reference artwork was used.
`manifest.json` identifies each output and its SHA-256. Captures use isolated
default profiles; camera timing is retained in the generation harness.

Images contain this project's MIT original geometry/material work and existing
CC0 Poly Haven / MakeHuman/MPFB inputs. Original AI assets retain the separately
recorded maintainer declaration. They do not acquire a new third-party source
classification merely because they appear in a rendered image.

Known input notices are retained in `docs/THIRD_PARTY.md`, `docs/ASSET_PROVENANCE.md`,
and the corresponding asset credits. Distribution retains **MIT AND CC0-1.0**
source notices. This record is provenance for the rendering workflow, not an
independent clearance of rights beyond those already documented for the project.

Regenerate after importing full assets with a graphics-capable engine:
`python tools/capture_previews.py`. The menu uses these static images rather than
instantiating six additional sport worlds at runtime. Different graphics drivers
may render small pixel differences; captures are reviewed visually, not compared
as deterministic golden images.
