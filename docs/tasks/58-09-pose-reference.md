# 58-09 关键姿态参考数据（MakeHuman Poses 02）

Issue #58 · P1 · D3 · 区域：素材（`game/assets/shared/characters/poses/`）+ 工具

## 目标 / 范围外

**目标**：把 MakeHuman 社区包 **Poses 02**（CC0）里的网球等姿态（`joachip_tennis_serve`、`punkduck_tennis_forehand_volley`、`punkduck_tennis_two-handed_backhand`、`punkduck_tennis_serve_wind-up` 等）转换成项目可读的“关键姿态”数据：每个姿态给出 `RSHumanRig.DRIVEN` 列出的 20 根骨骼在身体空间的旋转。各项目的 rig 子类可以拿它当程序姿态的目标或插值端点。

另外**只做评估、不入库**：Quaternius Universal Animation Library（CC0）能否重定向到 MPFB `game_engine` 骨架，结论写进 PR（能 / 不能、缺哪些骨骼、需要的工作量）。

**范围外**：在任何项目里使用这些姿态（各项目的事）；动画剪辑播放系统；Quaternius 动画入库。

## 先读

1. `game/core/human_rig.gd:1-30`（`DRIVEN` 骨骼表、身体空间约定：角色朝 −Z、骨架朝 +Z）、`:126` 起（`_fk` / `_limb` / `_apply_pose`，姿态怎么落到骨骼）
2. `tools/blender/make_skaters.py:1-30`（MPFB 环境、`game_engine` 骨架）
3. issue #58 正文 D3 一行、附录 A 的 MakeHuman / Quaternius 链接
4. [58-00 概览](58-00-overview.md)“素材卡通用规则”（Poses 02 ZIP 已在协调者本机，向协调者索取，用前核对 SHA-256）

## 改动文件

- 新建 `tools/blender/convert_poses.py`（Blender 无界面：给阵容 avatar0 套上 `.bvh` / `.mhpose` 姿态，读出 `DRIVEN` 骨骼的身体空间旋转）
- 新建 `game/assets/shared/characters/poses/poses.json` + `poses/CREDITS.md`
- `game/assets/shared/CREDITS.md` 总索引加 `characters/poses/` 一行
- 新建 `tools/tests/test_poses_json.py`（结构校验）

## 接口契约

`poses.json`（文本，体积可忽略）：

```json
{"version": 1, "skeleton": "mpfb_game_engine", "space": "body",
 "poses": {
   "tennis_serve": {"source": "joachip_tennis_serve",
                    "bones": {"pelvis": [x, y, z, w], "spine_01": [x, y, z, w], "...": "..."}}
 }}
```

- 键名去掉作者前缀，小写 `snake_case`（`tennis_serve`、`tennis_forehand_volley`、`tennis_backhand_2h`、`tennis_serve_windup`……）；`source` 保留原名便于追溯。
- 四元数是骨骼在**身体空间**的全局旋转，与 `RSHumanRig._rest` / `_pose` 同一空间（`human_rig.gd:18-21`），`bones` 必须恰好覆盖 `DRIVEN` 的 20 根骨骼。
- 读取方式（项目侧，不在本卡实现）：`JSON.parse_string(FileAccess.get_file_as_string("res://assets/shared/characters/poses/poses.json"))`。

## 依赖与顺序

不依赖 58-04 的输出也能做（用现有 `rider0` 的骨架即可，骨骼名相同）；58-04 合入后用阵容 avatar0 重新导出一次结果应一致。

## 验收

- `tools/tests/test_poses_json.py`：每个姿态的 `bones` 键集合等于 `DRIVEN`（测试里从 `human_rig.gd` 解析 `DRIVEN` 常量，避免两处手抄），四元数长度 ≈ 1。
- `python -m pytest -q tools/tests`；`python -m ruff check --config hub/pyproject.toml hub tools`。
- 素材记录：`poses/CREDITS.md` 写包页面、包 ZIP 的 SHA-256、每个姿态的原文件名、转换命令；许可 `CC0-1.0`；`docs/THIRD_PARTY.md` MakeHuman 一节补 Poses 02。
- PR 写 Quaternius 评估结论。

## 不要做

- 不提交 `.bvh` / `.mhpose` 原文件或 Quaternius 文件。
- 不改 `RSHumanRig`。

## 预计规模

转换脚本约 120 行，测试约 40 行，`poses.json` 几十 KB。
