# 任务卡

大 issue 拆成小任务卡。一张卡 = 一个 PR，领取的人只读 [AGENTS.md](../../AGENTS.md) 和这张卡（加上卡里“先读”列出的几个文件），不需要先读懂整个项目。

## 怎么领一张卡

1. 在下面的索引里找状态为 `待领` 且“依赖”都已 `已合并` 的卡。状态为 `待确认` 的卡要先等维护者在 issue 里拍板，不要开工。
2. 从最新的 `dev` 建分支（`git fetch origin && git switch -c <你的前缀>/<卡号> origin/dev`），PR 目标 `dev`。
3. 只读 `AGENTS.md` 和这张卡；卡里“先读”的文件按给出的行号看。行号以写卡时的 `dev` 为准，文件变了就按函数名找。
4. 只改卡里“改动文件”列出的路径。需要改别的文件时，停下来在 PR 说明里提出。**框架区**（`game/core/`、`game/autoload/`、`game/scenes/menu/`、`game/project.godot`、`docs/ARCHITECTURE.md`）由维护者 / Claude 做，其他人要有维护者的明确许可。
5. 同一个 PR 里把索引中这张卡的状态改成 `已提 PR #<n>`；合并后由维护者改成 `已合并`。不要改别的卡的状态。
6. PR 标题带卡号（例如 `feat: RSTeams 纯逻辑（39-01）`），说明里写 `Part of #<issue>`，按卡里“验收”列出检查和结果，写清楚没验证的部分。
7. 发现卡里的接口写错了或不够用：在 PR 里说明并改卡（接口变更要同时改依赖这张卡的后续卡），不要悄悄偏离。

## 卡的格式

文件名 `docs/tasks/<issue>-<nn>-<slug>.md`，`nn` 两位数，同一 issue 内按建议顺序编号；`00` 留给概览。每张卡的开头一行写 issue、所属分项和区域，然后依次是这些小节（都必须有，没有内容就写“无”）：

| 小节 | 写什么 |
|---|---|
| 目标 / 范围外 | 做完后什么成立；明确不在这张卡里的事 |
| 先读 | 最多 6 个文件，能给行号就给行号 |
| 改动文件 | 准确路径；尽量新建文件；框架区文件单独标出 |
| 接口契约 | 函数签名、信号、数据结构、谁调用谁。后续卡依赖的接口必须在这里写死 |
| 依赖与顺序 | 依赖哪些卡 / PR；哪些卡可以同时做 |
| 验收 | 要新增和运行的无界面测试、具体命令。不做完整试玩、截图巡检或大规模基准（用户最后自己试玩） |
| 不要做 | 容易越界的事 |
| 预计规模 | 改动行数估计。目标一张卡一个 PR、约 400 行以内（新建的独立文件和测试可以多一些，但单文件不超过 1000 行） |

状态只写在本页索引里，卡本身不写状态，避免两处不一致。

## 通用约定

- `<Godot>` 指 Godot 4.7.2 控制台版可执行文件。第一次跑测试前、以及新增 `class_name` 之后，先执行 `python tools/import_game.py --godot <Godot>`；提交新 `.gd` 时带上 `.gd.uid`。
- **纯逻辑单元测试**：新建 `game/tests/<主题>_cases.gd`（`extends RefCounted`，提供 `static func run(check: Callable) -> void`，写法照 `game/tests/catalog_cases.gd`），在 `game/tests/test_shell.gd` 里加一行 `preload` 和一行 `run(_check)`。用 `python tools/test_game.py --godot <Godot>` 运行，期望输出含 `RS_SHELL_TESTS: 0 failures`。CI 已经在跑这个入口，不用改 CI。
- 需要独立场景的测试（检查项很多或要建 3D 节点）：`game/tests/test_<主题>.gd/.tscn`，结束时打印 `RS_<主题>_TESTS: <n> checks, 0 failures`，用 `<Godot> --headless --path game res://tests/test_<主题>.tscn` 运行。要进 CI 的话在 PR 里提出，由工具区负责人接入。
- 提交前照 `AGENTS.md`“提交前必须通过”跑一遍；改了游戏代码再跑 `python tools/smoke_game.py <Godot> --project game`。
- 文案：中文原文是 key，用 `tr()` / `RSLang.t()`；`game/i18n/en.json` 只追加，跑 `python tools/i18n_check.py`。
- 共享且容易冲突的文件（`game/core/party_game.gd`、`game/core/party_ui.gd`、`game/core/tutorial.gd`、`game/tests/test_shell.gd`、`game/i18n/en.json`）只做小而集中的修改，不重排格式。`party_game.gd` 已超过 1000 行（SIZE 警告），新逻辑放进新文件，这个文件只加接线。

