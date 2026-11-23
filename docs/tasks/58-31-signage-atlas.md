# 58-31 广告板 / 横幅 / 场地 Logo 图集 + 共享旗面着色器 `banner_wind`

Issue #58 · P7 · A5、G4 · 区域：素材（`game/assets/shared/signage/`）+ 工具（`tools/signage.py`）+ 着色器（`game/shaders/banner_wind.gdshader`，新文件）

## 目标 / 范围外

**目标**：

1. 一套**虚构**品牌：Regina Sports 标志 + 3 个虚构赞助商（名字由领卡人起，PR 里给维护者过目），中文、英文各一版字标。
2. 两张广告板图集，交给 39-15 `RSArena.ad_boards(parent, path, width, height, atlas, slots = 4)`：横向 4 等分。
3. 一张横幅 / 场地图案图集（2 × 2 格）：横幅两格、中圈 / 场地 Logo 两格，供网球、乒乓、排球、拳击、保龄球场地使用（G4）。
4. 共享旗面着色器 `banner_wind.gdshader`：从 `golf_flag.gdshader` 的顶点摆动提炼成通用版（贴图 + 图集区域 + 固定边 + 风速），横幅、场边旗、拳台角旗共用。

全部用 SVG 源文件，由 Godot 原生 SVG 导入生成纹理（不另存 PNG）；文字在构建时转成路径（字体是仓库里已有的 OFL 字体），SVG 里没有 `<text>`。

**范围外**：广告板 / 看台几何（39-15）；场地划线（58-18）；记分牌（39-16）；**不改** `golf_flag.gdshader` 和高尔夫代码（高尔夫以后要换成共享着色器另开卡）；项目图标（58-30）。

## 先读

1. [39-15](39-15-arena-structures.md) 的 `ad_boards` 签名和“图集横向等分”的约定（第 55-58 行）
2. `game/shaders/golf_flag.gdshader`（22 行，摆动公式的出处）
3. `tools/subset_fonts.py:1-20`（fonttools 用法；`fonttools` 是可选的本地依赖，CI 不装）
4. `docs/UI_THEME.md:1-60`（字体、颜色；字标用 Barlow Condensed ExtraBold Italic / Noto Sans SC Black）
5. `game/assets/shared/signage/CREDITS.md`（模板）
6. [58-00 概览](58-00-overview.md)“和 #39 的分工”表（广告板图集路径、`banner_wind` 路径）

## 改动文件

- 新建 `tools/signage.py`：读 `game/assets/shared/signage/signage.json`（品牌、字标文字、颜色、版式），用 fontTools 的 `SVGPathPen` 把字标转成路径，拼出下面三个 SVG；`--check` 只验证已提交的 SVG 与 JSON 一致（不需要 fonttools）
- 新增 `game/assets/shared/signage/`：
  - `signage.json`（版式源）
  - `logos/*.svg`（Regina Sports 标志和 3 个虚构标志的图形部分，手绘路径）
  - `signage_boards.svg` + `.import`（英文 / 拉丁字母版，**默认**，路径与 58-00 接口表一致，见下）
  - `signage_boards_zh.svg` + `.import`（中文版，版式相同）
  - `signage_banners.svg` + `.import`（2 × 2）
  - `signage.json` 同时写明每格的名字和 UV 区域
- `game/assets/shared/signage/CREDITS.md`、`game/assets/shared/CREDITS.md`（文件数）
- `tools/asset_policy.json`：在 `game/assets/shared/` 之前加 `game/assets/shared/signage/` → `MIT`（项目原创，证据指向该 CREDITS）
- 新建 `game/shaders/banner_wind.gdshader` + `.uid`
- 新建 `tools/tests/test_signage.py`；`game/tests/signage_cases.gd` + `game/tests/test_shell.gd` 两行
- `docs/ASSET_MANIFEST.json` 重新生成

## 接口契约

图集尺寸（SVG `viewBox`，导入 `svg/scale = 1.0`）：

| 文件 | viewBox | 格子 | 用法 |
|---|---|---|---|
| `signage_boards.svg` / `_zh.svg` | 4096 × 256 | 横向 4 格，每格 1024 × 256（4 : 1） | `RSArena.ad_boards(..., width, height, load(path), 4)`；板子宽高比按 4 : 1 设计，项目用别的比例会拉伸 |
| `signage_banners.svg` | 2048 × 2048 | 2 × 2，每格 1024² | 格 0、1：横幅（交给 `banner_wind`）；格 2：中圈图案；格 3：Regina Sports 标志 |

