# 39-18 室内场馆壳与室内灯光预设

Issue #39 F10（#58 P2 的 C6 室内场馆壳的代码部分）· 区域：框架（`game/core/`）

## 目标 / 范围外

**目标：** 新增 `RSArenaHall`：按尺寸生成一个室内场馆的壳（地面、四面墙、天花板和梁），并建好对应的室内环境（`WorldEnvironment`：环境光、反射、色调映射 AgX、SSAO、雾、glow），全部经过 `RSSettings.environment(env)` 让画质档位生效。乒乓球、拳击、保龄球翻新都能用；项目只选尺寸和一个预设（体育馆 / 拳击馆 / 球馆）。

**范围外：** 看台、灯架（39-15 / 39-16，项目自己组合进壳里）；场地地板的场线（#58 P3 的共享 `court_lines`）；保龄球现有的 `RSBowlingHall`（不迁移）；室内 HDRI 素材下载（#58 P3）。

## 先读

1. `game/scenes/bowling/bowling_hall.gd` 138-231（`_lighting()`、`_shell()`：现有项目私有的室内壳，照它的做法抽成公共版）
2. `game/core/settings.gd` 238-247（`apply_world`）、279-314（`sun_shadows`、`environment`）
3. [39-15](39-15-arena-structures.md) 的材质约定
4. [39-16](39-16-arena-lights-scoreboard.md) 的 `RSArenaLights.ceiling_grid` 签名（预设里引用它）
5. `game/core/pbr.gd` 61-90（`surface`、`standard`）
6. #58 正文 C6、C7 两行和“美术方向 / 灯光”一节（`gh issue view 58`）

## 改动文件

- 新建 `game/core/arena_hall.gd`（+ `.gd.uid`）—— 框架区
- `game/tests/test_arena.gd`：追加 `_test_hall()`（与 39-16 / 39-17 各加各的函数，合并冲突时都保留）
- `docs/ARCHITECTURE.md` 第 3 节表格加一行“场馆构件 → `RSArena` / `RSArenaLights` / `RSScoreboard` / `RSCrowd.fill_seats` / `RSArenaHall`” —— 框架区（F10 线最后合入的卡负责）

## 接口契约

```gdscript
class_name RSArenaHall
extends RefCounted

class Preset:
	var floor_id := "concrete_floor_painted"   ## RSPbr 材质 id（地面）；项目可改（木地板等到 #58 P3 入库后再换）
	var wall_id := "concrete_wall_003"
	var ceiling_color := Color(0.18, 0.19, 0.21)
	var hdri := ""                        ## 室内 HDRI 路径；"" = 用纯色环境光（#58 的室内 HDRI 到了再填）
	var ambient := Color(0.55, 0.57, 0.6)
	var ambient_energy := 0.6
	var exposure := 1.0
	var fog_density := 0.002
	var light_rows := 3                   ## 交给 RSArenaLights.ceiling_grid
	var light_cols := 4
	var real_lights := 2

static func preset_gym() -> Preset       ## 体育馆（乒乓球、排球室内）
static func preset_boxing() -> Preset    ## 暗场 + 拳台聚光（灯光由项目用 hanging_lamps 加）
static func preset_hall() -> Preset      ## 通用球馆（保龄球翻新等）

## 建壳和环境，返回根节点（含 WorldEnvironment，已调用 RSSettings.environment）。
## size：内部长宽高（米），地面中心在 xform 原点。天花板顶灯按 preset 调 RSArenaLights.ceiling_grid。
static func build(parent: Node3D, xform: Transform3D, size: Vector3, preset: Preset) -> Node3D
```

注意：默认材质 id 必须是锁定清单（`tools/assets.lock.json`）里已有的。写卡时核对过：`concrete_floor_painted`、`concrete_floor_worn_001`、`concrete_wall_003`、`plywood` 都在；锁定清单里还没有木地板。

## 依赖与顺序

依赖 39-15（测试场景、材质约定）和 39-16 的 `ceiling_grid` 签名（39-16 未合入时 `build` 先不建顶灯，留一行 TODO 注释写明由哪张卡接上——合并前必须二者之一已合入，避免 TODO 留在 dev）。可以与 39-17 同时做。

## 验收

`test_arena.gd` 的 `_test_hall()`：

- `build` 后有且只有一个 `WorldEnvironment`；`environment.tonemap_mode == TONE_MAPPER_AGX`；改 `RSSettings.quality` 后调用 `RSSettings.apply_world(root)`，SSAO 等开关按画质变化（与 `RSSettings.environment` 的现有规则一致）
- 墙、地、天花板的包围盒等于 `size`
- 三个预设都能建出来；`hdri == ""` 时不加载贴图、不报错
- 顶灯数量与预设一致，真实光源数 = `real_lights`

命令：`<Godot> --headless --path game res://tests/test_arena.tscn`（`RS_ARENA_TESTS: <n> checks, 0 failures`），`python tools/check_conventions.py`。

## 不要做

- 不改 `RSBowlingHall` 和保龄球项目。
- 不加 `DirectionalLight3D`（室内没有太阳）。
- 不下载 HDRI 或材质。

## 预计规模

`arena_hall.gd` 约 180 行，测试约 60 行，文档 1 行。
