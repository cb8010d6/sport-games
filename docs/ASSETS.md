# 素材下载与仓库内容

本项目不使用 Git LFS。源码和本地生成的成品通过普通 Git 分发；可以从原站恢复的
Poly Haven 二进制文件不进 Git，由脚本下载。现有本机文件不会因为忽略规则被删除。

## 克隆后的第一步

安装 Node.js 20 或更新版本，然后在仓库根目录运行：

```sh
node tools/sync_assets.mjs
node tools/sync_assets.mjs --check
```

通过后使用 Godot 打开 `game/project.godot`。不需要 Blender、npm 安装或 Git LFS。
中枢的 Python 环境仍按 [开发说明](DEVELOPMENT.md) 安装。

脚本处理 58 组 Poly Haven 素材、222 个文件，当前总量 799,958,793 字节，约 763 MiB。
已有且 SHA-256 一致的文件直接跳过；中断后重跑只会下载缺失或失败的文件。
单个未完成文件会重新下载，不支持该文件内部的 HTTP 断点续传。

```sh
node tools/sync_assets.mjs --list                # 离线查看来源、分组与大小
node tools/sync_assets.mjs --only clean_asphalt  # 只同步一组
node tools/sync_assets.mjs --check               # 离线校验全部下载文件
```

本地文件有修改时默认不覆盖。如果确认要用锁定版本替换，可显式添加 `--force`。
下载器不执行远端脚本、不解压任意压缩包，不自动更新到原站的新版本；下载失败会返回非零退出码。

## 哪些文件在哪里

| 内容 | 分发方式 | 来源与许可 |
|---|---|---|
| Poly Haven 原始纹理、HDR 天空和模型 buffer | 原站下载，Git 忽略 | 原站 CC0；逐文件记录在 `tools/assets.lock.json` |
| glTF 描述、Godot `.import` / `.uid`、来源清单 | 普通 Git | 保留来源与可移植配置 |
| 16 个角色及配套纹理（包含开发中的高尔夫） | 普通 Git | Blender/MakeHuman 系统素材生成，CC0；生成脚本在 `tools/blender/` |
| 6 组树木图集 | 普通 Git | 从 Poly Haven CC0 模型烘焙 |
| 4 个减面模型的 buffer 和 1 张加工纹理 | 普通 Git | 从 Poly Haven CC0 模型加工；17 张未改变的纹理直接引用原站同步文件 |
| 手柄模型、35 个成品音效、3 张贴花 | 普通 Git | 项目提供者确认 AI 原创，按项目 MIT；见 [来源声明](ASSET_PROVENANCE.md) |
| 三首背景 / 胜利音乐 | 普通 Git | 本次贡献的乐谱与程序合成，无外部采样，输出 CC0；见 [生成记录](../game/assets/music/CREDITS.md) |
| 六张主菜单项目预览 | 普通 Git，约 1.06 MiB | 从实际项目相机导出，MIT 代码与 CC0 场景素材；见 [生成记录](../game/assets/previews/CREDITS.md) |
| 下载缓存、工具、证书、日志和私人配置 | 仅本机，Git 忽略 | 不分发 |

以上 166 个角色/树木/减面生成文件约 673 MiB，最大文件 `skier1.glb` 约 22.3 MiB。
当前待发布游戏素材没有超过 50 MiB 的单文件，也没有超过 GitHub 普通 Git 的 100 MiB
单文件限制。总大小是未压缩文件之和，不代表首次克隆的实际传输量；后续频繁修改大文件会累积历史。

## 固定版本与隐私

`tools/assets.lock.json` 为每个下载文件记录相对路径、原站资产 ID、格式/分辨率、来源页、许可、
字节数、原始 SHA-256 和最终 SHA-256。下载器通过 `https://api.polyhaven.com/files/<资产ID>`
找到对应的官方文件 URL，校验成功后再安装到项目目录。下载和重定向只允许 Poly Haven HTTPS 域名。

一张沙地法线纹理的原文件带有电脑上的处理路径。脚本会清理 EXIF Software、EXIF ImageHistory
和 IPTC OriginatingProgram 中的路径记录，保留其他字段与原始图像编码数据；最终结果也必须
符合清单中的 SHA-256，避免重新下载时把路径带回来。

