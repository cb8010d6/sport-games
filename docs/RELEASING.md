# 分支和 Windows 发行

`main` 保存经过检查的版本，`dev` 接受日常 PR，`experiment/nvidia-rtx` 隔离 NVIDIA 引擎实验。
标准发行固定 Godot 4.7.2，不在 `main/dev` 中切换到实验引擎。

## 构建与下载

每次提交到 `main/dev` 或向它们提交 PR，GitHub Actions 的 **Windows package** 都会：

1. 扫描隐私和素材声明，下载并校验锁定的 Poly Haven 文件。
2. 校验官方 Godot 和导出模板的 SHA-512，用 Linux runner 导入并交叉导出 Windows 游戏。
3. 在 Windows runner 冻结 Python 中枢和启动器，包含手机网页及第三方声明。
4. 检查 HTTP、HTTPS、WebSocket、启动器、各游戏地图和篮球 1/2/4 人启动。
5. 打包 ZIP 和 SHA-256，保存为 Actions artifact（7 天）。

Python 依赖从带哈希的 `hub/requirements-windows.txt` 安装（`pip --require-hashes`），
包含 `tools/release_config.json` 原先指定的 PyInstaller 版本；工作流会检查两者一致。
依赖升级后按 [DEVELOPMENT.md](DEVELOPMENT.md#updating-python-dependencies) 重新生成并提交锁文件。
Actions 固定到完整提交 SHA；升级和 artifact 兼容性记录见同文的 Actions upgrade notes。
Node 工具使用 `24` 的最新修补版（`check-latest: true`）；不需要 npm 依赖。
触发条件、打包内容、版本号规则和 artifact 的名称、路径及保留天数沿用现有发行流程。

玩家解压后运行根目录 `SportGames.exe`，无需开发环境或另行同步素材。
无界面测试不覆盖图像正确性、BLE、手机权限流程、网络防火墙和 GPU 性能；发布前仍应实机检查。
官方发行模板禁用命令行场景路径覆盖。测试通过菜单内六个固定游戏 ID 选择玩法，
例如 `./game/SportGames.exe -- --game=basketball --demo=4 --map=1`；不接收任意场景文件路径。
同仓库 `dev` PR 通过全部检查后，若合入 main 的文件树完全相同，第一次 main 构建可恢复该 PR
的导入结果，随后重新导出并做 Windows 检查。外部 Fork 的导入缓存不用于此步骤。
导入交接 artifact 保留 1 天；不存在或已过期时回退正常导入，日常构建优先使用 Godot 导入缓存。
当前游戏的静态资源缓存会在退出时报告资源仍被引用；启动检查保留这项警告但不将其视为加载失败。
脚本错误、缺失资源及其他 ERROR 即使进程返回 0 也会阻止打包。退出清理仍是后续可优化项。

## 发布

在 PR 检查通过后将 `dev` 合入 `main`。第一次成功的 main 构建会发布 `tools/release_config.json`
指定的初始预发布 `v0.1.0-alpha.1`；该 Release 存在后不再覆盖。后续可在对应的 `main` 提交上建立并推送 `v*` 标签：

```sh
git switch main
git pull --ff-only
git tag v0.1.0-alpha.2
git push origin v0.1.0-alpha.2
```

标签触发完整构建；只有构建成功且提交位于 `main` 的历史中，才创建带 ZIP/校验和的 GitHub 预发布。
目前所有标签都发布为 prerelease。达到稳定条件后再明确修改工作流；不要仅靠去掉版本名中的 alpha 宣称稳定。

## 主分支规则

审阅后的配置位于 `.github/rulesets/main.json`：禁止删除和强推、要求 PR、对话解决以及五项 CI 检查。
GitHub 不会自动应用仓库中的 JSON。维护者使用具有仓库管理权限的 GitHub CLI 登录后运行：

```sh
python tools/apply_repository_rules.py
```

脚本幂等更新同名 ruleset 并读取验证。连接器可以提交代码，但未提供管理规则的写入能力，
所以不能把提交 JSON 当作 GitHub 已开启保护。可在仓库 Settings → Rules → Rulesets 核实状态。
