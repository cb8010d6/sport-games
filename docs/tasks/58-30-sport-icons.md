# 58-30 项目图标 SVG（运动剪影）

Issue #58 · P7 · G1 · 区域：素材（`game/assets/shared/icons/`）+ 框架（`RSGameModule` 加一个字段）

## 目标 / 范围外

**目标**：给每个运动项目画一个单色剪影图标，主菜单、派对总积分榜、成绩页、教学页以后都用同一套。风格跟 `RSUi` 一致：粗、方角、整体向右倾斜 `RSUi.SKEW`，像 Barlow Condensed ExtraBold Italic 的笔画。项目自绘 SVG，许可 MIT（不用 game-icons.net，那是 CC BY；Kenney Sports Pack 是俯视像素风，不合适）。

12 个图标，文件名 = sport id：现有 `archery`、`basketball`、`bowling`、`golf`、`plane`、`skate`、`ski`，新项目 `table_tennis`（#60）、`tennis`（#63）、`volleyball`（#64）、`boxing`（#62）、`jetski`（#61）。

同时给 `RSGameModule` 加 `icon` 字段，现有 7 个 `_module.tres` 填上路径，菜单以后从目录里取图标。

**范围外**：菜单、积分榜、成绩页里**显示**图标（框架另开卡，等 UI 排版确定）；新项目的 `_module.tres`（各项目建自己的时候填）；菜单预览图（G2，`tools/capture_previews.py` 已有流程）；横幅 / Logo（58-31）。

## 先读

1. `docs/UI_THEME.md:1-60`（颜色、字体、方角、倾斜）
2. `game/core/ui_kit.gd:9-20`、`:205-220`（`TEXT`、`ACCENT`、`SKEW = 0.22` 和倾斜条的画法）
3. `game/core/game_module.gd:1-30`（字段写法；顶部注释要求和 `tools/catalog.py` 的 `DEFAULTS` 同步）
4. `tools/catalog.py:20-62`（`DEFAULTS`、`.tres` 解析）
5. `game/core/catalog.gd:98-105`（`_entry()` 输出的字段）
6. `game/assets/shared/CREDITS.md`、`tools/asset_policy.json:85-95`（`shared/` 规则；更窄的前缀放前面）

## 改动文件

- 新增 `game/assets/shared/icons/<sport_id>.svg` × 12 + `.import`
- 新建 `game/assets/shared/icons/CREDITS.md`（“项目自绘，MIT”，每个文件一行：文件名、作者、日期、绘制工具）；`game/assets/shared/CREDITS.md` 表格加 `icons/` 一行
- `tools/asset_policy.json`：在 `game/assets/shared/` 之前加 `{"prefix": "game/assets/shared/icons/", "license": "MIT", "evidence": "game/assets/shared/icons/CREDITS.md"}`
- `docs/ASSETS.md:94` 目录树加 `icons/`；`docs/ASSET_MANIFEST.json` 重新生成
- `game/core/game_module.gd`（**框架区**）：`preview` 后加 `@export_file("*.svg") var icon := ""   ## monochrome sport icon (white on transparent), tinted by the UI`
- `game/core/catalog.gd`（**框架区**）：`_entry()` 加 `"icon": m.icon`
- `tools/catalog.py`：`DEFAULTS` 加 `"icon": ""`
- `game/scenes/<7 个现有项目>/<id>_module.tres`：各加一行 `icon = "res://assets/shared/icons/<id>.svg"`（只加这一行）
- 新建 `tools/tests/test_sport_icons.py`

## 接口契约

- SVG 规格：`viewBox="0 0 256 256"`，内容留 16 px 边距；只有 `<path>` / `<g>` / `<polygon>` / `<rect>` / `<circle>`，填充**只用纯白** `#ffffff`（界面用 `modulate` 染成 `TEXT` / `ACCENT` / 玩家色），无渐变、无描边、无 `<text>`、无 `<image>`、无外部引用、无 `<script>`；每个文件 ≤ 4 KB。
- 倾斜：整个剪影套 `transform="skewX(-12.4)"`（`atan(0.22)` ≈ 12.4°，与 `RSUi.SKEW` 的方向一致：顶部向右）；在 PR 里放一张 12 个图标的拼图（只在 PR 描述里，不提交）。
- 笔画：最细处 ≥ 14 px（256 视窗），保证缩到 48 px 还看得清；人物剪影和器材（球拍、球、滑板、雪杖……）各项目要一眼可分。
- 导入：Godot 4 原生 SVG 导入为纹理，`svg/scale` 设为 1.0（256 px），`mipmaps/generate=true`，`compress/mode=0`（无损；图标小，显存可忽略）。
- `icon` 字段为空表示没有图标，读的人自行回退（本卡不实现回退）。

## 依赖与顺序

无依赖。和 39 / 57 的卡都不改同一处（`game_module.gd` 只加一行字段；若同时有别的卡改 `catalog.py` 的 `DEFAULTS`，后合入的合并 dev）。

## 验收

- `tools/tests/test_sport_icons.py`：12 个文件齐全；逐个用 `xml.etree` 解析，检查 `viewBox`、标签白名单、`fill` 只有白色、无 `href` / `<script>` / `<text>`、字节 ≤ 4 KB；`tools/catalog.py` 解析出的每个 `ready` 模块 `icon` 非空且文件存在。
- `python -m pytest -q tools/tests`；`python tools/test_game.py --godot <Godot>`（目录测试仍 0 失败）；`python tools/import_game.py --godot <Godot>`；`node --test tools/tests/asset_sync.test.mjs`；`node tools/publication_audit.mjs --write audit-output` 无 pending；`python tools/check_conventions.py`。
- 观感由维护者看 PR 拼图决定；游戏内未显示，PR 里写明。

## 不要做

- 不描摹任何现有图标库、奥运 / 联赛象形图或品牌标志。
- 不改菜单、积分榜、成绩页的布局。
- 不用位图。

## 预计规模

代码约 15 行，测试约 60 行；12 个 SVG 合计 < 50 KB。
