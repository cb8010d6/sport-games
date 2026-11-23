# 58-10 场馆灯具、围栏、场边家具（Poly Haven）+ `RSProps` 键

Issue #58 · P2 · A3、A6、A7 · 区域：素材 + 框架（`game/core/props.gd` 只加键）

## 目标 / 范围外

**目标**：把 issue 已核实的 Poly Haven CC0 模型加入锁定清单，并在 `RSProps.PREFABS` 里登记带套件前缀的键，让 39-15 / 39-16 / 39-18 和各项目用 `RSProps.place(parent, key, xforms)` 直接摆放。

| 键 | Poly Haven id | 用途 | 2K 体积 | 批次 |
|---|---|---|---:|---|
| `arena_security_light` | `security_light` | 室外灯塔灯头（39-16 `flood_tower` 换灯头几何） | 8.1 MiB | 首批 |
| `hall_fluorescent` | `mounted_fluorescent_lights` | 室内顶灯（39-16 `ceiling_grid`） | 4.9 MiB | 首批 |
| `hall_hanging_lamp` | `hanging_industrial_lamp` | 拳台吊灯（39-16 `hanging_lamps`） | 11.4 MiB | 首批 |
| `arena_chainlink_fence` | `modular_chainlink_fence` | 近处铁丝网（远处用 58-11 的 `shared:acg_fence006`） | 15.5 MiB | 首批 |
| `hall_metal_stool` | `metal_stool_02` | 拳击角落凳 | 9.3 MiB | 首批 |
| `hall_folding_stool` | `folding_wooden_stool` | 场边折凳 | 7.7 MiB | 首批 |
| `arena_bench_wood` | `painted_wooden_bench` | 球员长椅 | 7.6 MiB | 首批 |
| `arena_crate_02` | `plastic_crate_02` | 球筐 | 5.0 MiB | 首批 |
| `hall_wall_clock` | `wall_clock` | 场馆挂钟 | 4.7 MiB | 可选 |
| `beach_chalkboard` | `standing_chalkboard_01` | 沙排手翻记分板 | 9.1 MiB | 可选 |
| `arena_megaphone` | `Megaphone_01` | 扩音器 | 1.5 MiB | 可选 |
| `urban_lamp_02` | `street_lamp_02` | 码头步道灯 | 4.9 MiB | 可选 |
| `urban_barrier_02` | `concrete_road_barrier_02` | 护栏 | 9.4 MiB | 可选 |

首批约 70 MiB，全部约 100 MiB（同步下载，不进 Git）。`wooden_picnic_table`（16.8 MiB）、`life_jacket` 不在本卡（后者在 58-08）。

**范围外**：看台、记分牌、灯架桁架的代码（39-15 / 39-16）；观众（58-12）；码头 / 浮标（58-23）；任何场景摆放。

## 先读

1. `game/core/props.gd:1-51`（`PREFABS` 格式：`[glTF 相对路径, [要取的网格名]]`，空数组 = 全部网格）、`:56-94`（`parts` 如何重新居中、`path`）
2. `game/tests/test_assets.gd:47-78`（每个键的检查；新键自动被检查）
3. [58-02](58-02-polyhaven-lock-tool.md) 的命令行
4. `tools/blender/decimate_gltf.py`（超出三角面预算时减面，输出 `*_lod.gltf`；减面件进 Git，见 `.gitignore:51-52`）
5. [58-00 概览](58-00-overview.md)“素材卡通用规则”

## 改动文件

- `tools/assets.lock.json`（`node tools/lock_polyhaven.mjs add --kind models --res 2k --purpose "#58 A3/A6/A7 …" <id …>` 生成）
- `game/assets/polyhaven/models/<id>/<id>_2k.gltf` + `.import`（描述文件进 Git；`.bin` / 纹理同步下载）
- 需要减面的：`game/assets/polyhaven/models/<id>/<id>_lod.gltf` + `_lod.bin`（+ `textures_lod/` 只放加工过的纹理）
- `game/core/props.gd`（**框架区**：只在 `PREFABS` 里加键，按套件归到对应注释段下，不改函数）
- `game/assets/polyhaven/CREDITS.md`（工具自动追加）、`docs/ASSETS.md`（组数 / 文件数 / 字节数）、`docs/ASSET_MANIFEST.json`（有减面件时重新生成）

## 接口契约

- 键名就是上表第一列，写死，39 系列卡按名字取用。
- 每个键的网格名列表：领卡时打开 glTF 看节点名再填；一个文件里有多个变体时只取一个变体（照 `urban_hydrant` / `urban_hydrant_aged` 的写法拆成两个键）。
- 三角面预算：场边道具 ≤ 10k / 个（`docs/ASSETS.md`）。超出的先 `decimate_gltf.py` 到预算以内，键指向 `_lod` 文件（照 `urban_barrier` 指向 `concrete_road_barrier_lod`）。
- 朝向：`RSProps.parts()` 会把底部中心放到原点、面向 +Z；灯具如果原模型灯头朝向不是 −Y（向下）或 +Z，在 PR 里写明，39-16 摆放时自己转。

## 依赖与顺序

依赖 58-02。与 58-11、58-12 可并行。39-16 不依赖本卡也能合入（先用代码几何），本卡合入后 39-16 或后续项目再换。

## 验收

- `node tools/sync_assets.mjs --check`；`node --test tools/tests/asset_sync.test.mjs`；`python tools/test_assets.py --godot <Godot>`（新键全部通过：有网格、尺寸 > 0）；`python -m pytest -q tools/tests`；`python tools/check_conventions.py`。
- PR 里列：每个键的三角面数、原始 / 减面后；`RS_LOCK_ADDED` 输出（同步新增字节）；新增 Git 字节（只有 `.gltf` 描述和减面件）。
- 素材记录：锁定清单由工具生成，`purpose` 写用途和卡号；`polyhaven/CREDITS.md` 一行一个；减面件在 `docs/THIRD_PARTY.md` Poly Haven 一节或 `RESOURCE_CLEANUP` 风格写清命令。

## 不要做

- 不改 `RSProps` 的函数和已有键。
- 不提交 Poly Haven 原始 `.bin` / 纹理。
- 不在任何场景里摆这些道具。

## 预计规模

`props.gd` +8–13 行；锁定清单约 +60 条（工具生成）；Git 新增 < 5 MiB（不含减面件时）。