## #39 框架：新项目共用玩法模块（F5–F10）

概览、已合并内容和依赖图见 [39-00 概览](39-00-overview.md)。全部卡都改 `game/core/`，属于框架区。

| 卡 | 内容 | 状态 | 依赖 | 区域 |
|---|---|---|---|---|
| [39-01](39-01-teams-core.md) | 队伍纯逻辑 `RSTeams`、`Player.team`、按队排名 | 待领 | — | 框架 |
| [39-02](39-02-teams-fill.md) | 电脑补位（人数不够时补满两队） | 待领 | 39-01 | 框架 |
| [39-03](39-03-teams-views.md) | 参赛者与视口分离、按队分屏、端线朝向 | 待领 | 39-01 | 框架 |
| [39-04](39-04-teams-results.md) | 成绩页、OLED、派对积分、领奖台按队显示 | 待领 | 39-01 | 框架 |
| [39-05](39-05-ball-flight.md) | `RSBallFlight` 飞行、受力与碰撞 | 待领 | — | 框架 |
| [39-06](39-06-ball-hit-predict.md) | 击球响应、落点预测、瞄准 | 待领 | 39-05 | 框架 |
| [39-07](39-07-swing-peak.md) | `RSSwingDetector` 峰值候选、`reset()`、新鲜度 | 待领 | — | 框架 |
| [39-08](39-08-swing-classify.md) | `RSSwingClassifier` 正反手 / 高低 / 速度 / 拍面 | 待领 | 39-07 的数据结构（可并行） | 框架 |
| [39-09](39-09-tutorial-swing.md) | 教学通用 `SWING` 步骤 | 待领 | 39-07 | 框架 |
| [39-10](39-10-water-waves.md) | `RSWater` 波浪高度函数（CPU / GPU 同一公式） | 待领 | — | 框架 |
| [39-11](39-11-water-surface.md) | 水面网格、着色器、泡沫、海湾 / 湖泊预设 | 待领 | 39-10 | 框架 |
| [39-12](39-12-water-wake.md) | 尾迹与浪花接口 | 待领 | 39-11 | 框架 |
| [39-13](39-13-race-track.md) | `RSRaceTrack` 路线进度、检查点、实时名次 | 待领 | — | 框架 |
| [39-14](39-14-race-follower.md) | `RSRaceFollower` 机器人跟线、速度曲线、追赶 | 待领 | 39-13 | 框架 |
| [39-15](39-15-arena-structures.md) | `RSArena` 看台、围挡、广告板 | 待领 | — | 框架 |
| [39-16](39-16-arena-lights-scoreboard.md) | `RSArena` 灯架与记分牌 | 待领 | 39-15 | 框架 |
| [39-17](39-17-crowd-seats.md) | `RSCrowd` 按座位填观众、欢呼强度、换网格入口 | 待领 | 39-15 的座位数据 | 框架 |
| [39-18](39-18-arena-hall.md) | 室内场馆壳与室内灯光预设 | 待领 | 39-15 | 框架 |

## #57 框架小问题合集（剩余项）

概览见 [57-00 概览](57-00-overview.md)。

| 卡 | 内容 | 状态 | 依赖 | 区域 |
|---|---|---|---|---|
| [57-01](57-01-msdf-experiment.md) | HUD 字体 MSDF 导入实验（测量后决定改不改） | 待领 | PR #93 | 素材 + 框架 |
| [57-02](57-02-slot-guard.md) | 比赛中玩家编号被改时钉回原号（守卫档） | 待领 | — | 框架 |
| [57-03](57-03-replay-buffer.md) | `RSReplay` 录制限频，去掉每帧 `pop_front` | 待领 | — | 框架 + 项目 |
| [57-04](57-04-basketball-alloc.md) | 篮球每帧数组分配（`near`、篮网） | 待领 | — | 项目（篮球） |
| [57-05](57-05-local-shadow-tier.md) | 低画质关闭点光 / 聚光阴影 | 待领 | PR #93 | 框架 |
| [57-06](57-06-rig-quality-refresh.md) | 改画质后已建人物材质跟着更新 | 待领 | PR #93 | 框架 |
