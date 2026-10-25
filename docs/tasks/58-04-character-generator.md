# 58-04 统一人物生成脚本 + 阵容 / 服装配置

Issue #58 · P1 · D1 · 区域：工具（`tools/blender/`）+ 素材（只加配置）

## 目标 / 范围外

**目标**：把 `tools/blender/make_skaters.py`、`make_skiers.py`、`make_ballers.py`、`make_golfers.py`（共 536 行，互相 import）合并成一个 `make_character.py`，由两类配置驱动：

- **阵容**：avatar 0–3 的身份（性别、种族比例、肤色贴图、眼睛、发型、眉毛、身高 / 肌肉 / 体重），跨项目不变；
- **服装**：每个项目一份，给出每个 avatar 穿什么 MakeHuman 衣服、要做哪些剪裁 / 拆分操作、输出哪些可重染的材质名。

输出改成 `.gltf` + 外部纹理，纹理按 MakeHuman 资产名放进共享目录，天然去重。本卡只交脚本和配置，并用它生成**一个**样例证明可用。

**范围外**：替换游戏里现在用的角色（58-06）；新项目的服装（58-07、58-08）；任何 `game/` 代码。

## 先读

1. `tools/blender/make_skaters.py:1-142`（MPFB 管线、`VARIANTS`、`human_info`、`bake_mesh`、导出；开头写了 `BLENDER_USER_RESOURCES` 的用法）
2. `tools/blender/make_skiers.py:37-118`（`split_clothes`、`add_gloves`：拆 `jacket` / `pants` / `glove`）
3. `tools/blender/make_ballers.py:40-88`（`unmask_body`、`cut_suit`：剪袖子、裁短裤）
4. `tools/blender/make_golfers.py:38-75`（`unmask_forearms`、`cut_sleeves`）
5. `docs/ASSETS.md:87-103`（共享目录约定）、`game/assets/shared/characters/CREDITS.md`
6. [58-00 概览](58-00-overview.md)“素材卡通用规则”和“需要维护者决定的”第 1、2 条

## 改动文件

- 新建 `tools/blender/make_character.py`
- 新建 `tools/blender/characters/<sport>.json`：`skate.json`、`ski.json`、`basketball.json`、`golf.json`（从现有 4 个脚本的 `VARIANTS` 转过来）
- 新建 `game/assets/shared/characters/roster/roster.json`（阵容身份记录，运行时也可读）
- 新建 `tools/character_config.py`（纯 Python 配置校验，不 import bpy）+ `tools/tests/test_character_config.py`
- 样例输出 1 个：`game/assets/shared/characters/outfits/skate/avatar0.gltf` + `.bin` + 它用到的 `textures/*.png`（含 `.import`，导入设置过 53-05 的检查）
- `game/assets/shared/characters/{roster,outfits,textures}/CREDITS.md` 填行；`game/assets/shared/CREDITS.md` 文件数
- 旧的 4 个 `make_*.py` **先保留**（58-06 迁移完再删），在文件开头注释里写“已由 make_character.py 取代”

## 接口契约

**目录约定（58-05、58-06、58-07、58-08 都按这个写，不再改）**：

```
game/assets/shared/characters/
  roster/roster.json                    # 阵容身份
  outfits/<sport>/avatar<N>.gltf|.bin   # 一个（项目, avatar）一个完整角色：身体 + 头发 + 眼睛 + 服装 + 骨架
  textures/<MakeHuman 资产名>_<map>.png  # 例：young_caucasian_male_diffuse.png、male_casualsuit06_normal.png
```

不拆成“身体 glTF + 服装 glTF 运行时拼装”的原因：MPFB 的衣服按每个身体单独拟合，身体还要按衣服删掉被遮住的面；拆开会穿模。体积主要在纹理，按资产名共享后去重效果一样（待维护者确认，见概览）。

**`roster.json`**：

