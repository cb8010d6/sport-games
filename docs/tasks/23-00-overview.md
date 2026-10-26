# #23 · 局域网联机 MVP 拆分 · 框架 + 滑板/滑雪 + 工具

## 目标 / 范围外

以 `209897f4573208e02df52c4c929731a27d3527b1` 的 [LAN_PLAY](../LAN_PLAY.md) 为拆卡基线；该文件与原已采纳的 LAN 设计内容未变，本轮不修改设计记录。范围仍为 2–4 人、每机至少一个本地玩家，各机模拟本地玩家与机器人，滑板/滑雪远端为无碰撞幽灵。产品尚无 LAN 运行时；本组文档不构成已运行、已测量的证据。

本轮仅新增任务卡及追加索引；实施时每卡一个 PR，目标 `dev`。不做其他运动、派对大赛、共享球、predictive、回滚、主机迁移、局中重连或完整联机平台。用户最终自己试玩；卡内验收均为 headless。

**本组卡的所有网络源与目标均限定 `127.0.0.1`**：ENet、发现、注入测试、报告参考时钟也适用。拒绝 `0.0.0.0`、其他回环别名、主机名、局域网 IP、公网及广播。这覆盖 LAN_PLAY 的旧广播/任意 bind 候选，不保留解除限制的选项。

## 先读

1. [AGENTS.md](../../AGENTS.md)：分区授权及提交前检查。
2. [任务索引](README.md)：八节格式、领卡、两行测试注册、接口变更规则。
3. [LAN_PLAY.md](../LAN_PLAY.md)：第 1–6 节及附录 A/B。

## 改动文件

本轮只允许 `docs/tasks/23-*.md` 及 `docs/tasks/README.md` 的 #23 追加索引；不改既有状态列。

未来运行时授权逐卡精确列出；**框架文件只有卡内列明的路径获准**，不是对整个目录的授权。三个新增 core 文件仅为 `net_session.gd`、`net_remote.gd`、`net_discovery.gd` 及其 uid。不得据此增加第四个 core 文件、autoload 或修改 `project.godot`。

## 接口契约

### 兼容性与 23-01 的冻结门槛

有界 UTF-8 JSON、下述分 channel 序列、SHA-256 算法及本机地址限制已选定。精确内容输入清单、姿势范围及原名次奖励来源尚无源码/运行证据，由 [23-01](23-01-wire-core.md) **同实现 PR**交付并更新本节、正式协议和后续卡；不得另开纯文档前置 PR，不得手填相同摘要冒充证据。

摘要输入路径相对 `game/`，使用仓库规范大小写及 `/`，拒绝绝对路径、反斜杠、空段、`.`、`..`；按路径 UTF-8 字节序排序，重复路径拒绝。输入为 UTF-8 域标签 `RS_LAN_V1:<kind>\0`，随后每项依次拼接小端 u32 路径字节数、路径字节、小端 u64 内容字节数、原始内容字节，最后 SHA-256，输出 64 位小写 hex。kind 为 `build`、`catalog`、`map:<game>:<map_index>`。确切 build/catalog/map 输入集合、目录与地图关系、导出包可读性均须 23-01 证明；如需新构建产物或其他文件，先列路径需求给维护者，不擅自添加。

23-01 必须列出 skate 12 项/ski 14 项姿势的索引、源字段、单位、布尔项、范围依据、量化误差；来源为两项目 `_record()`。没有范围证明时需边界及实际 demo 数据，并明确其证据限制；无法确定安全范围就不得标完成。发现候选范围不够，同 PR 修订 profile、协议及依赖卡，禁止静默钳位。

### 消息封套、类型和通道

控制封套仅允许 `v,t,session_id,round_id,seq,body` 六个字段。v=1；session_id 为随机 128 位会话的 32 位小写 hex；round_id 为 u32，主机逐局递增。hello/reject 仅在 CONNECTING 使用空 session、round 0；welcome 仅接受当前连接的主机。peer 身份来自 ENet 回调，负载不能声明自己的 peer。

