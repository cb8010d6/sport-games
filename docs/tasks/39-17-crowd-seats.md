# 39-17 RSCrowd：按座位填观众、欢呼强度、换网格入口

Issue #39 F10（#58 P2 的 A2 观众 v2 的代码部分）· 区域：框架（`game/core/`）

## 目标 / 范围外

**目标：** 扩展现有 `RSCrowd`（不破坏滑板、滑雪的用法）：
1. `fill_seats()`：给一组座位变换（39-15 的 `seat_transforms`）按上座率填观众，随机但可复现；
2. 欢呼强度：项目调用 `cheer(mmi, intensity)`，观众的跳动 / 挥手幅度跟着变，由着色器做，不逐个改实例；
3. 换网格入口：#58 的观众 v2（MPFB 低模 + impostor）到了以后，只需要放进 `game/assets/shared/crowd/` 并改一个常量路径，`RSCrowd` 自动用新网格；没到就继续用现有胶囊小人。

**范围外：** 观众 v2 的模型、贴图、impostor 烘焙（#58 P2）；把滑板 / 滑雪的观众换成座位式（不改它们）；观众声音（#58 P6）。

## 先读

1. `game/core/crowd.gd`（全文 60 行：`SHIRTS`、`person_mesh()`、`place()`）
2. `game/shaders/crowd.gdshader`（全文：实例自定义数据 = 相位 / 节奏）
3. [39-15](39-15-arena-structures.md) 的 `seat_transforms` 签名和朝向约定（+Z 朝场地）
4. `game/scenes/ski/ski_course.gd` 895-900、`game/scenes/skate/skate_course.gd` 1415-1420（现有两处调用，必须保持可用）
5. #58 正文 A2 一行（`gh issue view 58`）

## 改动文件

- `game/core/crowd.gd` —— 框架区
- `game/shaders/crowd.gdshader`：加 `cheer` uniform
- `game/tests/test_arena.gd`：追加 `_test_crowd()`（与 39-16 / 39-18 各加各的函数，合并冲突时都保留）

## 接口契约

```gdscript
# game/core/crowd.gd（新增部分）
const V2_MESH := "res://assets/shared/crowd/crowd_person.tres"
	## #58 交付的观众 v2 网格（Mesh 资源，表面 0 = 衣服按实例色，表面 1 = 皮肤）；文件不存在时回退 person_mesh()

static func mesh() -> Mesh                 ## 有 V2_MESH 就加载它（缓存），否则 person_mesh()

## 在 seats 里按 occupancy（0..1）随机选座填人；rng 由调用方给（固定种子 → 同样的上座分布）。
## 返回一个 MultiMeshInstance3D（已加进 parent），实例颜色 = 衣服色，自定义数据 = (相位, 节奏, 0, 0)，和 place() 一致。
static func fill_seats(parent: Node, seats: Array[Transform3D], occupancy: float,
		rng: RandomNumberGenerator, shirts: Array = SHIRTS) -> MultiMeshInstance3D

## 欢呼强度 0..1：写 MultiMesh 材质的 cheer uniform（0 = 坐着轻微晃动，1 = 起立跳跃挥手）。
## 每个 MultiMeshInstance3D 一份材质覆盖（material_override），不影响其他观众组。
static func cheer(mmi: MultiMeshInstance3D, intensity: float) -> void

# place(parent, xforms, rng, shirts) 签名和行为不变，内部改用 mesh()。
```

着色器：新增 `uniform float cheer = 0.6;`，默认值必须让现有滑板 / 滑雪观众的动作和改动前一样（先读懂现有着色器的幅度，再选默认值）。

## 依赖与顺序

只依赖 39-15 的 `seat_transforms` 签名（测试里可以自己构造座位数组），**可以和 39-15 同时做**；合并在 39-15 之后（测试场景由 39-15 创建，如果本卡先合并，就自己建 `test_arena.gd` 场景，39-15 再往里加）。

## 验收

`test_arena.gd` 的 `_test_crowd()`：

- `fill_seats` 200 个座位、上座率 0.5：实例数约 100（同种子结果固定，写死期望值）；上座率 0 / 1 → 0 / 200
- 同一种子两次调用实例变换完全相同
- `cheer(mmi, 1.0)` 后该实例的材质 `cheer == 1.0`，另一个观众组不受影响
- `V2_MESH` 不存在时 `mesh()` 返回胶囊网格且不报错
- `place()` 的现有调用（构造一个与滑雪相同参数的调用）实例数和颜色与改动前一致

命令：`<Godot> --headless --path game res://tests/test_arena.tscn`（`RS_ARENA_TESTS: <n> checks, 0 failures`），`python tools/smoke_game.py <Godot> --project game`（滑板、滑雪仍能加载），`python tools/check_conventions.py`。

## 不要做

- 不改滑板、滑雪的代码和观众位置。
- 不下载或生成观众模型。
- 不为每个观众建节点。

## 预计规模

`crowd.gd` 约 +60，着色器约 +10，测试约 70 行。
