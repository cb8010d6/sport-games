# 58-08 拳击 / 水上摩托服装、裁判 NPC

Issue #58 · P1 · D2、D4 · 区域：素材（`game/assets/shared/characters/`）+ 工具配置

## 目标 / 范围外

**目标**：

| sport id | 服装 | 可重染材质 |
|---|---|---|
| `boxing` | 赤膊（男）/ 运动背心（女）+ 拳击短裤，拳击鞋（沿用运动鞋）；手套不在本卡（58-22，项目运行时挂到手骨） | `pants`（短裤）；女式背心 `jacket` |
| `jetski` | 防寒衣（全身紧身）+ 救生衣 | `jacket`（防寒衣上身）、`pants`（下身）；救生衣固定橙 / 黄，不重染 |
| NPC `referee` | 阵容外的 1–2 个身体 + 黑白制服 | 无（NPC 不用玩家色） |

**范围外**：拳套、拳台（58-22）；水上摩托模型（58-24）；网球司线等更多 NPC（等对应项目需要再加）；游戏代码。

## 先读

1. [58-04](58-04-character-generator.md) 的“接口契约”
2. `tools/blender/make_ballers.py:40-88`（裁短裤、露出皮肤的做法；拳击短裤沿用）
3. `tools/blender/make_skiers.py:37-98`（`split_clothes`：按 UV 岛拆上下身，防寒衣沿用）
4. issue #58 正文 D2、D4 两行（救生衣用 Poly Haven `life_jacket`；防寒衣布料参考 `scuba_suede`）
5. [58-02](58-02-polyhaven-lock-tool.md)（`life_jacket` 模型要先进锁定清单）
6. [58-00 概览](58-00-overview.md)“素材卡通用规则”

## 改动文件

- 新建 `tools/blender/characters/boxing.json`、`jetski.json`、`referee.json`
- `game/assets/shared/characters/roster/roster.json`：**追加** NPC 身体到单独的 `"npcs"` 数组（不改 `"avatars"`）
- `tools/blender/make_character.py`：新 op `attach_model:<polyhaven id>:<bone>`（把一个 glTF 模型按骨骼绑定到角色上，用于救生衣）；`tools/character_config.py` 合法取值同步
- `tools/assets.lock.json`、`game/assets/polyhaven/models/life_jacket/*.gltf(.import)`、`polyhaven/CREDITS.md`（用 `node tools/lock_polyhaven.mjs add --kind models --res 2k life_jacket`）
- 新增 `game/assets/shared/characters/outfits/{boxing,jetski}/avatar{0..3}.gltf|.bin`、`outfits/npc/referee{0,1}.gltf|.bin`、新增 `textures/*.png`；对应 CREDITS

## 接口契约

- 选手路径：`RSOutfit.path("boxing" | "jetski", avatar)`。NPC 路径：`res://assets/shared/characters/outfits/npc/referee<N>.gltf`（58-05 的 `RSOutfit` 暂不提供 NPC 函数，项目直接用这个路径常量；以后 NPC 多了再加）。
- `roster.json` 新字段：`"npcs": [{"id": "referee0", ...与 avatars 相同字段}]`；`tools/character_config.py` 校验它，id 唯一。
- 救生衣：加工后的网格并入角色 glTF（不单独成文件），Poly Haven 原模型的 `.bin` / 纹理仍由同步脚本下载、不进 Git；被并入角色的那份几何是加工件，随角色 glTF 进 Git，CREDITS 写明来源 `life_jacket`（PierreB3D）。
- 拳击赤膊：身体皮肤完整可见，`body` 材质按 `RSHumanRig._tune_material` 的命名规则（名字含 `body`）保持，SSS 等由框架处理。

## 依赖与顺序

依赖 58-04、58-02。与 58-07 可并行（注意共享 `textures/` 同名同内容）。

## 验收

- `python tools/character_config.py --check`；`python -m pytest -q tools/tests`；`python tools/texture_imports.py --check`；`node --test tools/tests/asset_sync.test.mjs`；`node tools/sync_assets.mjs --check`。
- `python tools/import_game.py --godot <Godot>` 无报错；`game/tests/outfit_cases.gd` 追加路径存在检查（稀疏检出跳过）。
- PR 里列：三角面数（选手 ≤ 30k、NPC 同）、新增纹理与字节数、Poly Haven 新增下载字节（`RS_LOCK_ADDED` 输出）。
- 素材记录：CREDITS（输入、版本、命令）；`docs/ASSETS.md` Poly Haven 组数 / 文件数 / 字节数更新；ASSET_MANIFEST 重新生成。

## 不要做

- 不做拳套、头盔等器材。
- 不给 NPC 用玩家色。
- 不改已有 `avatars`。

## 预计规模

配置 3 个 JSON + roster 追加；脚本约 +60 行；素材约 20–40 MiB；Poly Haven 同步新增约 8 MiB。
