# 39-08 RSSwingClassifier：正手 / 反手、高低、速度、拍面

Issue #39 F7 · 区域：框架（`game/core/`）

## 目标 / 范围外

**目标：** 新增纯函数类 `RSSwingClassifier`：输入一次挥动的摘要（39-07 的 `swing` 字典）和回中时的姿态，输出统一的挥拍描述：正手 / 反手、低 / 中 / 高、力度（0–1）、击球瞬间拍面相对回中的俯仰和扭转、是不是“朝前出拍”（区分回摆）。乒乓球、网球、排球都用这一套，项目只把它映射到自己的击球参数。

**范围外：** 什么时候算击中（时机窗口是项目规则）；拳击出拳；排球垫 / 传 / 扣的具体判定（项目在本类输出上自己判断）；真机阈值校准（参数做成可调，默认值只是起点）。

## 先读

1. [39-07](39-07-swing-peak.md) 的 `swing` 字典字段表
2. `game/core/rs_controller.gd` 98-120（`left_handed`、`motion_pose`、`motion_orientation`、`motion_gyro`、`motion_roll`）
3. `game/core/tilt_stick.gd`（回中姿态和“相对回中”的写法）
4. `docs/ARCHITECTURE.md` 第 4 节“左手手势偏好”一段
5. [乒乓球 D0 设计](../TABLE_TENNIS_DESIGN.md)“F7 初值”一段（力度、上下旋、侧旋的映射需求）

## 改动文件

- 新建 `game/core/swing_classifier.gd`（+ `.gd.uid`）—— 框架区
- 新建 `game/tests/swing_classify_cases.gd`（+ `.gd.uid`），`game/tests/test_shell.gd` 加 2 行注册

## 接口契约

```gdscript
class_name RSSwingClassifier
extends RefCounted
## 输入已经镜像过（左手玩家的正手与右手玩家的正手得到相同结果），本类不再镜像。
## 坐标：回中姿态 neutral 定义的参考系，+Y 向上，-Z 是玩家面向的方向。

enum Side { FOREHAND, BACKHAND }
enum Height { LOW, MID, HIGH }

class Params:
	var rate_min := 5.0          ## rad/s：力度 0 对应的峰值角速度（= RSSwingDetector.start_rate）
	var rate_full := 12.0        ## rad/s：力度 1
	var high_pitch := deg_to_rad(35.0)    ## 峰值时手柄前端相对回中上抬超过它 → HIGH
	var low_pitch := deg_to_rad(-20.0)    ## 低于它 → LOW
	var backswing_min := deg_to_rad(15.0) ## 起点偏离中线不足这个角度、且向外摆 → 判为回摆
	var face_axis := Vector3.RIGHT        ## 拍面法线在手柄坐标系里的方向（右手持握）

static func classify(swing: Dictionary, neutral: Quaternion, params: Params = null) -> Dictionary
```

返回字典：

| 键 | 类型 | 含义 |
|---|---|---|
| `side` | int (`Side`) | 绕竖直轴的转动方向：右手正手（从持拍侧扫向身体另一侧）为 FOREHAND |
| `height` | int (`Height`) | 峰值时手柄前端相对回中的俯仰 |
| `power` | float | `clampf((peak_rate - rate_min) / (rate_full - rate_min), 0, 1)` |
| `toward` | bool | true = 朝前出拍；false = 回摆（项目应忽略） |
| `face_normal` | Vector3 | 峰值时拍面法线，回中参考系 |
| `face_pitch` | float | rad，拍面相对回中的俯仰（+ = 拍面向上翻，用于上 / 下旋映射） |
| `face_roll` | float | rad，相对回中的扭转（用于侧旋映射） |
| `peak_rate` | float | 原样带出 |
| `peak_msec` | int | 原样带出（项目据此算早 / 好 / 晚） |
| `id` / `epoch` | int | 原样带出，方便消费方去重 |

判定规则（写进代码注释，参数见 `Params`）：

- `side`：`axis_world` 投影到回中参考系后的竖直分量符号（正 = FOREHAND）。
- `toward`：起点姿态相对回中的偏航角 `start_yaw` 与转动方向相反（从外侧摆回中线 / 穿过中线），且 `|start_yaw| >= backswing_min` 时为 true；从中线附近向外摆为回摆。
- `height`：`peak_orientation` 相对 `neutral` 的手柄前端俯仰与 `high_pitch` / `low_pitch` 比较。

## 依赖与顺序

只依赖 39-07 写死的字典字段，**可以和 39-07 同时做**（测试里自己构造字典，不需要探测器）。

## 验收

- `swing_classify_cases.gd` 用构造的字典覆盖：
  - 正手 / 反手各一组；同一动作的左手镜像输入（字典值由测试按 `M=diag(-1,1,1)` 规则镜像）得到相同 `side`
  - 从外侧摆回 → `toward = true`；从中线向外 → `toward = false`
  - 俯仰 +45° / 0° / -30° → HIGH / MID / LOW
  - `power` 在 `rate_min` 以下为 0、`rate_full` 以上为 1、中间线性
  - 拍面俯仰 / 扭转：峰值姿态绕手柄右轴转 +20° → `face_pitch` ≈ +20°（容差 0.5°）
  - 输入缺键时返回空字典并 `push_warning` 一次，不崩溃
- 命令：`python tools/import_game.py --godot <Godot>`，`python tools/test_game.py --godot <Godot>`（`RS_SHELL_TESTS: 0 failures`）

## 不要做

- 不连接信号、不持有状态（纯静态函数）。
- 不在这里决定击球结果或球速（交给项目 + `RSBallFlight.hit`）。
- 不改 `RSSwingDetector`。

## 预计规模

`swing_classifier.gd` 约 120 行，测试约 150 行。
