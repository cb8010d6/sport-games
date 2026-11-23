# 58-07 乒乓 / 网球 / 沙排服装

Issue #58 · P1 · D2 · 区域：素材（`game/assets/shared/characters/`）+ 工具配置

## 目标 / 范围外

**目标**：用 58-04 的 `make_character.py` 给三个新项目各生成 4 个 avatar 的角色：

| sport id | 服装 | 可重染材质 |
|---|---|---|
| `table_tennis` | Polo / T 恤 + 运动短裤，运动鞋 | `jacket`（上衣）、`pants`（短裤） |
| `tennis` | Polo 或背心 + 短裤 / 短裙，运动鞋 | `jacket`、`pants` |
| `volleyball` | 运动背心 + 短裤，**赤脚**（不加鞋） | `jacket`、`pants` |

同一 avatar 的身体、头发、眼睛与阵容一致（`roster.json`），只换服装。sport id 以各项目 issue 标题里的 id 为准：乒乓球 #60 `table_tennis`、网球 #63 `tennis`、沙滩排球 #64 `volleyball`，领卡时再核对一次。

**范围外**：拳击、水上摩托（58-08）；姿态 / 动作（58-09 和各项目）；球拍等器材（58-19、58-20）；游戏代码（新项目还没有，接入由各项目做）。

## 先读

1. [58-04](58-04-character-generator.md) 的“接口契约”（配置格式、`ops`、输出目录）
2. `tools/blender/characters/basketball.json`（58-04 生成的现成样例：剪袖、裁短裤、`split`）
3. issue #58 正文 D2 一行和附录 A 的 MakeHuman 部分（哪些包是 CC0：Shirts 01、Skirts 01、Pants 01、系统 `female_sportsuit01`；Pants 03 / Suits 03 / Underwear 02–03 是 CC-BY，不用）
4. `docs/TABLE_TENNIS_DESIGN.md:131-141`（乒乓球对人物的要求：玩家色不串色、电脑中性色外观）
5. [58-00 概览](58-00-overview.md)“素材卡通用规则”

## 改动文件

- 新建 `tools/blender/characters/table_tennis.json`、`tennis.json`、`volleyball.json`
- 新增 `game/assets/shared/characters/outfits/{table_tennis,tennis,volleyball}/avatar{0..3}.gltf|.bin` 及新增的 `textures/*.png`（含 `.import`）
- 如需新的 op（例如“去掉鞋子露出脚”）：`tools/blender/make_character.py` 加一个 op 函数，`tools/character_config.py` 的合法取值同步加
- `game/assets/shared/characters/{outfits,textures}/CREDITS.md`、`game/assets/shared/CREDITS.md`；第一次用到的 MakeHuman 社区包在 `docs/THIRD_PARTY.md` MakeHuman 一节补一段（包名、页面、CC0 依据）

## 接口契约

- 输出路径即 `RSOutfit.path(sport, avatar)`（58-05）：`res://assets/shared/characters/outfits/<sport>/avatar<N>.gltf`。
- 材质名 `jacket` / `pants` 必须存在且只覆盖布料（项目按玩家色重染）；皮肤、头发不能落进这两个材质。
- MakeHuman 社区包：只用 issue 附录 A 列为 CC0 的包。包里资产的原名作纹理文件名（去重规则）；如果原名和系统素材重名但内容不同，加 `mh_` 前缀并在 CREDITS 写明。
- 布料细节法线（Poly Haven `cotton_jersey`、`waffle_pique_cotton`）**本卡不做**：服装贴图沿用 MakeHuman 自带的；需要时另开卡。

## 依赖与顺序

依赖 58-04（脚本和配置格式）。与 58-06（迁移旧项目）、58-08 没有文件冲突，可以并行；同时生成时注意共享 `textures/` 里同名文件必须同内容（脚本会报错）。

## 验收

- `python tools/character_config.py --check`；`python -m pytest -q tools/tests`（含 CREDITS、导入设置检查）；`python tools/texture_imports.py --check`。
- `python tools/import_game.py --godot <Godot>` 无报错；在 `game/tests/outfit_cases.gd` 追加：三个 sport 的 4 个路径都 `ResourceLoader.exists`（稀疏检出时跳过，判断照 `test_assets.gd:56` 的 `RS_SPARSE_ASSETS`）。
- PR 里列：每个角色三角面数（≤ 30k）、新增纹理张数和字节数、本卡新增 Git 体积（预算：每个项目新增服装纹理每人 ≤ 2 × 2K，Git 成品 ≤ 40 MiB / 项目）。
- 素材记录：CREDITS 写输入包（页面 URL、包名、资产名、原始 ZIP 的 SHA-256、下载日期）、Blender / MPFB 版本、命令；许可 `CC0-1.0`。
- 画面不截图，PR 里写明。

## 不要做

- 不用 CC-BY 包；不用 Sketchfab 等平台的“免费”服装。
- 不改阵容（`roster.json`）。
- 不改 `game/scenes/` 下任何文件。

## 预计规模

配置 3 个 JSON；脚本改动 ≤ 60 行；素材约 20–40 MiB（多数纹理与现有角色共享）。
