# #23 · 可靠完赛、权威奖励与断线终局 · 框架

## 目标 / 范围外

实现finish/place、主机唯一结算及可更新的活动排名视图，保留审计事实；不实现反作弊保证、延迟公平、主机迁移或派对积分。

## 先读

1. [23-00](23-00-overview.md)：所有消息body、事实/视图两个幂等键。
2. [23-05](23-05-round-flow.md)：阶段和冻结名单。
3. `game/core/net_session.gd`。
4. `game/tests/net_session_cases.gd`。
5. `game/tests/test_lan_transport.gd`。
6. `docs/protocol.md`：23-01冻结的奖励来源。

## 改动文件

- **框架**：`game/core/net_session.gd`；`docs/protocol.md`、`docs/ARCHITECTURE.md` 对应段。
- 测试：`game/tests/net_session_cases.gd`、`game/tests/test_lan_transport.gd`。
- 不改项目/UI/存档，不新增注册行。

## 接口契约

session层为 `send_event(local_slot:int,kind:String,data:Dictionary)->String`，成功返回EventId，失败空串；kind仅finish，data为 `{base_score:int,score_revision:int}`，严格检查范围/字段。**不是**RSPartyGame两参钩子。事件不等snapshot tick，调用即可靠入队，保留ID供重试。

信号 `event_received(seat:int,kind:String,data:Dictionary)`、`results_ready(rows:Array,result_id:String,roster_revision:int)`、`peer_removed(seats:Array,reason:String)`。event_received只发经主机确认的事件，data为 `{event_id,place,bonus,score_revision}`；bonus为已验证int，不可二次累加。closed沿23-02。

主机检查来源/seat/阶段/时间/revision，按有效finish收到顺序派place，原奖励表由23-01冻结。每seat保存唯一finish/bonus；重复ID返回原place，不再发奖。state仅更新基础分，不得撤销bonus。首finish以place携带收紧后的deadline。

结果事实结算键 `(session_id,round_id,result_id)` 只执行一次；显示键再加 `roster_revision`。RESULTS离开只移除活动视图并重新计算score rank，同result_id新revision发results；同revision无操作、旧revision拒绝，新revision不得改原finish/score/bonus事实或再次结算，place不重排。客户离开主机继续；PLAY中主机退出/5秒超时不产正常results，清幽灵回菜单。

## 依赖与顺序

23-05已合并；23-08与runner依赖本卡。结果行类型/奖励来源不完整时回23-01修订并同步依赖卡，不能自行填一个奖励表。

## 验收

运行test_game及**127.0.0.1双实例**transport场景。测重复finish/重试同ID同确认、不同ID重复完赛不二次发奖；最后state丢失仍以finish基础分封存，旧state不覆盖奖励；并列总分为1,1,3，place单独保留；首finish截止min规则。

RESULTS里客户离开后同result_id新revision只改显示，旧revision拒绝、同revision幂等；已有第一place离开后第二place不重排。客户PLAY离开主机继续、主机PLAY离开及硬断线≤5秒检测目标；第二局旧事件无效。无丢包事件发送入队≤1tick。运行AGENTS与headless smoke。

## 不要做

不让客户端决定place/奖励/终局，不把rank当place，不给离开者补造最终结果，不写个人纪录/星数/派对积分，不宣称可靠重传延迟≤1tick。

## 预计规模

约300–400行；net_session累计950为停止预算线，若不可容纳须先列具体抽取需求，不能自行新增core文件。
