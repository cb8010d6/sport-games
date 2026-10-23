# 局域网联机设计提案（#23）

**状态：供维护者审阅，尚未实现。** 本文不表示游戏已经支持 LAN；现有手机 Wi-Fi 接入仍是单机手柄。此次仅新增本文及离线报告校验器，不修改架构、协议或游戏运行时。下文的类、参数、消息、字节布局与验收都是后续实施约定的候选方案；维护者同意后，先更新 `ARCHITECTURE.md`、`protocol.md`，再分片实现。

## 1. 范围与待决策

MVP 为两台及以上电脑各运行游戏和自己的 hub，各自分屏；仅开放滑板、滑雪，远端为无碰撞幽灵。每台电脑只模拟本地玩家与机器人；不转发 200 Hz 手柄数据。其他运动、派对大赛、共享球体预测与超过四人均不在 MVP。

| 维护者决定 | 推荐方案与理由 |
|---|---|
| 生命周期、人数与加入 | 不加 autoload；常驻节点；合计 2–4 人，每机至少一人；仅大厅接纳加入，比赛加入明确拒绝，下一局自行重试。保留四档配色与名次奖励。 |
| 暂停、离开与排名 | LAN 暂停为不冻结比赛的覆盖层，客户端无重开；无主机迁移、无局中重连。客户端离开移除活动名单与幽灵，本局结果不含离开者，审计名单保留。主机离开所有人回菜单；超时目标 5 秒，实际 ENet 检测行为须测试。 |
| 构建、档案与成绩 | 协议版本、构建摘要、目录/地图内容摘要全部匹配才接纳；档案与视口沿用本地槽，LAN 结果暂不写个人纪录/挑战星数，避免把新规则写进旧成绩。派对积分第二阶段单独确认。 |
| 高频事件验收 | 所有网络档位均要求事件产生后至发送入队不超过一个物理 tick。无丢包时接收处理不超过注入单程延迟与抖动上界加一个 tick；有丢包时另报 p50/p95/p99、重传与超时。可靠重传无法保证 5% 丢包下每个事件仍只多一个 tick，不能以合成报告宣称原目标已满足。 |

以上均是建议，未获得维护者批准。下一实施 PR 须记录决定；选项改变须先同步本文及报告版本。

## 2. 跨区改动与兼容边界

| 后续文件 | 需要的改动与归属 |
|---|---|
| `game/core/net_session.gd`、`net_discovery.gd`、`net_remote.gd` 及 `.uid` | 框架：会话/收发/时钟/测试注入；发现；远端状态缓冲。不依赖项目类。 |
| `game/core/party_game.gd`、`party_ui.gd` | 框架：LAN 生命周期分支、默认钩子、名单与成绩显示，避免挪动 HUD 或样式。 |
| `game/core/tournament.gd`、`catalog.gd` | 第二阶段才改派对赛全局身份；MVP 只允许 skate/ski，不能直接把本地槽积分当全局座位积分。 |
| `game/scenes/menu/main_menu.gd`、新增 `lan_page.gd` 及 `.uid`、`game/core/pause_menu.gd` | 框架：独立页面、参数入口、暂停条件；复用已有 RSUi，不重写样式。 |
| `game/scenes/skate/skate_game.gd`、`game/scenes/ski/ski_game.gd` | 项目：幽灵、全局起跑位、完赛去重、计时与远端进度点；抽出已有回放姿态应用函数。 |
| `docs/ARCHITECTURE.md`、`docs/protocol.md` | 维护者先记录公共模块、权威、版本与全部消息，本文不能代替正式协议。 |
| `game/i18n/en.json` | 共享区只追加相关中文 key 的英文；网络名字转义富文本。 |
| `game/tests/test_lan.gd`、`.tscn`、`.uid`、`tools/test_lan.py` | 后续真正的双/三实例驱动、报告生产者；当前不存在本提案对应的实现。 |

`ControllerHub` 继续是唯一 autoload；无需修改 `project.godot` 的 120 Hz 物理设置。`RSNetSession.ensure(tree)` 幂等创建 `tree.root` 的直属常驻节点，保留引用或用组查找，不使用绝对节点路径。节点不归 `current_scene`，`PROCESS_MODE_ALWAYS`；退出时关闭 ENet、信标、队列并解除信号，重入不得重复创建。默认保留 `SceneTree.multiplayer_poll=true`，不另加第二次 poll；暂停、切场景期间收发须用 Godot 4.7.2 实测后确认。

