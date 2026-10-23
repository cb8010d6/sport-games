# 架构

本文说明代码分几层、谁可以依赖谁、每个公共模块负责什么，以及新功能应该放在哪里。写代码的规则见 [CODING_STANDARDS.md](CODING_STANDARDS.md)，审查清单见 [REVIEW_CHECKLIST.md](REVIEW_CHECKLIST.md)。

**修改本文需要维护者同意**：先动架构文档，再动代码，不允许代码和文档不一致。

## 1. 总览

```
手机网页 / 模拟器 ──WSS──┐
Regina 手柄 ──BLE──────┤→ hub（Python，hub/regina_hub）──UDP──→ ControllerHub（autoload）
                                                                    │
                                    game/core（RS* 公共框架）←───────┘
                                          ▲
                                    game/scenes/<项目>（各运动项目）
```

| 层 | 路径 | 职责 | 可以依赖 |
|---|---|---|---|
| 中枢 | `hub/regina_hub/` | 设备连接、姿态融合、手机页面、UDP 转发 | 只依赖自己；与游戏之间只通过 [protocol.md](protocol.md) 通信 |
| 接入 | `game/autoload/controller_hub.gd` | 唯一的 autoload；收 UDP、维护 `RSController`、发 OLED / 震动 | `game/core` |
| 框架 | `game/core/` | 回合流程、分屏、界面、输入手势、音频、设置、存档、素材加载 | 只依赖 `core` 和 autoload，**不依赖任何项目**（ARCH-CORE） |
| 项目 | `game/scenes/<id>/` | 某一个运动项目的玩法、场地和角色 | `core`、autoload；**不依赖别的项目**（ARCH-GAME） |
| 菜单 / 调试 | `game/scenes/menu/`、`game/scenes/debug/` | 主菜单、手柄调试 | 可以引用任意项目（菜单背景用了滑板场地） |
| 测试 | `game/tests/`、`hub/tests/`、`tools/tests/` | 自动检查 | 任意 |
| 工具 | `tools/` | 素材同步、构建、发布、检查 | 不被游戏运行时引用 |

依赖方向只能向上指（项目 → 框架 → 接入）。需要在项目之间共用的代码，先移进 `core`，再由两个项目分别使用。

## 2. 一个项目的结构

每个运动项目是一个文件夹，`id` 就是文件夹名（`RSPartyGame.game_id()` 由它得出，存档和派对赛都用它）：

```
game/scenes/<id>/
  <id>_game.gd      extends RSPartyGame，只写本项目的规则和画面
  <id>_game.tscn    只有根节点和脚本，场景内容在代码里构建
  <其他>.gd         本项目专用类，class_name RS<项目><名字>
game/assets/<类别>/... 本项目素材（来源记录见 docs/ASSETS.md）
```

项目注册在游戏目录里（PR #2 合并后是 `game/core/catalog.gd` 的 `RSCatalog.GAMES`；在那之前是 `main_menu.gd` 的 `GAMES`）。

菜单的 `RSGamePreview` 根据目录 ID 显示 `assets/previews/<id>.jpg`，只在焦点切换时加载并缓存。预览由 `tools/capture_previews.py` 从实际运动场景的玩家 3D 视口渲染，不含界面覆盖；运行时不会为选中项目再建一个世界。缺少预览的目录项正常进入，不显示空卡；设置等非运动入口隐藏预览。

### 回合流程

`RSPartyGame` 负责整个回合：大厅（A 准备、手机二维码、地图卡）→ 3-2-1 倒数 → 比赛 → 成绩（A 再来、C 回菜单）。按一下 D 或 Esc 打开暂停菜单。项目**只重写钩子**，不要自己做大厅、倒数、成绩或暂停。

| 阶段 | 钩子 | 在这里做 |
|---|---|---|
| 加载 | `_setup_world()`、`_maps()`、`_load_map(i)` | 建场地、放 `lobby_cam`；多地图项目列出地图并按 `map_index` 重建 |
| 大厅 | `_player_added/removed(p)`、`_player_ready`、`_lobby_process`、`_lobby_button`、`_lobby_extra(col)` | 给玩家建角色，存进 `p.data`；额外的大厅选项 |
| 倒数 | `_countdown_time()`、`_round_started(ordered)`、`_countdown_process` | 摆位置、发 OLED 比赛画面；倒数超过 3 秒的部分可用作开场 |
| 比赛 | `_play_started()`、`_play_process(delta)`、`_player_button(p, b, pressed)` | 玩法；分数写进 `p.score`；结束时调用 `finish_round()` |
| 成绩 | `_results_process`、`_result_detail(p)` | 成绩页第二行；领奖台演出 |
| 绘制 | `_draw_hud(h, p, k)`、`_draw_overlay(o, k)` | 每个玩家的 HUD 与全屏覆盖层，用 `draw_text / draw_pill / draw_clock` |
| 文案 | `_game_name()`、`_oled_name()`、`_how_to_play()` | 名称；OLED 标题为 ASCII、最多 10 个字符 |

