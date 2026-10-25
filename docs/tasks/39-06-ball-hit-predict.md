# 39-06 RSBallFlight：击球响应、落点预测、瞄准

Issue #39 F6 · 区域：框架（`game/core/`）

## 目标 / 范围外

**目标：** 在 `RSBallFlight` 上加三组能力：
1. 击球：拍面（或排球的前臂 / 手）以一定速度和朝向在接触点击中球 → 出球速度和旋转；乒乓球、网球共用，排球的垫 / 传 / 扣用不同的“击球面”预设。
2. 预测：给机器人和自动跑位用，算出落点、落地时刻、过网高度；用的是和实时飞行完全相同的步进函数，所以预测 = 实际。
3. 瞄准：给定出球点、目标落点和速度，反解出球速度（含阻力和旋转）。

**范围外：** 挥拍手势怎么变成拍面速度和朝向（39-07 / 39-08 + 项目）；规则判定；机器人难度（项目用 `bot_error()` 往瞄准目标上加误差）。

## 先读

1. [39-05](39-05-ball-flight.md) 的接口契约
2. `game/core/ball_flight.gd`（39-05 合入后的版本：`Surface`、接触处理函数、`copy()`）
3. [乒乓球 D0 设计](../TABLE_TENNIS_DESIGN.md)中“自动跑位”“三档机器人”两段（需求参考）
4. 草稿：协调者本机 `wt/ball` 的 `game/core/ball_flight.gd` 695-844 行（见 [39-00](39-00-overview.md)）
5. `docs/ARCHITECTURE.md` 第 3 节

## 改动文件

- `game/core/ball_flight.gd` —— 框架区
- `game/tests/test_ball_flight.gd`：追加用例
- `docs/ARCHITECTURE.md` 第 3 节表格加一行“球类飞行与击球 → `RSBallFlight`” —— 框架区

## 接口契约

```gdscript
# 击球面预设（Surface 的 mass = 击球面的等效质量，dwell = 球在胶皮 / 线床里“带一下”的比例）
static func racket_table_tennis() -> Surface
static func racket_tennis() -> Surface
static func hands_bump() -> Surface     ## 排球垫球（前臂）
static func hands_set() -> Surface      ## 排球传球（手指，dwell 大）
static func hands_spike() -> Surface    ## 排球扣球（手掌）

## 拍面经过 contact_point，外法线 face_normal，速度 hitter_velocity（m/s）击球：
## 球心移到 contact_point + face_normal * 半径，按接触模型给出出球速度和旋转（拍面向上刷出上旋、后仰出下旋）。
## 球不是朝拍面运动时返回 false，状态不变。成功时 tick 不变、resting = false。
func hit(contact_point: Vector3, face_normal: Vector3, hitter_velocity: Vector3, hitter: Surface) -> bool

class Prediction:
	var bounces := PackedVector3Array()           ## 每次落地的球心位置
	var bounce_times := PackedFloat64Array()      ## 从调用 predict() 起的秒数
	var bounce_ids: Array[StringName] = []
	var bounce_velocities := PackedVector3Array() ## 落地前一刻的速度
	var net_crossed := false
	var net_clearance := INF                      ## 第一次过网时球底到网顶的距离，< 0 表示碰网
	var net_time := -1.0
	var net_hit := false
	var end_position := Vector3.ZERO
	var end_velocity := Vector3.ZERO
	var end_time := 0.0
	var settled := false
	func landed() -> bool
	func land_point() -> Vector3
	func land_time() -> float

## 用副本模拟到第 max_bounces 次落地 / max_time 秒 / 停下为止；本对象不变。
## 开销约每 1/HZ 秒飞行一步：每次击球或落地后算一次，不要每帧算。
func predict(max_time := 3.0, max_bounces := 1) -> Prediction
func time_to_height(height: float, max_time := 3.0, descending := true) -> float   ## -1 = 不会到
func time_to_plane(point: Vector3, normal: Vector3, max_time := 3.0) -> float      ## 例如球员的击球平面；-1 = 不会到
func probe(seconds: float) -> RSBallFlight                                         ## 推进了 seconds 的副本

## 从 from 以 speed 出球、第一次落地落在 target 的出球速度（忽略球网，用真实阻力和旋转迭代求解）；
## lob = true 取高弧线。够不到返回 Vector3.ZERO。用了三角函数，跨机器最后几位可能不同：
## 联机时发送击球后的 snapshot()，不要发送 aim 的输入。过网与否另用 predict().net_clearance 检查。
func aim(from: Vector3, target: Vector3, speed: float, spin := Vector3.ZERO, lob := false, iterations := 8) -> Vector3
```

## 依赖与顺序

依赖 39-05（同一文件，必须在它之后）。

## 验收

`test_ball_flight.gd` 追加：

- 静止拍面挡住来球：出球速度约等于来球速度乘反弹系数；拍面向前挥：出球更快；拍面向上刷：出球带上旋（旋转方向符合右手定则）
- 球背离拍面时 `hit()` 返回 false 且 `snapshot()` 不变
- `predict()` 的第一次落点与实际推进到第一次 `contacted` 时的位置相同（误差 0，同一步进函数）；`predict()` 前后本对象 `snapshot()` 不变
- `net_clearance`：刚好擦网 / 明显过网 / 下网三种情况的符号正确
- `aim()`：网球场、乒乓球台各 5 个目标点，用返回的速度 `set_state` 后实际落点误差 < 5 cm；够不到时返回 `Vector3.ZERO`
- `time_to_plane` 与实际穿过时刻一致（误差 < 一步）

命令：`<Godot> --headless --path game res://tests/test_ball_flight.tscn`（`RS_BALL_FLIGHT_TESTS: <n> checks, 0 failures`），`python tools/check_conventions.py`。

## 不要做

- 不在 `predict()` / `aim()` 里发信号或改原对象。
- 不把规则（比如“必须先落本方台面”）写进预测。
- 不在这里读手柄或挥拍数据。

## 预计规模

`ball_flight.gd` 约 +170，测试约 +150，文档 1 行。
