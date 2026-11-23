# 57-04 篮球每帧数组分配

Issue #57“每帧内存分配”第 3 条 · 区域：项目（`game/scenes/basketball/`）

> 开工前提：维护者确认这一项仍属 #57（维护者 10-25 的评论里问过，清单没点名）。

## 目标 / 范围外

**目标：** 去掉篮球每个物理步（120 Hz）里的临时数组分配，行为逐位不变：
1. `basketball_game.gd` `_physics_process()` 每步新建的 `near := [[], [], [], []]`；
2. `RSHoopNet.advance()` 每次新建的 `local: Array[Vector3]`；
3. `RSHoopNet._cord()` 每根绳每次新建的四元素数组 `q`。

改为成员变量复用（`clear()` 后再填）或常量下标表。

**范围外：** 篮网的物理和外观；`RSReplay` 录制（57-03）；篮球其他文件。

## 先读

1. `game/scenes/basketball/basketball_game.gd` 571-608（`_physics_process`）
2. `game/scenes/basketball/hoop_net.gd` 60-82（`advance`）、83-142（`_step`，确认它只读 `balls`）、143-171（`_rebuild`、`_cord`）
3. `docs/CODING_STANDARDS.md`（类型标注规则）

## 改动文件

- `game/scenes/basketball/basketball_game.gd` —— 项目区（`basketball_game.gd` 953 行，改动不能让它超过 1000 行）
- `game/scenes/basketball/hoop_net.gd` —— 项目区

## 接口契约

不改任何对外接口：

- `RSHoopNet.advance(dt: float, balls: Array) -> void` 签名不变；内部用成员 `var _local: Array[Vector3] = []`，每次 `clear()` 后填。
- `basketball_game.gd` 用成员 `var _near: Array = [[], [], [], []]`（长度 = `RSBallCourt.COURTS`），每步开头对四个子数组 `clear()`。`advance()` 收到的仍是这四个数组；`RSHoopNet` 不得保存对它的引用（现状就不保存，改动后在注释里写明）。
- `_cord()`：四个角点改为四个局部 `Vector3` 变量，顶点顺序表 `[0, 2, 1, 0, 3, 2]` 改为类常量 `const QUAD := [0, 2, 1, 0, 3, 2]`，用 `match` 或小函数按下标取角点。

## 依赖与顺序

需要维护者先确认范围。与 57-03 可并行（都改 `basketball_game.gd`，位置不同）。

## 验收

- 行为不变：`python tools/smoke_game.py <Godot> --project game`（篮球 1 / 2 / 4 人分屏用例）通过；`python tools/smoke_test.py --games basketball --players 2` 通过（这是机器人跑的单局冒烟，不是试玩）
- 没有可靠的数组分配计数器（`Array` 不是 `Object`，`OBJECT_COUNT` 看不到），所以“不再分配”靠审查确认：PR 说明里列出三个函数改动前后的代码，`_physics_process`、`advance`、`_cord` 里不再出现数组字面量或新建数组
- `python tools/check_conventions.py`（无新增 SIZE 警告）

## 不要做

- 不改篮网的步长、阻尼、碰撞参数。
- 不拆分 `basketball_game.gd`（除非为了不超过 1000 行，且只抽出与本卡相关的部分）。
- 不改其他项目。

## 预计规模

两个文件共约 +15 / −10。