每个玩家是一个 `RSPartyGame.Player`：`c`（RSController）、`score`、`data`（本项目的玩家状态）、`cam`、`hud`、`fake`（机器人）。机器人由项目自己驱动（`--demo=N`）。

正式单人模式使用 `RSSolo.begin(game_id, slot, difficulty)`：一个已分配本地槽的真人和一个电脑对手，共用原有物理、名次和教学流程；只有真人可以写纪录。电脑独占另一个槽，`RSPartyGame` 保证真人缺席时不会自动开局，其他手柄不会加入。项目通过 `bot_error()` / `bot_ability()` 取得难度参数，演示默认参数保持原样。退出到菜单时清除会话。每项目三个分数挑战基于地图 1 的正式个人最佳导出（每档一星），复用 `records.cfg`，不另加进度文件；主菜单标明规则、个人星数与难度。

调试参数（`--` 之后）只在 `party_game.gd` 和 `main_menu.gd` 里解析（ARCH-ARGS）：`--demo=N`、`--shots=<前缀>`、`--map=N`、`--game=<id>`；项目自己的参数通过 `_parse_arg(arg)` 拿到。

## 3. 公共模块

新功能先找这里有没有现成的；没有的话，**在 `core` 加通用接口**，不要在某个项目里写一份私有的。

| 需求 | 用这个 | 不要 |
|---|---|---|
| 手柄状态、按键 | `ControllerHub` 的信号，`RSController`（`orientation`、`forward()`、`pitch()`、`is_pressed()`） | 自己连 UDP 或解析协议 |
| 体感手势 | `RSMotionGestures` → `RSMotionControls`（倾斜转向、甩动起跳、翻转、转体）；`RSSwingDetector`（挥动）；`RSTiltStick`（倾斜当摇杆） | 在项目里重写阈值和滤波 |
| 震动 | `haptic(p, "hit")`、`haptic_all(name)`（名称表是 `ControllerHub.HAPTICS`，新名称加在那里） | 直接 `ControllerHub.vibrate`（ARCH-HAPTIC） |
| 手柄屏幕 | `send_ui(p, {...})`（自动去重） | 每帧发同样的内容 |
| 音效 | `RSSfx.play(node, id)`、`RSSfx.loop(node, id)`，加载时 `RSSfx.warm_up([...])` | 自己 new AudioStreamPlayer（ARCH-AUDIO）；所有声音必须走 `RSAudio` 的总线，音量设置才有效 |
| 音乐 | `RSMusic.attach(parent)` 创建随场景释放的公共播放器，`play_track("menu" / "lobby" / "victory")`、`silence()`，统一走 `RSAudio.MUSIC` 总线 | 项目自己放背景音乐 |
| 界面 | `RSUi.theme / label / panel_style`；大厅、成绩、暂停在 `RSPartyUi`、`RSPauseMenu` | 每个项目自建一套面板样式 |
| 分屏 | `RSPartyViews`（`views`）；每个玩家的相机在 `p.cam`，可见层为 `1 | 1 << 玩家号` | 自建 SubViewport |
| 画面设置 | `RSSettings.apply(tree)`、`apply_viewport(vp)`、`environment(env)`、`sun_shadows(sun)` | 写死阴影、抗锯齿、帧率 |
| 文案 | 节点里 `tr("中文")`，静态代码里 `RSLang.t("中文")`；英文在 `game/i18n/en.json` | 直接写英文、拼接句子 |
| 材质、道具 | `RSPbr.surface / standard`，`RSProps.place`（MultiMesh 批量） | 每个物体一个材质、一个节点 |
| 人物 | `RSHumanRig` 子类（MPFB 角色，FK / IK 姿态） | 另做一套骨骼控制 |
| 存档 | 只在 `core` 里读写 `user://`（ARCH-SAVE）：`RSSettings`（settings.cfg），PR #2 合并后还有 `RSProfiles`（profiles.cfg）、`RSRecords`（records.cfg）、`RSTournament`（内存中的派对赛） | 项目自己写文件 |

## 4. 数据与接口

无障碍的镜头晃动开关由 `RSSettings.camera_shake` 统一保存到现有 `settings.cfg`，主菜单和游戏暂停菜单共用无障碍页面。滑板、滑雪在生成原有随机偏移后决定是否应用，保持原随机数消耗顺序，关闭抖动不改变运动物理、机器人决策或计分。

