# 39-13 RSRaceTrack：路线进度、检查点、实时名次

Issue #39 F9 · 区域：框架（`game/core/`）

## 目标 / 范围外

**目标：** 新增 `RSRaceTrack`，把“沿路线推进、检查点、实时名次”的通用部分做成纯逻辑：折线或 Catmull-Rom 样条路线、弧长进度、投影（含急弯和交叉路线下不跳到别的路段）、按顺序的检查门（水上摩托的浮标门）、圈数或点到点终点、实时名次（并列同名次）、终点时刻插值。水上摩托第一个用。

**范围外：** 机器人跟线、速度曲线、落后追赶（39-14）；把滑板、滑雪迁移过来（本 issue 不强制，等它们下次修改时再做）；漏门罚时等规则（项目决定，本类只报告事件）。

## 先读

1. `game/scenes/skate/skate_game.gd` 190-200、375-390、540-550（滑板现在的名次和进度条写法，作为需求参考）
2. `game/core/fixed_step.gd` 前 20 行（core 纯逻辑类的写法）
3. `docs/CODING_STANDARDS.md`
4. `docs/ARCHITECTURE.md` 第 3 节
5. 草稿：`origin/wip/39-race` 分支的 `game/core/race_track.gd` 1-210、240-500、560-689 行（见 [39-00](39-00-overview.md)；`Follower`、`speed_profile`、`catch_up`、`rubber_band` 属于 39-14，本卡不要）

## 改动文件

- 新建 `game/core/race_track.gd`（+ `.gd.uid`）—— 框架区
- 新建 `game/tests/test_race_track.gd` / `.tscn`（+ `.gd.uid`），独立场景测试

## 接口契约

39-14 只依赖下面列出的公开成员。

```gdscript
class_name RSRaceTrack
extends RefCounted
## 米、秒。路线在地面上：弧长和投影都在水平 XZ 平面计算（Y 只由 point_at 带出）。
## s：从起点算的弧长 [0, length]；闭合路线 s = 0 是起终点线。progress：展开的进度 = lap * length + s。
## lateral：相对行进方向右侧为正的横向偏移。纯逻辑：不建节点、不用随机数。

const GATE_PASSED := 1          ## update_racer 返回的事件位
const GATE_MISSED := 2
const LAP := 4
const FINISHED := 8
const SPLINE_STEP := 2.0        ## m：样条重采样间距

class Racer extends RefCounted:
	var id := 0
	var s := 0.0
	var lateral := 0.0
	var progress := 0.0
	var lap := 0
	var next_gate := 0          ## 下一个要过的门序号；没有门剩下时 = gate_count()
	var gates_hit := 0
	var gates_missed := 0
	var finished := false
	var finish_time := 0.0      ## 在跨线前后两次更新之间插值
	var finish_order := 0       ## 到达顺序 1, 2, 3 …（唯一）；0 = 未到
	var place := 0              ## 实时名次，并列同名次（1, 1, 3）
	var wrong_way := false

var closed := false
var length := 0.0
var laps := 1                   ## 闭合路线的圈数
var finish_s := -1.0            ## 开放路线的终点 s；< 0 表示路线末端
var racers: Array[Racer] = []
var order: Array[Racer] = []    ## update_standings() 之后：领先者在前

func _init(points: PackedVector3Array, loop := false, step := SPLINE_STEP) -> void
func wrap_s(s: float) -> float
func delta_s(from_s: float, to_s: float) -> float      ## 闭合路线取最短方向
func point_at(s: float) -> Vector3
func tangent_at(s: float) -> Vector3
func right_at(s: float) -> Vector3
func curvature_at(s: float) -> float                   ## 1/m，+ = 右转
func project(pos: Vector3, hint_s := NAN) -> Vector2   ## (s, lateral)；有 hint 时只在其附近窗口内找
static func steer_angle(forward: Vector3, from: Vector3, to: Vector3) -> float   ## rad，+ = 右转

func add_gate(s: float, lo := -INF, hi := INF) -> int  ## 门在 s 处，横向窗口 [lo, hi]；门按 s 排序
func add_gate_between(a: Vector3, b: Vector3) -> int   ## 两个浮标之间的门
func gate_count() -> int
func gate_s(i: int) -> float
func gate_window(i: int) -> Vector2
func gate_point(i: int) -> Vector3

func add_racer(id: int) -> Racer
func remove_racer(r: Racer) -> void
func new_race() -> void                                ## 每回合开始：清空所有 Racer 的进度
func start_racer(r: Racer, start_progress: float, time := 0.0) -> void   ## 发车格可在线后（负进度）
func update_racer(r: Racer, pos: Vector3, time: float) -> int            ## 返回事件位
func update_standings() -> void                        ## 每帧对所有人调用 update_racer 后调用一次
func fraction(r: Racer) -> float                       ## 0..1 的完成比例（给 HUD 进度条）
func leader() -> Racer
func gap_to_leader(r: Racer) -> float                  ## m
```

实现要求：`project`、`update_racer`、`update_standings` 不分配内存（所有表在 `_init` / `add_gate` 里建好）；投影用“上次 s 附近窗口 + 均匀网格全局查找”两级，急弯、交叉路线、重生、抄近路都不会跳到邻近路段。名次规则：已完赛的按 `finish_order` 在前；未完赛的按 `progress` 降序；进度差 < 1 mm 视为并列。

## 依赖与顺序

无前置。39-14 依赖本卡的公开接口；接口按上面写死后，39-14 可以在本卡审查期间开工。

## 验收

`game/tests/test_race_track.gd` 打印 `RS_RACE_TRACK_TESTS: <n> checks, 0 failures`，至少覆盖：

- 直线 / 圆形路线的 `length`、`point_at`、`tangent_at`、`curvature_at` 与解析值一致
- 发夹弯和 8 字交叉路线：沿路线移动时 `project` 的 s 单调，不跳到另一段
- 闭合路线跨过起终点线 `lap` + 1；倒着开 `wrong_way` 为 true
- 门：从窗口内穿过 → `GATE_PASSED`，从窗口外绕过 → `GATE_MISSED`，`next_gate` 前进
- 名次：3 人中 2 人进度相同 → 1, 1, 3；先到终点者名次固定在前
- `finish_time` 在两次更新之间正确插值
- 连续 1000 次 `update_racer` 的耗时在测试里打印出来（不设硬门槛，供审查参考）；“不分配”靠审查确认：`project` / `update_racer` / `update_standings` 里没有数组字面量或新建数组

命令：`python tools/import_game.py --godot <Godot>`，`<Godot> --headless --path game res://tests/test_race_track.tscn`，`python tools/check_conventions.py`。

## 不要做

- 不改滑板、滑雪代码。
- 不依赖 `Path3D` / `Curve3D` 节点（要能在不进场景树时使用）。
- 不放机器人逻辑（39-14）。

## 预计规模

`race_track.gd` 约 550 行（新文件，草稿可改造），测试约 400 行。
