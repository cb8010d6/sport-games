# 58-00 概览：#58 共享素材库的剩余工作

Issue #58（共享素材库），涉及素材、工具、框架区。任务卡格式和领取流程见 [README](README.md)。
本页另有一节“素材卡通用规则”，所有素材卡都把本页列为“先读”之一。

## 已经合并（PR #88，P0 的半成品）

| 内容 | 位置 |
|---|---|
| 共享素材库规范（目录、命名、导入、预算、来源记录） | [docs/ASSETS.md](../ASSETS.md) “共享素材库”一节 |
| `game/assets/shared/` 骨架，每个子目录一份 CREDITS 模板（`characters/{roster,outfits,textures}`、`crowd`、`arena`、`equipment`、`materials`、`vegetation`、`vfx`、`signage`） | [总索引](../../game/assets/shared/CREDITS.md) |
| `tools/asset_policy.json` 把 `game/assets/shared/` 登记为 `CC0-1.0`；规则匹配逻辑抽到 `tools/asset_policy.mjs`（先匹配的规则生效，`shadowedRules()` 查被遮住的规则） | `tools/asset_policy.*` |
| `RSPbr` 支持 `"shared:<来源>_<id>"`，读 `res://assets/shared/materials/<来源>_<id>/`，文件名沿用 Poly Haven 规则 | `game/core/pbr.gd:12-35` |
| `RSProps.PREFABS` 键名改成 `<套件>_<名称>`，套件 `urban / nature / beach / marina / arena / hall`；glTF 路径以 `shared:` 开头时读 `res://assets/shared/` | `game/core/props.gd:12-51`、`:90-94` |
| 9 组未使用的 Poly Haven 素材在锁定清单里写了 `purpose` | `tools/assets.lock.json`，ASSETS.md 末尾表格 |
| `tools/test_assets.py`（137 项，已进 CI；CI 稀疏检出时 `RS_SPARSE_ASSETS=1` 只查键名和路径） | `game/tests/test_assets.gd` |

## 还剩什么

P0 遗留（issue 评论列出的三项）：

| 遗留项 | 处理 |
|---|---|
| 角色纹理显存实测 + 统一 VRAM 压缩、2K 上限 | 转到 [53-05](53-05-texture-imports.md)（工具 + 角色导入设置）；迁移到新目录时由 58-06 再跑一次检查 |
| 复核 `ASSETS.md` 规范文字 | [58-01](58-01-assets-spec-review.md)，顺带补“每个文件都有 CREDITS 行”的自动检查 |
| prefab 改名后的画面检查 | 不拆卡。改名只换键名，几何没变；按用户规则留给最终试玩 |

另外两个规范里写了、但仓库里没有工具支撑的步骤，作为基础设施卡：

- “用同步工具生成 `assets.lock.json` 条目，不手写哈希”——现在没有这样的工具（`tools/fetch_polyhaven.py` 只下载、不写锁定清单）→ [58-02](58-02-polyhaven-lock-tool.md)
- “ambientCG 手动下载 → 只留需要的贴图 → 转 Poly Haven 命名”——没有脚本 → [58-03](58-03-cc0-material-pack.md)

P1–P7：

