# 39-16 场馆灯架与记分牌

Issue #39 F10（#58 P2 的代码部分）· 区域：框架（`game/core/`）

## 目标 / 范围外

**目标：** 两个共享构件：
1. 灯架 `RSArenaLights`：室外灯塔（桁架 + 一排灯头）、室内顶灯阵列、拳台吊灯。灯头是发光材质，真实光源数量受预算控制（每个场馆默认最多 4 盏），阴影统一走画质接口。
2. 记分牌 `RSScoreboard`：一块带发光底板的屏，显示左右比分、中间一行文字（局数 / 时间），内容变了才更新。

**范围外：** 看台 / 围挡（39-15）；室内整体灯光预设和环境（39-18）；成品灯具模型（#58 P2 的 A3，到了之后用 `RSProps` 的 `arena_*` / `hall_*` 键替换灯头几何）；记分牌上的动画、回放画面。

## 先读

1. [39-15](39-15-arena-structures.md) 的接口契约（朝向约定、材质缓存）
2. `game/core/settings.gd` 207-271（`apply`、`apply_world`、`apply_viewport`、`set_views`）
3. [57-05](57-05-local-shadow-tier.md) 的接口契约（`RSSettings.local_shadows(light)`）
4. `game/core/ui_kit.gd` 24-65（`font_numeric()` 等字体入口）
5. `game/core/podium.gd` 29-68（`configure()`：Label3D + 发光材质的现有写法）
6. `docs/ASSETS.md`“每个新项目的预算”一节（131-144 行）

## 改动文件

- 新建 `game/core/arena_lights.gd`（+ `.gd.uid`）—— 框架区
- 新建 `game/core/scoreboard.gd`（+ `.gd.uid`）—— 框架区
- `game/tests/test_arena.gd`：追加 `_test_lights()`（39-15 的独立测试场景；与 39-17 / 39-18 各加各的函数，合并冲突时都保留）

## 接口契约

```gdscript
class_name RSArenaLights
extends RefCounted

class LightSpec:
	var color := Color(1.0, 0.97, 0.9)
	var energy := 4.0
	var range := 40.0              ## m
	var real_lights := 1           ## 这个灯架上的真实光源数（其余灯头只发光不照明）
	var cast_shadows := false      ## 想要阴影时设 true；是否真的投影由 RSSettings 按画质决定

## 室外灯塔：高 height 米，顶部 heads 个灯头，朝 aim 点照。返回根节点。
static func flood_tower(parent: Node3D, xform: Transform3D, height: float, heads: int, aim: Vector3, spec: LightSpec) -> Node3D
## 室内顶灯阵列：rect（XZ，米）范围内 rows × cols 个灯板，高 height。
static func ceiling_grid(parent: Node3D, rect: Rect2, height: float, rows: int, cols: int, spec: LightSpec) -> Node3D
## 拳台 / 球台上方的吊灯组。
static func hanging_lamps(parent: Node3D, center: Vector3, size: Vector2, height: float, count: int, spec: LightSpec) -> Node3D
## 场馆内全部真实光源数（项目自查预算用）
static func real_light_count(root: Node3D) -> int
```

阴影约定：每盏真实光源建好后调用 `RSSettings.local_shadows(light)`（57-05 提供）；57-05 合入之前，所有 `SpotLight3D` / `OmniLight3D` 一律 `shadow_enabled = false`，不要自己读画质档位。

```gdscript
class_name RSScoreboard
extends Node3D

func _init(size: Vector2, title := "") -> void   ## size 米；底板发光材质 + Label3D（数字用 RSUi.font_numeric()）
func set_scores(left: String, right: String) -> void
func set_line(text: String) -> void              ## 中间一行，调用方负责 tr / RSLang.t
func set_colors(left: Color, right: Color) -> void   ## 左右比分颜色（例如 RSTeams.color）
```

记分牌只在内容变化时改 Label3D 文本；不使用 SubViewport（分屏下每个视口都要渲染，成本高）。

## 依赖与顺序

依赖 39-15（测试场景和朝向约定）。软依赖 57-05：合入顺序任意，按上面的阴影约定写。可以和 39-17、39-18 同时做（各自新文件）。

## 验收

`test_arena.gd` 追加：

- `flood_tower` 的真实光源数等于 `spec.real_lights`，灯头数等于 `heads`
- `ceiling_grid` 4 × 6 阵列、`real_lights = 2` 时整个阵列只有 2 盏真实光源
- 57-05 未合入时所有局部光源 `shadow_enabled == false`；合入后改为检查 `local_shadows` 被应用（按当时代码二选一）
- `RSScoreboard.set_scores("11", "9")` 后文本正确；连续两次同样内容不触发重复赋值（用计数或比较实现）
- `real_light_count` 统计正确

命令：`<Godot> --headless --path game res://tests/test_arena.tscn`（`RS_ARENA_TESTS: <n> checks, 0 failures`），`python tools/check_conventions.py`。

## 不要做

- 不加 `DirectionalLight3D` 或 `WorldEnvironment`（39-18 / 项目负责）。
- 不自己按画质开关阴影。
- 不在记分牌里用 SubViewport。

## 预计规模

`arena_lights.gd` 约 160 行，`scoreboard.gd` 约 80 行，测试约 80 行。
