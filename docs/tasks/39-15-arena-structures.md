# 39-15 RSArena：看台、围挡、广告板

Issue #39 F10（#58 P2 的代码部分）· 区域：框架（`game/core/`）

## 目标 / 范围外

**目标：** 新增 `RSArena`，用参数生成场馆通用构件：看台（室外金属阶梯、室内座椅、拳台边折叠椅三种样式）、围挡（铁丝网、矮挡板、围绳）、广告板（沿一条折线排列，贴图来自共享横幅图集）。几何由代码生成、材质用已有的 Poly Haven 扫描材质（`RSPbr`），座椅用 MultiMesh。看台同时给出**座位变换列表**，39-17 用它摆观众。

**范围外：** 灯架和记分牌（39-16）；观众（39-17）；室内场馆壳和灯光预设（39-18）；成品 glTF 模型和横幅图集（#58 P2 / P7 交付，到了以后用 `RSProps` 的 `arena_*` / `hall_*` 键接入）；任何具体项目的场地布局。

## 先读

1. `game/core/pbr.gd` 1-15、61-90（`ROOTS`、`surface()`、`standard()`）
2. `game/core/props.gd` 1-15、107-130（套件前缀约定、`place()`）
3. `game/core/crowd.gd` 44-60（MultiMesh 写法）
4. `game/core/mesh_util.gd`（现有网格工具，先看有没有能复用的）
5. `docs/ASSETS.md` 81-130（共享素材库：目录、命名、导入、预算）
6. #58 正文“(a) 场馆 / 看台套件”表格 A1、A5、A6 三行（`gh issue view 58`）

## 改动文件

- 新建 `game/core/arena.gd`（+ `.gd.uid`）—— 框架区
- 新建 `game/tests/test_arena.gd` / `.tscn`（+ `.gd.uid`）：要建 3D 节点，用独立场景

## 接口契约

39-16、39-17、39-18 依赖以下内容。所有构件朝向约定：局部 +Z 朝向场地（观众看过去的方向），原点在构件前沿底部中点。

```gdscript
class_name RSArena
extends RefCounted

enum BleacherStyle { OUTDOOR_METAL, INDOOR_SEATS, RINGSIDE_CHAIRS }
enum FenceStyle { CHAINLINK, LOW_BOARD, ROPE }

class Bleacher:
	var style := BleacherStyle.OUTDOOR_METAL
	var rows := 6
	var seats_per_row := 20
	var seat_pitch := 0.5        ## m：同排两座间距
	var row_depth := 0.8         ## m
	var row_rise := 0.4          ## m
	var seat_color := Color(0.25, 0.3, 0.38)   ## 中性色，不用玩家色（#58 美术规范）
	var aisle_every := 0         ## 每多少座留一条过道（0 = 不留）

## 建一座看台，返回它的根节点（已加进 parent）。台阶和栏杆合并成少量 MeshInstance3D，座椅一个 MultiMesh。
static func bleacher(parent: Node3D, xform: Transform3D, spec: Bleacher) -> Node3D
## 这座看台每个座位上“观众坐下时的变换”（世界坐标，+Z 朝场地），按排从前到后、排内从左到右。
## 只算数，不建节点；39-17 的 RSCrowd.fill_seats 用它。
static func seat_transforms(xform: Transform3D, spec: Bleacher) -> Array[Transform3D]

## 沿折线建围挡（每段一个 MeshInstance3D 或 MultiMesh 立柱）。height 米。
static func fence(parent: Node3D, path: PackedVector3Array, height: float, style: FenceStyle) -> Node3D

## 沿折线排广告板，每块 width 米宽、height 米高；atlas 为 null 时用纯色占位（RSUi.SURFACE 系颜色），
## 否则按 slots 把图集横向等分、依次轮流贴到各块上。
static func ad_boards(parent: Node3D, path: PackedVector3Array, width: float, height: float,
		atlas: Texture2D = null, slots := 1) -> Node3D

## 估算这些构件的三角形数（给项目做预算检查）
static func triangle_count(root: Node3D) -> int
```

材质约定：金属台阶 `RSPbr.standard("metal_plate")`，混凝土 `RSPbr.standard("concrete_wall_003")`，木梁 `RSPbr.standard("beam_wall_01")`，座椅塑料 `StandardMaterial3D`（`seat_color`，粗糙度 0.6）。同一种材质在整个场馆里只建一份（静态缓存）。所有构件只在加载时建，之后不改。

## 依赖与顺序

无前置。39-16、39-18 依赖本卡；39-17 只依赖 `seat_transforms` 的签名和朝向约定，可以同时开工。

## 验收

`game/tests/test_arena.gd` 打印 `RS_ARENA_TESTS: <n> checks, 0 failures`，至少覆盖：

- `seat_transforms` 数量 = rows × seats_per_row（扣掉过道）；第一排高度 = `row_rise`，每排递增；所有座位 +Z 朝场地
- `bleacher()` 的 MultiMesh 实例数等于座位数；三种样式都能建出来
- 同一场景里建两座看台，金属材质对象是同一个（缓存生效）
- `fence` / `ad_boards` 的段数与折线段数一致；`atlas == null` 不报错
- `triangle_count` 对 6 排 × 20 座的室外看台低于预算（建议 ≤ 20k 三角，在测试里写死这个上限）

命令：`python tools/import_game.py --godot <Godot>`，`<Godot> --headless --path game res://tests/test_arena.tscn`，`python tools/check_conventions.py`。Poly Haven 贴图在稀疏检出时可能缺失：测试只检查材质对象和网格，不依赖贴图存在。

## 不要做

- 不下载素材、不新增 `RSProps.PREFABS` 键（素材归 #58）。
- 不使用真实品牌或赛事标志（占位就是纯色）。
- 不放灯光（39-16）。

## 预计规模

`arena.gd` 约 300 行，测试约 120 行。