| 阶段 | issue 编号 | 卡 |
|---|---|---|
| P1 人物 | D1 统一阵容 | 58-04 生成脚本、58-05 `RSOutfit`、58-06 迁移现有 3 个项目 |
| | D2 运动服装、D4 NPC | 58-07 乒乓 / 网球 / 沙排服装，58-08 拳击 / 水上摩托服装 + 裁判 |
| | D3 姿态参考 | 58-09 |
| P2 场馆 + 观众 | A3 灯、A6 围栏、A7 场边家具 | 58-10（Poly Haven 模型 + `RSProps` 键） |
| | A6 远处铁丝网、B4 网 / 绳、C5 泡沫、B1 胶皮 | 58-11（ambientCG 材质一次做完） |
| | A2 观众 v2 | 58-12 低模、58-13 impostor 图集 |
| | C8 树迁移 | 58-14 |
| | A1 看台、A4 记分牌、C6 室内壳的代码 | **不在本 issue 拆**：由 [39-15](39-15-arena-structures.md) ~ [39-18](39-18-arena-hall.md) 的 `RSArena` 卡负责，本 issue 只交素材 |
| P3 场地与天空 | C1–C4、C6 材质 | 58-15 |
| | C7 HDRI | 58-16 素材、58-17 `RSSkyPresets`（框架） |
| | C1 / C2 场线 | 58-18 `court_lines` 着色器（框架） |
| P4 公共水面 | C5 | **代码是 [39-10](39-10-water-waves.md) ~ [39-12](39-12-water-wake.md) 的 `RSWater`**；素材部分：泡沫 `shared:acg_foam002`（58-11）、湖 / 海湾 HDRI（58-16）、湿沙（58-15）、浪花贴图（58-25）、水声（58-29） |
| P5 器材 | B1、B3 | 58-19（含 `make_equipment.py` 骨架） |
| | B2 网球拍 | 58-20 |
| | B4 球网系统 | 58-21 `RSNet`（框架） |
| | B5、B6 拳击 | 58-22 |
| | B8、B9、C8 码头浮标、灌木岩石 | 58-23 |
| | B7 水上摩托 | 58-24（待确认：先要白模试玩） |
| | B10 保龄 / 射箭 / 飞机器材 | 归 #25，不拆 |
| P6 特效与音频 | E1 图集 | 58-25 |
| | E2–E5 粒子预设 | 58-26 `RSVfx`（框架） |
| | E6 拖尾 | 58-27 `RSTrail`（框架） |
| | F4、F9（Kenney，可直接下载） | 58-28 |
| | F1–F3、F5–F8（Freesound，需要登录） | 58-29（待确认：维护者下载） |
| P7 界面美术 | G1 图标 | 58-30 |
| | A5、G4 横幅 / Logo | 58-31 |
| | G2 预览图、G3 HUD、G5 字体 | 不拆：G2 流程已有（`tools/capture_previews.py`），G3 随各项目 issue，G5 已有 |
| — | A8 领奖台材质 | 不拆：只改 `game/core/podium.gd` 的材质参数，维护者顺手做 |

## 依赖图

```
基础设施   58-01 规范复核 + CREDITS 检查（建议最先合入，其余卡的验收都调用它的测试）
           58-02 Poly Haven 锁定工具 ──→ 58-10、58-15、58-16、58-19、58-20、58-22、58-23
           58-03 CC0 材质打包脚本 ───→ 58-11 ──→ 58-19（胶皮）、58-21（网 / 绳）、58-22（绳）、39-11（泡沫）
           53-05 纹理导入工具 ───────→ 所有新增纹理的卡用 --check

P1 人物    58-04 生成脚本 ──┬── 58-06 迁移（还要 58-05）
                           ├── 58-07 新服装 A
                           └── 58-08 新服装 B
           58-05 RSOutfit（框架，只依赖 58-04 写死的目录约定，可与 58-04 同时做）
           58-09 姿态参考（独立）

P2         58-10、58-11 可并行；58-12 ── 58-13；58-14 可做
P3         58-15、58-16 可并行；58-17 依赖 58-16 的 HDRI 路径约定（可同时做）；58-18 独立
P5         58-19 ── 58-20、58-22（复用 make_equipment.py 骨架）；58-21 依赖 58-11；58-23 独立；58-24 待确认
P6         58-25 ── 58-26；58-27 独立；58-28 独立；58-29 待确认
P7         58-30、58-31 独立
```

P1、P2、P3、P5、P6、P7 之间除上图标出的以外没有依赖。

## 卡索引