封套/所有 body 都拒绝未知或缺少字段。解码前限 4096 字节，有界词法扫描先拒绝重复 key、深度>4、数组>16、非法 JSON 数字，再解析；禁止对象解码、任意 Variant、动态方法名。整数须有限、无小数且非 bool；微秒为 0..2^53-1；u32 为 0..2^32-1。score/bonus 使用规范十进制字符串（仅 `0` 或无前导零的数字，范围 0..2^63-1），运算检查溢出。hash 为 64 位小写 hex，game 仅 `skate|ski`，map_index 为零基 u16，seed 为 u32。

下表的字段集合均为必填且穷尽；R=可靠，U=不可靠，O=有序。C→H 指客户发主机，H→C 指主机广播/回复；主机本地命令也走同一验证路径。

| t | channel / 模式 / 方向 | body |
|---|---|---|
| hello | 0 / R / C→H | `build_id:hash,catalog_hash:hash,players:LocalPlayer[]` |
| welcome | 0 / R / H→C | `host_peer:int>0,roster_revision:u32,roster:RosterRow[]` |
| reject | 0 / R / H→C | `code:Reason` |
| roster | 0 / R / H→C | `roster_revision:u32,roster:RosterRow[]` |
| ready | 0 / R / C→H | `roster_revision:u32,ready:bool` |
| load | 0 / R / H→C | `roster_revision:u32,game,map_index,map_hash:hash,seed` |
| loaded | 0 / R / C→H | `roster_revision:u32,map_hash:hash` |
| countdown | 0 / R / H→C | `roster_revision:u32,start_host_us:us,deadline_host_us:us` |
| finish | 0 / R / C→H | `roster_revision:u32,seat:u8,event_id:EventId,race_ms:u32,base_score:score,score_revision:u32` |
| place | 0 / R / H→C | `roster_revision:u32,seat:u8,event_id:EventId,place:u8,bonus:score,score_revision:u32,place_seq:u32,deadline_host_us:us` |
| results | 0 / R / H→C | `result_id:ResultId,roster_revision:u32,rows:ResultRow[]` |
| lobby | 0 / R / H→C | `roster_revision:u32` |
| leave | 0 / R / 双向 | `reason:Reason` |
| clock_ping | 2 / U 无序 / C→H | `ping_id:u32,t1:us` |
| clock_pong | 2 / U 无序 / H→C | `ping_id:u32,t1:us,t2:us,t3:us` |
| state | 1 / UO / C→H→C | 附录 A 固定二进制，不使用 JSON 封套 |

`LocalPlayer={local_slot:1..4,name:String,avatar_id:String,bot:bool}`；每机 1–4 项、槽唯一。name/合法 avatar_id 最多 48 UTF-8 字节；avatar_id 只允许冻结的本地显示属性键，不当作资源路径执行。`RosterRow` 为 LocalPlayer 加 `seat:1..4,peer_id:int>0`。名单总人数 2–4；主机本地槽升序优先，其余按加入顺序，`(peer_id,local_slot)` 唯一；配色按四档 seat，不接受客户自定颜色。

`ResultRow={seat:1..4,base_score:score,bonus:score,total_score:score,rank:1..4,place:0..4}`；place=0 表示未完赛，rank 用竞赛排名 1,1,3，行按 total_score 降序/seat 升序。`EventId="<seat>:<event_seq>"`，event_seq 从 1 递增，本局不回绕；`ResultId="<session_id>:<round_id>"`。Reason 仅允许 `bad_version,bad_build,bad_catalog,bad_map,bad_packet,bad_owner,busy,full,not_ready,load_timeout,peer_left,host_left,timeout,closed`。

MVP `send_event` 仅接受 kind=`finish`，类型化 data 为 `{base_score:int,score_revision:int}`；session 添加 seat/event_id/race_ms 并编码为 finish。其他 kind、独立 event/map 消息均不在 v1 白名单中，不开放任意 data。新类型需同时修订协议及依赖卡。

控制 seq 按 `(sender_peer,channel)` 分流；state packet_seq 是 channel 1 自己的流。u32 半区间模比较：重复/旧值及跨度≥2^31 拒绝；时钟 pong 另匹配未完成 ping_id。至少三 channel；关闭 `SceneMultiplayer.server_relay`，客户端只发主机、只接主机权威广播，保持 `multiplayer_poll=true` 不重复 poll。主机转发控制/事件使用自己的channel0 seq，保留原seat/event_id；MVP finish确认place也使用主机新封套。转发state重新编码为主机channel1统一连续packet_seq，保留原seat/race_ms/记录；不能透传各客户从1开始的序号，不增加origin_peer等协议字段。

