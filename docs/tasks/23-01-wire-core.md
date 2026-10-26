# #23 · 首片：纯数据 codec、状态转换与种子队列 · 框架

## 目标 / 范围外

交付 LAN_PLAY 第6节要求的首个独立实现片，不接 ENet、菜单、发现、幽灵或报告。核对摘要来源、姿势 profile 和旧奖励规则，与 codec/FSM/队列及正式协议同 PR 交付；不另开前置纯文档 PR。

## 先读

1. [23-00](23-00-overview.md)：完整线格式、门槛和地址边界。
2. [LAN_PLAY](../LAN_PLAY.md)：第3–6节、附录A。
3. `game/core/party_game.gd`：原成绩/奖励、默认钩子。
4. `game/core/catalog.gd`：目录/地图来源（只读）。
5. `game/scenes/skate/skate_game.gd`：`_record()` 和实际分数来源。
6. `game/scenes/ski/ski_game.gd`：`_record()` 和地图来源。

## 改动文件

- **框架**：新建 `game/core/net_session.gd`、`game/core/net_session.gd.uid`；`docs/ARCHITECTURE.md`、`docs/protocol.md` 仅对应公共模块/线格式段。
- 测试：新建 `game/tests/net_session_cases.gd`、`game/tests/net_session_cases.gd.uid`；`game/tests/test_shell.gd` 仅一行 preload 和一行 run(_check)。
- 契约：本卡、`docs/tasks/23-00-overview.md`；如核对改变 profile/摘要接口，同 PR 只同步受影响的 `docs/tasks/23-02-*.md` 至 `23-15-*.md`。
- 不改目录/项目源码；需要新构建产物或输入清单文件时先列需求。

## 接口契约

`RSNetSession` 的纯函数：`static encode_control(message:Dictionary)->Dictionary`、`decode_control(packet:PackedByteArray)->Dictionary`、`encode_state(snapshot:Dictionary)->Dictionary`、`decode_state(packet:PackedByteArray)->Dictionary`。返回恰为 `{ok:true,value:<结果>,error:""}` 或 `{ok:false,value:null,error:<Reason>}`；编码 value 为字节，解码 value 为纯字典。校验遵守23-00全部白名单，不解码对象。

纯函数 `static validate_ingress(message:Dictionary,context:Dictionary)->Dictionary` 返回同形结果；context由可信接收回调构造，严格字段为 `sender_peer,host_peer,channel,role,phase,session_id,round_id,roster_revision,seat_owners,last_seq`，seat_owners为seat→peer映射，last_seq=-1表示首次。控制序列取seq，state取packet_seq。codec只校验格式/数值，归属、阶段、旧局/序列由此函数验证；不得让无上下文的decode自称已验证身份。

`static transition(current:String,role:String,message_type:String)->Dictionary` 返回同形结果，value 为下一状态；不修改会话或访问树。role仅host/client，非法转换失败。种子队列为同文件内类 `RSNetSession.InjectionQueue`，每peer一实例，接口 `configure_injection(latency_ms:int,jitter_ms:int,loss:float,seed:int)->Error`、`enqueue(packet:PackedByteArray,channel:int,now_us:int)->Error`、`drain(now_us:int)->Array`、`clear()->void`；队列项为 `{packet,channel,due_us}`，按 due_us/入队序输出，最多每peer256项，退出清空。只在发端注入一次；channel0只延迟不丢，channel1/2可丢，layer=application。

摘要纯函数 `static hash_manifest(kind:String,entries:Array)->Dictionary`，entry仅 `{path:String,bytes:PackedByteArray}`，按23-00 SHA-256算法；不接受调用方手填hash作为验证。此卡必须交付实际 build/catalog/map 输入路径清单、内容读取与导出包可用性证据，以及各摘要测试；运行时读取接入留23-03。

在正式协议和本概览逐项写全两个pose profile的索引/单位/边界/误差、布尔值与原奖励规则来源。若范围不够，同PR修订profile和后续卡，绝不钳位。无法证明安全范围、无法确定摘要输入/导出包可读性或需要越权文件，**不得标完成或解锁后续卡**；提交具体失败及所需路径给维护者。

## 依赖与顺序

无实施依赖；这是首个运行时实现 PR。完成上述冻结门槛并合并后23-02/07才能领取。接口变更同时更新依赖卡，不能把未确认候选交给后续自行决定。

## 验收

运行 import、`python tools/test_game.py --godot <Godot>`，输出含0 failures。用例覆盖4096/4097字节、重复key/深度/数组上限、缺字段/未知类型、bool冒整数、NaN/Inf、i64十进制溢出、未知profile/错误记录长度/尾随字节、量化极值和四元数容差、旧局/半区间歧义/冒用seat、重复事件、非法FSM转换、队列上限/清空/同种子重复结果。

摘要输入调序得同hash，任一文件/路径变化改变hash，重复/绝对路径失败；实际项目pose边界及 headless demo=2/4数据检查纳入该PR证据，不以有限采样宣称所有状态已证明。运行AGENTS检查及游戏smoke，全部 headless；本卡不绑定网络，无双实例通过声明。

## 不要做

不接菜单/ENet/发现/报告，不新增依赖、autoload、协议外消息或第四个core文件；不把候选profile、手写相同hash当成兼容验证，不忽略导出包失败。

## 预计规模

约400行（独立测试可适度例外），单文件≤1000行。net_session 后续累计950行为停止预算线；超过需先列需求，不能自行扩大文件授权。
