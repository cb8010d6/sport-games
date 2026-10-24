# 局域网联机设计记录（#23）

**状态：设计已获主线采纳，运行时尚未实现。** 本 PR 只新增本文；手机 Wi-Fi 接入仍是单机手柄，#23 的 LAN MVP 尚未完成。四项产品决定及跨区授权见 [PR #29 的主线审查](https://github.com/cb8010d6/sport-games/pull/29#issuecomment-6377606809)。下文新增类、钩子、参数与协议均为后续实现约定；字节布局和报告草案放在附录，不是已发布协议。

## 1. 已采纳的范围与决定

MVP 支持多台电脑各运行游戏和自己的 hub，各自分屏；总计 2–4 人，每机至少一人。先接滑板、滑雪，远端为无碰撞幽灵；每台只模拟本地玩家与机器人，不转发 200 Hz 手柄数据。其他运动、派对大赛、共享球体和超过四人留到后续。

| 已采纳决定 | 实施约定 |
|---|---|
| 生命周期、人数与加入 | 不加 autoload，使用常驻节点；保留四档配色和名次奖励；仅大厅接纳加入，局中明确拒绝，下一局自行重试。 |
| 暂停、离开与排名 | LAN 暂停只显示覆盖层，不冻结比赛；客户端不能重开。离开者移出活动名单、幽灵及本局最终排名，保留审计名单。主机离开则全员回菜单；断线检测目标 5 秒。无主机迁移、局中重连。 |
| 构建、档案与成绩 | 协议、构建及目录/地图摘要全部匹配才加入；档案和视口仍用本地槽。LAN 暂不写个人纪录或挑战星数；派对积分第二阶段再定。 |
| 高频事件验收 | 事件产生至发送入队不超过一个物理 tick；无丢包时接收处理不超过注入单程延迟＋抖动上界＋一个 tick。有丢包时另报 p50/p95/p99、重传及超时，不承诺可靠重传仍只增加一个 tick。 |

## 2. 已有入口与后续实现授权

