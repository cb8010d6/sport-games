# 58-29 Freesound 音效与环境循环（维护者下载后加工）

Issue #58 · P6 · F1–F3、F4（铃）、F5–F8、F9（沙地）· 区域：素材（`game/assets/sfx/`）+ 框架（`game/core/sfx.gd` 只改 `LOOPS` 一行）

**状态：待领（58-28 合并后再开工）。** 上表 17 个原文件维护者已全部手动下载（2026-10-25/26），许可页面均已确认 CC0-1.0，2026-10-27 逐个核对了文件头和大小并记下 SHA-256。原文件放在维护者本机下载缓存（不进 Git），领卡的代理向维护者要缓存路径；同目录的 `download-manifest.json` 有每个文件的声音 ID、下载日期、字节数和 SHA-256，`SHA256SUMS.txt` 是 `sha256sum` 格式。412863 是 `.ogg`，其余是 WAV；457149（约 500 MB）只是备选，可以不用，`decode` 会把整个文件读进内存。

## 维护者下载清单

| 组 | Freesound 页面 | issue 中的许可状态 | 用来做 |
|---|---|---|---|
| F1 | <https://freesound.org/people/giddster/sounds/414461/> | 已逐页确认 CC0 | `pp_hit`、`pp_table` |
| F2 | <https://freesound.org/people/kletton97/sounds/710041/> | 已确认 | `racket_hit` |
| F2 | <https://freesound.org/people/jamesdrake89/sounds/662266/> | 仅搜索结果 | `racket_hit`（发球）备选 |
| F2 | <https://freesound.org/people/gprosser/sounds/412863/> | 仅搜索结果 | `tennis_bounce` 备选 |
| F3 | <https://freesound.org/people/Luisa_Sanchez/sounds/813420/> | 已确认 | `vb_spike`、`vb_bump` |
| F3 | Luisa_Sanchez 816991 | 仅搜索结果 | `vb_bump` 备选 |
| F4 | <https://freesound.org/people/kretopi/sounds/406464/> | 已确认 | `punch`（若比 58-28 的 Kenney 版好，替换同名文件） |
| F4 | <https://freesound.org/people/craigsmith/sounds/438626/> | 已确认 | `bell` |
| F5 | <https://freesound.org/people/SpliceSound/sounds/218318/> | 已确认 | `whistle` |
| F6 | <https://freesound.org/people/mglennsound/sounds/678544/> | 已确认 | `crowd_cheer`（循环）、`crowd_ooh` |
| F6 | <https://freesound.org/people/fattirewhitey/sounds/381411/> | 仅搜索结果 | `hall_amb`（循环） |
| F7 | <https://freesound.org/people/vero.marengere/sounds/524524/> | 已确认 | `splash` |
| F7 | <https://freesound.org/people/wjauch/sounds/212441/> | 已确认 | `engine_jetski`（循环） |
| F8 | <https://freesound.org/people/Anya_Media/sounds/872757/> | 已确认 | `waves_amb`、`beach_amb`（循环） |
| F8 | <https://freesound.org/people/Benbojangles/sounds/457149/> | 已确认（原文件 502 MB，可不下） | `waves_amb` 备选 |
| F9 | <https://freesound.org/people/YannSauvin/sounds/777609/> | 仅搜索结果 | `step_sand`、`sand_thud` |
| F9 | felix.blume 705743 | 仅搜索结果 | `step_sand` 备选 |

`lake_amb`、`links_amb`（高尔夫）、`park_amb` 在 issue 里没有具体页面：维护者在 Freesound 用 CC0 过滤搜索后补进这张表，或决定先不做（这三条可以留空，不阻塞本卡）。

维护者交给代理的东西：每个文件的本机路径、声音 ID、下载日期、原文件 SHA-256（`sha256sum` 输出即可）。

## 目标 / 范围外

**目标**：把上表原文件加工成 `game/assets/sfx/` 下的成品 WAV，循环音加入 `RSSfx.LOOPS`，来源记录照 58-28 的格式。

**范围外**：项目接入（播放时机、按油门调音高等由 #60–#64 各项目做）；`RSSfx` 合成后备（引擎声合成另开卡）；音乐。

## 先读