- **中枢 ↔ 游戏**：只有 [protocol.md](protocol.md) 定义的 UDP 消息。新增字段要同时改协议文档、hub 和 `ControllerHub`，并保持旧字段兼容。
- **存档**：`user://*.cfg`（ConfigFile）。`RSSave.read(path)` 读原文件、`.bak`、`.tmp` 中的有效副本；`RSSave.write(path, config)` 使用版本 1 元数据、SHA-256 校验、验证后的临时文件和上一份有效备份。无版本旧档按版本 0 读取，下次成功保存时升级。未知版本只读保护，不用旧备份覆盖；所有副本损坏时返回默认配置并记录警告。备份与临时文件是现有存档的恢复副本，不新增业务存档或 autoload。Windows 替换目标文件存在短暂间隙，因此承诺可恢复写入，不承诺断电原子性或磁盘硬件损坏恢复。`override.cfg` 仍是启动时派生的渲染设置；两份设置文件无法构成跨文件事务，驱动变更保存失败时返回错误。
- **文案**：中文原文就是 key。改中文原文等于换了 key，必须同步 `en.json`，并通过 `python tools/i18n_check.py`。
- **素材**：`res://assets/...`。新增素材必须记录来源和许可（[ASSETS.md](ASSETS.md)、[THIRD_PARTY.md](THIRD_PARTY.md)）。Poly Haven 原图不进 Git，由 `tools/sync_assets.mjs` 下载并按 `tools/assets.lock.json` 校验。
- **音乐生命周期**：菜单和大厅循环，倒数开始淡出，比赛保持音乐静默，正式结算播放一次胜利短曲；返回大厅重新播放大厅曲。播放器归当前场景所有，不新增 autoload，暂停跟随场景树。三首程序合成音乐保留完整乐谱与生成脚本，输出以 CC0 提供；来源记录与运行器检查见素材目录。

## 5. 改框架（core）的规则

`core`、`autoload`、`project.godot`、菜单和协议是所有项目共用的，冲突也最多：

1. 这些路径由维护者负责（见 `.github/CODEOWNERS`）。其他人要改，先在 Issue 或 PR 说明里写清楚需求。
2. 钩子保持向后兼容：新增钩子要有默认实现；改签名或删除钩子必须在同一个 PR 里改完所有项目。
3. 同一个 PR 里更新本文和受影响项目的说明。
4. 不新增 autoload，除非维护者同意。公共服务优先用 `class_name` + 静态函数（现有做法）。

## 6. 目前的已知例外

- 以下脚本超过 1000 行，下次修改时顺便拆分（SIZE 警告）：`basketball_game.gd`、`skate_course.gd`、`skater.gd`、`ski_course.gd`。
- 高尔夫（`scenes/golf/`）还没有接入回合框架，只有球场原型；保留，不要删除。
- 少数解析 JSON 的地方用了无类型变量（Variant），这是有意的。

## 7. 内置性能测试设计

本节先记录已授权的第二阶段接口和范围，代码在独立 draft PR 中实现；不扩展 GPT-B 原测量工具 PR 的文件权限，也不改变标准引擎版本或优化运动项目。

- 主菜单“设置 → 性能测试”进入专用菜单场景，比赛暂停页不提供该入口。菜单选择人数、画质、输出分辨率，按滑板/滑雪/篮球地图 1 顺序实例化真实运动场景；前一场景完全释放后才开始下一段。默认每段 PLAY 预热 10 秒、采样 30 秒，总流程约 2–3 分钟，加载时间另计。
- `core` 的公共采样器只接收阶段、视口及参数，不选择运动项目；菜单宿主引用 `RSCatalog`，负责场景序列。CLI 测试适配器调用同一公共实现，发行代码不依赖 `game/tests` 或 `tools`。不新增 autoload 或依赖。
- `RSPartyGame` 提供入树前的 benchmark 配置，覆盖 demo 人数、地图和记录禁用。测试实例屏蔽原有游戏键盘/手柄操作；测试宿主单独接收取消输入。普通真人、派对与单人流程保持原接口。
- 测试会话保存本次临时设置和实际窗口状态，结束、失败或取消均恢复，不调用 `RSSettings.save()`，不改变档案、纪录、教学或挑战进度。测试结果的 JSON/CSV 经 `core` 统一输出接口导出，不属于业务存档。
- 帧时间采用真实单调时钟，加载、倒数及最终成绩不入样本；提前结束或窗口最小化等条件使结果明确失效。逐视口 GPU 读数保留，整帧 GPU 不可用时为 null；统计定义与 CLI 基线一致。界面曲线和采样本身的开销保留在结果中。
- 固定地图和起始种子不代表跨帧率确定性回放。现有按帧随机消耗、物理与 GPU 粒子限制应在界面和元数据说明，不能用固定 FPS 模拟或录像替代真实渲染测量。

验收涵盖成功/取消/失败恢复、哨兵存档字节不变、同一统计样本、2/4 人实际渲染、中英文截图和严格退出检查。只交付测量能力，不自动调画质，不承诺尚未实测的 FPS。
