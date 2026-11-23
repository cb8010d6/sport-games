# 57-06 改画质后已建人物材质跟着更新

Issue #57 正文第 5 条（PR #93 留下的局限）· 区域：框架（`game/core/human_rig.gd`、`game/core/settings.gd`）

## 目标 / 范围外

**目标：** PR #93 让人物皮肤 SSS 只在高档以上开、头发 alpha-to-coverage 只在 MSAA 生效时开，但这是在人物构建时一次性设置的：比赛中从暂停菜单改画质，已经在场上的人物不变。本卡加一个通用的“画质监听”约定：需要随画质更新的节点加入 `RSSettings.QUALITY_GROUP` 组并实现 `apply_quality()`，`RSSettings.apply_world(root)` 统一调用。`RSHumanRig` 第一个接入。

**范围外：** 新的画质开关；其他材质（地面、道具）的画质门控；`RSWaterSurface`（39-11 合入后可以照此接入，单独做）。

## 先读

1. PR #93 对 `game/core/human_rig.gd` 的改动（`_tune_material()` 里 SSS / alpha-to-coverage 的门控条件）
2. `game/core/human_rig.gd` 60-75（构建时遍历网格材质）、90-115（`_tune_material`）
3. `game/core/settings.gd` 207-247（`apply` 末尾调用 `apply_world`；`apply_world` 的写法）
4. `game/core/pause_menu.gd` 275-285（暂停菜单改设置后调用 `RSSettings.apply`）
5. PR #93 在 `game/tests/test_shell.gd` 里加的“探针材质 SSS / A2C 随档位开关”用例

## 改动文件

- `game/core/settings.gd` —— 框架区（约 +6 行）
- `game/core/human_rig.gd` —— 框架区（约 +20 行）
- `game/tests/test_shell.gd`：在 #93 的探针用例旁追加
- `docs/ARCHITECTURE.md` 第 3 节“画面设置”一行补一句 `QUALITY_GROUP` 约定 —— 框架区

## 接口契约

```gdscript
# game/core/settings.gd
const QUALITY_GROUP := &"rs_quality"
## apply_world(root) 末尾新增：对 root 子树里属于 QUALITY_GROUP 的节点调用 apply_quality()。
## 约定：组内节点必须实现 func apply_quality() -> void，只读 RSSettings 的静态变量，不保存设置。

# game/core/human_rig.gd
## 构建时把需要画质门控的材质（皮肤、头发 / 眉毛 / 睫毛）记进 _quality_materials，并 add_to_group(RSSettings.QUALITY_GROUP)。
## apply_quality() 按 #93 的同一条件重新设置这些材质的 SSS 和 alpha-to-coverage；_tune_material 改为调用同一个判断函数，
## 保证构建时和刷新时规则一致。
func apply_quality() -> void
```

注意：glTF 导入的材质在同一角色文件的多个实例之间是共享资源，刷新一个人物会影响同款人物，这与构建时的行为一致（构建时也是改共享材质）。

## 依赖与顺序

依赖 PR #93。与 57-05 都改 `settings.gd`，位置不同（`apply_world` 末尾 vs 新函数），可以并行，合并时保留双方。

## 验收

- `test_shell.gd` 追加：建一个探针 `RSHumanRig`（或照 #93 用例的探针材质方式），`quality = 3` 时 SSS 开；改 `quality = 0` 后调用 `RSSettings.apply_world(root)` → SSS 关、alpha-to-coverage 按 MSAA 规则变化；再改回 3 → 恢复。测试结束恢复 `RSSettings.quality`。
- 不在组里的节点不受影响；组里节点缺 `apply_quality` 方法时 `push_warning` 一次、不崩溃。
- 命令：`python tools/test_game.py --godot <Godot>`（`RS_SHELL_TESTS: 0 failures`），`python tools/smoke_game.py <Godot> --project game`，`python tools/check_conventions.py`

## 不要做

- 不改 #93 定下的门控条件本身。
- 不每帧检查画质（只在 `apply_world` 时刷新）。
- 不新增 autoload 或信号总线。

## 预计规模

`settings.gd` 约 +6，`human_rig.gd` 约 +20，测试约 30 行，文档 1 句。
