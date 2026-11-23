# 39-02 电脑补位

Issue #39 F5 · 区域：框架（`game/core/`）

## 目标 / 范围外

**目标：** 分队项目开局时人数不够（例如 3 个真人打 2v2、1 个真人打 1v1），由电脑补满两队。补位电脑由项目像 `--demo` 机器人一样驱动（`p.fake`），不写纪录、不拿挑战星、不进派对积分，回大厅时移除。

**范围外：** 补位电脑有没有分屏格子（39-03 决定：没有）；成绩页怎么显示电脑（39-04）；电脑怎么打（各项目自己写）。

## 先读

1. [39-01](39-01-teams-core.md) 的接口契约（`Player.filler`、`begin_round` / `end_round`、`_add_player(c, fake, filler)`）
2. `game/core/teams.gd`（39-01 合入后的版本）
3. `game/core/party_game.gd`：`_ready()` 296-311（demo 机器人和单人电脑怎么建）、`color_of` / `name_of` / `can_record` 440-453、`_remove_player()` 528-535、`finish_round()` 592-634（`results` 数组）
4. `game/core/solo.gd` 28-35（`active()`、`opponent_slot()`）
5. `game/core/tournament.gd` 79-114（`record()`、`missing()`）
6. [乒乓球 D0 设计](../TABLE_TENNIS_DESIGN.md)“人数、队伍与一局流程”表（1–4 个真人时的配对和补位需求）

## 改动文件

- `game/core/teams.gd` —— 框架区：新增 `fill()` / `clear()`，在 `begin_round` / `end_round` 里调用
- `game/core/party_game.gd` —— 框架区：`color_of`、`finish_round` 里 `results.append` 两处小改（共约 4 行）
- `game/tests/teams_cases.gd`：追加用例
- `game/i18n/en.json`：追加 `"电脑"`

## 接口契约

```gdscript
# game/core/teams.gd
const FILLER_ID := -10          ## 补位电脑的 controller id = FILLER_ID - k（k = 0, 1, …）。
                                ## 真实手柄是 0..255，单人电脑是 -1，demo 机器人是 200+，不会冲突。
const BOT_COLOR := RSUi.TEXT_MUTED

## 在 begin_round 里、分队之前调用。需要的总人数 = 2 * side_size(game, 当前人数)；
## 不够时用空闲的槽号（1..4 里没人用的，从小到大）新建 RSController：
##   id = FILLER_ID - k, player = 空闲槽号, kind = "bot", display_name = RSLang.t("电脑"), connected = true
## 然后 game._add_player(c, true, true)。不分队时什么都不做。
static func fill(game: RSPartyGame) -> void

## 在 end_round 里调用：对所有 p.filler 的玩家调用 game._remove_player(p.c.id)。
static func clear(game: RSPartyGame) -> void

static func fillers(game: RSPartyGame) -> Array   ## 当前的补位电脑
```

`party_game.gd` 的两处改动：

```gdscript
func color_of(p: Player) -> Color:
	return RSTeams.BOT_COLOR if p.filler else RSProfiles.player_color(p.c.player)

# finish_round()：补位电脑不进 results（派对积分），其余照旧
if not p.filler:
	results.append({"slot": p.c.player, "rank": rank, "score": p.score})
```

规则：

- 单人模式（`RSSolo`）已有的电脑对手算一个电脑参赛者，`fill` 不再给它补第二个对手，只补到够人数为止。
- `--demo=N` 的机器人算参赛者；`--demo=3` 打 2v2 时补 1 个电脑。
- 补位电脑在倒数开始时才加入，大厅的准备 / 开局判断看不到它们；比赛中断线、暂停、重开（`restart_round` 经过 `_to_lobby`）都会先 `clear` 再在下一次倒数重新 `fill`。
- `name_of(p)` 不用改：`fake` 的玩家本来就显示 `c.display_name`。
- `can_record(p)` 不用改：`fake` 已经不能写纪录。
- 39-03 合入之前，补位电脑会像普通玩家一样得到一个分屏格子，这是预期的中间状态。

## 依赖与顺序

依赖 39-01。可以和 39-03、39-04 同时做：三张卡都改 `teams.gd`，但各加各的函数；`begin_round` / `end_round` 里只加一行调用，合并冲突时保留双方的行。

## 验收

- `teams_cases.gd` 新增：
  - VERSUS 1 个真人 → 补 1 个电脑；2 个真人 → 不补
  - TEAMS 3 个真人 → 补 1 个，槽号是唯一空着的那个，id 为 -10；1 个真人 → 补 3 个，id -10 / -11 / -12
  - 单人模式（`RSSolo` 激活）VERSUS → 不补
  - `end_round` 后补位电脑从 `game.players` 消失
  - `finish_round` 的 `results`（用 `RSTournament` 激活时的积分验证，或直接检查传给 `RSTournament.record` 的行）不含补位电脑
  - 不分队项目调用 `fill` 不加人
- 测试里的 `game` 不在场景树里时 `_add_player` 会调 `views.add()`：用 39-01 里同样的测试子类，必要时在测试子类里重写 `_player_added` 并给 `views` 一个最小替身；不要为了测试改生产代码的结构。
- 命令：`python tools/test_game.py --godot <Godot> --party`，`python tools/smoke_game.py <Godot> --project game`，`python tools/i18n_check.py`

## 不要做

- 不给补位电脑建档案、头像或玩家色。
- 不改 `RSTournament.record()`（补位电脑在调用方就过滤掉）。
- 不在大厅阶段就加补位电脑（大厅的配对预览由 39-04 用纯计算显示）。

## 预计规模

`teams.gd` 约 +50，`party_game.gd` 约 +4，测试约 100 行，`en.json` +1。
