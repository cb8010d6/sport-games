# 58-22 拳套、拳台

Issue #58 · P5 · B5、B6 · 区域：素材（`game/assets/shared/equipment/`）+ 工具（`make_equipment.py` 加函数）

## 目标 / 范围外

**目标**：在 58-19 的 `make_equipment.py` 里加 `gloves_boxing` 和 `ring` 两个物品：

- 拳套：左右各一个静态网格，项目用 `BoneAttachment3D` 挂到 `hand_l` / `hand_r`；皮革法线取 Poly Haven `leather_red_02`，主色可染（玩家色，电脑对手中性黑 / 白）。可以 MakeHuman **Gloves 01** 包里的 `learning_mma_fighting_gloves`（CC0）为底改形，也可完全自建；
- 拳台：立柱、角垫、四根围绳 × 4 边、台布、台裙、台阶，单个 glTF；围绳每根是独立网格，项目受击时自己晃动。

**范围外**：拳击服装（58-08）；拳台灯光（39-16 `hanging_lamps`）；台裙上的 Logo（58-31）；挥拳动作、命中判定（拳击项目）。

## 先读

1. `tools/blender/make_equipment.py`（58-19 的注册表和导出函数）
2. [58-19](58-19-equipment-paddle-balls.md) “接口契约”（目录、命名、`MIT AND CC0-1.0` 规则已加）
3. `game/core/human_rig.gd:11-13`（`DRIVEN` 里 `hand_l` / `hand_r` 骨骼名）；任意一个角色 glTF 里 `hand_r` 的朝向（拳套原点和朝向要与骨骼一致）
4. issue #58 正文 B5、B6 两行；附录 A 的 MakeHuman Gloves 01、ambientCG Rope001
5. [58-02](58-02-polyhaven-lock-tool.md)（`leather_red_02`、`hessian_230` 先锁定）
6. [58-00 概览](58-00-overview.md)“素材卡通用规则”

## 改动文件

- `tools/blender/make_equipment.py`（加 `gloves_boxing`、`ring`）
- `tools/assets.lock.json` + `polyhaven/CREDITS.md`：`node tools/lock_polyhaven.mjs add --kind textures --res 2k --purpose "#58 B5/B6 …" leather_red_02 hessian_230`
- 新增 `game/assets/shared/equipment/gloves_boxing/eq_gloves_boxing_{l,r}.gltf|.bin`、`ring/eq_ring.gltf|.bin` + 贴图 + `ring/eq_ring.json`
- `game/assets/shared/equipment/CREDITS.md`、`game/assets/shared/CREDITS.md`；用了 Gloves 01 时 `docs/THIRD_PARTY.md` MakeHuman 一节补一段

## 接口契约

| item | 原点 / 朝向 / 尺寸 | 三角面 | 材质名 |
|---|---|---|---|
| `gloves_boxing` | 原点在手腕（`hand_*` 骨骼头），轴向与该骨骼静止姿态一致（挂上即对齐，项目不再补旋转）；10–12 oz 体积感 | ≤ 3k / 只 | `leather`（染色）、`cuff`（腕带，白 / 黑）、`lace`（可选） |
| `ring` | 原点在台面中心、台面高度 y = 0（台面以下是台裙和台阶，项目把整体抬高 `platform_h`）；围绳内 6.1 m 见方 | ≤ 15k | `canvas`（`hessian_230`）、`apron`、`post`（`metal_plate`）、`pad_red` / `pad_blue` / `pad_neutral`、`rope` |

`eq_ring.json`：

```json
{"version": 1, "platform_h": 1.0, "inner": 6.1,
 "ropes": [{"node": "rope_n_0", "a": [-3.05, 0.45, -3.05], "b": [3.05, 0.45, -3.05]}, "..."]}
```

- 每根围绳一个节点，名字 `rope_<边 n|e|s|w>_<0..3>`，从下往上；`a` / `b` 是两端在拳台局部坐标的位置（米），项目据此做晃动或碰撞。
- 角垫颜色固定（红角 / 蓝角 / 两个中性角），不用玩家色。
- 绳材质用 `shared:acg_rope001`（58-11）的贴图烘焙或直接引用；没合入时先用纯色，PR 写明。

## 依赖与顺序

依赖 58-19（脚本骨架）、58-02；绳的贴图依赖 58-11（可回退纯色）。与 58-20 可并行。

## 验收

- `game/tests/test_assets.gd` 追加（稀疏检出跳过）：3 个 glTF 能加载；三角面在预算内；必需材质名存在；`eq_ring.json` 里每个 `node` 在拳台场景中存在，共 16 根。
- `python tools/test_assets.py --godot <Godot>`；`python tools/texture_imports.py --check`；`python -m pytest -q tools/tests`；`node tools/sync_assets.mjs --check`。
- PR 里列：三角面、新增 Git 字节（目标 ≤ 10 MiB）、新增同步字节（约 20 MiB）。
- 素材记录：CREDITS 写输入（`leather_red_02`、`hessian_230`、`metal_plate`、`acg_rope001`、Gloves 01 若使用）、Blender 版本、命令；许可 `MIT AND CC0-1.0`。

## 不要做

- 不做蒙皮拳套（静态网格挂骨骼即可）。
- 不印真实品牌或赛事标志。
- 不在游戏里接入。

## 预计规模

脚本 +250 行；素材约 6–10 MiB。
