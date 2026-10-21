# NVIDIA RTX 篮球实验

仅位于 `experiment/nvidia-rtx`，与标准 Godot 4.7.2 发行隔离。
固定 [NVIDIA-RTX/godot](https://github.com/NVIDIA-RTX/godot/tree/135dff3887a3d2ccf45cafbd9bdffa7b718e1e76)
的 `135dff3887a3d2ccf45cafbd9bdffa7b718e1e76`（`nvidia-pt-dlss`，版本 4.8.dev）。
不要用标准版导出模板打包 fork 工程；不要用 fork 编辑器覆盖唯一的标准开发副本。

实验场景继承现有篮球游戏，无玩法副本。通过反射设置 fork 的 `Environment.pathtracing_enabled`、
`pathtracing_denoiser=PT_DENOISER_DLSS_RAY_RECONSTRUCTION`、1 sample/pixel，
所有玩家 SubViewport 使用 DLSS 质量比例 0.66。主窗口也应用相同设置，帧生成关闭。
光栅对照关闭光追，原生分辨率、不启用 MSAA/FXAA；两者都取消帧率上限和 VSync。
这比较的是两套实用配置，不是相同内部渲染分辨率下的纯算法对照。

## 运行

取得上述提交的 NVIDIA 引擎，并按其官方构建文档编译；SConstruct 的 `use_streamline` 默认为 true，
但仍应检查目标平台支持、Streamline 运行库、NVIDIA 驱动与 SDK 许可/分发要求。
本分支不分发 NVIDIA SDK 或来源不明的引擎二进制。

```sh
node tools/sync_assets.mjs
<NVIDIA-Godot> --headless --path game --editor --import
python tools/benchmark_rtx.py <NVIDIA-Godot>
```

默认 Vulkan，可传 `--driver d3d12` 对照。两张篮球地图分别跑 1、2、4 人，
每项预热 12 秒、采样 20 秒，结果写入被忽略的 `audit-output/rtx`。
报告包含引擎版本、GPU 型号、平均 FPS、帧时间 p50/p95 和驱动估算显存；不包含主机名、用户路径或设备地址。
它不测量手机到画面的输入延迟。必须保持分辨率、画质和驱动一致，并保存驱动版本和实机截图。

## 验收与限制

普通 Godot、无光追设备、无 RTX GPU、错误引擎提交或 headless 光追请求会明确失败，
不会自动回退后输出假 RTX 帧率。属性配置成功也不等于 DLSS RR 在驱动中实际生效，
仍需打开 fork 的 DLSS RR 调试视图确认，检查日志和画面。

实机重点检查球员蒙皮、toon/PBR 混合材质、篮网、透明物、天空、MultiMesh 和分屏。
分别记录 1/2/4 人的显存、帧时间、闪烁、拖影和手感；多人明显退化时保留标准渲染作为默认。
不要用帧生成 FPS 代替输入响应测试。

2026-10-21 的执行环境没有 GPU，也没有官方预编译的该 fork Release。
本次只验证实验入口的脚本兼容性、标准引擎拒绝路径及 API 与固定源码一致性；
没有声称完成 NVIDIA 引擎编译、RTX 画面或性能验收。标准发行工作流仍只用官方 Godot。
