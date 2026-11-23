# 58-14 `golf/trees/` → `shared/vegetation/`（只移动）

Issue #58 · P2 · C8（树木部分）· 区域：素材 + 项目（`game/scenes/golf/` 改一个常量）

**开工前提**：高尔夫负责人（#26）在 issue 里同意现在移动。高尔夫 M1（#33）已合入，但高尔夫仍在开发；没有同意不要开工。

## 目标 / 范围外

**目标**：6 组树木 impostor（`fir_a`、`fir_b`、`fir_c`、`island01`、`island02`、`jacaranda`，各 `_albedo.png` / `_normal.png` / `.json`）从 `game/assets/golf/trees/` 移到 `game/assets/shared/vegetation/`，让海湾、湖泊、网球场边、射箭林缘等也能用，不再“借用高尔夫私有目录”。

按 `docs/ASSETS.md` 规定，迁移 PR **只做 `git mv` + 路径与记录更新，不改内容**，便于审查。

**范围外**：灌木、岩石（58-23）；重新烘焙或调整树木；棕榈树（issue 记为缺口，另立任务）；其他项目开始用这些树。

## 先读

1. `game/scenes/golf/golf_course.gd:28`（`TREE_DIR`）、`:620-645`（读取方式）
2. `tools/asset_policy.json` 里 `game/assets/golf/trees/` 规则（约第 104 行）
3. `docs/THIRD_PARTY.md:56-70`（Tree impostors 一节）、`docs/ASSET_PROVENANCE.md:30`、`docs/GOLF_DESIGN.md:25`
4. `game/assets/shared/vegetation/CREDITS.md`（模板）
5. [58-00 概览](58-00-overview.md)“素材卡通用规则”

## 改动文件

- `git mv game/assets/golf/trees/* game/assets/shared/vegetation/`（18 个文件 + 12 个 `.import`）
- `game/scenes/golf/golf_course.gd`：`TREE_DIR := "res://assets/shared/vegetation/"`（只改这一行）
- `.import` 里的 `source_file` 路径（运行一次 `python tools/import_game.py --godot <Godot>` 让 Godot 改写；`uid` 不变）
- `tools/asset_policy.json`：删 `game/assets/golf/trees/` 规则（`shared/` 规则覆盖新位置）；如果 58-01 之后 `shared/vegetation/` 需要 `MIT AND CC0-1.0`（烘焙脚本是项目代码），加更窄规则
- `game/assets/shared/vegetation/CREDITS.md`（每个文件一行：来源 Poly Haven 模型、作者，照 THIRD_PARTY 现有记录）、`game/assets/shared/CREDITS.md`
- `docs/THIRD_PARTY.md`、`docs/ASSET_PROVENANCE.md`、`docs/GOLF_DESIGN.md`、`docs/ASSETS.md` 中的路径文字；`docs/ASSET_MANIFEST.json`（路径变了，重新生成）

## 接口契约

- 文件名不变：`res://assets/shared/vegetation/<kind>_albedo.png`、`<kind>_normal.png`、`<kind>.json`，`kind` 取上面 6 个。其他项目以后照 `golf_course.gd:620-645` 的方式读取。
- 树木的 JSON 字段（`frames / radius / centre_up / height / width`）不变。

## 依赖与顺序

依赖高尔夫负责人同意。与 58-13（只改 `bake_impostor.py` 参数）没有文件冲突。

## 验收

- `git diff --stat -M` 显示 18 个文件为纯重命名（100% 相似度）。
- `python tools/test_golf.py --godot <Godot>`（以及高尔夫其他现有 `tools/test_golf_*.py` 中会加载树的那几个）通过；`python tools/smoke_game.py <Godot> --project game`。
- `python -m pytest -q tools/tests`；`node --test tools/tests/asset_sync.test.mjs`（策略规则无遮挡、证据存在）。
- 画面不截图（内容未变）。

## 不要做

- 不改图集、JSON 内容，不改高尔夫的其他代码。
- 不在本 PR 里给别的项目加树。

## 预计规模

代码 1 行；文档 / 记录约 30 行；纯重命名约 120 MiB（Git 里是 rename，不新增对象）。
