# 58-15 地表材质：红土、木地板、沙、地胶

Issue #58 · P3 · C1–C4、C6 · 区域：素材（Poly Haven 锁定清单）

## 目标 / 范围外

**目标**：把新项目场地需要、仓库里还没有的 Poly Haven 扫描材质（2K）加进锁定清单，之后各项目和 39-18 `RSArenaHall.Preset.floor_id` 直接写 `RSPbr` id 使用。

| `RSPbr` id | 编号 | 用途 | 2K 体积 | 批次 |
|---|---|---|---:|---|
| `red_sand` | C2 | 网球红土 | 9.2 MiB | 首批 |
| `wood_floor` | C3 | 球馆 / 乒乓训练馆木地板 | 6.5 MiB | 首批 |
| `rectangular_parquet` | C3 | 比赛场馆拼花地板（第二种木地板） | 6.1 MiB | 首批 |
| `sand_01` | C4 | 沙排场内细沙 | 4.7 MiB | 首批 |
| `damp_beach_sand` | C4 | 湿沙岸线（与 39-11 的岸线距离混合） | 9.6 MiB | 首批 |
| `rubber_tiles` | C6 | 运动地胶（拳击馆、比赛场馆） | 6.7 MiB | 首批 |
| `asphalt_track` | C1 | 硬地网球场底材（可选；也可继续用已有 `clean_asphalt`） | 9.5 MiB | 可选 |

首批约 43 MiB（同步下载，不进 Git）。器材用的皮革 / 毛毡在 58-19 / 58-20，布料细节法线不在本 issue 首批。

**范围外**：场线（58-18）；脚印 / 凹陷着色器（各项目）；HDRI（58-16）；任何场景使用。

## 先读

1. [58-02](58-02-polyhaven-lock-tool.md) 的命令行
2. `game/core/pbr.gd:38-88`（`maps` 选最高分辨率；`surface` 用于大面积、`standard` 用于小件）
3. `docs/ASSETS.md:131-143`（每个新项目预算：≤ 12 组 2K、≤ 2 组 4K 主表面）
4. `docs/ASSETS.md:159-169`（“暂未使用的素材”表，加完后如果仍无人使用要登记在这里）
5. [58-00 概览](58-00-overview.md)“素材卡通用规则”

## 改动文件

- `tools/assets.lock.json`（`node tools/lock_polyhaven.mjs add --kind textures --res 2k --purpose "#58 C2 网球红土" red_sand` 等，每组一条 `purpose`）
- `game/assets/polyhaven/textures/<id>/*.jpg.import`（Godot 导入后生成，进 Git；`.jpg` 本身不进 Git）
- `game/assets/polyhaven/CREDITS.md`（工具追加）
- `docs/ASSETS.md`：总组数 / 文件数 / 字节数；“暂未使用的 Poly Haven 素材”表追加本卡全部 id 和计划用途（项目还没接入）

## 接口契约

- `RSPbr` id 就是上表第一列（Poly Haven 资产 id），写死。
- 文件名由工具决定：`textures/<id>/<id>_{diff,nor_gl,arm}_2k.jpg`，`RSPbr.maps(id)` 直接可读。
- 导入设置照现有 Poly Haven 纹理（Godot 默认 + 显存压缩），法线 `normal_map=1`。53-05 的检查默认不管 `polyhaven/`，PR 里抽查 1 个 `.import` 与现有 `clean_asphalt` 的设置一致即可。

## 依赖与顺序

依赖 58-02。与 58-16、58-10 可并行（都改锁定清单，追加在末尾；后合入的一方合并 dev 解决冲突即可，条目互不重叠）。

## 验收

- `node tools/sync_assets.mjs --check`；`node --test tools/tests/asset_sync.test.mjs`。
- `game/tests/test_assets.gd` 的 `_pbr_paths()` 把检查列表 `["clean_asphalt", "snow_02"]` 扩成也包含本卡 id（已同步才检查，现有写法）；`python tools/test_assets.py --godot <Godot>`。
- PR 里贴 `RS_LOCK_ADDED` 输出和 `docs/ASSETS.md` 改后的总数。
- 素材记录：锁定清单 `purpose` 字段、`polyhaven/CREDITS.md` 每组一行（作者见 issue #58 附录 A）。

## 不要做

- 不手写哈希；不提交 `.jpg`。
- 不下 4K（需要 4K 主表面时由项目 PR 说明理由后再加）。
- 不在任何场景里使用（避免和项目卡冲突）。

## 预计规模

锁定清单约 +18–21 条；Git 只增 `.import` 文本；同步下载约 43 MiB（含可选约 52 MiB）。