- 导入：`compress/mode=2`（显存压缩）、`mipmaps/generate=true`；颜色为 sRGB。
- 语言版本：项目按 `RSLang.english()` 选 `signage_boards.svg` 或 `signage_boards_zh.svg`（本卡不改项目）。
- SVG 规格：只允许 `<svg> <g> <path> <rect> <circle> <polygon> <linearGradient> <stop> <defs>`；无 `<text>`、`<image>`、`<script>`、外部 `href`；每个文件 ≤ 200 KB。

`banner_wind.gdshader`：

```glsl
shader_type spatial;
render_mode cull_disabled;
uniform sampler2D albedo_tex : source_color, hint_default_white, filter_linear_mipmap;
uniform vec4 uv_rect = vec4(0.0, 0.0, 1.0, 1.0);   // 图集区域 (x, y, w, h)，0..1
uniform vec4 tint : source_color = vec4(1.0);
uniform vec2 size = vec2(1.0, 0.6);                 // 网格宽高（米），网格是 XY 平面、居中、面朝 +Z
uniform int pinned_edge = 0;                        // 0 = 左边固定（旗），1 = 上边固定（挂幅），2 = 左右都固定（拉在两根杆之间的横幅）
uniform float wind = 3.0;                           // m/s，0..12
uniform float sway = 1.0;                           // 振幅倍数；拉紧的横幅给小值
uniform sampler2D cloth_normal : hint_normal;       // 可选，布纹法线（例如 hessian_230）
uniform float cloth_scale = 4.0;
```

- 摆动公式沿用 `golf_flag.gdshader` 的形式（距固定边的归一化距离 `u` 控制振幅，`TIME` 相位），`pinned_edge == 2` 时 `u = sin(PI * x 归一化)`；`BACKLIGHT` 保留，横幅背光可见。
- 网格由调用方给（`PlaneMesh`，`orientation = FACE_Z`，细分 ≥ 12 × 6）；着色器不假设固定尺寸，靠 `size` 换算。
- `cloth_normal` 没给时不采样（`hint_normal` 默认平坦）。`hessian_230` 由 58-22 锁定，本卡不重复锁定。

## 依赖与顺序

无硬依赖。39-15 可以先用 `atlas = null` 的纯色占位合入，本卡合入后项目改传图集。

## 验收

- `tools/tests/test_signage.py`：三个 SVG 存在，`viewBox` 与上表一致；标签白名单、无外部引用、无 `<text>`；每个 ≤ 200 KB；`python tools/signage.py --check` 通过（`signage.json` 里列出的每格都在 SVG 里有对应 `id="cell_<n>"` 的 `<g>`）。
- `game/tests/signage_cases.gd`：`banner_wind.gdshader` 能加载；`get_shader_uniform_list()` 含上面的全部 uniform 名；三张 SVG 能作为 `Texture2D` 加载且尺寸正确（稀疏检出时跳过，照 `test_assets.gd` 的 `RS_SPARSE_ASSETS`）。
- `python -m pytest -q tools/tests`；`python tools/test_game.py --godot <Godot>`；`python tools/import_game.py --godot <Godot>`；`node --test tools/tests/asset_sync.test.mjs`；`node tools/publication_audit.mjs --write audit-output` 无 pending；`python tools/check_conventions.py`。
- PR 描述里放三张图集的预览图（不提交）和 3 个虚构品牌名，请维护者确认名字不撞真实品牌。
- 素材记录：CREDITS 写“项目原创”、作者、`tools/signage.py` 命令、用到的字体文件（Barlow Condensed、Noto Sans SC，OFL；字形转路径后随图集分发，在 CREDITS 注明 OFL 字体来源）。

## 不要做

- 不使用任何真实品牌、赛事、联赛、场馆的名字或标志，也不做“近似仿写”。
- 不改 `golf_flag.gdshader`、`golf_course.gd`。
- 不提交 PNG 导出图或字体文件副本。

## 预计规模

`signage.py` 约 200 行，着色器约 50 行，测试约 90 行；SVG 合计 < 600 KB。
