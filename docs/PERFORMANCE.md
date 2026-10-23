# 性能测量

本工具测量实际运动场景的机器人分屏负载，不改变玩法或进行优化。参考目标为 AMD Radeon 780M 上双人平均 60 fps、四人平均至少 45 fps；目标不是测量结果。正式首份基线覆盖六项目、地图 1、2/4 人、高画质、每组 3 次，共 36 次运行。结果只在具备相同条件的运行间比较。

## 测量条件

- 使用官方 Godot 4.7.2、真实显示窗口和 1600×900 输出。无头模式不渲染，不能用其耗时、固定 FPS 或快进测试推算 GPU 性能。
- 笔记本接交流电源；记录供电、CPU/GPU、驱动、实际渲染后端、引擎版本、源码提交和有效画质设置。运行期间不要并行启动其他渲染、编译或压力任务，窗口保持可见，避免最小化和远程显示环境切换。
- 本进程内关闭 VSync 与帧率上限，使用原生分辨率渲染；不修改玩家持久化设置。操作系统、驱动帧率限制和后台负载也会影响结果，应记录相同电源/性能模式。预热不代表已证明温度和频率稳定。
- 工具为每次运行建立隔离的 APPDATA / XDG 用户目录，使用 `RS_TEST_MODE=1`，不读取或改写玩家的设置、档案和纪录。场景中的机器人不能提交个人最佳。原始日志、JSON、汇总输出默认位于被 Git 忽略的 `audit-output/bench/`。
- GPU 编号依后端和机器而异。先看引擎 verbose 设备枚举，再以运行时实际 adapter 名称核对，不能只根据 Windows 设备清单判断。2026-10-23 的本次参考机同时有 RTX 4060 Laptop 与 Radeon 780M；官方 4.7.2 Vulkan 枚举分别为 GPU 0 与 GPU 1。下列 `--gpu-index 1` 仅对应本次枚举，`--expect-gpu 780M` 用于拒绝误跑独显的结果。

JSON 的实际渲染卡名称、厂商、API 版本和后端来自 RenderingServer。`metadata.driver` 来自 OS 的 active-adapter 查询，手动选择另一张 GPU 时可能与渲染卡不同，`driver_source` 明确记录此限制；`gpu_api_version` 是图形 API 版本，也不等于厂商驱动版本。正式基线需从操作系统按设备补充所选 780M 的驱动版本，不能把 OS 返回的独显驱动误标为核显驱动。CPU 型号、内存、显示/电源模式和其他背景条件也应补充在基线报告中。

CLI 在启动前检查供电。已知 `OFFLINE` 时不启动引擎，该次明确为 `FAIL`，保留项目、源码与供电元数据，没有样本或统计，`power_after=null` 表示没有运行后读数。运行后检测到 `OFFLINE` 时，即使引擎报告 `PASS`，工具仍将该次置为 `FAIL`、统计置为 `null`，保留原始引擎样本供诊断。

`UNKNOWN` / `UNAVAILABLE` 表示未能确认供电，不等于交流供电；工具不因此一律封锁无电池桌面等环境，正式基线仍须外部确认。`metadata.power_endpoints_online=true` 仅表示运行前后两次读数均为 `ONLINE`，不能证明采样期间从未短暂断电。该供电门禁在已保存基线之后新增，不改写历史 raw、统计或证据包；历史测量来源仍为 `8ec5889`，历史结果的供电资格以其原始读数和报告中的选样规则为准。

## 运行

以下从仓库根目录执行。将环境变量 `GODOT` 设为官方 Godot 4.7.2 控制台程序；`--godot` 也可直接指定自己的可执行文件路径。公共结果中不要填写本机绝对路径、玩家身份或设备地址。

先查看参数并用一组双人测量确认工具、设备和输出：

```powershell
python tools/bench.py --help
python tools/bench.py --godot "$env:GODOT" --games plane --maps 0 --players 2 --quality 2 --repeat 1 --warmup 2 --duration 5 --gpu-index 1 --expect-gpu 780M --output audit-output/bench-check
```

