# #23 · ENet 与常驻节点生命周期 · 框架

## 目标 / 范围外

接入三通道传输和常驻节点，验证暂停/切场景下的收发与清理；不做名单、倒数、发现、项目适配或报告。

## 先读

1. [23-00](23-00-overview.md)：通道/序列、限额及全部127约束。
2. [23-01](23-01-wire-core.md)：合并后的codec契约。
3. `game/core/net_session.gd`：codec、FSM、队列。
4. `game/autoload/controller_hub.gd`：ControllerHub 的 ports_for/listen_port，只读。
5. `tools/test_hub_port.py`：回环临时端口入口。
6. `tools/engine_process.py`：run_engines/进程归属（只读）。

## 改动文件

- **框架**：`game/core/net_session.gd`；`docs/ARCHITECTURE.md`、`docs/protocol.md` 的对应段。
- 测试：新建 `game/tests/test_lan_transport.gd`、`game/tests/test_lan_transport.gd.uid`、`game/tests/test_lan_transport.tscn`。
- 不改autoload、project.godot、工具进程管理或其他框架文件；已有uid不重建。

## 接口契约

`static ensure(tree:SceneTree)->RSNetSession` 幂等返回根下常驻节点，PROCESS_MODE_ALWAYS，不归 current_scene。`open_host(config:Dictionary,local_players:Array)->Error`、`open_client(config:Dictionary,local_players:Array)->Error`、`close(reason:String)->void`；`session_changed(state:String,reason:String)`、`closed(reason:String)`。

config字段固定为 `bind_ip,host_ip,port,discovery_port,hub_ports,snapshot_hz,latency_ms,jitter_ms,loss,seed`：两个IP只能127.0.0.1；端口1024–65535、相互及hub_ports不冲突；snapshot_hz仅20/60/120；latency_ms仅0/30/80、jitter_ms为0..10、loss为0..0.05、seed为u32。host模式host_ip也须127。无效参数在创建套接字前失败；绑定错误向调用者返回，不降级/忽略。

显式分配≥3 channel、server_relay=false，不重复poll。收包先限长/验证来源再codec；根据(sender,channel)做序列与滚动限额。关闭连接/发现引用/注入队列，解除所有信号，重复close无副作用。内部不向游戏暴露可绕过验证的原始包信号。

控制/事件转发使用主机自身channel0序号，保留原seat/event_id；state转发重编码为主机channel1统一序号，保留原seat和race_ms；同包只一个原所属peer，从冻结roster推导，不新增字段。入口按真实发送peer限频，转发/接收按23-00原所属peer分桶并有活动来源数合计上限，避免多个源各自20Hz被误判为主机超频。

## 依赖与顺序

23-01已合并且profile/摘要门槛交付。与23-07可并行；net_session后续卡按依赖串行，同共享文件不并发改。

## 验收

import后运行 `<Godot> --headless --path game res://tests/test_lan_transport.tscn`，标记 `RS_LAN_TRANSPORT_TESTS: <n> checks, 0 failures`。场景按 host/client 测试配置在两个进程运行，**所有套接字源/目标127.0.0.1**，临时端口/用户目录和RS_TEST_MODE=1。

最小用例：ensure两次同对象；三个channel互不误判seq；非法地址/冲突端口不绑定；50/51控制、目标state+10%及256/257队列边界；暂停/更换current_scene仍收包；重复close、连接失败、退出都无残余队列/信号。运行AGENTS及游戏headless smoke。

## 不要做

不改autoload的hub解析，不手动poll，不开放任何非127地址或网络广播，不忽略日志/端口错误，不杀其他进程。

## 预计规模

约250–350行，单个新文件≤1000行；net_session累计接近950时停止并列需求，不新增core帮助文件。