最新 `dev` 已包含 [#27 主题](https://github.com/cb8010d6/sport-games/pull/27) 和 [#34 测试端口入口](https://github.com/cb8010d6/sport-games/pull/34)（关闭 #32）。源码核对结果：

- `RSUi` 位于 `game/core/ui_kit.gd`；页面根节点用 `RSUi.theme()`，面板用 `modal_style()` / `card_style()`，按钮沿用主题，主要操作设 `theme_type_variation = &"RSPrimary"`。颜色、字体及动效见 [UI_THEME.md](UI_THEME.md)。
- `RS_TEST_MODE=1` 且未传 `--hub-port` 时，`ControllerHub` 绑定系统分配的回环 UDP 临时端口，不向 hub 发消息；并非完全关闭 UDP。测试从 `ControllerHub.listen_port()` 取得端口。
- 已有 `ControllerHub.ports_for(args, test_mode)`；`--hub-port=N` 在任何模式下覆盖默认值：游戏发往 N、监听 N-1，对应 hub 用 `--hub-port N --game-port N-1`。无效 N（非 2–65535）报错且不绑定。普通游戏仍为 47800/47801。
- 已有 `tools/test_hub_port.py` 和 `engine_process.run_engines()`；未来 runner 复用这些入口和进程归属管理，不另改 autoload 或忽略端口错误。#34 的已合入状态不等于 LAN 已验证。

| 后续实现范围 | 授权与边界 |
|---|---|
| `game/core/net_session.gd`、`net_discovery.gd`、`net_remote.gd` 及 `.uid` | 主线已授权：会话/收发/时钟/注入、发现、远端缓冲；core 不依赖项目类。 |
| `game/core/party_game.gd` | 已授权下表默认钩子及 LAN 接入；非 LAN 行为不变，不改旧签名。 |
| `game/scenes/menu/main_menu.gd`、新增 `lan_page.gd` 及 `.uid` | 已授权独立 LAN 页面和参数入口，必须使用 RSUi；#27 的先决条件已满足。 |
| `docs/ARCHITECTURE.md`、`docs/protocol.md` | 与对应实现放在同一个 PR 同步公共模块、权威和消息，无需另开前置文档 PR。本文不代替正式协议。 |
| 滑板/滑雪、`game/i18n/en.json` 与相关测试 | 后续切片接幽灵、全局起跑位和完赛事件；只改相关项目、翻译及测试，逐片列明范围。 |
| `party_ui.gd`、`pause_menu.gd`、`catalog.gd`、`tournament.gd`、autoload、`project.godot` | 不由本次授权自动覆盖；如需改动先列出具体需求。派对赛全局身份留到第二阶段。 |

下表列出待新增接口及已有接口的 LAN 扩展；这些 LAN 行为尚未实现：

| 接口 | 非 LAN 默认 / LAN 约定 |
|---|---|
| `is_lan()`、`is_lan_host()`、`remote_players()` | `false`、`false`、空列表 |
| `seat_of(p)`、`start_index(p)`、`start_count()` | 原本地槽、原排序索引、原本地人数；LAN 使用冻结全局名单 |
| `name_of/color_of/avatar_of` 的 LAN 分支 | 保留现有非 LAN 实现；LAN 读名单快照，本地档案上报显示属性 |
| `ranked_all()` | 非 LAN 由本地排名生成纯数据行；LAN 合并全局成绩，不暴露远端 `p.data` |
| `_net_tick_hz()`、`_net_sync_mode()` | `20`、`ghost`；未来项目可声明 `60/120`、`predictive` |
| `_net_snapshot(p)`、`_net_event(seat, kind, data)` | 默认仅 score / 空操作；项目适配自己的数据 |
| `_remote_added/removed/step`、`send_event(kind, data)` | 非 LAN 空操作；LAN 事件立即进入可靠发送路径 |

`players`、`ordered()`、`ranked_players()` 始终只含本地 Player；相机、OLED、回放和分屏继续用本地槽，不把远端伪装成 `RSController`。`RSNetSession.ensure(tree)` 幂等创建根下常驻节点，用引用或组查找；不归 `current_scene`，采用 `PROCESS_MODE_ALWAYS`。保留 `SceneTree.multiplayer_poll=true`，不重复 poll；退出关闭连接、发现与队列并解除信号。暂停和切场景收发须在 Godot 4.7.2 实测。

LAN 参数仍仅在 `party_game.gd`、`main_menu.gd` 解析；已有 `--hub-port` 的 autoload 例外沿用 [ARCHITECTURE.md](ARCHITECTURE.md)，不扩大例外。

## 3. 身份、状态与主机权威

peer 身份来自 ENet 回调。主机分配 seat 1–4：主机本地槽升序优先，其余按加入顺序；`(peer_id, local_slot)` 唯一。本地槽仍为各机 1–4，配色和起跑序号用 seat，存档和视口用 local_slot。大厅名单带 `roster_revision`；倒数前冻结，本局不压缩离开者座位，旧局/旧 revision 数据无效。

会话为 `OFFLINE → CONNECTING → LOBBY → LOADING → COUNTDOWN → PLAY → RESULTS → LOBBY`；拒绝、主机离开、超时或致命协议错误进入 `CLOSING → OFFLINE` 并显示原因。游戏保留现有四个 Phase。主机本地命令也走验证路径。

| 内容 | 权威与顺序 |
|---|---|
| 名单、准备与加载 | 主机广播名单/地图/种子/内容摘要；全员准备且加载确认后才倒数，加载超过 10 秒回大厅。 |
| 起点与截止时刻 | 主机下发共享时钟中的未来起点与截止时间；客户端不能自行开局、结束或推进下一局。 |
| 运动、手势与基础分 | 所属机器产生；主机检查 seat 所属、范围、时间和阶段再转发。MVP 不提供反作弊保证。 |
| finish / place | finish 带唯一事件 ID；主机按收到的有效 finish 顺序分配唯一 place，比赛时间只供检查/展示，不宣称延迟公平。首位完赛将截止收紧为 `min(原截止, 主机当前比赛时间+25秒)` 并可靠广播。 |
| 奖励、排名与结果 | 主机保存每 seat 唯一 finish 和奖励事实；重复请求回同一确认，奖励只应用一次。基础分＋奖励封存为 results，旧快照不能覆盖奖励。比分用竞赛排名 1,1,3，行按 score 降序/seat 升序；place 与 score rank 分开。 |

客户端断线后主机继续，不再等它 ready/finish；最终排名排除离开者，已发 place 不重排。主机断线不产生正常 results，客户端清幽灵并回菜单。只有主机能返回大厅；MVP 不记 LAN 派对积分。

## 4. 连接、消息与输入边界

候选默认 ENet UDP 47810、发现 UDP 47811，避开现有 hub 端口。后续参数为 `--lan-host`、`--lan-join=<IP>`、`--lan-bind=<IP>`、`--lan-port=<端口>`、`--lan-discovery-port=<端口>`；报告参数随 runner 实现再定。端口限 1024–65535、两者不同，也不得与所选 hub 端口对冲。绑定地址由用户选；产品 IPv4 广播每秒一次、3 秒过期，手动加入兜底，不自动改防火墙。

发现采用 UTF-8 JSON（≤512 字节，名字≤48 UTF-8 字节），字段为 `t=rs_lan,v,name,port,game,players,open`；只是展示信息，加入后重新握手，源地址不是身份凭证。自动测试的 LAN 和发现一律显式绑定回环，发现向回环单播。

连接顺序为 ENet → hello → welcome/reject → roster/ready → load/加载确认 → countdown → state/event → results → lobby。控制消息统一 `v,t,session_id,round_id,seq`；hello 可无 session_id，welcome 下发随机 128 位会话 ID。round_id 每局递增，seq 按发送者递增；主机验证后显式转发原所属 seat，客户端只接主机广播。

| 消息 | 传输与约定 |
|---|---|
| hello/welcome/reject、roster/ready、load/map/countdown/lobby、results/leave | channel 0，可靠；承载构建/内容校验、名单、阶段及结果 |
| event/finish/place | channel 0，可靠且立即发送，带 seat、event_id、race_ms 和类型化负载 |
| state | channel 1，不可靠有序；固定二进制候选见附录 A |
| clock_ping/clock_pong | channel 2，不可靠无序，四时刻样本 |

显式分配至少三个 channel，关闭 `SceneMultiplayer.server_relay`；客户只发主机。控制字典候选用 `var_to_bytes` / `bytes_to_var(packet)`，禁用对象解码，保持 `allow_object_decoding=false`。解码前限长 4096 字节；只允许白名单字段、标量和浅数组（深度≤4、每数组≤16），禁止对象、Resource、Node、Callable 及动态方法名。Variant 畸形长度的分配风险必须在 codec 切片审查，必要时采用有界 framing/JSON。

版本错误、缺字段、NaN/Inf、越界、越权、旧局和歧义序列均拒绝并计数；持续非法输入断开。控制限 50 条/秒，state 限目标频率＋10%，队列≤256 条/peer。名字显示前转义富文本。API 参考 [SceneMultiplayer](https://docs.godotengine.org/en/stable/classes/class_scenemultiplayer.html)、[ENetMultiplayerPeer](https://docs.godotengine.org/en/stable/classes/class_enetmultiplayerpeer.html)；实施仍须锁定 Godot 4.7.2，不承诺其他 ENet 实现互通。

## 5. 时钟、快照与事件

120 Hz 物理下，20/60/120 Hz 分别每 6/2/1 tick 采样，和渲染分离；卡顿后只发当前快照，不补发旧包。`ghost` 默认缓冲 100 ms、最多外推 250 ms 后冻结；teleport 或跳变>5 m 清窗口。网络姿态窗口独立于成绩回放。`predictive` 不用固定 100 ms 延迟，而用实测抖动缓冲、速度外推及短时修正。

网络同步用单调时间，不替代玩法 delta，例外随实现写入正式文档。四时刻 t1/t2/t3/t4 计算 RTT=`(t4-t1)-(t3-t2)`、主机减客户偏移=`((t2-t1)+(t3-t4))/2`。握手至少八个有效样本，以最低 RTT 初始化，再每秒采样并限速平滑；负 RTT/异常跳变重同步。倒数起点至少领先 300 ms，未同步不得开始；race_ms 从倒数起点累计，阶段切换不重置。

无注入回环目标：独立测得时钟误差≤2 ms、倒数起点差≤100 ms。共同单调参考必须独立于估计 offset；不对称链路不能靠 RTT/2 证明误差。报告 RTT/抖动/丢包/偏移分布、有效样本和实际发送率，计时不受 time_scale 或成绩慢放影响。

`send_event` 不等快照 tick，立即带事件 ID、seat、race_ms、round_id 入可靠通道，接收去重。未来共享球采用击球方权威、固定步长确定性积分，远端从事件时刻快进并平滑修正；主机仲裁冲突/得分/出界，不假设 Jolt 确定性。回滚和击球合法性属于后续实时项目设计。

测试候选 `--net-latency=0|30|80`（单程 ms）、`--net-jitter=10`（±ms）、`--net-loss=0.05`、`--net-seed=<整数>`。发端只注入一次，队列有界、退出清空。应用层可丢 state/时钟；可靠事件用保留 ID 的测试重试，或在 transport 重传层下方丢包。报告区分 application/transport，前者不能充当真实 ENet 丢包验收。

## 6. 后续切片与验收

1. **首个独立实现切片**：在已授权 core 范围内实现纯数据 codec、会话状态转换、种子化注入队列及单测；先覆盖非法长度/profile、量化边界、旧序列/旧局、冒用 seat、重复事件和有界清理。不接菜单、发现、幽灵或报告工具；架构/协议随实现同步。本 PR 不开始此切片。
2. 再接 ENet、发现及主机权威，随后滑板/滑雪幽灵。双实例 runner 真正产出报告时，与校验器及测试放在同一个实现 PR；附录 B 只是待调整草案。
3. 自动实例用临时用户目录、`RS_TEST_MODE=1`、headless、回环和临时端口，沿用 #34；不占真实 hub 固定端口、不忽略日志错误，只结束 runner 创建的进程。需要真实 hub 时显式为两端选择互不冲突的端口对。
4. 真双实例覆盖各 demo=2、1+1、1+3、三实例座位、地图摘要拒绝、客户端无权推进、重复 finish、双方轮换主机、客户端离开与主机继续、主机离开及超时回菜单；再开第二局检查 round_id 隔离。
5. 测 20/60/120 Hz、0/30/80 ms、5% 丢包和固定种子，报告实际频率、事件尾延迟、纠正跳变、时钟误差及样本数。时延按第 1 节验收；5 m 跳变为待测目标，实时项目的可玩阈值需另定。
6. 滑板/滑雪 demo=2/4、非 LAN、暂停/重开/回放/本地纪录隔离和 smoke 回归；幽灵画面另做实际渲染验证。规范、i18n、tools/hub/Node 与隐私检查按仓库要求执行；两台真电脑的发现、防火墙、Wi-Fi 和体感延迟另测，证据只保留无设备标识的摘要。

**当前证据边界：设计记录和已有入口的源码核对。** 本 PR 无 LAN 运行时、报告生产者或校验器；没有双 Godot、真实 LAN、手柄或画面验收结果。

## 附录 A：二进制快照候选 v1

全部小端，无 Transform/Variant、隐式 padding、墙钟或尾随字节；每包 1–4 条记录。profile 1=skate、2=ski，未知 profile 整包拒绝；新实时项目另分配 profile。

| 头偏移 | 长度 | 字段 |
|---|---|---|
| 0 / 2 / 3 | 2 / 1 / 1 | ASCII `RS` / version=1 / profile |
| 4 | 16 | session_id，welcome 的原始 16 字节 |
| 20 / 24 / 28 | 4 / 4 / 4 | round_id / packet_seq / race_ms，均 u32 |
| 32 / 33 / 34 | 1 / 1 / 2 | count / record_bytes / payload_bytes=count×record_bytes |

记录内偏移从 0 起；skate/ski 分别 79/83 字节。

| 记录偏移 | 长度 | 字段与单位 |
|---|---|---|
| 0 / 1 | 1 / 1 | seat 1–4，同包唯一且属于发送者；flags bit0=finished、bit1=teleport，其余为 0 |
| 2 | 12 | x/y/z，3×i32 毫米，世界坐标约 ±2147 km |
| 14 / 15 | 1 / 6 | 四元数最大绝对分量索引 0–3；整体取反使它非负，其余分量按索引顺序量化为 `round(分量×√2×32767)` 的三个 i16 |
| 21 / 29 / 31 | 8 / 2 / 2 | 非负 i64 score / u16 progress（÷65535）/ u16 impact（÷1024） |
| 33 / 35 | 2 / 24或28 | pose_count=12或14；现有 `_record()` 的 `in` 顺序，各 i16÷1024，布尔只取 0或1024 |
| 59或63 | 12 | vx/vy/vz，3×i32 毫米/秒 |
| 71或75 | 8 | u32 score_revision、u32 已应用 place 事件序号（0=尚无） |

包长 `36+count×record_bytes`，最大 368 字节；20/60/120 Hz 每发送者最大应用负载约 7.36/22.08/44.16 KB/s，转发及协议开销另测。seq 用半区间模比较，拒绝跨度≥2³¹；单局≤30 分钟。score_revision 仅递增，results 后不再更新。

非有限数、超量化范围直接拒绝，不静默钳位。四元数三分量解码除以 `√2×32767`，平方和≤1＋0.0001 才用 `sqrt(max(0,1-平方和))` 恢复缺失分量，并在容差内归一化；无效旋转拒绝。现有姿势确为滑板 12 项、滑雪 14 项；逐项范围及量化误差仍待真实分布确认，超界即修订 profile。impact 丢包可能少一次视觉冲量；可靠音效/击球使用去重事件。

## 附录 B：双实例报告草案

以下沿用 `lan-report-draft-1` 供 runner 设计参考，**没有冻结 schema，也没有实现校验器**。等真实报告生产者落地，再一起确定版本、字段、单位和验证规则；不先提交一个校验无生产者数据的工具。

| 层级 | 候选字段与一致性 |
|---|---|
| 根对象 | schema_version/protocol_version、session_id、round_id、scenario（normal/client_left/host_left）、peer_id/host_id、game、零基 map_index、content_hash、complete/errors/last_error；测试 peer 数字与合成名字，不写设备地址 |
| roster / active_seats | 2–4 个唯一 seat；记录 peer_id、local_slot、name、bot；双报告的冻结初始名单一致，各机至少一人 |
| phases | phase、at_ms；使用早于首次 LOBBY 的共同主机单调锚点，不能直接比较两进程原始 ticks 或混用 race_ms。normal 为 LOBBY/COUNTDOWN/PLAY/RESULTS/LOBBY；客户离开后 MENU、主机受控离开后 CLOSED。首次 LOBBY 不比时刻，后续对应阶段差≤100 ms |
| results / finishes | seat、score、rank、place；完赛另有 event_id、bonus_count=1。normal 两边一致，比分按 score 降序/seat 升序；离开客户只可记录已确认 finish 的子集，不补造最终结果 |
| disconnects | peer_id、观察 at_ms、reason；采用共同锚点，但两端观察时刻可不同。观察差预算为 5 秒检测目标＋单程延迟＋抖动上界；离开者无活动名单/结果，主机离开时双方均无正常 results |
| injection | latency_ms、jitter_ms、loss、seed、layer（application/transport）；双端配置一致 |
| metrics | 目标/实际 snapshot_hz、发送/接收数、跳过 tick、ghosts_seen、有效 clock_samples、window_ms；独立时钟误差、事件 p50/p95/p99、最大跳变、RTT/抖动/偏移分布；无注入时钟误差目标≤2 ms |

报告须 UTF-8、有大小/字段/容器限额，拒绝重复 key、布尔冒充数值及 NaN/Inf。正常完成包含回大厅；受控离开在清理后各自写报告。硬杀只能留下不完整检查点，不能补 complete=true；由 runner 单独核对幸存者及退出归属。单局双报告不能替代跨局、三实例、发现、视觉或真机验收，声明一致也不能证明测量可信。
