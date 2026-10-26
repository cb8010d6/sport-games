# 固定 209897f 的 NVIDIA 迁移检查

迁移记录日期：2026-10-26；材质复验更新：2026-10-27。游戏基线为 `209897f4573208e02df52c4c929731a27d3527b1`，
已有实验头为 `e3f954c`；二者共同祖先是 `030d8cc97e9c9b882abb0404be0f9c30e849be95`。
实验独有的七个文件通过非快进合并保留原历史。对旧实验分支的 PR 会包含此前 dev 的前进，
应将这部分同步与后续 NVIDIA 适配提交分别审查，不能通过回退主线来压小差异。

## 固定引擎与证据范围

当前实验固定个人 fork `cb8010d6/godot` 的
`a73826e8c0fd90351a1bae5095ce87bc6210be7f`（下称 A738），运行库为 Streamline 2.14.16。
这是实验版本，不能称为 RC。当前材质复验的机器可读脱敏摘要见
[rtx-a73826e8c0.json](validation/rtx-a73826e8c0.json)；
[rtx-c1fc0252a9.json](validation/rtx-c1fc0252a9.json) 保留为旧 C1
`c1fc0252a98913d3be394417b6977a8c5aa4d77d` 的历史记录，其中保留原始验收 JSON 与截图的 SHA-256。
完整日志、截图和运行回执保留在私有任务证据中，不随源码发布。

不同提交的结果分别列出：早期 headless 适配检查发生在 `1000baebd`，严格 GPU 对照发生在
`d37b63e72b`，下文旧版真实游戏画面与模板导出发生在 C1，新增材质复验发生在 A738。
历史上 C1 相对 d37 的引擎代码
只增加了 `EditorHelp::load_script_doc_cache` 的六行退出保护，另有诊断文档；这不能代替重跑严格验证。

## A738 实测：短时材质复验

RTX 4060 Laptop GPU 上的 Vulkan 真实游戏检查已完成：6 个 PT 关闭 / 开启 RR 用例、4 个
分屏 PT / RR 用例、2 个 DDGI 用例均通过。PT 与 DDGI 分别运行，没有将两个光照模式混为同一结果。
最终游戏输入包含立面与滑雪地形的 RT 导数兼容分支；引擎使用真实 `INSTANCE_ID`、
`INSTANCE_CUSTOM`、实例颜色及按几何 owner 隔离的实例位移缓存，并修复受限不透明标准材质
的顶点色路径。细节、先前失败记录和高级材质排除条件见
[PT_MATERIAL_COMPATIBILITY.md](PT_MATERIAL_COMPATIBILITY.md)。
游戏侧实测输入是 `979778df7b2d89b9ebce7abc8737bd3389c4bb6e` 的 dirty 工作树快照；
相同四个 shader 文件后来提交为 `ab46ff811e7b9c2f9f8fa46144f0be5f4dd2de76`，哈希逐项匹配。
摘要保留实际测试 HEAD 与冻结输入，不将其重标为后补提交上的 GPU 重跑。

官方 Godot 4.7.2 另完成 2 / 4 人真实启动烟测，检查光栅兼容分支；这不证明 RTX 功能。
这些都是短时画面与退出检查，不覆盖完整赛程、自然输入、长期稳定性、性能或实际 DLSS 模型身份。

A738 标准 / Mono 的仓库烟测已独立重跑通过，退出码均为 0，分别耗时 31.031 / 27.078 秒。
四种 installed template 物理夹具（standard / Mono × debug / release）导出和 D3D12 实际运行
全部通过；21 个版本查询、导入、构建、导出及运行步骤退出码均为 0，模板、编辑器、托管依赖与
feed 的前后完整性检查通过。运行目录不提供 Streamline DLL；Mono 为 .NET 10 self-contained，
仅从进程环境移除 SDK，宿主机器仍安装 SDK。这不是新电脑分发证明。
该结果验证的是 PhysX / C# PhysX 夹具，不是 Regina 本体的 PT / RR 导出；
上述 A738 回执没有复用下文 C1 的通过记录。

Regina 本体也已通过独立完整工程副本的 A738 冷导入与 release 导出，退出码均为 0。
匹配标准安装模板的实际 EXE / PCK 完成以下生产入口检查：

| A738 Regina 本体运行 | 实测结果 |
|---|---|
| D3D12，滑冰 2 人，光栅请求 | 通过；三张 1600×900 PNG，退出码 0，耗时 37.531 秒 |
| Vulkan，滑冰 1 人，PT + RR 请求 | 通过；三张 1600×900 PNG，退出码 0，耗时 45.266 秒 |

两例均经生产 `--shots` 路径在最后一张截图后由 `RSExit` 自然退出，命令没有 `--path`、外部
`--script` 或 `--quit-after`，外层仅设 180 秒超时。日志无 `ERROR` / `SCRIPT ERROR`，实际后端、
A738 版本与 RTX 4060 符合预期，测试 Job 关闭所属子进程后没有新增 NGX updater 残留。
实际 PCK 包含 `res://shaders/rt_pixel_footprint.gdshaderinc`；读取出的 1654 字节 payload 与
源文件逐字节相同，MD5 匹配目录记录、SHA-256 匹配冻结 shader 输入。
原导出定位文件在准备阶段记录的 `runtime_pending=true` 保留不动，最终自然退出矩阵为后续独立回执。
这证明本次生产入口启动、截图、自然退出与 include 打包，不证明完整比赛、每种材质的全部画质、
实际模型身份或严格 GPU 验证；Vulkan 的 PT + RR 是请求记录，生产入口没有额外插入状态读回脚本。

