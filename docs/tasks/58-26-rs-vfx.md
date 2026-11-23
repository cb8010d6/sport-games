# 58-26 `RSVfx`：共享粒子预设（水花、尘土、闪光、彩带、冲击）

Issue #58 · P6 · E2–E5 · 区域：框架（`game/core/`）

## 目标 / 范围外

**目标**：新项目不再各写一套粒子。新建 `RSVfx`，提供一次性特效的静态调用，贴图来自 58-25 的共享图集，资源全部静态共享（53-04 篮球火焰踩过的坑），粒子数按画质和分屏档缩放：

| 函数 | issue 编号 | 用途 |
|---|---|---|
| `spray` | E2 | 船首浪花、转弯甩水（有方向） |
| `splash` | E2 | 落水大水花；39-12 `RSWaterWake.splash()` 以后内部改调它 |
| `dust` | E3 | 沙尘 / 红土扬尘 / 雪粉，颜色由调用方从地表取 |
| `sparkle` | E4 | 得分、完美击球的闪光星星 |
| `confetti` | E4 | 领奖台彩带（统一一份） |
| `impact` | E5 | 击球甜点、拳击命中、拍网：一圈冲击环 + 火花 |

**范围外**：拖尾（58-27）；尾迹（39-12）；现有项目里的粒子（滑雪雪粒子、篮球火焰等不迁移）；镜头晃动（冲击感不能只靠抖屏，抖屏仍由项目按 `RSSettings.camera_shake` 决定）。

## 先读

1. [58-25](58-25-vfx-atlas.md) 的 `vfx_particles.json` 键名和 4 × 4 网格约定
2. [53-04](53-04-ball-fire-cache.md)（静态共享资源 + 开场预热的写法和原因）
3. `game/scenes/basketball/ball.gd:150-201`（一个完整的 `GPUParticles3D` + `ParticleProcessMaterial` 建法）
4. `game/core/settings.gd:37-51`、`:265-276`（`quality`、`split_tier()`）
5. [39-12](39-12-water-wake.md) 的 `splash(parent, pos, strength)` 签名（本卡的 `splash` 保持同样的前三个参数）
6. `game/tests/catalog_cases.gd`、`game/tests/test_shell.gd:1-10`

## 改动文件

- 新建 `game/core/vfx.gd`（`class_name RSVfx`）+ `.gd.uid`（**框架区**）
- 新建 `game/tests/vfx_cases.gd`；`game/tests/test_shell.gd` 加一行 `preload`、一行 `run(_check)`
- `docs/ARCHITECTURE.md` 第 3 节加一行“粒子特效：`RSVfx.spray / splash / dust / sparkle / confetti / impact`”（**框架区**）

## 接口契约

```gdscript
class_name RSVfx
const ATLAS := "res://assets/shared/vfx/vfx_particles.png"
const ATLAS_JSON := "res://assets/shared/vfx/vfx_particles.json"
const AMOUNT_SCALE := [0.35, 0.6, 1.0, 1.0]   ## 按 RSSettings.quality；split_tier() 时再 × 0.5

static func spray(parent: Node3D, pos: Vector3, dir: Vector3, strength: float, layers: int = 1) -> void
static func splash(parent: Node3D, pos: Vector3, strength: float, layers: int = 1) -> void
static func dust(parent: Node3D, pos: Vector3, color: Color, strength: float, layers: int = 1) -> void
static func sparkle(parent: Node3D, pos: Vector3, color: Color, layers: int = 1) -> void
static func confetti(parent: Node3D, pos: Vector3, colors: PackedColorArray, layers: int = 1) -> void
static func impact(parent: Node3D, pos: Vector3, normal: Vector3, color: Color, strength: float, layers: int = 1) -> void
	## 全部是一次性（one_shot）特效：建一个 GPUParticles3D 挂到 parent，播完自动 queue_free。
	## strength 0..1 线性影响数量和速度；layers 照 RSPartyViews 约定（1 = 所有视图，1 << player = 仅该玩家）。

static func amount(base: int) -> int
	## maxi(1, roundi(base * AMOUNT_SCALE[quality] * (0.5 if split_tier() else 1.0)))，便于测试。
static func warm_up(parent: Node3D) -> void
	## 每种特效各建一个、发射一帧后删掉，让着色器在加载时编译。项目在场景加载时调用一次。
```

- 每种特效的 `ParticleProcessMaterial`、绘制网格（`QuadMesh`）、`StandardMaterial3D`（`billboard_mode = BILLBOARD_PARTICLES`、`particles_anim_h_frames = 4`、`v_frames = 4`、`vertex_color_use_as_albedo = true`）放进静态字典缓存，键为 `"<特效>:<颜色 html>"`：同一特效同一颜色复用同一组资源，不同颜色各一组（颜色数受限于玩家色 + 少量地表色，不会无限增长）。颜色写在 `ParticleProcessMaterial.color`，不要在调用后再复制或修改共享资源。
- 帧号从 `ATLAS_JSON` 读一次（静态缓存）；在 `ParticleProcessMaterial` 里用 `anim_offset_min/max` 固定到对应格子（`frame / 16.0`），`anim_speed` = 0。
- 图集缺失（58-25 未合入或稀疏检出）时用程序生成的圆形渐变贴图（照 `ball.gd` 的 `GradientTexture2D`），不报错。
- 不投影；`visibility_aabb` 按特效尺寸给定，不用默认的大包围盒。

## 依赖与顺序

依赖 58-25 的键名（可先用回退贴图合入）。39-12 合入后，另起小 PR 把 `RSWaterWake.splash()` 内部改调 `RSVfx.splash()`（不在本卡）。

## 验收

- `game/tests/vfx_cases.gd`：`amount()` 在 4 个画质 × 是否分屏下的值；同一种特效连续调用两次，两个节点的 `process_material` 和 `draw_pass_1` 是同一对象；同色 `dust` 复用材质、不同色不复用；节点 `one_shot == true`、`cast_shadow == OFF`；图集缺失时不报错。
- 命令：`python tools/test_game.py --godot <Godot>`；`python tools/check_conventions.py`。
- 画面不截图；观感由第一个使用它的项目和最终试玩确认。

## 不要做

- 不迁移现有项目的粒子。
- 不加对象池以外的全局状态；不加 autoload。
- 不用 `CPUParticles3D`。

## 预计规模

`vfx.gd` 约 250 行，测试约 70 行。
