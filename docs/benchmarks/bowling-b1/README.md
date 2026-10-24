# B1 单次渲染短采样

这些 JSON 是有限前后对照的原始有效样本，不是正式 benchmark 或性能门槛验收。没有删去慢帧或改写数据。

- before：`ac4a3ec01abcf05db82a13294ce960ec3b9aad7a`。
- after 运行时代码：`737232ee328486d514623bcedf176f95b87dfa30`。
- Godot `4.7.2.stable.official.ed1daf0bf`，Forward+ / Vulkan 1.4.349，AMD Radeon 780M Graphics。
- 原生 1600×900，quality=2，upscale=0，max_fps=0，VSync 关闭，隐藏桌面，交流电状态全程为 1。
- 每组预热 5 秒、采样约 10 秒，仅一次。`samples_frame_ms` 是相邻实际 `frame_post_draw` 的毫秒间隔，覆盖整个窗口及所有分屏，不是单个视口的 FPS。

平均 FPS 为 `1000 * N / sum(samples_frame_ms)`。1% low 将间隔从慢到快排序，取最慢的 `ceil(N * 0.01)` 项，以 `1000 / mean(这些间隔)` 计算。`duration_ms` 是间隔之和，`frames` 为间隔个数；CPU / GPU 整帧指标为 `null`。

| 分屏 | 改动前原始样本 | 改动后原始样本 |
|---|---|---|
| 双人 | [before-p2.json](before-p2.json) | [after-p2.json](after-p2.json) |
| 四人 | [before-p4.json](before-p4.json) | [after-p4.json](after-p4.json) |

后台负载未严格控制：before 双人采样期间，工具测试尾声 / 清理可能仍在同机运行。缺少重复样本、完整回合与长期稳态，不能把样本差值全部归因于 B1，也不能据此确定稳定回归。这是 #22 正式工具合入前的历史样本；返工版本将使用现有工具重新测量，不能用本目录数据代替。完整设置、观察值与截图分组见 [B1 记录](../../BOWLING_B1_ENVIRONMENT.md)。
