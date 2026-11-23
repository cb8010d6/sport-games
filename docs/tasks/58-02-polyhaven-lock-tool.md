# 58-02 Poly Haven 锁定条目生成工具

Issue #58 · P0 基础设施 · 区域：工具（`tools/`）

## 目标 / 范围外

**目标**：新建 `tools/lock_polyhaven.mjs`，一条命令完成“查 Poly Haven API → 下载 → 算哈希 → 写 `tools/assets.lock.json` 条目 → 追加 `game/assets/polyhaven/CREDITS.md`”。之后加 Poly Haven 纹理 / 模型 / HDRI 的素材卡（58-08、58-10、58-15、58-16、58-19、58-20、58-22、58-23）都用它，不再手写哈希。

现状：`tools/fetch_polyhaven.py` 只下载并写 CREDITS，不写锁定清单；`tools/sync_assets.mjs` 只按已有锁定条目下载 / 校验。

**范围外**：不加任何新素材（测试用假数据）；不改 `sync_assets.mjs` 的下载 / 校验行为；不支持 Poly Haven 以外的站点。

## 先读

1. `tools/sync_assets.mjs:12-71`（`sha256`、`safePath`、`validateUrl`、`request`、`validateManifest`：锁定条目的字段和校验规则）、`:73-130`（`resolveFile`、`installAsset`：选择器和 `transform` 的含义）
2. `tools/asset_metadata.mjs`（`sanitizeJpegProcessingHistory`：JPEG 路径信息清理）
3. `tools/fetch_polyhaven.py:45-80`（每类素材取哪些文件、CREDITS 行格式，照抄）
4. `tools/tests/asset_sync.test.mjs:1-30`、`:68-72`（假响应、选择器的测试写法）
5. `tools/assets.lock.json` 开头的字段和任意一个纹理 / 模型 / HDRI 条目

## 改动文件

- 新建 `tools/lock_polyhaven.mjs`
- `tools/tests/asset_sync.test.mjs`（追加测试；CI 只跑这一个 node 测试文件，`.github/workflows/ci.yml:70`）
- `docs/ASSETS.md`（“修改素材的 PR”下加 3 行用法；58-01 先合入时改它写好的那句）

## 接口契约

```
node tools/lock_polyhaven.mjs add --kind textures|models|hdris --res 1k|2k|4k [--purpose TEXT] [--dry-run] ASSET_ID ...
```

每类取的文件和选择器（与现有锁定条目一致）：

| kind | 文件（相对 `game/assets/polyhaven/`） | selector | 进锁定清单？ |
|---|---|---|---|
| textures | `textures/<id>/<id>_diff_<res>.jpg` | `["Diffuse", res, "jpg"]` | 是 |
| | `textures/<id>/<id>_nor_gl_<res>.jpg` | `["nor_gl", res, "jpg"]` | 是 |
| | `textures/<id>/<id>_arm_<res>.jpg` | `["arm", res, "jpg"]` | 是 |
| hdris | `hdris/<id>/<id>_<res>.hdr` | `["hdri", res, "hdr"]` | 是 |
| models | `models/<id>/<gltf 文件名>` | — | **否**：`.gltf` 描述进 Git |
| | `models/<id>/<include 相对路径>`（`.bin`、`textures/*.jpg`） | `["gltf", res, "gltf", "include", <相对路径>]` | 是 |

每个锁定条目：`{path, asset, sourcePage: "https://polyhaven.com/a/<id>", license: "CC0-1.0", selector, bytes, sha256, downloadSha256}`，有 `--purpose` 时加 `purpose`。JPEG 下载后调用 `sanitizeJpegProcessingHistory`：结果和原文件不同时写 `transform: "jpeg-processing-history-v1"`，`sha256` 为清理后的哈希；相同时 `sha256 == downloadSha256`、不写 `transform`。

- 只用 `sync_assets.mjs` 导出的 `request` / `validateUrl` / `safePath` / `sha256` / `validateManifest`，不复制一份下载逻辑；下载域名限制因此和同步工具一致。
- 写回前对整个清单跑 `validateManifest()`；已存在同一 `path` 的条目时报错退出（不覆盖）。新条目追加到 `files` 末尾，JSON 两空格缩进、末尾换行（和现有文件一致）。
- CREDITS 行格式照 `fetch_polyhaven.py` 的 `credit()`：``- <kind 单数> `<id>` (<名称>) by <作者, …>: https://polyhaven.com/a/<id>``，已有同一行不重复加。
- 结束时打印 `RS_LOCK_ADDED: <n> files, <bytes> bytes`，素材卡用它更新 `docs/ASSETS.md` 的文件数 / 字节数。
- `--dry-run`：只查 API、打印将要写的条目和总字节数，不下载、不写文件（素材卡在 PR 里用它报预算）。
- 导出 `planFiles(kind, res, id, filesJson) -> [{path, selector, url, size, locked: boolean}]` 供测试（纯函数，不联网）。

## 依赖与顺序

无依赖。58-01 在 ASSETS.md 里写死了本工具的文件名，两张卡可以同时做。

## 验收

- `tools/tests/asset_sync.test.mjs` 追加：
  - `planFiles` 对三类素材生成的路径和选择器与上表一致（用手写的 API 片段）；
  - 用假 fetcher 跑一次 `add`（目标目录用临时目录）：写出的条目通过 `validateManifest`，`bytes` / 哈希正确；带路径信息的 JPEG（复用现有 `historyJpeg()`）会写 `transform`；
  - 重复添加同一个文件报错，清单不变。
- 命令：`node --test tools/tests/asset_sync.test.mjs`；`python tools/check_conventions.py`（`.mjs` 也查 SRC-PATH）；`node tools/sync_assets.mjs --check`（现有清单不受影响）。
- 不联网的测试必须能在 CI 里跑；PR 里可以附一次对真实 API 的 `--dry-run` 输出（不提交下载结果）。

## 不要做

- 不改 `sync_assets.mjs` 的现有导出函数签名。
- 不提交任何新的 Poly Haven 文件或锁定条目（那是各素材卡的事）。
- 不加 npm 依赖。

## 预计规模

工具约 160 行，测试约 80 行。
