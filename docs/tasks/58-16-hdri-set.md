# 58-16 HDRI：室外 puresky、海滩、湖 / 海湾、室内 2K

Issue #58 · P3 · C7（素材部分）· 区域：素材（Poly Haven 锁定清单）

## 目标 / 范围外

**目标**：按“时段 × 场景”补齐新项目要用的 HDRI，加进锁定清单。室外可见天空用 4K，室内只做反射 / 环境光用 2K（`docs/ASSETS.md` 导入设置表）。

| 预设用途 | Poly Haven id | 分辨率 | 体积 | 首个使用者 |
|---|---|---|---:|---|
| 室内：乒乓训练馆反射 | `squash_court` | 2k | 6.2 MiB | 乒乓球 #60 |
| 室内：比赛场馆反射 | `empty_play_room` | 2k | 6.2 MiB | 乒乓球 #60 |
| 室内：拳击馆反射 | `basement_boxing_ring` | 2k | 5.7 MiB | 拳击 |
| 白天 puresky | `syferfontein_18d_clear_puresky` | 4k | 15.1 MiB | 网球、射箭 |
| 黄金时段 puresky | `rosendal_park_sunset_puresky` | 4k | 19.5 MiB | 网球红土 |
| 海湾 | `blue_lagoon` | 4k | 22.6 MiB | 水上摩托 |
| 湖泊清晨 | `lakeside_sunrise` | 4k | 23.6 MiB | 水上摩托 |
| 海滩白天 | `spiaggia_di_mondello` | 4k | 23.8 MiB | 沙排 |
| 海滩夜场 | `sandsloot` | 4k | 25.7 MiB | 沙排夜场 |

合计约 148 MiB（同步下载，不进 Git），按首个使用者分摊都在每项目 ≤ 120 MiB 以内。`netball_court`、`stadium_01`、`secluded_beach`、`lakeside`、`small_harbour_sunset`、`school_hall`、`wrestling_gym` 不在本卡，项目需要时再加。

**范围外**：天空 / 太阳 / 雾的预设参数和构建代码（58-17）；已有 8 张 HDRI 的改动；任何场景使用。

## 先读

1. [58-02](58-02-polyhaven-lock-tool.md) 的命令行
2. `game/scenes/ski/ski_maps.gd:10-60`（现有地图怎么引用 HDRI：完整 `res://` 路径）
3. `game/scenes/ski/ski_course.gd:1123-1180`（`setup_environment`：HDRI → `PanoramaSkyMaterial` 的现成写法）
4. [39-18](39-18-arena-hall.md) 的 `RSArenaHall.Preset.hdri` 字段（室内 HDRI 填这里）
5. [58-00 概览](58-00-overview.md)“素材卡通用规则”

## 改动文件

- `tools/assets.lock.json`（`node tools/lock_polyhaven.mjs add --kind hdris --res 2k --purpose "…" squash_court empty_play_room basement_boxing_ring`；4K 一组同理）
- `game/assets/polyhaven/hdris/<id>/<id>_<res>.hdr.import`（Godot 导入生成，进 Git；`.hdr` 不进 Git）
- `game/assets/polyhaven/CREDITS.md`（工具追加）
- `docs/ASSETS.md`：总数；“暂未使用的 Poly Haven 素材”表登记本卡 id 和计划用途

## 接口契约

- 路径固定为 `res://assets/polyhaven/hdris/<id>/<id>_<res>.hdr`（与现有 8 张一致）。58-17 的 `RSSkyPresets` 按这个规则写死路径；39-18 的室内预设填这里的 2K 路径。
- `.hdr.import` 的 `hdr_compression` 等参数照现有 HDRI（例如 `kloppenheim_06_puresky_4k.hdr.import`）。
- 有地面景物的 HDRI（`blue_lagoon`、`spiaggia_di_mondello`、`sandsloot`、`lakeside_sunrise`）只作远景 / 反射，近处必须是项目自己的几何——写进 `purpose`。

## 依赖与顺序

依赖 58-02。58-17 只依赖上面的路径规则，可以同时做。

## 验收

- `node tools/sync_assets.mjs --check`；`node --test tools/tests/asset_sync.test.mjs`；`python tools/import_game.py --godot <Godot>` 无报错。
- `game/tests/test_assets.gd` 追加：本卡每张 HDRI 已同步时 `load()` 得到 `Texture2D`（未同步跳过）。`python tools/test_assets.py --godot <Godot>`。
- PR 里贴 `RS_LOCK_ADDED` 输出、每个首个使用者分摊的字节数。
- 素材记录：`purpose`、`polyhaven/CREDITS.md`（作者见 issue #58 附录 A）。

## 不要做

- 不下 8K；室内不下 4K。
- 不改现有地图的 HDRI。

## 预计规模

锁定清单 +9 条；Git 只增 9 个 `.import`；同步下载约 148 MiB。
