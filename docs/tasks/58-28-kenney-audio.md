# 58-28 Kenney Impact Sounds：出拳、挡格、木地板脚步

Issue #58 · P6 · F4（挡格 / 身体击打部分）、F9（木地板 / 硬地脚步部分）· 区域：素材（`game/assets/sfx/`）+ 工具配置（`tools/asset_policy.json`）

## 目标 / 范围外

**目标**：Kenney **Impact Sounds**（CC0，130 个 OGG，下载不需要登录）是 F 组里唯一能直接拿到的来源。从中挑选、用 `tools/blender/audio_tool.py` 裁剪和响度匹配，做出拳击、乒乓、网球需要的三组变体，并**第一次**为 `game/assets/sfx/` 建立 CC0 录音的来源记录方式（58-29 照此办理）。

| RSSfx id | 文件 | 来源（Kenney 原文件名以下载包为准） | 变体 |
|---|---|---|---|
| `punch` | `punch_0..3.wav` | `impactPunch_heavy_*`、`impactPunch_medium_*` | 4 |
| `block` | `block_0..2.wav` | `impactSoft_heavy_*` / `impactGeneric_light_*`（手套挡格的闷响） | 3 |
| `step_wood` | `step_wood_0..2.wav` | `footstep_wood_*` | 3 |
| `step_court` | `step_court_0..2.wav` | `footstep_concrete_*`（塑胶 / 硬地场地，网球、排球室内） | 3 |

`RSSfx._recording()` 已经会把 `<id>_0..7.wav` 组成 `AudioStreamRandomizer`，所以**不用改代码**。issue 原文把 `punch` 指向 Freesound kretopi 406464；本卡先用 Kenney 版本，58-29 的维护者下载到位后若听感更好再替换同名文件。

**范围外**：拳击铃（`bell`）、哨声、沙地脚步、所有循环音（58-29，需要 Freesound 登录）；`RSSfx.LOOPS`（本卡没有循环音）；任何项目接入。

## 先读

1. `tools/blender/audio_tool.py:1-20`（`decode` / `plot` / `cut` 的参数和 `levels.json` 的写法）
2. `game/core/sfx.gd:13-16`、`:55-95`（`DIR`、`LOOPS`、变体查找、`trim_db`）
3. `tools/asset_policy.json:120-128`（现有 `game/assets/sfx/` 规则：整体登记为维护者声明的 AI 原创 MIT）和 `tools/asset_policy.mjs:1-16`（前缀匹配、先匹配先生效、`shadowedRules`）
4. `docs/THIRD_PARTY.md:71-90`（Audio 一节；本卡在其后加一节）
5. `docs/ASSET_PROVENANCE.md:5-20`（35 个 AI 原创 WAV 的声明；新文件**不**计入这 35 个）
6. [58-00 概览](58-00-overview.md)“素材卡通用规则”和维护者问题 4

## 改动文件

- 新增 `game/assets/sfx/{punch_0..3,block_0..2,step_wood_0..2,step_court_0..2}.wav` + `.import`
- `game/assets/sfx/levels.json`（`audio_tool.py cut` 自动写入新 id 的回放增益；不手改其他 id）
- 新建 `game/assets/sfx/CREDITS.md`：逐文件一行（成品名 | Kenney 原文件名 | 包名 Impact Sounds | 包页面 <https://kenney.nl/assets/impact-sounds> | 作者 Kenney | `CC0-1.0` | 下载日期 | 包 ZIP SHA-256 | 原 OGG SHA-256 | 裁剪参数）
- 新建 `tools/blender/audio_specs/58-28.json`：本卡的 cut spec（源路径写成占位 `<download>/...`，不写本机绝对路径；58-29 照此存放）
- `tools/asset_policy.json`：在 `game/assets/sfx/` 规则**之前**加 4 条精确前缀规则（`game/assets/sfx/punch_`、`block_`、`step_wood_`、`step_court_`，`extensions: [".wav"]`，`license: "CC0-1.0"`，`evidence: "game/assets/sfx/CREDITS.md"`）
- `docs/THIRD_PARTY.md`：Audio 一节后加 “Audio - CC0 recordings (Kenney)” 一节（许可页链接、文件清单指向 `sfx/CREDITS.md`）；把 Audio 一节第一句的 “current 35 final WAVs” 保持原意，补一句“其后新增的 CC0 录音见下一节”
- `docs/ASSET_MANIFEST.json`（`node tools/publication_audit.mjs --write audit-output` 重新生成）
- 新建 `tools/tests/test_sfx_credits.py`：凡是被 CC0 规则匹配的 `sfx/*.wav` 都在 `sfx/CREDITS.md` 里有一行；CREDITS 里的每个成品文件都存在；规则匹配到的文件数 = CREDITS 行数

## 接口契约

- 文件名 = RSSfx id + `_N`，N 从 0 连续；id 只用上表 4 个（58-29 会新增其他 id，不重名）。
- 成品：16 位单声道 WAV（`audio_tool.py cut` 的输出格式），单个 ≤ 100 KB，合计 ≤ 1 MiB。
- 响度：用 `cut` 的 `"match"` 对齐到现有同类（`punch` / `block` 对齐 `board`，脚步对齐 `step`），削波的余量写进 `levels.json`；不改现有 id 的值。
- 许可规则：每个前缀只覆盖本卡的成品；`node --test tools/tests/asset_sync.test.mjs`（含 `shadowedRules` 检查）必须通过。

## 依赖与顺序

无依赖。先于 58-29 合入（58-29 照抄本卡的 CREDITS 格式和规则写法）。如果维护者对问题 4 选了“子目录 `sfx/cc0/`”方案，本卡改为该方案并在 PR 里说明（那需要框架改 `RSSfx.DIR`，先停下来提）。

## 验收

- `python -m pytest -q tools/tests`（含新测试）；`node --test tools/tests/asset_sync.test.mjs`；`node tools/publication_audit.mjs --write audit-output` 无 pending / unknown；`python tools/check_conventions.py`。
- `python tools/import_game.py --godot <Godot>` 无报错。
- PR 里列：每个成品的时长、峰值、新增字节；包 ZIP SHA-256。
- 听感不在 PR 里验证（写明“未试听于游戏内”），留给维护者试玩。

## 不要做

- 不提交 Kenney 原 ZIP / OGG 或未用的文件。
- 不改现有 35 个 WAV、不改它们的许可规则。
- 不改 `game/core/sfx.gd`。
- 下载页如果要求登录、付款或“捐赠后下载”之外的操作，停下来报告。

## 预计规模

测试约 60 行；JSON / 文档约 60 行；素材 ≤ 1 MiB。