这只是工具短测，不能代替正式基线。正式矩阵命令：

```powershell
python tools/bench.py --godot "$env:GODOT" --games plane archery bowling skate ski basketball --maps 0 --players 2 4 --quality 2 --repeat 3 --warmup 10 --duration 30 --gpu-index 1 --expect-gpu 780M --seed 20261023 --output audit-output/bench-baseline-780M
```

命令行地图从 0 开始，因此 `--maps 0` 对应玩家界面的地图 1。人数支持 1、2、4；画质 0/1/2/3 对应低/中/高/极高。可通过 `--games`、`--maps`、`--players`、`--quality`、`--repeat` 缩小矩阵，`--timeout` 设置单次进程超时；具体组合以 `--help` 和实际地图范围为准。默认包含 1/2/4 人，和上述仅双/四人的首份基线矩阵不同。不同后端必须重新确认 GPU 枚举。

## 样本与统计定义

采样在进入真实 `PLAY` 后开始预热，预热结束后以单调真实时间采集逐帧数据；不计加载、大厅、倒数和正式成绩演出。游戏提前进入 `RESULTS` 或有效时长不足时，该次运行失败并保留已有数据，不用成绩页补足，不拼接重开后的多段。截图和结果写盘不应进入样本窗口。

| 数字 | 定义与单位 |
|---|---|
| 帧时间 | 相邻有效采样帧的真实时间间隔，ms；不是固定 FPS 的模拟 delta。|
| 平均 FPS | `1000 × 有效帧数 / Σ帧时间(ms)`；不平均逐帧瞬时 FPS。|
| p50 / p95 / p99 | 对有效样本升序排列，按 R7 线性插值，位置为 `(n−1) × p`；数值越低越好。p95 表示 95% 样本不高于该时间，不代表每秒的 95%。|
| 最差帧 | 有效帧时间的最大值，ms。|
| 1% low | 取最慢 `ceil(n × 0.01)` 帧的平均时间，再计算 `1000 / 该平均时间(ms)`；不是 `1000 / p99`，也不是瞬时 FPS 的百分位。|
| CPU process | `Performance.TIME_PROCESS × 1000`，ms；为引擎 process monitor，不能称为 GPU 时间或含所有线程的总 CPU 工时。|
| GPU render | 对启用计时的 root / 玩家 SubViewport 分别读取 `viewport_get_measured_render_time_gpu`，单位 ms，保留在 `gpu_viewports_ms`；本工具的 `gpu_ms` 为 `null`，不输出整帧 GPU 时间。|
| Draw calls | `Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME`，引擎全局计数，避免再叠加每个子视口计数。|
| 显存 | `Performance.RENDER_VIDEO_MEM_USED`，bytes；引擎渲染分配监测，不是整张 GPU 的总占用或任务管理器进程驻留显存。|
| 节点数 | `Performance.OBJECT_NODE_COUNT`，当前场景树节点数量。|

