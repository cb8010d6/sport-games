# 58-13 观众 v2 后排 impostor 图集 + `RSCrowd` 远排入口

Issue #58 · P2 · A2（后排部分）· 区域：素材（`game/assets/shared/crowd/`）+ 工具 + 框架（`game/core/crowd.gd` 加一个函数）

## 目标 / 范围外

**目标**：40 m 以外的观众不再画 3k 三角面的网格，改为一个朝向相机的四边形 + 烘焙图集（复用高尔夫树木的 hemi-octahedral impostor 流程）。

1. 用 `tools/blender/bake_impostor.py` 把 58-12 的坐姿观众烘成图集，衣服区域记在法线图集的 alpha 里，运行时按实例色染衣服；
2. 在 `RSCrowd` 加 `fill_far()`，用现有 `game/shaders/impostor.gdshader` 画远排观众（它已经支持“法线 alpha 标记的区域乘 `INSTANCE_CUSTOM.rgb`”，原本给树叶染色用）。

**范围外**：近排网格（58-12）；`fill_seats` / `cheer`（39-17）；远排观众的动画（远处不动，可接受）；按距离自动在近 / 远之间切换（由项目按看台排数决定用哪个函数）。

## 先读

1. `tools/blender/bake_impostor.py:1-60`（参数、`LEAF_HINTS`：名字含这些词的材质在法线 alpha 里记 1）
2. `game/shaders/impostor.gdshader:1-40`（`INSTANCE_CUSTOM.rgb` 染色、`radius` / `centre_up` / `frames` uniform）
3. `game/scenes/golf/golf_course.gd:620-645`（读 `<kind>.json` 和两张图集、建材质的现成写法）
4. [39-17](39-17-crowd-seats.md) 的“接口契约”（`fill_seats` 签名；本卡的 `fill_far` 参数与它保持一致）
5. [58-12](58-12-crowd-meshes.md)（`crowd_person_src.gltf` 的位置和朝向约定）
6. [58-00 概览](58-00-overview.md)“素材卡通用规则”

## 改动文件

- `tools/blender/bake_impostor.py`：加可选参数 `--tint-hints clothes,shirt,pants`（覆盖 `LEAF_HINTS`，默认值不变，树木烘焙结果不变）
- 新增 `game/assets/shared/crowd/crowd_far_albedo.png`、`crowd_far_normal.png`、`crowd_far.json`（+ `.import`）
- `game/core/crowd.gd`（**框架区**）：加 `fill_far()` 和常量
- `game/tests/test_assets.gd`：追加检查
- `game/assets/shared/crowd/CREDITS.md`、`game/assets/shared/CREDITS.md`

## 接口契约

```gdscript
# game/core/crowd.gd（新增）
const FAR_DIR := "res://assets/shared/crowd/"
const FAR_NAME := "crowd_far"     ## FAR_DIR + FAR_NAME + "_albedo.png" / "_normal.png" / ".json"

static func has_far() -> bool
	## 三个文件都存在。
static func fill_far(parent: Node, seats: Array[Transform3D], occupancy: float,
		rng: RandomNumberGenerator, shirts: Array = SHIRTS) -> MultiMeshInstance3D
	## 与 fill_seats 同样的选座方式（同 rng 序列 → 同样的上座分布）；
	## 每个实例一个四边形，INSTANCE_CUSTOM.rgb = 衣服色，材质 = impostor.gdshader，
	## radius / centre_up / frames 读 crowd_far.json。has_far() 为假时退回 fill_seats()。
```

- `crowd_far.json` 字段与 `bake_impostor.py` 现在输出的一致（包围球中心高度、半径，帧数）。
- 图集：≤ 2048²（`docs/ASSETS.md` A2 预算“共享图集 ≤ 2×2K”），帧数 8×8 起步；`backlight_color` 对观众设成接近 0（不需要树叶透光），在 `fill_far` 里设材质参数，不改着色器。
- `fill_seats` 若尚未合入（39-17），本卡不能开工——`fill_far` 要复用它的选座逻辑（抽成一个私有静态函数两边共用）。

## 依赖与顺序

依赖 58-12（网格）和 39-17（`fill_seats`、选座逻辑）。

## 验收

- `game/tests/test_assets.gd` 追加（稀疏检出跳过）：`RSCrowd.has_far()`；两张图集 ≤ 2048²；`fill_far` 在 100 个座位、上座率 0.5、固定种子下实例数与 `fill_seats` 相同。
- 树木回归：用默认参数重烘一棵树，输出与仓库里的 `golf/trees/` 图集逐字节相同不是必须的（Cycles 有噪声），但 PR 里说明默认路径的代码没有变化（diff 只在参数解析处）。
- `python tools/test_assets.py --godot <Godot>`；`python tools/texture_imports.py --check`；`python -m pytest -q tools/tests`；`python tools/check_conventions.py`。
- 素材记录：输入 `crowd_person_src.gltf`、Blender 版本、烘焙命令与参数；许可同 58-12 的 `crowd/` 规则（`MIT AND CC0-1.0`）。

## 不要做

- 不新建 impostor 着色器（复用 `impostor.gdshader`）。
- 不改 `fill_seats` 的签名和行为。
- 不在任何项目里替换观众。

## 预计规模

`bake_impostor.py` 约 +10 行，`crowd.gd` 约 +45 行，测试约 25 行；图集约 4–8 MiB。
