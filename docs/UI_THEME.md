# 界面主题

所有 2D 界面（主菜单、菜单子页面、设置 / 暂停菜单、游戏大厅、新手教学、成绩）共用 `game/core/ui_kit.gd`（`RSUi`）里的一套主题。
根节点设置 `theme = RSUi.theme(字号)` 后，普通的 `Button`、`OptionButton`、`CheckBox`、`LineEdit`、`HSeparator`、滚动条和下拉列表就会自动使用统一样式，不需要逐个控件设置。

## 颜色

| 常量 | 用途 |
|---|---|
| `TEXT` / `TEXT_MUTED` | 正文 / 说明和提示 |
| `ACCENT` | 焦点框、选中状态、主要操作 |
| `HIGHLIGHT` | 星数、地图信息、需要玩家处理的提示 |
| `GOOD` / `BAD` | 连接正常 / 未连接等状态 |
| `SURFACE`、`SCRIM`、`STROKE` | 弹出面板底色、面板后面的遮罩、细边框 |

玩家颜色仍由 `RSProfiles` 提供（包括色弱友好配色），主题不改动玩家颜色。

## 样式

- `modal_style()`：盖在菜单或游戏上的完整面板，带阴影。
- `card_style()`：面板内的分组（地图、玩家、每个项目的纪录）。
- `button_style(状态)`：按钮的 normal / hover / pressed / disabled / focus。焦点是蓝色描边，左侧加粗，手柄和键盘都能看清当前选中项。
- `chip_style(颜色)`：状态条，例如主菜单底部的 hub 连接状态。
- 每页唯一的主要操作（如“开始大赛”）设置 `theme_type_variation = &"RSPrimary"`，显示为实心蓝色按钮。
- 标题用 `RSUi.font_bold()`，正文用 `RSUi.font()`。

## 截图

1600×900，Godot 4.7.2 实际渲染。菜单背景和预览图包含 CC0 的 Poly Haven 素材。

| 中文 | English |
|---|---|
| ![主菜单](screenshots/ui-theme-menu-zh.png) | ![Main menu](screenshots/ui-theme-menu-en.png) |
| ![单人挑战](screenshots/ui-theme-solo-zh.png) | ![Party tournament](screenshots/ui-theme-party-en.png) |
| ![新手教学](screenshots/ui-theme-tutorial-zh.png) | |

复现截图：

```sh
<Godot> --path game --resolution 1600x900 res://tests/ui_capture.tscn -- --ui-shots=out/ui
```

## 没有覆盖

游戏中的 HUD（分数、计时、各项目的提示）和手柄调试场景还是各自的样式，后续单独统一。
