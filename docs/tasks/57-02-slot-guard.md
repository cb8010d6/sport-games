# 57-02 比赛中玩家编号被改时钉回原号（守卫档）

Issue #57 正文第 7 条 · 区域：框架（`game/core/party_game.gd`）

> 开工前提：维护者在 #57 里确认采用“守卫档”。维护者 10-25 的核查结论是：玩家无法在比赛中改号（hub 的 `set_player` 只有游戏命令通道一个入口，游戏端 `ControllerHub.set_player()` 目前没有调用方）；剩下的风险是 hub 重启或偏好变化后手柄在比赛中重连、被分到不同的号。如果维护者选了“完整的中途换号”（移除并重新加入玩家、重建视图，约 60–90 行、跨 4–5 个文件），这张卡作废，另写一张。

## 目标 / 范围外

**目标：** 一个玩家加入时的号码记在 `Player` 上；之后如果 roster 把这个手柄的号码改了，游戏不改视图和图层，而是用现成的 `set_player` 命令请 hub 把号码改回原值，并且在改回之前本地仍按原号显示、计分、排名。加一条回归测试。

**范围外：** 支持真正的中途换号；hub 侧的分号策略；大厅里的换号（大厅里号码变化按现有 `_sync_players` 逻辑处理，见下）。

## 先读

1. `game/core/party_game.gd`：`Player` 24-38、`_process()` 363-410、`_add_player()` 514-525、`_sync_players()` 538-556
2. `game/core/party_views.gd` 33-59（`cull_mask = 1 | (1 << p.c.player)` 在加入时固定）
3. `game/autoload/controller_hub.gd` 137-138（`set_player`）、282-296（`_apply_roster`、`roster_changed`）
4. `game/core/rs_controller.gd` 140-155（`apply_roster` 直接覆盖 `player`）
5. `game/scenes/skate/skate_game.gd` 150-157、`game/scenes/skate/skater.gd` 989-994（号码烘焙进图层的例子）
6. `game/tests/test_lifecycle.gd`（UDP 合成 roster 的现有测试写法，找 `roster` 相关用例）

## 改动文件

- `game/core/party_game.gd` —— 框架区（约 +20 行）
- `game/tests/test_lifecycle.gd` 或新建 `game/tests/slot_guard_cases.gd`（注册进 `test_shell.gd`），二选一，优先后者（不需要真实场景）

## 接口契约

```gdscript
# game/core/party_game.gd
class Player:
	var slot := 0            ## 加入时的号码（_add_player 里设为 c.player）；视图图层、HUD、纪录都以它为准

const SLOT_PIN_INTERVAL := 1.0   ## s：同一玩家两次请求改回之间的最短间隔

## 每帧在 LOBBY 以外的阶段调用（_process 里 match 之前一行）。
## 对每个真人（not p.fake）：p.c.player != p.slot 时，若距上次请求超过 SLOT_PIN_INTERVAL，调用 _pin_slot(p)。
func _guard_slots() -> void

## 请 hub 改回原号。测试子类重写它来记录调用。
func _pin_slot(p: Player) -> void:
	ControllerHub.set_player(p.c.id, p.slot)
```

规则：

- 大厅（LOBBY）：`_sync_players()` 发现已加入玩家的 `c.player != p.slot` 时，移除该玩家（`_remove_player`），下一帧按新号重新加入。大厅里重建视图代价很小，也不影响比分。
- 比赛中（COUNTDOWN / PLAY / RESULTS）：不移除、不重建；`_guard_slots()` 负责钉回。
- 本地显示和计分：本卡**不**把框架里所有 `p.c.player` 换成 `p.slot`（改动面太大）。钉回通常在一个 roster 周期内完成；在此期间的短暂错号只影响显示。若维护者要求“改回之前也必须完全正确”，在 PR 里提出，改为完整方案。
- 测试模式（`RS_TEST_MODE=1`）下 `ControllerHub` 不向 hub 发消息，所以测试只验证 `_pin_slot` 被调用，不验证 hub 行为。

## 依赖与顺序

需要维护者先确认（见开头）。领取前看 PR #78（改 `party_game.gd`）、#80（改 `controller_hub.gd` / `rs_controller.gd`）是否已合入，未合入时避开它们改的函数。

## 验收

- `slot_guard_cases.gd`：
  - 加入时 `p.slot == c.player`
  - PLAY 阶段把 `c.player` 从 2 改成 3：`_guard_slots()` 调用一次 `_pin_slot`；同一秒内再调不重复；超过 `SLOT_PIN_INTERVAL` 后再调一次
  - 号码改回 2 后不再调用
  - `p.fake` 的玩家不处理
  - LOBBY 阶段号码变化：`_sync_players()` 后旧 `Player` 被移除
- 命令：`python tools/test_game.py --godot <Godot> --party`，`python tools/test_lifecycle.py --godot <Godot> --games plane archery bowling`，`python tools/smoke_game.py <Godot> --project game`

## 不要做

- 不新增协议消息（用现有 `set_player`）。
- 不改 hub。
- 不在比赛中移除或重新加入玩家。

## 预计规模

`party_game.gd` 约 +20，测试约 80 行。
