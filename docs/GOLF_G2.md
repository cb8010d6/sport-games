# 高尔夫 G2：纯规则与统一时序

本片是M1累计draft PR #33的内部G2切片，接在G1之后，依据已批准的[G0](GOLF_DESIGN.md)实施规则；不独立作为外部里程碑。仍使用占位按键、144 tick抛物线和放大的球。`can_record()`始终返回false，不注册菜单，不实现G3几何或G4手势，HUD继续等PR #27。

## 模块与API

[`RSGolfRules`](../game/scenes/golf/golf_rules.gd)只持有整数、枚举、数组及RefCounted令牌，没有Node、Vector3、球场、存档或协议依赖。`RSGolfState.rules`为每人的权威计分状态；state只处理占位球、输入队列和复用的事件数组。

| API | 契约 |
|---|---|
| `reset_round(pars, slot)` | 三洞正par、P1–P4；清空全部洞并递增epoch。病态布局assert失败，不能构造有效局。 |
| `start_hole(index)` | 只能从首洞或已终态洞前进到下一洞，拒绝重复/跳洞，时钟归零。 |
| `command_key(seq, at_tick)` | 创建本rules所有者的CommandKey；按下B捕获上下文，释放时填入排队tick；提交后不可修改或重试。 |
| `try_stroke(command)` | 合法新命令加1杆并返回ShotKey；上下文无效拒绝。同上下文递增seq一经观察即消费，即使FLIGHT/DROP阻塞或tick不符；恢复后须新释放。 |
| `resolve_tick(next_tick, events)` | 每步一次批处理，返回是否发生规则转移；不在无事件tick创建数组/字典/令牌。 |
| `complete_drop(shot)` | 仅当前DROP的原始ShotKey可确认一次，回READY；旧局、旧洞、旧shot、另一rules及封顶后都拒绝。 |
| `ready/finished/stroke_count/score` | 查询当前状态；只有已终态洞贡献Stableford，未完成洞0分。 |
| `summary()` | 按需生成独立快照：总积分、总杆、已终态洞相对par、上限数，以及每洞par/杆/罚杆/分/状态/原因。修改快照不影响规则。 |

CommandKey和ShotKey均使用类型`RSGolfRules.StrokeKey`，包含slot/epoch/hole/seq/tick，并携带每个rules独有的owner身份。ShotKey还要求与内部当前令牌为同一对象；即使另一rules的所有数字相同也不能结算。令牌仅在内存中，不可序列化为网络协议或另造同数字的替代品，owner不回指rules，因而不会形成循环引用。

## 时钟与事件顺序

- 唯一比赛时钟是共享`hole_tick`，120Hz、每洞18000步；各人规则只验证同一时钟的连续步。渲染delta只进入一个累积器，不按渲染帧计杆；积压在当前有效PLAY阶段全部消费，比较容差保留浮点欠账。
- Command.tick表示**上一个已完成步**。17999仍允许新杆，随后仅剩一步；18000及以后拒绝新杆。已有球在18000这步结束时的接触仍先结算。这是两种不同的边界，不把“恰时出手”写成“恰时进洞”。
- 每步先消费排队输入/机器人命令，再推进占位飞行、批处理该步事件，最后才超时封顶；进入洞卡或RESULTS立刻停止余下积压，不把洞卡剩余delta带入新洞。暂停不累积也不清掉暂停前的半步，重开/换图清空旧局累积器。
- 换洞沿用G0的全员终态屏障。
- 负delta、NaN、非有限累积会明确报错并拒绝，不产生合法tick；规则跳步assert失败。重复已完成tick为无副作用的重试。
- `Event(key, kind, tick, order)`只接收当前FLIGHT、正确步号和当前ShotKey。order较小优先；相同时HOLED/WATER/OB/REST优先。重复事件只结算一次；几何接触先后必须由未来G3提供，G2没有判断真实碰撞。
- 真人断线由`controller_disconnected`或`roster_changed`事件立即取消armed和排队release，tick检查仍兜底；即使同一轮Hub轮询又重连也不能消费旧释放。保留球/规则/时钟，不改变`p.fake`，不自动接管，重连须重新按B。暂停/回中也取消尚未消费的释放。

