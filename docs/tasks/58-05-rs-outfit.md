# 58-05 `RSOutfit`：共享阵容的路径与可重染材质槽

Issue #58 · P1 · D1 · 区域：框架（`game/core/`）

## 目标 / 范围外

**目标**：新建 `RSOutfit`，让项目代码只写“我是哪个项目、这是第几个 avatar”，就拿到共享角色的路径；并提供按材质名找到可重染表面的帮助函数，替代各项目 rig 里重复的“遍历网格 → 按材质名 match”代码。

**范围外**：生成角色（58-04）；把现有项目切换过去（58-06）；改 `RSHumanRig` 的加载 / 姿态逻辑；材质外观（尼龙、棉布等仍由各项目 rig 决定）。

## 先读

1. [58-04](58-04-character-generator.md)“接口契约”的目录约定和 `materials` 约定
2. `game/core/human_rig.gd:39-82`（`_load_character(path)`：拿到路径后怎么加载）
3. `game/scenes/ski/skier_rig.gd:310-340`（现在怎么按材质名 `jacket / pants / glove` 重染）
4. `game/core/profiles.gd`（`RSProfiles.avatar(slot)` 返回 0–3）
5. `game/tests/catalog_cases.gd`、`game/tests/test_shell.gd:1-10`（纯逻辑测试的写法）

## 改动文件

- 新建 `game/core/outfit.gd`（`class_name RSOutfit`）+ `.gd.uid`（**框架区**）
- 新建 `game/tests/outfit_cases.gd`；`game/tests/test_shell.gd` 加一行 `preload`、一行 `run(_check)`
- `docs/ARCHITECTURE.md` 第 3 节公共模块表加一行“人物：`RSOutfit.path(sport, avatar)`”（**框架区**）

## 接口契约

```gdscript
class_name RSOutfit
const ROOT := "res://assets/shared/characters/"
const ROSTER_SIZE := 4

static func path(sport: String, avatar: int) -> String
	## ROOT + "outfits/%s/avatar%d.gltf" % [sport, posmod(avatar, ROSTER_SIZE)]

static func exists(sport: String, avatar: int) -> bool
	## ResourceLoader.exists(path(sport, avatar))；项目在共享角色还没生成时可以退回旧路径。

static func roster() -> Array
	## 读 ROOT + "roster/roster.json" 的 "avatars"（缓存）；文件不存在返回 []。

static func slots(root: Node, names: PackedStringArray) -> Dictionary
	## { 材质名: [[MeshInstance3D, surface_index], ...] }，只收 names 里列出的材质名，
	## 按 mesh.surface_get_material(i).resource_name 匹配（与现有 rig 的 match 相同）。

static func paint(root: Node, name: String, material: Material) -> int
	## 对 slots(root, [name]) 里每个表面 set_surface_override_material；返回改了几个表面。
```

- `sport` 用项目清单里的 id（`skate`、`ski`、`basketball`、`golf`，新项目照各自清单），与 58-04 的配置文件名一致。
- 只读文件，不写 `user://`；不依赖 `game/scenes/` 下任何类（ARCH-CORE）。

## 依赖与顺序

只依赖 58-04 的目录约定（已写死），可与 58-04 同时做。58-06 依赖本卡。

## 验收

- `game/tests/outfit_cases.gd`：`path("ski", 5)` 等于 `.../outfits/ski/avatar1.gltf`；`path("x", -1)` 取 avatar3；用代码拼一个带两个命名材质的 `MeshInstance3D` 测 `slots` / `paint` 的返回；`roster()` 在文件缺失时返回空数组（测试里不依赖素材是否存在）。
- 命令：`python tools/test_game.py --godot <Godot>`（`RS_SHELL_TESTS: 0 failures`）；`python tools/check_conventions.py`。

## 不要做

- 不在本卡改任何项目的 rig。
- 不做运行时“身体 + 服装”拼装（58-04 已决定一个完整 glTF）。
- 不加 autoload。

## 预计规模

`outfit.gd` 约 60 行，测试约 50 行，ARCHITECTURE 1 行。
