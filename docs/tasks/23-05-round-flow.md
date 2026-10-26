# #23 · 加载、共享起点与主机推进 · 框架

## 目标 / 范围外

实现准备/加载确认、倒数和阶段权限；不做项目幽灵、菜单或奖励计算。客户端不能自行开局、结束、重开或回大厅。

## 先读

1. [23-00](23-00-overview.md)：状态机、冻结revision、消息body。
2. [23-03](23-03-lobby-roster.md)：名单/ready。
3. [23-04](23-04-clock-sync.md)：时钟门禁。
4. `game/core/net_session.gd`。
5. `game/tests/net_session_cases.gd`。
6. `game/tests/test_lan_transport.gd`。

## 改动文件

- **框架**：`game/core/net_session.gd`；`docs/protocol.md`、`docs/ARCHITECTURE.md` 对应段。
- 测试：`game/tests/net_session_cases.gd`、`game/tests/test_lan_transport.gd`。
- 不改项目或菜单，不新增注册行。

## 接口契约

`host_load(game:String,map_index:int,seed:int)->Error`、`mark_loaded(round_id:int,map_hash:String)->Error`、`host_return_lobby()->Error`；信号 `load_requested(game:String,map_index:int,seed:int,round_id:int)`、`countdown_received(start_host_us:int,deadline_host_us:int)`。

`set_round_rules(profile:int,duration_ms:int,finish_bonuses:PackedInt64Array)->Error` 仅主机LOBBY可调用，profile为1/2、duration为1..1800000ms、bonuses恰4个非负i64；规则取23-01已核对的原项目数据，测试可传夹具，运行时不能手填不同规则。host_load前必须已配置。客户mark_loaded只在本机clock_ready时成功，loaded即为加载与同步门禁完成的声明；主机也核对该peer近期八个时钟应答已发送，过期时不倒数。

host_load仅主机LOBBY全员ready可调用，递增round_id并冻结名单/revision；用实际资源计算选定map_hash。全部loaded摘要匹配且各客户端clock_ready才发送countdown，start≥host_now+300ms。初始deadline沿项目原比赛时限，由23-01冻结来源，不能客户端自报；单局≤30分钟。加载10秒未齐回LOBBY并清加载状态。PLAY/RESULTS/Lobby只由主机推进；旧局数据不得改新局。

## 依赖与顺序

23-03和23-04均已合并；随后23-06。不得凭未合并clock接口开工。

## 验收

test_game及**127.0.0.1双实例**transport场景覆盖：未ready/未loaded/未同步都不开始；起点提前量≥300ms；map错误拒绝；10秒加载超时回大厅；客户调用推进/重开失败；从RESULTS仅主机回大厅。再开第二局注入第一局load/loaded/countdown，不能改变新局。运行AGENTS及headless smoke。

## 不要做

不修改现有四个游戏Phase含义，不把网络时间当玩法delta，不允许局中重连，不自动推进客户的下一局，不增autoload。

## 预计规模

约250–350行；net_session累计950行停止线适用，超限先提具体需求。
