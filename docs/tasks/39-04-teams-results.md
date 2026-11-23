# 39-04 成绩页、OLED、派对积分、领奖台按队显示

Issue #39 F5 · 区域：框架（`game/core/`）

## 目标 / 范围外

**目标：** 分队项目结束时，成绩页按队分组（队名次、队名、队分，下面列出队员）；大厅显示本局配对预览；手柄 OLED 显示队名次；派对积分全队同名次（依赖 39-01 的 `places`，`RSTournament` 本身不改）；`RSPodium` 能直接按给定名次摆台，两队时胜队两人站第一高度、负队两人站第二高度。不分队项目的文字、积分、领奖台完全不变。

**范围外：** 派对总领奖台（`show_tournament_podium`，仍按个人积分）；“整场派对 2v2 合计积分”（roadmap 待决定事项，不在本卡）；项目里的领奖台人物姿势和镜头。

## 先读

1. [39-01](39-01-teams-core.md) 的接口契约（`places()` 的语义）
2. `game/core/party_game.gd` `finish_round()` 592-634
3. `game/core/party_ui.gd` `update_lobby()` 76-101、`set_results()` 187-194
4. `game/core/podium.gd` 69-130（`reset`、`present`、`rank`、`_local_spot`）
5. `game/tests/test_podium.gd` 中 math 部分（`python tools/test_podium.py --math-only` 跑的用例）
6. `docs/ARCHITECTURE.md` 第 4 节第 1 段（领奖台名次与台面规则）

## 改动文件

- `game/core/teams.gd` —— 框架区：新增 `result_lines`、`lobby_line`
- `game/core/party_game.gd` —— 框架区：`finish_round()` 分队时用 `RSTeams.result_lines`（约 +8 / −3）
- `game/core/party_ui.gd` —— 框架区：`update_lobby()` 分队时追加一行配对预览（约 +2）
- `game/core/podium.gd` —— 框架区：新增 `present_places()`，`present()` 改为算出名次后调用它
- `game/tests/teams_cases.gd`、`game/tests/test_podium.gd`：追加用例
- `game/i18n/en.json`：追加本卡新文案
- `docs/ARCHITECTURE.md` 第 2 节“回合流程”加一段“对战与组队”、第 3 节表格加一行 —— 框架区（F5 线的最后一张卡负责写文档；如果 39-02 / 39-03 后合入，由最后合入的那张补全）

## 接口契约

```gdscript
# game/core/teams.gd
## 分队时的成绩页正文。list / places 来自 finish_round（ranked_players() 与 RSTeams.places()）。
## 每队一块：
##   [font_size=30][color=<名次色>]第 %d 名[/color]  [color=<队色>]%s[/color]  %d 分[/font_size]   ← 名次、队名、队分
##   每个队员一行：[color=<玩家色>]P%d[/color]  名字 · _result_detail(p)
## 名次色沿用 RSPodium.TRIMS（超过 3 用 RSUi.TEXT_MUTED），和现在个人成绩页一致。
static func result_lines(game: RSPartyGame, list: Array, places: PackedInt32Array) -> PackedStringArray

## 大厅配对预览（用 assign 的同一规则对“当前在场者 + 将补位的电脑”做纯计算，不改任何 Player）：
## "红队：P1、P3　蓝队：P2、电脑"。不分队返回 ""。
static func lobby_line(game: RSPartyGame) -> String
```

```gdscript
# game/core/party_game.gd finish_round()
# 分队时：lines 先放 RSTeams.result_lines(self, list, places)，循环里不再追加个人那两行；
#   新纪录行改为 tr("P%d 新纪录！") % p.c.player（个人模式仍是 tr("新纪录！")）。
# OLED：main 仍是 "#%d" % rank（队名次），sub 改为 "%d PTS" % RSTeams.team_score(self, p.team)。
# results / RSTournament.record 不变（39-01 已让 rank = 队名次；39-02 已过滤补位电脑）。
```

```gdscript
# game/core/podium.gd
## 按给定名次摆台。places[i] 是 ranked_players() 第 i 人的名次（1..4，非递减），最多 4 个。
## 站位、台面高度、奖牌色沿用现有规则（_local_spot 按 rank(i) 取高度）。
func present_places(places: PackedInt32Array) -> void
## present(scores) 不改签名：先用原来的竞赛排名算出 places，再调用 present_places(places)。行为必须逐项不变。
func present(scores: PackedInt64Array) -> void
```

项目侧用法（写进 ARCHITECTURE）：分队项目领奖时调用 `_podium.present_places(RSTeams.places(self, ranked_players()))`，不要伪造个人分数数组去凑名次。

新增文案（`en.json` 追加）：`"红队"`、`"蓝队"`、`"红队：%s　蓝队：%s"`、`"P%d 新纪录！"`、`"[font_size=30][color=#%s]第 %d 名[/color]  [color=#%s]%s[/color]  %d 分[/font_size]"`（如果 39-02 还没合入，`"电脑"` 也在这里加；重复的 key 只留一份）。

## 依赖与顺序

依赖 39-01。可与 39-02、39-03 同时做。

## 验收

- `teams_cases.gd`：2v2 结果文字含两个队块、队名和队分；平局两队都是“第 1 名”；`lobby_line` 在 3 个真人时显示一个“电脑”；不分队时 `result_lines` 不被调用、成绩页文字与改动前逐字相同（对照一个固定输入）
- `test_podium.gd`：`present_places([1, 1, 2, 2])` 的 `rank()` 和台面高度；任意分数数组下 `present(scores)` 与“先算名次再 `present_places`”结果一致
- 命令：`python tools/test_game.py --godot <Godot> --party`，`python tools/test_podium.py --godot <Godot> --math-only`，`python tools/i18n_check.py`，`python tools/smoke_game.py <Godot> --project game`

## 不要做

- 不改 `RSTournament`（积分表、缺席规则都不动）。
- 不改派对总领奖台。
- 成绩页颜色写在代码里，不要写进翻译 key（#57 已经把这类 key 清理过）。

## 预计规模

`teams.gd` 约 +60，`podium.gd` 约 +10 / −8，`party_game.gd` 约 +8，`party_ui.gd` +2，测试约 80 行，文档约 15 行。
