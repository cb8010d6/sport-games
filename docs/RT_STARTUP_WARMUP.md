# RT 场景加载门（尚待原生构建与实机验收）

只在支持新 readiness API、实际 Vulkan PT+RR 请求成立时创建场景内
`RSRenderWarmup`；官方 4.7.2、headless、D3D12/非 RT 路径保留原启动行为。
不新增 autoload、依赖、存档或协议，不提前加载全部运动项目。

`RSPartyGame` 在场地/大厅相机建好后及 `_round_started()` 放好实际玩家
和相机后分别调用门。后者覆盖地图重建、重新开始和多玩家实际视口。
遮罩是独立 CanvasLayer；3D、相机和窗口保持可见，目标 SubViewport 暂时
`UPDATE_ALWAYS`，不会因遮罩阻挡纹理而误停渲染。没有摄像机或实际 PT
Environment 的视口不参与，主窗口无 update-mode 改写。

门保存 SceneTree 原暂停状态，暂停玩法、倒数、截图时钟和物理；自身
PROCESS_MODE_ALWAYS，仍轮询 frame_post_draw。每个实际目标视口必须有
非空 TLAS、有效 pipeline/bindings 的 RT 命令记录、零 failed/pending，
且两次不同的 fresh serial 快照一致，才能开始呈现游戏。只检查当前
variant 的 live-ready mask，不等待全局后台队列，也不以固定 sleep 或
frame 数冒充编译完成。记录的命令不是独立 GPU fence/present 确认。

120 秒只是失败上限。失败/超时保留暂停和明确的失败界面，返回主菜单
按钮及 Esc 可恢复；窗口关闭仍由 RSExit 接管。ready、failure、timeout、
cancel、tree-exit 和窗口关闭均恢复各目标 VP 原 update_mode 并断开轮询。
恢复 pause 与恢复渲染 override 分开；失败不会无声地启动比赛，取消不
产生晚到的倒数回调。没有修改用户 settings.cfg 或把测试 profile 保存。

`render_warmup_status` 是内存诊断结果，区分 unsupported/not_rendered、
pending、failed/timeout、ready；空目标不创建门。配置请求不是实际 DLSS
模型/FG 证明。本变化必须单独重新构建和验证，不覆盖冻结的 A738 记录。

验收至少包括：真实新缓存 pending→live-ready；前端/RT 错误不变 ready；
空/不支持 no-op；多 VP stale serial 不放行；取消回菜单和关闭窗口恢复；
1/2/4 人物理位置/phase_time/_clock 在门内不推进；官方 4.7.2 受影响场景
及完整 smoke；最终实际导出包；原生 editor/Mono/template 相关回归。

## 2026-10-27 实测范围

游戏程序输入为 `3d51851c6eec09ff4cb8a2b0f818e837d06ca4e8`。5470 的单人入口、8a 的
双人/四人滑板、四人滑雪、首/第二道门取消、加速注入超时、坏 RT shader 恢复均已执行；
暂停期间实际物理与时钟没有推进，恢复或回菜单行为通过。超时注入不是等待完整 120 秒的压力测试。

D29 六种原生 Windows 构建、标准/Mono 仓库烟测、四个实际安装模板导出均通过。公开预热夹具
经过同一 D29 release 模板的真实 PCK 运行，五阶段、四组像素、pending 与故意失败检测通过。
完整游戏的编译 warm-up 类/remap/include 已流式核对；Vulkan 与 D3D12 各保存三张原始图并自然退出。

RR 自动/F 的严格同步失败与预热结果分开。请求 D 并在启动前禁用 FG 插件的兼容组合，在
单人/四人真实场景中严格验证通过；不宣称模型权重读回、逐帧质量或长时间稳定性。
完整记录见 [最新摘要](validation/rtx-d29e706530.json)；历史失败没有改写。
