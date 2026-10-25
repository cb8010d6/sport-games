# 39-07 RSSwingDetector：峰值候选、reset()、新鲜度门控

Issue #39 F7 · 区域：框架（`game/core/`）

## 目标 / 范围外

**目标：** 现在的 `RSSwingDetector` 只在挥动**结束**（角速度降下来并保持 0.06 s）后给摘要，延迟太大，也没有击球那一刻的姿态。本卡加：
1. `swing_peaked` 信号：峰值一确认就发（低延迟击球候选），带峰值时刻的姿态和角速度、唯一 id 和 epoch；
2. `reset()`：暂停、回中、断线、重开时取消正在进行的挥动并换 epoch；
3. 新鲜度门控：重复 / 倒退的样本不处理，样本中断太久就取消，积压太久的一批不产生候选；
4. `feed_new(c)`：不接 `samples_received` 的调用方（教学）也能只处理新样本。

现有的 `swing_started` / `swing_finished` 和摘要字段保持兼容（手柄调试页在用）。

**范围外：** 正反手 / 高低 / 拍面分类（39-08）；教学步骤（39-09）；拳击出拳识别（以后另开卡）；具体项目的击球时机判定。

## 先读

1. `game/core/swing_detector.gd`（全文 91 行）
2. `game/core/rs_controller.gd` 19-35（`player`、`sample_time`）、98-130（`left_handed`、`motion_pose`、`motion_gyro`、`history_size`、`history_index`、`push_sample`）
3. `game/autoload/controller_hub.gd` 17、225-231（`samples_received` 何时发出）
4. `game/scenes/debug/controller_debug.gd` 340-345、440-450（现有唯一调用方）
5. [乒乓球 D0 设计](../TABLE_TENNIS_DESIGN.md)“新鲜度与时钟域契约（F7 前置）”一节（需求参考）
6. `docs/ARCHITECTURE.md` 第 4 节“左手手势偏好”一段（镜像规则：`feed()` 已镜像，不要再镜像）

## 改动文件

- `game/core/swing_detector.gd` —— 框架区
- 新建 `game/tests/swing_cases.gd`（+ `.gd.uid`），`game/tests/test_shell.gd` 加 2 行注册

## 接口契约

39-08（分类）和 39-09（教学）只依赖这里写死的信号和字典字段。

```gdscript
signal swing_started(controller: RSController)                       ## 不变
signal swing_peaked(controller: RSController, swing: Dictionary)     ## 新增：每次挥动最多一次
signal swing_finished(controller: RSController, swing: Dictionary)   ## 不变，字典多几个字段

var peak_confirm := 0.7     ## 角速度从峰值降到 peak_confirm * 峰值以下时确认峰值（新增）
var max_gap := 0.3          ## s：挥动中两个样本的 hub 时间间隔超过它 → 取消本次挥动（新增）
var max_batch_span := 0.1   ## s：一批新样本跨度超过它 → 只推进游标，不产生 peaked（新增）

func reset() -> void              ## 取消进行中的挥动（不发 finished），epoch += 1，从现在起算 cooldown
func epoch() -> int
func feed(c: RSController, count: int) -> void   ## 不变：接 samples_received
func feed_new(c: RSController) -> int            ## 处理 hist_time 大于上次处理时间的全部历史样本，返回处理数
```

`swing` 字典（`swing_peaked` 和 `swing_finished` 共用；finished 额外有 `duration`、`end_orientation`）：

| 键 | 类型 | 含义 |
|---|---|---|
| `id` | int | 本探测器内递增，同一次挥动的 peaked 和 finished 相同；消费方据此“只用一次” |
| `epoch` | int | 发出时的 epoch；消费方发现与 `epoch()` 不同就丢弃 |
| `start_time` | float | 挥动开始的 hub 时间（秒） |
| `peak_time` | float | 峰值的 hub 时间（秒） |
| `peak_rate` | float | 峰值角速度 rad/s |
| `peak_gyro` | Vector3 | 峰值时的角速度（已镜像，手柄坐标系） |
| `angle` | float | 到发出时为止扫过的角度 rad |
| `axis_body` / `axis_world` | Vector3 | 主旋转轴（手柄 / 世界坐标），归一化，无效时 `Vector3.ZERO` |
| `peak_lin_accel` | float | 线加速度峰值 m/s² |
| `start_orientation` | Quaternion | 开始时姿态（`motion_pose`，已镜像） |
| `peak_orientation` | Quaternion | 峰值时姿态（已镜像）—— 拍面角度用这个，不要用 end |
| `received_msec` | int | 处理这一批样本时的 `Time.get_ticks_msec()`（游戏本地单调时钟） |
| `peak_msec` | int | 峰值在游戏时钟上的估计：`received_msec - (本批最后样本 hub 时间 - peak_time) * 1000`。不补偿网络延迟 |
| `left_handed` | bool | `c.left_handed()`，只供显示；数据已镜像 |

原有键 `duration`、`end_orientation`（只在 finished 里）保持原义。

规则：

- hub 时间重复或倒退的样本跳过；倒退超过 1 s（hub 重启）时自动 `reset()`。
- `swing_peaked` 只在本次挥动的峰值被确认时发一次；如果挥动直接结束而没确认过，先发 peaked 再发 finished。
- 被 `reset()` 或 `max_gap` 取消的挥动，不再发 peaked / finished。
- `feed` 和 `feed_new` 共用同一个“上次处理的 hub 时间”游标，混用不会重复处理。

## 依赖与顺序

无前置。39-08 可以同时开工（只用上表的字典字段，测试里自己构造字典）；39-09 要等本卡合入。

## 验收

- `swing_cases.gd` 用合成样本（`c.push_sample(t, q, gyro, accel, lin)`，写法参考 `game/tests/tutorial_cases.gd` 的 `_sample`）覆盖：
  - 一次正常挥动：started → peaked（峰值后、finished 之前）→ finished，id 相同，`peak_orientation` 等于峰值那个样本的姿态
  - 同一批样本重复喂两次（`feed` 后再 `feed_new`）：不重复发信号
  - hub 时间倒退：样本被忽略；倒退 > 1 s 时 epoch 变化
  - 挥动中途停更超过 `max_gap`：不发 peaked / finished
  - 挥动中 `reset()`：不发 finished，epoch + 1
  - 一批跨度 > `max_batch_span` 的积压样本：不发 peaked
  - 左手：同一动作在左手偏好下 `peak_rate` 相同、`peak_gyro` 为镜像值（`-M g`）
  - `peak_msec` 按公式计算
- 命令：`python tools/import_game.py --godot <Godot>`，`python tools/test_game.py --godot <Godot>`（`RS_SHELL_TESTS: 0 failures`）
- `python tools/test_left_hand.py --godot <Godot> --ui-only` 仍通过

## 不要做

- 不改默认阈值 `start_rate` / `end_rate` / `end_hold` / `min_duration` / `cooldown`（真机手感未验证，改阈值另开卡）。
- 不在探测器里做正反手判断（39-08）。
- 不改协议、不给按键包加时间戳。
- 不再镜像一次输入。

## 预计规模

`swing_detector.gd` 约 +80 / −10，测试约 150 行。
