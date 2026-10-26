# #23 · 独立LAN页与参数入口 · 框架（菜单）

## 目标 / 范围外

接入独立LAN页面、准备/加入/拒绝/离开状态和获准参数；使用RSUi。只做headless结构与事件验收，不做截图、试玩、其他菜单改版或任意地址联机。

## 先读

1. [23-00](23-00-overview.md)：接口/地址/阶段权威。
2. [23-08](23-08-party-hooks.md)：进入比赛与回菜单。
3. [23-11](23-11-loopback-discovery.md)：单播发现端口模型。
4. `game/scenes/menu/main_menu.gd`：页面/参数入口。
5. `game/core/ui_kit.gd`：RSUi.theme/modal_style/card_style。
6. `docs/UI_THEME.md`：主题和主要操作按钮。

## 改动文件

- **框架**：`game/scenes/menu/main_menu.gd`；新建 `game/scenes/menu/lan_page.gd`、`game/scenes/menu/lan_page.gd.uid`；`game/core/party_game.gd` 仅LAN参数接线；`docs/ARCHITECTURE.md` 对应段。
- `game/i18n/en.json` 仅追加本页新增中文key的翻译。
- 测试：新建 `game/tests/test_lan_menu.gd`、`game/tests/test_lan_menu.gd.uid`、`game/tests/test_lan_menu.tscn`。
- 不改party_ui/pause_menu、autoload、project.godot。

## 接口契约

新增 `RSLanPage` extends Control：`configure(session:RSNetSession,discovery:RSNetDiscovery)->void`、`refresh()->void`、信号 `back_requested()`。页面操作只调用已冻结open_*/set_ready/host_load/close接口，显示名单/准备/原因；客户端不显示可执行重开或推进动作，服务端仍必须校验。

根主题RSUi.theme，面板modal_style/card_style，主要操作RSPrimary。LAN参数只在main_menu/party_game解析：`--lan-host`、`--lan-join=127.0.0.1`、`--lan-bind=127.0.0.1`、`--lan-port=N`、`--lan-discovery-port=N`；host/join互斥，非127立即拒绝且不绑定。默认LAN47810/发现47811，端口1024–65535、两者及hub不冲突；已有--hub-port逻辑只读沿用，不改autoload。

页面手动join可用；发现只限已配置回环单播端口，不开放地址选择或广播。页面退出释放本页连接信号，离会话调用close；主机离开全员回菜单，暂停覆盖层不停止会话。

## 依赖与顺序

23-08、23-11均已合并，相关接口已在当前dev。项目适配可独立进行；不把未合并菜单改动作为项目卡前提。

## 验收

import后 `<Godot> --headless --path game res://tests/test_lan_menu.tscn` 输出 `RS_LAN_MENU_TESTS: <n> checks, 0 failures`。headless构造页面并调用事件：主题/主要按钮、准备/拒绝原因、禁富文本、重复进入退出信号不倍增。

**127双实例**菜单进入→准备→比赛→主机回大厅；客户端推进失败，PLAY中加入busy，主机离开客户回菜单。参数host/join冲突、非法IP/端口/hub冲突均不绑定；人工点击/画面不宣称已验收。跑AGENTS/i18n与headless smoke。

## 不要做

不改其他菜单版式或party_ui/pause_menu，不新增autoload/依赖，不增加任何可选非127 bind、不用机器名作广告、不保存地址。

## 预计规模

约300–400行，新文件各≤1000行；party_game只少量参数接线，不借此重构；范围不足先提需求。