GPU 计时必须先在对应 RID 调用 `viewport_set_measure_render_time`。只取 root 会遗漏分屏子视口的工作；GPU 值小于等于 0、非有限或未就绪时表示该读数不可用，写为 `null`，不能以 0 ms 宣称免费。本工具逐个保留视口读数，并以 `metadata.gpu_ms_scope` 说明整帧 GPU 时间不可用，所以汇总的 `gpu_ms_avg` 也是 `null`，`gpu_samples` 为 0。官方描述的视口时间和是渲染工作量读数，不等于从输入到屏幕呈现的整帧墙钟时间；本实现不求该和，也不用其倒数代替实测 FPS。各视口 p95 不能直接相加。CPU 渲染计时同样不包含脚本和物理，若另行统计需将各视口 CPU 渲染时间与共享 `get_frame_setup_time_cpu()` 相加，后者每帧只计一次；raw 中的 `cpu_render_viewports_ms` 是独立视口读数，不是总 CPU 时间。参见 [Godot RenderingServer 计时说明](https://docs.godotengine.org/en/stable/classes/class_renderingserver.html#class-renderingserver-method-viewport-get-measured-render-time-gpu)。

部分 monitor 在发行构建不可用，或更新频率低于渲染帧率；同一 monitor 值可能被连续多帧采到。区分帧时间采样与这些监测读数，不据此宣称所有指标逐帧独立更新。参见 [Godot Performance 说明](https://docs.godotengine.org/en/stable/classes/class_performance.html)。

采样器、计时查询和原始样本收集也有开销，当前数字包含这些开销，没有扣除估计值。节点数包含测量进程的场景树而非单一运动根节点；不同采样器或带额外曲线界面的结果不是完全相同条件。

## 重复性与比赛时长

`--seed` 固定受本工具控制的起始随机源，不能保证跨机器、跨 FPS 的画面和物理逐帧相同。现有项目有固定局部 RNG，但机器人/镜头中部分随机数按渲染帧消耗，摔倒姿态使用全局随机，GPU 粒子及 Jolt 物理还有不同于局部 RNG 的状态。因此比较时必须保持相同项目、地图、人数、seed、时窗、设置和运行方式，并查看三次重复间的差异。

| 项目 | 正常 PLAY 结束条件；不把上限当最短保证 |
|---|---|
| 飞机 | 默认 90 秒模拟比赛时间。|
| 射箭 | 3 轮，每轮 3 箭及内部 INTRO/SUMMARY；完成后结束。内部阶段仍属于 PLAY，和最终 RESULTS 不同。|
| 保龄球 | 默认 5 格；全中、补中和最后一格奖励球改变球数，真实物理滚动和结算决定时长。|
| 滑板 / 滑雪 | 150 秒上限；首人完成后剩余最多 25 秒，全员完成后约 3 / 3.5 秒即可结束。|
| 篮球 | 70 秒上限，25 球投完并且空中球处理完成也可提前结束。|

预热 10 秒、采样 30 秒是起始测量方案，不是六项目任何条件下都有 40 秒有效 PLAY 的承诺。遇到不足时先保留失败证据；需要更短时窗时，对可比矩阵明确选择统一的新参数后重跑，不悄悄改玩法或将不足样本列入正式基线。

## 输出与比较

每次运行位于 `<项目>-m<地图>-p<人数>-q<画质>-r<重复序号>/`，保留 `engine-output.txt`（原始 JSON）、`raw.json`（结合进程退出与严格校验后的结果）、`run.log` 和 `engine.log`。`raw.json` 的 `runner_status` / `runner_errors` 保留原 runner 状态；即使 runner 先报告 PASS，随后退出出现引擎/资源错误，最终 `status` 仍为 FAIL。矩阵目录输出 `summary.json` 与 `summary.md`，顶层含 schema 版本、状态、计划/完成数量、错误、每次运行及重复分组。

raw 顶层包括 `game`、`map`、`players`、`quality`、`warmup_seconds`、`duration_seconds`、`elapsed_seconds`、`frames`、`samples` 和 `metadata`；逐帧字段为 `frame_ms`、`cpu_process_ms`、`gpu_ms`、`gpu_viewports_ms`、`cpu_render_viewports_ms`、`draw_calls`、`video_memory_bytes`、`nodes`。重复组统计包括 `avg_fps`、`frame_ms_p50/p95/p99/worst`、`one_percent_low_fps`、`cpu_process_ms_avg`、`gpu_ms_avg`、`gpu_samples`、`draw_calls_avg`、`video_memory_bytes_max`、`nodes_max`。

超时、崩溃、引擎/脚本错误、设备不符、输出无效或提前结束均明确报告失败，不能静默跳过。`PASS` 表示测量有效，与性能目标是否达标分开。重复组将有效运行的原始样本汇集后重新计算统计，不能把三个 p95 取平均当作合并 p95；另列每次平均 FPS 的最小/最大值。所有计划重复均有效且每次都达到双人 60 / 四人 45 fps 才为 `MET`，任一有效重复不足为 `BELOW_TARGET`，缺少或无效重复为 `INVALID`；1 人为 `N/A`。平均达标不代表所有帧满足相应预算，应同时查看 p95/p99、1% low 和最差帧。

对比两个版本时，核对源码提交、引擎/构建类型、GPU/驱动/后端、分辨率、各视口尺寸、画质/超分、人数、地图、seed、时窗和供电。`source_dirty=true` 表示提交号不足以还原被测树；正式基线应冻结源码并记录可还原的提交，或者另附对应差异与校验信息。不要把首次冷导入、热缓存、不同驱动或独显结果混成同一基线。差异若落在重复波动内，不宣称已证明性能提升。

正式可复核结果保存到 `docs/perf/baseline-<GPU>-<日期>.md`，附同条件运行的汇总、原始样本关联及未验证项；没有实际测量就不填基线数字。本文不把历史手测 FPS 或无头测试通过当成新基线。“设置 → 性能测试”在独立变更中实现，原 GPT-B 工具 PR 保留其冻结的独立采样器。

## 游戏内性能测试

在主菜单打开“设置 → 性能测试”。选择双人/四人、画质和 1600×900 / 1920×1080，点击开始；按 Esc 或手柄 D 可以取消。比赛暂停页不提供入口，以免中断正在进行的真人回合。笔记本请接电，保持窗口大小且不要最小化。

快速序列使用滑板、滑雪、篮球地图 1 的真实机器人场景，每段 PLAY 预热 10 秒、采样 30 秒，通常约 2–3 分钟加加载时间。它固定地图和起始种子，但不是跨帧率完全确定的录像回放；场景、物理和粒子限制同上。

运行界面显示当前阶段、进度、FPS 和帧时间曲线。结果页显示每场的平均 FPS、1% low、p95/p99、最差帧、CPU process 与独立视口 GPU 均值/有效覆盖率。结果曲线把该场全部真实帧按顺序等帧数分成最多 96 箱，显示各箱最大帧时间；纵轴 0–60 ms，超出截顶，精确最差值和原始数据另保留。图中的箱最大值不是逐帧原图或新的百分位。

完成、失败或取消后恢复本次临时改变的画质、帧率、超分和实际窗口状态，不保存玩家设置，不写档案、个人最佳或教学进度。结果导出只在点击“导出 JSON / CSV”时发生，写到 `user://benchmarks/<时间标识>/results.json` 和 `samples.csv`，不属于业务存档。JSON 同时保留原始样本与共享统计结果；CSV 按帧和视口展开，null GPU 值为空单元格；写入或 flush 失败明确报告失败。

内置界面与更新后的 CLI 适配器调用 `RSBenchmark` 公共实现，数据格式和统计定义相同。内置结果以 `entrypoint=in_game`、`overlay_enabled=true`、`sampler_version` 标明仪器条件；这些结果包含曲线界面开销。原始 GPT-B 首份基线来自独立采样器提交，不能不加说明地将两个版本当作完全相同仪器做差值。发行包未提供 `REGINA_BUILD_COMMIT` 时，内置导出的源码提交为 null；引擎/应用版本与实际 GPU/后端仍记录，不能猜测源码 SHA。

自动验收支持 `python tools/test_benchmark.py --godot <GODOT> --unit-only`，以及真实中英文 2/4 人界面验收 `--screenshots --players 2 4 --gpu-index <INDEX>`。图形验收使用明确注入的短采样窗口验证恢复、隔离、导出及布局，不是正式 FPS 基线，不改变产品的 10/30 秒默认值。

加 `--full-duration` 可验证产品默认的每场 10 秒预热、30 秒采样；仍标记为功能验收，不能与原仪器基线直接比较。首次冷启动的纹理、模型和管线编译可能明显增加加载时间；每场启动与序列总等待都有明确上限，超时会失败。验收排除引擎日志、着色器缓存及已知 Vulkan 管线缓存后，仍核对全部玩家文件、备份和临时副本的哈希及目录清单。