现有 `players`、`ordered()`、`ranked_players()` 始终仅含本地 Player，分屏、OLED、相机、回放和领奖台继续使用它们。新增 `ranked_all()` 返回纯数据行，不暴露远端 `p.data`。建议新增钩子默认行为：

| 接口 | 非 LAN 默认 / LAN 约定 |
|---|---|
| `is_lan()`、`is_lan_host()`、`remote_players()` | `false`、`false`、空列表 |
| `seat_of(p)`、`start_index(p)`、`start_count()` | 原本地槽、原排序索引、原本地人数；LAN 按冻结的全局名单 |
| `name_of/color_of/avatar_of` | 非 LAN 原实现；LAN 从名单快照取显示属性，头像仍由各玩家自己的本地档案上报 |
| `_net_tick_hz()`、`_net_sync_mode()` | `20`、`ghost`；未来项目声明 `60/120` 与 `predictive` |
| `_net_snapshot(p)`、`_net_event(seat, kind, data)` | 默认仅 score / 空操作；项目对象由会话编码器适配，不在 core 引用滑板/滑雪类 |
| `_remote_added/removed/step`、`send_event(kind, data)` | 非 LAN 空操作；LAN 立即入可靠发送路径，不能等下一快照 |

不修改旧签名，不把远端设备伪装成 `RSController`。所有新增参数仅在 `party_game.gd`、`main_menu.gd` 解析并交给会话配置；项目不重复解析。

## 3. 身份、状态机与权威

传输 peer 身份来自 ENet 回调，不能信任包内自称的 peer。主机分配全局 seat 1–4：主机本地槽升序优先，其余按加入顺序；`(peer_id, local_slot)` 唯一。本地槽仍为各机自己的 1–4，可同时有多个本地 P1；全球颜色与起跑序号按 seat，存档和视口图层按 local_slot。大厅名单有递增 `roster_revision`；进入倒数后冻结，不压缩离开者的座位。回大厅才可重分配，旧包以 round_id/revision 拒绝。

会话状态：`OFFLINE → CONNECTING → LOBBY → LOADING → COUNTDOWN → PLAY → RESULTS → LOBBY`；加入拒绝、主机离开、5 秒检测超时或协议致命错误进入 `CLOSING → OFFLINE`，菜单显示 `last_error`。游戏仍使用原有四个 Phase；CONNECTING/LOADING 不额外冒充游戏阶段。主机本地玩家也通过相同命令验证路径，避免两套计分规则。

| 内容 | 权威与顺序 |
|---|---|
| 名单、准备、地图与加载 | 主机广播 roster；全员 ready 后 load，所有 peer 回 ready（含内容摘要与加载确认）才下发 countdown。加载超过 10 秒取消回大厅。 |
| 倒数与计时 | 主机给出未来的共享时钟起点与比赛截止时间；客户端只跟随，不因本地全员 ready 或时间归零自行开局/结束。 |
| 本地运动、手势与基础得分 | 所属机器；主机检查 seat 所属、范围、时间及阶段后转发。MVP 是可信 LAN，并无反作弊保证。 |
| finish/place/AFTER_FIRST | finish 带事件 ID 与比赛时间；主机按接收的有效 finish 顺序分配唯一 place，时间仅作有效性检查与展示，不声称公平校正网络延迟。首位将截止时间收紧到 `min(原截止, 主机当前比赛时间+25秒)`，可靠广播。 |
| 奖励与结果 | 主机保存每 seat 唯一 finish 及奖励事实；广播 place，所有本地只应用一次，重复请求回同一确认。最终基础分+奖励由主机封存为唯一 results；断线者移出最终排名，已发 place 不重排。比分并列用竞赛排名 1,1,3，行顺序按 score 降序/seat 升序，finish place 与 score rank 是两个字段。 |
| 结果返回与派对赛 | 只有主机发 lobby/下一项目；客户端 A 不推进。MVP 不调用 LAN 派对积分，第二阶段由主机唯一记账再广播。 |

主机断线不宣告正常结果；客户端回菜单清理幽灵与状态。客户端断线后主机继续，保留审计记录但不再等待它 ready/finish；断线后的旧事件和快照无效。无重连恢复令牌、无互联网穿透、无主机迁移。

## 4. 连接、消息与输入边界

