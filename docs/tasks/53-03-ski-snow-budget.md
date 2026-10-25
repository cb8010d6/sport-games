# 53-03 滑雪雪粒子：按视图数缩量，大厅雪在比赛中停掉

Issue #53 · 分项 1.7 · 区域：项目（`game/scenes/ski/`）

## 目标 / 范围外

**目标**：降雪地图（夜场 `snowfall = 0.25`、冰川风雪 `1.0`）里，每名玩家一套 2400 粒子、带湍流的雪，加上大厅 / 领奖台相机一套，4 人时共 5 套同时模拟。改成：

1. 粒子比例 = `snowfall × 视图系数`，3–4 个视图时系数 0.5（每个视图更小，看不出密度差）；
2. 大厅雪只在大厅 / 领奖台相机在画时发射，比赛中 `emitting = false`；
3. 低画质（`RSSettings.quality == 0`）建雪时关湍流。

雪的生成代码搬进新文件，方便测试，`ski_game.gd` 只留调用。

**范围外**：滑雪者身上的雪尘粒子（`skier.gd` 的 `_make_fx`）；雪的外观（尺寸、速度、颜色）；非降雪地图（已经不发射）。

## 先读

1. `game/scenes/ski/ski_game.gd:155-166`（换图时设置全部雪）、`:170-222`（`_snow_systems`、`_make_snow`）、`:248-249`（`_follow_snow`）、`:255-270`（玩家加入时建雪）
2. `game/scenes/ski/ski_game.gd:120-130`（大厅雪的创建）以及大厅 / 比赛切换处（搜 `lobby_cam` 和 `views.visible`）
3. `game/core/settings.gd:51`（`RSSettings.views`）、`:265-276`（`set_views`、`split_tier`）
4. `game/tests/test_perf.gd:26-35`（`_run()` 的调用顺序）

## 改动文件

- 新建 `game/scenes/ski/ski_snow.gd`（`class_name RSSkiSnow`）+ `.gd.uid`
- `game/scenes/ski/ski_game.gd`（`_make_snow` 搬走；3 处设置 `amount_ratio` 改调 `RSSkiSnow.ratio()`；大厅雪的开关）
- `game/tests/test_perf.gd`（加一个检查函数）

## 接口契约

```gdscript
# game/scenes/ski/ski_snow.gd
class_name RSSkiSnow
const AMOUNT := 2400
const SPLIT_FACTOR := 0.5           ## 3–4 个视图时的粒子比例系数

static func make(layers: int, quality: int) -> GPUParticles3D
	## 现在 _make_snow(layers) 的内容原样搬来；quality == 0 时 turbulence_enabled = false。

static func ratio(snowfall: float, views: int) -> float
	## snowfall <= 0 返回 0；否则 maxf(snowfall * (SPLIT_FACTOR if views >= RSSettings.SPLIT_TIER_VIEWS else 1.0), 0.01)。

static func apply(ps: GPUParticles3D, snowfall: float, views: int) -> void
	## ps.emitting = snowfall > 0；ps.amount_ratio = ratio(snowfall, views)。amount_ratio 改变不重启粒子。
```

- `ski_game.gd` 里三处 `emitting` / `amount_ratio` 赋值（换图、玩家加入）改为 `RSSkiSnow.apply(sn, snowfall, RSSettings.views)`。
- 视图数在大厅加人时会变：在已有的每帧 `_follow_snow` 调用旁，比较上一次记下的 `RSSettings.views`，变化时对 `_snow_systems()` 重新 `apply`（不要每帧无条件设置）。
- 大厅雪：比赛开始（分屏视图显示）时 `_lobby_snow.emitting = false`，回到大厅 / 领奖台时按地图恢复。找现有的大厅 ↔ 比赛切换函数加这两行，不新增状态。

## 依赖与顺序

无依赖。53-02 改 `skier.gd`，本卡改 `ski_game.gd`，可以并行。

## 验收

- `game/tests/test_perf.gd` 新增 `_ski_snow_budget()`（不需要角色模型，CI 也跑）：
  - `RSSkiSnow.ratio(0.0, 4) == 0.0`；`ratio(1.0, 1) == 1.0`；`ratio(1.0, 4) == 0.5`；`ratio(0.25, 2) == 0.25`；
  - `make(1, 0)` 的处理材质 `turbulence_enabled == false`，`make(1, 2)` 为 `true`；
  - 打印 `RS_PERF_SNOW: storm map, 4 views: <5 × 2400 × 1.0> -> <4 × 2400 × 0.5> particles`（改前算 5 套全量，改后 4 套半量、大厅停）。
- 命令：`python tools/test_perf.py --godot <Godot>`；`python tools/check_conventions.py`；`python tools/smoke_game.py <Godot> --project game`。
- PR 里写清：4 人风雪图的观感（雪密度）留给最终试玩，帧率未测。

## 不要做

- 不改 `AMOUNT`、粒子寿命、发射盒大小（它们决定 1–2 人时的观感）。
- 不在 `RSSettings` 里加新回调（框架区）；视图数用 `RSSettings.views` 读。
- 不改 `skier.gd`。

## 预计规模

新文件约 70 行（大部分是搬来的代码），`ski_game.gd` 约 −50 / +20 行，`test_perf.gd` 约 +25 行。
