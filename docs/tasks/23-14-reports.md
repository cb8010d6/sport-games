# #23 · 真实报告生产者、校验器与独立测量 · 工具 + 框架观测

## 目标 / 范围外

同一实现PR交真实双实例报告、版本schema、校验器和测试，接入滑板/滑雪幽灵；不先提交无生产者校验器，不声称应用层丢包等于transport丢包。

## 先读

1. [23-00](23-00-overview.md)：时钟域、幂等与证据边界。
2. [LAN_PLAY](../LAN_PLAY.md)：第5–6节、附录B仅草案。
3. `tools/test_lan.py`：进程/临时目录。
4. `game/tests/test_lan_peer.gd`：真实生产入口。
5. `game/core/net_session.gd`：事件/时钟计数。
6. `game/core/net_remote.gd`：幽灵/纠正计数。

## 改动文件

- 新建 `tools/lan_report.py`、`tools/tests/test_lan_report.py`；修改 `tools/test_lan.py`、`tools/tests/test_lan_runner.py`、`game/tests/test_lan_peer.gd`。
- **框架**：`game/core/net_session.gd`、`game/core/net_remote.gd` 仅必要观测；`docs/protocol.md`、`docs/ARCHITECTURE.md` 对应段。
- 本卡和23-00同步生产者最终schema。无项目脚本/其他框架权限。

## 接口契约

session/remote各加 `metrics_snapshot()->Dictionary` 返回纯观测深拷贝；不在运行时写报告或解析报告CLI。runner支持 `--case baseline --output <目录>` 写双方UTF-8报告及校验结论；`python tools/lan_report.py <host.json> <client.json>` 成功0、无效非0。

schema在本PR真实生产后冻结为 `rs-lan-report-1`。根严格字段：`schema_version,protocol_version,session_id,round_id,scenario,peer_id,host_id,game,map_index,content_hash,complete,errors,roster,active_seats,phases,finishes,results,disconnects,injection,clock_reference,metrics`。scenario仅normal/client_left/host_left；名字合成，不写设备地址/本机路径。≤1MiB、深度≤8、单数组≤4096，重复key/未知字段/bool冒数值/NaN/Inf拒绝。

roster=冻结RosterRow数组；active_seats为唯一seat数组；phase项为 `{phase,at_us}`，相对早于首次LOBBY的共同参考锚点；normal含LOBBY/COUNTDOWN/PLAY/RESULTS/LOBBY，首次LOBBY不比时刻，后续对应阶段差≤100ms。finishes项为 `{seat,event_id,place,bonus_count}`，bonus_count=1；results为 `{result_id,roster_revision,rows:ResultRow[]}` 或null，检查同result新revision只更新视图。disconnect项为 `{peer_id,at_us,reason}`。

injection严格为 `{latency_ms,jitter_ms,loss,seed,layer}`，本组layer=application；仅丢state/clock，可靠事件只延迟；transport重传计数未知写null，不写0冒充已测。metrics含目标/实际snapshot_hz、tx/rx、skipped_ticks、application_drops、ghosts_seen、clock_samples、window_us、event_enqueue_max_us、event_p50/p95/p99_us、correction_max_mm、RTT/抖动/offset分布、clock_error_bound_us及参考不确定度；每一字段类型/单位/容器上限在本PR schema表和生产测试中冻结，不能把缺少真实值的字段标通过。

独立参考仅测试工具：Python单调微秒a发probe，Godot记录接收g2、发送g3，Python接收b；参考减Godot偏移区间为 `[a-g2,b-g3]`，多样本求交，不用LAN offset。仅127回环临时UDP，probe/回复≤256字节，有界JSON类型 `{t:"probe",id:u32,a_us:us}` / `{t:"probe_reply",id:u32,g2_us:us,g3_us:us}`，匹配id且g3≥g2。clock_reference保存共同anchor_ref_us及每peer的lo/hi/uncertainty_us。客户对主机真offset区间由两peer参考区间相减；估计误差的整个区间须在±2000us且参考不确定度≤1000us才证明无注入目标，否则失败/未证明，不能用RTT/2或估计offset自证。

参考端口由runner绑定127临时端口后通过测试专用环境变量 `RS_LAN_REFERENCE_PORT` 传入（1024–65535，仅测试peer读取）；不扩生产--lan-*解析或23-13测试配置白名单。metrics的目标/实际state率按原所属peer报告，并另报主机转发合计，不能拿合计冒充单来源频率。

正常完成须回大厅；受控离开清理后写报告；硬杀只有不完整检查点，不补complete=true，由runner独立核对幸存者/归属。PLAY中host_left双方无正常results；client_left主机结果排除离开者，客户仅保留已确认事实子集。

## 依赖与顺序

23-09、23-10、23-13均已合并。schema/生产者/校验器/测试必须同PR；若必须改变字段，同PR更新本卡及23-15，不保留两个含义不同的同版本。

## 验收

`python -m pytest -q tools/tests/test_lan_report.py tools/tests/test_lan_runner.py`；真跑 `python tools/test_lan.py --godot <Godot> --case baseline --output <临时目录>`，**127双实例headless**轮流skate/ski。报告真实ghosts_seen>0，冻结名单一致、结果/奖励一致，第二revision不二次结算。

篡改重复key、类型/单位、容器、旧revision、缺phase/finish、伪complete均失败。独立参考区间过宽必须失败，不能为了过≤2ms隐藏不确定度。无丢包验证入队≤1tick及接收≤单程+抖动+1tick；application loss报告尾延迟/丢弃但不宣称transport重传通过。运行AGENTS和headless smoke，不留实际录制/报告进仓库。

## 不要做

不先交校验器空壳、不补造正常结果/complete、不保存设备标识、不以声明一致证明测量可信、不新增网络外时钟服务/依赖/第四core文件。

## 预计规模

约350–400行，独立新测试可适度例外；新单文件≤1000，net_session累计950仍为停止线。schema或观测放不下先提具体拆分需求，不扩大授权。
