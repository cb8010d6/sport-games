# #25 老项目翻新设计：保龄球 → 射箭 → 飞机

设计草稿，2026-10-25。对应 [issue #25](https://github.com/cb8010d6/sport-games/issues/25)，源码基线为 `dev` 的 `278d4461e827edb39773c1f5da6956333f7d0d2c`。本次只交付设计；不下载素材、不实现玩法、不把历史截图或测试当作本设计的验收结果。

目标是三个项目都有真实材质、人物、开场、精彩回放、领奖台和关键动作音效；射箭、保龄球各至少两张地图。按项目完成整条体验，再进入下一项目。输入、计分、机器人难度、教学和单人挑战不变。

## 1. 已有能力、PR 草稿与未实现范围

| 状态 | 已核对事实 | 后续如何承接 |
|---|---|---|
| 已合入 `dev` | [项目清单](ARCHITECTURE.md#项目清单与自动发现)（PR #86）、[画质与分屏阴影](../game/core/settings.gd)（PR #87）、[共享素材约定](ASSETS.md#共享素材库)及 prefab 命名（PR #88） | 使用实际清单与新键名，不照搬 issue 的旧列表 |
| 已有于 `dev` | `RSIntro`、`RSReplay`、`RSPodium`、`RSHumanRig`、`RSPbr`、`RSProps`、`RSSfx` | 复用接口；项目自己提供演出数据和镜头参数 |
| PR 草稿，尚未合入 | [PR #31](https://github.com/cb8010d6/sport-games/pull/31)，核对 head `a5453d2b20cebedb80b415a08885acfdc4fe70be`：B1 PBR 场馆、球瓶材质、拆出的 `RSBowlingHall`，以及 3.8 秒 `RSIntro` 开场 | B1 由该 PR 独立验收；B2 起从其合入后的 `dev` 开工，不重写 B1，也不称其已进主线 |
| 仅本设计，待实现 | B2–B5、A1–A5、P1–P4；P5 可选 | 下述切片全部是计划，不是完成记录 |

PR #31 保留 MSDF / opaque prepass 标牌、`fwidth` 图案过滤、bloom=0，以及用户选定的 `#E3E5EF` / alpha=0.76 计分格。后续不得借人物或地图切片重做其样式。其逐帧 raw 已私有归档；Git 仅保留摘要、SHA 与九张代表图，来源和待测门槛以 [B1 返工记录](https://github.com/cb8010d6/sport-games/blob/a5453d2b20cebedb80b415a08885acfdc4fe70be/docs/BOWLING_B1_REVISION.md) 为准。

当前源码的具体接点与缺口：

| 证据文件 / 接口 | 可复用部分 | 本项目需补的部分 |
|---|---|---|
| [bowling_game.gd](../game/scenes/bowling/bowling_game.gd)：`Bowler`、`_track_swing`、`_release`、`_count_pins` | `swing_angle`、站位、原球瓶刚体、标准计分 | 无人物和回放；`_count_pins` 会立即重摆球瓶，必须在重摆前封存片段 |
| [archery_game.gd](../game/scenes/archery/archery_game.gd)：`_update_view`、`_fly_arrows`、`_score_arrow`、`_begin_round` | 第一人称瞄准、箭轨迹、命中点、每轮校准 | 无人物和演出；换轮会清箭、移动靶位，回放不能读取最后一轮的靶位冒充最佳箭的场景 |
| [plane_game.gd](../game/scenes/plane/plane_game.gd)、[island.gd](../game/scenes/plane/island.gd)、[plane.gd](../game/scenes/plane/plane.gd) | `ground_height` 与网格三角形一致；飞行、环判定和复位已有 | 材质、环境、领奖人物及回放缺失；`RSPlane._process` 的螺旋桨/尾迹会独立更新，演出要明确停止实时更新 |
| [replay.gd](../game/core/replay.gd)：`record / since / reset / sample / lead_out` | 时间窗口、独立游标、插值和跨帧事件范围 | 不记录物理、挑选精彩片段或控制显隐；这些由各项目实现 |
| [human_rig.gd](../game/core/human_rig.gd)、[podium.gd](../game/core/podium.gd)、[party_views.gd](../game/core/party_views.gd) | FK/IK、`set_layers`、名次/站位、左侧取景、玩家专属渲染层 | `capture/show_pose` 是现有运动 rig 的做法，不是基类现成接口；新 rig 自己实现紧凑姿态快照，禁止引用其他运动的 rig 类 |
| [bowling](../game/scenes/bowling/bowling_module.tres)、[archery](../game/scenes/archery/archery_module.tres)、[plane](../game/scenes/plane/plane_module.tres) 清单 | ID、教学、三档挑战、预览路径都已登记 | 三者 `maps_script` / `ambience` 均为空；新增地图、环境声时补相应字段 |

## 2. 小 PR 顺序与交付

每个切片以一个可审查目标为界，除测试、素材和生成文件外约 800 行以内；超出时按表内的 a/b 拆分。先完成保龄球，之后射箭，最后飞机。公共框架需求另交维护者，不夹入项目 PR。

| 顺序 / issue 项 | 本次切片的具体结果 | 主要文件与验收重点 |
|---|---|---|
| 前置 B1 | 仅跟进 PR #31 的独立验收与合入 | 不在本计划重复实现或重新扩大画面矩阵 |
| B2 人物 | `RSBowlerRig extends RSHumanRig`；站位、短助走、摆臂、放球、跟随和反应姿态。AIM 保留原球后瞄准；SWING/ROLLING 可平滑转为肩后/跟球 | `bowler_rig.gd`；必要时先抽 `bowling_hud.gd`。rig 手追随原球，`_release` 的时刻、初始位置/速度不变，不为等动画延迟出球 |
| B3a 快照 | 记录投球候选、封存最佳球；先补片段选择与球瓶显隐测试 | `bowling_replay.gd`；全中优先，其次本球击倒数，平手保留较早球；不拿奖励分再次计分 |
| B3b 回放 | 沿用 B1 开场；成绩阶段慢放最佳球的瓶区特写，无碰撞替身播放 | 只调整 B1 开场终点以适配人物站位；投球至结算全过程中选包含撞瓶的有限窗口，不承诺播放整条球道 |
| B4a 领奖台 | 场馆休息区预留演出位，四人、同分、右侧成绩均可见 | `bowling_presentation.gd`；复用同一人物和 `RSPodium`，验证相机不会退入墙、回球机或座位 |
| B4b 音效 | 滚球、击瓶、回球、全中、馆内环境声 | 复用 `roll / thud / applause / chime`；击瓶按每球事件节流，环境声单实例，不在每个视口叠播 |
| B5 地图及收尾 | 地图 1 保留 B1 霓虹夜场；地图 2 为明亮经典球馆，完成预览及文档 | `bowling_maps.gd`、清单、场馆参数化；两图仅视觉不同，油面 shader 不改变摩擦/弧线 |
| A1 场地 | HDRI、扫描草地/木架，PBR 纸靶与草靶、长椅和遮阳棚，独立布旗 shader | 先抽 `archery_range.gd`；`sparse_grass / leafy_grass / plywood / beam_wall_01`，靶面图案程序生成，不虚构纸靶扫描来源；不改靶面半径、中心高度、距离和击中判定 |
| A2 弓箭与人物 | PBR 程序弓箭、`RSArcherRig` 的拉弓/放箭/庆祝姿态 | `archer_rig.gd`、`archery_equipment.gd`；比赛继续第一人称，自己的完整人物不进入瞄准镜头，不改变现有 FOV/准星/校准 |
| A3a/b 开场与回放 | 约 3.8 秒靶位→射击线开场；0.45 倍速跟箭回放最高分一箭 | `archery_replay.gd`、`archery_presentation.gd`；先快照/选择，后显示/镜头；同环按距靶心、再按较早箭排序；全脱靶跳过回放 |
| A4 领奖台与音效 | 射击线后方平地领奖；拉弓、弦响、飞箭、中靶、10 环和风声 | 人物由私有层转公共层；一发箭只触发一次命中音，回放只重播演出音，不调用计分/震动/设备消息 |
| A5 地图及收尾 | 地图 1 草地晴天，地图 2 海边黄昏；完成预览及文档 | `archery_maps.gd` + 清单。海岸使用已有沙/岩材质与石头道具；两图共用原 `ROUNDS`、风力范围与 RNG 消耗顺序，黄昏雾不遮住 40 米靶与旗 |
| P1 地形与海 | 扫描草/沙/岩按高度与坡度混合，HDRI、真实海面、分层云；植被待共享产物实到 | 新 `plane_terrain.gdshader`；保留 seed、网格、每个顶点和对角线，不加顶点位移；只读复用 `sea.gdshader`，海面基准仍 y=0。少量程序云网格/专用 shader 增加体积感，高档启用、低档退回 HDRI，不能遮挡环 |
| P2 飞机与环 | 程序机体用漆面金属、玻璃、橡胶，去描边；螺旋桨模糊盘；有材质的赛道门 | 抽 `plane_visual.gd`，飞行状态仍由 `RSPlane` 持有；环中心/法线/半径、金环顺序、提示轮廓清晰度不变 |
| P3a/b 开场与回放 | 约 4 秒环岛→起飞位开场；回放最佳连续穿环窗口 | `plane_replay.gd`、`plane_presentation.gd`；按窗口实得分、连击、较早时间排序；相机随快照，不再调用 `fly/_check_rings` |
| P4 领奖台、音效、人物 | 起点外侧平地/小码头领奖，`RSPilotRig` 只用于演出；发动机、穿环、坠海和风声 | 复用现有人物，不增加驾驶舱人物；发动机音高随原 `speed`，坠海音效不改变 `_crash` 的复位位置和无敌时长 |
| P5 可选 | 第二张“黄昏海湾”，只改变视觉参数 | 主体交付后再做；保留原高度场/环线，真正峡谷与新赛道另立玩法范围；未做 P5 不阻塞 #25 |

每个项目收尾都重新导出自己的预览，更新相关 README 调试参数、路线图和实际状态；整项 #25 在三项目及必需地图均验收后才可勾选完成。

## 3. 演出数据、内存与物理隔离

统一流程是 `COUNTDOWN 开场 → 原 3 秒倒数 → PLAY → RESULTS 回放 → 领奖台 → 成绩面板`。只使用原 `phase_time`，暂停自然冻结；不改 `Engine.time_scale`，不增加异步计时器。`finish_round()` 的项目收尾先检查 `_result_committed`，只封存一次，再调用父类，避免二次结束重置演出。

每玩家一个 `RSReplay`，只录实际可观察的视觉状态，不录输入或磁盘录像。30 Hz 为初始采样建议，使用现有玩法状态；不新增一个固定步长去重跑物理，也不把 FPS 波动时的插值帧称为实测物理帧。普通渲染帧只插值，采样槽、姿态容器和替身加载时预建；事件发生时才裁片段。保留片段独立拥有冻结数据，不能复用仍被最佳片段引用的采样槽。

| 项目 | 一帧负载 | 滚动上限 / 保留上限（每玩家） | 事件与选择时机 |
|---|---|---|---|
| 保龄球 | `t`、人物根变换和紧凑姿态参数、球+10瓶变换、11位可见掩码、球序号/事件位 | 12 秒 / 361 帧；最佳源片段 ≤4 秒 / 121 帧 | 撞瓶时标记视觉事件；`_count_pins` 重摆前封存。片段围绕撞瓶，包含可用的前摇与倒瓶尾段；全零分无有效片段则跳过 |
| 射箭 | `t`、人物姿态、单箭变换/可见性、当次靶变换/命中点、轮/箭序号 | 6 秒 / 181 帧；最佳 ≤4 秒 / 121 帧 | 命中后留短尾停；`_begin_round/_clear_arrows` 前封存。靶位取该箭快照，不取当前 40 米靶位 |
| 飞机 | `t`、机体变换、螺旋桨相位、速度/boost视觉量、环事件/目标序号、复位断点 | 8 秒 / 241 帧；最佳 ≤4 秒 / 121 帧 | 穿环后完成候选尾段；坠机传送切断插值，窗口不跨复位；尾迹由有限快照轨迹生成或回放时关闭 |

播放建议均为 0.45 倍速、最长 9 秒，再由 `RSReplay.lead_out(..., 9.0, 0.3)` 留尾停；成绩面板延后至领奖台开始 1.6 秒。空/单帧片段直接跳过；某玩家无片段时显示自己的固定场地镜头，不阻塞其他人的回放。事件按 `crossed_from..index` 触发一次，重复采样与暂停不重响。

内存预算是**建议上限，尚未实测**：四人回放数据合计 ≤16 MiB；只保留滚动缓冲、一个待完成候选、一个最佳片段，候选尽量引用不可变帧，替换最佳后释放旧引用。变换/姿态用紧凑标量或 packed 数组，不存每帧完整骨骼矩阵、节点或材质引用；采样同时限制帧数和秒数。保龄球仅 11 个 `Transform3D` 的 float32 原始负载约 528 字节/帧，这不含 Variant、字典与容器开销，不能据此声称实际内存达标。

人物只加载参与玩家选中的外观，最多四个人物实例；同一实例依次服务比赛、回放、领奖，不额外建立四套回放人或领奖人。不复制 glb/纹理；同外观资源共享。`RSHumanRig` 会调整导入材质，需上色时每人物只在加载时 duplicate 自己改动的衣物材质，避免串色。领奖与比赛显隐、骨架更新都显式切换，人物隐藏时停止无用姿态更新。

保龄球在进入 RESULTS 时冻结全部真实 Jolt 球瓶、清速度、移出碰撞并隐藏；碰撞属性在安全的延迟边界修改。预建的 11 组无碰撞网格替身/玩家共享原网格和材质，只读快照变换，绝不驱动真实刚体或调用 `_count_pins`。`_physics_process` 的 PLAY 判断只停止施力，**不会自动停止 Jolt 模拟**，不能把它当作冻结实现。重开先显式恢复球的原碰撞层/掩码，再调用 `_reset_pins/_hold_ball`；后者目前不会恢复球的碰撞过滤，不能假设原函数已覆盖新冻结状态。恢复后再打开 PLAY；地图切换先释放全部球瓶与替身，待释放后再创建新场地，不能留下旧碰撞。

射箭隐藏实时箭、第一人称弓和实时靶，用本玩家专属层的箭/靶替身还原历史距离；飞机关闭实时 `RSPlane._process` 对演出的写入，只显示替身机体。各玩家回放替身使用 `1 << p.c.player`，公共世界为层 1，防止同时回放的四个历史状态互相穿帮；领奖时统一隐藏替身、`rig.set_layers(1)`、`views.visible=false`、`lobby_cam.current=true`。

领奖台加载时 `configure`，成绩时以 `ranked_players()` 的稳定顺序传 `PackedInt64Array` 给 `present`，使用 `spot/cheer/apply_camera/fit_left`。同分沿用 1、1、3；不另算名次。重开、返大厅、移除玩家和换图都要释放片段引用、重置游标/音效、`podium.reset()`，恢复分屏、相机 FOV、渲染层及第一人称弓，不能只把画面藏起来。

## 4. 地图与清单契约

新增 `RSBowlingMaps.MAPS`、`RSArcheryMaps.MAPS`，`_maps()` 原样返回；对应 `<id>_module.tres.maps_script` 指向该脚本。字段限定为名称/说明、HDRI、太阳/雾、材质色调、视觉道具布局、演出锚点，不放计分或难度参数。保龄球原地图固定为 index 0 的霓虹夜场，射箭固定为 index 0 草地；新增图只追加，避免纪录地图键变化。

`_load_map(i)` 重建本项目 world root，恢复原静态玩法布局，清空玩家演出数据后重新绑定人物/器材。沿用 `RSPartyGame` 的大厅取消准备、延迟换图和 `RSSettings.apply_world`，不另写地图菜单。注册后的地图同时服务大厅、`RSCatalog.maps`、`tools/catalog.py`、smoke 和预览工具；游戏 `--map=0/1` 及 benchmark `--maps 0/1` 都是零基索引，玩家看到的是地图 1/2。

保龄球的球道尺寸/间隔、摩擦、球瓶形状/质量、站位、速度/旋转映射、最后格奖励球全不变；射箭的 15/25/40 米、每轮三箭、风范围、重力、拉满时长与逐轮校准全不变。射箭地图装饰不消耗玩法 `_rng`；第一张地图的教学/挑战沿用清单原值。飞机 P1/P2 不改高度场、环线、飞行常量、计时、自动驾驶和复位。

清单 `id/scene/lessons/solo_goals/players/mode/order/ready` 保留；环境声 ID 落地后填 `ambience`。不恢复已经移除的 `RSCatalog.GAMES`、`RSTutorial.LESSONS`、`RSSolo.GOALS` 硬编码。现有 [catalog_cases.gd](../game/tests/catalog_cases.gd) 的 `LEGACY_MAPS` 和 [test_catalog.py](../tools/tests/test_catalog.py) 仍冻结旧地图数；地图 PR 应改为“清单与实际 `_maps()` 一致 + 原地图规则不变”的契约测试，而不是再写一份新地图总表。

## 5. 素材复用、预算与共享接口需求

只把锁定素材与现存产物当作可用资源；[共享素材总索引](../game/assets/shared/CREDITS.md) 目前所有类别为 0 文件，统一人物、场馆 kit、树图集还没有实现。不要把目录骨架当成模型，或在计划里虚构 prefab。

| 用途 | 第一版复用 | 限制 / 缺口 |
|---|---|---|
| 人物 | 直接加载已在 `assets/characters/` 的 `baller0–3.glb`，外观由 `avatar_of(p)`，颜色由 `color_of(p)` | 三运动不各生成一组新人物；后续统一 roster 迁移按共享素材 PR 的真实结果跟进，不抢先改资产位置 |
| 保龄球 | B1 的 `rooftop_night`、`plywood`、`metal_plate`、墙/砖/灰泥/地砖；现有 `urban_plant / urban_boombox / hall_wet_floor_sign` | 仅放休息区，不挡原相机/演出路线。保留 B1 已锁 4K 反射源，不能为新 2K 建议顺手重下载改 B1 |
| 射箭 | `kloofendal_43d_clear_puresky / belfast_sunset_puresky`、`sparse_grass / leafy_grass / plywood / beam_wall_01 / coast_sand_01 / dark_rock_02`；`urban_bench / urban_bin / nature_boulder` | 弓、箭、靶和遮阳棚优先程序几何 + 已锁纹理；林缘地图可待 shared vegetation 后追加，必需第二图不依赖树图集，不复制 `golf/trees` |
| 飞机 | 现有晴空 HDRI、`leafy_grass / coast_sand_01 / dark_rock_02`、只读 `sea.gdshader` | 第一版以草/沙/岩和石头构成海岛；植被待共享产物实到后追加，移除旧圆锥卡通树。不改共享 shader；地形 shader 不改变顶点，近处扫描植被不能无减面直接批量加载 |
| 音效 | 现有 `roll / swish / thud / chime / ding / applause / wind / wind_amb` | 一次性新录音按动作 ID 优先、确实专属才加项目前缀；不得给共享 `thud` 换成击瓶录音影响其他项目 |

`RSProps` 已按 kit 更名，使用 [props.gd](../game/core/props.gd) 的实际 key，不使用旧 `bench/bin/boulder`。`RSProps.place` 支持批量、层与阴影；`RSPbr.maps` 缓存贴图，`surface/standard` 每次仍新建材质，项目需在场地加载时自行缓存并复用材质实例。非 Poly Haven 材质使用 `shared:<id>`，场地重复件用 MultiMesh。

第一版新增人物、外部模型和 Poly Haven 下载预算均为 **0**，必要的新音效另计；新增内容遵循 [ASSETS.md](ASSETS.md#每个新项目的预算)：Git 成品 ≤40 MiB、单文件 ≤20 MiB、新 Poly Haven ≤120 MiB、场景实测显存 ≤550 MB、道具等 ≤120 MB，超出必须在实施 PR 说明。复用资源仍有加载/显存成本，不能以下载为零宣称运行成本为零；四人分屏共用世界，逐视口渲染仍有代价。

2K 是新增素材的目标规格，不是现有 `RSPbr` 的画质降级能力：当前它选已下载的最高分辨率，没有按画质封顶。先限制同时加载的材质组/道具；超预算时申请维护者提供可选分辨率上限，不能在本项目顺手改共用贴图导入设置或声称低档已自动变 2K。

本 issue 只向维护者提出以下共享需求，不直接改 `game/core/*`：

- `RSSfx.LOOPS` 增加有已登记 WAV 的 `bowling_hall_amb`、`plane_engine`；前者自动进入 Ambience 总线，后者走 SFX。若回球/拉弓需要持续循环再逐项申请；提交录音前不得调用未知 ID，避免静音 fallback/警告。可先用已存在的 `roll / wind_amb` 完成其他切片。
- 如共享人物/植被迁移先落地，提供稳定资源入口和 prefab key；当前 `RSHumanRig` 加项目子类足以使用现存 glb，不要求新增公共骨架接口。
- 现有 intro/replay/podium 接口足够；测试适配器不作为运行时 core 接口。若后续需要通用演出测试入口，先由维护者定义默认实现与旧项目兼容，再另行迁移。
- 仅当受影响场景实测超预算时，申请 `RSPbr` 可选的分辨率上限；保持默认选图行为兼容既有项目，不把未来接口当成本轮已提供能力。

新增外部内容只接受逐文件可核实的 CC0；来源页、作者、下载日期、原始文件名/SHA、加工方法、版本/命令完整登记。Poly Haven 使用现有锁定/同步流程，不手填哈希；生成产物更新本目录 CREDITS、`ASSET_MANIFEST.json`、`THIRD_PARTY.md` 与窄前缀许可策略，混合原创代码/扫描图记 `MIT AND CC0-1.0`。没有二进制变化时不重生成大清单。

## 6. 文件 ownership 与验证边界

| Owner | 可改范围 | 协作约束 |
|---|---|---|
| 当前设计 | 仅本文 | 不改 B1、其他任务或共享文件 |
| #25 项目实现者 | `scenes/bowling/*` → `archery/*` → `plane/*`；新项目专用 shader；对应演出/规则测试 | 每个项目同时只一人；按需拆 hall/range/visual、rig、replay、presentation、hud，保持 `.tscn` 根节点式结构及 `.uid` |
| 素材 owner | 新产物及来源登记、锁定清单、许可策略、这三个项目预览与 `manifest.json/CREDITS.md` 条目 | 与共享素材任务串行协调；不编辑其他项目代码/产物，不复制尚未迁移的高尔夫树 |
| 维护者 | `core/*`、共享 shader/架构、通用测试接口 | 本文只提出需求；公共接口变更独立 PR，默认行为兼容旧项目 |
| 收尾 owner | `en.json`、README、roadmap 相关几行 | 文案 `tr/RSLang.t`，OLED ASCII 大写 ≤10 字符；不全文件重排 |

现有 `tools/test_intro.py / test_replay.py / test_podium.py` 仍只接受三个旧项目，对应 GDScript 还直接读取它们的私有状态；不能把修改 choices 列表当作接入完成。先在项目演出 PR 中加入本项目专用适配用例，测试运行器从清单和测试文件命名约定发现项目/地图，不再扩硬编码项目表。复用公共数学测试，保留旧项目用例；适配器负责本项目快照、真实刚体冻结、显隐与相机断言。

实施时“小改动小测、大切片合并验收”：人物切片核对出手/瞄准不变，回放切片重点测选择/快照生命周期、暂停、空片段和不重复计分，地图切片测清单一致、切换释放和原地图规则。每项目完成时再做一次实际地图 × 2/4 人的演出/完整回合验收及同机同设置性能对比，避免每个小 PR 反复跑全矩阵。四人领奖补部分并列/全并列、右侧面板及墙/地形遮挡。

最终画面按 #25 要求保留 1600×900 双语、每图 2/4 人及开场/回放/领奖代表；性能目标为 780M 双人 60 / 四人 45 FPS，必须实测，历史 B1 数字不能推广到人物和其他项目。截图/性能运行使用隔离玩家数据与隐藏/独立桌面，不在使用者桌面弹窗；工具日志/原始逐帧数据留 `audit-output/` 或私有归档，公共文档只放必要摘要、SHA 与代表图，不重复引入大型 raw。

预览沿用 `python tools/capture_previews.py --godot <Godot> --games <id>`：真实 3D 相机、map=0、1600×900，更新该项目 JPG、manifest SHA/字节及 CREDITS，不增加菜单硬编码或在线图片。素材变化再执行同步校验与 strict 发布审计；项目收尾再跑相关 solo/party、左手和暂停/重开回归。真实手柄、BLE、HDR/VRR 与跨平台画面未做就明确写未验证。

本设计本轮只运行规范、i18n、差异空白、相对链接与路径隐私检查；不运行 Godot、下载、截图、性能或完整测试套件。检查结果随本次文档交付报告，不能预先写通过。

## 7. 实施前需定下的选择

| 决策 | 推荐值 | 依赖动作 |
|---|---|---|
| B1 承接点 | PR #31 审查并合入后的 `dev` | 开 B2 前刷新基线；保留其最终样式和证据边界 |
| 人物与镜头 | 复用 `baller0–3`；保龄球 AIM 不动、挥臂后肩后；射箭始终第一人称 PLAY；飞机只演出有人 | B2/A2 用小样确认无遮挡，不改手势或出手时序 |
| 林缘树来源 | 第一版不依赖；需要追加时优先用 shared vegetation 的真实迁移产物 | 追加前确定文件/key/预算，不假设 #88 已完成迁移 |
| 循环音效 | 馆内环境 + 发动机两项，先登记 WAV，再由维护者加 loop ID | 只阻塞这两个声音，不阻塞人物/地图/演出其余工作 |
| 飞机第二图 | 本期先不做；需要时选择视觉“黄昏海湾” | B/A 必需地图和 P1–P4 验收后再决定，不以可选 P5 拖延交付 |
