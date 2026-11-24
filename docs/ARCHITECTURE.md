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
  <id>_module.tres  项目清单（RSGameModule），框架、菜单、测试和工具都从这里取项目信息
  <其他>.gd         本项目专用类，class_name RS<项目><名字>
game/assets/<类别>/... 本项目素材（来源记录见 docs/ASSETS.md）
```

### 项目清单与自动发现

每个项目在自己的文件夹里放一个 `<id>_module.tres`（`class_name RSGameModule`，`game/core/game_module.gd`）。新增项目只加这个文件夹、预览图、`en.json` 和 README 条目，不改 `core`、菜单或 `tools` 里的列表。步骤见 [NEW_GAME.md](NEW_GAME.md)，`tools/new_game.py <id>` 生成骨架。

| 字段 | 含义 |
|---|---|
| `id` | 等于文件夹名；存档、纪录、教学完成状态、派对赛都用它，定了不改 |
| `name`、`desc` | 菜单名称和说明（中文 key，英文在 `en.json`） |
| `oled` | 手柄 OLED 标题，ASCII 大写，最多 10 个字符 |
| `scene` | `RSPartyGame` 场景 |
| `maps_script` | 定义 `const MAPS` 的脚本（就是 `_maps()` 返回的数组）；单地图项目留空 |
| `lessons` | 大厅教学步骤：`RSTutorial` 步骤常量的名字（`TILT_RIGHT`、`THROW`…） |
| `solo_goals` | 单人挑战三档分数（地图 1，每档一星） |
| `players` | 支持人数 `Vector2i(最少, 最多)`，1–4 |
| `mode` | `individual` 各打各的 / `versus` 同场对战 / `teams` 组队（F5 之前都是 `individual`） |
| `ambience` | 主环境音的 `RSSfx` id |
| `preview` | 菜单预览图 `res://assets/previews/<id>.jpg` |
| `ready` | 是否出现在菜单、单人和派对页；未完成的项目设 `false`，仍可用 `--game=<id>` 打开 |
| `order` | 菜单顺序（小的在前，相同按 id） |
| `benchmark` | 是否进入设置页的性能测试（`RSBenchmarkMenu.CASES`） |

选 `.tres` 而不是 `<id>_module.gd` 常量：字段有类型，编辑器里能直接改；读取清单不会加载项目场景或贴图；工具不用启动 Godot 也能解析文本。

`RSCatalog` 第一次被调用时用 `ResourceLoader.list_directory("res://scenes/")` 找所有 `<id>/<id>_module.tres`，检查字段（id 与文件夹一致、OLED、场景存在、人数、模式），不合格的报错并跳过。导出包里 `.tres` 会被转成二进制并重映射，`list_directory` 仍然列出原名，所以导出版本不需要构建时索引（已用导出的 pck 实测）。`RSCatalog.games()` 是菜单列表（`ready` 的项目，按 `order`），`find_game(id, include_hidden)`、`module(id)`、`maps(id)`、`lessons(id)`、`solo_goals(id)`、`benchmark_ids()` 供框架使用；`RSTutorial` 和 `RSSolo` 从清单取教学步骤和挑战分数。

工具从 `tools/catalog.py` 取项目和地图列表（直接解析清单和 `MAPS`，不需要 Godot）。`python tools/catalog.py --check`（CI 里的 `tools/tests/test_catalog.py`）要求每个 `ready` 项目都有预览图、教学、三档挑战和英文翻译。`main_menu.gd` 的 `--dump-catalog=<文件>` 把游戏自己发现的目录写成 JSON 后退出；`tools/test_game.py` 用它核对 Godot 和 Python 两边一致，也可以拿导出的游戏跑同样的核对。

菜单的 `RSGamePreview` 显示清单里的 `preview`，只在焦点切换时加载并缓存。预览由 `tools/capture_previews.py` 从实际运动场景的玩家 3D 视口渲染，不含界面覆盖；运行时不会为选中项目再建一个世界。缺少预览的目录项正常进入，不显示空卡；设置等非运动入口隐藏预览。

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

调试参数（`--` 之后）只在 `party_game.gd` 和 `main_menu.gd` 里解析（ARCH-ARGS）：`--demo=N`、`--shots=<前缀>`、`--map=N`、`--game=<id>`、`--dump-catalog=<文件>`；项目自己的参数通过 `_parse_arg(arg)` 拿到。唯一例外是 `--hub-port=N`：`ControllerHub` 必须在任何场景之前绑定端口，所以由它自己读取（`# allow: ARCH-ARGS`），见第 4 节。

