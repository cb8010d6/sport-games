# 57-00 概览：#57 剩余工作

Issue #57（框架小问题合集）。任务卡格式见 [README](README.md)。

## 已经合并 / 已提 PR

| 内容 | 状态 |
|---|---|
| 并列名次台阶高度、`finish_round` 防重入、`RSProfiles` 每帧 `duplicate(true)`、`send_ui` 统一去重、配色移出翻译 key、未翻译的 `Bot-%d` / `REPLAY`、游戏内基准加 2560×1440 | 已合并（PR #83） |
| 菜单 `_prompt()` 私建 `StyleBoxFlat` → `RSUi.glyph_style()`，并加源码扫描测试防回潮 | PR #93，未合并 |
| 画质管不到的开销：分屏视口的点光 / 聚光阴影图集随档位（1024 / 2048 / 4096 / 4096）；皮肤 SSS 只在高档以上开、alpha-to-coverage 只在 MSAA 生效时开 | PR #93，未合并 |
| HUD 动画字号量化（`RSPartyGame.draw_text()` 入口吸附到少数字号台阶，非 MSDF 路线） | PR #93，未合并 |

下面的卡默认 PR #93 会合入。如果 #93 被拒，它的三项回到待做，PR #93 的说明本身就可以当卡用。

## 还剩什么

| 卡 | 来源 | 状态说明 |
|---|---|---|
| [57-01](57-01-msdf-experiment.md) HUD 字体 MSDF 实验 | issue 正文“HUD 字号动画与非 MSDF 字体”；PR #93 只做了量化，MSDF 单列实验 | 要在有显示的机器上测一次内存和描边；结论可以是“不改” |
| [57-02](57-02-slot-guard.md) 比赛中玩家编号被改 | issue 正文第 7 条；维护者评论（10-25）的可达性核查 | **待确认**：核查结论是玩家无法在比赛中改号，只剩重连时 hub 分到不同号的风险。**已定：守卫档**（约 15 行，把号钉回原值），不做完整的中途换号 |
| [57-03](57-03-replay-buffer.md) `RSReplay` 录制限频 | issue 正文“每帧内存分配”第 2 条 | **已定：仍属 #57**，待领 |
| [57-04](57-04-basketball-alloc.md) 篮球每帧数组 | issue 正文“每帧内存分配”第 3 条 | **已定：仍属 #57**，待领；属于篮球项目区，不是框架区 |
| [57-05](57-05-local-shadow-tier.md) 低画质关闭点光 / 聚光阴影 | PR #93 说明“未含：低档关闭聚光阴影（观感变化大，建议维护者单独拍板）” | **已定：按卡里规则做**（低档关、中档 3–4 分屏关、其余按场景）；观感由用户最终试玩确认 |
| [57-06](57-06-rig-quality-refresh.md) 改画质后已建人物材质跟着更新 | PR #93 说明的局限：“菜单改画质只影响之后新建的 rig” | 待领（#93 合入后） |

## 依赖图

```
PR #93 ──┬── 57-01（量化之后再测 MSDF 是否还有必要）
         ├── 57-05（同在 settings.gd 的画质逻辑上）
         └── 57-06（改的是 #93 加的 human_rig 门控）
57-02、57-03、57-04 互不依赖，也不依赖 #93
```

57-05 提供的 `RSSettings.local_shadows(light)` 也被 [39-16](39-16-arena-lights-scoreboard.md)（场馆灯架）使用。

## 框架区

| 卡 | 框架区文件 |
|---|---|
| 57-01 | 可能改 `game/core/ui_kit.gd`（如果走“只给 HUD 字体开 MSDF”的方案）；字体 `.import` 属于素材区 |
| 57-02 | `game/core/party_game.gd` |
| 57-03 | `game/core/replay.gd`（另改滑板 / 滑雪 / 篮球三处调用，项目区） |
| 57-04 | 无（只改 `game/scenes/basketball/`） |
| 57-05 | `game/core/settings.gd` |
| 57-06 | `game/core/human_rig.gd`、`game/core/settings.gd` |

开放中的 PR 也在改相关文件：#78 改 `party_game.gd`（暂停 / 断线按键），#80 改 `controller_hub.gd` 和 `rs_controller.gd`（注册表上限与 roster 同步）。57-02 领取前先看这两个是否已合入。
