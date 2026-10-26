# NVIDIA RTX 实验

本分支将固定游戏基线 `209897f4573208e02df52c4c929731a27d3527b1` 与已有的
`experiment/nvidia-rtx` 合并，保留 `e623451` 的篮球实验和 `e3f954c` 的验证记录。
没有用旧实验分支覆盖新框架、项目、素材或体感协议。标准发行仍使用官方 Godot 4.7.2；
实验目标是 `experiment/nvidia-rtx`，不向 `dev` / `main` 推送。

当前实验引擎来源与版本见 [rtx_engine.json](../tools/rtx_engine.json)，固定个人 fork
`cb8010d6/godot` 的 `a73826e8c0fd90351a1bae5095ce87bc6210be7f`（A738）。
这是经过审查的个人引擎补丁系列，不是 NVIDIA 上游已有提交。
编辑器、导出模板和 Streamline 2.14.16 运行库必须成套，不能用标准模板导出实验工程。
SDK 与运行库按 NVIDIA 自身许可分发，本游戏仓库不收录 SDK 或二进制构建产物。
本文保留的 C1 构建、游戏画面和导出记录属于历史验收，不自动转为 A738 的通过记录。

## 画面设置

普通 Godot 4.7.2 保留原生及原有五档 FSR2，不需要 Streamline 全局类型。
可用引擎通过 `Engine.has_singleton`、动态调用、ClassDB 常量及属性探测启用实验入口。
所有主视口和玩家 SubViewport 仍由 `RSSettings.apply_viewport` 统一设置，避免后续设置覆盖 DLSS。

- 超分新增 DLAA、DLSS 质量 / 均衡 / 性能，预设可选 Recommended、K、L、M。
  这些是请求；不能仅据日志中的请求值声称驱动实际使用了该模型。
- NVIDIA 菜单的 DLSS 锐化控制复用引擎的 `fsr_sharpness` / NIS，默认显式为 0。
  切回 FSR 后恢复原来的 FSR 锐化值。没有增加 MFG、动态 MFG 或 DLSS 5。
- DLSS 能力不可用时保留用户请求，并按对应的 FSR 档回退；菜单明确显示回退。
  游戏菜单暂不提供 NVIDIA 超级性能；本次真实游戏矩阵覆盖 DLAA、质量和性能档。
- DDGI / PT + RR 需要 Vulkan Forward+、实际光追管线和对应属性。
  PT + RR 还要求 DLAA / DLSS、SDK 的 DLSS RR 能力，使用 1 sample/pixel。
  D3D12 的光追管线在此 fork 尚不可用，因此保持光栅；Windows HDR 仍沿用 D3D12 路径。
- 普通帧生成只向主 Window 的非 XR 视口发请求。玩家 SubViewport 不请求 FG，
  因而单人玩家格子和多人分屏都明确降级。引擎还会按实际渲染的 3D 视口数裁决；2D HUD 不计数。
  菜单显示 `get_frame_generation_status` 的原因，`sdk_enabled` 只说明 SDK 接受选项，
  不证明插入帧已经显示。实际生成帧应另用 SDK 状态 / 前台呈现证据确认。

新增请求保存在原有 `settings.cfg` 的 display 区，不新增存档、autoload、协议或依赖。
旧存档默认继续光栅、原生和关闭 FG。内置性能测试临时关闭实验光照与 FG，结束恢复原请求，
不将 FG 后的显示帧率混入原性能基线。Jolt Physics 和 120 Hz 物理设置保持原值。

## 运行与验证

使用独立工程副本和独立用户目录。不要让实验编辑器覆盖唯一的标准开发副本。
原启动器已经支持 `REGINA_GODOT` 指向显式引擎，不限定其必须是 4.7.2，标准查找路径不变。
试玩快捷方式应只在自己的启动环境中设置该变量并隔离游戏的设置 / 存档。

```sh
node tools/sync_assets.mjs
python tools/import_game.py --godot <NVIDIA-Godot>
python tools/test_nvidia.py --godot <NVIDIA-Godot>
python tools/smoke_game.py <NVIDIA-Godot> --project game
```

`test_nvidia.py` 使用 headless 测试官方引擎兼容、设置校验和明确回退，不能证明 GPU 功能。
画面验收应串行运行两后端的菜单 / 大厅，以及各项目的 2 / 4 人流程，保留 1600×900 中英文截图。
分别检查暂停改设置、重开、成绩、回菜单、HDR、XR 降级、蒙皮、透明物、天空、MultiMesh、闪烁和拖影。
真实手柄 / BLE / 手机手感与长时间游玩另行验收。

原篮球对比入口仍保留，使用同一个篮球玩法和新的适配器：