异步编译首次创建 hit group 时仍可能显示灰色占位；同步编译对照只能帮助区分等待与错误，
不能宣称冷异步路径已经无占位。严格 GPU 验证仍未干净，当前实验仍非 RC。

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
原 `RTX_VALIDATION.json` 保持为历史记录。上表不声称已在 C1 或 A738 重跑全部早期 CPU 用例。

## C1 实测：真实游戏画面与模板导出

六种 Windows 构建（standard / Mono 的 editor、template_debug、template_release）通过，
构建回执退出码为 0、耗时 527.406 秒。冻结后的 17 个真实游戏画面用例逐项通过，整体也通过，
运行期间引擎、脚本和游戏适配输入的哈希未变。GPU 为 NVIDIA GeForce RTX 4060 Laptop GPU，
实际后端与请求一致，游戏保持 Jolt Physics / 120 Hz，HDR 关闭。
C1 的引擎 `Godot.SourceGenerators.Tests` 另有 43 项通过、0 失败、0 跳过；这是引擎源码生成器
测试，不是本游戏测试，也不扩大下面的游戏验收范围。

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

Regina 本体另以独立完整工程副本完成冷导入和 Windows release 导出，两步退出码均为 0、
日志无 `ERROR` / `SCRIPT ERROR`。使用安装到隔离用户目录的 C1 标准模板，模板哈希与对应
构建一致；SDK 2.14.16 DLL 仅放入私有本地运行目录，没有发布游戏或 SDK 二进制。
从导出的 EXE 与旁边的实际 PCK 完成了两例生产入口运行：

| Regina release 导出运行 | 结果 |
|---|---|
| D3D12，滑冰 2 人，中文 | 全部检查通过；三张 1600×900 原始 PNG，退出码 0 |
| Vulkan，篮球 4 人，英文 | 全部检查通过；三张 1600×900 原始 PNG，退出码 0 |

命令均没有 `--path`、`--script` 或 `--quit-after`，使用现有 `--at=1,4,8` / `--shots` 路径，
最后一张截图后由生产 `RSExit` 自然退出；外层工具只有 180 秒超时限制。
实际日志确认 C1、RTX 4060 和请求后端，SDK 接受 DLSS 质量 Recommended 选项；隔离设置中
NIS 为 0、光栅、FG / HDR 关闭。Windows Job 清理后两例均无 NGX updater 残留。
这些短时截图与退出检查没有请求验证层，不证明实际模型、稳定帧率、完整赛程或真实输入手感。

两轮先前尝试仍保留原件：首轮 release 模板未执行外部 `--script`，没有预期 capture marker，
即使游戏进程退出 0，控制器验收仍失败；第二轮用墙钟时间小于 19 秒推断自然退出，判据不成立，
两例仍记录为 FAIL。最终移除帧数退出保护后的自然退出矩阵是独立重跑，不覆写这些失败记录。

独立试玩启动器已实测 D3D12 退出码 0，关闭本次 Windows Job 后没有遗留的本次 NGX updater；
这只覆盖该次启动 / 清理，不代表所有退出流程都已验收。
本轮独立 Windows 试玩入口选择 D3D12 为默认后端；Vulkan 仍可显式选择以试验光追功能，
其已知严格验证问题见下节。

此前 d37 的 17 个分例虽然通过，整体因运行途中 driver 文件哈希变化而失败。
原始整体 FAIL 完整保留；C1 冻结工具后的重跑是新的独立记录。

## 严格验证与剩余边界

d37 的 13 组严格对照中，六组 D3D12（无 SDK、SDK 2.10 / 2.14、NIS、普通 FG）没有
D3D / 引擎错误。七组 Vulkan 中无 SDK 基线干净，SDK 路径仍有验证层问题：2.14 可出现
`VUID-vkCmdDraw-None-09600`、`VUID-vkQueueSubmit2-semaphore-03868`；FG 还出现内部同步危险、
信号量使用与多线程读写诊断；2.10 对照也有信号量诊断。C1 没有重跑这 13 组严格对照，
A738 材质复验也不将其改记为通过。后续材质生命周期严格检查仍有 `PRESENT_AFTER_WRITE`
同步诊断；短时画面通过不能消除这些已知问题。

真实 BLE / 手机体感、长时间自然游玩、输入延迟、稳定帧率结论和全新电脑分发尚未验证。
其余项目的完整自然流程、暂停修改设置 / 重开 / 成绩 / 回菜单、双语设置截图、实际模型指示器、
XR 与 HDR / SDR 切换也不在这 17 例的通过范围内。Vulkan 内部 SDK 同步 / swapchain
验证问题未解决前，本实验不应称为 RC。

现有 `game/tests/ui_capture.tscn` 会额外保存中英文 display / nvidia 页，并输出 `RS_NVIDIA_UI`
JSON，记录实际后端、DLSS 能力、请求 / 生效缩放模式、锐化及 FG 状态，供主任务核对真实适配调用。