建议 ENet UDP 47810、发现 UDP 47811，避开 hub 的 47800/47801/47802/47843。后续参数：`--lan-host`、`--lan-join=<IP>`、`--lan-bind=<IP>`、`--lan-port=<端口>`、`--lan-discovery-port=<端口>`、`--lan-report=<相对输出文件>`。端口限 1024–65535 且两者不同；绑定地址由用户选。产品 IPv4 广播每秒一次，3 秒过期，手动 IP 为兜底；多网卡/IPv6 自动发现留待后续，不自动改防火墙。

发现包候选为 `{"t":"rs_lan","v":1,"name":"测试主机","port":47810,"game":"ski","players":2,"open":true}`，UTF-8 JSON，最多 512 字节、名字最多 48 个 UTF-8 字节；只显示信息，加入后必须重新握手校验，发现源地址不作为身份认证。所有回环自动测试 bind `127.0.0.1`，发现也只向它单播；禁止测试默认绑定所有网卡。

ENet 建连 → 客户 hello → 主机 welcome/reject → roster → ready → load → 加载 ready → map/countdown → 二进制 state 与即时 event/finish/place → results → lobby。低频字典统一 `v,t,session_id,round_id,seq`，每条限制字段与范围；`hello` 可尚无 session_id，welcome 下发主机随机的 128 位会话 ID。round_id 每局递增，seq 每发送者递增；重发同 event_id 幂等。主机转发时保留已核验的原始所属 seat，客户端只接纳来自主机的广播。

| 消息 | 发起方 / 关键内容 | 传输 |
|---|---|---|
| hello / welcome / reject | 客户构建、协议、目录摘要、本地玩家；主机分配名单或拒绝原因 | channel 0，可靠 |
| roster / ready | 主机完整名单 revision；客户本地准备与加载确认 | channel 0，可靠 |
| load / map / countdown / lobby | 主机项目、地图索引/种子/关键点摘要、未来共享时刻、截止时刻 | channel 0，可靠 |
| event / finish / place | seat、event_id、比赛时间、类型化负载；finish→主机；place→所有人 | channel 0，可靠，立即发送 |
| results / leave | 主机完整成绩、结果 revision；主动离开及原因 | channel 0，可靠 |
| clock_ping / clock_pong | 四时刻采样；丢失即可用下一样本 | channel 2，不可靠无序 |
| state | 下节固定二进制帧 | channel 1，不可靠有序 |

创建连接显式分配至少 3 个 channel，关闭 `SceneMultiplayer.server_relay`，客户只发主机，由主机验证后显式转发，不能让默认中继绕过权限检查。可靠消息建议 `var_to_bytes` 字典、不编码对象，接收 `bytes_to_var(packet)`；禁止 `bytes_to_var_with_objects`，保持 `SceneMultiplayer.allow_object_decoding=false`。先限制至 4096 字节，再检查仅允许的字段/标量/浅数组（最大深度 4、每数组最多 16 项），不容许对象、Resource、Node、Callable 或动态调用方法名。超大包在解码前拒绝；Godot Variant 解码器的畸形长度分配风险须在实施时专项审查，必要时改成有固定 framing 的有界 JSON。未知版本/必填字段缺失/NaN/Inf/非法枚举/越界 seat/越权/旧局包均拒绝并计数；同 peer 持续非法输入断开。可靠控制限 50 条/秒，state 限项目频率加 10%，排队上限 256 条/peer，超限断开并记录原因。

