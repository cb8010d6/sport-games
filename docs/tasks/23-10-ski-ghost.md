# #23 · 滑雪无碰撞幽灵与完赛适配 · 项目（滑雪）

## 目标 / 范围外

滑雪接入冻结profile、全局起跑位与完赛事件；仅模拟本地玩家，远端无碰撞。非LAN保持原行为，不改框架/素材或做画面巡检。

## 先读

1. [23-00](23-00-overview.md)：profile2、权威/摘要/127边界。
2. [23-08](23-08-party-hooks.md)：两参send_event与remote钩子。
3. `game/scenes/ski/ski_game.gd`：`_record()`、地图/起点/finish/重置。
4. `game/core/party_game.gd`：已合并钩子。
5. `game/core/net_remote.gd`：sample数据。
6. `game/tests/test_lan_party.gd`：无界面测试形式。

## 改动文件

- 项目：`game/scenes/ski/ski_game.gd`；新建 `game/scenes/ski/net_ghost.gd`、`game/scenes/ski/net_ghost.gd.uid`。
- 测试：新建 `game/tests/test_lan_ski.gd`、`game/tests/test_lan_ski.gd.uid`、`game/tests/test_lan_ski.tscn`。
- `game/i18n/en.json` 仅为新增中文key追加翻译。
- 不授予任何框架文件写权限，已有uid不重建。

## 接口契约

_net_snapshot返回profile2记录，14项pose精确对应23-01冻结表；_remote_added创建 `RSSkiNetGhost`，_remote_removed销毁，_remote_step仅显示。新ghost提供 `configure(row:Dictionary)->void`、`apply_sample(sample:Dictionary)->void`，无碰撞/计分/Controller。起跑位/配色用seat与全局人数，不改本地视口槽。

finish使用RSPartyGame两参 `send_event("finish",{local_slot:<本地槽>,base_score:<int>,score_revision:<int>})`；不是session三参签名。确认奖励一次，ranked_all合并远端纯数据，重置只清本机模拟及旧局幽灵。地图摘要不匹配必须在开局前拒绝。

## 依赖与顺序

23-08已合并，继承23-01全部冻结结果；可与23-09并行。接口/显示路径不足先给维护者列需求，不改卡外party_ui等。

## 验收

import后 `<Godot> --headless --path game res://tests/test_lan_ski.tscn` 输出 `RS_LAN_SKI_TESTS: <n> checks, 0 failures`。**127.0.0.1双实例**1+1、1+3检查无碰撞幽灵、全局起点、地图摘要拒绝、重复finish、离开清理、重置/第二局隔离。

非LAN ski demo=2/4、暂停/重开/回放/纪录隔离、smoke全headless；AGENTS/i18n。没有实际渲染或体感验收声明；临时测试peer双实例入口以后由runner自动化。

## 不要做

不改滑板/框架/素材，不修改profile或玩法物理，不以远端Player模拟、不自行发奖，不接非127网络。

## 预计规模

约300–400行，新文件各≤1000行；旧主脚本只集中适配，不借此重构，超范围先列需求。
