# 58-11 ambientCG 材质：铁丝网、球网、绳、泡沫、胶皮

Issue #58 · P2 / P4 / P5 · A6、B4、B6、C5、B1 · 区域：素材（`game/assets/shared/materials/`）

## 目标 / 范围外

**目标**：用 58-03 的打包脚本，把 5 组 ambientCG（CC0）材质加工成 `RSPbr` 可直接读取的成品，一次交付给多个使用者：

| `RSPbr` id | ambientCG 资产 | 分辨率 | diff 格式 | 使用者 |
|---|---|---|---|---|
| `shared:acg_fence006` | Fence006 | 1k | PNG（带 alpha） | 39-15 远处铁丝网（`FenceStyle.CHAINLINK`） |
| `shared:acg_net004a` | Net004A | 1k | PNG（带 alpha） | 58-21 `RSNet` 网面 |
| `shared:acg_rope001` | Rope001 | 1k | JPG | 58-21 网带、58-22 拳台围绳 |
| `shared:acg_foam002` | Foam002 | 2k | PNG（opacity 进 alpha） | 39-11 `RSWaterSurface` 泡沫 |
| `shared:acg_rubber004` | Rubber004（领卡时在 Rubber001–004 里挑最像乒乓球拍胶皮的一组；换了编号就同步改 id 和 58-00 / 58-19） | 1k | JPG | 58-19 乒乓球拍 |

**范围外**：AcousticFoam、Carpet 等可选材质；任何代码；Poly Haven 材质（58-15）。

## 先读

1. [58-03](58-03-cc0-material-pack.md) 的命令行和输出约定
2. `game/core/pbr.gd:20-55`（`folder` / `map_path` / `maps`：`shared:` 根目录和 PNG diff 的读取顺序）
3. `game/assets/shared/materials/CREDITS.md`（要填的表）
4. `docs/THIRD_PARTY.md:19-33`（Poly Haven 一节的写法，ambientCG 照此加一节）
5. [58-00 概览](58-00-overview.md)“素材卡通用规则”和“需要维护者决定的”第 6 条（泡沫路径）

## 改动文件

- 新增 `game/assets/shared/materials/acg_<id>/acg_<id>_{diff,nor_gl,arm}_<res>.(jpg|png)` + `.import`（5 个目录）
- `game/assets/shared/materials/CREDITS.md`（每个文件一行）、`game/assets/shared/CREDITS.md`（文件数）
- `docs/THIRD_PARTY.md` 新增 “ambientCG” 一节（许可页 <https://docs.ambientcg.com/license/>）
- `docs/ASSET_MANIFEST.json`（重新生成）

## 接口契约

- 文件名和目录严格按 `RSPbr` 规则：`res://assets/shared/materials/acg_foam002/acg_foam002_diff_2k.png` 等。39-11 现在写的 `FOAM_TEXTURE` 路径（`.../foam_color.png`）与此不同，**以本卡为准**，由 39-11 调整（已在 58-00 列为待维护者确认）；本卡不另放一份 `foam_color.png`。
- 带 alpha 的 diff 必须是 PNG（`RSPbr.maps` 先找 JPG 再找 PNG，同目录不能同时有两种）。
- 导入设置按 `docs/ASSETS.md` 导入表（diff / arm 显存压缩，法线 `normal_map=1`），用 `python tools/texture_imports.py --check` 验证（53-05）。

## 依赖与顺序

依赖 58-03（脚本）。53-05 合入后必须过 `--check`。58-19、58-21、58-22、39-11 用本卡的成品；它们都能先用占位合入。

## 验收

- `python tools/test_assets.py --godot <Godot>`：在 `game/tests/test_assets.gd` 的 `_pbr_paths()` 里追加——5 个 id 各自 `RSPbr.maps(id)` 三张都非空（稀疏检出时跳过，照现有 `RS_SPARSE_ASSETS` 写法）。
- `python -m pytest -q tools/tests`（CREDITS、单文件 ≤ 20 MiB、导入设置）；`node --test tools/tests/asset_sync.test.mjs`（策略规则未被遮住）。
- PR 里列：每组成品字节数和合计（预算参考：每组约 3–6 MB，合计 ≤ 25 MiB），原始 ZIP 名与 SHA-256。
- 素材记录：CREDITS 每个文件写 ambientCG 页面（`https://ambientcg.com/view?id=<资产>`）、作者 ambientCG / Lennart Demes、许可 `CC0-1.0`、下载日期、原始 ZIP 文件名与 SHA-256、58-03 打印的命令。Foam002 的 ZIP 已在协调者本机（58-00），用前核对 SHA-256 与原页面。

## 不要做

- 不提交 ZIP、Displacement、NormalDX、预览图。
- 不改 `RSPbr`。
- 不给素材起不带 `acg_` 前缀的名字。

## 预计规模

素材约 15–25 MiB；文档约 30 行。
