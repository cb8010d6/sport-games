# 57-05 低画质关闭点光 / 聚光阴影

Issue #57 正文第 5 条（PR #93 未含的部分）· 区域：框架（`game/core/settings.gd`）

> 开工前提：维护者确认观感规则（下面“接口契约”里的表）。PR #93 的说明写过“低档关闭聚光阴影观感变化大，建议维护者单独拍板”。

## 目标 / 范围外

**目标：** 和太阳阴影（`RSSettings.sun_shadows`）一样，给点光和聚光的阴影一个统一的画质门控：场景作者设的 `shadow_enabled` 记成元数据，按画质档位和分屏数决定实际是否投影；菜单改画质、切地图、分屏人数跨档时都重新应用。篮球夜图那 8 盏带阴影的聚光灯（`court.gd` 772 行附近）不用改代码就受控。新场馆灯架（39-16）也用这个接口。

**范围外：** 阴影图集大小（PR #93 已按档位设置）；太阳阴影；灯的数量和亮度；各项目的灯光布置。

## 先读

1. `game/core/settings.gd` 207-247（`apply`、`apply_world`）、263-297（`set_views`、`split_tier`、`sun_shadows`：元数据保存场景原值的写法）
2. PR #93 对 `settings.gd` 的改动（`positional_shadow_atlas_size` 按档位）
3. `game/scenes/basketball/court.gd` 755-778（带阴影的聚光灯怎么建的）
4. `game/core/party_views.gd` 28-30（`set_views` 何时调用）
5. `game/tests/test_shell.gd` 中 PR #93 加的画质探针用例（同类测试照着写）

## 改动文件

- `game/core/settings.gd` —— 框架区（约 +20 行）
- `game/tests/test_shell.gd`：追加探针用例（或放进新的 `game/tests/settings_cases.gd` 再注册，二选一）
- `docs/ARCHITECTURE.md` 第 3 节“画面设置”一行加上 `local_shadows(light)` —— 框架区

## 接口契约

```gdscript
# game/core/settings.gd
## 点光 / 聚光的阴影画质门控。第一次调用时把场景设的 shadow_enabled 存为元数据 "shadow_enabled"，
## 之后按下表决定实际值；场景原来就不投影的灯永远不投影。
static func local_shadows(light: Light3D) -> void
```

| 画质 `quality` | 1–2 个视口 | 3–4 个视口（`split_tier()`） |
|---|---|---|
| 0 低 | 关 | 关 |
| 1 中 | 按场景原值 | 关 |
| 2 高 / 3 极高 | 按场景原值 | 按场景原值 |

（这是提案，维护者可以改表，改表只动一个判断。）

接线：

- `apply_world(root)`：除了现有的环境和太阳，再对 `root` 下所有 `OmniLight3D`、`SpotLight3D` 调用 `local_shadows`。
- `set_views(n, root)`：跨分屏档时，除了太阳，也对局部光源重新应用。
- `DirectionalLight3D` 不走这个函数（它有 `sun_shadows`）。

## 依赖与顺序

需要维护者先确认表格。依赖 PR #93（同一文件的画质逻辑，避免冲突）。39-16 会调用 `local_shadows`，两者合并顺序任意。

## 验收

- 测试用例（不渲染）：建一个 `SpotLight3D`（`shadow_enabled = true`）和一个 `OmniLight3D`（`false`），放进一个节点：
  - `quality = 0` → `apply_world` 后两者都不投影；`quality = 2` → 聚光投影、点光不投影
  - `quality = 1` 且 `set_views(4, root)` → 聚光不投影；`set_views(2, root)` → 恢复投影
  - 反复调用不改变元数据里的原值
  - 测试结束恢复 `RSSettings.quality` 和 `views` 原值
- 命令：`python tools/test_game.py --godot <Godot>`（`RS_SHELL_TESTS: 0 failures`），`python tools/smoke_game.py <Godot> --project game`，`python tools/check_conventions.py`
- 篮球夜图的观感和帧时间由维护者在 4 分屏下试玩确认（不在本卡做基准）。

## 不要做

- 不改 `court.gd` 或其他项目的灯光代码。
- 不改阴影图集大小（#93 已做）。
- 不保存新的设置项（档位规则写死在代码里）。

## 预计规模

`settings.gd` 约 +20，测试约 40 行，文档 1 行。
