# 39-01 队伍纯逻辑 RSTeams 与按队排名

Issue #39 F5 · 区域：框架（`game/core/`）

## 目标 / 范围外

**目标：** 一个项目在清单里写 `mode = "versus"` 或 `"teams"` 后，`RSPartyGame` 在倒数开始时给每个参赛者分队（`Player.team`），`ranked_players()` 和 `finish_round()` 的名次按队计算。`mode = "individual"` 的现有 6 个项目行为完全不变。

**范围外：** 电脑补位（39-02）、视口和分屏（39-03）、成绩页文字 / OLED / 领奖台 / 派对积分展示（39-04）、任何具体项目的规则。

## 先读

1. `game/core/party_game.gd`：`Player` 类 24-38、`ordered()` 433-437、`ranked_players()` 506-511、`_add_player()` 514-525、`_to_lobby()` 559-569、`_start_countdown()` 572-589、`finish_round()` 592-634
2. `game/core/game_module.gd`（全文 28 行，`MODES` 和 `mode` 字段）
3. `game/core/catalog.gd` 27-33（`module(id, include_hidden)`）
4. `game/core/tournament.gd` 79-92（`record()` 按 `rank` 给积分）
5. `game/tests/catalog_cases.gd` 前 40 行（cases 文件写法）
6. `docs/ARCHITECTURE.md` 第 2 节“回合流程”、第 4 节（领奖台名次规则）

## 改动文件

- 新建 `game/core/teams.gd`（+ `.gd.uid`）—— 框架区
- `game/core/party_game.gd` —— 框架区，只加接线，净增不超过 30 行
- 新建 `game/tests/teams_cases.gd`（+ `.gd.uid`），`game/tests/test_shell.gd` 加 2 行注册

## 接口契约

后续 39-02 / 39-03 / 39-04 都依赖以下内容，名字和语义不要改。

```gdscript
# game/core/party_game.gd —— Player 新增两个字段（39-02 才用到 filler，但在这里一次加好）
class Player:
	var team := -1        ## 0 = 红队, 1 = 蓝队；-1 = 不分队（individual 模式，或还没开局）
	var filler := false   ## RSTeams 补位加入的电脑（39-02）；filler 一定也是 fake

# game/core/party_game.gd —— 新增钩子（都有默认实现，项目可以重写）
func _team_mode() -> int:                      ## RSTeams.Mode；默认读清单：RSTeams.mode_of(game_id())
func _team_size(count: int) -> int:            ## 每队人数；默认 RSTeams.default_size(_team_mode(), count)
func _assign_teams(list: Array, size: int) -> void:   ## 默认 RSTeams.assign(list, size)
func _team_score(members: Array) -> int:       ## 一队的分数；默认 RSTeams.sum_score(members)

# game/core/party_game.gd —— 现有函数的改动
# _add_player(c, fake) 改为 _add_player(c: RSController, fake: bool, filler := false) -> Player，在 views.add(p) 之前设 p.filler
# _start_countdown()：在 _apply_pending_map() 之后、views.layout() 之前调用 RSTeams.begin_round(self)
#   （补位电脑要在分屏布局和 _round_started 之前加入）
# _to_lobby()：开头调用 RSTeams.end_round(self)
# ranked_players()：if RSTeams.teamed(self): return RSTeams.ranked_players(self)；否则保持原代码
# finish_round()：名次改为 var places := RSTeams.places(self, list)，rank = places[i]；其余不动
```

