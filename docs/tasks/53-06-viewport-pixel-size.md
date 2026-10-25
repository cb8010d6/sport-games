# 53-06 分屏 SubViewport 按窗口像素渲染

Issue #53（PR #87 的“其他发现”）· 区域：框架（`game/core/party_views.gd`、`game/core/settings.gd`）

**开工前提**：维护者已在 #53 里回答“默认值”问题（见下文“需要维护者先定”）。没回答前不要开工。

## 目标 / 范围外

**现状**：`game/project.godot` 的画布是 1600×900（`window/stretch/mode="canvas_items"`）。`RSPartyViews.add()` 用 `SubViewportContainer.stretch = true`，SubViewport 的尺寸跟着容器的**画布尺寸**走。2560×1440 窗口下，1 人全屏也只渲染 1600×900，4 人每格 796×446，再放大到窗口。所有项目都受影响（1 人也是每人一个 SubViewport）。

**目标**：SubViewport 按格子在窗口上的**实际像素**渲染，乘上一个由画质 / 设置决定的上限系数；1080p 及以下窗口行为不变（系数 ≤ 1 时保持现状）。

**范围外**：FSR / 分辨率缩放选项本身（`UPSCALE_SCALES` 不变）；HUD（画布元素本来就按窗口缩放）；高尔夫测试场景（不走 `RSPartyViews`）。

## 需要维护者先定

像素数会变成原来的（窗口宽 / 1600）²：2560×1440 下是 2.56 倍，GPU 开销会上升，抵消一部分 PR #87 的收益。可选：

- A：所有画质都按窗口像素（画质优先）；
- B：只有高 / 极高画质按窗口像素，低 / 中保持画布尺寸（**卡里默认按 B 写**，`PIXEL_SCALE_CAP` 一张表就能改成 A）；
- C：保持现状，不做本卡。

## 先读

1. `game/core/party_views.gd:33-58`（`add`：建容器和 SubViewport）、`:65-79`（`layout`）
2. `game/core/settings.gd:249-262`（`apply_viewport`：`scaling_3d_scale` 等）、`:37-51`（常量和静态变量）
3. `game/project.godot:26-29`（画布尺寸、拉伸模式）
4. `docs/perf/issue-53-2026-10-25.md` 的“其他发现”一节（问题来源和实测尺寸）

## 改动文件

- `game/core/party_views.gd`（**框架区**）
- `game/core/settings.gd`（**框架区**，加一个常量表和一个函数）
- 新建 `game/tests/view_pixels_cases.gd`，在 `game/tests/test_shell.gd` 里加一行 `preload` 和一行 `run(_check)`（写法照 `game/tests/catalog_cases.gd`）

## 接口契约

```gdscript
# game/core/settings.gd
const PIXEL_SCALE_CAP := [1.0, 1.0, 2.0, 2.0]   ## 每个画质档允许的“窗口像素 / 画布像素”上限（B 方案）

static func view_pixel_scale(window_scale: float) -> float
	## clampf(window_scale, 1.0, PIXEL_SCALE_CAP[quality])。window_scale ≤ 1 时返回 1.0（不缩小）。

# game/core/party_views.gd
static func cell_pixels(cell_size: Vector2, scale: float) -> Vector2i
	## Vector2i((cell_size * scale).round())，各分量至少 1。纯函数，便于测试。
```

- 实现方式（推荐）：`SubViewportContainer.stretch = false`；`layout()` 里对每个格子算 `scale := RSSettings.view_pixel_scale(get_viewport().get_final_transform().get_scale().x)`，设 `vp.size = cell_pixels(cell.size, scale)`，容器 `size = Vector2(vp.size)`、`scale = Vector2.ONE / scale`，使容器在画布上正好铺满格子。
- 画质改变时要重新 `layout()`：在 `RSSettings.apply()` 末尾已有遍历 SubViewport 的地方之后，由 `RSPartyViews` 监听自己已有的 `get_viewport().size_changed`，再加一个在 `apply()` 之后调用 `layout()` 的入口（例如 `RSPartyViews` 加入组 `&"rs_party_views"`，`apply()` 末尾 `call_group(&"rs_party_views", &"layout")`）。
- 鼠标：容器 `mouse_filter` 仍是 IGNORE，缩放不影响输入。
- `RSBenchmark` 已经记录 `viewport_sizes`，不需要改，PR 里用它的字段名描述结果。

## 依赖与顺序

- 依赖维护者对默认值的决定。
- 39-03（参赛者与视口分离、按队分屏）也改 `party_views.gd`。两张卡同时进行时，本卡只改 `add()` 的容器设置和 `layout()` 末尾的尺寸计算，不动格子划分逻辑；后合入的一方合并 dev。

## 验收

- `game/tests/view_pixels_cases.gd`（纯逻辑，CI 已跑 `test_shell`）：
  - `view_pixel_scale(1.6)` 在 quality 2 时为 1.6、quality 1 时为 1.0；`view_pixel_scale(0.8) == 1.0`；
  - `cell_pixels(Vector2(796, 446), 1.6) == Vector2i(1274, 714)`；`cell_pixels(Vector2(0.2, 0.2), 1.0)` 各分量为 1。
- 命令：`python tools/test_game.py --godot <Godot>`（期望 `RS_SHELL_TESTS: 0 failures`）；`python tools/test_perf.py --godot <Godot>`；`python tools/check_conventions.py`；`python tools/smoke_game.py <Godot> --project game`。
- 性能数字：只在 PR 里写理论像素比（例如 2560×1440、4 人、高画质：每格 796×446 → 1274×714，像素 × 2.56）；不跑基准矩阵，实际帧率留给维护者最终试玩。

## 不要做

- 不改 `game/project.godot` 的画布尺寸或拉伸模式。
- 不改 `UPSCALE_SCALES` / FSR 的含义。
- 不改格子划分（谁在左、谁在右）。

## 预计规模

`party_views.gd` 约 +25 行，`settings.gd` 约 +10 行，测试约 40 行。
