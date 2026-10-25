# #52：回合与派对大赛中断恢复

结论：射箭／保龄球时限、缺员继续大赛及二次 C 退出已实现并通过下述历史验收。当前正常合并 dev `24097b1`，保留 #75 的 Hub 生产时钟修复、#79 的换图画质重应用及 #83 的 `finish_round` 防重入／OLED 去重；#82 已被 #75 取代。新整合及暂停取消回归仍待执行，PR 保持 draft；CI 全绿且相关回归通过后可转 ready，由维护者合并。

## 规则与接口

- 射箭每支待射箭最多等待 20 秒有效 SHOOT 时间；超时按 0 环消耗一箭，取消拉弓。按键和重连不续期；已飞出的箭沿用原物理并只结算一次，迟到松开不能生成箭。
- 保龄球每次 AIM 最多等待 20 秒；超时经正常换球／换格接口记 0 瓶，不扫描旧倒瓶。原 SWING 超过 6 秒自动出手、ROLLING／SETTLE 时限和第十格加球规则保留。
- 大赛至少一人在场，且在场的原参赛者全部准备后即可继续。缺席者本项加 0 大赛积分，保留此前积分和原槽位，下项可重新加入；在场者按实际竞赛名次得分。PLAY 中断线仍保留玩家，不以移除玩家替代超时结算。
- 有效大赛的大厅／成绩／总领奖台中，首次 C 只显示确认；同一有效在场手柄在 3 秒内再次 C 才清空大赛并回菜单，恰到 3 秒须重新确认。其他按键、换阶段、重开或确认者断线取消；陌生对象、不同手柄不能组合确认。普通单项目仍单次 C 返回，暂停菜单明确选择回菜单及总领奖台 A 返回沿用原规则。
- 所有玩法和确认时钟使用现有 `delta`／阶段时钟，树暂停即冻结；重开／换箭／换球／换项目重置对应状态。演示与回归不写个人纪录。
- 跨区范围仍为射箭、保龄球及现有公共回合／大赛／UI。`RSPartyGame` 独占阶段和退出，`RSTournament.ExitGuard` 每实例独占，只保存身份、槽位、阶段和时限；`RSPartyUi` 只显示提示，确认期间隐藏普通 footer 并为确认条保留内容空间。无新增协议、业务存档、autoload、素材或依赖。

暂停取消的本次接口设计先于实现记录：#78 尚未合入 dev，当前框架会丢弃暂停中的 release。射箭在 `super._ready()` 后连接现有 `ui.pause.visibility_changed`，菜单显示时调用项目内 `_player_cancel_hold(p, BTN_A)`；只清 `drawing`、`draw_t` 和力量条，不 release、不扣箭、不重置 `wait_t`。同名钩子与 #78 当前设计一致，重复调用、超时后、RESULTS 或无玩家时均须安全。#78 落地后框架可接管暂停 release／断线取消；本项目的暂停入口取消可保留为幂等保护，不在本 PR 复制框架钩子或 `button_cancelled` 信号。

## 测试覆盖与证据边界

| 范围 | 自动覆盖 |
|---|---|
| 射箭／保龄球实际场景 | 两项目×2／4 人×中英文，idle／disconnected 共 16 组，自然等待有限时长内进入 RESULTS；截止前／恰到／截止后、重复按键、迟到 release、重连、暂停、重开、飞行箭单次结算、首／次球及 5／10 格加球 |
| 本次新增 | 真实 UDP 拉弓→他人暂停→松手→恢复：箭数组、余箭、命中及分数不变，可重新拉弓，原截止时间不续期；同名取消重复调用及超时后／RESULTS／空玩家安全；自然超时 `finish_round()` 只调用一次，RESULTS 后输入及超时入口不重复结算 |
| 大赛与退出 | 2／4 人各 normal／missing／exit，共 6 组；实际大厅移除缺席者、累计积分／本项 0 分／下项回归、零人在场、同手柄二次 C 与身份／阶段／断线／其他按键撤销；保留原 23 条退出／输入／积分断言及新增 UI 几何恢复断言 |
| UI | 中英文、125% 字号、2560×1080；内容与确认条在窗口内且互不重叠，确认隐藏普通 footer，取消／到期／换页恢复原几何 |
| 基础检查 | 规范、i18n、工具／Hub 单测、Node 素材工具、隐私、相关 lifecycle／party-flow、公共 smoke 和 CI；五根用户目录隔离，拒绝写入 `records.cfg*` |

已执行的历史验收保留各自源码边界，不能视为本次整合重跑：

- `9e21ff4`：16 组运动恢复、4 组普通生命周期、15 项公共 smoke 全部通过；私有证据编号 `concentrated-acceptance-20261025-B` 下的 `idle73`、`disconnected73`、`ordinary73`、`smoke73`。
- `3aa7c45`（game tree `908956987e90a2c13fd09958c7d99b5168b25c2a`）：6 组大赛及 shell／storage 通过，storage 65 项、重新打开检查通过；编号 `party73-attempt2`。此前规则源码未变，生产差异仅确认条布局。
- 同源码 D 轮：射箭 2P 中文／4P 英文、保龄球 2P 英文／4P 中文，共 208 项检查、12 张原始 PNG 和 4 份取消后几何 JSON 通过；编号 `recovery-ui-20261025-D/runs`。内容位于确认条上方，取消恢复同一控件和原几何，容差 0.5 物理像素。主审目视检查四例首次 C 原图。C 轮原图中 footer 被遮挡的发现仍保留，未改写成 D 轮通过。

历史图形验收使用官方 Godot 4.7.2、隐藏桌面及 `--fixed-fps 60` 合成输入；不提供 FPS、真机手感、BLE、手机或 HDR 结论。本次整合不得以旧截图证明新调用路径已经验证。

## 回归入口

```sh
python tools/test_lifecycle.py --godot <official-Godot-4.7.2> --games archery bowling --players 2 4 --languages zh en --round-recovery idle --output <new-idle-directory>
python tools/test_lifecycle.py --godot <official-Godot-4.7.2> --games archery bowling --players 2 4 --languages zh en --round-recovery disconnected --output <new-disconnected-directory>
python tools/test_lifecycle.py --godot <official-Godot-4.7.2> --games archery bowling --players 2 4 --output <new-ordinary-directory>
python tools/test_game.py --godot <official-Godot-4.7.2> --party-recovery --party-output <new-party-directory>
python tools/smoke_game.py <official-Godot-4.7.2> --project game
```

恢复入口要求新输出目录并保留失败记录；启动异常、超时、非零退出、缺少完成标记或写入纪录均为失败。本次整合的 CPU 检查：规范 0 错误／4 项既有 SIZE 警告，i18n 481 项／0 缺失／0 多余，工具 88 项及 256 子测试、Hub 150 项、Node 9 项全部通过，Ruff、隐私及 diff-check 通过。Godot 解析、上述新整合回归及最新 CI 仍由主审独占图形会话后执行，结果应按实际源码与输出记录。