```gdscript
# game/core/teams.gd
class_name RSTeams
extends RefCounted

enum Mode { INDIVIDUAL, VERSUS, TEAMS }
const MODE_IDS := ["individual", "versus", "teams"]   ## 必须等于 RSGameModule.MODES
const MAX_SIDE := 2
const NAMES := ["红队", "蓝队"]                         ## 翻译 key（39-04 才显示）
const COLORS := [Color("ef4444"), Color("3b82f6")]
const ACCESSIBLE_COLORS := [Color("d55e00"), Color("0072b2")]   ## RSSettings.color_safe 时用

static func mode_from_id(id: String) -> int            ## 未知 id → INDIVIDUAL
static func mode_of(game_id: String) -> int            ## RSCatalog.module(game_id, true) 的 mode；找不到 → INDIVIDUAL
static func default_size(mode: int, count: int) -> int ## INDIVIDUAL 0，VERSUS 1，TEAMS 2
static func teamed(game: RSPartyGame) -> bool          ## game._team_mode() != INDIVIDUAL
static func side_size(game: RSPartyGame, count: int) -> int   ## clampi(game._team_size(count), 1, MAX_SIDE)；不分队时 0
static func color(team: int) -> Color                  ## 按 color_safe 选色
static func team_name(team: int) -> String             ## RSLang.t(NAMES[team])

## 分队：list 按槽号升序，先真人（not fake）后电脑；按顺序交替 0, 1, 0, 1。
## 结果：H1 → 0，H2 → 1，H3 → 0，H4 → 1（3 个真人时第 4 人是电脑，落在 1 队）。
static func assign(list: Array, size: int) -> void

static func begin_round(game: RSPartyGame) -> void     ## 倒数开始：不分队时把所有人 team 设 -1 后返回；
                                                       ## 分队时 game._assign_teams(lineup(game), side_size(...))。
                                                       ## 39-02 在这里加补位，调用方不变。
static func end_round(game: RSPartyGame) -> void       ## 回大厅：所有人 team = -1。39-02 在这里移除补位电脑。
static func lineup(game: RSPartyGame) -> Array         ## 分队用的顺序（见 assign 的规则）
static func members(game: RSPartyGame, team: int) -> Array   ## 该队成员，按槽号升序
static func sum_score(list: Array) -> int              ## Player.score 之和
static func team_score(game: RSPartyGame, team: int) -> int  ## game._team_score(members(game, team))

## 排名：队按 team_score 降序（同分按队号升序），队内按个人分降序、同分按槽号升序。
static func ranked_players(game: RSPartyGame) -> Array

## 与 list（ranked_players() 的结果）一一对应的名次。
## 不分队：竞赛排名，和现在的成绩页一样（30/30/10 → 1, 1, 3）。
## 分队：队的名次 = 1 + 分数严格更高的队数，展开到每个成员（两队 → 1, 1, 2, 2；平局 → 1, 1, 1, 1）。
## RSTournament.record() 按这个 rank 给积分，所以胜队每人第 1 名积分、负队每人第 2 名积分。
static func places(game: RSPartyGame, list: Array) -> PackedInt32Array
```

调用关系：`RSPartyGame` → `RSTeams`（静态函数，参数传 game）；`RSTeams` 只读 `game.players`、调用 `game._team_*` 钩子，不持有状态，不建节点。

## 依赖与顺序

无前置。完成后 39-02、39-03、39-04 可以同时开工（它们各自只往 `teams.gd` 加函数、改 `begin_round` / `end_round` 的内部）。

## 验收

- 新增 `game/tests/teams_cases.gd`，至少覆盖：
  - `mode_from_id` 三个值和未知值；`MODE_IDS == RSGameModule.MODES`
  - 不分队：`ranked_players()` 顺序和 `places()` 与原逻辑一致（含 30/30/10 → 1, 1, 3）
  - VERSUS 2 人：1, 2；平分 1, 1
  - TEAMS 4 人：H1/H3 一队、H2/H4 一队；`places` 为 1, 1, 2, 2；两队平分为 1, 1, 1, 1
  - `begin_round` 后 `team` 正确，`end_round` 后全部为 -1
  - 用测试内的子类（`extends RSPartyGame`，重写 `_team_mode()`），不在树里运行，手动建 `Player`（写法参考 `test_shell.gd` 里的 `RSPartyGame.new()` 用例）
- 命令：`python tools/import_game.py --godot <Godot>`，`python tools/test_game.py --godot <Godot> --party`（`RS_SHELL_TESTS: 0 failures`、派对流程 PASS）
- `python tools/smoke_game.py <Godot> --project game` 通过（证明 6 个现有项目不受影响）
- `python tools/check_conventions.py`、`python tools/i18n_check.py`（本卡不新增可见文案）

## 不要做

- 不改 `RSTournament`、`RSPodium`、`RSPartyUi`、`RSPartyViews`（属于 39-03 / 39-04）。
- 不加新 autoload、存档字段或协议消息。
- 不改任何现有项目的清单 `mode`。
- `party_game.gd` 里不要写队伍规则，只写钩子和一行调用。

## 预计规模

`teams.gd` 约 150 行，`party_game.gd` 约 +25 / −5，测试约 150 行。
