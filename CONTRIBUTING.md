# Contributing to Regina Sports

欢迎提交 Issue 和 Pull Request。游戏、电脑中枢和可选固件都位于本仓库内；
父目录的 Regina 项目不属于本仓库，也不应随 PR 提交。

## 开始开发

1. Fork 仓库并克隆，安装 Node.js 20+，执行 `node tools/sync_assets.mjs` 取得原站素材。
   生成成品随普通 Git 克隆；不使用 Git LFS。详见 [素材说明](docs/ASSETS.md)。
2. 使用 Godot 4.7.2 打开 `game/project.godot`。Python 中枢的安装和固件依赖见
   [开发说明](docs/DEVELOPMENT.md)。
3. 从 `dev` 建立功能分支，PR 目标选择 `dev`。`main` 用于通过验证的发布版本；维护者通过 PR 将 `dev` 合入 `main`。
4. 每个 PR 聚焦一个问题；先描述现象、预期行为和修改原因。较大的玩法和协议改动请先开 Issue 讨论。

## 提交前

- 中枢修改：在 `hub` 下执行 `python -m pytest -q`。
- 游戏修改：运行受影响的游戏，检查大厅、开始、暂停、重开、结算和返回菜单；
  涉及多人界面时检查 2 人和 4 人分屏。
  自动无界面检查可运行 `python tools/smoke_game.py <Godot可执行文件> --project game`，它不替代画面和手柄实测。
- 体感修改：说明测试用手机还是 Regina；检查短挥动、长按、断线与重连。
- 文案修改：执行 `python tools/i18n_check.py`，检查中英文。
- 安装 Node.js 20+ 后可执行 `node tools/publication_audit.mjs --strict --write audit-output`；
  这是开发检查，不是游戏的运行依赖。也应执行 `node --test tools/tests/asset_sync.test.mjs`。
- 不提交本机证书、密钥、设备地址、用户数据、录制、环境目录、构建结果和下载缓存。
  不要使用真实个人信息制作测试数据；用明确标注的示例值。

## 素材和许可

新增或修改图片、模型、音效时，在 `docs/THIRD_PARTY.md` 和素材清单中记录
原始链接、作者、许可证、原文件标识及加工方式。免费使用不等于允许把源素材公开再分发。
不要提交从商业游戏提取的素材、未获许可的角色/商标图案、个人照片或无法核实来源的资源。

项目原创代码及维护者声明的 AI 原创素材按 [MIT](LICENSE) 授权；第三方素材保留各自许可证。提交 PR 表示你有权
贡献相应内容，并同意按对应文件的项目许可证提供贡献。署名和版权声明应予保留。

发现潜在密钥或隐私泄漏时，先私下联系维护者，不在公开 Issue 中粘贴敏感值。
