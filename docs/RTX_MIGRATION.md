# 固定 209897f 的 NVIDIA 迁移检查

日期：2026-10-26。游戏基线为 `209897f4573208e02df52c4c929731a27d3527b1`，
已有实验头为 `e3f954c`；二者共同祖先是 `030d8cc97e9c9b882abb0404be0f9c30e849be95`。
实验独有的七个文件通过非快进合并保留原历史。对旧实验分支的 PR 会包含此前 dev 的前进，
应将这部分同步与后续 NVIDIA 适配提交分别审查，不能通过回退主线来压小差异。

## 固定引擎与证据范围

本次实验固定个人 fork `cb8010d6/godot` 的
`c1fc0252a98913d3be394417b6977a8c5aa4d77d`（下称 C1），运行库为 Streamline 2.14.16。
这是实验版本，不能称为 RC。机器可读的脱敏摘要见
[rtx-c1fc0252a9.json](validation/rtx-c1fc0252a9.json)，其中保留原始验收 JSON 与截图的 SHA-256；
完整日志、截图和运行回执保留在私有任务证据中，不随源码发布。

不同提交的结果分别列出：早期 headless 适配检查发生在 `1000baebd`，严格 GPU 对照发生在
`d37b63e72b`，本轮冻结输入的真实游戏画面与模板导出发生在 C1。C1 相对 d37 的引擎代码
只增加了 `EditorHelp::load_script_doc_cache` 的六行退出保护，另有诊断文档；这不能代替重跑严格验证。

## 已执行的 CPU 检查（早期迁移）

| 检查 | 结果与边界 |
|---|---|
| 官方 4.7.2 `tools/import_game.py` | 冷缓存与增量导入通过；222 项锁定素材逐项校验，28 项由独立任务副本补齐。原游戏目录只读。 |
| `tools/test_nvidia.py`，官方 4.7.2 | 56 项检查，0 失败：旧设置、NIS 默认关闭、十档请求的回退、AA、保存恢复、输入类型 / 范围与状态字段。 |
| 同一测试，实验引擎 `1000baebd` / 4.8.beta1 | 57 项检查，0 失败；额外验证玩家 SubViewport 不请求 FG。headless 不验证 SDK 功能。 |
| 两引擎的旧 RTX 入口 `--probe-only` / headless | 在旧固定引擎 `1000baebd` 上均按预期退出 2：官方引擎缺少 PT API；实验引擎拒绝以 headless 测量 RTX。当前候选提交已前进，此记录不覆盖新候选。 |
| 官方 4.7.2 `tools/smoke_game.py` | 17 个菜单 / 地图 / 篮球分屏启动用例通过。工具对强制 `--quit-after` 的已知资源保留采用既有允许，因此不是干净退出证明。 |
| 七项目地图 0，`--demo=2` / `--demo=4` | 14 个 headless 启动用例通过；完整结果在本次私有运行证据中保留，不作为画面结论。 |
| 现有 `tools/test_benchmark.py --unit-only` | 官方 4.7.2：53 checks，0 failures；这是单元检查，不是渲染性能基线。 |
| `python tools/check_conventions.py` | 0 错误，4 个既有 SIZE 警告；不修改无关的大脚本。 |
| `python tools/i18n_check.py` | 510 文案，0 缺失、0 多余。 |
| `python -m pytest -q tools/tests` | 122 通过，293 subtests 通过。 |
| `python -m pytest -q`（hub） | 251 通过；没有修改 hub 或体感协议。 |
| `python -m ruff check --config hub/pyproject.toml hub tools` | 通过。 |
| Node 24.22.1 `--test tools/tests/asset_sync.test.mjs` | 12 通过。 |
| `node tools/publication_audit.mjs --privacy-only` | 无发现；不能替代素材外观或法律审查。 |

旧缓存与两轮导入产生的 sidecar 差异在任务证据目录保留，不将缓存、导入器自动改动或二进制提交到 Git。
原 `RTX_VALIDATION.json` 保持为历史记录。上表不声称已在 C1 重跑全部早期 CPU 用例。

## C1 实测：真实游戏画面与模板导出