| 卡 | 内容 | 状态 | 依赖 | 区域 |
|---|---|---|---|---|
| [58-01](58-01-assets-spec-review.md) | 复核 ASSETS.md；每个共享文件都有 CREDITS 行的自动检查 | 待领 | — | 素材文档 + 工具 |
| [58-02](58-02-polyhaven-lock-tool.md) | Poly Haven 锁定条目生成工具 | 待领 | — | 工具 |
| [58-03](58-03-cc0-material-pack.md) | ambientCG 等 CC0 材质 ZIP → Poly Haven 命名的打包脚本 | 待领 | — | 工具 |
| [58-04](58-04-character-generator.md) | 统一人物生成脚本 + 阵容 / 服装配置 | 待领 | — | 工具（Blender） |
| [58-05](58-05-rs-outfit.md) | `RSOutfit`：阵容路径、服装材质槽 | 待领 | 58-04 的目录约定 | 框架 |
| [58-06](58-06-character-migration.md) | 滑板 / 滑雪 / 篮球改用共享阵容，删旧角色 | 待领 | 58-04、58-05、53-05 | 素材 + 项目 |
| [58-07](58-07-outfits-court.md) | 乒乓 / 网球 / 沙排服装 | 待领 | 58-04 | 素材 |
| [58-08](58-08-outfits-boxing-jetski.md) | 拳击 / 水上摩托服装、裁判 NPC | 待领 | 58-04、58-02 | 素材 |
| [58-09](58-09-pose-reference.md) | 网球等关键姿态数据（Poses 02） | 待领 | — | 素材 |
| [58-10](58-10-venue-props.md) | 灯具、围栏、场边家具（Poly Haven）+ `RSProps` 键 | 待领 | 58-02 | 素材 + 框架（只加键） |
| [58-11](58-11-acg-materials.md) | ambientCG 材质：铁丝网、球网、绳、泡沫、胶皮 | 待领 | 58-03 | 素材 |
| [58-12](58-12-crowd-meshes.md) | 观众 v2 低模（MPFB） | 待领 | — | 素材（Blender） |
| [58-13](58-13-crowd-impostor.md) | 观众 v2 后排 impostor 图集 + `RSCrowd` 远排入口 | 待领 | 58-12、39-17 | 素材 + 框架 |
| [58-14](58-14-trees-to-shared.md) | `golf/trees/` → `shared/vegetation/`（只移动） | 待领 | — | 素材 + 项目（高尔夫） |
| [58-15](58-15-ground-materials.md) | 红土、木地板、沙、地胶等地表材质 | 待领 | 58-02 | 素材 |
| [58-16](58-16-hdri-set.md) | HDRI：室外 puresky、海滩、湖 / 海湾、室内 2K | 待领 | 58-02 | 素材 |
| [58-17](58-17-sky-presets.md) | `RSSkyPresets`：天空 + 太阳 + 雾的预设与构建 | 待领 | 58-16 的路径约定 | 框架 |
| [58-18](58-18-court-lines.md) | 共享场线着色器 + 网球 / 乒乓 / 沙排场线数据 | 待领 | — | 框架（着色器） |
| [58-19](58-19-equipment-paddle-balls.md) | `make_equipment.py` + 乒乓球拍 + 三种球 | 待领 | 58-02、58-11 | 素材（Blender） |
| [58-20](58-20-tennis-racket.md) | 网球拍 | 待领 | 58-19 | 素材（Blender） |
| [58-21](58-21-rs-net.md) | `RSNet` 球网 + 网柱生成 | 待领 | 58-11 | 框架 |
| [58-22](58-22-boxing-kit.md) | 拳套、拳台 | 待领 | 58-19、58-11 | 素材（Blender） |
| [58-23](58-23-marina-nature-props.md) | 码头、浮标、灌木、岩石 + `RSProps` 键 | 待领 | 58-02 | 素材 + 框架（只加键） |
| [58-24](58-24-jetski-model.md) | 水上摩托模型 | 待确认 | 水上摩托 issue 的白模试玩 | 素材（Blender） |
| [58-25](58-25-vfx-atlas.md) | Kenney 粒子贴图 → 2K 共享图集 | 待领 | — | 素材 |
| [58-26](58-26-rs-vfx.md) | `RSVfx` 粒子预设（水花、尘土、闪光、彩带、冲击） | 待领 | 58-25 | 框架 |
| [58-27](58-27-rs-trail.md) | `RSTrail` 拖尾网格 | 待领 | — | 框架 |
| [58-28](58-28-kenney-audio.md) | Kenney Impact Sounds：出拳、挡格、脚步 | 待领 | — | 素材 |
| [58-29](58-29-freesound-audio.md) | Freesound 音效（维护者下载后加工） | 待确认 | 维护者下载原文件、58-28 | 素材 + 框架（`RSSfx.LOOPS`） |
| [58-30](58-30-sport-icons.md) | 项目图标 SVG + `RSGameModule.icon` 字段 | 待领 | — | 素材 + 框架（一个字段） |
| [58-31](58-31-signage-atlas.md) | 横幅 / Logo 图集 + 共享旗面着色器 | 待领 | — | 素材 + 着色器 |

