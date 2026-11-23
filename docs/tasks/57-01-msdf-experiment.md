# 57-01 HUD 字体 MSDF 导入实验

Issue #57“HUD 字号动画与非 MSDF 字体” · 区域：素材（字体导入设置）+ 框架（`game/core/ui_kit.gd`，仅当结论是要改）

## 目标 / 范围外

**目标：** 用数据回答一个问题：PR #93 把 HUD 动画字号量化之后，还值不值得给 HUD 字体开 MSDF？做一个小的测量场景，在同一次运行里对比“位图光栅（现状）”和“MSDF”两种字体在分数弹跳、加分飘字、倒数这类动画下的字体纹理内存增长、首帧卡顿和描边观感，然后把结论写进文档。结论是“改”的话，另开一张卡实施（见“不要做”）。

**范围外：** 全面更换字体或子集；3D 世界里的 `Label3D`；菜单控件字体（`project.godot` 的默认主题字体已经是 MSDF）；完整的游戏内基准。

## 先读

1. PR #93 的说明和 `game/core/party_game.gd` 里 `draw_text()` / `_snap_font_size()`（#93 合入后的版本）
2. `game/core/ui_kit.gd` 24-65（`font()`、`_noto()`、`font_bold()`、`font_numeric()`：字体怎么加载、怎么挂回退）、82-130（`text_size`、`fit_text_size`）
3. `game/assets/fonts/NotoSansSC-RS.ttf.import`、`BarlowCondensed-ExtraBoldItalic.ttf.import`（`multichannel_signed_distance_field=false`、`msdf_pixel_range`、`msdf_size`）
4. `game/project.godot` 第 39 行（`default_font_multichannel_signed_distance_field=true` 只作用于默认主题字体）
5. `docs/UI_THEME.md`“字体”一节
6. `docs/PERFORMANCE.md`（`Performance.RENDER_TEXTURE_MEM_USED` 等指标的现有用法）

## 改动文件

- 新建 `game/tests/font_probe.gd` / `.tscn`（+ `.gd.uid`）：测量场景，不进 CI
- `docs/UI_THEME.md`“字体”一节末尾加“字体光栅与 MSDF”小节（结论和数据）
- 不改字体 `.import`、不改 `ui_kit.gd`（实施另开卡）

## 接口契约

测量场景的行为（不被其他代码调用，只约定输出格式，方便以后复测）：

- 启动参数 `-- --font-mode=raster|msdf|both`（默认 `both`）。`msdf` 模式在运行时复制 `RSUi` 的 HUD 字体（`FontFile.duplicate()`），设置 `multichannel_signed_distance_field = true`、`msdf_pixel_range = 8`、`msdf_size = 48` 后使用；不改导入文件。
- 在 1600×900 窗口里，用与 `RSPartyGame.draw_text()` 相同的描边规则（`maxi(3, fs / 7)`）连续 10 秒绘制：中文 + 数字混排的加分飘字（36 → 45 号放大）、倒数数字（120 → 150 号）、分数弹跳（40 → 47 号），字号经过 #93 的吸附函数。
- 每种模式输出一行：
  `RS_FONT_PROBE: mode=<m> tex_mem_start=<bytes> tex_mem_end=<bytes> first_frame_ms=<f> p99_frame_ms=<f> max_frame_ms=<f>`
- 每种模式各存一张 2× 放大的截图到 `--shots` 指定目录（只用于在 PR 里贴对比，不提交）。

## 依赖与顺序

依赖 PR #93（量化后的基线）。与其他卡无关。

## 验收

- 需要真实渲染，不能用 `--headless`：在有显示的机器上运行一次（协调者本机按协调者给的隐藏桌面方式运行，不弹窗）：
  `<Godot> --path game --resolution 1600x900 res://tests/font_probe.tscn -- --font-mode=both --shots=out/font_probe`
- PR 说明贴两行 `RS_FONT_PROBE` 输出和两张截图的对比（描边、小字号清晰度）。
- `docs/UI_THEME.md` 写清楚：两种模式的数字、结论（保持位图 / 只给拉丁数字字体开 MSDF / 全部 HUD 字体开 MSDF）、理由；中文 CJK 字体的导入时间和包体变化（如果测了）。
- `python tools/check_conventions.py`、`python tools/i18n_check.py`（测量场景里的文字用固定中文常量，确认 i18n 脚本不把它当成未翻译文案；需要时按现有测试文件的豁免方式处理）。
- 不做完整游戏试玩或截图巡检。

## 不要做

- 不在本卡里改字体导入设置或 `RSUi`（结论是“改”时，在 PR 里提出，由维护者开 57-07 实施卡，改动只涉及 `.import` 或 `ui_kit.gd` 的几行）。
- 不提交截图和测量输出。
- 不改 #93 的量化逻辑。

## 预计规模

测量场景约 150 行，文档约 20 行。
