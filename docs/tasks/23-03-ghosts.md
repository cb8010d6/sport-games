# 23-03 · 滑板与滑雪远端幽灵

## 目标 / 范围外

滑板、滑雪在 LAN 一局中显示对面玩家的无碰撞幽灵、全局起跑位和完赛结果。远端幽灵只读取快照，自机物理与输入仍由原项目模拟。

## 先读

1. [23-02](23-02-round.md)
2. [LAN_PLAY.md](../LAN_PLAY.md) 第 2、5 节及附录 A
3. `game/scenes/skate/skate_game.gd`、`game/scenes/ski/ski_game.gd` 的回放帧和结束流程

## 改动文件

- 新增 `game/core/net_remote.gd` 与 UID；`game/core/net_session.gd`、`game/core/party_game.gd` 只接快照及幽灵钩子。
- 两个项目各自的 `skate_game.gd`、`ski_game.gd`、各自新增 `net_ghost.gd` 与 UID；`game/i18n/en.json` 只追加新增文案。
- 新增 `game/tests/net_remote_cases.gd` 与 UID，`game/tests/test_shell.gd` 注册；滑板/滑雪各用 `game/tests/test_lan_skate.gd`、`game/tests/test_lan_ski.gd`，含 UID 和同名测试场景。
- `docs/ARCHITECTURE.md`、`docs/protocol.md` 同步实际快照和钩子。

## 接口契约

- `net_remote` 按本局座位持有短时间窗，插值位置、四元数与姿势，短暂断流时限制外推，长断流冻结；断线、切图与回大厅清理。不混入本地 `players`。
- 两项目以 20 Hz 发送当前快照，卡顿时不补发过期快照。姿势字段来源和合法范围以项目为准，编码前加边界验证；附录布局随真实字段一起定稿。
- 项目使用主机冻结的起跑顺序。相机图层、OLED、暂停和个人输入仍用本地槽，远端无碰撞、不可触发本地计分或存档。

## 依赖与顺序

依赖 23-02。与 23-04 协调 `party_game.gd` 的接线修改。

## 验收

无界面覆盖正常插值、短时丢包后的恢复、长断流、传送、旧局快照和幽灵回收；滑板/滑雪各做 2/4 人启动回归，覆盖本地回放与完赛。幽灵实际观感留给双机试玩。

## 不要做

不改玩法物理、完整回放格式、输入频率或引入远端碰撞。

## 预计规模

公共缓冲一份，项目适配各一份，避免复制会话和插值。
