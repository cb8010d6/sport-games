# 给 AI 助手和协作者的说明

这是 Regina Sports：Godot 4.7.2 体感运动派对游戏（`game/`）+ Python 手柄中枢（`hub/`）+ 可选固件（`firmware/`）。开始写代码前，先读：

1. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)：分层、模块职责、新功能放哪里
2. [docs/CODING_STANDARDS.md](docs/CODING_STANDARDS.md)：规则（带 ID 的由脚本检查）
3. [docs/REVIEW_CHECKLIST.md](docs/REVIEW_CHECKLIST.md)：你的 PR 会按这份清单审查
4. 你的任务说明里列出的文件

## 硬性规则

- 从 `dev` 建分支，PR 目标是 `dev`。不要推送到 `main` 或 `dev`，不要强推，不要改写历史。
- **只改任务说明里指定的区域**（下表）。需要改区域外的文件时，停下来在 PR 说明里提出，不要直接改。
- 不新增依赖、autoload、存档文件或协议消息，除非任务说明允许。
- 不删除未完成的工作（尤其是 `game/scenes/golf/` 和高尔夫素材）。
- 不提交本机路径、证书、密钥、设备地址、录制、`.godot/`、构建产物、下载缓存。
- 不使用 Git LFS。新素材必须记录来源和许可。
- 跟周围代码保持一致；不重排无关代码的格式。
- 如实报告：PR 里写清楚跑了哪些检查、结果如何、哪些没验证（真机手感、BLE、HDR、画面）。

## 提交前必须通过

```bash
python tools/check_conventions.py
python tools/i18n_check.py
python -m pytest -q tools/tests
python -m ruff check --config hub/pyproject.toml hub tools
cd hub && python -m pytest -q
node --test tools/tests/asset_sync.test.mjs
```

改了游戏代码：用 Godot 4.7.2 跑受影响的项目（`--demo=2`、`--demo=4`），并跑 `python tools/smoke_game.py <Godot> --project game`。

## 分区

| 区域 | 路径 | 负责人 |
|---|---|---|
| 框架（主线） | `game/core/`、`game/autoload/`、`game/project.godot`、`game/scenes/menu/`、`docs/protocol.md`、`docs/ARCHITECTURE.md`、`docs/CODING_STANDARDS.md`、`docs/REVIEW_CHECKLIST.md`、`AGENTS.md` | 维护者 / Claude |
| 中枢 | `hub/` | 按任务分配 |
| 工具与 CI | `tools/`、`.github/` | 按任务分配 |
| 运动项目 | `game/scenes/<项目>/` | 按任务分配；同一时间一个项目只给一个人 |
| 素材 | `game/assets/`、`docs/ASSETS*.md`、`docs/THIRD_PARTY.md` | 按任务分配 |
| 共享文件 | `game/i18n/en.json`、`README.md`、`docs/roadmap.md` | 谁都可以改，但只追加或改相关的几行 |

框架区由维护者负责（`.github/CODEOWNERS`）。其他人需要框架提供新接口时，在 PR 或 Issue 里写清楚需求，由主线实现。

## 常用命令

```bash
node tools/sync_assets.mjs                      # 下载 Poly Haven 素材（首次）
python -m venv hub/.venv && hub/.venv/Scripts/python -m pip install -r hub/requirements.txt
<Godot> --path game -- --game=skate --demo=2    # 直接进入某个项目，2 个机器人
<Godot> --path game -- --game=ski --map=2 --demo=4 --shots=out/ski   # 截图后退出
```
