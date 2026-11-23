# 58-19 `make_equipment.py` + 乒乓球拍 + 三种球

Issue #58 · P5 · B1、B3 · 区域：素材（`game/assets/shared/equipment/`）+ 工具（`tools/blender/`）

## 目标 / 范围外

**目标**：

1. 新建器材生成脚本 `tools/blender/make_equipment.py`（一个“物品名 → 建模函数”的注册表），之后的网球拍（58-20）、拳套 / 拳台（58-22）往里加函数；
2. 用它做乒乓球拍（B1）和乒乓球、网球、沙滩排球（B3），导出 glTF，球的缝线 / 分片 / 毛毡烘进小贴图。

没有找到合格的 CC0 现成模型（issue 附录 A 已核实），全部程序化建模 + CC0 材质。

**范围外**：网球拍（58-20）；球网（58-21）；乒乓球台（乒乓球项目 #60 自己的素材，放 `game/assets/table_tennis/`）；球的拖尾（58-27）；任何游戏代码和物理参数。

## 先读

1. `tools/blender/decimate_gltf.py`（最短的 Blender 无界面脚本：参数、导入导出写法）
2. `tools/blender/make_skaters.py:95-142`（`bake_mesh` 与 glTF 导出参数）
3. `game/core/pbr.gd:20-55`（`plywood`、`shared:acg_rubber004` 的贴图文件在哪里）
4. issue #58 正文 B1、B3 两行（尺寸、材质、三角面预算）
5. [58-02](58-02-polyhaven-lock-tool.md)（`leather_white`、`terry_cloth` 要先进锁定清单）
6. [58-00 概览](58-00-overview.md)“素材卡通用规则”

## 改动文件

- 新建 `tools/blender/make_equipment.py`
- `tools/assets.lock.json` + `polyhaven/CREDITS.md`：`node tools/lock_polyhaven.mjs add --kind textures --res 2k --purpose "#58 B3 …" leather_white terry_cloth`
- 新增 `game/assets/shared/equipment/paddle_tt/eq_paddle_tt.gltf|.bin` + 贴图
- 新增 `game/assets/shared/equipment/ball_tt/`、`ball_tennis/`、`ball_volley/` 各一个 `eq_ball_<名>.gltf|.bin` + 烘焙贴图（≤ 1K）
- `game/assets/shared/equipment/CREDITS.md`、`game/assets/shared/CREDITS.md`；`tools/asset_policy.json` 为 `game/assets/shared/equipment/` 加 `MIT AND CC0-1.0` 规则（项目原创几何），放在 `game/assets/shared/` 之前

## 接口契约

```
blender --background --factory-startup --python tools/blender/make_equipment.py -- <item> [<item> ...]
	# item ∈ {paddle_tt, ball_tt, ball_tennis, ball_volley}（58-20 / 58-22 往注册表里加）
	# 输出 game/assets/shared/equipment/<item>/eq_<item>.gltf（GLTF_SEPARATE，贴图放同目录）
```

| item | 尺寸 / 原点 / 朝向 | 三角面 | 材质名（项目按名字找表面） |
|---|---|---|---|
| `paddle_tt` | 拍面 0.15 × 0.16 m、柄长 0.10 m；原点在柄底中心，柄沿 +Y，正手胶皮朝 +Z | ≤ 2k | `blade`（`plywood`）、`rubber_fh`（红）、`rubber_bh`（黑）、`band`（柄端细环，项目染玩家色） |
| `ball_tt` | 直径 0.040 m，原点球心 | ≤ 1k | `ball`（白 / 橙由项目改 `albedo_color`） |
| `ball_tennis` | 直径 0.067 m | ≤ 1k | `ball`（黄绿毛毡 + 白色缝线，贴图烘焙） |
| `ball_volley` | 直径 0.21 m | ≤ 1k | `ball`（蓝 / 黄 / 白分片，不仿真实品牌） |

- 胶皮贴图来自 `shared:acg_rubber004`（58-11），烘到拍面 UV 上；颜色在材质里染（红 / 黑），同一张贴图。
- 球的贴图在 Blender 里烘焙：毛毡法线取 `terry_cloth`，皮革法线取 `leather_white`，缝线 / 分片用程序纹理画；输出 `eq_ball_<名>_diff_1k.png` / `_nor_gl_1k.png`（命名照 Poly Haven，便于以后改用 `RSPbr`）。
- 物理尺寸以真实规则为准；项目的碰撞体自己按半径建，不读 glTF 包围盒。

## 依赖与顺序

依赖 58-02（锁定两组材质）、58-11（胶皮）。58-11 未合入时可以先做球，球拍最后补。58-20、58-22 依赖本卡的脚本骨架。

## 验收

- `game/tests/test_assets.gd` 追加（稀疏检出跳过）：4 个 glTF 都能加载；三角面在预算内；必需材质名存在；`ball_*` 的 AABB 直径与表中尺寸误差 < 2%。
- `python tools/test_assets.py --godot <Godot>`；`python tools/texture_imports.py --check`；`python -m pytest -q tools/tests`；`node tools/sync_assets.mjs --check`；`node --test tools/tests/asset_sync.test.mjs`。
- PR 里列：每件三角面、贴图尺寸、新增 Git 字节（目标合计 ≤ 8 MiB）、新增同步字节（约 22 MiB）。
- 素材记录：CREDITS 每个文件写输入（`plywood`、`acg_rubber004`、`leather_white`、`terry_cloth` 及作者）、Blender 版本、命令；许可 `MIT AND CC0-1.0`。

## 不要做

- 不仿任何真实品牌的标志、配色或字样。
- 不在游戏里接入（乒乓球 / 网球 / 沙排项目自己接）。
- 不写球的着色器（贴图烘焙即可）。

## 预计规模

脚本约 300 行；素材约 5–8 MiB。
