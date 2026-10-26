# #23 · 真双实例headless执行器 · 工具 + 测试

## 目标 / 范围外

交付能启动、等待、判错和清理真实双Godot的回环runner；先覆盖假项目完整会话，不先提交报告schema或校验器，不改生产运行时。

## 先读

1. [23-00](23-00-overview.md)：临时用户目录、端口、进程归属。
2. [23-06](23-06-events-results.md)：正常终局/断线。
3. `tools/engine_process.py`：run_engines接口与退出归属。
4. `tools/test_hub_port.py`：RS_TEST_MODE及回环临时端口。
5. `game/tests/test_lan_transport.gd`：双角色入口。
6. `game/core/net_session.gd`：合并后的公开API。

## 改动文件

- 新建 `tools/test_lan.py`、`tools/tests/test_lan_runner.py`。
- 新建 `game/tests/test_lan_peer.gd`、`game/tests/test_lan_peer.gd.uid`、`game/tests/test_lan_peer.tscn`。
- 无框架写权限，不改engine_process/test_hub_port、CI或依赖。

## 接口契约

入口 `python tools/test_lan.py --godot <Godot> --case baseline --output <临时目录>`；成功exit0、明确 `RS_LAN_RUNNER: 0 failures`，失败非0。复用engine_process.run_engines，不另造脱离归属的进程管理；输出路径不写入版本库。

runner创建临时用户目录、RS_TEST_MODE=1、临时回环LAN/发现及独立hub端口配置，只启动headless。测试peer通过 `RS_LAN_TEST_CONFIG` 有界JSON读取测试配置并直接调用session接口，不在新运行时代码解析--lan-*，生产解析仍限menu/party_game。配置只允许 `role,case,bind_ip,host_ip,port,discovery_port,hub_ports,local_players,snapshot_hz,latency_ms,jitter_ms,loss,seed`，各类型沿23-00/02。

Godot peer输出结构化检查标记（角色/阶段/错误，合成名字和peer数字），runner验证双方握手→PLAY→RESULTS→LOBBY且进程成功退出，不以“进程启动了”算通过。超时/日志ERROR/脚本错误/端口绑定失败均失败；只终止本次创建的进程，finally清临时资源。无报告complete字段直到23-14真实生产者落地。

## 依赖与顺序

23-06已合并；可与23-09/10并行。23-14等本卡和两项目卡均合并后扩展真实项目报告。

## 验收

`python -m pytest -q tools/tests/test_lan_runner.py` 覆盖启动失败、部分启动、超时、端口冲突、日志错误、子进程非0及只清自己进程；fake进程单元测试之外必须真运行 `python tools/test_lan.py --godot <Godot> --case baseline --output <临时目录>`。

真实**127.0.0.1双实例**1+1，正常走完整局并回大厅，重复执行不占端口、不影响已有Godot/hub。运行AGENTS及游戏headless smoke。报告/独立时钟误差本卡未验证，不生成占位通过文件。

## 不要做

不改CI/进程管理公共工具，不忽略日志或测试端口错误，不占真实hub固定端口，不杀其他进程，不为假报告先写校验器。

## 预计规模

约300–400行，独立测试可适度例外但新单文件≤1000；超范围先提需求，不新建框架帮助文件。
