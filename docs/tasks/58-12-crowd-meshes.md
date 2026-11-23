# 58-12 观众 v2 低模（MPFB）

Issue #58 · P2 · A2（前排部分）· 区域：素材（`game/assets/shared/crowd/`）+ 工具

## 目标 / 范围外

**目标**：交付 39-17 约定的观众网格 `res://assets/shared/crowd/crowd_person.tres`，替换现在代码拼的胶囊小人。来源是 MakeHuman / MPFB 系统素材（CC0）生成的低模坐姿人物，≤ 3k 三角面。39-17 合入后 `RSCrowd.mesh()` 发现这个文件就自动使用，滑板 / 滑雪终点区的观众一起升级。

**范围外**：后排 impostor（58-13）；`RSCrowd` 和 `crowd.gdshader` 的代码（39-17）；观众声音（58-28 / 58-29）。

## 先读

1. [39-17](39-17-crowd-seats.md) 的“接口契约”（`V2_MESH` 路径、表面约定：表面 0 = 衣服按实例色，表面 1 = 皮肤）
2. `game/core/crowd.gd:10-43`（现在的 `person_mesh()`：尺寸、两个表面、材质怎么挂）
3. `game/shaders/crowd.gdshader`（全文 37 行：`VERTEX.y > 1.15 && abs(VERTEX.x) > 0.18` 的顶点被当作手臂挥动；整体按实例跳动；皮肤色由实例哈希决定）
4. `tools/blender/make_skaters.py:1-110`（MPFB 管线：建人、选衣服、`bake_mesh`）
5. `tools/bench.py:210-220`（`--script res://tests/...` 无界面运行 GDScript 的先例）
6. [58-00 概览](58-00-overview.md)“素材卡通用规则”

## 改动文件

- 新建 `tools/blender/make_crowd.py`（MPFB 生成 1 个主体 + 最多 3 个变体，坐姿、减面、导出 glTF）
- 新建 `game/tests/build_crowd_mesh.gd`（`extends SceneTree`；读上一步的 glTF，合并成两个表面、挂 `crowd.gdshader` 材质，`ResourceSaver.save` 成 `.tres`）
- 新增 `game/assets/shared/crowd/crowd_person.tres`（必需）、`crowd_person_1..3.tres`（可选变体，暂无代码使用）、生成中间件 `crowd_person_src.gltf|.bin`（保留，便于复现）
- `game/assets/shared/crowd/CREDITS.md`、`game/assets/shared/CREDITS.md`

## 接口契约

- `crowd_person.tres` 是 `ArrayMesh`，恰好两个表面：
  - 表面 0：衣服、头发、鞋子。颜色走实例色（MultiMesh `use_colors`）；头发 / 鞋子用深色**顶点色**区分（顶点色 × 实例色后仍是深色），不加第三个表面——第三个表面不会跟着着色器跳动。
  - 表面 1：皮肤（脸、手、手臂裸露部分），材质参数 `skin = true`。
  - 两个表面的材质都是 `res://shaders/crowd.gdshader` 的 `ShaderMaterial`（与 `person_mesh()` 一致）；39-17 若在 `mesh()` 里自己挂材质，以 39-17 为准，网格本身不受影响。
- 尺寸与姿态：原点在臀部下方的座面高度（坐在 39-15 座位变换上不悬空、不陷进去，座位约定见 39-15），面向 +Z（朝场地）；坐姿双手半举，手和前臂的顶点 y > 1.15 m（相对原点）、|x| > 0.18 m，保证现有着色器的挥手规则生效。
- 预算：≤ 3k 三角面 / 个；无纹理（纯顶点色 + 实例色），所以不占纹理显存。
- 变体文件名 `crowd_person_<n>.tres`，契约相同；`RSCrowd` 以后要多网格时按这个名字找。

## 依赖与顺序

不依赖 39-17 也能做（文件放好即可）；39-17 合入后才会被使用。58-13 依赖本卡的主体网格做 impostor。

## 验收

- `game/tests/test_assets.gd` 追加（稀疏检出跳过）：`crowd_person.tres` 存在时：是 `ArrayMesh`、2 个表面、三角面 ≤ 3000、AABB 高度在 1.1–1.5 m（坐姿）、表面 1 的材质 `skin == true`。
- `python tools/test_assets.py --godot <Godot>`；`python -m pytest -q tools/tests`；`python tools/check_conventions.py`。
- 复现命令写进 CREDITS：`blender --background --python tools/blender/make_crowd.py -- <out>`，然后 `<Godot> --headless --path game --script res://tests/build_crowd_mesh.gd`。
- 素材记录：输入（MakeHuman 系统素材资产名）、Blender / MPFB 版本、命令；许可：输入 CC0、转换脚本是项目代码 → 记 `MIT AND CC0-1.0`，在 `tools/asset_policy.json` 为 `game/assets/shared/crowd/` 加一条更窄的规则（放在 `game/assets/shared/` 之前）。
- 画面不截图；PR 写明“滑板 / 滑雪观众会在 39-17 合入后变化，留给最终试玩”。

## 不要做

- 不改 `game/core/crowd.gd`、`crowd.gdshader`。
- 不用骨骼动画（MultiMesh 不支持蒙皮；动作全靠着色器）。
- 不做 impostor。

## 预计规模

Blender 脚本约 150 行，Godot 转换脚本约 60 行；素材 < 2 MiB。
