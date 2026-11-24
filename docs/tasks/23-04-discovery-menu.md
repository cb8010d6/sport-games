# 23-04 · 房间发现与 LAN 菜单

## 目标 / 范围外

两台电脑在同一局域网时，玩家从菜单建房、选择发现的房间，或输入主机私有 IPv4 地址加入；连不上能看到原因并返回。

## 先读

1. [LAN_PLAY.md](../LAN_PLAY.md) 第 2、4 节
2. [23-01](23-01-session.md) 和 [23-02](23-02-round.md)
3. [UI_THEME.md](../UI_THEME.md)

## 改动文件

- 新增 `game/core/net_discovery.gd` 及 UID，`game/scenes/menu/main_menu.gd`、新增 `game/scenes/menu/lan_page.gd` 及 UID；`game/core/party_game.gd` 只接 LAN 启动参数。
- `docs/ARCHITECTURE.md`、`docs/protocol.md` 对应段，`game/i18n/en.json` 增加新文案。
- 新增 `game/tests/test_lan_discovery.gd`、`game/tests/test_lan_menu.gd` 和各自 UID、同名测试场景。

## 接口契约

- 正式建房先选择本机私有 IPv4 接口；在该网段用广播发现，每秒公告、三秒过期。发现数据只用于展示，加入仍走正常握手。手动输入私有地址作为找不到广播时的后备。
- CI 和无界面发现测试单独使用回环地址及单播。眼下可通过纯地址判定测试覆盖私有网段识别；真实广播、网卡选择与系统防火墙留给维护者双机验证。
- 页面沿用 RSUi，有建房、房间列表、手动地址、退出与连接错误；退出时关闭临时发现和未完成连接。参数继续只在主菜单或 RSPartyGame 解析，端口与 hub 分开。

## 依赖与顺序

依赖 23-01、23-02。可以与 23-03 并行。

## 验收

用回环验证出现、消失、重复公告与非法数据；无界面检查建房/加入入口、手动地址反馈、失败返回和退出清理。界面 PR 按 AGENTS 提交中英文截图；双机真实发现由维护者验收。

## 不要做

不做公网匹配、自动网关映射、防火墙改写或调用任意外部地址。

## 预计规模

一个发现模块和一个页面，沿用现有主题与会话。
