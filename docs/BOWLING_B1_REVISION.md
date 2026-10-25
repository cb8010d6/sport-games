# B1 画面返工与证据

PR #31 继续完成保龄球 B1；人物、回放、音效、领奖台和新地图不在本次范围。按[维护者评论 6392600213](https://github.com/cb8010d6/sport-games/pull/31#issuecomment-6392600213)，四人原生和 FSR 原生抗锯齿的 P1–P4 标牌应清楚、无脏 halo，包含 P1 远望 P4；连续运动中的闪烁与拖影仍须主审。FSR 质量档 scale≈0.67 的远处小字变软本身不阻塞 B1，保持可读即可，不为它改全局后处理。

本轮正常合并 `dev` 的 `24097b1e5414c655bcc6113ada6bc7387b28e8fd`，保留 #75 的旧 BLE clock 修复、#79 的换图画质重应用和 #83 的框架修复。#82 已由 #75 取代并关闭，不再作为依赖，也不加入假 clock 对象。最新整合源码尚未完成双档画面复核，PR 状态由主审决定，本文不宣称 ready 或整个 #25 完成。

## 保留的实现

- P1–P4 独立黑底已移除；专用 MSDF 字体 range=24、size=128、outline=10，保留 opaque prepass。range 至少为描边两倍的断言保留。
- bowling 专用遮板 shader 以 `fwidth` 过滤细线，环境 bloom=0，glow 服从公共画质。计分格为 `#E3E5EF`、alpha=0.76，数字为 `RSUi.INK`；公共 P1 badge、框架和共享字体不改。
- 场馆使用原创程序几何/图案与既有 CC0 材质，重复部件使用 MultiMesh；开场接入 `RSIntro`。球道碰撞、刚体参数、输入、机器人和计分规则不变。
- bowling 专用测试以 20 秒真实时钟 deadline 等待 PLAY，保留原断言；不把固定 1200 个渲染帧当作倒数经过的秒数。本轮未顺手修改其他项目测试。

## 已有运行证据及来源

以下结果均属于标明的旧源码，不能冒充最新合并源码的重新运行。正式基线与画面采集是独立证据；PNG 读回速度不是 FPS。

| 来源与环境 | 实际结果 | 边界 |
|---|---|---|
| 最终样式，官方 Godot 4.7.2 | 2/4 人 × 中/英文 × 100%/125% 场馆矩阵，八例 4800 项通过 | headless 不验证真实字体、灯光、shader 或运动观感 |
| `0c71361`，780M，1600×900，q2，原生请求 | 六次正式基线全部有效、0 重试；2P 合并 88.98827 FPS / 1% low 70.18961；4P 69.62846 / 47.08742 | 各预热 10 秒、采样 30 秒，seed=20261023；不是新旧样式配对测量 |
| `0c71361`，780M，125% 图形观察 | 四例静态 PASS，共 2424 项；原生运动整例 **FAIL**；两档 FSR **NOT_RUN** | 原生 worker 的 120 帧通过，但运行后全机进程 guard 失败；归属未确认，历史 FAIL 不改写 |
| `5a0b918`，RTX 4060，官方 4.7.2 | 七例静态 PASS，共 3998 项，包含宽屏 1/2/4 人与 1600×900 中/英 2/4 人 125% | 含 intro、PLAY、场馆观察；受控画面不能替代自然流程 |
| `5a0b918`，4P QHD 连续运动 | 原生、FSR 原生抗锯齿、FSR 质量三档各完整 120 帧通过采集断言 | 游戏/物理继续，受控相机路径；是画面证据，不是 FPS 或完整主审结论 |
| `5a0b918`，自然 2/4 人 | 各自然完成五格至 RESULTS，各保留 112 张原 PNG | 2P 247.734 秒，4P 241.937 秒；不等于真实手柄手感验收 |
| `5a0b918`，普通 2/4 人与公共 smoke | 两个普通完整流程通过，公共 smoke 15 项通过 | 已知静态资源 shutdown warning 保留，仅按原 runner 规则排除，不能称 diagnostic-free |

正式统计见 [summary](benchmarks/bowling-b1-formal-20261024/summary.json) 与 [SHA 清单](benchmarks/bowling-b1-formal-20261024/sha256.json)。逐视口 GPU 计时分别报告、覆盖率为 1.0，不能求和当整帧 GPU；整帧 GPU 未采集为 null。该 sampler 未采逐玩家实际尺寸、AA、scale，均为 null，不能拿另一批静态图补填。使用 Balanced、频率未锁、顺序为 2P 三次后 4P 三次，没有随机化，也没有同条件旧样式正式对照，不能宣称样式收益。