状态以 [README](README.md) 的索引为准（README 收录本表后，本页这一列不再单独维护）。

## 素材卡通用规则

每张素材卡只写本卡特有的内容；下面这些对所有素材卡都成立。

### 进 Git 还是同步下载

按 `.gitignore:43-52` 和 `docs/ASSETS.md`“哪些文件在哪里”：

| 文件 | 分发 | 要提交的东西 |
|---|---|---|
| Poly Haven 原始纹理 / HDR / 模型 buffer（`game/assets/polyhaven/**` 的 `.jpg .png .hdr .bin`） | **不进 Git**，`node tools/sync_assets.mjs` 下载 | `tools/assets.lock.json` 条目（用 58-02 的工具生成，不手写哈希）、模型的 `.gltf` 描述文件、Godot `.import`、`polyhaven/CREDITS.md` 一行 |
| Poly Haven 加工件（减面 `*_lod.bin`、`textures_lod/`） | 进 Git（`.gitignore` 例外规则） | 加工结果 + 加工命令 |
| 其他 CC0 来源（ambientCG、Kenney、MakeHuman 社区包、Freesound、OpenGameArt）的**加工成品** | 进 Git，放 `game/assets/shared/...`（音效放 `game/assets/sfx/`） | 成品 + CREDITS 行；原始 ZIP / WAV **不提交** |
| 项目脚本生成（Blender 器材、人物、impostor、SVG） | 进 Git | 成品 + 生成脚本（`tools/blender/`）+ CREDITS 行 |

不用 Git LFS。单文件 ≤ 20 MiB；每个新项目新增 Git 成品 ≤ 40 MiB、新增 Poly Haven 同步下载 ≤ 120 MiB（`docs/ASSETS.md`“每个新项目的预算”）。共享件会被多个项目复用，PR 里写清本卡新增多少 MiB、算在哪个首个使用者的预算里。

### 来源记录

- 外部来源一律 CC0（或项目原创 MIT）。不收 CC-BY / CC-BY-SA / “royalty free” / 来源不明的素材；真实商标去掉或换成虚构标志。
- 每个提交的文件在**所在目录的 CREDITS.md** 表格里有一行（模板已在各目录里），写原始页面、资产 ID、作者、许可、下载日期、原始文件名与 SHA-256、加工命令。58-01 合入后由 `tools/tests/test_shared_credits.py` 自动检查。
- 新的外部来源（ambientCG、Kenney、MakeHuman 社区包等第一次出现时）在 `docs/THIRD_PARTY.md` 加一节，附官方许可页链接（链接已在 issue #58 附录 A 核实过）。
- 含项目原创几何 / 着色器的子目录记 `MIT AND CC0-1.0`，并在 `tools/asset_policy.json` 的 `documented` 里加一条更窄的前缀规则，放在 `game/assets/shared/` 那条**之前**（`node --test tools/tests/asset_sync.test.mjs` 会查被遮住的规则）。
- 有二进制变化的 PR 重新生成 `docs/ASSET_MANIFEST.json`：`node tools/publication_audit.mjs --write audit-output`，把 `audit-output/asset-manifest.json` 复制过来（没有二进制变化不要重生成）。
- 同步 `game/assets/shared/CREDITS.md` 总索引里的文件数，和 `docs/ASSETS.md` 里的组数 / 文件数 / 字节数（Poly Haven）。

