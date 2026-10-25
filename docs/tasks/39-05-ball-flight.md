# 39-05 RSBallFlight：飞行、受力与碰撞

Issue #39 F6 · 区域：框架（`game/core/`）

## 目标 / 范围外

**目标：** 新增 `RSBallFlight`，给乒乓球、网球、排球共用的单球物理：固定步长积分（与帧率无关）、重力 + 二次空气阻力 + 马格努斯升力 + 旋转衰减；与有界平面（地面、球台、场地）和球网（网面 + 网带）的连续碰撞，按表面材质给反弹系数和摩擦；接触事件；状态快照。纯逻辑，不建节点。

**范围外：** 球拍 / 手击球、落点预测和瞄准（39-06）；任何规则判定（落台几次、出界、得分由项目的规则类决定）；画面（球的网格、拖尾由项目或 #58 做）。高尔夫的 `RSGolfBall` 保持独立，不合并。

## 先读

1. `game/core/fixed_step.gd`（全文，现有固定步长写法；本类自己带累加器，不复用它的插值）
2. `game/core/swing_detector.gd` 前 30 行（core 纯逻辑类的注释和命名风格）
3. `docs/CODING_STANDARDS.md`（类型、命名、SIZE）
4. `docs/ARCHITECTURE.md` 第 3 节（公共模块表）
5. [乒乓球 D0 设计](../TABLE_TENNIS_DESIGN.md)“F6 球物理与规则边界”一节（需求参考，玩法参数待维护者确认）
6. 草稿：协调者本机 `wt/ball` 的 `game/core/ball_flight.gd` 1-445、460-700 行（见 [39-00](39-00-overview.md)）

## 改动文件

- 新建 `game/core/ball_flight.gd`（+ `.gd.uid`）—— 框架区
- 新建 `game/tests/test_ball_flight.gd` / `.tscn`（+ `.gd.uid`），独立场景测试（检查项多）

## 接口契约

39-06 会往同一个类里加 `hit` / `predict` / `aim`，以下内容是它的基础，不要改名。

```gdscript
class_name RSBallFlight
extends RefCounted
## 单位：米、秒、千克；旋转是世界坐标角速度 rad/s（右手定则）；+Y 向上；位置是球心。

signal contacted(kind: int, id: StringName, point: Vector3, normal_speed: float)
	## 一次落地 / 触网，在 step() 里发出；发出时 tick 已是本步的编号。预测用的副本（emit_events = false）不发。

const HZ := 240                 ## 固定步长频率（见 39-00“需要维护者决定的”第 2 条）
const STEP := 1.0 / HZ
const MAX_FRAME_STEPS := 60     ## advance() 一次最多跑这么多步，超出的卡顿时间丢弃（不积压）
const GRAVITY := 9.81
const CONTACT_SURFACE := 0
const CONTACT_NET := 1
const CONTACT_CORD := 2

class Ball:                     ## mass, radius, drag (Cd), lift_max, spin_decay (1/s), inertia (I/(m r²)), air_density
class Surface:                  ## restitution, restitution_drop, restitution_min, friction, spin_grip, rolling, mass(INF=固定), dwell

static func ball_table_tennis() -> Ball
static func ball_tennis() -> Ball
static func ball_volleyball() -> Ball
static func surface_hard_court() -> Surface
static func surface_clay() -> Surface
static func surface_grass() -> Surface
static func surface_table() -> Surface
static func surface_floor() -> Surface
static func surface_sand() -> Surface
static func surface_net() -> Surface
static func surface_net_cord() -> Surface

var ball: Ball
var tick := 0                   ## set_state() / restore() 之后走过的步数
var resting := false            ## 已停在某个平面上滚动或静止
var emit_events := true

func _init(b: Ball = null) -> void
func set_ball(b: Ball) -> void

# 世界
func add_plane(id: StringName, surface: Surface, point: Vector3, normal := Vector3.UP,
		half_extents := Vector2(INF, INF), axis := Vector3.RIGHT) -> int   ## 单面矩形（或无限平面），返回序号
func add_net(id: StringName, surface: Surface, center: Vector3, normal: Vector3, half_width: float,
		top: float, bottom: float, cord: Surface = null) -> int           ## 竖直球网，顶边是网带
func clear_world() -> void
func add_table_tennis_table(floor_center: Vector3, length_axis := Vector3.FORWARD, floor := surface_floor()) -> void
func add_tennis_court(court: Surface, floor_center := Vector3.ZERO, length_axis := Vector3.FORWARD) -> void
func add_beach_court(floor_center := Vector3.ZERO, length_axis := Vector3.FORWARD) -> void

# 状态
func set_state(position: Vector3, velocity: Vector3, spin := Vector3.ZERO) -> void   ## tick 归零
func position() -> Vector3
func velocity() -> Vector3
func spin() -> Vector3
func time() -> float                     ## tick * STEP
func render_position() -> Vector3        ## 用累加器余量在上一步和本步之间插值，只给画面用
func snapshot() -> PackedFloat64Array    ## 完整动态状态（位置、速度、旋转、tick、resting…）
func restore(s: PackedFloat64Array) -> void
func copy() -> RSBallFlight              ## 共享世界、复制状态，emit_events = false

# 推进
func advance(delta: float) -> int        ## 按帧时间跑整数步，返回步数
func advance_to_tick(target: int) -> void
func step() -> void
```

