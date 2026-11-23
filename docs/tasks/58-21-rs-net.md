# 58-21 `RSNet`：球网 + 网柱 + 网带的生成与摆动

Issue #58 · P5 · B4 · 区域：框架（`game/core/`、`game/shaders/`）

## 目标 / 范围外

**目标**：乒乓球、网球、沙排共用一套球网生成器：按尺寸建透明网面（`shared:acg_net004a`）、顶部网带（`shared:acg_rope001` 或白布带）、两侧网柱；击网时项目调用 `shake()`，网面用顶点着色器摆动。同时给出与 39-05 `RSBallFlight.add_net()` 参数一致的数据，项目不用自己再算一遍网的位置。

**范围外**：球与网的碰撞计算（39-05）；乒乓球台和夹网器的成品模型（乒乓球项目）；网球场边裁判椅等。

## 先读

1. [39-05](39-05-ball-flight.md) “接口契约”里的 `add_net(id, surface, center, normal, half_width, top, bottom, cord)`（本卡的 `flight_args()` 按它的参数给值）
2. [58-11](58-11-acg-materials.md)（网 / 绳材质 id 和 PNG alpha 约定）
3. `game/core/pbr.gd:38-88`（`maps` / `standard`）
4. `game/shaders/golf_flag.gdshader`（22 行：顶点摆动的现成写法）
5. `game/tests/catalog_cases.gd`、`game/tests/test_shell.gd:1-10`

## 改动文件

- 新建 `game/core/net.gd`（`class_name RSNet`）+ `.gd.uid`（**框架区**）
- 新建 `game/shaders/rs_net.gdshader`（**共享着色器，按框架区处理**）
- 新建 `game/tests/net_cases.gd`；`game/tests/test_shell.gd` 加一行 `preload`、一行 `run(_check)`
- `docs/ARCHITECTURE.md` 第 3 节加一行“球网：`RSNet.build(parent, xform, spec)`”（**框架区**）

## 接口契约

```gdscript
class_name RSNet

class Spec:
	var width := 1.83          ## 网面总宽（米，含伸出台外的部分）
	var top := 0.1525          ## 网带上沿离地 / 离台面高度（中点）
	var post_top := 0.1525     ## 网柱处上沿高度（网球 1.07、中点 0.914）
	var bottom := 0.0          ## 网面下沿
	var band := 0.015          ## 网带高度
	var post_radius := 0.01    ## 0 = 不建网柱
	var net_id := "shared:acg_net004a"
	var band_id := ""          ## "" = 白色布带（StandardMaterial3D）；或 "shared:acg_rope001"
	var cell_m := 0.0135       ## 网眼尺寸，决定网面贴图平铺

static func preset_table_tennis() -> Spec   ## 宽 1.83、高 0.1525（ITTF）
static func preset_tennis() -> Spec         ## 宽 12.8、中点 0.914、网柱 1.07
static func preset_beach_volleyball() -> Spec   ## 宽 8.5、网高 1.0 m 网面、上沿 2.43（男）——女子 2.24 由项目改 top / post_top

static func build(parent: Node3D, xform: Transform3D, spec: Spec) -> Node3D
	## 原点 = 网下沿中点，网面沿局部 X 展开、法线 ±Z。网面一个 MeshInstance3D（细分 16 × 4 供顶点摆动），
	## 网带、网柱各一个。网面材质：rs_net.gdshader，alpha scissor 用 net 贴图的 alpha，双面、不投影。
static func shake(net_root: Node3D, local_x: float, strength: float) -> void
	## 在网面 local_x 处触发一次衰减摆动（写着色器 uniform hit_x / hit_time / hit_strength），不分配内存。
static func flight_args(xform: Transform3D, spec: Spec) -> Dictionary
	## {"center": Vector3, "normal": Vector3, "half_width": float, "top": float, "bottom": float}，
	## 世界坐标，可直接展开传给 RSBallFlight.add_net()。
```

- 材质缺失（58-11 未合入或稀疏检出）时网面用程序网格线（着色器里 `use_tex = false`），不报错。
- 网面不投影（细网的阴影在分屏下代价高、几乎看不见）。

## 依赖与顺序

依赖 58-11 的材质 id（已写死，可先用回退路径合入）。与 39-05 无代码依赖，只对齐参数名。

## 验收

- `game/tests/net_cases.gd`：三个预设的尺寸；`build()` 生成的节点数和网面 AABB 与 `spec` 一致；`flight_args()` 在旋转 / 平移过的 `xform` 下 `center` / `normal` 正确；`shake()` 写入的 uniform 值；材质缺失时不报错。
- 命令：`python tools/test_game.py --godot <Godot>`；`python tools/check_conventions.py`。

## 不要做

- 不做碰撞（39-05）。
- 不建乒乓球台、网球场地。
- 网面不用 `TRANSPARENCY_ALPHA` 混合（用 alpha scissor）。

## 预计规模

`net.gd` 约 140 行，着色器约 40 行，测试约 60 行。
