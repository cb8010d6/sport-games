# 编码规范

所有人和所有 AI 助手都按本文写代码。**必须**的规则违反就不能合并；**建议**的规则需要在 PR 里说明为什么不遵守。带 ID 的规则由 `python tools/check_conventions.py` 自动检查（CI 也会跑），审查意见引用规则 ID。

确实需要例外时，在那一行写 `# allow: 规则ID 原因`，例如 `# allow: GD-PARAM JSON 解析结果是 Variant`。审查时会逐个检查这些例外。

分层和模块职责见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 1. 通用（必须）

- **一个 PR 只做一件事**。不顺手重排格式、改名或"顺便优化"无关代码；需要重构就单独提 PR。
- **只改自己负责的区域**（见 [AGENTS.md](../AGENTS.md) 的分区表）。要改别人的区域，PR 说明里写"跨区修改"和原因。
- **跟周围代码保持一致**：命名、注释密度、写法都照现有代码，不引入第二种风格。
- **不新增依赖**（Python 包、Godot 插件、npm 包、CDN 脚本），除非 PR 说明了理由并经维护者同意。
- **不提交**：本机路径（SRC-PATH）、证书、密钥、设备地址、录制、构建产物、`.godot/`、下载缓存。
- **不删除**未完成的工作（尤其是高尔夫的角色、纹理、球场和生成脚本），除非维护者明确要求。
- **改了就要验证**：跑相关检查，并在 PR 里写出跑了什么、结果如何、什么没验证。没有验证过的事不写"已通过"。

## 2. GDScript（Godot 4.7.2）

### 类型（必须）

- **GD-RET**：每个函数写返回类型，包括 `-> void`。
- **GD-PARAM**：每个参数写类型（`a: int`）或用带默认值的推断（`b := 2`）。
- 变量写类型或用 `:=` 推断。真的是 Variant（JSON、`Dictionary.get`）时写 `var x: Variant = ...`。
- `for` 循环遍历对象数组时写元素类型：`for p: Player in players.values():`。
- 需要被别处当作类型使用的脚本，给它 `class_name`，不要用 `preload` 常量加无类型变量绕过。

### 命名与文件（必须）

- **GD-CLASS**：`class_name` 以 `RS` 开头，PascalCase：`RSSkateCourse`。文件名 snake_case，对应类名：`skate_course.gd`。
- **GD-UID**：每个 `.gd` 都提交对应的 `.gd.uid`（Godot 打开工程时生成）。
- 私有成员和私有函数以 `_` 开头；常量 `UPPER_SNAKE`；信号用过去时（`round_finished`）；`RSPartyGame` 的钩子以 `_` 开头，由项目重写。
- 缩进用 Tab，换行用 LF（`.gitattributes` 已设置）。

### 结构（必须）

- 新文件开头写 `##` 文档注释：这个类是什么、谁用它、关键约定（单位、坐标系）。参考 `core/sfx.gd`、`core/human_rig.gd`。
- 分层规则 **ARCH-CORE / ARCH-GAME**：`core` 不引用任何项目的类；项目之间不互相引用。
- **ARCH-SAVE**：只有 `game/core` 读写 `user://`。
- **ARCH-ARGS**：命令行参数只在 `party_game.gd`、`main_menu.gd` 解析；项目用 `_parse_arg()`。
- **ARCH-HAPTIC**：震动用 `haptic(p, name)`；**ARCH-AUDIO**：声音用 `RSSfx`，不要自己创建 AudioStreamPlayer。
- **ARCH-QUIT**：退出游戏用 `RSExit.quit(get_tree(), code)`，调用后直接 `return`；不要直接 `get_tree().quit()`。测试脚本可以直接退出。
- 界面外观来自 `RSUi`：根节点设置 `theme = RSUi.theme()`，颜色用 `RSUi` 的常量，面板和按钮用 `modal_style()`、`card_style()`、`button_style()`，主要操作按钮设 `theme_type_variation = &"RSPrimary"`。不要为单个控件新写颜色值或 `StyleBoxFlat`。说明见 [UI_THEME.md](UI_THEME.md)。
- 场景内容在代码里构建，`.tscn` 只放根节点和脚本（现有做法，避免多人改同一个 `.tscn` 产生冲突）。
- 不新增 autoload；不用 `get_node("/root/...")` 这类绝对节点路径。

