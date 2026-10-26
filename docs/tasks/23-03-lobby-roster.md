# #23 · 握手、全局名单与准备 · 框架

## 目标 / 范围外

实现真实兼容握手、seat归属和大厅准备；不做倒数、终局、发现或菜单。每机本地槽/档案与全局seat保持分离。

## 先读

1. [23-00](23-00-overview.md)：消息body、身份和摘要。
2. [23-01](23-01-wire-core.md)：已冻结输入清单/profile。
3. `game/core/net_session.gd`：open/codec/序列。
4. `game/core/catalog.gd`：只读内容入口。
5. `game/core/party_game.gd`：只读本地玩家显示属性来源。
6. `game/tests/net_session_cases.gd`：纯用例入口。

## 改动文件

- **框架**：`game/core/net_session.gd`；`docs/protocol.md`、`docs/ARCHITECTURE.md` 对应段。
- 测试：`game/tests/net_session_cases.gd`；`game/tests/test_lan_transport.gd`。
- 不改catalog或玩家存档；不新增测试注册行。

## 接口契约

`roster()->Array` 返回深拷贝RosterRow；`set_ready(ready:bool)->Error`；`roster_changed(rows:Array,revision:int)`。open_*的local_players遵守23-00 LocalPlayer，host分配seat，客户端不能自报seat。host本地命令也进相同验证器。

读取23-01冻结的实际资源字节，经hash_manifest产生build/catalog摘要；不能从测试参数或手填常量直接取得“匹配结果”。完全匹配才进入LOBBY。仅LOBBY接纳加入；人数上限4、每机至少1槽，slot在本peer唯一。主机槽升序优先，后加入按顺序；大厅revision递增，旧ready拒绝。显示名禁富文本，avatar键白名单。就绪不冻结名单，冻结在load时完成。

## 依赖与顺序

23-02已合并；继承23-01冻结门槛。23-04和11可独立实现，但同net_session文件由维护者串行整合，依赖卡合并前不能开始相应接线。

## 验收

运行 `python tools/test_game.py --godot <Godot>` 和transport场景的**127.0.0.1双实例**模式。覆盖1+1、1+3、2+2、三个实例各1槽；重复slot/第五人/空本地名单失败；修改一个真实输入文件的测试副本导致摘要拒绝；bad_build/bad_catalog分别有原因，bad_map留23-05加载验收。

伪造peer/seat、旧ready/revision拒绝；进入非LOBBY后加入为busy；客户离开释放活动名单，冻结后的seat不压缩。运行AGENTS和headless smoke。

## 不要做

不修改catalog、档案、autoload、项目脚本；不以peer负载自证身份，不伪造相同摘要通过，不用发现源地址代替握手。

## 预计规模

约250–350行；net_session950行是停止预算，不保证实现一定能容纳；超预算先列路径需求。
