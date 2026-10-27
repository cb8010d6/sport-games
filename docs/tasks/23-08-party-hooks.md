# #23 · RSPartyGame 的 LAN 小接线 · 框架

## 目标 / 范围外

接通常驻会话、全局seat/排名纯数据和项目钩子；保留本地玩家、档案、视口及非LAN行为。现有party_game已超1000行，只小接线，不借本卡重构。

## 先读

1. [23-00](23-00-overview.md)：身份/事实/视图/两参钩子。
2. [LAN_PLAY](../LAN_PLAY.md)：第2节候选钩子，需对照源码核对。
3. `game/core/party_game.gd`：玩家/排序/Phase/暂停/存档调用。
4. `game/core/net_session.gd`：已合并的会话接口。
5. `game/core/net_remote.gd`：数据窗口。
6. `game/tests/test_shell.gd`：测试入口。

## 改动文件

- **框架**：`game/core/party_game.gd`、`game/core/net_session.gd`、`game/core/net_remote.gd`；`docs/ARCHITECTURE.md`、`docs/protocol.md` 对应段。
- 测试：新建 `game/tests/test_lan_party.gd`、`game/tests/test_lan_party.gd.uid`、`game/tests/test_lan_party.tscn`。
- 不改party_ui、pause_menu、catalog、tournament、autoload、project.godot、现有签名或任何档案格式。

## 接口契约

保留LAN_PLAY钩子：`is_lan()->bool`、`is_lan_host()->bool`、`remote_players()->Array`；`seat_of(p)->int`、`start_index(p)->int`、`start_count()->int`、`ranked_all()->Array`。非LAN分别false/false/空、原槽/排序/人数，ranked_all用本地数据行；LAN用冻结名单，全局行与ResultRow一致。

`_net_tick_hz()->int`默认20，`_net_sync_mode()->String`默认ghost；`_net_snapshot(p)->Dictionary`默认只含score；`_net_event(seat:int,kind:String,data:Dictionary)->void`默认空；`_remote_added(row:Dictionary)->void`、`_remote_removed(seat:int)->void`、`_remote_step(seat:int,sample:Dictionary)->void`默认空。name_of/color_of/avatar_of保留原签名，LAN读冻结显示属性。

**`RSPartyGame.send_event(kind:String,data:Dictionary)->void` 必须保持两参**。finish的data允许 `local_slot,base_score,score_revision`；party取出local_slot，仅把剩余两字段交session.send_event(local_slot,kind,data)，非LAN空操作。不得把session三参签名抄成party钩子。

session新增 `send_snapshot(profile:int,records:Array)->Error`、`snapshot_received(snapshot:Dictionary)`；_physics_process按120Hz下6/2/1 tick采样，不跟渲染帧，不补旧包。session验证/转发后交remote窗口；派生项目只做字段/显示适配。players/ordered/ranked_players仍只含本地Player；不把远端伪装成Controller。暂停仅覆盖层，LAN拦截个人纪录/星数/派对积分写入与客户重开。

进入主机加载前调用23-05的set_round_rules，规则取23-01冻结的原项目数据；不在框架编造新比赛时限/奖励。测试夹具可声明20/60/120Hz，项目默认仍20Hz。

## 依赖与顺序

23-06和23-07均已合并；对应钩子若与源码冲突，按索引第7条同PR修卡及依赖卡，不能悄改旧签名。之后23-09/10/12可领取。

## 验收

运行import及 `<Godot> --headless --path game res://tests/test_lan_party.tscn`，标记 `RS_LAN_PARTY_TESTS: <n> checks, 0 failures`。假项目**127.0.0.1双实例**覆盖：本地槽≠seat、start_index/count全局、分屏/档案仍本地、players不含远端、20/60/120采样跳tick不补包、非LAN默认钩子。

暂停/切场景持续收发，客户重开失败，LAN不写纪录/星数/积分，result新revision不二次奖励；验证两参party→三参session转换。AGENTS、非LAN demo=2/4及smoke均headless，画面未验收。

多来源state都经主机重签channel1序号，单包来源归属一致；三个来源各20Hz转发不误触一个来源的22Hz上限，单一来源第23包仍被拒绝。

## 不要做

不扩框架授权，不为接线改party_ui/pause_menu等文件，不重排超长party_game、不把新会话逻辑堆进去，不改变相机/OLED/回放本地槽。

## 预计规模

约300–400行；party_game只集中少量接线。新单文件≤1000，net_session950为停止线，无法满足时列路径/接口需求给维护者，不自行重构。
