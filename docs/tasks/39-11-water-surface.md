# 39-11 RSWaterSurface：水面网格、着色器、泡沫、画质

Issue #39 F8（#58 P4 的代码部分）· 区域：框架（`game/core/`、`game/shaders/`）

## 目标 / 范围外

**目标：** 一个可以直接放进场景的共享水面节点：顶点按 39-10 的公式位移的网格（近密远疏），物理着色（深浅色、近岸透明、浪尖和近岸泡沫），海湾 / 湖泊预设一行切换，网格密度随画质档位和分屏数降低。项目只需 `RSWaterSurface.new(preset, size)`、加进场景、每帧 `update(t)`。

**范围外：** 尾迹、浪花（39-12）；泡沫贴图素材本身（#58 P4 负责，路径见下）；替换飞机 / 滑板 / 高尔夫的水；水下效果。

## 先读

1. [39-10](39-10-water-waves.md) 的接口契约（`Preset`、`apply_to`、`water_waves.gdshaderinc`、时间约定）
2. `game/shaders/sea.gdshader`（全文：深度贴图做近岸透明、远处细浪转粗糙度的写法，可以照搬思路）
3. `game/core/settings.gd` 37-51（`quality`、`views`、`SPLIT_TIER_VIEWS`）、238-271（`apply_world`、`apply_viewport`、`set_views`、`split_tier`）
4. `game/core/pbr.gd` 20-40（`folder`、`map_path`：`shared:` 根目录怎么取贴图路径）
5. `docs/ASSETS.md` 中“共享素材库”一节（`game/assets/shared/materials/` 的命名）

## 改动文件

- 新建 `game/core/water_surface.gd`（+ `.gd.uid`）—— 框架区
- 新建 `game/shaders/rs_water.gdshader`（`#include "res://shaders/water_waves.gdshaderinc"`）
- `game/tests/water_cases.gd`：追加用例
- 不改 `RSSettings`；需要的画质信息只读它的静态变量

## 接口契约

```gdscript
class_name RSWaterSurface
extends MeshInstance3D

const FOAM_TEXTURE := "res://assets/shared/materials/acg_foam002/foam_color.png"
	## #58 P4 交付的泡沫贴图；文件不存在时着色器用程序噪声代替（use_foam_texture = false），不报错

var preset: RSWater.Preset

func _init(p: RSWater.Preset, size: Vector2, center := Vector3.ZERO) -> void
	## 建网格（size 是水面范围，米）和 ShaderMaterial，调用 RSWater.apply_to
func set_preset(p: RSWater.Preset) -> void   ## 换预设（地图切换），不重建网格
func update(t: float) -> void                ## 每帧：写 wave_time；不分配内存
func apply_quality() -> void                 ## 按 RSSettings.quality 和 RSSettings.split_tier() 重建网格密度；
                                             ## 项目在 _load_map 后、以及 RSSettings.set_views 跨档后调用
func height_at(x: float, z: float) -> float  ## = RSWater.height_at(preset, x, z, 当前 t)，给项目用的便捷函数
```

网格与画质约定：

| 画质 `RSSettings.quality` | 中心区格距 | 外圈格距 | 备注 |
|---|---|---|---|
| 0 低 | 1.0 m | 8 m | 关闭近岸深度采样之外的细节法线 |
| 1 中 | 0.5 m | 4 m | |
| 2 高 / 3 极高 | 0.25 m | 2 m | |

`split_tier()` 为 true（3–4 个分屏）时再降一档。网格中心区跟随 `center`（项目可每帧把水面节点的 x / z 对齐到主角附近的整格，避免浪“滑动”：位移按世界坐标算，节点移动整格不改变画面）。

着色器 uniform（除 39-10 的波浪参数外）：`deep_color`、`shallow_color`、`clear_depth`、`foam_amount`、`foam_tex`、`use_foam_texture`、`depth_tex : hint_depth_texture`。浪尖泡沫按位移后的高度 / 陡度算；近岸泡沫按深度差算（和 `sea.gdshader` 一样）。

## 依赖与顺序

依赖 39-10。39-12 依赖本卡。泡沫贴图来自 #58 P4，没到也能合并（回退到程序噪声）。

## 验收

- `water_cases.gd` 追加（不渲染，只检查数据）：
  - `RSWaterSurface.new(preset_bay(), Vector2(200, 200))` 建出网格，四档画质的顶点数单调不增，`split_tier` 时更少
  - `update(1.5)` 后材质的 `wave_time == 1.5`；`set_preset(preset_lake())` 后 `waves` 参数改变、网格对象不变
  - `height_at` 与 `RSWater.height_at` 相同
  - 泡沫贴图不存在时 `use_foam_texture == false` 且没有错误输出
- 命令：`python tools/test_game.py --godot <Godot>`（`RS_SHELL_TESTS: 0 failures`），`python tools/check_conventions.py`
- `<Godot> --headless --path game --import` 无报错。headless 模式不保证真正编译着色器，`rs_water.gdshader` 的编译和画面由维护者在有显示的机器上随水上摩托接入一起检查
- 画面观感、4 人分屏帧时间不在本卡验收，由维护者在水上摩托接入时统一试玩

## 不要做

- 不新增依赖、不下载素材（素材归 #58）。
- 不改 `RSSettings`（如果确实需要新的画质开关，在 PR 里提出）。
- 不使用 `TIME`；不在 `update` 里重建网格。

## 预计规模

`water_surface.gd` 约 150 行，`rs_water.gdshader` 约 120 行，测试约 60 行。
