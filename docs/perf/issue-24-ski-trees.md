# #24 滑雪树：结论与后续条件

PR #37 保持 open/draft，当前不接受整体优化。2026-10-25 主审意见明确：现有小幅均值改善不足以抵偿低模、shader变体及距离交接的复杂度；#53 的子步、赛道查询与分屏阴影改动已通过 PR #87 合入 dev；仍需在该基线上评估真实四人帧时间和同机位画面。暂不新增树优化、不扩大测量矩阵，也不自行关闭 PR，代码留在本分支备查。

## 实现边界

v1保留150m布局批次、RNG/INSTANCE_ID、高模、远树与250m近景保护，增加独立低模及距离visibility dependency。v2只为低模建立并复用项目私有coarse shader，删除次级针叶/法线微噪声；共享shader、高模/远树材质身份、几何与规则保持。较少三角形或shader运算不是实测收益。

## 已有测量的结论

| 测量 | 结论 |
|---|---|
| 780M：原始版对v1，36次、31,385帧 | 未变skate控制组下降约5%；ski map1双/四人分别−6.887%/−1.775%，map3双人−6.979%、四人+5.301%。局部改善不能抵消其他组退化或控制漂移；503.304ms最差帧保留。 |
| RTX4060：当前core上v1对v2，6次、19,443帧 | map1双人平均107.527→108.470FPS（+0.877%）；1%low84.668→82.953，最差帧31.348→50.733ms。收益很小且尾部变差，不接受整体优化。 |

两批的完整分组统计见[780M摘要](../benchmarks/ski-trees-20261024-v3/summary.json)及[RTX4060摘要](../benchmarks/ski-trees-20261025-rtx4060-v2/summary.json)。两批硬件、源代码和问题不同，不能混用。FPS按全部实际帧间隔合并计算；逐VP GPU独立报告、不求和称整帧，实际VP尺寸/AA/scale未测时为null，TIME_PROCESS不是OS CPU利用率。三个重复的范围不是显著性检验，逐帧不充当独立实验重复。

780M批次为官方Godot4.7.2、native1600×900/q2，每侧18次，10秒预热/30秒采样，包含skate控制组与ski map1/map3双/四人。RTX4060批次为同引擎、Balanced/交流供电、频率未锁，ski map1双人、相同分辨率/画质、seed20261023、相同预热/采样，顺序A1/B1/B2/A2/A3/B3。

RTX4060对照A为本地未推送的a181ce50998b0bd9621d1e746b1edb3da9353365；可从0fbdfe682abcc285e9aa353493eef9fe1a87cf61基底恢复v1 bac293db4df4ba612aa608aafda288d93841b737的ski_trees.gd和test_ski_trees.gd，并删除coarse shader重建。B为a0252c3dcd3d70bf82abd7f6926dd9e0893e8ca1；B另有官方生成UID。core/autoload/tools/project/assets同对象，完整身份见摘要；不能把旧v1直接对新core的共有代码变化算作材质收益。

## 原始样本的保存

逐帧raw已从Git索引移出，仓库只保留摘要和[780M SHA清单](../benchmarks/ski-trees-20261024-v3/raw-sha256.json)、[RTX4060 SHA清单](../benchmarks/ski-trees-20261025-rtx4060-v2/raw-sha256.json)。42份raw及原manifest/statistics先逐字节归档并验证后才移出索引，本地原件仍保留；未发布Release或公开附件，不提供不存在的下载链接。

归档名：ski-raw-archive-20261025-pr37.zip；SHA-256：f7c47e895b19606aa4466556ac0f15874fb07a9970356c460d5380c33cbe3492。它保存在本机review-evidence；每份原raw的完整SHA和大小在上述清单。原始私有采样及失败证据也独立保留，没有改数值、过滤最差帧或重标失败。早期raw提交仍在分支历史，最终整合方式交维护者决定；本任务不重写历史、不强推。

## 验证边界与后续门

官方4.7.2导入/编译与专用数据回归通过；renderer检查含852次实际MultiMesh transform存储回读，但course未加入scene tree，不能证明可见LOD交接、阴影或风雪。断言数量不作为优化验收依据。最近15项公共smoke通过，按原runner规则排除的既有资源退出警告保留。

首次441组配对cache审计因47模型payload/receipt不同而FAIL；先备份A的94原件，再在批准范围内B→A复制并重审等价后执行正式六次。未flush，不声称pipeline cache相同或冷态。verbose双人预检虽产生7PNG/exit0，RGB8转换warning的backtrace被原分类器拒绝，仍记FAIL；默认非verbose短probe和六次正式诊断通过。短probe/截图不计入正式样本。

本轮正常合并dev278d446，包含#75生产perf_counter、#79重应用画质、#83防重入、#86项目清单、#87性能改动及#88素材命名，#82已被取代关闭，不再列为依赖。旧测量保留其原始source归属，不冒充合并后重新测量。

后续在已合入#87的基线上，评估地图1/3、四人的实际树开销及同机位运动画面；若占比仍大再决定继续，否则由维护者决定关闭。真实LOD交接与四人画面未完成，当前保留draft；不以存储回读数量或六次双人均值替代验收。

本次按用户要求不恢复性能测量或完整画面序列。新基线仅做源码整合与轻量静态检查；旧导入、smoke和测量结果保留原提交归属，不视为278d446上重跑。该候选尚未通过优化收益审查，继续保持draft，不因其他PR简测通过而标记完成。
