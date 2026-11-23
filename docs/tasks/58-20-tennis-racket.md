# 58-20 网球拍

Issue #58 · P5 · B2 · 区域：素材（`game/assets/shared/equipment/`）+ 工具（`tools/blender/make_equipment.py` 加一个函数）

## 目标 / 范围外

**目标**：在 58-19 的 `make_equipment.py` 注册表里加 `racket_tennis`：参数化曲线建拍框，拍线做成真实的细网格几何（不用 alpha 贴图），握把用 Poly Haven `leather_white` 细节法线，拍框漆面可按玩家色染。

**范围外**：网球（58-19）；挥拍动作、持拍骨骼挂点（网球项目）；其他球拍。

## 先读

1. `tools/blender/make_equipment.py`（58-19 写好的注册表、导出函数；照 `paddle_tt` 的写法加）
2. [58-19](58-19-equipment-paddle-balls.md) 的“接口契约”（输出目录、命名、朝向约定）
3. issue #58 正文 B2 一行（网格拍线、色带用玩家色、≤ 4k 三角）
4. `game/core/pbr.gd:20-55`（`leather_white` 贴图位置；58-19 已锁定）
5. [58-00 概览](58-00-overview.md)“素材卡通用规则”

## 改动文件

- `tools/blender/make_equipment.py`（加 `racket_tennis` 函数和注册）
- 新增 `game/assets/shared/equipment/racket_tennis/eq_racket_tennis.gltf|.bin` + 贴图
- `game/assets/shared/equipment/CREDITS.md`、`game/assets/shared/CREDITS.md`

## 接口契约

| item | 尺寸 / 原点 / 朝向 | 三角面 | 材质名 |
|---|---|---|---|
| `racket_tennis` | 全长 0.685 m、拍面约 0.26 × 0.33 m；原点在柄底中心，柄沿 +Y，拍面法线 ±Z（正手面 +Z） | ≤ 4k | `frame`（漆面，项目可整体染色）、`throat_band`（拍喉色带，项目染玩家色）、`strings`（白色，粗糙度 0.5）、`grip`（皮革，法线取 `leather_white`） |

- 拍线：纵横各 16 / 19 根，每根是截面 4 边形的细管或两片交叉四边形（三角面预算内二选一，PR 里说明）；不用透明贴图，避免分屏下的排序和 alpha-to-coverage 成本。
- 不带任何品牌字样或仿真实拍型的特征配色。

## 依赖与顺序

依赖 58-19（脚本骨架、`leather_white` 已锁定）。与 58-22 可并行（都只往注册表里加函数，冲突时都保留）。

## 验收

- `game/tests/test_assets.gd` 追加（稀疏检出跳过）：glTF 能加载；三角面 ≤ 4000；4 个材质名存在；包围盒长度 0.685 m ± 2%。
- `python tools/test_assets.py --godot <Godot>`；`python tools/texture_imports.py --check`；`python -m pytest -q tools/tests`。
- PR 里列三角面、新增 Git 字节（目标 ≤ 3 MiB）。
- 素材记录：CREDITS 写输入（`leather_white`，Rob Tuytel）、Blender 版本、命令；许可 `MIT AND CC0-1.0`（58-19 已加策略规则）。

## 不要做

- 不加新的 Poly Haven 材质（握把只用已锁定的 `leather_white`）。
- 不在游戏里接入。

## 预计规模

脚本 +120 行；素材 1–3 MiB。