## 规则与恢复边界

状态为`UNPLAYED → READY → FLIGHT → READY/DROP/HOLED/CAPPED`，DROP仅确认后回READY；终态只结算一次。

- 合法出手+1。达到`par+4`的最后一杆继续FLIGHT，HOLED仍记实际进洞；REST才拿起，原因`stroke_limit`。
- WATER/OB每杆最多+1罚杆，累计杆数封顶`par+4`；达到/超过上限立即CAPPED，原因`penalty_limit`，不再请求抛球。
- 未触顶时WATER返回`WATER_BACKTRACK`，OB返回`PREVIOUS_SHOT`，并保持DROP阻止下一杆；确认不再加罚。入水/界外检测、保存上一杆坐标、退2m/0.5m搜索/20m回退及合法落球验证全部留G3。
- 第18000步的进洞/罚杆先执行，再将未完成洞记`par+4`、原因`timeout`；进洞不会被超时覆盖，超时会取消待drop，后到/重复事件不能重开该洞。
- 每洞积分`max(0, 2+par-strokes)`。不重写公共排名；`[4,3,5]`与`[3,2,9]`分别12杆/E和14杆/+2，均6分并列；结果明细按“杆/分”列出各洞，不能暗中以总杆打破同分。

## 验收边界

`python tools/test_golf.py --godot <Godot>`使用临时用户目录，开始每个子进程前探测UDP 47800；占用则失败并等其他实例结束，不停止他人进程。常规六组为两地图×demo1/2/4，复用实际游戏场景；另外两个子进程分别输入负delta/NaN，要求唯一指定错误、退出1和拒绝标记，任何额外错误或资源泄漏仍失败。
规则表覆盖出手/罚杆幂等、阻塞release消费、跨rules隔离、旧epoch/hole/shot、最后一杆、期限前/恰时/之后、同tick先事件后timeout、恢复确认、Stableford并列及快照独立性。集成保留暂停/重开/换图/释放/禁纪录，并比较30/60/144Hz分帧及1秒积压的同一240 tick终态。

| 固定输入 | 预期结果 |
|---|---|
| 新命令seq=5出手，FLIGHT时seq=6被拒绝，REST后重传seq=6 | 仍为1杆，必须新命令才能再出手。DROP同样消费被拒绝release。 |
| 同一WATER/OB事件传入两次、再确认同一drop两次 | 仅1罚杆、仅第一次确认成功；跨rules或旧局/洞/shot均不能确认。 |
| par4第8杆分别HOLED/REST/WATER | 均8杆0分；前者HOLED，后两者CAPPED，不再drop。 |
| 分别在已完成步17999/18000请求新杆 | 前者尚可出手，后者拒绝。 |
| 已在FLIGHT的球分别于17999/18000/18001接触洞杯 | 前两种接触得分，后一种按超时0分，不能再开洞。 |
| release排队后disconnect或roster离线，同帧重连，随后推进一步 | 无出手、不接管；重连后须新按下并释放B。 |

Godot 4.7.2 headless实测：两图的demo1/2/4分别142/146/154项，共884项通过；两个非法delta子进程各1项通过，共886项。六组正常局零引擎错误、零环境诊断、无泄漏诊断及`records.cfg`；非法delta仅出现预期的单条拒绝错误。首次导入超时已保留日志，延长受控导入后成功；初版内部类型名冲突和单人提前完成的测试预期已修正后全矩阵重跑。

配套检查：工具69项及130子测试、中枢62项、Node素材测试8项、Ruff通过；规范0错误（3个原有大文件警告），i18n475项/0缺失/0多余，隐私扫描0发现，素材缓存222项一致且未下载。公共启动smoke使用仓库现有口径，仍单列保留的静态资源退出诊断，不能据此宣称全项目无泄漏。

本片未做新的GPU/FPS测量，不宣称真实抛球、碰撞或挥杆手感完成。G3须在维护者审查本片后另开内部切片，M1按[G0](GOLF_DESIGN.md)累计验收。
