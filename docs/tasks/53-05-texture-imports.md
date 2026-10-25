# 53-05 纹理导入设置工具；角色纹理改显存压缩 + 2K 上限

Issue #53（显存）· 同时完成 #58 P0 遗留项“角色纹理显存实测 + 统一 VRAM 压缩、2K 上限” · 区域：工具 + 素材

## 目标 / 范围外

**目标**：

1. 新建 `tools/texture_imports.py`：按 `docs/ASSETS.md`“导入设置”表检查 / 修正纹理的 `.import` 参数，并离线估算显存；
2. 用它把 `game/assets/characters/` 的 133 张 PNG 改成显存压缩（`compress/mode=2`），法线贴图按法线压缩，全部 `process/size_limit=2048`，眼睛 / 眉毛 / 睫毛 1024；
3. 以后 `game/assets/shared/` 下新增的纹理都用它检查（58 系列素材卡的验收会调用）。

现状：133 个角色 `.import` 全是 `compress/mode=0`（无损、`vram_texture=false`），法线最大 4096²，运行时按未压缩 RGBA 占显存。

**范围外**：角色纹理去重、`.glb` 改 `.gltf`（58-06 迁移时做）；Poly Haven 纹理（已经是显存压缩，`226` 个 `.import` 已是 `compress/mode=2`）；HDRI；改任何游戏代码。

## 先读

1. `docs/ASSETS.md:116-127`（“导入设置”表，本工具的规则来源）
2. `game/assets/characters/baller0_male_casualsuit04_normal.png.import`（现在的参数长什么样）
3. `tools/test_assets.py`（工具脚本风格、怎么找 Godot）
4. `tools/import_game.py`（改完参数后用它重新导入）
5. `tools/tests/test_music_assets.py`（`tools/tests` 里检查素材文件的测试写法）

## 改动文件

- 新建 `tools/texture_imports.py`
- 新建 `tools/tests/test_texture_imports.py`
- `game/assets/characters/*.png.import`（133 个，由工具改参数后再由 Godot 重新导入生成）
- `docs/ASSETS.md`（“导入设置”表下加一行：用 `tools/texture_imports.py --check` 检查）

## 接口契约

```
python tools/texture_imports.py --check  [PATH ...]   # 违反规则时列出文件和参数，退出码 1
python tools/texture_imports.py --apply  [PATH ...]   # 只改 [params] 段的相关键，其余行原样保留
python tools/texture_imports.py --report [PATH ...]   # 打印估算显存：当前设置 -> 规则设置（MiB）
```

- 默认 PATH：`game/assets/characters` 和 `game/assets/shared`。只处理 `*.png.import` / `*.jpg.import`。
- 规则（按文件名判断，和 `docs/ASSETS.md` 一致）：
  - 所有纹理：`compress/mode=2`、`mipmaps/generate=true`；
  - 文件名含 `_normal` 或 `_nor_gl_`：`compress/normal_map=1`；
  - 路径在 `characters/` 或 `shared/characters/` 下：`process/size_limit=2048`；文件名含 `eye`、`eyebrow`、`eyelash` 的为 `1024`；
  - 其他目录 `process/size_limit` 不强制。
- 显存估算（纯 Python，读 PNG / JPEG 头取尺寸和是否带 alpha，不加依赖）：未压缩 = 宽 × 高 × 4 B；显存压缩 = 不透明颜色 0.5 B/像素（BC1），带 alpha 或法线 1 B/像素（BC3 / BC5）；有 mipmap 再 × 4/3；尺寸超过 `size_limit` 的按缩小后的计算。输出最后一行固定格式：`RS_TEXTURE_VRAM: <当前> MiB -> <规则> MiB (<n> textures)`。
- `--apply` 后必须跑 `python tools/import_game.py --godot <Godot>`，让 Godot 按新参数重新导入并改写 `[remap]` 段（`path`、`metadata.vram_texture`、`dest_files` 会变）；提交 Godot 改写后的 `.import`。

## 依赖与顺序

无依赖，可以先做。58-06（角色迁移到 `shared/characters/`）和之后所有新增纹理的素材卡都用 `--check`。

## 验收

- `tools/tests/test_texture_imports.py`（pytest，不需要 Godot）：
  - 用临时目录里的假 `.import` 和 1×1 / 带 alpha 的小 PNG，验证规则判断、`--apply` 只改目标键、估算公式；
  - 对仓库真实目录跑 `--check`，期望 0 违规（这一条保证以后新增的角色 / 共享纹理不会漏设）。
- 命令：`python -m pytest -q tools/tests/test_texture_imports.py`；`python tools/texture_imports.py --report`（PR 里贴改前改后的 `RS_TEXTURE_VRAM` 行）；`python tools/import_game.py --godot <Godot>`；`python tools/test_perf.py --godot <Godot>`（角色仍能加载）；`python tools/smoke_game.py <Godot> --project game`；`python -m ruff check --config hub/pyproject.toml hub tools`。
- 素材记录：没有新增或修改二进制文件，`docs/ASSET_MANIFEST.json` 不用重生成；Git 体积不变（只改 `.import` 文本）。
- PR 里写清：`RENDER_VIDEO_MEM_USED` 实测没做（需要有显示的机器），数字是离线估算；角色贴图压缩后的画面（皮肤、衣服法线）留给最终试玩。

## 不要做

- 不缩小、不重新编码 PNG 文件本身（只改导入参数）。
- 不改 `game/assets/polyhaven/`、`golf/trees/`、`decals/` 的导入设置。
- 不删除角色或纹理（重复纹理在 58-06 迁移时处理）。

## 预计规模

工具约 180 行，测试约 100 行，133 个 `.import` 各改几行（机械改动，审查时看工具和抽样即可）。
