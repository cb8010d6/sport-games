# 58-01 复核共享素材规范；每个共享文件都有 CREDITS 行的自动检查

Issue #58 · P0 遗留 · 区域：素材文档 + 工具

## 目标 / 范围外

**目标**：

1. 逐行复核 `docs/ASSETS.md`“共享素材库”一节（PR #88 的半成品没人逐行审过），和 issue #58 正文“目录与规范”对照，改掉不一致、过时或做不到的地方；
2. 新建 `tools/tests/test_shared_credits.py`，让“每个提交到 `game/assets/shared/` 的文件都在所在目录 CREDITS 里有一行、单文件 ≤ 20 MiB、总索引文件数和实际一致”成为 CI 自动检查。之后所有素材卡的验收都靠它。

**范围外**：新增任何素材；改 `RSPbr` / `RSProps`；角色导入设置（53-05）。

## 先读

1. `docs/ASSETS.md:81-169`（“共享素材库”整节）
2. issue #58 正文的“目录与规范”和“来源记录”两节（`gh issue view 58`）
3. `game/assets/shared/CREDITS.md`（总索引）和任意一个子目录模板，例如 `game/assets/shared/arena/CREDITS.md`
4. `tools/asset_policy.json`（`documented` 列表里 `game/assets/shared/` 那条）、`tools/asset_policy.mjs`
5. `tools/tests/test_music_assets.py`（`tools/tests` 里检查素材文件的写法）
6. [58-00 概览](58-00-overview.md)“素材卡通用规则”

## 改动文件

- `docs/ASSETS.md`（只改“共享素材库”一节）
- 新建 `tools/tests/test_shared_credits.py`
- 如复核发现模板列不够用：`game/assets/shared/**/CREDITS.md` 模板（只改表头说明，不加内容）

## 接口契约

复核时至少处理这几处（写卡时已发现）：

- “来源记录”表写“用同步工具生成 `tools/assets.lock.json` 条目”，仓库里还没有这样的工具 → 改为指向 `tools/lock_polyhaven.mjs`（58-02 新建，名字以本卡为准写死）。
- ambientCG 的处理写的是手工步骤 → 改为指向 `tools/blender/pack_material.py`（58-03 新建，名字写死）。
- `docs/ASSET_MANIFEST.json` 只说“重新生成”，没写命令 → 补：`node tools/publication_audit.mjs --write audit-output`，再复制 `audit-output/asset-manifest.json`；没有二进制变化时不重生成。
- 人物目录：ASSETS.md 写 `roster/<avatar_id>/`、`outfits/<sport>/`。58-04 提议改成“每个（项目, avatar）一个完整 glTF”。本卡**不改**这段，只在文字旁加“以 58-04 合入时的约定为准”，避免两处说法打架。
- 导入设置表下加一句：用 `python tools/texture_imports.py --check` 检查（53-05 新建）。

`tools/tests/test_shared_credits.py`（pytest，不需要 Godot，稀疏检出时 `game/assets/shared/` 只有 CREDITS 也能通过）：

```python
SHARED = ROOT / "game/assets/shared"
IGNORED_SUFFIXES = {".import", ".uid"}       # Godot 旁车文件不需要 CREDITS 行
MAX_BYTES = 20 * 1024 * 1024
LICENSES = {"CC0-1.0", "MIT AND CC0-1.0", "MIT"}

def credits_for(path: Path) -> Path          # 从文件所在目录往上找最近的 CREDITS.md，最远到 SHARED
def credited_files(credits: Path) -> dict[str, str]
	# 解析 CREDITS.md 里的 Markdown 表格：第 1 列是相对 CREDITS 所在目录的文件路径（反引号包裹），
	# “许可”列是许可；返回 {相对路径: 许可}。表头行和分隔行跳过。
```

测试项：
- `SHARED` 下每个文件（排除 `CREDITS.md` 和 `IGNORED_SUFFIXES`）都出现在 `credits_for()` 找到的那份 CREDITS 表里，许可在 `LICENSES` 内；
- 每个文件 ≤ `MAX_BYTES`；
- CREDITS 表里列出的文件都真实存在（防止删文件忘了删行）；
- `shared/CREDITS.md` 总索引表“文件数”列等于该子目录下实际计入的文件数。

## 依赖与顺序

无依赖，建议在其他 #58 卡之前合入（之后的卡用它验收）。58-02 / 58-03 可以同时做，它们按本卡写死的工具名实现。

## 验收

- `python -m pytest -q tools/tests/test_shared_credits.py`（当前仓库 0 个共享文件，应通过；再在临时目录造一个“有文件没 CREDITS 行”的例子，确认会失败——用 `tmp_path` 和可替换的 `SHARED` 参数做）。
- `python -m pytest -q tools/tests`、`python -m ruff check --config hub/pyproject.toml hub tools`、`node --test tools/tests/asset_sync.test.mjs`。
- PR 说明里逐条列出 ASSETS.md 改了什么、为什么（对照 issue 原文哪一句）。

## 不要做

- 不改 ASSETS.md 共享库以外的章节（下载器、隐私等）。
- 不改预算数字（那是 issue 定的，需要维护者同意）。
- 不在 CI 工作流里加新步骤（`tools/tests` 已经在 CI 里跑）。

## 预计规模

文档改 20–40 行；测试约 120 行。
