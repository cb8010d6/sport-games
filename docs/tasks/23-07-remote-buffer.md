# #23 · 远端快照缓冲与幽灵插值 · 框架

## 目标 / 范围外

交付独立的远端纯数据窗口，服务滑板/滑雪无碰撞幽灵；不建角色节点、不负责成绩或玩法模拟，不把网络窗口复用为成绩回放。

## 先读

1. [23-00](23-00-overview.md)：profile门槛、插值时间域。
2. [23-01](23-01-wire-core.md)：已冻结二进制解码数据。
3. [LAN_PLAY](../LAN_PLAY.md)：第5节、附录A。
4. `game/tests/catalog_cases.gd`：纯用例形式。
5. `game/tests/test_shell.gd`：两行注册位置。

## 改动文件

- **框架**：新建 `game/core/net_remote.gd`、`game/core/net_remote.gd.uid`；`docs/ARCHITECTURE.md` 对应段。
- 测试：新建 `game/tests/net_remote_cases.gd`、`game/tests/net_remote_cases.gd.uid`；`game/tests/test_shell.gd` 仅一行preload和一行run(_check)。
- 不改net_session或项目脚本。

## 接口契约

`RSNetRemote` 为RefCounted；`begin_round(round_id:int,start_host_us:int)->void`、`push(snapshot:Dictionary,received_host_us:int)->Error`、`sample(render_host_us:int)->Dictionary`、`remove_seat(seat:int)->void`、`clear()->void`。snapshot为23-01已解码state；样本主机时间=start_host_us+race_ms×1000。sample返回整数seat→record字典的映射（空时空字典），不修改原快照。

调用者传入render_host_us=host_now_us-100000，不再次减延迟。位置lerp、旋转slerp、非布尔pose线性插值；布尔pose/flags离散保持左样本，score/revision取已接受事实不插值。超出最后样本时仅用速度外推位置≤250ms，旋转/pose保持；再后冻结。teleport或>5m跳变清该seat窗口。每seat最多128条且只保留最近1秒；不同round拒绝，离开立即移除，不给陈旧包恢复seat权限（归属先由session验证）。

## 依赖与顺序

23-01已合并且profile已冻结；可与23-02并行。共享test_shell注册需串行合并，只改自己两行，不撤销别人注册。23-08需等本卡和23-06都合并。

## 验收

import后 `python tools/test_game.py --godot <Godot>`，0 failures。检查100ms采样时刻、位置/四元数/布尔姿势、250ms边界后冻结、teleport/5m上下界、旧局/乱序、128条及时间窗、移除/clear幂等。构造全部合法profile边界，拒绝NaN/Inf。

本卡纯数据无套接字；与session合流的**127双实例**验收在23-08/09/10，不据此宣称幽灵画面通过。运行AGENTS与headless smoke。

## 不要做

不建碰撞体，不访问远端p.data/RSController，不插值分数，不做predictive或网络成绩回放，不新增其他core文件。

## 预计规模

约250–350行，新单文件≤1000行，net_remote目标≤400行；超限先提明确路径需求。