### 下载和工具

- 下载放协调者本机的 F 盘临时目录（例如 `wt/_dl/<卡号>/`），不放仓库里，不放 C 盘。每个下载解压到单独的新目录，脚本不在下载目录里运行。
- **不登录任何网站**。Freesound 必须登录才能下载原文件，相关条目只列清单交给维护者（58-29）。
- Blender 在协调者机器 D 盘（Steam 版）；MPFB 扩展和 MakeHuman 系统素材包按 `tools/blender/make_skaters.py` 开头的说明装在 `BLENDER_USER_RESOURCES` 指向的目录（不进 Git）。其他机器自备 Blender 4.x。
- 先前的子 agent 已下载、可以复用的原始文件（在协调者本机，向协调者索取；用前重新核对原页面许可和 SHA-256）：ambientCG `Foam002_2K-JPG.zip`（约 32 MB，已解压出 Color / NormalGL / Opacity / Displacement）；MakeHuman CC0 包 `shirts01_cc0.zip`、`pants01_cc0.zip`、`skirts01_cc0.zip`、`poses02_cc0.zip`；MPFB 扩展的 `blender_user` 目录。`wt/` 下的 `assets`、`chars`、`water`、`arena`、`perf` worktree 没有任何未合并改动。

### 每张素材卡都要跑的检查

```
python tools/check_conventions.py
python -m pytest -q tools/tests                      # 含 58-01 的 CREDITS 检查、53-05 的导入设置检查
node --test tools/tests/asset_sync.test.mjs
node tools/sync_assets.mjs --check                   # 本卡加了锁定条目时
python tools/texture_imports.py --check              # 本卡加了纹理时（53-05）
python tools/test_assets.py --godot <Godot>          # 本卡加了 RSPbr 材质或 RSProps 键时
```

不做截图巡检；画面留给维护者最终试玩，PR 里写清没看过画面。

## 和 #39 的分工

照 [39-00](39-00-overview.md)“和 #58 的分工”：`RSArena`、`RSCrowd` 扩展、`RSWater` 这些 `core` 类和接口由 #39 的卡负责；本 issue 的卡只交素材，并通过以下**素材侧接口**接入，#39 的卡按名字取用：

| 素材侧接口 | 卡 | 使用者 |
|---|---|---|
| `RSProps` 键 `arena_*` / `hall_*`（灯、围栏、家具） | 58-10 | 39-15、39-16、39-18 |
| `RSPbr` id `shared:acg_fence006`（39-15 `FenceStyle.CHAINLINK` 可换用）、`shared:acg_net004a`、`shared:acg_rope001`、`shared:acg_foam002`、`shared:acg_rubber004` | 58-11 | 39-15、39-11、58-21、58-19 |
| 泡沫贴图文件 `res://assets/shared/materials/acg_foam002/acg_foam002_diff_2k.png`（`RSPbr.map_path("shared:acg_foam002", "diff", "2k", "png")`） | 58-11 | 39-11 的 `FOAM_TEXTURE`（见“需要维护者决定的”第 6 条） |
| 观众网格 `res://assets/shared/crowd/crowd_person.tres`（39-17 的 `RSCrowd.V2_MESH`：表面 0 衣服按实例色、表面 1 皮肤） | 58-12 | 39-17 |
| 后排 impostor 图集 `res://assets/shared/crowd/crowd_far_albedo.png` / `_normal.png` / `crowd_far.json` | 58-13 | 58-13 自带的 `RSCrowd` 远排入口 |
| 广告板图集 `res://assets/shared/signage/signage_boards.svg`（英文，默认）/ `signage_boards_zh.svg`（中文），4096 × 256，横向 4 等分，交给 39-15 `ad_boards(atlas, slots = 4)`；SVG 由 Godot 导入为 `Texture2D` | 58-31 | 39-15 |
| 共享旗面着色器 `res://shaders/banner_wind.gdshader`（横幅 / 旗 / 角旗） | 58-31 | 各项目 |
| 室内 HDRI 路径（`RSSkyPresets.hdri_path(id)`），填进 39-18 `RSArenaHall.Preset.hdri` | 58-16、58-17 | 39-18 |
| `RSSkyPresets` 室外预设 id | 58-17 | 新项目地图数据 |

