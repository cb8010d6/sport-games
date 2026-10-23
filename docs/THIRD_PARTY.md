# Third-party sources and rights review

This file separates the project's code license from third-party asset licenses. The MIT
license at the repository root applies to original Regina Sports code and the maintainer-declared
AI original assets listed in [ASSET_PROVENANCE.md](ASSET_PROVENANCE.md);
it does not relicense models, photos, audio, upstream software, trademarks or other people's
work. No files from the parent Regina application are included as project source.

Review date: 2026-10-21. The 39 formerly unresolved outputs are now classified using the project
provider's explicit AI originality declaration. This is distinguished from independently documented
third-party sources. See [PUBLICATION_AUDIT.md](PUBLICATION_AUDIT.md) and `tools/asset_policy.json`.

## Procedural background music

The separately documented [background music](../game/assets/music/CREDITS.md) is a new
procedural contribution released as CC0-1.0, generated from the retained project score
without external samples. It does not inherit the historical SFX source classification.

## Poly Haven

Location: `game/assets/polyhaven/`.

The local [asset credits](../game/assets/polyhaven/CREDITS.md) record asset IDs, authors and
canonical source URLs. The official license page permits using, modifying and redistributing
their HDRIs, textures and 3D models under CC0:

- <https://polyhaven.com/license>
- <https://creativecommons.org/publicdomain/zero/1.0/>

The CC0 declaration does not itself resolve separate trademarks, artwork depicted in a
photograph, privacy or likeness rights. The current decals are classified separately according
to the maintainer declaration; a historical extraction tool is not treated as proof of their input.

## MakeHuman characters

Location: `game/assets/characters/`; regeneration scripts: `tools/blender/make_*.py`.

The character scripts use MakeHuman's base mesh and system skins, clothes, hair, eyes, brows,
and lashes through MPFB. The locally retained official system-asset archive contains explicit
CC0 notices in the `.mhclo` and `.mhmat` files. Samples inspected include casual suits,
shoes, hair and eyebrows actually referenced by the character scripts. The scripts modify
body proportions, recolor/trim clothes and export rigged characters; those changes do not
turn the MPFB application itself into bundled project code.

The system-asset notices identify the historical copyright holders as Data Collection AB,
Joel Palmius and Jonas Hauquier. Their notices are acknowledged here rather than replaced by
the project copyright. The MPFB add-on and source archive are excluded from the Git repository;
the project's generation scripts and generated characters are included.

- <https://static.makehumancommunity.org/mpfb/faq/use_in_closed_source.html>
- <https://static.makehumancommunity.org/assets/assetpacks/makehuman_system_assets.html>

This finding applies to the documented system assets, not arbitrary community-contributed
packs. The software/add-on license and exported core-asset license are distinct.

## Tree impostors

Location: `game/assets/golf/trees/`; processor: `tools/blender/bake_impostor.py`.

The retained download credits identify these Poly Haven sources:

- Jacaranda Tree, Rob Tuytel and Rico Cilliers: <https://polyhaven.com/a/jacaranda_tree>
- Island Tree 01/02, Rob Tuytel and Rico Cilliers:
  <https://polyhaven.com/a/island_tree_01>, <https://polyhaven.com/a/island_tree_02>
- Fir Sapling Medium, Rob Tuytel and Rico Cilliers:
  <https://polyhaven.com/a/fir_sapling_medium>

The bake script generates albedo/normal atlases and geometric bounds. The final atlas names
should be tied to the corresponding bake command/source model in any future regeneration PR.

## Audio - maintainer-declared AI originals

Location: `game/assets/sfx/*.wav`; processor: `tools/blender/audio_tool.py`.

The project provider explicitly confirmed that the current 35 final WAVs are AI originals.
They are distributed under the project MIT license on that declared basis; the declaration
and unarchived generation records are documented in [ASSET_PROVENANCE.md](ASSET_PROVENANCE.md).

Historical documentation and ignored downloads referred to BigSoundBank and Kenney, but no
complete final-file mapping had been established. Those earlier source leads remain recorded
below for traceability; they are not asserted as verified inputs to the current outputs.

- <https://bigsoundbank.com/licenses.html>
- <https://kenney.nl/assets/interface-sounds>
- <https://kenney.nl/assets/impact-sounds>

If future records establish that a final WAV incorporates a recording, update its entry with
the actual source ID, author, license and processing parameters. Project-generated synthesis in
`core/sfx.gd` is a separate audio source.

## Controller model - maintainer-declared AI original

File: `game/assets/models/regina.glb`.

The project provider confirmed this model is an AI original; it is included under project MIT
on that declared basis. An older comment linked it to the separate Phalange demo
(<https://github.com/Forairaaaaa/Phalange>). That earlier source lead is preserved in the
provenance record rather than being asserted as the verified origin. No license from the
parent Regina project is copied or assumed to cover the model.

## Decals and optional desktop icon

- `game/assets/decals/graffiti_*.png`: project provider confirmed these three outputs are AI
  originals, supplied under project MIT. The old photo-cropping tool/source lead is recorded
  in the provenance history without overriding that current declaration.
- `tools/regina_sports.ico`: the icon source/generation record has not been established;
  this optional desktop icon is excluded from publication. The editable game SVG is separate.

## Scene-rendered menu previews

`game/assets/previews/*.jpg` are 1600×900 exports of this project's actual game cameras,
using project MIT code/geometry and the existing CC0 scene assets. They do not introduce
external photographs, samples or AI-generated images. Source notices remain applicable;
see [capture provenance](../game/assets/previews/CREDITS.md), the retained capture harness
and SHA-256 manifest. UI evidence in `docs/screenshots/phase5-menu-*.png` additionally
contains the project MIT menu. The combined scene exports are recorded as MIT AND CC0-1.0.

## UI fonts

`game/assets/fonts/` bundles Noto Sans SC (a subset of the variable font) and three Barlow
Condensed styles from google/fonts, both under the SIL Open Font License 1.1. The license texts
ship beside the fonts; source commit, subset method and Reserved Font Name notes are in the
[font credits](../game/assets/fonts/CREDITS.md).

## Runtime and build dependencies

Godot is an external MIT-licensed engine; see <https://godotengine.org/license/>.
Python packages are declared in `hub/pyproject.toml` and installed separately. M5GFX,
M5Unified, ESP-IDF, Blender and MPFB are separate tools/dependencies, not vendored here.
When distributing a compiled game, hub or firmware, collect the notices required by the
exact bundled versions. This source review does not clear an unbuilt binary distribution.

Names of products/platforms in documentation describe compatibility or historical design
references; they do not imply endorsement. No Nintendo game assets or Mixamo animation
files were identified by filename/source records in this review, which is not a visual or
similarity-search guarantee.
