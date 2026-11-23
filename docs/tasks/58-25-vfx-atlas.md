# 58-25 Kenney 粒子贴图 → 2K 共享图集

Issue #58 · P6 · E1 · 区域：素材（`game/assets/shared/vfx/`）+ 工具（`tools/blender/`）

## 目标 / 范围外

**目标**：从 Kenney **Particle Pack**（CC0，80 张 512²）和 **Smoke Particles**（CC0，70 张）里挑 16 张，打成一张 2048² 的 4 × 4 图集，供 58-26 `RSVfx` 的粒子预设（水花、尘土、闪光、冲击）和 39-12 浪花共用。附一个 JSON 写明每格的名字。

**范围外**：粒子预设代码（58-26）；拖尾（58-27）；泡沫材质（58-11）。

## 先读

1. issue #58 正文 E1–E5 几行（每种特效要什么样的贴图）和附录 A 的 Kenney 链接
2. `tools/blender/bake_impostor.py:1-20`（Blender 无界面图像输出脚本的写法）
3. `game/assets/shared/vfx/CREDITS.md`（模板）
4. `docs/THIRD_PARTY.md:19-33`（Poly Haven 一节的写法，Kenney 照此加一节）
5. [58-00 概览](58-00-overview.md)“素材卡通用规则”

## 改动文件

- 新建 `tools/blender/pack_atlas.py`（读 N 张 PNG，缩放到格子大小，按网格拼成一张 RGBA PNG，写 JSON）
- 新增 `game/assets/shared/vfx/vfx_particles.png` + `.import`、`vfx_particles.json`
- `game/assets/shared/vfx/CREDITS.md`、`game/assets/shared/CREDITS.md`
- `docs/THIRD_PARTY.md` 新增 “Kenney” 一节（许可页 <https://kenney.nl/assets/particle-pack>、<https://kenney.nl/assets/smoke-particles>，CC0）
- `docs/ASSET_MANIFEST.json`（重新生成）

## 接口契约

```
blender --background --factory-startup --python tools/blender/pack_atlas.py -- <out.png> <grid> <name=src.png> ...
```

`vfx_particles.json`：

```json
{"version": 1, "grid": 4, "cell_px": 512,
 "frames": {"spark": 0, "star": 1, "circle_soft": 2, "ring": 3,
            "smoke_soft": 4, "smoke_puff": 5, "dust": 6, "splash_drop": 7,
            "splash_sheet": 8, "foam_bits": 9, "flare": 10, "confetti": 11,
            "streak": 12, "impact_burst": 13, "glow": 14, "twirl": 15}}
```

- 格子编号从左上角开始按行；名字就是 58-26 引用的键（写死），挑哪张 Kenney 原图由领卡人决定，但每个名字的用途要符合字面意思。
- 贴图是白色 / 灰度 + alpha（颜色由粒子着色），PNG RGBA 8 位；导入按 `docs/ASSETS.md` 颜色纹理设置（显存压缩、mipmap）。
- Godot 用法：`ParticleProcessMaterial` + `StandardMaterial3D.particles_anim_h_frames = 4`、`v_frames = 4`，按帧号选格。

## 依赖与顺序

无依赖。58-26 依赖本卡的 JSON 键名（已写死，可同时做）。

## 验收

- `game/tests/test_assets.gd` 追加（稀疏检出跳过）：图集 2048²；JSON 的 16 个键齐全、帧号 0–15 不重复。
- `python tools/test_assets.py --godot <Godot>`；`python tools/texture_imports.py --check`；`python -m pytest -q tools/tests`。
- 素材记录：CREDITS 写每个格子的原图文件名、所属包、包 ZIP 的 SHA-256、下载日期、Kenney 页面、作者 Kenney、许可 `CC0-1.0`、打包命令。Kenney 页面下载不需要登录（如果遇到要求登录或付款的页面，停下来报告，不要操作）。
- PR 里列图集字节（目标 ≤ 4 MiB）。

## 不要做

- 不提交 Kenney 原 ZIP 或未使用的图。
- 不做彩色烘焙（颜色交给粒子）。

## 预计规模

打包脚本约 80 行；素材 2–4 MiB。
