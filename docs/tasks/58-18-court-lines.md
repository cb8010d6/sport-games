# 58-18 共享场线着色器 + 网球 / 乒乓 / 沙排场线数据

Issue #58 · P3 · C1、C2（场线部分）· 区域：框架（`game/shaders/`、`game/core/`）

## 目标 / 范围外

**目标**：从篮球的 `court.gdshader` 里把“在扫描材质上画带磨损的线”的逻辑提出来，做成通用着色器 + 场线数据：

- `court_surface.gdshader`：底材用 `RSPbr` 的三张图，叠一层涂层色，再按一组线段画线（线宽、磨损、脏污遮罩、红土上“压在土上”的胶带效果）；
- `RSCourtLines`：给出网球（双打含单打线）、乒乓球台面、沙排三种标准场线（米为单位），并一步建好材质。

**范围外**：篮球迁移到新着色器（`court.gdshader` 不动，以后翻新时再说）；乒乓球台几何（属于乒乓球项目 #60 的 `game/assets/table_tennis/` / 项目代码）；场地 Logo（58-31）；脚印 / 凹陷（项目）。

## 先读

1. `game/shaders/court.gdshader`（全文 110 行：`seg()` 线段距离、`LW` 线宽、`wear` / `scuff` 磨损、`line_coat` 粗糙度处理）
2. `game/shaders/pbr_surface.gdshader`（`RSPbr.surface` 的反平铺写法，底材采样照它）
3. `game/core/pbr.gd:38-72`（`maps`、`surface`：怎么把三张图交给着色器）
4. `game/scenes/basketball/court.gd` 里设置 `court.gdshader` 参数的地方（搜 `court.gdshader` / `set_shader_parameter("pitch"`）
5. `game/tests/catalog_cases.gd`、`game/tests/test_shell.gd:1-10`

## 改动文件

- 新建 `game/shaders/court_surface.gdshader`（**共享着色器，按框架区处理**）
- 新建 `game/core/court_lines.gd`（`class_name RSCourtLines`）+ `.gd.uid`（**框架区**）
- 新建 `game/tests/court_lines_cases.gd`；`game/tests/test_shell.gd` 加一行 `preload`、一行 `run(_check)`
- `docs/ARCHITECTURE.md` 第 3 节加一行“场地线：`RSCourtLines.material(layout, base_id)`”（**框架区**）

## 接口契约

着色器 uniform：

```glsl
uniform sampler2D albedo_tex, normal_tex, orm_tex;   // 与 pbr_surface 同名同提示
uniform float size_m = 3.0;                           // 底材贴图覆盖的米数
uniform vec4 coat_col : source_color;                 // 涂层色（硬地蓝 / 绿）；a = 0 表示不涂（红土、沙、木台面）
uniform vec4 line_col : source_color = vec4(0.95, 0.95, 0.92, 1.0);
uniform float line_w = 0.05;                          // 米
uniform float wear = 1.0;                             // 磨损强度
uniform float tape = 0.0;                             // 0..1，红土胶带：线略亮、边缘带泥污
uniform int seg_count = 0;
uniform vec4 segs[64];                                // 每段 (ax, az, bx, bz)，场地局部坐标（米），原点在场地中心，+X 沿长边
```

场地局部坐标 = 网格 UV × 场地尺寸 − 尺寸 / 2：调用方给的网格是一张 `PlaneMesh`，`size` 等于场地外包尺寸（含场外延伸），UV 0..1 铺满。

```gdscript
class_name RSCourtLines
const LAYOUTS := ["tennis", "table_tennis", "beach_volleyball"]

static func segments(layout: String) -> PackedVector4Array
	## 标准尺寸（米），线段中心线坐标：
	##   tennis：23.77 × 10.97 双打边线、8.23 单打边线、发球线距网 6.40、中线、底线中点标记 0.10
	##   table_tennis：2.74 × 1.525 台面四边（线宽 0.02）+ 中线（线宽 0.003，用 line_w 时按台面单独建材质）
	##   beach_volleyball：16 × 8 边界（无中线）
static func extent(layout: String) -> Vector2
	## 场地本身尺寸（不含场外），调用方据此加场外延伸。
static func material(layout: String, base_id: String, plane_size: Vector2, params: Dictionary = {}) -> ShaderMaterial
	## RSPbr.maps(base_id) 三张图 + segments(layout) + line_w 默认值（网球 0.05、乒乓 0.02、沙排 0.06），
	## params 覆盖任意 uniform（coat_col、tape、wear……）。
```

推荐组合（写进注释，项目照用）：硬地 = `clean_asphalt` + 蓝 / 绿 `coat_col`；红土 = `red_sand` + `tape = 1`；沙排 = `sand_01`；乒乓台面 = 项目自己的台面材质 id。

## 依赖与顺序

无硬依赖。`red_sand`、`sand_01` 由 58-15 加入；没同步时 `RSPbr.maps` 返回空图，着色器仍能画线（测试不依赖素材）。

## 验收

- `game/tests/court_lines_cases.gd`：每个 layout 的段数和关键坐标（例如网球双打边线 x 范围 ±11.885、z = ±5.485；单打 ±4.115）；全部线段在 `extent()` 以内；`material()` 返回的材质 `seg_count` 等于段数、`segs` 数组前 `seg_count` 项与 `segments()` 相同；段数 ≤ 64。
- 着色器能编译：测试里给一个 `MeshInstance3D` 挂上材质并进树一帧，无 `SHADER ERROR`（无界面也会编译）。
- 命令：`python tools/test_game.py --godot <Godot>`；`python tools/check_conventions.py`；`python tools/smoke_game.py <Godot> --project game`（篮球不受影响）。
- 画面不截图；PR 写明线的观感留给第一个使用它的项目。

## 不要做

- 不改 `court.gdshader` 和篮球代码。
- 不把线烘进贴图（issue 规定线在着色器里）。
- 不做 Logo / 中圈图案。

## 预计规模

着色器约 90 行，`court_lines.gd` 约 110 行，测试约 60 行。
