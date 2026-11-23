# 58-24 水上摩托模型

Issue #58 · P5 · B7 · 区域：素材（`game/assets/shared/equipment/`）+ 工具（`make_equipment.py` 加函数）

**开工前提**：水上摩托项目（#61）已经用白模试玩定下尺寸、座位、把手和骑手挂点（issue #58 P5：“先白模试玩确定尺寸，再出成品”）。白模的尺寸数据写进 #61 之前不要开工。这是最高风险的自建件。

## 目标 / 范围外

**目标**：按 #61 白模定下的尺寸，程序化建模水上摩托成品：船体、座椅、把手、发动机盖、脚踏槽；船壳漆面 + 玩家色条纹，座椅用 Poly Haven `scuba_suede` 法线，金属件 `metal_plate`；自动 LOD。另做比赛用的两色充气转向浮标（58-23 未包含）。

**范围外**：浮力、操控、尾迹（#61、39-12）；骑手服装（58-08）；骑手姿态（#61）；真实品牌外形或字样。

## 先读

1. #61 里白模尺寸的那条评论（`gh issue view 61 --comments`）——没有就停
2. `tools/blender/make_equipment.py`（58-19 的注册表、导出、`MIT AND CC0-1.0` 规则）
3. issue #58 正文 B7、B8 两行（LOD0 ≤ 15k 三角、自动 LOD、条纹玩家色）
4. [58-02](58-02-polyhaven-lock-tool.md)（`scuba_suede` 先锁定）
5. [58-00 概览](58-00-overview.md)“素材卡通用规则”

## 改动文件

- `tools/blender/make_equipment.py`（加 `jetski`、`buoy_turn`）
- `tools/assets.lock.json` + `polyhaven/CREDITS.md`：`scuba_suede` 2K
- 新增 `game/assets/shared/equipment/jetski/eq_jetski.gltf|.bin` + 贴图 + `eq_jetski.json`、`buoy_turn/eq_buoy_turn.gltf|.bin`
- `game/assets/shared/equipment/CREDITS.md`、`game/assets/shared/CREDITS.md`

## 接口契约

- 原点：船体静水吃水线中心；前进方向 −Z（与 `RSHumanRig` 身体空间“角色朝 −Z”一致，骑手直接放进去不用转）；单位米。
- 材质名：`hull`（漆面，项目可整体改色）、`stripe`（玩家色）、`seat`、`metal`、`rubber`。
- `eq_jetski.json`：`{"version": 1, "seat": [x, y, z], "handles": [[lx, ly, lz], [rx, ry, rz]], "feet": [[...], [...]], "length": L, "beam": B, "draft": D, "float_points": [[x, z], ...]}`——骑手挂点和项目做浮力采样用的点，数值来自 #61 白模。
- 三角面：LOD0 ≤ 15k；glTF 导入设置 `meshes/generate_lods=true`（Godot 自动 LOD，不手做 LOD 网格）。
- `buoy_turn`：充气转向浮标，两色（橙 / 白），不用玩家色，原点在吃水线。

## 依赖与顺序

依赖 #61 白模尺寸（维护者 / #61 负责人提供）、58-19、58-02。

## 验收

- `game/tests/test_assets.gd` 追加（稀疏检出跳过）：glTF 能加载；LOD0 三角面 ≤ 15000；材质名齐全；`eq_jetski.json` 字段齐全且挂点在包围盒内。
- `python tools/test_assets.py --godot <Godot>`；`python tools/texture_imports.py --check`；`python -m pytest -q tools/tests`；`node tools/sync_assets.mjs --check`。
- PR 里列三角面、新增 Git 字节（≤ 10 MiB）、同步字节（约 12 MiB）。
- 素材记录：CREDITS 写输入（`scuba_suede`、`metal_plate`）、Blender 版本、命令；许可 `MIT AND CC0-1.0`。

## 不要做

- 不仿任何真实水上摩托品牌的外形特征、配色或字样。
- 不在游戏里接入。

## 预计规模

脚本 +250 行；素材约 5–10 MiB。
