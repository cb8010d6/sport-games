# #23 · 四时刻时钟同步 · 框架

## 目标 / 范围外

实现共享单调时钟估计和同步门禁，保留玩法delta；本卡不宣称独立时钟误差已≤2ms，不做倒数权限、报告或网络外时钟平台。

## 先读

1. [23-00](23-00-overview.md)：时钟域/公式/阈值。
2. [LAN_PLAY](../LAN_PLAY.md)：第5节独立误差边界。
3. `game/core/net_session.gd`：三通道和队列。
4. `game/tests/net_session_cases.gd`：纯用例。
5. `game/tests/test_lan_transport.gd`：双实例入口。

## 改动文件

- **框架**：`game/core/net_session.gd`；`docs/protocol.md` 的时钟段。
- 测试：`game/tests/net_session_cases.gd`、`game/tests/test_lan_transport.gd`。
- 不新增core文件、存档或测试注册。

## 接口契约

`clock_ready()->bool`、`host_now_us()->int`、`race_ms()->int`，未同步的客户host_now_us返回-1；主机直接用自己的单调微秒。race_ms仅在已设置起点后有效，之前返回0。信号 `clock_sync_changed(ready:bool)`。

按23-00公式：t1/t4客户、t2/t3主机；至少8有效样本、50ms初始间隔、最低RTT初始化；以后1Hz、最近8样本最低RTT目标、每秒最多500us修正；负RTT/目标跳变>50ms/5秒无样本重同步。pong严格匹配ping_id和原t1；重复/未知pong不计有效样本。offset只用于网络时间，不修改Engine.time_scale/physics delta。

## 依赖与顺序

23-02已合并；23-03/11可按文件协调并行，23-05必须等23-03和本卡均合并。

## 验收

纯用例用合成t1..t4精确验证RTT/offset、非对称链路不能证明真实误差、负RTT/旧pong、8样本门禁、最低RTT、平滑限速/跳变重置；模拟time_scale变化网络时间不变。运行test_game及transport的**127双实例**样本输出，保留原始t1..t4摘要、有效样本数，不直接比较两进程ticks。AGENTS和headless smoke；独立误差验收由23-14完成。

## 不要做

不以RTT/2当真值、不用offset自证误差，不读取墙钟，不让比赛阶段切换重置race累计，不增加公网NTP或外部依赖。

## 预计规模

约200–300行；net_session累计950行停止线适用。