### 快照、限额、时钟

快照采用 LAN_PLAY 附录 A 候选 v1：小端、36 字节头、skate 79 字节/ski 83 字节记录、每包 1–4 项、最大 368 字节；无尾随字节。session/round/seq/profile/count/record_bytes/payload_bytes、seat 唯一及归属、保留 flags、量化边界全部验证。未知 profile 整包拒绝。精确姿势 profile 须经过上述 23-01 门槛，不能当成已发布协议。

codec内部state字典严格为 `{v,profile,session_id,round_id,packet_seq,race_ms,records}`；记录为 `{seat,finished,teleport,position,rotation,base_score,progress,impact,pose,velocity,score_revision,place_seq}`。position/velocity为米及米每秒Vector3，rotation为单位Quaternion，pose为冻结顺序的数值数组，其余字段按附录A；这些内部数学值不走JSON/Variant对象解码，二进制逐字段读写。counts/bytes由codec计算并与包头核对，不信任调用方自报。

state 的 score 只表示基础分；奖励与最终事实由主机单独存储，score_revision 只递增，旧 state 不撤销奖励。单局≤30分钟，race_ms≤1800000；RESULTS 不再接受基础分更新。

每 peer 控制 channel 0 最多 50 条/滚动秒；state按原所属peer最多ceil(hz×1.1)条/滚动秒，每包记录必须来自同一原所属peer（由冻结seat表推导）。客户接主机转发时分原所属peer计桶，并限主机合计≤该上限×活动来源peer数；不能把多来源正常转发误判为一个来源超频。主机入口仍核对原所属peer=ENet发送者。clock最多20条/秒（初始八样本），同步后最多2条/秒。每peer待发送队列≤256包，满则返回错误，不静默丢可靠包；非法包计数，滚动一秒达10次断开，版本/归属等致命错误直接拒绝。退出、切离会话清队列和计数。

网络用单调微秒，不改变玩法 delta，不受 time_scale/暂停覆盖层/成绩慢放影响。t1/t4 属客户单调域，t2/t3 属主机单调域：

```text
RTT = (t4-t1) - (t3-t2)
host_minus_client_offset = ((t2-t1) + (t3-t4)) / 2
estimated_host_us = client_local_us + offset
race_ms = floor(max(0, estimated_host_us-start_host_us) / 1000)
```

主机 offset=0。客户先以50ms间隔取至少8个有效样本，最低 RTT 初始化；以后每秒取样，采用最近8样本最低 RTT 为目标，offset 每秒最多调整500us。负 RTT、目标跳变>50000us 或5秒无有效样本清同步状态并重新取8样本；未同步不得开始。倒数起点≥主机当前时间+300000us。race_ms 从该起点累计，阶段切换不重置。

120Hz物理下20/60/120Hz每6/2/1 tick发当前快照，卡顿不补发旧包。ghost 取 estimated_host_us-100000us，位置 lerp、四元数 slerp、姿势线性插值；最多外推250ms后冻结；teleport或跳变>5m清窗口。网络窗口独立于回放。

### 权威、幂等与结果视图

状态为 OFFLINE→CONNECTING→LOBBY→LOADING→COUNTDOWN→PLAY→RESULTS→LOBBY；拒绝/主机退出/超时/致命协议错进入 CLOSING→OFFLINE。所有 ready+loaded 且时钟就绪才倒数；加载10秒超时回大厅。主机独占推进、未来起点与截止时刻；本地命令不绕过校验。

load 冻结本局名单及其 revision；局中不接纳加入、不压缩 seat。局数据中的 roster_revision 指冻结 revision；活动名单离开时另递增当前 roster_revision，不改变冻结 seat 映射。state 由 round_id 找冻结名单，已移除 seat 不再接收。