API 依据：[SceneMultiplayer.send_bytes/peer_packet](https://docs.godotengine.org/en/stable/classes/class_scenemultiplayer.html)、[ENetMultiplayerPeer 绑定与频道](https://docs.godotengine.org/en/stable/classes/class_enetmultiplayerpeer.html)、[SceneTree.multiplayer_poll](https://docs.godotengine.org/en/stable/classes/class_scenetree.html)、[bytes_to_var](https://docs.godotengine.org/en/stable/classes/class_%40globalscope.html#class-globalscope-method-bytes-to-var)。stable 文档会变化；落地必须锁定仓库的 Godot 4.7.2 核验。传输只面向同版本 Godot；不承诺与其他 ENet 实现互通。

## 5. 二进制快照候选 v1

全部小端；不直接序列化 Transform/Variant。不携带系统墙钟。每包最多 4 条、负载最多 368 字节（不含 Godot/ENet/UDP 开销），禁止尾随字节和隐式 padding。每个项目使用注册的固定 profile，未知 profile 整包拒绝；未来实时项目必须分配新 profile，不把球拍塞入现有空字段。

| 偏移 | 长度 | 字段 / 单位 |
|---|---|---|
| 0 | 2 | magic，ASCII `RS` |
| 2 | 1 | version=1 |
| 3 | 1 | profile：1=skate，2=ski |
| 4 | 16 | session_id，welcome 的 16 原始字节 |
| 20 | 4 | round_id，u32 |
| 24 | 4 | packet_seq，u32，按发送者递增 |
| 28 | 4 | race_ms，u32，自本局倒数起点累计毫秒 |
| 32 | 1 | count，1–4 |
| 33 | 1 | record_bytes，skate=79、ski=83 |
| 34 | 2 | payload_bytes=count×record_bytes，u16 |

记录偏移从每条起点计算，位置采用世界坐标米 → 毫米 int32，支持约 ±2147 km；不用会截断长雪道的 int16。

| 记录偏移 | 长度 | 字段 |
|---|---|---|
| 0 | 1 | seat，1–4，同包唯一且属于该发送者 |
| 1 | 1 | flags：bit0=finished，bit1=teleport，其余必须 0 |
| 2 | 12 | x/y/z，3×i32 毫米 |
| 14 | 1 | quaternion 最大绝对分量索引 0–3；先整体取反使该分量非负 |
| 15 | 6 | 剩余三分量按分量索引顺序，各 i16，值=分量×√2×32767，四舍五入；解码除同一系数，缺失分量取正平方根 |
| 21 | 8 | score，i64 非负 |
| 29 | 2 | progress，u16，0–65535 表示 0–1 |
| 31 | 2 | impact，u16，值/1024，范围 0–约64 |
| 33 | 2 | pose_count，u16，skate=12、ski=14 |
| 35 | 24 / 28 | 依现有 `_record()` 的 `in` 顺序，各 i16，值/1024，范围约 ±32；所有字段须有逐项范围检查，布尔姿势只取 0 或 1024 |
| 59 / 63 | 12 | vx/vy/vz，3×i32 毫米/秒，供外推 |
| 71 / 75 | 8 | 本地 score_revision，u32；已应用 place 事件序号，u32（0=尚无） |

总长 `36+count×record_bytes`，ski 四人 368 字节；20/60/120 Hz 时单机应用负载约 7.36/22.08/44.16 KB/s，主机转发、协议开销及双向流量另计，必须实测。score_revision 只递增，不能用过期 state 覆盖已确认奖励；results 封存后不接受 score 更新。u32 seq 用半区间模比较，拒绝相差 ≥2³¹ 的歧义；单局最长 30 分钟，race_ms 不在一局内回绕。编码前非有限浮点和超量化范围直接拒绝，不能静默钳位；解码校验四元数剩余平方和 ≤1+量化容差（建议 0.0001），仅容差内归一化，零/无效旋转拒绝。

姿势和 rig 显示沿用现有回放帧格式，经适配送入 `RSReplay.record/sample` 的独立网络窗口，不能复用成绩回放游标。滑板姿势 12 项、滑雪 14 项的实际范围及量化误差尚须用录制分布确认；上限不足即修订 profile，不能带着溢出发布。impact 是快照采样量，丢包可少一次视觉冲量；需要可靠的音效/击球使用 event ID，不能依赖重复快照重复触发。

## 6. 时钟、频率与即时事件

现有物理为 120 Hz；20/60/120 Hz 分别每 6/2/1 个物理 tick 采样，网络节奏与渲染分离。卡顿后最多发当前状态，不补发旧快照形成突发；记录实际频率、跳过 tick、发送/接收数。`ghost` 模式按共享比赛时钟减 100 ms 采样，最多外推 250 ms 后冻结并标记；teleport 或位移 >5 m 清窗口并跳转。实时 `predictive` 模式禁用固定 100 ms 延迟，使用测量抖动的最小缓冲、速度外推与短时修正，不能仅改频率便声称实时项目可玩。

时钟服务可用单调微秒时钟（需维护者给网络同步明确时间来源例外，不替代玩法 delta）；t1 客户发送、t2 主机收到、t3 主机回发、t4 客户收到，RTT=`(t4-t1)-(t3-t2)`，主机减客户偏移=`((t2-t1)+(t3-t4))/2`。握手收集至少 8 个有效样本，取最低 RTT 样本初始化，之后每秒采样、滑动窗口最低 RTT 与限速平滑；负 RTT/超大跳变丢弃并重新同步。倒数 start 建议至少领先 300 ms，不足先重排，加载完成但未同步不得开局。比赛时间从倒数起点累计；阶段切换只改变阶段起点，不重置网络时间。

目标无注入回环共享时钟误差 ≤2 ms、倒数起点差 ≤100 ms；误差要用同机共同单调参考独立测量，不能拿估算 offset 本身当误差。注入不对称链路时 RTT/2 无法证明真实误差 ≤2 ms，另报误差分布。调试叠加层与报告记录 RTT/抖动/丢包/偏移的 p50/p95/p99 与样本数；计时不受 Engine.time_scale、成绩慢放或菜单影响。

`send_event` 立即加 `event_id,seat,race_ms,round_id` 入可靠 channel，不等采样 tick；收方去重并按时间处理。未来球体使用项目的固定步长确定性积分，击球方本地判断后立即发送位置/速度/旋转，接收端从事件时刻快进并平滑修正；共享球不使用 Jolt 确定性假设。冲突由主机按事件时刻仲裁，得分/出界主机定；回滚、冲突窗口与击球合法性属于实时项目后续设计，本次不实现。

仅测试启用 `--net-latency=0|30|80`（毫秒，单程）、`--net-jitter=10`（对称有界 ±毫秒）、`--net-loss=0.05`、`--net-seed=<整数>`；发端统一注入一次，接收不再重复加延迟。快照与非可靠时钟包可在应用层按种子丢弃；可靠事件不可直接扔掉就声称 ENet 会重发，须用保留同 event_id 的测试重试模拟，或在测试 transport adapter 的重传层下方丢包。报告分别注明 `application` 与 `transport`，前者不能算真实 ENet 丢包验收。队列有界，退出清空；不修改系统网络或防火墙。

## 7. 双实例报告 schema draft-1 与校验器

`tools/lan_report.py` 是当前唯一新增的可运行功能：离线校验两个 JSON，不启动 Godot、不生成测量、不验证网络包解码，也不证明画面平滑。所有字段必填，不接受额外字段；数值不得是布尔值/NaN/Inf。文件 UTF-8、≤1 MiB、不得重复 key。机器用测试 peer 数字、玩家用合成名字，不写设备地址或真实资料。

| 层级 | 字段与约束 |
|---|---|
| 根对象 | `schema_version="lan-report-draft-1", protocol_version=1, session_id`（32 位小写十六进制）、`round_id`（1..u32）、`scenario`（normal/client_left/host_left）、`peer_id,host_id`（正整数）、`game`（skate/ski）、`map_index`（零起；当前 skate 仅 0、ski 为 0–3，和现有目录一致）、`content_hash`（64 位小写十六进制）、`complete=true, errors=[], last_error`（字符串；正常场景为空，离开端非空） |
| 根数组 | `roster, active_seats, phases, results, finishes, disconnects`；名单 2–4 人、恰有两台 peer，每机至少一人；两报告 peer 不同、唯一一份为 host_id |
| `roster[]` | `seat,peer_id,local_slot,name,bot`；seat 全局唯一、1–4，(peer_id,local_slot) 唯一，local_slot 1–4、name 1–48 UTF-8 字节、bot 为 bool；两边初始冻结名单完全一致 |
| `phases[]` | `phase,at_ms`；采用本会话主机单调时钟的共同锚点为 0（早于首次 LOBBY），有限非负毫秒且严格递增；不是各进程原始 ticks，也不是从 COUNTDOWN 开始的 race_ms。normal 为 LOBBY/COUNTDOWN/PLAY/RESULTS/LOBBY；client_left 主机同 normal、客户前三阶段后 MENU；host_left 主机前三阶段后 CLOSED、客户前三阶段后 MENU。比较 COUNTDOWN/PLAY 及正常完成时 RESULTS/再次 LOBBY，差 ≤100 ms；首次进入 LOBBY 可因晚加入相差数秒，不比较 |
| `results[]` | `seat,score,rank,place`；score 非负 i64；rank 按分数竞赛排名，place=0 表示未完赛。结果严格按 score 降序/seat 升序覆盖 active_seats；normal 两边完全一致 |
| `finishes[]` | `seat,event_id,place,bonus_count`；每 seat/event_id/place 唯一、bonus_count=1、place 从 1 连续。normal 两边完全一致；离开的客户只持有主机已确认列表的子集，不能虚构未收结果 |
| `disconnects[]` | `peer_id,at_ms,reason`；normal 空；client_left 两边恰一条客户记录，主机 active_seats 不含客户、客户空结果/活动名单；host_left 两边恰一条主机记录、都无结果/活动名单。at_ms 是各端观察时刻，沿用主机会话锚点，不是同一个发起事件时间；须在该端 PLAY 与 RESULTS/MENU/CLOSED 之间。两观察差不超过 5000 ms 检测目标+单程注入延迟+抖动上界，原因非空；超时目标仍须后续 ENet 实测 |
| `injection` | `latency_ms,jitter_ms,loss,seed,layer`，前两项 0..500，loss 0..1（小于 1）、seed 为 u32，layer 为 application/transport，两边相同 |
| `metrics` | `snapshot_hz` 为 20/60/120；`sent_snapshots,received_snapshots,ghosts_seen,clock_samples` 正整数；`window_ms` ≥1000；`max_clock_error_ms,event_latency_p99_ms,max_remote_jump_m` 有限非负；`rtt_ms,jitter_ms,offset_ms` 各含 p50/p95/p99（有序，offset 可负）。实际发送率与目标偏差 ≤10%，ghosts_seen 等于对方初始人数；无注入误差 ≤2 ms |

校验器只对报告声明与一致性负责；指标本身的可信采集由后续驱动负责。normal 的双报告必须完整包含回大厅；受控断线场景允许双方在清理后分别写报告，异常杀进程只能留下不完整检查点，不得补 `complete=true`。硬杀场景须后续驱动单独验证幸存者和退出进程归属，不能拿残缺报告调用本校验器骗过验收。当前 schema 一次只描述一局；跨局重开、三实例、发现与视觉须另有测试，后续扩展须升 schema 版本。

```bash
python -m unittest discover -s tools/tests -p test_lan_report.py
python tools/lan_report.py out/host.json out/client.json
```

退出码 0 仅为“两份报告符合 schema 且声明一致”；退出码 1 为报告失败，2 为命令用法错误。单元测试全部使用合成报告，是验证器测试，不是 Godot/LAN 的通过证据。

## 8. 后续实施验收与证据

1. 维护者确认第 1 节及跨区接口，正式协议/架构先行；小片实现 codec、状态机与注入单测，再接滑板/滑雪。非法长度、未知 profile、边界量化、旧序列、重复事件、冒用 seat、NaN/Inf 都有拒绝测试。
2. 真实双实例只在 `RS_TEST_MODE=1` 下用临时 APPDATA/XDG 目录，`--headless`、loopback 和临时空闲端口；分别 demo=2，以真实产生的报告验证地图、名单、阶段、结果与返回大厅。另测 demo=1+1、1+3 与三实例座位。runner 只结束自己创建的进程。
3. 第二实例的 hub UDP 47800 冲突不得依赖环境偶然空闲：推荐维护者添加测试专用不绑定 hub 的入口，沿用现有参数解析层；未获批准前不以全局忽略 engine error 解决。允许日志例外也须逐条精确限定并保留其他错误检测。
4. 同机测试发现单播、手动加入、错误版本/地图摘要拒绝、主机选图、客户端按键无权推进、重复 finish 奖励仅一次、客户端断线与主机继续、主机断线与客户端在超时内回菜单。轮换两端角色，再正常重开第二局验证 round_id 隔离。
5. 测 20/60/120 Hz，以及 0/30/80 ms、5% 丢包、固定种子；保存真实发送率、有效样本数、丢包/RTT/时钟/事件分布、每轮差异报告。实际接收事件尾延迟、纠正跳变阈值需维护者确定，再由 runner 判定；本离线工具不把任意 p99 或位移数值自动当“可玩”通过。
6. 滑板/滑雪各 demo=2/4 与非 LAN 回归、smoke、暂停/重开/回放/本地纪录隔离；双实例幽灵截图/录像检查须另做渲染验证。无注入跳变建议 ≤5 m（显式 teleport 除外），这是待测目标。
7. 提交前规范/i18n/tools/hub/Node/隐私检查；两台真电脑的发现、多网卡、防火墙、Wi-Fi 尖峰和体感链路延迟由维护者实测，报告用摘要不含设备标识。

**当前证据边界：仅设计审阅与离线校验器的合成单元测试。** 未实现上述运行时接口、未运行双 Godot、未测实际 LAN/手柄/画面；#23 的完整 MVP 验收仍待后续跨区实施。