```json
{"version": 1, "avatars": [
  {"id": 0, "gender": 1.0, "race": "caucasian", "skin": "young_caucasian_male", "eyes": "darkbrown",
   "hair": "short02", "brows": "eyebrow001", "height": 0.55, "muscle": 0.6, "weight": 0.45}
]}
```

提议沿用 `make_skaters.py` 的 rider0–3 身份作为 avatar 0–3（等维护者确认后 58-06 才落地）。

**`tools/blender/characters/<sport>.json`**：

```json
{"version": 1, "sport": "basketball",
 "clothes": [["male_casualsuit04", "shoes02"], ["female_casualsuit01", "shoes06"], ["…"], ["…"]],
 "ops": ["cut_sleeves:upperarm", "cut_shorts:above_knee", "split:jacket,pants"],
 "materials": ["jacket", "pants"]}
```

- `clothes[i]` 是 avatar i 的 MakeHuman 衣服 / 鞋子资产名（只用 CC0 系统素材和 issue 附录列出的 CC0 社区包）。
- `ops` 按顺序执行，取值：`cut_sleeves:upperarm`（篮球）、`cut_sleeves:forearm`（高尔夫）、`cut_shorts:above_knee`（篮球）、`split:jacket,pants`（按 UV 岛上下拆，滑雪）、`gloves`（手部皮肤变 `glove`，滑雪）。每个 op 是 `make_character.py` 里一个函数，代码从现有脚本搬来，不改算法。
- `materials` 是导出后保证存在的可重染材质名，各项目的 rig 按名字重染（现有约定：滑雪 `jacket / pants / glove`，篮球 / 高尔夫 `jacket / pants`，滑板无）。

**命令**：

```
set BLENDER_USER_RESOURCES=<MPFB 安装目录>
blender --background --python tools/blender/make_character.py -- <sport> [avatar ...]
	# 输出到 game/assets/shared/characters/outfits/<sport>/，纹理到 ../../textures/
	# 纹理已存在且内容不同 → 报错停止（同名必须同内容，否则去重会悄悄覆盖）
```

- glTF 导出用 `GLTF_SEPARATE`，`export_texture_dir` 指向共享 `textures/`；不内嵌图片。
- 脚本自己生成的纹理（例如现有 `make_darkbrown_eyes()` 改出来的眼睛）用 `rs_` 前缀命名，避免和 MakeHuman 原名冲突。
- `tools/character_config.py --check`：校验 `roster.json` 和每个项目配置的字段、类型、`clothes` 长度等于阵容人数、`ops` 取值合法、`materials` 与 `ops` 一致（有 `split` 或 `gloves` 才能有对应材质名）。

## 依赖与顺序

无硬依赖。53-05（导入设置工具）合入后样例纹理要过它的检查；没合入就先按 `docs/ASSETS.md` 导入表手动设好。58-05 只依赖上面的目录约定，可以同时做。

## 验收

- `python -m pytest -q tools/tests/test_character_config.py`（合法 / 非法配置各几例，加对仓库真实配置跑 `--check`）。
- 样例：`skate/avatar0.gltf` 在 Godot 里能加载（`python tools/import_game.py --godot <Godot>` 无报错）；PR 里贴三角面数（≤ 30k）、样例新增字节数。
- 素材记录：CREDITS 写输入素材（MakeHuman 系统素材包页面、资产名）、Blender / MPFB 版本、命令；许可 `CC0-1.0`（输入全 CC0，脚本只做形变和剪裁）。
- 通用检查见 58-00（`tools/tests`、`texture_imports.py --check`、`asset_sync.test.mjs`）。
- 不跑截图；画面留给 58-06 合入后最终试玩。

## 不要做

- 不改游戏里任何 rig 的路径（58-06）。
- 不删旧的 4 个脚本和 `game/assets/characters/`。
- 不用 CC-BY 的 MakeHuman 社区包（Pants 03、Suits 03、Underwear 02–03 等）。

## 预计规模

`make_character.py` 约 350 行（大部分从 4 个脚本搬来），配置 4 个 JSON，校验 + 测试约 150 行；样例素材约 10–20 MiB。