实现要求：

- 动态状态用 GDScript 64 位 float 分量保存，一步里只用 `+ - * /` 和 `sqrt`，不用 32 位 `Vector3` 运算或 `sin` / `exp`：同一快照、同样步数，结果逐位相同；帧率只改变“当前是第几步”，不改变每一步的状态。
- 碰撞用解析的球体扫掠（本步起点到终点）找最早接触，一步内最多处理 4 次接触，不穿透薄网和高速球台边。
- 接触处理：法向按 `restitution`（随法向速度下降到 `restitution_min`），切向按 `friction` 和球的转动惯量同时改速度和旋转；法向速度小于约 0.15 m/s 时转为滚动，滚动速度很小时停止。
- `step()` 和 `advance()` 不分配数组 / 字典（每帧调用）。

## 依赖与顺序

无前置。39-06 依赖本卡。

## 验收

`game/tests/test_ball_flight.gd` 打印 `RS_BALL_FLIGHT_TESTS: <n> checks, 0 failures`，至少覆盖：

- 真空、无旋转时与解析抛物线一致（误差 < 1 mm / 1 s）
- 阻力让水平速度单调下降；上旋球比无旋球落点更近、下旋更远
- 同一初态用 30 / 60 / 144 FPS 的 `advance()` 切分推进同样的总时间：`snapshot()` 完全相等
- 乒乓球从 0.3 m 落在球台上的反弹高度在合理范围（按 ITTF 规定约 0.23 m，给出容差）；红土比硬地慢、摩擦大
- 高速球（30 m/s）斜穿球网高度以下：必然碰网，不穿过；擦网带时发 `CONTACT_CORD`
- `contacted` 信号的 kind / id / 法向速度正确；`copy()` 出来的副本不发信号、不影响原对象
- `snapshot()` → `restore()` 后继续推进与不中断的结果相同

命令：`python tools/import_game.py --godot <Godot>`，`<Godot> --headless --path game res://tests/test_ball_flight.tscn`；另跑 `python tools/check_conventions.py`。接入 CI 在 PR 里提出（见 README“通用约定”）。

## 不要做

- 不依赖 Godot 物理引擎（`RigidBody3D`、`PhysicsServer3D`）。
- 不读手柄、不知道任何项目的规则或场地尺寸以外的东西（预设里的器材尺寸可以有）。
- 不改 `RSFixedStep` 和高尔夫代码。

## 预计规模

`ball_flight.gd` 约 600 行（主要是新文件，草稿可改造），测试约 300 行。超过 400 行是因为是独立新文件；如审查要求，可把球场预设（`add_*_court/table`）拆成第二个 PR。
