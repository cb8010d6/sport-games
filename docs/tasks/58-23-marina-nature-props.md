# 58-23 码头、浮标、灌木、岩石（Poly Haven）+ `RSProps` 键

Issue #58 · P5 · B8、B9、C8（灌木 / 岩石部分）· 区域：素材 + 框架（`game/core/props.gd` 只加键）

## 目标 / 范围外

**目标**：水上摩托、沙排、网球场边需要的岸边 / 自然道具，加进锁定清单并登记 `RSProps` 键。

| 键 | Poly Haven id | 用途 | 2K 体积 | 备注 |
|---|---|---|---:|---|
| `marina_pier` | `modular_wooden_pier` | 码头 / 栈桥（模块化，按部件拆键） | 22.0 MiB | 按 glTF 里的模块拆成 `marina_pier_<部件>` 多个键 |
| `marina_buoy` | `ocean_buoy` | 航道浮标 | 10.0 MiB | 随水面起伏由项目用 `RSWaterSurface.height_at` 驱动 |
| `marina_marker` | `lateral_sea_marker` | 侧标 | 7.2 MiB | |
| `nature_shrub_02` | `shrub_02` | 场边 / 岸边灌木 | 4.6 MiB | |
| `nature_shrub_04` | `shrub_04` | 灌木 | 4.2 MiB | |
| `nature_rock_07` | `rock_07` | 岸边岩石 | 6.0 MiB | |
| `nature_coast_rocks` | `coast_rocks_05` | 海岸礁石 | 32.0 MiB 原始 | **原始 145 万三角，必须先减面**到 ≤ 10k，键指向 `_lod` 文件 |

合计同步约 86 MiB（不进 Git）；减面件进 Git。比赛用的充气转向浮标（两色）是自建件，不在本卡（水上摩托项目或 58-24 一并做）。

**范围外**：树（58-14）；棕榈树（issue 记为缺口）；远景船只（C9，暂不做）；水面（39-10 ~ 39-12）；任何场景摆放。

## 先读

1. `game/core/props.gd:1-51`、`:56-94`（`PREFABS` 格式、`parts` 居中）
2. `tools/blender/decimate_gltf.py`（减面命令；输出 `_lod.gltf`，`textures_lod/` 只放改过的纹理）
3. `game/tests/test_assets.gd:47-78`（新键自动检查）
4. [58-02](58-02-polyhaven-lock-tool.md) 的命令行
5. [39-11](39-11-water-surface.md) 的 `RSWaterSurface.height_at`（浮标随浪的用法，写进 `purpose` 即可，本卡不实现）
6. [58-00 概览](58-00-overview.md)“素材卡通用规则”

## 改动文件

- `tools/assets.lock.json`、`game/assets/polyhaven/models/<id>/*.gltf(.import)`、`polyhaven/CREDITS.md`（工具生成）
- `game/assets/polyhaven/models/coast_rocks_05/coast_rocks_05_lod.gltf|_lod.bin`（+ 必要的 `textures_lod/`）
- `game/core/props.gd`（**框架区**：只在 `PREFABS` 的 `marina` / `nature` 注释段下加键）
- `docs/ASSETS.md`（总数）、`docs/ASSET_MANIFEST.json`（有减面件，重新生成）、减面记录写进 `docs/THIRD_PARTY.md` Poly Haven 一节

## 接口契约

- 键名如上表，码头部件键名在 PR 里列全，写进 58-00 的接口表（同一 PR 更新 58-00）。
- 三角面：场边道具 ≤ 10k；超出一律减面。
- 浮标、侧标的原点在吃水线（`RSProps.parts` 默认把底部放到原点，浮标需要另给吃水深度：在 `props.gd` 键旁注释写明“项目放置时下沉 X m”，不改 `parts` 逻辑）。

## 依赖与顺序

依赖 58-02。与 58-10、58-15、58-16 都改锁定清单，追加不重叠，后合入的合并 dev。

## 验收

- `node tools/sync_assets.mjs --check`；`node --test tools/tests/asset_sync.test.mjs`；`python tools/test_assets.py --godot <Godot>`；`python -m pytest -q tools/tests`；`python tools/check_conventions.py`。
- PR 里列：每个键三角面（原始 / 减面后）、`RS_LOCK_ADDED` 输出、新增 Git 字节。
- 素材记录：`purpose` 写用途和卡号；减面命令与预算写进 THIRD_PARTY。

## 不要做

- 不提交 Poly Haven 原始 `.bin` / 纹理和高模。
- 不改 `RSProps` 函数。
- 不加 `dutch_ship_medium` / `ship_pinnace`。

## 预计规模

`props.gd` +8–12 行；锁定清单约 +40 条；Git 新增 < 8 MiB（主要是礁石减面件）。
