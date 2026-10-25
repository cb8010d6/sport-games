# 58-27 `RSTrail`：共享拖尾带（球、球拍、浮标航线提示）

Issue #58 · P6 · E6 · 区域：框架（`game/core/`）

## 目标 / 范围外

**目标**：乒乓、网球、排球、水上摩托、飞机的新玩法都要“一条跟着物体、尾部渐隐的带子”。现在只有飞机自己写了一份（`plane.gd` 的 `ImmediateMesh` 翼尖尾迹）。新建 `RSTrail`：每帧把目标位置推进环形缓冲，按“相机朝向带”或“固定朝上带”生成三角带，单一共享材质、顶点色渐隐。球拖尾默认用击球者玩家色、透明度低（issue E6）。

**范围外**：粒子（58-26）；水面尾迹（39-12 `RSWaterWake`，那是贴在水面上的变形 / 泡沫，不是空中带子）；**不迁移**飞机现有尾迹（以后另开小卡）；球拍挥拍残影的美术调参（各项目）。

## 先读

1. `game/scenes/plane/plane.gd:24-27`、`:36-46`、`:96-129`（现有写法：最小间距采样、`ImmediateMesh` 每帧重建、顶点色 alpha 渐隐）
2. `game/core/settings.gd:37-51`、`:265-276`（`quality`、`split_tier()`）
3. `game/core/party_views.gd:51`（`cull_mask = 1 | (1 << player)`：层 1 所有视图可见，`1 << player` 仅该玩家视图）
4. `game/tests/catalog_cases.gd`、`game/tests/test_shell.gd:1-10`
5. `docs/ARCHITECTURE.md` 第 3 节（`game/core/` 模块清单，新模块加一行）

## 改动文件

- 新建 `game/core/trail.gd`（`class_name RSTrail extends MeshInstance3D`）+ `.gd.uid`（**框架区**）
- 新建 `game/tests/trail_cases.gd`；`game/tests/test_shell.gd` 加一行 `preload`、一行 `run(_check)`
- `docs/ARCHITECTURE.md` 第 3 节加一行（**框架区**）

## 接口契约

```gdscript
class_name RSTrail
extends MeshInstance3D

enum Facing { CAMERA, UP }            ## CAMERA：带面朝向当前相机（球）；UP：带面竖直（浮标航线、飞机翼尖）
const POINTS := [12, 20, 32, 32]      ## 按 RSSettings.quality 的最大采样点数；split_tier() 时再 × 0.5（≥ 6）

var target: Node3D                    ## 每帧采样 target.global_position；null 时不采样，只渐隐
var color := Color(1, 1, 1, 0.35)     ## 头部颜色；尾部 alpha → 0
var width := 0.06                     ## 头部宽度（米），尾部线性收到 width * tail_scale
var tail_scale := 0.2
var life := 0.35                      ## 一个点从头到消失的秒数
var min_step := 0.03                  ## 与上一个点距离小于它不追加（米）
var facing := Facing.CAMERA

static func make(parent: Node, target: Node3D, color: Color, width: float = 0.06, layers: int = 1) -> RSTrail
func push(pos: Vector3, up: Vector3 = Vector3.UP) -> void   ## 手动追加一个点（target 为 null 时用）
func clear() -> void
func point_count() -> int                                    ## 测试用
```

- `top_level = true`，`cast_shadow = OFF`，`layers` 照参数；`mesh` 是自己的 `ImmediateMesh`，`material_override` 用**静态共享**的 `StandardMaterial3D`（unshaded、`vertex_color_use_as_albedo`、alpha 混合、`cull_disabled`），全游戏只一份。
- 采样在 `_process` 里做（不进物理步）；点的年龄超过 `life` 就丢弃；点数超过 `POINTS[...]` 丢最旧的。
- `Facing.CAMERA`：带的横向 = `(p[k+1] - p[k]).cross(到相机方向).normalized()`，相机取 `get_viewport().get_camera_3d()`。分屏下每个视图的相机不同，本卡**只按当前渲染视口的相机算一次**（拖尾很细，侧视误差可以接受）；在 PR 里写明这一点。
- 少于 2 个点时清空网格，不报错。

## 依赖与顺序

无依赖。乒乓（#60）、网球（#63）等项目接入时直接调用。

## 验收

- `game/tests/trail_cases.gd`（不需要相机：用 `Facing.UP` 测几何）：连续 `push` 间距小于 `min_step` 不增点；点数封顶等于当前画质的 `POINTS` 值（分屏减半）；年龄超过 `life` 的点被丢弃（直接调内部的推进函数，传入 `delta`）；生成的顶点数 = `(点数 − 1) × 6`；头部 alpha = `color.a`、尾部 alpha = 0；两个 `RSTrail` 的 `material_override` 是同一对象。
- 命令：`python tools/test_game.py --godot <Godot>`；`python tools/check_conventions.py`。
- 性能：只给一个数字——在 `game/tests/test_perf.gd` 加 `RS_PERF_TRAIL: 8 trails x 32 pts = N us/frame`（8 条拖尾每帧重建网格的耗时），用 `python tools/test_perf.py --godot <Godot>` 跑一次贴进 PR。不做其他基准。

## 不要做

- 不改 `plane.gd`。
- 不用 `GPUParticles3D` 的 trail 模式（分屏和颜色控制都不合适）。
- 不加 autoload 或全局管理器。

## 预计规模

`trail.gd` 约 140 行，测试约 70 行，性能条目约 20 行。
