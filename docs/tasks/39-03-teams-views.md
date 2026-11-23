# 39-03 参赛者与视口分离、按队分屏、端线朝向

Issue #39 F5 · 区域：框架（`game/core/`）

## 目标 / 范围外

**目标：**
1. 不是每个参赛者都需要分屏格子：补位电脑永远没有；分队项目里的单人电脑对手也没有（1 个真人打电脑时真人占满全屏）。`--demo=N` 机器人和不分队项目里的单人电脑保持现在的格子。
2. 分队项目的分屏按队排列：红队在左、蓝队在右（2 格左右、3–4 格按列）。
3. 给项目一个统一的“这队在场地哪一端”的符号，项目据此把 `p.cam` 放到自己端线后面。

**范围外：** 镜头具体怎么跟球（项目自己做）；成绩页（39-04）。

## 先读

1. [39-01](39-01-teams-core.md) 的接口契约
2. `game/core/party_views.gd`（全文 79 行：`add()` 33-59、`remove()` 61-62、`layout()` 65-79、`_count_views()` 28-30）
3. `game/core/party_game.gd`：`Player.popup()` 36-37、`benchmark_viewports()` 233-242、`_start_countdown()` 572-589（`p.hud.popups.clear()`）、`draw_clock()` 907-935
4. `game/core/settings.gd` 263-271（`set_views()`）
5. `game/core/teams.gd`（39-01 合入后的版本）
6. [乒乓球 D0 设计](../TABLE_TENNIS_DESIGN.md)“人数、队伍与一局流程”表的“视口提案”一列

## 改动文件

- `game/core/party_views.gd` —— 框架区
- `game/core/party_game.gd` —— 框架区：`Player.popup`、`benchmark_viewports`、`_start_countdown` 三处对 `hud` / `cam` 判空；`draw_clock()`（907-935）里的 `players.size()` 改为 `views.viewers().size()`（计时牌位置跟着实际格子数走）。共约 6 行
- `game/core/teams.gd` —— 框架区：新增 `wants_view` / `view_order` / `side`
- `game/tests/teams_cases.gd`：追加用例

## 接口契约

```gdscript
# game/core/teams.gd
## 这个参赛者要不要分屏格子。规则：p.filler → false；teamed(game) 且 p.c.kind == "bot"（单人电脑）→ false；其余 true。
static func wants_view(game: RSPartyGame, p: RSPartyGame.Player) -> bool

## 有格子的参赛者的排列顺序。不分队：game.ordered() 里有格子的人（和现在一样，按槽号）。
## 分队：先红队后蓝队，队内按槽号；layout() 按“列优先”摆放，使红队在左列、蓝队在右列。
static func view_order(game: RSPartyGame) -> Array

## 这队守哪一端：红队 +1.0（站在 +Z 端、面向 -Z，也就是相机默认朝向），蓝队 -1.0；不分队返回 1.0。
static func side(team: int) -> float
```

```gdscript
# game/core/party_views.gd
func add(p: RSPartyGame.Player) -> void
	## RSTeams.wants_view(game, p) 为 false 时直接返回：p.cell、p.cam、p.hud 保持 null。
func remove(p) -> void             ## p.cell 为 null 时什么都不做
func viewers() -> Array            ## RSTeams.view_order(game)；layout() 和 _count_views() 都用它
func layout() -> void
	## n = viewers().size()。不分队时摆法和现在完全一样。
	## 分队时：n == 2 左右；n == 3 / 4 按列优先，第 0 列 = 红队，第 1 列 = 蓝队（列里不足两人时下格留空）。
```

约定（写进 `party_views.gd` 的类注释）：**没有格子的参赛者 `cam`、`hud`、`cell` 都是 `null`**，项目代码要判空；它们仍在 `game.players` 里、照常计分和排名。`Player.popup()` 对没有 `hud` 的参赛者什么都不做。

`RSSettings.set_views()` 收到的数量是 `viewers().size()`（真正渲染的视口数），阴影分档跟着它走。

注意：分队要到倒数开始（`RSTeams.begin_round`）才确定，而大部分格子在大厅加入时就建好了。`layout()` 在 `_start_countdown()` 里于分队之后调用，所以顺序正确；`add()` 时只需要 `wants_view` 的判断（它只看 `filler` 和 `kind`，不看 `team`）。

## 依赖与顺序

依赖 39-01。可与 39-02、39-04 同时做。

## 验收

- `teams_cases.gd` 新增（在树里建一个最小的测试游戏场景，或只测 `RSTeams` 的纯函数 + `RSPartyViews` 的矩形计算）：
  - 补位电脑 `wants_view` 为 false，`add()` 后 `cell == null`
  - 分队 + 单人电脑：只有真人有格子，`viewers().size() == 1`
  - 不分队项目（含单人电脑、demo）：格子数量和顺序与改动前相同
  - 分队 4 人：红队两人在左列、蓝队两人在右列；2 人：红左蓝右
  - `side(0) == 1.0`，`side(1) == -1.0`
- 命令：`python tools/test_game.py --godot <Godot> --party`，`python tools/smoke_game.py <Godot> --project game`
- `python tools/test_camera_comfort.py --godot <Godot> --ui-only`、`python tools/test_text_size.py --godot <Godot> --ui-only`（现有分屏布局检查不变）

## 不要做

- 不改现有 6 个项目的分屏摆法。
- 不新增“观众视角”或空格子里的画面（3 格时第 4 格留空，和现在一样）。
- 不移动各项目自己的相机代码。

## 预计规模

`party_views.gd` 约 +25 / −8，`teams.gd` 约 +40，`party_game.gd` 约 +5，测试约 100 行。