素材没到时 #39 的卡用代码占位几何，接口不变。

## 需要维护者决定的

1. **阵容**（58-04 / 58-06）：avatar 0–3 用哪四个人（卡里提议沿用滑板 rider0–3 的身体、肤色、发型），迁移后篮球 / 滑雪里同一档案会换成这四个人。
2. **人物文件拆法**（58-04）：issue 原文是“`roster/<id>/body.gltf` + `outfits/<sport>/<outfit>.gltf` 运行时拼装”。MPFB 的衣服按每个身体单独拟合，身体还要按衣服删掉被遮住的部分，所以卡里改成“每个（项目, avatar）导出一个完整 `.gltf`，纹理放共享目录去重”。体积主要在纹理，去重效果相同。
3. **高尔夫树迁移**（58-14）：高尔夫 M1（#33）已合入，#26 是否允许现在移动 `golf/trees/`。
4. **新增 CC0 音效的许可规则**（58-28 / 58-29）：`game/assets/sfx/` 目前整体登记为“维护者声明 AI 原创 MIT”。卡里按“每个新 RSSfx id 一条前缀规则（如 `game/assets/sfx/punch_`）、放在 `game/assets/sfx/` 规则之前，证据指向新建的 `game/assets/sfx/CREDITS.md`”设计；另一个选择是新录音放子目录 `sfx/cc0/`，但那要改 `RSSfx` 的查找路径（框架区）。
5. **Freesound 下载**（58-29）：需要维护者本人登录下载清单里的原文件。
6. **泡沫贴图路径**：[39-11](39-11-water-surface.md) 写的 `FOAM_TEXTURE` 是 `.../acg_foam002/foam_color.png`，和 `docs/ASSETS.md` 的命名规则（`<名>_diff_<res>.png`，`RSPbr` 才能读）不一致。本 issue 的 58-11 按规则交付 `acg_foam002_diff_2k.png`；建议改 39-11 的常量（或改成 `RSPbr.map_path(...)` 现算），不在素材侧另放一份同内容文件。
7. **浪花**：39-12 的 `RSWaterWake.splash()` 先自带最小粒子，以后内部改调 58-26 的 `RSVfx.splash(parent, pos, strength)`（前三个参数与 39-12 相同；船首浪花另用 `RSVfx.spray()`）。这条只需要维护者知悉，不需要决定。
8. **虚构品牌名**（58-31）：广告板上的 3 个虚构赞助商名字由领卡人起，PR 里请维护者确认不撞真实品牌。
9. **缺来源的环境循环**（58-29）：`lake_amb`、`links_amb`、`park_amb` 在 issue 里没有具体 Freesound 页面，需要维护者搜索补充，或先不做。

## 维护者决定（2026-10-25）

1. 阵容：0–3 号沿用滑板 rider0–3。
2. 角色文件：按（项目, 人物）各导出一份完整 glTF，贴图共享。同意。
3. 58-14：现在可以把 `golf/trees/` 移到 `shared/vegetation/`；同一 PR 改好高尔夫的全部引用并跑 `tools/test_golf*.py`，不删任何高尔夫内容。
4. 新 CC0 音效许可：用“每个新 RSSfx id 一条前缀规则”方案，不改 `RSSfx.DIR`。
5. Freesound：需要登录，由用户自己下载 58-29 清单里的文件；下载前 58-29 保持待确认。
6. 泡沫贴图：39-11 的 `FOAM_TEXTURE` 已改为 RSPbr 命名 `acg_foam002_diff_2k.png`。
7. 58-31 虚构品牌名：在该卡的 PR 里检查，不能与真实品牌重名。
8. `lake_amb`、`links_amb`、`park_amb`：暂时跳过，等有 CC0 来源再补。