### 写法（建议）

- 可调参数写成文件顶部的 `const`，注释写单位：`const JUMP_V := 4.2   ## m/s`。不要在代码中间写裸数字。
- 注释解释"为什么"，不复述代码做了什么。
- 玩法计时用 `delta`、`phase_time`，不用系统时间；只有输入时序（按键按住多久）可以用 `Time.get_ticks_msec()`。
- 机器人和随机场地用自己的 `RandomNumberGenerator` 并能设置种子，方便复现和自动测试。
- 每帧运行的代码里不创建节点、材质或数组；大量重复物体用 `RSProps` / MultiMesh。
- 出错用 `push_error` / `push_warning`，不要静默跳过。发布代码里不留调试 `print`（命令行和测试用的标记除外）。
- **SIZE**：单个脚本超过 1000 行时会被警告；新文件不要超过它，旧文件下次修改时拆分。

### 文案（必须）

- 玩家能看到的文字全部用中文原文包起来：节点里 `tr("中文")`，静态函数里 `RSLang.t("中文")`；英文写进 `game/i18n/en.json`。
- 不拼接句子，用格式化：`tr("第 %d 名") % rank`，中英文的 `%` 占位符数量一致。
- 不给玩家看的字符串（ID、路径、日志）在行尾标 `# no-i18n`。
- OLED 文字为 ASCII 大写，标题最多 10 个字符。
- `python tools/i18n_check.py` 必须是 0 缺失、0 多余。`en.json` 只追加或修改相关条目，不整体重排。

## 3. Python（hub/、tools/）

- Python 3.11+。公共函数写类型标注；用 `pathlib`；不用全局可变状态。
- hub 是 asyncio 程序：事件循环里不做阻塞调用（文件和网络用异步接口，或放进线程）。
- 改协议（hub ↔ 游戏，手机页面 ↔ hub）必须同时改 [protocol.md](protocol.md)、两端代码和测试，并兼容旧消息。
- 测试放在 `hub/tests/`、`tools/tests/`。`tools/tests` 的测试写成 `unittest.TestCase`，这样 `pytest` 和 `python -m unittest` 都能跑。
- 在安装依赖之前就要能跑的工具（检查、下载、构建）只用标准库。

## 4. 网页（hub/regina_hub/web/）

- 纯 HTML / CSS / JS，不用构建步骤、npm 包或 CDN；手机在局域网里离线也要能用。
- 界面文字通过 `RS.t()` 翻译，英文写在 `common.js` 的 `EN` 表。
- 手机传上来的内容都是不可信输入：hub 里清理，游戏里显示时转义（富文本用 `[lb]` 转义 `[`）。

## 5. Node 工具（tools/*.mjs）

- 只用 Node 自带模块，不加 `package.json` 和 npm 依赖。
- 开发者需要已修补的 Node：22.23.4+、24.22.1+ 或 26.12.1+（2026-10-21 安全更新）。Node 20 已停止维护。

## 6. 提交与 PR

- 从 `dev` 建分支，PR 目标是 `dev`；`main` 只接受维护者从 `dev` 合并。分支名 `<作者>/<主题>`，例如 `gpt-a/ci-node24`。
- 提交信息用前缀：`feat:`、`fix:`、`refactor:`、`test:`、`docs:`、`chore:`，一句话说明改了什么。
- PR 尽量小：除测试、素材和生成文件外不超过约 800 行改动；更大的改动先拆分或先开 Issue 讨论。
- PR 说明按模板写：问题、改动、验证（命令和结果）、没验证的部分。界面改动附 1600×900 截图（中英文各一张）。
- 不强推 `dev` 和 `main`，不改写别人的提交历史。