1. [58-28](58-28-kenney-audio.md)（CREDITS 格式、许可规则写法、`test_sfx_credits.py`）——本卡照抄
2. `tools/blender/audio_tool.py:1-20`（`decode` / `plot` / `cut`；循环 `"loop": true` 会把尾部交叉淡入到头部；`"match"` 响度匹配；`"grains"` 颗粒纹理）
3. `game/core/sfx.gd:13-16`、`:70-95`（`LOOPS` 决定 `loop_mode`；变体 `<id>_N.wav`）
4. `game/core/game_module.gd:24`（`ambience` 字段：项目主环境循环的 RSSfx id）
5. `tools/asset_policy.json:120-128`
6. [58-00 概览](58-00-overview.md)“素材卡通用规则”

## 改动文件

- 新增 `game/assets/sfx/<id>[_N].wav` + `.import`（id 见下）
- `game/assets/sfx/levels.json`（`cut` 自动写入）
- `game/assets/sfx/CREDITS.md`（追加行；Freesound 页面 URL、声音 ID、作者、许可 `CC0-1.0`、下载日期、原文件名和 SHA-256、cut 参数）
- 新建 `tools/blender/audio_specs/58-29.json`（本卡的 cut spec，源路径写成占位 `<download>/...`，不写本机绝对路径）
- `tools/asset_policy.json`：每个新 id 一条精确前缀规则，放在 `game/assets/sfx/` 规则之前（写法同 58-28）
- `game/core/sfx.gd`（**框架区**，只改第 16 行 `LOOPS`）：追加 `"crowd_cheer", "hall_amb", "engine_jetski", "waves_amb", "beach_amb"`，以及实际做出来的 `"lake_amb", "links_amb", "park_amb"`
- `docs/THIRD_PARTY.md` 加 “Audio - CC0 recordings (Freesound)” 一节；`docs/ASSET_MANIFEST.json` 重新生成

## 接口契约

| id | 变体 | 循环 | 预算 |
|---|---|---|---|
| `pp_hit`、`pp_table` | 各 3–4 | 否 | 单个 ≤ 60 KB |
| `racket_hit`、`tennis_bounce` | 各 3–4 | 否 | ≤ 80 KB |
| `vb_spike`、`vb_bump`、`sand_thud` | 各 2–3 | 否 | ≤ 100 KB |
| `bell`、`whistle` | 1–2 | 否 | ≤ 300 KB |
| `crowd_ooh` | 2 | 否 | ≤ 300 KB |
| `splash` | 3 | 否 | ≤ 200 KB |
| `step_sand` | 3 | 否 | ≤ 60 KB |
| `crowd_cheer`、`hall_amb`、`waves_amb`、`beach_amb`、`lake_amb`、`links_amb`、`park_amb` | 1（无 `_N`） | 是 | 每条 ≤ 1.6 MB（与 `city_amb.wav` 同级，约 18 s） |
| `engine_jetski` | 1 | 是 | ≤ 400 KB（取稳态转速的一段，项目按油门改 `pitch_scale`） |

- 循环必须用 `cut` 的 `"loop": true` 做无缝接缝；`RSSfx` 播放时不再做交叉淡入（`XFADE` 只用于合成音）。
- `id` 不和现有 id、58-28 的 id 重名；`splash` 是声音 id，与 `RSVfx.splash`（58-26 粒子）同名但不同模块，不冲突。
- 本卡合计新增 Git ≤ 14 MiB（7 条循环约 11 MiB + 一次性音效）；超出时缩短循环，不降采样到 22 kHz 以下。

## 依赖与顺序

依赖维护者下载（上表）和 58-28（格式先定）。可以按维护者到货顺序拆成两个 PR：先一次性音效（F1–F5、F7 水花、F9），再循环音（F6–F8 + `LOOPS` 改动）；两个 PR 都按本卡验收。

## 验收

- `python -m pytest -q tools/tests`（`test_sfx_credits.py` 覆盖新文件）；`node --test tools/tests/asset_sync.test.mjs`；`node tools/publication_audit.mjs --write audit-output` 无 pending；`python tools/check_conventions.py`；`python tools/import_game.py --godot <Godot>`；`python tools/test_game.py --godot <Godot>`（`LOOPS` 改动后壳测试仍 `RS_SHELL_TESTS: 0 failures`）。
- PR 里列：每个成品时长、峰值、字节；每条循环的接缝位置；`audio_tool.py plot` 生成的波形图**不提交**，只在本机检查接缝。
- 未在游戏内试听，PR 里写明。

## 不要做

- 代理不登录 Freesound、不用任何账号下载；不提交原文件。
- 不用许可不是 CC0 的声音（CC-BY 也不用）。
- 不改 `RSSfx` 的其他代码；不改现有 id 的 `levels.json` 值。

## 预计规模

代码 1 行；spec / 规则 / 文档约 150 行；素材约 10–14 MiB。
