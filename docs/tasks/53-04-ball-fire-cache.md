# 53-04 篮球火焰粒子：资源共享、开场预热

Issue #53 · 分项 1.7 · 区域：项目（`game/scenes/basketball/`）

## 目标 / 范围外

**目标**：球进入“火热”状态时，`RSBasketball._make_fire()` 现场新建 QuadMesh、StandardMaterial3D、两个 Gradient、GradientTexture2D、ParticleProcessMaterial、Curve、CurveTexture、GradientTexture1D 共 9 个资源，第一次出现还要编译粒子着色器，比赛中可能卡一下。改成：

1. 这 9 个资源做成静态缓存，所有球的火焰共用一份（照本文件里 `mesh()` / `material()` 的静态缓存写法）；
2. 篮球场景加载时预热一次（建一个火焰节点，发射 1 帧后删掉），让着色器在开场前编译。

**范围外**：火焰外观；篮球每帧数组分配（57-04）；篮网（`RSHoopNet`）。

## 先读

1. `game/scenes/basketball/ball.gd:14-48`（`_mesh`、`_mats` 静态缓存和 `mesh()` / `material()`）、`:110-116`（`set_fire`）、`:150-201`（`_make_fire`）
2. `game/scenes/basketball/basketball_game.gd` 的场景加载段（搜 `RSSfx.warm_up`，预热放在它旁边）
3. `game/tests/test_perf.gd:26-35`（`_run()`）

## 改动文件

- `game/scenes/basketball/ball.gd`
- `game/scenes/basketball/basketball_game.gd`（加 1 行预热调用）
- `game/tests/test_perf.gd`（加一个检查函数）

## 接口契约

```gdscript
# game/scenes/basketball/ball.gd
static var _fire_res: Array = []    ## [QuadMesh(带材质), ParticleProcessMaterial]，第一次用时建

static func fire_resources() -> Array
	## 返回共享的 [draw_pass_1 网格, process_material]；内容与现在 _make_fire() 里建的完全相同。

func _make_fire() -> GPUParticles3D
	## 只新建 GPUParticles3D 节点本身（amount / lifetime / aabb 等节点属性照旧），网格和处理材质取 fire_resources()。

static func warm_up_fire(parent: Node) -> void
	## 建一个火焰节点挂到 parent、emitting = true，下一帧 queue_free。basketball_game 加载时调用一次。
```

- 共享资源不能在运行中被改（`set_fire` 只改节点的 `emitting` 和 `layers`，现在也没有改材质，保持这样）。

## 依赖与顺序

无依赖。57-04 改 `basketball_game.gd` 的每帧逻辑，本卡只在加载段加 1 行，冲突很小；两张卡同时进行时，后合入的一方合并 dev 即可。

## 验收

- `game/tests/test_perf.gd` 新增 `_ball_fire_shared()`（不需要角色模型）：
  - 建两个 `RSBasketball.new()`，各 `set_fire(true)`；断言两个火焰节点的 `process_material` 和 `draw_pass_1` 是同一个对象（`==` 比较引用）；
  - 统计第二颗球着火时新建的 `Resource` 数：在 `set_fire` 前后比较 `Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)`，断言差值 ≤ 1（只允许节点内部可能的资源）；
  - 打印 `RS_PERF_FIRE: resources per new fire 9 -> <n>`。
- 命令：`python tools/test_perf.py --godot <Godot>`；`python tools/check_conventions.py`；`python tools/smoke_game.py <Godot> --project game`。
- PR 里写清：比赛中卡顿是否消失没有在有显示的机器上测，留给最终试玩。

## 不要做

- 不改火焰的颜色、数量、寿命。
- 不把火焰挪到 `game/core/` 或 `RSVfx`（#58 的 58-26 `RSVfx` 以后可以收编，这里不提前做）。

## 预计规模

`ball.gd` 约 +30 / −10 行，`basketball_game.gd` +1 行，`test_perf.gd` 约 +25 行。
