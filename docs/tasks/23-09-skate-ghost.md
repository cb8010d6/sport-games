# #23 · 滑板无碰撞幽灵与完赛适配 · 项目（滑板）

## 目标 / 范围外

滑板接入冻结profile、全局起跑位和主机完赛；远端只显示幽灵。非LAN行为不变，不改框架签名或素材，不做画面巡检。

## 先读

1. [23-00](23-00-overview.md)：冻结profile、权威和127边界。
2. [23-08](23-08-party-hooks.md)：两参send_event/remote钩子。
3. `game/scenes/skate/skate_game.gd`：`_record()`、起跑位、finish/分数。
4. `game/core/party_game.gd`：已实现钩子。
5. `game/core/net_remote.gd`：sample数据。
6. `game/tests/test_lan_party.gd`：无界面测试形式。

## 改动文件

- 项目：`game/scenes/skate/skate_game.gd`；新建 `game/scenes/skate/net_ghost.gd`、`game/scenes/skate/net_ghost.gd.uid`。
- 测试：新建 `game/tests/test_lan_skate.gd`、`game/tests/test_lan_skate.gd.uid`、`game/tests/test_lan_skate.tscn`。
- `game/i18n/en.json` 仅有新增中文key时追加对应翻译。
- 无框架文件写权限；原项目uid不重建。

## 接口契约

实现party钩子：_net_snapshot返回profile1记录的项目字段，pose顺序/范围严格用23-01冻结表；_remote_added创建 `RSSkateNetGhost` 节点，_remote_removed销毁，_remote_step仅应用采样。新ghost提供 `configure(row:Dictionary)->void`、`apply_sample(sample:Dictionary)->void`，不注册Controller、不建/启用任何碰撞体，不计分。

起点/配色取seat_of/start_index/start_count。原finish点调用两参 `send_event("finish",{local_slot:<现有本地槽>,base_score:<int>,score_revision:<int>})`；本地槽读取沿用现有Player字段，不凭空改Player。奖励只取主机place确认，重复确认不累计。名次页读ranked_all纯数据，不访问远端p.data。单机仍走旧路径。

## 依赖与顺序

23-08已合并，含23-01的精确profile/摘要/奖励冻结；23-10可并行。若现有显示必须改party_ui等，先列具体需求，不能扩路径。

## 验收

import后 `<Godot> --headless --path game res://tests/test_lan_skate.tscn` 输出 `RS_LAN_SKATE_TESTS: <n> checks, 0 failures`。**127.0.0.1双实例**1+1、1+3，检查远端节点数/无碰撞、全局起跑位、增删、finish一次、旧snapshot不撤奖金、客户离开清幽灵。

非LAN skate demo=2/4、暂停/重开/回放/纪录写入隔离及smoke全headless；AGENTS和i18n检查。无实际渲染通过声明；暂缺runner时用测试peer双实例入口，23-14/15再接自动报告。

## 不要做

不改共享框架、其他运动/素材、网络profile或项目物理，不为远端创建本地Player/Controller，不自行发奖，不使用非127目标。

## 预计规模

约300–400行，新ghost与测试各≤1000行；原主脚本只集中适配，不借此重构。超范围先提需求。