主机按有效 finish 收到顺序分配唯一 place；基础分/finish/bonus 事实每 seat 一次，重复 EventId 返回相同确认。首位 finish 把截止收紧为 min(旧截止,主机当前时刻+25秒)，通过 place 可靠广播。奖励沿用 23-01 核对的旧规则；不宣称延迟公平或反作弊。

finish/score/bonus 事实仅封存一次。离开者从活动名单/幽灵/排名视图移除，审计名单保留，已发 place 不重排；同 ResultId 可按新的当前 roster_revision 发布新 rows。结果视图幂等键为 `(session_id,round_id,result_id,roster_revision)`：同 revision 无操作，旧 revision 拒绝，新 revision 只更新显示；结算幂等键为 `(session_id,round_id,result_id)`，绝不再次发奖或结算。原事实及已确认 finish 不因显示更新改写。

断线检测目标5秒；客户离开主机继续，不再等待其 ready/finish。主机在 PLAY 离开时不生成正常 results，客户清幽灵回菜单；只有主机回大厅。LAN 不写个人纪录、挑战星数或派对积分。

### 接口与报告边界

`RSNetSession.ensure(tree:SceneTree)->RSNetSession` 根下常驻、幂等、PROCESS_MODE_ALWAYS；不归 current_scene。core 不引用项目类。各卡写死其新增函数/信号；`RSPartyGame.send_event(kind,data)` 始终保留两参，session 层才用 `send_event(local_slot,kind,data)`。

报告由 [23-14](23-14-reports.md) 在真实生产者、校验器和测试同一个 PR 冻结 schema；不提前交无生产者的校验器。报告用共同单调锚点，禁止直接比较进程原始 ticks 或用估计 offset 自证误差；独立参考区间不确定度不足时判“未证明”。硬杀不补 complete=true。应用层 loss 仅丢 state/clock，可靠事件仅延迟；不冒充 transport 丢包或 ENet 重传验收。

## 依赖与顺序

`01→02→03`；`02→04`；`03+04→05→06`；`01→07`；`06+07→08→09/10`；`02→11`；`08+11→12`；`06→13`；`09+10+13→14`；`12+14→15`。**领取前所有直接依赖必须已合并**，不能只凭接口草案开工。

23-07 可与23-02并行；23-04/11可与23-03并行；23-09/10可并行；runner 可与项目适配并行。共享 net_session/协议/test_shell 的卡按依赖串行，小接线不重排其他人内容。接口需变更时同 PR 改依赖卡，遵循索引第7条。

## 验收

本次文档提交检查所有本地链接、八节顺序、每卡先读≤6、文件大小、依赖闭合、索引旧内容不变，再跑 AGENTS 必须的非 Godot 检查；不运行 Godot/试玩/下载。

未来每卡按本卡列出的最小 headless 用例和 AGENTS 运行。首次测试/新增 class_name 先 `python tools/import_game.py --godot <Godot>`，新 .gd 提交 .gd.uid；纯用例在 test_shell 中只加一行 preload、一行 run(_check)，执行 `python tools/test_game.py --godot <Godot>`，期望 `RS_SHELL_TESTS: 0 failures`。独立场景打印对应0 failures标记。

网络用例显式 `127.0.0.1` 双实例、临时用户目录、临时端口、RS_TEST_MODE=1，复用 #34 入口，不占真实 hub 固定端口。无丢包时事件产生→发送入队≤1物理tick，接收处理≤单程注入延迟+抖动上界+1tick；丢包另报尾延迟和超时，不许沿用一个tick承诺。无注入独立时钟误差目标≤2ms、倒数起点差≤100ms，证据不足如实失败。

## 不要做

不修改未列明的框架路径、party_ui/pause_menu/catalog/tournament/autoload/project.godot，不新增依赖或存档；catalog 可只读。不要以回环通过声称真实LAN/防火墙/Wi-Fi/手柄/画面已验收，不跑截图、完整试玩或大基准，不保存设备地址和个人档案。

## 预计规模

15张实施卡各约400行以内；独立新文件和必要测试可适度例外，但新单文件≤1000行。net_session 累计950行是**停止预算线**，不是必能实现的承诺；将超预算时先给维护者列明确抽取路径/接口需求，不能新建未授权第四个 core 文件。已有超长 party_game 仅小接线，不借本组重构。