```sh
python tools/benchmark_rtx.py <NVIDIA-Godot> --driver vulkan
```

两张地图分别运行 1 / 2 / 4 人，预热 12 秒、采样 20 秒。RTX 为 DLSS 质量 + PT / RR、
Recommended 预设、锐化 0、FG 关闭；光栅为原生、MSAA / FXAA 关闭。每次进程使用隔离用户目录和
`RS_TEST_MODE=1`。报告在被忽略的 `audit-output/rtx`，只记录墙钟帧时间、显存估算和实际引擎 / GPU / 后端。
这不是相同内部分辨率的算法对照，也不测输入延迟。D3D12 可做光栅检查，但 RTX 对比会明确拒绝。

## 验收边界与来源

当前 A738 在 RTX 4060 Laptop GPU 上完成短时真实游戏材质复验：Vulkan 的 6 个 PT 关闭 / 开启
RR 用例、4 个分屏 PT / RR 用例、2 个 DDGI 用例均通过。游戏的导数兼容分支与引擎的真实实例数据、
实例位移缓存隔离及受限不透明顶点色修复一起受测；范围与剩余限制见
[PT_MATERIAL_COMPATIBILITY.md](PT_MATERIAL_COMPATIBILITY.md) 和
[A738 验证摘要](validation/rtx-a73826e8c0.json)。官方 4.7.2 另完成 2 / 4 人真实启动烟测，
不代表官方引擎具备 RTX 功能。

A738 标准 / Mono 仓库烟测另已通过，分别耗时 31.031 / 27.078 秒，退出码均为 0。
standard / Mono × debug / release 四种 installed template 物理夹具导出及 D3D12 运行也全部通过。
这些是匹配 A738 模板的 PhysX / C# PhysX 夹具检查，不是 Regina 本体的 PT / RR 导出验收；
Regina 本体另以 A738 标准安装模板完成冷导入、release 导出及两例生产入口运行：D3D12 双人滑冰
光栅请求、Vulkan 单人滑冰 PT + RR 请求，各保存三张 1600×900 PNG 后自然退出，退出码均为 0。
命令没有 `--path`、外部 `--script` 或 `--quit-after`；PCK 中 RT include 的实际内容已与源文件校验相同。
这验证启动、截图、自然退出与打包内容，不证明完整比赛、生产入口的 PT/RR 状态读回或模型身份。
冷异步编译仍可能短暂显示灰色占位；严格 GPU 验证尚未干净。

[RTX_VALIDATION.json](RTX_VALIDATION.json) 是 2026-10-21 的历史验证，针对旧上游
`135dff3887a3d2ccf45cafbd9bdffa7b718e1e76`，不代表新引擎或本次迁移已经完成 GPU 验收。
各提交的实测范围见 [RTX_MIGRATION.md](RTX_MIGRATION.md)。以下为
[C1 历史脱敏验证摘要](validation/rtx-c1fc0252a9.json) 的结果：C1 六种 Windows 构建、17 个真实游戏画面用例及
四种 installed template 物理测试工程导出 / 运行通过。Regina 本体另以匹配的 installed template
完成 Windows release 导出，并从 EXE / PCK 通过 D3D12 中文双人滑冰、Vulkan 英文四人篮球：
每例保存三张 1600×900 原始 PNG 后由生产 `RSExit` 自然退出，退出码 0，Job 清理后无 NGX 残留。
运行命令没有 `--path`、外部 `--script` 或 `--quit-after`；前两轮控制器失败记录原样保留。
这两例是短时导出启动 / 截图 / 退出检查，不是完整赛程或长时间自然游玩验收。
画面用例在 RTX 4060 Laptop GPU 上验证 Vulkan / D3D12、Jolt 120 Hz、DLSS / DLAA、
分屏 FG 降级、DDGI / PT 请求以及无 SDK 的 FSR2 回退，没有请求验证层或验证实际 DLSS 模型。
早期 CPU 检查的实验引擎是 `1000baebd`；六组 D3D12 严格干净对照发生在 `d37b63e72b`，
不能标成 C1 重跑通过。此前 d37 游戏画面运行因工具哈希变化导致的整体 FAIL 也保持原样。
Vulkan SDK 2.14 仍有 `09600` / `03868` 验证诊断，FG 另有内部同步与线程诊断；
本分支不能称为发布候选版本。
独立 Windows 试玩入口默认 D3D12；显式选择 Vulkan 试验光追时仍受上述 SDK 验证问题限制。
属性设置成功、headless 通过或单个菜单截图都不能替代实际 RTX / HDR / 性能验证。

本次源代码适配由 OpenAI Codex 辅助完成；没有新增 AI 素材或第三方资产。
保留原仓库 MIT、已有素材 CC0 / OFL 与 SDK 独立许可说明。
