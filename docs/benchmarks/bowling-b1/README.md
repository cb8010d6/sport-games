# B1 历史单次渲染短采样

[summary.json](summary.json) 保留四组统计和环境；[sha256.json](sha256.json) 登记原始字节哈希。逐帧 raw 已先私有归档并逐文件校验，再从 Git 索引移除，原始本地文件保留，未上传附件或 Release。本目录不是正式 benchmark 或性能门槛验收。

- before：`ac4a3ec01abcf05db82a13294ce960ec3b9aad7a`；after：`737232ee328486d514623bcedf176f95b87dfa30`。
- 官方 Godot 4.7.2、Forward+ / Vulkan、Radeon 780M、1600×900、quality=2、原生、VSync 关闭；隐藏桌面、交流电。
- 每组预热 5 秒、采样约 10 秒，只运行一次。间隔来自相邻实际 `frame_post_draw`，覆盖整帧及所有分屏。

平均 FPS 为 `1000 * N / sum(frame_ms)`；1% low 取最慢 `ceil(N * 0.01)` 个间隔，以 `1000 / mean(intervals)` 计算。帧数和间隔之和保留在摘要，整帧 CPU/GPU 指标为 null。

before 双人采样与其他工具工作重叠，后台负载未严格控制；缺少重复样本和长期稳态，不能把差值归因于 B1。正式六次基线与最新验收边界见 [B1 返工记录](../../BOWLING_B1_REVISION.md)。
