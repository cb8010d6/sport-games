# 39-14 RSRaceFollower：机器人跟线、速度曲线、落后追赶

Issue #39 F9 · 区域：框架（`game/core/`）

## 目标 / 范围外

**目标：** 新增 `RSRaceFollower`，给竞速类项目的机器人用：沿 `RSRaceTrack` 的路线取前视瞄准点（可设车道偏移，接近检查门时自动收进门的窗口）、按弯道曲率算目标速度（横向加速度和刹车上限）、落后追赶 / 领先放慢系数。项目拿到“往哪里转、开多快”，自己转换成油门和转向。

**范围外：** 载具物理；难度（项目用 `bot_error()` / `bot_ability()` 调 `vmax` 和车道误差）；真人的追赶加速是否开启（项目决定，默认关闭）。

## 先读

1. [39-13](39-13-race-track.md) 的接口契约（`Racer`、`point_at`、`right_at`、`curvature_at`、`gate_window`、`steer_angle`）
2. `game/core/race_track.gd`（39-13 合入后的版本，只看公开函数）
3. `game/core/party_game.gd` 456-461（`bot_error()`、`bot_ability()`）
4. 草稿：`origin/wip/39-race` 分支的 `game/core/race_track.gd` 80-110（`Follower`）、214-245（`speed_profile` / `profile_at`）、441-460（`catch_up` / `rubber_band`）
5. `docs/ARCHITECTURE.md` 第 3 节

## 改动文件

- 新建 `game/core/race_follower.gd`（+ `.gd.uid`）—— 框架区
- `game/tests/test_race_track.gd`：追加用例（39-13 的独立测试场景）
- `docs/ARCHITECTURE.md` 第 3 节表格加一行“赛道、名次、机器人跟线 → `RSRaceTrack` / `RSRaceFollower`” —— 框架区

## 接口契约

```gdscript
class_name RSRaceFollower
extends RefCounted

var track: RSRaceTrack
var lane := 0.0                 ## m，相对中线向右
var lookahead := 6.0            ## m：静止时的前视距离
var lookahead_time := 0.6       ## s：再加上这么多秒的行驶距离
var gate_margin := 1.0          ## m：在门窗口内留的余量
var profile := PackedFloat32Array()   ## 每个路线采样点的目标速度

## vmax m/s；lat_accel 横向加速度上限 m/s²；brake 刹车减速度 m/s²；accel > 0 时也限制出弯加速
func _init(race_track: RSRaceTrack, vmax: float, lat_accel := 6.0, brake := 8.0, accel := 0.0) -> void
func target(r: RSRaceTrack.Racer, speed: float) -> Vector3   ## 世界坐标瞄准点
func lane_for(r: RSRaceTrack.Racer) -> float                  ## 实际车道：下一个门没过之前收进门窗口
func speed(r: RSRaceTrack.Racer) -> float                     ## 当前位置的目标速度

## 速度曲线：v = min(vmax, sqrt(lat_accel / |曲率|))，再按 brake 从后往前、按 accel 从前往后平滑
static func speed_profile(track: RSRaceTrack, vmax: float, lat_accel: float, brake: float, accel := 0.0) -> PackedFloat32Array
static func profile_at(track: RSRaceTrack, profile: PackedFloat32Array, s: float) -> float

## 追赶系数，范围 [0.5, 1.5]：gap = 参考进度 - 自己进度（正 = 落后）。
## 落后 full_gap 米时乘 1 + boost，领先 full_gap 米时乘 1 - brake_factor，中间线性；boost / brake_factor 为 0 时恒为 1。
static func rubber_band(gap: float, full_gap: float, boost: float, brake_factor: float) -> float
```

用法（写进类注释）：

```gdscript
var f := RSRaceFollower.new(track, 22.0)
f.lane = 2.0
var aim := f.target(r, speed)
var steer := RSRaceTrack.steer_angle(forward, pos, aim)
var want := f.speed(r) * RSRaceFollower.rubber_band(best_human.progress - r.progress, 80.0, 0.15, 0.1)
```

`target`、`lane_for`、`speed`、`rubber_band` 不分配内存。

## 依赖与顺序

依赖 39-13 的公开接口（可在 39-13 审查期间开工，合并必须在它之后）。

## 验收

`test_race_track.gd` 追加：

- 直线上 `speed_profile` 全为 `vmax`；半径 R 的弯上为 `min(vmax, sqrt(lat_accel * R))`；弯前按 `brake` 提前减速
- 一个简单的运动学小车（每步朝 `target` 转向、按 `speed` 调速）在环形和发夹路线上跑 3 圈：不漏门、`wrong_way` 从未为 true、`lateral` 不超过门窗口
- `lane_for`：下一个门窗口很窄时取窗口中心
- `rubber_band`：0 gap 为 1；落后 / 领先满额时为 1 ± 系数；超出时截断在 [0.5, 1.5]

命令：`<Godot> --headless --path game res://tests/test_race_track.tscn`（`RS_RACE_TRACK_TESTS: <n> checks, 0 failures`），`python tools/check_conventions.py`。

## 不要做

- 不往 `race_track.gd` 里加机器人代码。
- 不读手柄，不碰 `RSPartyGame`。
- 不改滑板、滑雪的机器人。

## 预计规模

`race_follower.gd` 约 130 行，测试约 150 行，文档 1 行。
