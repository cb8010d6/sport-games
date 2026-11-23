# 39-12 RSWaterWake：尾迹与浪花接口

Issue #39 F8（#58 P4 的代码部分）· 区域：框架（`game/core/`、`game/shaders/`）

## 目标 / 范围外

**目标：** 载具（水上摩托、以后的飞机落水、高尔夫落水）在共享水面上留下尾迹：一个固定容量的环形缓冲，用 MultiMesh 画贴在浪面上的泡沫条带，随时间变宽、变淡；外加一个“溅水”调用点，先给出最小的粒子效果，以后由 #58 的 `RSVfx`（E2 浪花）替换内部实现，调用方不变。

**范围外：** 屏幕空间或渲染到纹理的尾迹（成本高，先不做）；载具的浮力和操控；浪花贴图素材（#58 P6）。

## 先读

1. [39-11](39-11-water-surface.md) 的接口契约（`RSWaterSurface.height_at`、`update(t)`）
2. [39-10](39-10-water-waves.md) 的 `RSWater.normal_at`
3. `game/core/crowd.gd` 44-60（MultiMesh + 每实例颜色 / 自定义数据的写法）
4. `game/core/props.gd` 107-130（`place()`：MultiMesh 批量放置的现有约定）
5. `game/core/settings.gd` 37-51（`quality`、`split_tier`）

## 改动文件

- 新建 `game/core/water_wake.gd`（+ `.gd.uid`）—— 框架区
- 新建 `game/shaders/rs_water_wake.gdshader`
- `game/tests/water_cases.gd`：追加用例
- `docs/ARCHITECTURE.md` 第 3 节表格加一行“水面 → `RSWater` / `RSWaterSurface` / `RSWaterWake`” —— 框架区（F8 线最后一张卡）

## 接口契约

```gdscript
class_name RSWaterWake
extends MultiMeshInstance3D

const CAPACITY := [64, 128, 256, 256]   ## 按 RSSettings.quality 取；split_tier 时减半
var lifetime := 4.0                      ## s：一段尾迹从出现到完全消失
var spacing := 0.6                       ## m：两段之间的最小距离（低于它不新增段）

func _init(surface: RSWaterSurface) -> void
## 载具每个物理步调用：在 pos（水平位置）沿 dir 方向记录一段，宽 width 米、强度 strength（0..1，按速度给）。
## 环形缓冲满了覆盖最旧的段。
func emit(pos: Vector3, dir: Vector3, width: float, strength: float, t: float) -> void
## 每帧调用：按 surface.height_at 把每段贴到浪面上，按年龄写透明度和宽度（自定义数据），不分配内存。
func update(t: float) -> void
func clear() -> void                     ## 重开 / 换地图

## 溅水：在 pos 处放一次性浪花，strength 0..1。本卡用一个最小的 GPUParticles3D 预设实现，
## 以后 #58 的 RSVfx 就绪后只替换这个函数内部。
static func splash(parent: Node3D, pos: Vector3, strength: float) -> void
```

约定：尾迹段的世界位置只存水平坐标和出生时间，高度每帧从水面查（浪会把尾迹托起来）；同一个 `RSWaterWake` 可以给多辆载具共用（容量按总量算），也可以每辆一个。

## 依赖与顺序

依赖 39-11。

## 验收

- `water_cases.gd` 追加（不渲染）：
  - 连续 `emit` 超过容量后实例数不超过 `CAPACITY[quality]`，最旧的被覆盖
  - 间距小于 `spacing` 的连续 `emit` 不新增段
  - `update` 后每段的 y 等于 `surface.height_at`；超过 `lifetime` 的段透明度为 0
  - `clear()` 后可见段为 0
  - `splash` 在不在树里的父节点上调用不报错
- 命令：`python tools/test_game.py --godot <Godot>`（`RS_SHELL_TESTS: 0 failures`），`python tools/check_conventions.py`

## 不要做

- 不做渲染到纹理 / SubViewport 的尾迹。
- 不在 `emit` / `update` 里创建节点或数组。
- 不下载素材。

## 预计规模

`water_wake.gd` 约 130 行，着色器约 40 行，测试约 70 行，文档 1 行。
