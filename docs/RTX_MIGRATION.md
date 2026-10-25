# 固定 209897f 的 NVIDIA 迁移检查

日期：2026-10-26。游戏基线为 `209897f4573208e02df52c4c929731a27d3527b1`，
已有实验头为 `e3f954c`；二者共同祖先是 `030d8cc97e9c9b882abb0404be0f9c30e849be95`。
实验独有的七个文件通过非快进合并保留原历史。对旧实验分支的 PR 会包含此前 dev 的前进，
应将这部分同步与后续 NVIDIA 适配提交分别审查，不能通过回退主线来压小差异。

## 已执行的 CPU 检查

| 检查 | 结果与边界 |
|---|---|
| 官方 4.7.2 `tools/import_game.py` | 冷缓存与增量导入通过；222 项锁定素材逐项校验，28 项由独立任务副本补齐。原游戏目录只读。 |
| `tools/test_nvidia.py`，官方 4.7.2 | 56 项检查，0 失败：旧设置、NIS 默认关闭、十档请求的回退、AA、保存恢复、输入类型 / 范围与状态字段。 |
| 同一测试，实验引擎 `1000baebd` / 4.8.beta1 | 57 项检查，0 失败；额外验证玩家 SubViewport 不请求 FG。headless 不验证 SDK 功能。 |
| 两引擎的旧 RTX 入口 `--probe-only` / headless | 在旧固定引擎 `1000baebd` 上均按预期退出 2：官方引擎缺少 PT API；实验引擎拒绝以 headless 测量 RTX。当前候选提交已前进，此记录不覆盖新候选。 |
| 官方 4.7.2 `tools/smoke_game.py` | 17 个菜单 / 地图 / 篮球分屏启动用例通过。工具对强制 `--quit-after` 的已知资源保留采用既有允许，因此不是干净退出证明。 |
| 七项目地图 0，`--demo=2` / `--demo=4` | 14 个 headless 启动用例通过；完整结果在本次私有运行证据中保留，不作为画面结论。 |
| 现有 `tools/test_benchmark.py --unit-only` | 官方 4.7.2：53 checks，0 failures；实际渲染的 NVIDIA 设置关闭 / 恢复分支仍待 GPU 验收。 |
| `python tools/check_conventions.py` | 0 错误，4 个既有 SIZE 警告；不修改无关的大脚本。 |
| `python tools/i18n_check.py` | 510 文案，0 缺失、0 多余。 |
| `python -m pytest -q tools/tests` | 122 通过，293 subtests 通过。 |
| `python -m pytest -q`（hub） | 251 通过；没有修改 hub 或体感协议。 |
| `python -m ruff check --config hub/pyproject.toml hub tools` | 通过。 |
| Node 24.22.1 `--test tools/tests/asset_sync.test.mjs` | 12 通过。 |
| `node tools/publication_audit.mjs --privacy-only` | 无发现；不能替代素材外观或法律审查。 |

旧缓存与两轮导入产生的 sidecar 差异在任务证据目录保留，不将缓存、导入器自动改动或二进制提交到 Git。
原 `RTX_VALIDATION.json` 保持为历史记录。当前工具、源码和文档都不将自动化成功等同于 GPU / 手感验收。

## GPU / 导出待验矩阵

这些检查由负责 GPU 队列的主任务执行，本 CPU 迁移提交尚未声称通过。

| 场景 | Vulkan | D3D12 |
|---|---|---|
| 菜单 / 大厅，原生、FSR2、DLAA、DLSS 质量 / 均衡 / 性能 | 待验 | 待验 |
| Recommended / K / L / M 的请求与实际模型指示器；NIS 0 / 非零 | 待验 | 待验 |
| 七项目 2 / 4 人；暂停改设置、重开、成绩、回菜单 | 待验 | 待验 |
| 主窗口普通 FG、2D HUD；单 / 多玩家 SubViewport 与 XR 降级 | 待验 | 待验 |
| DDGI / PT + RR 的 API、SDK、真实画面 | 待验 | 应明确回退光栅 |
| 1600×900 中英文设置截图 | 待验 | 待验 |
| HDR / SDR 切换、匹配编辑器与模板的导出启动 | 不提供 Windows HDR 路径 | 待验 |

真实 BLE / 手机体感、长时间自然游玩、输入延迟、稳定帧率结论和全新电脑分发尚未验证。
Vulkan 内部 SDK 同步 / swapchain 验证问题未解决前，本实验不应称为 RC。

`tools/rtx_engine.json` 当前记录的是候选 `036c6c7`；最终 GPU 验收后仍需更新固定提交和实测证据。
现有 `game/tests/ui_capture.tscn` 会额外保存中英文 display / nvidia 页，并输出 `RS_NVIDIA_UI`
JSON，记录实际后端、DLSS 能力、请求 / 生效缩放模式、锐化及 FG 状态，供主任务核对真实适配调用。
