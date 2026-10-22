# 代码审查清单

给人和 AI 审查者用。每条意见引用规则 ID 或本文的条目号，写清文件、行号、问题、会造成什么后果和建议的改法。规则全文见 [CODING_STANDARDS.md](CODING_STANDARDS.md)，分层见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 严重程度

| 级别 | 含义 | 能否合并 |
|---|---|---|
| **阻断** | 功能错误、崩溃、数据丢失、违反"必须"规则、破坏分层、泄漏隐私、许可证问题 | 改完才能合并 |
| **重要** | 明显的维护或性能问题、缺少必要测试、文档和代码不一致 | 原则上改完再合并 |
| **次要** | 可读性、命名、注释 | 作者决定 |
| **吹毛求疵** | 个人偏好 | 只提，不要求改 |

只报告有把握的问题；不确定时写明"需要确认"以及怎么确认。

## 步骤

1. 看 PR 说明：目标是否清楚、是否只做一件事、目标分支是否为 `dev`、是否写了验证结果和没验证的部分。
2. 拿到差异：`git fetch origin pull/<编号>/head:pr<编号>`，然后 `git diff origin/dev...pr<编号>`。
3. 跑自动检查（见下节），把失败当作阻断意见。
4. 按下面的清单逐项看代码。
5. 给结论：**可以合并** / **改完再合并**（列出阻断和重要项）/ **不建议合并**（说明原因）。

## 自动检查

```bash
python tools/check_conventions.py          # 规范（GD-*、ARCH-*、SRC-PATH）
python tools/i18n_check.py                 # 中英文：0 缺失、0 多余
python -m pytest -q tools/tests            # 工具测试
cd hub && python -m pytest -q              # 中枢测试（改了 hub 时）
node --test tools/tests/asset_sync.test.mjs
node tools/publication_audit.mjs --privacy-only
```

改了游戏代码时，再用 Godot 4.7.2 跑一次无界面启动：`python tools/smoke_game.py <Godot> --project game`。无界面通过不代表画面和手感没问题。

## 清单

### A. 范围
- A1 只改了与目标相关的文件；没有顺带的重排格式或改名。
- A2 跨区修改（见 AGENTS.md 分区表）在说明里写了原因；改 `core`、autoload、`project.godot`、菜单、协议的，维护者已同意。
- A3 没有删除未完成的工作（高尔夫等）或别人的代码。

### B. 架构
- B1 依赖方向正确：`core` 不引用项目，项目之间不互相引用（ARCH-CORE、ARCH-GAME）。
- B2 用了现有公共模块（ARCHITECTURE.md 第 3 节），没有在项目里重写一份手势、震动、音效、界面、设置或存档。
- B3 项目只重写 `RSPartyGame` 钩子，没有自己做大厅、倒数、成绩或暂停。
- B4 改了钩子或公共接口时，所有项目都在同一个 PR 里改好；新钩子有默认实现。
- B5 改协议、存档格式或文案 key 时兼容旧数据，文档同步。

### C. 正确性
- C1 边界情况：0 / 1 / 4 个玩家、玩家中途断线和重连、机器人（`p.fake`）、重开一局、多次按键、地图切换。
- C2 回合状态：`finish_round()` 只调用一次；重开后状态清干净；暂停时（树暂停）不再推进玩法。
- C3 信号连接和节点在场景切换、重开时不会重复或泄漏。
- C4 数学和单位：角度用弧度还是度、坐标轴方向（-Z 为前）、帧率无关（用 `delta`）。
- C5 存档读到损坏或旧格式的文件时不会崩溃。

### D. 规范
- D1 GDScript 全部有类型（GD-RET、GD-PARAM）；Variant 写明。
- D2 命名、`class_name`、`.uid`、文件开头的 `##` 说明。
- D3 玩家可见文字都经过 `tr()` / `RSLang.t()`，`en.json` 已更新；OLED 为 ASCII。
- D4 没有裸数字参数、调试 `print`、注释掉的旧代码。
- D5 `# allow:` 例外有充分理由。

### E. 性能
- E1 每帧代码里没有创建节点、材质、数组或字符串拼接。
- E2 大量物体用 MultiMesh（`RSProps`），材质缓存复用（`RSPbr`）。
- E3 新的画面效果遵守 `RSSettings` 的画质档位，分屏 4 人时开销可接受。

### F. 测试与验证
- F1 新逻辑有自动测试（规则、存档、协议、工具）；纯画面改动有截图。
- F2 PR 写的验证结果可信：命令和输出对得上，没把"没跑"写成"通过"。
- F3 需要真机的部分（手感、BLE、HDR、手机权限）明确列为未验证。

### G. 安全、隐私与许可
- G1 没有密钥、证书、本机路径、设备地址、真实个人信息。
- G2 新素材有来源、作者、许可和加工记录；没有无法核实来源的资源。
- G3 手机和网络传来的数据都经过检查和转义。
- G4 没有新增依赖，或新增依赖已说明并经同意。

## 给 AI 审查者的提示词

把下面这段连同 PR 链接发给审查用的 AI：

> 你在审查 https://github.com/cb8010d6/sport-games 的一个 PR，目标分支是 `dev`。先读仓库里的 `AGENTS.md`、`docs/ARCHITECTURE.md`、`docs/CODING_STANDARDS.md` 和 `docs/REVIEW_CHECKLIST.md`，然后按 REVIEW_CHECKLIST.md 的步骤审查。只报告有把握的问题，每条写：级别（阻断 / 重要 / 次要 / 吹毛求疵）、规则 ID 或清单条目、文件:行号、问题、后果、建议改法。你没有实际运行的检查要写明"未运行"。最后给出结论：可以合并 / 改完再合并 / 不建议合并。不要修改代码，不要在 GitHub 上发评论。
