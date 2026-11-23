# 39-09 教学通用 SWING 步骤

Issue #39 F7 · 区域：框架（`game/core/`）

## 目标 / 范围外

**目标：** `RSTutorial` 增加一个通用步骤常量 `SWING`，项目在清单 `lessons` 里写 `"SWING"` 就能用：先示范，再要求玩家做一次**新的**挥拍（正手或反手都行），用 39-07 的峰值候选判定；旧的峰值、教学开始前的动作不能通过；回摆不单独过滤（由项目用 `RSSwingClassifier.toward` 处理）。

**范围外：** 发球教学（“B 抛球 → 下降时挥拍”，等乒乓球 T3 定下规则后另开卡）；回摆过滤 / 正反手文字，等 39-08 真机校准后另开卡；拳击出拳步骤。

## 先读

1. [39-07](39-07-swing-peak.md) 的接口契约（`swing_peaked`、`feed_new`、`reset`、`epoch`）
2. `game/core/tutorial.gd` 7-15（步骤常量）、53-73（`start` / `_begin_step`）、89-145（`update` 的 `match kind`）、171-196（`_motion_peak` / `_pass`）
3. `game/tests/tutorial_cases.gd`（全文：合成样本和现有步骤的测试写法）
4. `game/core/catalog.gd` 59-62（`lessons(id)`）；`tools/catalog.py` 163-165（`_step_names()` 用正则 `^const ([A-Z_]+) := \{"kind"` 从 `tutorial.gd` 读步骤名，新常量必须写成这个格式）
5. `docs/NEW_GAME.md` 第 4 节（`lessons` 写法）

## 改动文件

- `game/core/tutorial.gd` —— 框架区
- `game/tests/tutorial_cases.gd`：追加用例
- `game/i18n/en.json`：追加步骤文字
- `docs/ARCHITECTURE.md` 第 3 节“体感手势”一行补上 `RSSwingDetector.swing_peaked` / `RSSwingClassifier`；“大厅教学”一行列出 `SWING` —— 框架区

## 接口契约

```gdscript
# game/core/tutorial.gd
const SWING := {"kind": "swing", "text": "像挥拍一样快速挥动手柄（正手或反手都可以）"}

var _swing := RSSwingDetector.new()   ## 每个 RSTutorial 一个；_begin_step 时 reset()
var _swung := false                   ## 本步收到合格的 swing_peaked
```

行为：

- `_begin_step()`：`_swing.reset()`，`_swung = false`。
- `update()` 里 `kind == "swing"` 时：先 `_swing.feed_new(c)`；收到 `swing_peaked` 且满足 `swing.epoch == _swing.epoch()`、`swing.peak_time > _sample_at_start`（练习开始之后的样本）、`fresh`（沿用现有新鲜度判断）→ `_pass(c)`。示范阶段（`practicing == false`）收到的挥动不算。
- 断线、样本时间倒退（现有 `c.sample_time < _last_sample` 分支）时同时 `_swing.reset()`。
- `instruction()` 不需要左右手特判（挥拍方向不限）。
- `Demo`（教学卡上的小动画）给 `swing` 一个简单的左右摆动动画，沿用现有 `throw` 的画法即可。

## 依赖与顺序

依赖 39-07。与 39-08 无关。

## 验收

- `tutorial_cases.gd` 追加：
  - 示范阶段挥动 → 不通过；练习阶段一次合成挥动（峰值 8 rad/s）→ 通过
  - 练习开始前的历史样本里有峰值 → 不通过
  - 慢速转动（峰值 < `start_rate`）→ 不通过
  - 左手偏好下同样的动作也通过
  - `RSTutorial.step_list(["SWING"])` 返回 1 个步骤
- 命令：`python tools/test_game.py --godot <Godot>`（`RS_SHELL_TESTS: 0 failures`），`python tools/test_left_hand.py --godot <Godot> --ui-only`，`python tools/i18n_check.py`，`python tools/catalog.py --check`

## 不要做

- 不给现有 6 个项目的清单加 `SWING`。
- 不改 `THROW` 等现有步骤的判定。
- 不改 `RSSwingDetector` 的默认阈值。

## 预计规模

`tutorial.gd` 约 +30，测试约 80 行，`en.json` +1，文档 2 行。