## 3. 公共模块

新功能先找这里有没有现成的；没有的话，**在 `core` 加通用接口**，不要在某个项目里写一份私有的。

| 需求 | 用这个 | 不要 |
|---|---|---|
| 赛道、名次、机器人跟线 | `RSRaceTrack` 管理进度与检查门；`RSRaceFollower` 提供前视目标、速度曲线与追赶系数 | 项目自己复制路线进度或机器人跟线逻辑 |
| 项目列表、地图、教学、挑战 | `RSCatalog`（读各项目的 `RSGameModule` 清单）；工具用 `tools/catalog.py` | 在框架、菜单、测试或工具里另写一份项目或地图列表 |
| 大厅教学 | 清单的 `lessons` 引用 `RSTutorial` 的步骤常量（含 `SWING`）；新动作先在 `RSTutorial` 加通用步骤 | 项目自己做教学流程 |
| 手柄状态、按键 | `ControllerHub` 的信号，`RSController`（`orientation`、`forward()`、`pitch()`、`is_pressed()`） | 自己连 UDP 或解析协议 |
| 体感手势 | `RSMotionGestures` → `RSMotionControls`（倾斜转向、甩动起跳、翻转、转体）；`RSSwingDetector.swing_peaked`（挥动峰值候选）；`RSSwingClassifier`（挥拍分类，见 39-08）；`RSTiltStick`（倾斜当摇杆） | 在项目里重写阈值和滤波 |
| 球类飞行与击球 | `RSBallFlight`：固定步长受力与连续碰撞、拍面响应、只读预测、落点瞄准 | 项目重复积分球路、预测推进真实球或在物理类里判规则 |
| 震动 | `haptic(p, "hit")`、`haptic_all(name)`（名称表是 `ControllerHub.HAPTICS`，新名称加在那里） | 直接 `ControllerHub.vibrate`（ARCH-HAPTIC） |
| 手柄屏幕 | `send_ui(p, {...})`（自动去重） | 每帧发同样的内容 |
| 音效 | `RSSfx.play(node, id)`、`RSSfx.loop(node, id)`，加载时 `RSSfx.warm_up([...])` | 自己 new AudioStreamPlayer（ARCH-AUDIO）；所有声音必须走 `RSAudio` 的总线，音量设置才有效 |
| 音乐 | `RSMusic.attach(parent)` 创建随场景释放的公共播放器，`play_track("menu" / "lobby" / "victory")`、`silence()`，统一走 `RSAudio.MUSIC` 总线 | 项目自己放背景音乐 |
| 退出 | `RSExit.quit(get_tree(), code)`：暂停场景、停掉所有声音、按真实时间等 350 ms 让音频线程释放，再退出。菜单和 `RSPartyGame` 调用 `RSExit.install(tree)`，关窗口也走这条路 | 直接 `get_tree().quit()`（ARCH-QUIT），退出时会报音频资源泄漏 |
| 界面 | `RSUi.theme / label / panel_style`；大厅、成绩、暂停在 `RSPartyUi`、`RSPauseMenu` | 每个项目自建一套面板样式 |
| 开场飞越 | `RSIntro.apply(camera, elapsed, duration, start, via, end, look_start, look_end, fov_start, fov_end, look_delay)`：公共二次 Bézier 飞越、视线过渡与 FOV；`RSIntro.fade` 提供标题淡入淡出 | 项目各自重写相同插值公式 |
| 分屏 | `RSPartyViews`（`views`）；每个玩家的相机在 `p.cam`，可见层为 `1 | 1 << 玩家号` | 自建 SubViewport |
| 慢动作回放 | `RSReplay.record / since / duration / lead_out` 管理内存中的时间窗口与片段；每玩家一个 `RSReplay`，`reset(clip)` 后以成绩阶段秒数 `sample(elapsed, speed)` 取得帧对、插值和新跨越的帧范围 | 项目各自维护播放游标和相同的时间采样算法 |
| 画面设置 | `RSSettings.apply(tree)`、`apply_viewport(vp)`、`environment(env)`、`sun_shadows(sun)`、`local_shadows(light)`（点光 / 聚光阴影按画质和视图数门控）；`apply_world(root)` 刷新子树内 `QUALITY_GROUP` 的 `apply_quality()`，监听者只读设置、不保存，人物材质共用构建时的门控规则 | 写死阴影、抗锯齿、帧率 |
| 文案 | 节点里 `tr("中文")`，静态代码里 `RSLang.t("中文")`；英文在 `game/i18n/en.json` | 直接写英文、拼接句子 |
| 材质、道具 | `RSPbr.surface / standard`，`RSProps.place`（MultiMesh 批量） | 每个物体一个材质、一个节点 |
| 水面 | `RSWater`（共享波浪数学）、`RSWaterSurface`（水面与同一游戏时钟的高度查询）、`RSWaterWake`（固定容量尾迹、`splash` 浪花） | 项目另写波浪公式或独立计时的水面 / 尾迹 |
| 场馆构件 | `RSArena`（看台 / 围挡）、`RSArenaLights`（灯架）、`RSScoreboard`（记分牌）、`RSCrowd.fill_seats`（按座位填观众）、`RSArenaHall`（室内壳与环境） | 项目自建通用场馆构件或绕开 `RSSettings` 的室内效果 |
| 人物 | `RSHumanRig` 子类（MPFB 角色，FK / IK 姿态） | 另做一套骨骼控制 |
| 领奖台 | `RSPodium.configure(steps, footprint, extra, spacing, font, buried)` 在场景加载时建模；`present(scores)`、`rank(i)`、`cheer(i)`、`spot(i)`、`apply_camera(...)` 共用名次、台面、世界坐标站位和推进镜头；`fit_left(camera)` 为右侧成绩留出空间，`reset()` 隐藏并清除上一局名次 | 三个项目重复搭建台阶、计算名次与镜头公式 |
| 存档 | 只在 `core` 里读写 `user://`（ARCH-SAVE）：`RSSettings`（settings.cfg），还有 `RSProfiles`（profiles.cfg）、`RSRecords`（records.cfg）、`RSTournament`（内存中的派对赛） | 项目自己写文件 |

