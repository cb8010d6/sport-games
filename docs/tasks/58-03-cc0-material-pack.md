# 58-03 CC0 材质 ZIP → Poly Haven 命名的打包脚本

Issue #58 · P0 基础设施 · 区域：工具（`tools/`、`tools/blender/`）

## 目标 / 范围外

**目标**：ambientCG 只提供 ZIP，`sync_assets.mjs` 按设计不解压任意压缩包。按 `docs/ASSETS.md`“来源记录”的约定，少量外部材质走“手动下载 → 只留需要的贴图 → 转 Poly Haven 命名 → 提交 1K / 2K 成品”。本卡把这一步做成脚本，输出可直接被 `RSPbr.maps("shared:<名>")` 读取，并打印可以直接贴进 CREDITS 的记录行。

**范围外**：不加入任何真实材质（58-11 用本脚本做）；不联网下载（ZIP 由领卡人手动下载后作为输入）；不改 `RSPbr`。

## 先读

1. `game/core/pbr.gd:1-55`（`RSPbr` 读哪些文件名：`<name>_diff_<res>.jpg|png`、`_nor_gl_`、`_arm_`；diff 带 alpha 时用 PNG）
2. `game/assets/shared/materials/CREDITS.md`（输出要填的表头）
3. `tools/blender/audio_tool.py:1-40`（Blender 无界面脚本的参数写法、只用 Blender 自带的 numpy）
4. `tools/blender/bake_impostor.py:1-20`（另一个图像输出脚本的说明写法）
5. [58-00 概览](58-00-overview.md)“素材卡通用规则”

## 改动文件

- 新建 `tools/cc0_material.py`（纯 Python 规划逻辑，不 import bpy，pytest 可测）
- 新建 `tools/blender/pack_material.py`（Blender 无界面脚本，调用上面的模块做实际图像处理）
- 新建 `tools/tests/test_cc0_material.py`

## 接口契约

```
blender --background --factory-startup --python tools/blender/pack_material.py -- ZIP OUT_ROOT NAME RES
	# 例：... -- Net004A_2K-JPG.zip game/assets/shared/materials acg_net004a 1k
	# 输出 OUT_ROOT/NAME/NAME_diff_RES.(jpg|png)、NAME_nor_gl_RES.jpg、NAME_arm_RES.jpg
	# 标准输出最后打印每个输出文件一行 CREDITS 表格行（Markdown），以及 ZIP 和用到的每个条目的 SHA-256
```

```python
# tools/cc0_material.py
NAME_RE = r"^(acg|kn|mh)_[a-z0-9_]+$"     # 来源前缀：acg = ambientCG，kn = Kenney，mh = MakeHuman 社区包
RES_PX = {"1k": 1024, "2k": 2048}

def classify(entry_names: list[str]) -> dict[str, str]
	# ZIP 条目名 -> 角色：{"color", "normal_gl", "roughness", "ao", "metalness", "opacity"}。
	# 识别 ambientCG 命名 *_Color.jpg、*_NormalGL.jpg、*_Roughness.jpg、*_AmbientOcclusion.jpg、
	# *_Metalness.jpg、*_Opacity.jpg；*_NormalDX、*_Displacement、预览图忽略。没有 color 或 normal_gl 时报错。
def plan(name: str, res: str, roles: dict[str, str]) -> list[dict]
	# 每个输出文件：{"out": 文件名, "inputs": [条目名…], "op": "copy|pack_arm|rgba"}。
	# diff：有 opacity 时 op = "rgba"（颜色 + 不透明度进 alpha，输出 PNG），否则 JPG。
	# arm：R = ao（缺省 1.0）、G = roughness（缺省 1.0）、B = metalness（缺省 0.0），和 Poly Haven ARM 一致。
def credits_row(out_rel: str, page: str, asset_id: str, author: str, zip_name: str, zip_sha: str, cmd: str) -> str
	# 一行 Markdown，列顺序与 shared/*/CREDITS.md 表头一致；许可固定 CC0-1.0。
```

- 图像缩放到 `RES_PX[res]`（正方形；非正方形按长边缩放）；法线贴图缩放后不重新归一化（与 Poly Haven 1K/2K 的做法一致，写进说明）。
- JPEG 质量 90；PNG 8 位 RGBA。
- 输出前确认 `OUT_ROOT/NAME/` 不存在或为空，不覆盖已有成品。
- ZIP 在 Blender 里用标准库 `zipfile` 读到内存，不解压到磁盘；拒绝条目名里含 `..` 或绝对路径的 ZIP。

## 依赖与顺序

无依赖。58-11 依赖本卡。

## 验收

- `tools/tests/test_cc0_material.py`：`classify` 对一份真实 ambientCG 条目名列表（Net004A、Foam002 的条目名写进测试常量）分类正确；缺 Color 报错；`plan` 在有 / 无 Opacity 时分别给出 PNG / JPG；ARM 缺省值；`NAME_RE` 拒绝大写和非前缀名；`credits_row` 列数等于模板表头列数（读 `game/assets/shared/materials/CREDITS.md` 的表头算）。
- 手动验证（不进 CI）：用任意一个 ambientCG ZIP 跑一次，输出到临时目录，PR 里贴输出文件列表和打印的 CREDITS 行；不提交这次的输出。
- 命令：`python -m pytest -q tools/tests/test_cc0_material.py`；`python -m ruff check --config hub/pyproject.toml hub tools`；`python tools/check_conventions.py`。

## 不要做

- 不新增 Python 依赖（Pillow 等）；图像处理只在 Blender 里用 bpy + numpy。
- 不在 `sync_assets.mjs` 里加 ZIP 解压（issue 明确说数量多了再单独开工具 PR）。
- 不提交任何 ZIP 或成品。

## 预计规模

`cc0_material.py` 约 100 行，Blender 脚本约 120 行，测试约 80 行。
