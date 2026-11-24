# 53-01 人物的分屏档：降 LOD、细碎部件不投影、关 SSS

Issue #53 · 分项 1.3 · 区域：框架（`game/core/`）

## 目标 / 范围外

**目标**：低 / 中 / 高画质下，3–4 个视图同时在画时（`RSSettings.split_tier()` 为真且 `RSSettings.quality < 3`），每个 MakeHuman 角色：

- 所有网格 `lod_bias` 降到 `SPLIT_LOD_BIAS`（自己视图里的主角离相机近，仍用高 LOD；别人视图里的远处角色更早切到低 LOD）；
- 头发、眉毛、睫毛 `cast_shadow = OFF`（这些带 alpha-to-coverage 的薄片在每个视图 × 每个级联里都要画）；
- 皮肤 SSS 关闭。

极高画质（`quality == 3`）豁免上述人物降档：三 / 四人也保留 `lod_bias = 1.0`、原有投影及皮肤 SSS。回到 1–2 个视图或切到极高画质时全部恢复。分屏档 / 画质切换时已经建好的角色立即跟着变，之后新建的角色直接进入当前档。其他分屏规则（如太阳阴影）照旧。

**范围外**：粒子和名字标签（1.7 的其他卡）；服装 / 身体减面（#58 P1）；画质门控规则本身（PR #93 定，57-06 做刷新）；任何 `game/scenes/` 下的修改。

## 先读

1. [57-06](57-06-rig-quality-refresh.md)（“接口契约”：`RSSettings.QUALITY_GROUP`、`RSHumanRig.apply_quality()`。本卡直接扩展它，不新建第二套入口）
2. `game/core/human_rig.gd:31-35`（`set_layers`）、`:39-82`（`_load_character`，所有 `MeshInstance3D` 在这里设 `cast_shadow`）、`:90-123`（`_tune_material` / `_is_hair`）——以合入 #93、57-06 之后的 dev 为准
3. `game/core/settings.gd:238-247`（`apply_world`）、`:265-296`（`set_views`、`split_tier`、`sun_shadows` 的“原值存 metadata、重复应用不累积”写法）
4. `game/core/party_views.gd:24-30`（谁调用 `set_views`）
5. `game/tests/test_perf.gd:158-196`（缺角色模型时跳过的写法）、`:199` 起（`_split_shadow_tier`，测试分屏档切换的写法）

## 改动文件

- `game/core/human_rig.gd`（**框架区**）
- `game/core/settings.gd`（**框架区**，`set_views()` 里 1–3 行）
- `game/tests/test_perf.gd`（加一个检查函数，在 `_run()` 里调用）

## 接口契约

```gdscript
# game/core/human_rig.gd
const SPLIT_LOD_BIAS := 0.4      ## 分屏档的 GeometryInstance3D.lod_bias（默认 1.0）

func apply_quality() -> void
	## 57-06 已有：按画质重设皮肤 SSS、头发 A2C。本卡在同一函数里加分屏规则：
	##   - 人物降档条件：split = RSSettings.split_tier() and RSSettings.quality < 3
	##   - 全部网格 lod_bias = SPLIT_LOD_BIAS if split else 1.0
	##   - 头发 / 眉毛 / 睫毛 cast_shadow = OFF if split else ON
	##   - 皮肤 subsurf_scatter_enabled = (57-06 / #93 的画质条件) and not split
	## 幂等；构建时（_load_character 末尾）也调用一次，所以新建角色直接进入当前档。

func shadow_casters() -> int
	## 本角色当前 cast_shadow != OFF 的 MeshInstance3D 数量（测试和 PR 里的前后对比用）。
```

- `RSSettings.set_views(n, root)`：分屏档变化、`root` 有效时，现在只重设太阳。改为调用 `apply_world(root)`（它会重设太阳并刷新 `QUALITY_GROUP`，两者都幂等）；或者在重设太阳的循环后加同样的组刷新——二选一，以改动最少为准。
- 部件判定沿用 `_tune_material` 里的名字规则：`eyebrow`、`eyelash`、`_is_hair()` 为细碎部件；名字含 `body` 的材质是皮肤。细碎部件的 `MeshInstance3D` 在构建时记下来（照 57-06 记 `_quality_materials` 的方式），不要每次重新遍历名字。
- 材质注意：同一个角色文件的多个实例共享材质资源，SSS 改的是共享材质，必须全局一致——分屏档本来就是全局的。

## 依赖与顺序

- **硬依赖 PR #93 和 57-06**：两者都改 `_tune_material` / `human_rig.gd`，并提供本卡要扩展的 `apply_quality()`。57-06 合入前不要开工。
- 与 53-02 ~ 53-06 无文件冲突，可以并行。

## 验收

- `game/tests/test_perf.gd` 新增 `_rig_view_tier()`：
  - 角色模型不存在时打印 `RS_PERF_SKIP: ...` 并返回（判断照 `_riders_at_30fps()`）；
  - 建一个 `RSHumanRig.new()` 加进树，`_load_character(RSSkaterRig.RIDERS[1])`；
  - 低 / 中 / 高画质下 `RSSettings.set_views(4, self)` 后：全部网格 `lod_bias == SPLIT_LOD_BIAS`、细碎部件不投影、皮肤 SSS 关；
  - `set_views(1, self)` 后恢复（SSS 按当前画质）；`set_views(4)` 后新建第二个角色，直接是分屏档；
  - 极高画质下三 / 四人均不降低人物细节，切换高→极高→高时已有角色立即恢复 / 降档，新建的极高角色也保留原 LOD、投影和 SSS；
  - 打印 `RS_PERF_RIG: shadow casters per rig <1 视图> -> <4 视图>, lod_bias 1.00 -> 0.40`；测试结束恢复 `set_views(1, null)`。
- 命令：`python tools/test_perf.py --godot <Godot>`（PR 里贴上面那行输出）；`python tools/test_game.py --godot <Godot>`（57-06 的用例不回退）；`python tools/check_conventions.py`；`python tools/smoke_game.py <Godot> --project game`。
- PR 里写清：真实帧率未测；4 人画面变化（远处人物细节、头发影子、皮肤质感）留给最终试玩。

## 不要做

- 不改 `game/scenes/*/..._rig.gd`，不改各项目调 `set_layers()` 的地方。
- 不用 `visibility_range` 隐藏远处人物（回放 / 领奖台会出问题）。
- 不每帧轮询 `split_tier()`。
- 不改 1–2 个视图时的任何材质值，不改 #93 的画质条件。

## 预计规模

`human_rig.gd` 约 +30 行，`settings.gd` 1–3 行，`test_perf.gd` 约 +50 行。