## 4. 数据与接口

公共领奖台由滑板、滑雪、篮球各自持有，不增加 autoload。项目传入台阶尺寸、地下埋深、第四名站位与镜头参数，以 `ranked_players()` 的稳定顺序向 `present` 提供 64 位分数；并列名次沿用成绩页的竞赛排名（1、1、3），同名次使用同台面高度、奖牌色和庆祝等级。第四位并列前三时显示额外台阶，并向外留出间隔；普通第四名仍站在原地面位置，滑雪继续负责地形高度修正。`fit_left` 在配置的镜头上平移 / 后退，保持朝向与 FOV，让台面、人物和编号落在画面左半侧，避免被右侧成绩挡住；篮球将初始机位抬到 3.5 米，避免后退后被楼顶护栏遮挡。公共层不依赖项目类，不计分、不改变派对积分或存档。人物姿势、场景 / 分屏切换、音效与雪粒子仍由项目处理。所有模型 / 材质只在加载时建立，领奖时调整已有网格；每帧只更新相机数学，时间由原有成绩阶段驱动。

回放帧是按非递减 `t`（比赛时钟秒数）排列的字典，另含项目自定的变换、姿势、冲量或球体快照；只存在内存，不是录像文件或输入重放。`reset(clip)` 后到下次重设之间，调用者不修改片段容器或帧内容。`RSReplay` 不依赖项目类，不更新物理、分数或全局时间缩放。各项目仍负责最佳片段选择、姿势 / 相机 / 音效与领奖台；公共层只裁剪时间窗口、采样和报告新跨越帧。重复采样不重复触发冲量；向后采样本次只重新定位，恢复向前后重新报告再次经过的帧。每次重开与开始成绩回放均重置独立游标，暂停沿用冻结的 `phase_time`。

开场由项目在原有 COUNTDOWN 阶段调用无状态的 `RSIntro`，时间仍为 `phase_time`（秒），不增加计时器或 autoload。项目只提供当前世界坐标中的起点、控制点、跟随终点与视线目标；公共层不依赖场地、人物或游戏类。滑板、滑雪、篮球保留各自的时长、动态锚点、视线延迟与 FOV 参数，暂停冻结、重开归零及地图切换仍遵循 `RSPartyGame`。零或负时长直接落到终点；目标与相机重合时保留朝向，垂直视线使用备用上方向，避免无效相机变换。

左手手势偏好按 P1–P4 保存在现有 `RSProfiles`，旧档案默认右手。`RSController` 的原始姿态、角速度和历史保持协议原值，调试与录制不受影响；游戏通过 `motion_orientation / motion_pose / motion_gyro / motion_roll` 读取镜像后的输入。左右镜像使用 `M=diag(-1,1,1)`：旋转为 `M R M`，轴向角速度为 `-M g`，保持抬腕方向、速度和手势时序。六项目与教学统一消费这层输入，同一局不同玩家可选不同手。

