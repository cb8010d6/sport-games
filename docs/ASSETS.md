# 素材下载与仓库内容

本项目不使用 Git LFS。源码和本地生成的成品通过普通 Git 分发；可以从原站恢复的
Poly Haven 二进制文件不进 Git，由脚本下载。现有本机文件不会因为忽略规则被删除。

## 克隆后的第一步

安装 Node.js 20 或更新版本，然后在仓库根目录运行：

```sh
node tools/sync_assets.mjs
node tools/sync_assets.mjs --check
```

通过后使用 Godot 打开 `game/project.godot`。不需要 Blender、npm 安装或 Git LFS。
中枢的 Python 环境仍按 [开发说明](DEVELOPMENT.md) 安装。

脚本处理 58 组 Poly Haven 素材、222 个文件，当前总量 799,958,793 字节，约 763 MiB。
已有且 SHA-256 一致的文件直接跳过；中断后重跑只会下载缺失或失败的文件。
单个未完成文件会重新下载，不支持该文件内部的 HTTP 断点续传。

```sh
node tools/sync_assets.mjs --list                # 离线查看来源、分组与大小
node tools/sync_assets.mjs --only clean_asphalt  # 只同步一组
node tools/sync_assets.mjs --check               # 离线校验全部下载文件
```

本地文件有修改时默认不覆盖。如果确认要用锁定版本替换，可显式添加 `--force`。
下载器不执行远端脚本、不解压任意压缩包，不自动更新到原站的新版本；下载失败会返回非零退出码。

## 哪些文件在哪里

| 内容 | 分发方式 | 来源与许可 |
|---|---|---|
| Poly Haven 原始纹理、HDR 天空和模型 buffer | 原站下载，Git 忽略 | 原站 CC0；逐文件记录在 `tools/assets.lock.json` |
| glTF 描述、Godot `.import` / `.uid`、来源清单 | 普通 Git | 保留来源与可移植配置 |
| 16 个角色及配套纹理（包含开发中的高尔夫） | 普通 Git | Blender/MakeHuman 系统素材生成，CC0；生成脚本在 `tools/blender/` |
| 6 组树木图集 | 普通 Git | 从 Poly Haven CC0 模型烘焙 |
| 4 个减面模型的 buffer 和 1 张加工纹理 | 普通 Git | 从 Poly Haven CC0 模型加工；17 张未改变的纹理直接引用原站同步文件 |
| 手柄模型、35 个成品音效、3 张贴花 | 普通 Git | 项目提供者确认 AI 原创，按项目 MIT；见 [来源声明](ASSET_PROVENANCE.md) |
| 下载缓存、工具、证书、日志和私人配置 | 仅本机，Git 忽略 | 不分发 |

以上 166 个角色/树木/减面生成文件约 673 MiB，最大文件 `skier1.glb` 约 22.3 MiB。
当前待发布游戏素材没有超过 50 MiB 的单文件，也没有超过 GitHub 普通 Git 的 100 MiB
单文件限制。总大小是未压缩文件之和，不代表首次克隆的实际传输量；后续频繁修改大文件会累积历史。

## 固定版本与隐私

`tools/assets.lock.json` 为每个下载文件记录相对路径、原站资产 ID、格式/分辨率、来源页、许可、
字节数、原始 SHA-256 和最终 SHA-256。下载器通过 `https://api.polyhaven.com/files/<资产ID>`
找到对应的官方文件 URL，校验成功后再安装到项目目录。下载和重定向只允许 Poly Haven HTTPS 域名。

一张沙地法线纹理的原文件带有电脑上的处理路径。脚本会清理 EXIF Software、EXIF ImageHistory
和 IPTC OriginatingProgram 中的路径记录，保留其他字段与原始图像编码数据；最终结果也必须
符合清单中的 SHA-256，避免重新下载时把路径带回来。

原站如果替换文件、移除旧格式或暂时不可用，脚本会报错，保留原有本机文件。维护者应审核新来源、
更新清单和 glTF 引用并验证游戏，再通过 PR 发布。不要直接绕过哈希检查。

Powered by Poly Haven：<https://polyhaven.com>。使用自定义 User-Agent 标识项目，保留
[API 服务条款](https://github.com/Poly-Haven/Public-API/blob/master/ToS.md) 要求的来源提示；
不表示官方背书。素材许可见 <https://polyhaven.com/license>。

## 修改素材的 PR

生成成品没有原站同名下载文件，直接修改并提交生成结果即可；重新生成时附使用的 Blender/MPFB
版本、脚本与参数。现有生成工具可以继续使用，普通玩家和一般代码贡献者无需安装这些工具。
对外部下载文件的加工结果应另存为生成文件，记录加工方式，避免原站同步覆盖修改。

下载器验证：

```sh
node --test tools/tests/asset_sync.test.mjs
```

2026-10-21 已从 Poly Haven 实际下载全部 222 个文件，随后离线校验全部通过，失败数为 0。
下载器另有模拟网络、损坏文件和元数据脱敏测试。原站可用性会变化，CI 每次打包都会重新校验。