早期四份 5 秒预热 / 10 秒单次短采样仅保留[摘要、算法和 SHA](benchmarks/bowling-b1/README.md)。其中 before-2P 与其他工具工作重叠，不能据此判定稳定性能差值。历史图形状态、负面结果和图片来源见[验收摘要](benchmarks/bowling-b1-revision/summary.json)及[图片 SHA / 裁剪来源](benchmarks/bowling-b1-revision/sha256.json)。

### 保留的失败与后续独立观察

- 图形 B 的按帧等待在 COUNTDOWN 4.327889 秒结束，351 项中 1 项失败；`5a0b918` 只将等待改为真实 20 秒 deadline，未放宽断言。
- 图形 C 的 FSR 原生抗锯齿在 210 秒超时，保留 113/120 张原 PNG，仍为 FAIL。依据实际 PNG 成本手动建立 D，单组 engine/helper 预算为 360/390 秒；D 的 FSR 原生抗锯齿与质量档分别在 219.203 / 209.860 秒完成 120 帧，没有降低帧数或自动重试。
- 自然流程 B 的 4P 仅剩共享预算 139 秒而超时，失败原图/遥测保留；另一次 C 的 4P 使用独立 400 秒预算完成。后续通过不覆盖这些历史失败。

## 代表原图与布局解释

仓库保留以下九张原 PNG，未经缩放、重编码或修图；均属于标明的历史来源，不是最新合并源码的截图。

| 代表画面 | 原始 PNG |
|---|---|
| `r2` QHD 原生同机位对照 | [旧场馆，`cf88966`](screenshots/bowling-b1-r2-before-qhd-native.png)、[最终样式，`fb3af56`](screenshots/bowling-b1-r2-after-qhd-native.png) |
| `r3` 125% 中文双人 / 英文四人，`0c71361` | [双人 intro](screenshots/bowling-b1-r3-125-2p-zh-intro.png)、[四人 PLAY](screenshots/bowling-b1-r3-125-4p-en-play.png) |
| 四人自然流程 | [frame099](screenshots/bowling-b1-r4-natural-4p-frame099.png)、[frame111](screenshots/bowling-b1-r4-natural-4p-frame111.png) |
| 原生运动 frame060 | [原生](screenshots/bowling-b1-r4-motion-native-frame060.png) |
| FSR 原生抗锯齿 frame060 | [FSR 原生抗锯齿](screenshots/bowling-b1-r4-motion-fsr-native-aa-frame060.png) |
| FSR 质量 frame060 | [FSR 质量](screenshots/bowling-b1-r4-motion-fsr-quality-frame060.png) |

`r4` 对应 `5a0b918`。`r3` 是受控 125% 时刻，首个 PLAY 在源 suite 暂停后仍有临时 GO 覆盖层，不能据此判断自然流程的持续遮挡。`r2` 同机位对照冻结 44 个刚体，仅证明静态。

三档同 frame 使用同一受控相机路径，但实时物理状态不匹配，不能称确定性重放或像素级物理对照。主审已查看代表静态、125% PLAY、自然流程与运动选帧；它们不替代最新合并源码的两组完整 120 帧闪烁/拖影审核。

2560×1080 是物理窗口；生产内容基准保持 1600×900、`canvas_items` / `expand`，展开后的 root 逻辑区域为 2133×900，2P 内部视口 1062×896，4P 为 1062×446。2560×1440 的 QHD 运动图仍用生产内容基准，4P 内部视口为 796×446，不能写成 1280×720。

移出仓库的旧 200% crop 已归档，其源像素框与缩放 provenance 保留在 SHA 清单的 archive 条目，未新造 crop。既有图片沿用 **MIT AND CC0-1.0**，来源见 [THIRD_PARTY.md](THIRD_PARTY.md)，本轮不增加素材或许可政策。

## 证据存储与剩余门槛

按维护者要求，六份正式 raw 和四份早期逐帧 raw 已先完整私有归档、逐文件 SHA256 等价校验，再从 Git 索引移除；原始本地文件保留。旧完整 metadata 也已归档。24 张原 PNG 同样先完整归档并逐 SHA 核对，仓库仅保留上述九张；其余 15 张按 archive file ID + SHA 登记，原始本地文件保留。未上传 Release、附件或评论，不改写历史提交。正式清单区分原私有 raw 与旧公开导出字节的 SHA；归档清单 SHA 登记在摘要中。

合并后的 CPU 检查已实际通过：规范 0 错误、3 个既有 SIZE 提示；i18n 474 文本、0 缺失、0 多余；工具 pytest 86 项及 251 个子测试、中枢 pytest 150 项、Node 素材测试 9 项通过；隐私扫描 0 发现。没有用旧分支的绿灯代替这些结果。

当前仍待：最新整合源码在独占 GPU 条件下，各采四人原生 / FSR 原生抗锯齿连续 120 帧；主审检查 P1 远 P4 清晰度、细线闪烁和拖影，并复核最新 CI。FSR 质量档变软本身不作为单独阻塞条件。本轮尚未执行引擎、导入、性能或图形命令。
