# 39-10 RSWater：波浪高度函数（CPU / GPU 同一公式）

Issue #39 F8（#58 P4 的代码部分）· 区域：框架（`game/core/`、`game/shaders/`）

## 目标 / 范围外

**目标：** 定下共享水面的波浪数学：若干个 Gerstner 波叠加，GDScript 和着色器用**同一公式、同一组参数、同一时间**，所以载具在 CPU 上算出的浮力高度和画面上的浪对得上。提供海湾、湖泊两组预设。本卡只有数学和参数，不建水面网格。

**范围外：** 水面网格、颜色、泡沫、近岸（39-11）；尾迹和浪花（39-12）；把飞机、滑板、高尔夫现有的水换掉（以后在各项目卡里做）；载具浮力（水上摩托项目自己写，调用本卡的查询函数）。

## 先读

1. `game/shaders/sea.gdshader`（全文 77 行：现有无位移海面，滑板和高尔夫在用）
2. `game/shaders/water.gdshader`（全文 29 行：飞机岛屿的卡通水）
3. `game/core/fixed_step.gd` 前 20 行（core 纯逻辑类的写法）
4. #58 正文“C5 公共水面”一行和“P4”一节（`gh issue view 58`）
5. `docs/ARCHITECTURE.md` 第 3 节

## 改动文件

- 新建 `game/core/water.gd`（+ `.gd.uid`）—— 框架区
- 新建 `game/shaders/water_waves.gdshaderinc` —— 随框架
- 新建 `game/tests/water_cases.gd`（+ `.gd.uid`），`game/tests/test_shell.gd` 加 2 行注册

## 接口契约

39-11、39-12 和水上摩托都依赖以下内容。

```gdscript
class_name RSWater
extends RefCounted
## Gerstner 波：水平静止点 p0 = (x0, z0) 在时刻 t 移到 p0 + D(p0, t)，高度为 H(p0, t)。
## 每个波 i：方向 d_i（单位 Vector2）、波长 L_i、振幅 A_i；k = 2π / L，角速度 ω = sqrt(g k)（深水色散），
## 相位 θ = k (d·p0) - ω t；Q 为陡度（0..1，所有波共享，按波数分摊）。
## 位移 = Σ (Q_i A_i d_i cos θ, A_i sin θ)。着色器 water_waves.gdshaderinc 写的是逐字相同的公式。

const MAX_WAVES := 4            ## 着色器里 uniform 数组长度相同
const GRAVITY := 9.81

class Preset:
	var waves := PackedFloat32Array()   ## 每个波 4 个数：dir_x, dir_z, wavelength (m), amplitude (m)；最多 MAX_WAVES 个
	var steepness := 0.5                ## Q
	var deep_color := Color(0.015, 0.06, 0.085)
	var shallow_color := Color(0.1, 0.33, 0.32)
	var clear_depth := 3.5              ## m：近岸透明到不透明的深度
	var foam_amount := 0.5              ## 0..1：39-11 用
	func wave_count() -> int

static func preset_bay() -> Preset    ## 海湾：浪长、浪高（建议 4 个波，最大波长 20–40 m，振幅 0.3–0.6 m）
static func preset_lake() -> Preset   ## 湖泊：短而碎（建议 3 个波，振幅 ≤ 0.15 m）

## 静止点 (x0, z0) 在 t 时刻的位移（x, y, z 都是相对 p0 的偏移，y 即高度）
static func displace(p: Preset, x0: float, z0: float, t: float) -> Vector3
## 世界水平位置 (x, z) 处的水面高度：用 3 次不动点迭代反解 p0，再取 H。Q ≤ 0.6 时误差 < 2 cm。
static func height_at(p: Preset, x: float, z: float, t: float) -> float
## 世界水平位置处的单位法线（同样先反解 p0）
static func normal_at(p: Preset, x: float, z: float, t: float) -> Vector3
## 把预设写进 ShaderMaterial 的 uniform（waves、wave_count、steepness 和颜色等）
static func apply_to(p: Preset, mat: ShaderMaterial) -> void
```

```glsl
// game/shaders/water_waves.gdshaderinc
#define RS_WATER_MAX_WAVES 4
uniform vec4 waves[RS_WATER_MAX_WAVES];   // dir_x, dir_z, wavelength, amplitude
uniform int wave_count = 0;
uniform float steepness = 0.5;
uniform float wave_time = 0.0;            // 由 GDScript 每帧写入（游戏时钟，暂停时冻结），不要用 TIME
void rs_water_displace(vec2 p0, out vec3 offset, out vec3 normal);
```

**时间约定：** 着色器不用内置 `TIME`，统一用 `wave_time`，由使用方每帧写入同一个游戏时钟（项目自己的比赛秒数，或 `RSPartyGame` 每帧累加的时钟），CPU 查询传同一个 `t`。这样暂停时浪也停，CPU / GPU 永远同步。

## 依赖与顺序

无前置。39-11 依赖本卡。

## 验收

- `water_cases.gd` 覆盖：
  - 单个波时 `displace` 与手算公式一致
  - 对网格上 100 个静止点：`height_at(p0 + D.xz) ≈ D.y`，两种预设误差 < 2 cm
  - `normal_at` 是单位向量，平静水面（振幅 0）时为 `Vector3.UP`
  - 同一 `t` 重复查询结果相同；`t` 连续变化时高度连续（相邻 1/120 s 的差 < 5 cm）
  - 读取 `water_waves.gdshaderinc` 文本，确认 `RS_WATER_MAX_WAVES` 等于 `RSWater.MAX_WAVES`、有 `wave_time` uniform、没有使用 `TIME`
  - `apply_to` 后材质参数与预设一致（用一个只含该 include 的最小测试着色器，或直接检查 `get_shader_parameter`）
- 命令：`python tools/import_game.py --godot <Godot>`，`python tools/test_game.py --godot <Godot>`（`RS_SHELL_TESTS: 0 failures`），`python tools/check_conventions.py`

## 不要做

- 不改 `sea.gdshader`、`water.gdshader` 和它们的使用者。
- 不在 `height_at` 里分配数组（浮力每个物理步会调用多次）。
- 不加新的全局着色器参数（`project.godot` 不动）。

## 预计规模

`water.gd` 约 150 行，`water_waves.gdshaderinc` 约 40 行，测试约 120 行。