篮球改动时按 SIZE 规则抽出 `RSBasketballHud`，与阶段三 PR #7 的同名模块保持一致；控制输入与运动状态仍由游戏持有。
无障碍的镜头晃动开关由 `RSSettings.camera_shake` 统一保存到现有 `settings.cfg`，主菜单和游戏暂停菜单共用无障碍页面。滑板、滑雪在生成原有随机偏移后决定是否应用，保持原随机数消耗顺序，关闭抖动不改变运动物理、机器人决策或计分。

界面字号由 `RSSettings.text_size` 保存在同一设置文件，标准为 100%，大号为 125%。`RSUi` 保留控件、Theme 和成绩富文本的原始字号，切换时一次更新现有界面，新控件按当前设置创建；不重载比赛、不逐帧遍历节点、不重复累乘。主菜单项目列表和菜单子页滚动跟随焦点。六项目通过 `RSPartyGame.draw_text / draw_pill` 统一放大 HUD，受分屏宽度与屏幕边缘限制的单行文字按实际字体度量适配；3D 世界标签和手柄 OLED 保持原尺寸。

HUD 位图字体的动画字号由 `RSUi.snap_font_size(size, down=false)` 统一量化：64px 以下使用整数，之后每个二倍区间使用固定步宽，档距不超过当前字号的 1/32；向下模式供边界适配使用。`RSUi.fit_text_size(..., snap=false)` 保持原默认行为，`RSPartyGame.draw_text` 开启量化，使初次度量、缩小适配和最终绘制都落在同一组字号上。分数弹跳和 GO! 的直接绘制也使用该策略。此策略限制光栅字号组合，不等于已经验证字体纹理内存或帧时间收益；动效观感仍需实际渲染验收。

`RSSettings.apply_viewport` 为所有视口设置点光／聚光阴影图集：四档分别为 1024、2048、4096、4096。`RSHumanRig` 构建时按当前画质调整皮肤 SSS（仅高／极高）和头发、眉毛、睫毛的 alpha-to-coverage（仅原生分辨率且 MSAA 开启）。本批次不增加材质重应用接口；现有角色的材质不能保证随暂停页改画质即时更新，需重新创建角色后生效，不能将其描述为实时降级完成。

- **中枢 ↔ 游戏**：只有 [protocol.md](protocol.md) 定义的 UDP 消息。新增字段要同时改协议文档、hub 和 `ControllerHub`，并保持旧字段兼容。
- **蓝牙诊断**：roster 的可选 `ble_state` 描述 hub 的 BLE 来源，不影响手机、模拟手柄或名册逻辑。`ControllerHub.ble_warning()` 统一返回已翻译的异常提示；主菜单、玩家 / 手柄页与大厅显示 `no_adverts`、`unavailable`；比赛底部仅在本局有离线的真人 Regina 玩家时显示，纯手机 / 模拟手柄对局、已连接的 Regina、机器人与演示不会显示无关蓝牙告警。旧 hub 缺少字段时默认 `disabled`；状态恢复、hub 心跳过期或超过 3 秒未收到 roster 时隐藏提示，不沿用旧诊断。
- **端口**：正常游戏监听 `127.0.0.1:47800`、发往 hub 的 47801，同一时间只能运行一个实例。`RS_TEST_MODE=1` 时 `ControllerHub` 绑定系统分配的临时端口、不向 hub 发任何消息，同一台电脑上可以并行跑任意多个测试实例，也不会打扰正在运行的真实 hub；测试用 `ControllerHub.listen_port()` 取得端口，向它发送合成的 hub 数据包。需要真实 hub 的双实例测试给每个实例传 `--hub-port=N`（任何模式都有效）：游戏发往 N、监听 N-1，对应 hub 用 `--hub-port N --game-port N-1` 启动。端口无效（不在 2–65535）时报错且不绑定。`tools/` 下启动游戏项目的测试脚本都设置 `RS_TEST_MODE=1`；`tools/test_hub_port.py` 在占住 47800 的情况下同时启动多个实例检查以上行为。发行包冒烟按正常模式运行、自带 hub；其中只有启动器冒烟（`release_launcher.py`）使用固定端口，`smoke_release.py` 给冻结 hub 分配随机端口，导出游戏的冒烟走测试模式。
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

