# #23 · 本机发现与过期清理 · 框架

## 目标 / 范围外

提供本机127.0.0.1单播发现及手动加入兜底的数据入口，不做LAN广播/公网发现、自动防火墙、身份认证或菜单。

## 先读

1. [23-00](23-00-overview.md)：网络边界与正式握手。
2. [LAN_PLAY](../LAN_PLAY.md)：发现字段、频率、过期。
3. `game/core/net_session.gd`：关闭与端口配置。
4. `game/tests/test_lan_transport.gd`：双实例入口。
5. `docs/protocol.md`：已实现消息规范。

## 改动文件

- **框架**：新建 `game/core/net_discovery.gd`、`game/core/net_discovery.gd.uid`；`docs/protocol.md`、`docs/ARCHITECTURE.md` 的对应段。
- 测试：新建 `game/tests/test_lan_discovery.gd`、`game/tests/test_lan_discovery.gd.uid`、`game/tests/test_lan_discovery.tscn`。
- 不改菜单、autoload、project.godot或其他框架文件。

## 接口契约

`RSNetDiscovery` 为Node：`start(bind_ip:String,listen_port:int,target_port:int)->Error`、`advertise(info:Dictionary)->Error`、`poll_hosts(now_us:int)->Array`、`stop()->void`。bind/发送/来源只允许127.0.0.1；listen_port与target_port允许不同，范围1024–65535，避免本机端口占用冲突。测试发现者与广告者各自绑定不同回环临时端口，向对方已绑定的回环端口单播，不能依赖多进程复用同一UDP端口。

UTF-8 JSON≤512字节，严格字段为 `{t:"rs_lan",v:1,name:String,port:int,game:String,players:int,open:bool}`；name≤48 UTF-8字节且不是机器名，port为LAN会话端口，game仅skate/ski，players为1..4。每秒最多一份广告，3秒未更新过期；poll_hosts返回深拷贝条目，加 `last_seen_us:int`，不把来源地址写入报告。无对象/重复key/NaN/未知字段；禁富文本。

发现只展示，加入仍走session兼容握手；open只来自主机LOBBY状态。stop幂等关闭套接字、清缓存及计时。多实例默认临时发现端口由测试配置传入；生产页面手动join始终可用，不增加广播或其他bind选项。

## 依赖与顺序

23-02已合并；可与23-03/04按文件协调并行。23-12等本卡和23-08均合并后接页面。端口模型如需改session配置须同PR更新依赖卡，不悄加新参数。

## 验收

import后 `<Godot> --headless --path game res://tests/test_lan_discovery.tscn` 输出 `RS_LAN_DISCOVERY_TESTS: <n> checks, 0 failures`。**127.0.0.1双实例**各绑不同临时端口，单播发现/更新/3秒过期；512/513字节、重复key、超长名字、非法游戏/人数/端口拒绝；所有非127源/目标拒绝；stop两次无残留；伪造广告不能绕过hello。

运行AGENTS与headless smoke；回环通过不代表真实LAN/广播/防火墙已验证。

## 不要做

不使用0.0.0.0/局域网IP/公网/广播，不依赖SO_REUSEPORT多进程收同包，不自动改防火墙，不把发现源地址当身份，不扩框架路径。

## 预计规模

约200–300行，新文件各≤1000行，net_discovery目标≤400行；将超范围先列需求。
