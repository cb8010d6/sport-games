# 58-06 滑板 / 滑雪 / 篮球改用共享阵容，删除旧角色

Issue #58 · P1 · D1 · 区域：素材 + 项目（`game/scenes/skate/`、`ski/`、`basketball/` 各改一处常量）

**开工前提**：维护者已确认阵容（avatar 0–3 是哪四个人）和“一个（项目, avatar）一个完整 glTF”的拆法（58-00“需要维护者决定的”第 1、2 条）。

## 目标 / 范围外

**目标**：

1. 用 `make_character.py` 生成 `skate`、`ski`、`basketball` 三套 × 4 个 avatar 共 12 个角色到 `game/assets/shared/characters/outfits/`，纹理去重放 `textures/`；
2. 三个项目的 rig 改用 `RSOutfit.path(sport, avatar)`；同一个档案 avatar 在三个项目里是同一个人（修 issue #58“发现的问题”第 3 条）；
3. 删除 `game/assets/characters/` 里 `rider* / skier* / baller*` 的 `.glb` 和提取出的 PNG（含 `.import`）；
4. 角色目录总大小 ≤ 150 MiB（issue 验收目标，以实测为准），无逐字节重复纹理，纹理全部显存压缩、≤ 2K（53-05 的检查）。

**范围外**：高尔夫（`golfer0–3.glb` 目前没有代码引用，属于 #26 / 高尔夫负责人；本卡**不删、不改**，`golf.json` 配置已由 58-04 准备好，高尔夫负责人自己切换）；新服装（58-07、58-08）；rig 的姿态和重染逻辑。

## 先读

1. [58-04](58-04-character-generator.md)、[58-05](58-05-rs-outfit.md) 的“接口契约”
2. `game/scenes/skate/skater_rig.gd:20-25`、`:440-450`（`RIDERS`、`_load_character` 调用）
3. `game/scenes/ski/skier_rig.gd:14-19`、`:310-340`；`game/scenes/basketball/baller_rig.gd:18-23`、`:405-425`
4. `tools/asset_policy.json` 里 `game/assets/characters/` 那条规则；`docs/THIRD_PARTY.md` “MakeHuman characters” 一节
5. `game/tests/test_perf.gd:158-196`（它用 `RSSkaterRig.RIDERS[1]` 判断有没有角色模型——改名后要同步）
6. [58-00 概览](58-00-overview.md)“素材卡通用规则”

## 改动文件

- 新增 `game/assets/shared/characters/outfits/{skate,ski,basketball}/avatar{0..3}.gltf|.bin(.import)`、`textures/*.png(.import)`
- 删除 `game/assets/characters/{rider,skier,baller}*`（`git rm`）
- `game/scenes/skate/skater_rig.gd`、`game/scenes/ski/skier_rig.gd`、`game/scenes/basketball/baller_rig.gd`：路径常量改为由 `RSOutfit.path()` 生成（见契约）；其余不动
- `game/tests/test_perf.gd`：角色存在判断改用新常量（只改判断那一行）
- 删除 `tools/blender/make_skaters.py`、`make_skiers.py`、`make_ballers.py`（`make_golfers.py` 保留，等高尔夫切换）
- `tools/asset_policy.json`：`game/assets/characters/` 规则保留（高尔夫文件还在）；新文件由 `game/assets/shared/` 规则覆盖
- `docs/THIRD_PARTY.md` MakeHuman 一节的 Location、`docs/ASSETS.md` 体积统计、`docs/ASSET_MANIFEST.json`（重新生成）、各 CREDITS

## 接口契约

```gdscript
# skater_rig.gd（ski / basketball 同理，sport 分别为 "ski"、"basketball"）
const RIDERS := [
	"res://assets/shared/characters/outfits/skate/avatar0.gltf",
	...  # 4 项，与 RSOutfit.path("skate", i) 相同；保留常量名，别的代码和测试按名字引用它
]
```

保留常量（而不是到处改成函数调用）是为了让 `test_perf.gd`、回放等现有引用不变；常量值必须等于 `RSOutfit.path(sport, i)`，测试里断言这一点。

- 重染材质名不变：滑雪 `jacket / pants / glove`，篮球 `jacket / pants`，滑板无（58-04 配置已保证）。
- 滑板原来 avatar i 就是 rider i，提议的阵容沿用它，所以滑板外观不变；滑雪、篮球里同一档案会换成新阵容的人——这是预期变化。

## 依赖与顺序

依赖 58-04、58-05、53-05 全部合入，以及维护者对阵容的确认。之后 58-07 / 58-08 的新服装与本卡无冲突。

## 验收

- `game/tests/outfit_cases.gd` 追加：三个 rig 的路径常量逐项等于 `RSOutfit.path(sport, i)`。
- `python tools/texture_imports.py --check`（0 违规）；`python -m pytest -q tools/tests`（含 58-01 的 CREDITS 检查、无重复纹理）；PR 里贴：旧 `characters/` 三项目合计大小 → 新 `shared/characters/` 大小，重复纹理数 → 0。
- `python tools/import_game.py --godot <Godot>`；`python tools/test_perf.py --godot <Godot>`（真实骑手检查不再被跳过且通过）；`python tools/smoke_game.py <Godot> --project game`。
- 素材记录：CREDITS 每个文件一行（输入资产名、Blender / MPFB 版本、命令）；ASSET_MANIFEST 重新生成；`docs/RESOURCE_CLEANUP.md` 追加一段本次删除记录（文件数、字节数、可从哪个提交恢复），格式照文件里现有的那段。
- 画面（人物换人、贴图压缩后的观感）不截图，PR 里写明留给最终试玩。

## 不要做

- 不动 `golfer*` 文件和 `make_golfers.py`。
- 不在同一个 PR 里改 rig 的姿态、材质参数。
- 不改写 Git 历史（旧文件留在历史里，`RESOURCE_CLEANUP.md` 记录恢复方法）。

## 预计规模

代码改动约 30 行；素材新增约 100–150 MiB、删除约 400 MiB（以实测为准，PR 里列出）。
