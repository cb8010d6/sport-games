# 58-17 `RSSkyPresets`：天空 + 太阳 + 雾的预设与构建

Issue #58 · P3 · C7（代码部分）· 区域：框架（`game/core/`）

## 目标 / 范围外

**目标**：issue #58“美术方向 / 灯光”要求每张地图有一个灯光预设，同一时段在不同项目里曝光、色温相近。现在每个项目各自写一遍 `setup_environment`（滑雪的写法最完整）。新建 `RSSkyPresets`：

1. 一张室外预设表（白天 / 黄金时段 / 夜 / 海湾 / 湖泊 / 海滩……），字段沿用滑雪地图数据的键名；
2. `build()` 按预设建 `WorldEnvironment` + 与 HDRI 太阳方向一致的 `DirectionalLight3D`，并调用 `RSSettings.environment()` / `sun_shadows()`，让画质档统一生效；
3. `hdri_path()` 统一拼 HDRI 路径，室内项目和 39-18 `RSArenaHall.Preset.hdri` 也用它取路径。

**范围外**：室内场馆的环境和灯（39-18 负责，只借用 `hdri_path`）；把滑板 / 滑雪 / 篮球 / 高尔夫改用本模块（不强制，以后翻新时再迁）；HDRI 下载（58-16）。

## 先读

1. `game/scenes/ski/ski_course.gd:1123-1180`（`setup_environment`：本模块的参考实现）
2. `game/scenes/ski/ski_maps.gd:10-60`（字段：`hdri`、`sky_energy`、`sky_rot`、`sun_az`、`sun_el`、`sun_color`、`sun_energy`、`ambient`、`exposure`、`fog`、`fog_density`、`lights`）
3. `game/core/settings.gd:238-247`（`apply_world`）、`:279-314`（`sun_shadows`、`environment`）
4. [58-16](58-16-hdri-set.md) 的 HDRI 列表和路径规则
5. `game/tests/catalog_cases.gd`、`game/tests/test_shell.gd:1-10`（纯逻辑测试写法）

## 改动文件

- 新建 `game/core/sky_presets.gd`（`class_name RSSkyPresets`）+ `.gd.uid`（**框架区**）
- 新建 `game/tests/sky_preset_cases.gd`；`game/tests/test_shell.gd` 加一行 `preload`、一行 `run(_check)`
- `docs/ARCHITECTURE.md` 第 3 节公共模块表加一行“天空与太阳：`RSSkyPresets.build(parent, id)`”（**框架区**）

## 接口契约

```gdscript
class_name RSSkyPresets
const HDRI_ROOT := "res://assets/polyhaven/hdris/"

static func hdri_path(id: String, res: String = "4k") -> String
	## HDRI_ROOT + "%s/%s_%s.hdr" % [id, id, res]

const PRESETS := {
	"day_clear":   {"hdri": "syferfontein_18d_clear_puresky", "res": "4k", "sky_energy": 1.0, "sky_rot": 0.0,
	                "sun_az": 35.0, "sun_el": 50.0, "sun_color": Color(1.0, 0.97, 0.92), "sun_energy": 2.6,
	                "ambient": 0.7, "exposure": 0.85, "fog": Color(0.72, 0.8, 0.92), "fog_density": 0.0002, "glow": 0.4},
	"golden":      {...},   # rosendal_park_sunset_puresky
	"night":       {...},   # 已有 rooftop_night 或 kloppenheim_02_puresky
	"bay":         {...},   # blue_lagoon
	"lake_dawn":   {...},   # lakeside_sunrise
	"beach_day":   {...},   # spiaggia_di_mondello
	"beach_night": {...},   # sandsloot
}
	## 太阳方向、颜色要和 HDRI 里的太阳对上（打开 HDRI 看一眼定 sun_az / sun_el / sky_rot），写进注释。

static func preset(id: String, overrides: Dictionary = {}) -> Dictionary
	## PRESETS[id] 的副本合并 overrides；未知 id → push_error 并返回 "day_clear" 的副本。

static func build(parent: Node, id: String, overrides: Dictionary = {}) -> DirectionalLight3D
	## 建 WorldEnvironment（PanoramaSkyMaterial、AgX、SSAO、glow、指数雾，参数同 ski_course 的写法）
	## 和 4 级级联的太阳，挂到 parent，调用 RSSettings.environment(env)、RSSettings.sun_shadows(sun)。
	## HDRI 文件不存在（稀疏检出）时改用 ProceduralSkyMaterial，不报错。返回太阳。
```

- 字段名与滑雪地图数据一致，以后滑雪等迁移时可以直接把地图字典当 overrides 传入。
- 只读文件；不依赖 `game/scenes/`（ARCH-CORE）。

## 依赖与顺序

只依赖 58-16 的路径规则（已写死），可与 58-16 同时做；58-16 未合入时测试按“HDRI 不存在”路径跑。

## 验收

- `game/tests/sky_preset_cases.gd`：`hdri_path("squash_court", "2k")` 的值；每个预设都有全部必需字段且类型正确；`preset("nope")` 回退 `day_clear`；在一个临时 `Node3D` 上 `build(node, "day_clear")` 后恰好有 1 个 `WorldEnvironment` 和 1 个 `DirectionalLight3D`，太阳 `shadow_enabled`，HDRI 缺失时天空是 `ProceduralSkyMaterial`；`RSSettings.split_tier()` 为真时太阳是 2 级级联（证明调用了 `sun_shadows`）。
- 命令：`python tools/test_game.py --godot <Godot>`（`RS_SHELL_TESTS: 0 failures`）；`python tools/check_conventions.py`。
- 画面（曝光、色温是否协调）留给第一个使用它的项目和最终试玩。

## 不要做

- 不改任何现有项目的环境代码。
- 不放室内灯光（39-18）。
- 不在预设里写玩家色或项目专属的东西。

## 预计规模

`sky_presets.gd` 约 150 行（预设表占一半），测试约 60 行。
