# 57-03 RSReplay 录制限频

Issue #57“每帧内存分配”第 2 条 · 区域：框架（`game/core/replay.gd`）+ 项目（滑板、滑雪、篮球各一处调用）

> 开工前提：维护者确认这一项仍属 #57（维护者 10-25 的评论里问过，清单没点名）。

## 目标 / 范围外

**目标：** 现在滑板、滑雪、篮球每个渲染帧给每个玩家新建一个回放帧（字典 + 数组），缓冲按秒数裁剪，所以帧率越高分配越多（200 FPS 时每人约 1300 帧）。改为按固定频率（默认 60 Hz）录制：不到时间就不建字典；事件类字段在跳过的帧之间累加，不丢事件。回放观感（插值）不变。

**范围外：** 环形缓冲 / 换容器类型（`RSReplay.reset(clip)` 和项目都按 `Array` 用，改容器面太大）；回放镜头、片段选择；篮球 `near` 数组（57-04）。

## 先读

1. `game/core/replay.gd`（全文：`record`、`since`、`duration`、`reset`、`sample`）
2. `docs/ARCHITECTURE.md` 第 4 节“回放帧……”一段（帧格式与采样契约）
3. `game/scenes/skate/skate_game.gd` 628-645（`_record`：`imp` 是“自上次读取以来”的累加值，记录后清零；`r.post` / `r.pend` 的尾段逻辑）
4. `game/scenes/ski/ski_game.gd` 744-758（同样的 `_record`，后面还有 `_keep_clip`、`air_from`）
5. `game/scenes/basketball/basketball_game.gd` 805-820（`balls` 快照）
6. `game/tests/test_replay.gd` 的 math 部分（`python tools/test_replay.py --math-only`）

## 改动文件

- `game/core/replay.gd` —— 框架区
- `game/scenes/skate/skate_game.gd`、`game/scenes/ski/ski_game.gd`、`game/scenes/basketball/basketball_game.gd` —— 项目区，各改 `_record` 的开头几行
- `game/tests/test_replay.gd`：追加 math 用例
- `docs/ARCHITECTURE.md` 第 4 节回放一段补一句“录制按 `RSReplay.RECORD_HZ` 限频” —— 框架区

## 接口契约

```gdscript
# game/core/replay.gd
const RECORD_HZ := 60.0

## 距 frames 最后一帧已过 1 / hz 秒（允许 1e-4 s 误差），或 frames 为空时返回 true。
## 项目先调它，返回 false 就不建帧字典、直接返回。
static func due(frames: Array, t: float, hz := RECORD_HZ) -> bool

## record(frames, frame, window) 签名和语义不变。
```

项目侧改法（以滑雪为例，滑板相同；篮球只需把 `record` 和 `pend.append` 包进 `due` 判断）：

```gdscript
func _record(r: Racer, dt: float) -> void:
	var rig := r.sk.rig
	if RSReplay.due(r.rec, _clock):
		RSReplay.record(r.rec, {...}, ...)   # 帧内容原样
		rig.impacts = 0.0                    # 只在真正记录时清零，跳过的帧里继续累加
		if r.post >= 0.0:
			r.pend.append(r.rec.back())
	if r.post >= 0.0:                        # 尾段计时、_keep_clip、air_from 等其余逻辑每帧照常执行
		r.post -= dt
		if r.post < 0.0:
			_keep_clip(r)
	...
```

要点：所有“自上次读取以来”的字段（滑板 / 滑雪的 `imp`）只在真正记录时读取并清零；尾段（`post` / `pend`）的计时按真实时间走，不能因为跳帧变长。篮球 `balls` 是快照，直接限频即可。

## 依赖与顺序

需要维护者先确认范围。与 57-04 无关（都改 `basketball_game.gd` 但位置不同，可并行）。

## 验收

- `test_replay.gd` math 部分追加：
  - `due`：空数组 true；距上一帧 1/60 s 前 false、之后 true
  - 用 240 FPS 的时间序列调用 `due + record` 10 秒：帧数约 600 + 1（不是 2400）；`sample()` 的插值结果与 60 FPS 下逐帧录制的结果一致（误差 < 1e-4）
- 命令：`python tools/test_replay.py --godot <Godot> --math-only`，`python tools/smoke_game.py <Godot> --project game`，`python tools/check_conventions.py`
- 回放观感不在本卡验收（用户最后试玩）。

## 不要做

- 不改 `RSReplay.sample()` / `reset()` 的语义。
- 不改帧字典里的字段。
- 不改回放片段长度常量（`CLIP_MAX`、`PRE_ROLL` 等）。

## 预计规模

`replay.gd` 约 +8，三个项目各约 +5 / −2，测试约 40 行，文档 1 句。
