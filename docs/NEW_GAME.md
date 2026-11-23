# 接入一个新项目

新项目只在 `game/scenes/<id>/` 下加文件，再加预览图、`game/i18n/en.json` 和 README 的条目。**不要改** `core`、菜单、`tools` 或测试里的项目列表：它们都从项目清单（`<id>_module.tres`，见 [ARCHITECTURE.md](ARCHITECTURE.md) 第 2 节）读取。

## 1. 生成骨架

```bash
python tools/new_game.py table_tennis --name 乒乓球 --en "Table Tennis"
<Godot> --headless --path game --import          # 生成 .gd.uid，提交时一起提交
```

`id` 用小写字母、数字和下划线，定下来就不要再改（存档、纪录、教学状态、派对赛都用它）。生成的文件：

| 文件 | 内容 |
|---|---|
| `scenes/<id>/<id>_game.gd/.tscn` | `extends RSPartyGame` 的占位玩法（倾斜左右移动，跟住目标得分），机器人可玩 |
| `scenes/<id>/<id>_rules.gd` | 规则和计分的纯函数，方便单元测试 |
| `scenes/<id>/<id>_hud.gd` | 本项目 HUD |
| `scenes/<id>/<id>_module.tres` | 清单，`ready = false`：菜单、单人、派对页不显示 |
| `tests/test_<id>.gd/.tscn` | 规则单元测试骨架 |

`en.json` 会追加名称和占位说明的英文。删除生成的项目：`python tools/new_game.py <id> --remove`。

## 2. 先跑起来

```bash
<Godot> --path game -- --game=<id> --demo=2                 # 隐藏的项目也能直接打开
<Godot> --headless --path game res://tests/test_<id>.tscn   # RS_<ID>_TESTS: 0 failures
python tools/smoke_game.py <Godot> --project game           # 所有清单里的项目和地图，包括隐藏的
python tools/smoke_test.py --games <id> --players 2         # 完整一局机器人比赛
```

## 3. 做玩法

- 回合流程只重写 `RSPartyGame` 的钩子（ARCHITECTURE 第 2 节的表），公共能力先看第 3 节；`core` 里没有的通用功能在 `core` 加接口，不写成项目私有。
- 多地图：在一个脚本里写 `const MAPS := [{"name": "中文", "en": "ENGLISH", ...}]`，`_maps()` 返回它，清单的 `maps_script` 指向这个脚本。`smoke_catalog.gd` 会检查两者一致。
- 机器人：`p.fake` 的玩家由项目驱动，难度用 `bot_error()` / `bot_ability()`。
- 中文文案用 `tr()`，英文写进 `en.json`（只追加）；`python tools/i18n_check.py` 会检查，清单里的 `name`、`desc` 也算。

## 4. 上线前（把 `ready` 改成 `true`）

`python tools/catalog.py --check`（CI 跑）要求每个 `ready` 项目：

- [ ] `preview` 是 `res://assets/previews/<id>.jpg`，图片已用 `python tools/capture_previews.py --games <id>` 生成并写进 `manifest.json`
- [ ] `lessons` 列出 `RSTutorial` 的步骤常量；需要新动作时先在 `RSTutorial` 加通用步骤
- [ ] `solo_goals` 是三档递增的分数（地图 1 的单局分数）
- [ ] `name`、`desc` 和每张地图的 `en` 都有英文

另外：

- [ ] 清单的 `oled`、`players`、`mode`、`ambience`、`order` 填好；需要进性能测试时设 `benchmark = true`
- [ ] README 的项目列表加一条
- [ ] `smoke_test.py --games <id> --all-maps --players 2` 和 `--players 4` 通过
- [ ] 素材来源按 `docs/ASSETS.md` 记录