六种 Windows 构建（standard / Mono 的 editor、template_debug、template_release）通过，
构建回执退出码为 0、耗时 527.406 秒。冻结后的 17 个真实游戏画面用例逐项通过，整体也通过，
运行期间引擎、脚本和游戏适配输入的哈希未变。GPU 为 NVIDIA GeForce RTX 4060 Laptop GPU，
实际后端与请求一致，游戏保持 Jolt Physics / 120 Hz，HDR 关闭。

| 真实游戏画面用例 | Vulkan | D3D12 |
|---|---|---|
| 滑冰 1 人：DLSS 质量 Recommended、DLAA M、性能 M | 通过 | 通过；性能档锐化请求为 0.2 |
| 篮球 2 / 4 人：DLSS 质量、请求 FG | 通过；玩家视口 FG 关闭，SDK 未启用 FG | 同左 |
| 滑冰 3 人：DLSS 质量 | 通过 | 通过 |
| 滑冰 1 人：DDGI、PT + RR | 两用例通过，实际环境标志符合请求 | PT 请求用例通过，实际保持光栅 |
| 无 SDK 运行库：请求 DLSS 质量 | 通过，实际回退 FSR2 | 同左 |

每例读回 180 个 post-draw 帧后的 1600×900 PNG，核对实际缩放、光照标志、视口、引擎提交、
物理设置和退出码。除上述一个锐化用例外，NVIDIA 锐化请求为 0；无 SDK 的 FSR2 回退恢复原有
FSR 锐化值。这些是固定模拟步长的功能检查，没有请求验证层，也没有查询实际 DLSS 模型。
预设名称是请求值；本矩阵不证明模型指示器、生成帧呈现、图像质量、帧率或输入延迟。
篮球 FG 用例观察到 `reason=no_request`、`sdk_enabled=false`，不能解读为已测得帧生成。

四种 **installed template 物理测试工程** 导出和 D3D12 实际运行均通过：standard / Mono ×
debug / release，使用匹配的 `4.8.beta1` / `4.8.beta1.mono` 模板，未指定 custom template。
Mono 使用新的隔离 NuGet 缓存、本次构建的本地包和 .NET 10 self-contained 输出。
运行时仅从进程环境移除了 dotnet SDK；宿主机器仍装有 SDK，不能称为全新电脑验收。
这些工程验证的是 PhysX / C# PhysX 标记，**不是 Regina 游戏本体**，也不替代本游戏 Jolt 路径。
Regina 本体的 Windows 导出与启动仍待完成。

独立试玩启动器已实测 D3D12 退出码 0，关闭本次 Windows Job 后没有遗留的本次 NGX updater；
这只覆盖该次启动 / 清理，不代表所有退出流程都已验收。

此前 d37 的 17 个分例虽然通过，整体因运行途中 driver 文件哈希变化而失败。
原始整体 FAIL 完整保留；C1 冻结工具后的重跑是新的独立记录。

## 严格验证与剩余边界

d37 的 13 组严格对照中，六组 D3D12（无 SDK、SDK 2.10 / 2.14、NIS、普通 FG）没有
D3D / 引擎错误。七组 Vulkan 中无 SDK 基线干净，SDK 路径仍有验证层问题：2.14 可出现
`VUID-vkCmdDraw-None-09600`、`VUID-vkQueueSubmit2-semaphore-03868`；FG 还出现内部同步危险、
信号量使用与多线程读写诊断；2.10 对照也有信号量诊断。C1 没有重跑这 13 组严格对照，
本轮无验证层的游戏画面通过不能消除这些已知问题。

真实 BLE / 手机体感、长时间自然游玩、输入延迟、稳定帧率结论和全新电脑分发尚未验证。
其余项目的完整自然流程、暂停修改设置 / 重开 / 成绩 / 回菜单、双语设置截图、实际模型指示器、
XR 与 HDR / SDR 切换也不在这 17 例的通过范围内。Vulkan 内部 SDK 同步 / swapchain
验证问题未解决前，本实验不应称为 RC。

现有 `game/tests/ui_capture.tscn` 会额外保存中英文 display / nvidia 页，并输出 `RS_NVIDIA_UI`
JSON，记录实际后端、DLSS 能力、请求 / 生效缩放模式、锐化及 FG 状态，供主任务核对真实适配调用。