原站如果替换文件、移除旧格式或暂时不可用，脚本会报错，保留原有本机文件。维护者应审核新来源、
更新清单和 glTF 引用并验证游戏，再通过 PR 发布。不要直接绕过哈希检查。

Powered by Poly Haven：<https://polyhaven.com>。使用自定义 User-Agent 标识项目，保留
[API 服务条款](https://github.com/Poly-Haven/Public-API/blob/master/ToS.md) 要求的来源提示；
不表示官方背书。素材许可见 <https://polyhaven.com/license>。

## 修改素材的 PR

生成成品没有原站同名下载文件，直接修改并提交生成结果即可；重新生成时附使用的 Blender/MPFB
版本、脚本与参数。现有生成工具可以继续使用，普通玩家和一般代码贡献者无需安装这些工具。
对外部下载文件的加工结果应另存为生成文件，记录加工方式，避免原站同步覆盖修改。

下载器验证：

```sh
node --test tools/tests/asset_sync.test.mjs
```

2026-10-21 已从 Poly Haven 实际下载全部 222 个文件，随后离线校验全部通过，失败数为 0。
下载器另有模拟网络、损坏文件和元数据脱敏测试。原站可用性会变化，CI 每次打包都会重新校验。

## 共享素材库

规划见 issue #58。两个及以上项目会用的成品与加工件放 `game/assets/shared/`（普通 Git）；
只有一个项目用、将来大概率也只有它用的放 `game/assets/<sport_id>/`。拿不准时放 `shared/`。
项目代码不得引用别的项目目录，需要共用就先搬进 `shared/`。

### 目录

```
game/assets/
  polyhaven/                 # 不变：Poly Haven 原始文件（同步下载）
  shared/                    # 共享成品与加工件，CREDITS.md 是总索引
    characters/              # roster/<avatar_id>/、outfits/<sport>/、textures/（去重）
    crowd/  arena/  vegetation/  vfx/  signage/
    equipment/<item>/        # racket_tennis/、paddle_tt/、ball_*/、net/ …
    materials/<来源>_<id>/   # 非 Poly Haven 材质：acg_net004a/ …
  <sport_id>/                # 仅本项目使用
  sfx/ music/ fonts/ previews/ decals/ models/   # 不变
```

每个子目录都有 `CREDITS.md`（模板已建好）。现有 `characters/`、`golf/trees/` 在 #58 P1 / P2
迁移，迁移 PR 只做 `git mv` + 路径与记录更新，不同时改内容。

### 命名与代码入口

- 全部小写 ASCII `snake_case`，格式 `<类别>_<名称>[_<变体>]`：`arena_bleacher_outdoor`、`eq_racket_tennis`、`vfx_spray_atlas`。
- 纹理沿用 Poly Haven 命名：`<id>_diff_<res>.jpg`、`<id>_nor_gl_<res>.jpg`、`<id>_arm_<res>.jpg`；
  带透明的 diff 用 PNG。外部材质加工时改成同一套命名。
- 材质用 `RSPbr.maps / surface / standard`：Poly Haven 写 ID（`"clean_asphalt"`），共享材质写
  `"shared:<来源>_<id>"`（读 `res://assets/shared/materials/<来源>_<id>/`）。不要在项目里手拼路径。
- 批量道具用 `RSProps.place`。`PREFABS` 键名是 `<套件>_<名称>`，套件：`urban`（街景）、`nature`
  （岩石植被）、`beach`、`marina`、`arena`、`hall`（室内场馆）。glTF 路径以 `shared:` 开头时读
  `res://assets/shared/`。
- 音效 ID 用动作 / 物体（`racket_hit`），确实专属才加项目前缀（`pp_table`）；变体用 `_0`、`_1`。

### 导入设置

| 类型 | 设置 |
|---|---|
| 颜色 / ARM 纹理 | `compress/mode=2`（VRAM），`mipmaps/generate=true`；ARM 不当 sRGB |
| 法线 | `compress/mode=2`，`compress/normal_map=1`，OpenGL 方向（`nor_gl`） |
| 人物纹理 | 同上，`process/size_limit=2048`；眼睛 / 睫毛 / 眉毛 ≤ 1K |
| HDRI | 室外可见天空 4K；室内或只做反射 2K |
| 模型 | `meshes/generate_lods=true`、`create_shadow_meshes=true`、`ensure_tangents=true`；不导入无用动画；纹理外部引用 |
| 音频 | WAV 单声道（环境循环可立体声），裁掉首尾静音；循环 ≤ 1.6 MB，一次性 ≤ 300 KB |

重复物体用 `RSProps` / MultiMesh、同一材质。三角面：主角器材 ≤ 5k（水上摩托 ≤ 15k），场边道具
≤ 10k，人物 LOD0 ≤ 30k，前排观众 ≤ 3k / 人；40 m 外的植被 / 观众 / 远景用 impostor；高面数
扫描模型先减面或烘焙再入库。

### 每个新项目的预算

| 项目 | 上限（高画质） |
|---|---|
| 场地材质 | ≤ 12 组 2K，≤ 2 组 4K 主表面 |
| HDRI | 每张地图 1 张；室外 4K / 室内 2K |
| 人物 | 4 名选手 + ≤ 2 名 NPC；每人新增服装纹理 ≤ 2 × 2K |
| 道具 / 器材 / 观众 / 特效 | 合计 ≤ 120 MB 显存 |
| 合计显存 | ≤ 550 MB（`RENDER_VIDEO_MEM_USED` 实测，写进 PR） |
| 新增 Poly Haven 下载 | ≤ 120 MiB |
| 新增 Git 成品 | ≤ 40 MiB，单文件 ≤ 20 MiB |

超出要在 PR 里写明理由。

### 来源记录

| 来源 | 放哪 | 必须更新 |
|---|---|---|
| Poly Haven | `polyhaven/`（不进 Git） | 用同步工具生成 `tools/assets.lock.json` 条目（不手写哈希）；`polyhaven/CREDITS.md` 追加一行；本文的组数 / 文件数 / 字节数 |
| 其他 CC0（ambientCG、Kenney、Freesound、OpenGameArt、MakeHuman 社区包） | 加工后进 `shared/...` 或 `sfx/` | 所在目录 `CREDITS.md` 逐文件写原始页面、资产 ID、作者、许可、下载日期、原始文件名与 SHA-256、加工步骤；重新生成 `docs/ASSET_MANIFEST.json`；`docs/THIRD_PARTY.md` 加该来源一节 |
| 项目脚本生成（Blender 器材、人物、impostor） | `shared/...` | 脚本放 `tools/blender/`；CREDITS 写输入素材、Blender / MPFB 版本、命令与参数；全 CC0 输入记 `CC0-1.0`，含原创几何 / 着色器记 `MIT AND CC0-1.0` |
| AI 生成 | 原则上不新增 | 确需使用时按 [来源声明](ASSET_PROVENANCE.md) 单独列出 |

`tools/asset_policy.json` 把 `game/assets/shared/` 登记为 `CC0-1.0`。`MIT AND CC0-1.0` 的子目录要加
一条更窄的前缀规则并放在它之前（先匹配的规则生效，`asset_sync.test.mjs` 会检查被遮住的规则）。
ambientCG 只提供 ZIP，下载器不解压：少量材质手动下载、只留需要的贴图、改成 Poly Haven 命名后提交
1K / 2K 成品。不使用 CC-BY / CC-BY-SA / “royalty free” / 来源不明的素材；真实商标去掉或换成虚构标志。

### 暂未使用的 Poly Haven 素材

以下 9 组已同步但还没有场景使用，用途写在 `tools/assets.lock.json` 对应条目的 `purpose` 字段里；
M4 打包前仍无人使用的再从锁定清单移除：

| 素材 | 分配 |
|---|---|
| `painted_plaster_wall`、`white_plaster_02`、`red_brick`、`painted_metal_shutter` | #58 C6 室内场馆外壳（#25 翻新也可用） |
| `sparse_grass` | #25 射箭场草地；#58 C8 场边绿化 |
| `WetFloorSign_01` | #58 A7，给保龄球馆（#25）；`RSProps` 键 `hall_wet_floor_sign` |
| `concrete_cat_statue`、`rollershutter_window_01`、`spray_paint_bottles` | #25 翻新街景；`RSProps` 键 `urban_cat_statue`、`urban_shutter_window_01(_graffiti)`、`urban_spray_paint(_dirty)` |
