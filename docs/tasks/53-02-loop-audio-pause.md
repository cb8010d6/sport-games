# 53-02 滑手 / 滑雪者静音的循环音暂停混音

Issue #53 · 分项 1.7 · 区域：项目（`game/scenes/skate/`、`game/scenes/ski/`）

## 目标 / 范围外

**目标**：每名滑手常驻 4 个循环播放器（滚轮、金属滑杆、台沿滑杆、风声），每名滑雪者 3 个（刻滑、侧滑、风声）。它们静音时（音量压到 −60 dB 以下）仍在混音。改成：音量低于 `SILENT_DB` 时 `stream_paused = true`，音量回到阈值以上时自动恢复。4 人分屏、全员静止时，活跃循环从 4 × 4 + 4 × 3 降到 0。

**范围外**：场景级的观众 / 环境循环（`ski_game.gd` 的 `_crowd`、`_ambience` 等）；`RSSfx` 本身（框架区）；任何音量曲线、音色的调整。

## 先读

1. `game/scenes/skate/skater.gd:107-110`（4 个播放器）、`:125-138`（`_ready` 建循环、`quiet()`）、`:1029-1045`（`_update_audio`，每帧 lerp 音量）
2. `game/scenes/ski/skier.gd:84-86`、`:100-111`（`_ready`、`quiet()`）、`:670-684`（音量更新）
3. `game/core/sfx.gd:113-120`（`RSSfx.loop()`：建好就 `play()`，音量 −80 dB）
4. `game/tests/test_perf.gd:158-196`（建真实滑手 / 滑雪者、缺模型就跳过的写法）

## 改动文件

- `game/scenes/skate/skater.gd`
- `game/scenes/ski/skier.gd`
- `game/tests/test_perf.gd`（加一个检查函数）

## 接口契约

两个类各自加同样的一组成员（两个项目不能互相引用，ARCH-GAME，所以各写一份，约 10 行）：

```gdscript
const SILENT_DB := -59.0   ## 低于这个音量的循环暂停混音（lerp 的目标是 -60 / -74 dB，一定会穿过它）

func _set_loop_db(a: AudioStreamPlayer, db: float) -> void
	## a.volume_db = db；a.stream_paused = db <= SILENT_DB。所有改循环音量的地方都改走这个函数。

func active_loops() -> int
	## 本角色当前没有暂停的循环播放器数量（测试和 PR 前后对比用）。
```

- `quiet()` 改为对每个循环调用 `_set_loop_db(a, -80.0)`，结果是全部暂停。
- `_update_audio()`（滑板）和滑雪的音量更新里，`x.volume_db = lerpf(x.volume_db, target, k)` 改为 `_set_loop_db(x, lerpf(x.volume_db, target, k))`；`pitch_scale` 的赋值不变。
- 暂停后再恢复会从暂停处继续播放，循环音无所谓位置，不需要处理。
- 不新建、不删除任何 `AudioStreamPlayer`（ARCH-AUDIO 只允许 core 创建）。

## 依赖与顺序

无依赖。和 53-03（也改 `ski_game.gd`，不改 `skier.gd`）没有文件冲突。

## 验收

- `game/tests/test_perf.gd` 新增 `_idle_loops()`：模型不存在就跳过（同 `_riders_at_30fps()` 的判断）；建一个 `RSSkater` 和一个 `RSSkier`，`await` 一帧后：
  - 记录建好时的 `active_loops()`（4 和 3）；
  - 调 `quiet()` 后 `active_loops() == 0`；
  - 用 `RSSkateBot` / `RSSkiBot` 驱动 60 帧（照 `_riders_at_30fps()`），断言至少有一个循环恢复（`active_loops() > 0`），证明会自动恢复；
  - 打印 `RS_PERF_LOOPS: idle skater 4 -> 0, idle skier 3 -> 0`。
- 命令：`python tools/test_perf.py --godot <Godot>`；`python tools/check_conventions.py`；`python tools/smoke_game.py <Godot> --project game`。
- PR 里写清：混音 CPU 收益没有单独测量；实际听感（起步时滚轮声是否有可感知的延迟）留给最终试玩。

## 不要做

- 不改 `RSSfx.loop()` 或给 `RSSfx` 加新函数（框架区）。
- 不改阈值以外的音量数值。
- 不把两个类的公共代码抽到 `game/core/`（量太小，不值得改框架）。

## 预计规模

两个脚本各约 +15 / −8 行，`test_perf.gd` 约 +40 行。
