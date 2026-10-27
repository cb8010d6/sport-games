# #23 · 代表性回环场景与非LAN回归 · 工具 + 测试

## 目标 / 范围外

用少量分层组合完成双实例、跨局、三实例座位及断线验收；不是笛卡尔大矩阵/性能基准，不验真实LAN、画面或手柄。

## 先读

1. [23-00](23-00-overview.md)：时延目标/证据边界。
2. [23-12](23-12-lan-menu.md)：菜单/发现入口。
3. [23-14](23-14-reports.md)：真实schema与独立时钟。
4. `tools/test_lan.py`。
5. `tools/lan_report.py`。
6. `game/tests/test_lan_peer.gd`。

## 改动文件

- `tools/test_lan.py`、`tools/tests/test_lan_runner.py`、`tools/tests/test_lan_report.py`、`game/tests/test_lan_peer.gd`。
- 本卡仅同步代表性用例/验收说明；无框架/项目/CI写权限。
- 生产运行时bug回所属卡列明确补丁需求，不临时扩路径。

## 接口契约

入口 `python tools/test_lan.py --godot <Godot> --case representative --output <临时目录>`；固定seed=23，使用23-14同版本schema，输出每例结果/未验证项，任一必需断言失败即非0。除明确三进程座位例外均为**headless 127.0.0.1双实例**，源/目标/发现/参考时钟都127，临时用户目录与端口，RS_TEST_MODE=1。

采用以下代表组合覆盖各维度，不做所有维度乘积；hz是session采样率，项目默认仍20，60/120由测试夹具声明，不能据此实现predictive：

| 用例 | 项目 / hz / 单程ms / ±抖动ms / loss | 名单/行为 |
|---|---|---|
| A | skate / 20 / 0 / 0 / 0 | 主机A，1+1；独立时钟/正常结果 |
| B | ski / 60 / 30 / 10 / 0 | 主机B，1+3；两局及旧局注入 |
| C | skate / 120 / 80 / 10 / 0.05 | 主机A，2+2；事件尾延迟、重复finish |
| D | ski / 20 / 80 / 10 / 0.05 | 主机B，2+2；RESULTS离开视图revision |
| E | skate / 60 / 30 / 0 / 0.05 | 主机B，1+1；client_left主机继续 |
| F | ski / 120 / 0 / 0 / 0 | 主机A，1+1；PLAY主机受控离开 |
| G | skate / 20 / 0 / 0 / 0 | 三实例各1槽；seat唯一/归属 |
| H | ski / 20 / 0 / 0 / 0 | 主机B，1+1；PLAY硬杀及5秒断线目标 |

已有小场景复用断言覆盖摘要拒绝、客户端无权推进、局中加入busy、发现过期/菜单退出，不为每个组合重复启动全套。无注入误差≤2ms/起点差≤100ms；无丢包事件入队≤1tick、接收≤单程+抖动上界+1tick；loss仅application state/clock，另报p50/p95/p99/丢弃，不能宣称真实ENet重传。>5m纠正清窗是功能断言，最大纠正量只报告，不擅定实时可玩门槛。

## 依赖与顺序

23-12和23-14均已合并，包含两个项目适配、报告及校验器。若 schema需要变更回23-14协调同PR更新，不以测试fixture偏离运行时协议。

## 验收

运行representative入口、`python -m pytest -q tools/tests/test_lan_runner.py tools/tests/test_lan_report.py`、AGENTS检查。A-H逐例可复现且进程/端口清理，硬杀不补complete；双方轮换主机，normal回大厅，leave按权威/幂等规则，第二局不受第一局包影响。

非LAN skate/ski各demo=2/4，暂停/重开/回放/本地纪录隔离与 `python tools/smoke_game.py <Godot> --project game` 全headless；现有检查无法自动断言的行为明确未验证，不用截图/试玩补本卡。报告仅临时输出，PR保留无设备标识的摘要。

## 不要做

不跑大矩阵/长时基准，不下载素材，不用非127网络，不把回环当Wi-Fi/真实LAN/画面验收，不改卡外运行时文件，不隐藏失败/测量不确定度。

## 预计规模

约250–400行，新单文件≤1000；不为加用例重写runner，发现结构不足先列具体需求。