## 7. 内置性能测试

本功能的接口设计先于代码提交，在独立 draft PR 中实现；不扩展 GPT-B 原测量工具 PR 的文件权限，也不改变标准引擎版本或优化运动项目。

- 主菜单“设置 → 性能测试”进入专用菜单场景，比赛暂停页不提供该入口。菜单选择人数、画质、输出分辨率，按滑板/滑雪/篮球地图 1 顺序实例化真实运动场景；前一场景完全释放后才开始下一段。默认每段 PLAY 预热 10 秒、采样 30 秒，总流程约 2–3 分钟，加载时间另计。
- `RSBenchmark` 公共采样器只接收 `RSPartyGame`、视口及参数，不选择运动项目；菜单宿主引用 `RSCatalog`，负责场景序列。CLI 测试适配器调用同一公共实现，发行代码不依赖 `game/tests` 或 `tools`。不新增 autoload 或依赖。
- `RSPartyGame` 提供入树前的 benchmark 配置，覆盖 demo 人数、地图和记录禁用。测试实例屏蔽原有游戏键盘/手柄操作；测试宿主单独接收取消输入。普通真人、派对与单人流程保持原接口。
- `RSBenchmarkSession` 保存本次临时设置和实际窗口状态，结束、失败或取消均恢复，不调用 `RSSettings.save()`，不改变档案、纪录、教学或挑战进度。测试结果的 JSON/CSV 经其统一接口导出到 `user://benchmarks/`，写入与 flush 失败向菜单返回错误，不属于业务存档。
- 帧时间采用真实单调时钟，加载、倒数及最终成绩不入样本；提前结束或窗口最小化等条件使结果明确失效。逐视口 GPU 读数保留，整帧 GPU 不可用时为 null；统计定义与 CLI 基线一致。界面曲线和采样本身的开销保留在结果中。
- 固定地图和起始种子不代表跨帧率确定性回放。现有按帧随机消耗、物理与 GPU 粒子限制应在界面和元数据说明，不能用固定 FPS 模拟或录像替代真实渲染测量。

验收涵盖成功/取消/失败恢复、哨兵存档字节不变、同一统计样本、2/4 人实际渲染、中英文截图和严格退出检查。只交付测量能力，不自动调画质，不承诺尚未实测的 FPS。

## 8. 回合与派对大赛中断恢复（#52，实施中）

先于实现记录的接口与验收见 [中断恢复记录](ISSUE_52_ROUND_RECOVERY.md)。射箭与保龄球各自在现有玩家状态中保存出手等待时间，按正常计分接口消耗超时的零分出手；公共层不引用项目类型，不以移除比赛中玩家代替结算。

`RSPartyGame` 继续独占大厅准备、阶段转换与退出处理，`RSTournament` 继续只持有内存中的原始参赛槽位与累计积分。缺席下一项的槽位保留、该项加零分；大厅至少一人在场且所有在场参赛者准备才开始。`RSPartyUi` 展示缺席计分规则与短时二次 C 的退出确认；确认状态随其他输入、阶段／回合变化或确认者断线取消。暂停冻结玩法与确认时钟。无新增协议、业务存档、autoload 或运行时依赖。

退出确认的内存状态由 `RSTournament.ExitGuard` 承载，每个游戏实例独占一份；它接收调用者提供的比赛时钟、阶段和参与者校验，不持有场景、UI或SceneTree，不自行切换场景。`RSPartyGame` 负责信号、调用状态和实际退出，`RSPartyUi` 只显示提示。缺席结果槽位的计算也由 `RSTournament` 接收最终结果行完成，避免在 UI 或项目中另造积分规则。

## 9. 取消未完成的按住动作（#55）

`ControllerHub.button_cancelled(controller, button)` 与正常 `button_released` 分开：断线event、roster报离线、条目消失都先清零held位再按位发一次cancel，重复消息不重复取消。控制器对象保留，重连不产生迟到release。`RSPartyGame._player_cancel_hold(p, button)` 默认空实现；暂停中的release及离线cancel调用它，不能调用完成动作的普通release路径。射箭放下弓、篮球SET退回READY、保龄球SWING回AIM，均不出手或计分；只读按键掩码的项目使用默认实现。测试心跳重发最后完整roster，保留显式离线状态，空列表只用于真正的全员离线场景。

总领奖台首次A显示后，真实一秒内后续A不退出，避免多人同时确认跳过；C仍走既有大赛退出确认。该输入门不改变计分、比赛时钟或机器人速度。
