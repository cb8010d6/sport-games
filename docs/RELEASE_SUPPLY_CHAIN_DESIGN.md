# #43 发行许可与构建供应链设计

状态：待审设计，尚未实施。范围是 [issue #43](https://github.com/cb8010d6/sport-games/issues/43) 的 A 组剩余项和 H 组；不关闭整个 issue，不改变发布触发器、引擎版本、RTX 实验或游戏运行时代码。

遵循 [AGENTS.md](../AGENTS.md)、[架构](ARCHITECTURE.md)、[编码规范](CODING_STANDARDS.md)和[审查清单](REVIEW_CHECKLIST.md)；现有发行操作见 [RELEASING.md](RELEASING.md)。

## 1. 核对基线与结论

本次核对的是 `dev` 提交 `278d4461e827edb39773c1f5da6956333f7d0d2c`，日期为 2026-10-25。下表行号均属于该提交；#43 的原审计基线 `44c2331` 不直接代表当前状态。已读取 issue 全文和评论（当时无评论）、已合入的 #3、#42、#77、#81，以及当前开放 PR 列表；未发现另一个开放的 #43 实现 PR。

推荐采用三项互相独立的改动：仓库审查过的 Godot 工件与声明文件摘要、按实际冻结文件生成的运行组件清单、恢复后仍逐文件校验的 Poly Haven 原始文件缓存。缓存、版本标签和构建环境的已安装包列表都不能替代这些证据。

| 项目 | 当前状态 | 当前证据与剩余差距 |
|---|---|---|
| 内置字体 OFL 全文、字体 CREDITS 随包 | **已解决，保持回归检查** | #42 已合入；`tools/build_windows.py:80–83` 复制 OFL 和 `FONTS.md`，`tools/package_archive.py:13–21` 将它们纳入必需项。不能继续列成缺失许可。 |
| OFL 测试被发现、稀疏 CI 真正执行 | **已解决，保持回归检查** | #77 已合入；`tools/tests/test_release_tooling.py` 使用 `unittest.TestCase`，字体用例无跳过，`ci.yml:20–25` 保留字体目录。本设计的轻量稀疏树未取回字体，不能据此冒充执行了字体验收。 |
| Actions 完整 SHA、Python 版本与分发哈希锁 | **已解决，保持约束** | #3 已合入；两工作流的 Actions 使用完整提交 SHA，pip 使用 `--require-hashes`。实际锁文件是 `hub/requirements-{runtime,dev,windows}.txt`，不是另一本 `.lock`。 |
| Windows 锁混入 pytest / ruff | **原审计前提已变化** | `hub/requirements-windows.in:2` 现在只引用运行输入 `requirements.txt`；Windows 锁无 pytest、pytest-asyncio、ruff，开发包在 dev 锁中。不能声称当前标准 CI 必然打包或列出这些开发包。 |
| Python 许可、BUILD_INFO 的组件范围 | **仍缺** | `build_windows.py:34–43,93–95` 仍枚举全部 `importlib.metadata.distributions()`，会将环境中的构建工具或其他包当作依赖；并未核对冻结结果。干净环境只能缩小问题，不能证明清单准确。 |
| Godot `LICENSE.txt` / `COPYRIGHT.txt` 来源固定 | **仍缺** | `build_windows.py:25–30` 构建时按标签从 raw GitHub 下载，未校验摘要，断网也依赖该请求；`release_config.json` 无声明文件摘要。 |
| Godot editor / templates / SUMS 独立固定 | **仍缺** | `download_godot.py:52–69` 只固定版本，从同一 release 现取 SUMS 并信任其内容；配置没有工件或 SUMS 的摘要。已有传输校验，不是没有校验，但无法识别同源工件与 SUMS 一起被替换。 |
| CI 与发行共用 Godot 下载入口 | **仍缺** | `ci.yml:97–105` 用 `godotengine/godot` 的 curl / coreutils 路径；发行调用脚本，来源是 `godotengine/godot-builds`。同版本仍存在两套入口。 |
| SUMS 缺少所需 editor 时拒绝 | **脚本已具备；shell 分支需实测或移除** | `download_godot.py:60–61` 已明确拒绝缺失 editor。未运行 Ubuntu coreutils 的无匹配实验，不能把旧 issue 的疑问写成已证实漏洞；统一入口后用显式失败用例覆盖，无需依赖 `--ignore-missing` 的版本行为。 |
| Poly Haven 内容固定、暖本地文件不访问网络 | **已具备，CI 复用仍缺** | `sync_assets.mjs:54–124` 校验清单、原始/最终 SHA-256、字节数、路径和重定向；已有文件先验哈希，再决定是否请求 API。`--check` 离线。当前锁共 222 文件、799,958,793 字节（762.90 MiB），本次离线重算。 |
| Poly Haven Actions 缓存 | **仍缺** | `windows-release.yml:37–40` 每次新检出调用同步及检查，无原始文件缓存；第 43–48 行的 cache 是 `game/.godot` 导入结果，不能视为素材下载缓存。不能由静态阅读推断某次真实任务实际下载了多少。 |
| 导入交接、构建进程隔离 | **已有，保持边界** | `find_import_artifact.py` 要求同仓库、成功的 dev PR、相同树和未过期 artifact；#81 已提供临时用户目录及进程托管。自建引擎的 `engine_patches/build-lock.json` 固定源提交/工具链，不是标准发行 editor/templates 的哈希锁。 |

## 2. 信任边界与 Godot 固定方式

预期输入的信任根是经过维护者审查的仓库提交及其配置。官方下载站、GitHub release、缓存服务和恢复的 artifact 都是输入来源。构建应先把输入与仓库中预期的摘要比较，再解压、复制或执行。执行侧仍信任托管 runner、固定 SHA 的 Actions 和已提供的 Python/Node 工具链；本设计不证明可抵抗恶意 runner。摘要不能证明最初取得的文件没有上游问题；它能保证后续构建使用的字节与这次审查决定一致。

### 2.1 单一配置与一次更新流程

保留 `release_config.json` 的 `godotVersion=4.7.2`、PyInstaller 版本和现有包名；在其中增加有版本号的供应链配置，不再在工作流里写另一份 Godot URL、版本或哈希。推荐字段如下，真实摘要必须在实现 PR 中提供，不以占位符或空值通过检查：

| 配置 | 规则 |
|---|---|
| `supplyChainSchema` | 明确版本；未知版本立即失败。 |
| `godot.releaseRepository` | 统一为官方 `godotengine/godot-builds`；tag 由既有 `godotVersion` 派生。 |
| `godot.sourceCommit` | `godotengine/godot` 的完整源提交，供声明文件溯源；审核它与当前标准版的关系，不直接照抄自建引擎锁。 |
| `godot.sums` | `SHA512-SUMS.txt` 的准确文件名、字节数、独立记录的 SHA-512（128 个十六进制字符）。 |
| `godot.artifacts` | Linux x86_64 editor、Windows x86_64 editor、export templates 各自准确文件名、字节数和 SHA-512。只允许已声明的目标，不从 SUMS 自动选择“类似”的版本或架构。 |
| `godot.notices` | 每份声明的仓库相对路径、上游源文件路径、SHA-256；与 `sourceCommit` 关联。 |

首次录入/后续更新必须在普通 PR 中同时给出官方 release 链接、源提交、每个文件名/大小/摘要、取得与核对方式。可验证的官方签名或来源证明可作为额外证据；未实际核验就不宣称“已验证签名”。若只有同一 release 的 SUMS，明确记录这是一次受审查的首次信任，之后的独立固定来自仓库记录；不能说下载另一份同源 SUMS 已获得独立信任。

`download_godot.py` 在任何网络请求前校验配置完整性。先验证 SUMS 本身，再严格解析：拒绝格式错误、重复文件名、缺失条目，且所需条目的摘要必须与配置中的独立工件摘要相同。随后以配置摘要验工件。篡改 SUMS 和工件两者也必须失败；不得接受运行中从网络重新学习的摘要。

`ci.yml` 的 game-shell 改为调用 `download_godot.py --platform linux`；发行保留同一入口的 `--templates`。去掉 curl / `sha512sum --ignore-missing` 分叉。路径可由脚本生成或现有命名约定派生，不能另维护一个浮动版本。独立配置固定的是构建输入；托管 runner 镜像和 Python 补丁版仍会变化，这不等于已经实现逐字节可复现 ZIP。

### 2.2 Godot 声明文件推荐随源码保存

将经过核对的两个小文本保存到 `tools/licenses/godot/4.7.2/{LICENSE.txt,COPYRIGHT.txt}`，记录准确源提交与摘要。构建离线校验并复制为现有 `licenses/Godot-LICENSE.txt`、`licenses/Godot-COPYRIGHT.txt`，不再在打包时请求 raw GitHub。保留原文与第三方声明层级，不删节、不换成项目 MIT，不把 `engine_patches/LICENSE.godot.txt` 的单一 MIT 文本当作完整 COPYRIGHT 的替代品。

这仅增加少量声明文本，不增加运行依赖或二进制。`package_archive.validate_package` 同时要求这两份文件存在、非空且符合当前配置摘要，不能只检查构建函数曾返回成功。升级版本时更换目录、源提交和摘要，由同一 PR 审查。

### 2.3 Godot 缓存只缓存可重验的工件

下载器保留现有 `.part`、校验后替换和路径穿越拒绝。每次命中都重验文件大小与摘要；只缓存原始 ZIP/TPZ/SUMS，解压到新的临时目录后再安装，不能直接执行未经核对的缓存解压目录。目标目录替换要清除本次管理范围中的旧文件，避免 `dirs_exist_ok` 将不同版本残留混在一起。失败不覆盖原有有效工件，清除本次 `.part`，错误只报告相对文件名及预期/实际摘要。

模板从已验证 TPZ 重新展开，并在导出前确认使用的正是该份模板；继续通过 #81 的临时配置目录隔离，不把开发者个人 Godot 配置纳入输入。`tools/godot` 已解压文件或用户目录里“已安装相同版本”本身不是证明。

`game/.godot` 是派生构建缓存，保留 key 已有的 `release_config.json`，再加入 `tools/assets.lock.json` 和影响最终字节的变换脚本，相关输入变化即失效。保留现有同树导入 artifact 选择条件，不将外部 fork 的 artifact 提升为受信任发行输入。它仍是受限工作流生成的优化产物，不具有原始工件的独立哈希保证；正式发行验证另做一次无派生导入缓存的构建。

## 3. 许可和 BUILD_INFO 只描述实际分发内容

### 3.1 干净冻结环境加最终文件归属

推荐继续使用已存在的 Windows 哈希锁，在干净 Windows x64 venv 中安装，不装 dev 锁；不新增 `pip-licenses` 或其他扫描库。构建工具仍会存在于这个环境中，因此不能继续用“全部已安装 distribution”作为发行组件集合，也不能简单减去 pytest / ruff 作为过滤器。

冻结流程保留中枢 `onedir`、启动器 `onefile`、网页数据、`--noupx`、现有隐藏导入与清理参数。用两个受审查的 spec 在冻结时输出最终传入 PYZ/EXE/COLLECT 的文件集合，合并两次冻结的内容，再按当前安装 wheel 的 `RECORD` / `Distribution.files` 映射所属分发包。PyInstaller 的 spec 和 TOC 对应脚本、纯 Python、二进制和数据文件；不能只抓 Python import 名称，也不能把一次 smoke 中没执行的分支视为未打包。[官方 spec 文档](https://pyinstaller.org/en/stable/spec-files.html)、[TOC 说明](https://pyinstaller.org/en/stable/advanced-topics.html#the-table-of-contents-toc-lists-and-the-tree-class)说明了这些构建阶段。

归属规则：

1. 以 `requirements-runtime.txt` 在该解释器/平台下实际安装的精确版本作为应用运行依赖候选，和 Windows 锁核对同名版本。保留平台 marker，不把 Linux 的 dbus-fast 或 macOS 的 PyObjC 写成 Windows 组件。实现如需解析 marker，可使用 Windows 锁已有的 `packaging`，不添加新的分发依赖；安装前的下载/配置检查仍只用标准库。
2. TOC 的实际源文件与已安装分发文件相交才形成分发证据；名称按 PyPA 规则规范化。不能仅用顶层模块名对应包名，特别是 `winrt` 由多份 namespace distribution 共享。
3. 实际冻结的包若不在运行候选中，先判定它是否是内嵌工具运行代码或原生组件；没有明确归属就失败并要求审查。不能按“构建工具”名字盲目删掉已进入产品的文件。
4. CPython、标准库、系统/第三方 DLL、PyInstaller 引导器和运行 hook 独立分类；它们可能不属于应用 pip 依赖。保留实际分发的第三方原生库声明和可审查的归属记录；不得把所有无归属 DLL 都称为 Windows 系统库而放行。
5. 两个包的最终目录/内嵌归档与清单核对后再生成 notices。TOC 记录是构建证据，不能独自替代最后的冻结包检查。受锁版本的 PyInstaller 变化时重新验证适配，不解析未承诺稳定的内部 `.toc` 序列化格式。

内部比对可以使用绝对路径，输出只保留仓库相对路径、分发内相对路径及 `<python>` / `<venv>` 类来源标记。不得把 spec 的完整源路径、用户名、安装路径、pip direct_url 的本机路径或整个环境转储放进发行 JSON/日志。

### 3.2 声明提取与现有库的兼容

优先读取重复的 `License-File`，保留其在 `.dist-info/licenses/` 下的完整相对层级；保留 `License-Expression` 原值供说明，不能用表达式替代许可全文。PyPA 的[核心元数据规范](https://packaging.python.org/en/latest/specifications/core-metadata/#license-file-multiple-use)和[安装布局规范](https://packaging.python.org/en/latest/specifications/recording-installed-packages/#the-licenses-subdirectory)定义了这一关系。旧 wheel 的受控回退只查其自身 `RECORD` 内的 LICENSE / COPYING / NOTICE / AUTHORS 等文本；无法定位时使用按“名称+版本+wheel 摘要”审查的声明映射，缺证据即失败，不临时联网取最新许可。

保存到 `licenses/python/<规范名称>-<版本>/<原相对层级>`，避免当前只取 `file.name` 导致多个子目录同名声明相互覆盖。声明路径必须属于该分发，拒绝越界、符号链接、重复目标及内容冲突。完整保留必要的 copyright、NOTICE 和分发内第三方声明；发现多许可证表达式时保留其组合关系，不自动把 OR 改成 AND 或替组件选许可证。

| 组件/现有行为 | 设计必须保留或补证的兼容要求 |
|---|---|
| `aiohttp`、`yarl`、`multidict`、`frozenlist` 等扩展 | 按实际纯 Python 与 `.pyd`/DLL 来源归属，不因只看 import 或过滤 C 扩展而漏包；以选中的 wheel 为准。 |
| `bleak`、`winrt-*`、`winrt-runtime` | 保留现有 WinRT 隐藏导入；按文件归属区分共享 namespace 的各 wheel。Windows 冻结 BLE 自检仍必需；许可筛选不能改变后端收集。 |
| `cryptography` / CFFI 及其内嵌原生库 | 保留 wheel 中所有相关声明。Windows cryptography wheel 使用静态链接，不能以“未发现独立 OpenSSL DLL”推断没有相应分发声明；确切内容以锁定 wheel 检查为准。[官方安装说明](https://cryptography.io/en/latest/installation/#building-cryptography-on-windows)支持该约束。 |
| `qrcode` 及其他纯 Python 包 | 保持当前无新增 extra 的运行方式；已安装但无冻结文件的候选包不能因此自动列成分发组件，也不得通过主动删除实际文件来让清单变短。 |
| CPython 与 PyInstaller 内嵌运行代码 | CPython 声明改为明确必需，缺失时失败。PyInstaller 构建工具另记；引导器/运行 hook 如有分发则另记来源与声明。PyInstaller 的分发例外允许构建产物采用其依赖所允许的许可，不将整个产品误标为 GPL。[官方许可说明](https://pyinstaller.org/en/stable/license.html)。 |

本设计不凭包名给具体锁定 wheel 预先颁发“许可兼容通过”。实现 PR 要逐份核对当前版本的元数据、全文和实际分发文件，保留项目已有许可关系；缺声明、未知原生组件或未解决的分发条件均阻止发行。

### 3.3 机器清单与打包门禁

`BUILD_INFO.json` 增加 `schemaVersion`。保留 `godot`、`python`、`commit` 基本信息，明确 `dependencies` 只含实际冻结的应用 distribution；新增 `buildTools`、`runtimeComponents`、输入锁摘要、目标架构和供应链配置摘要。`buildTools` 只列本次使用的构建工具，不转储整个环境。记录 Python 完整补丁版和所选 wheel 文件名/摘要；名称、版本、文件证据和 notices 路径可互相核对。

生成 `licenses/MANIFEST.json`，逐声明记录组件 ID、版本、相对目的路径与 SHA-256。包校验器检查：运行组件有对应声明、声明存在且非空/摘要一致、组件和 BUILD_INFO 版本一致、无重复/越界/未登记声明。不得通过编辑清单把已冻结但无声明的组件隐藏起来。保留 #42/#77 的两份 OFL、FONTS 和缺失拒绝测试，不改变字体许可证或重做已经解决的修复。

## 4. Poly Haven 缓存命中仍须验证

### 4.1 只保存锁清单里的原始文件

当前 `game/assets/polyhaven` 同时有 Git 跟踪的 glTF、CREDITS、导入元数据和未跟踪的下载文件。不能把整个目录作为可信覆盖层恢复后只检查清单里的 222 个原始文件：未列入锁的受审查文件也可能被缓存覆盖。

首选在 `sync_assets.mjs` 增加只读、离线的 `--cache-paths` 机器输出，返回经过现有清单/路径校验的锁定文件列表；另拒绝换行和 Actions path 的 glob 元字符，避免多行/通配符扩大缓存范围。Actions 的 `path` 使用该列表，只缓存最终原始文件，不缓存目录、源码、glTF/CREDITS、`.godot`、证书或任何用户数据。本次已离线核对：222 条锁路径与 Git 跟踪路径交集为空；以后若相交，配置/测试必须明确拒绝，不能默默扩大缓存覆盖范围。机器输出只含相对路径，诊断与来源提示不要混入该输出。

使用已经固定 SHA 的官方 cache action 的 restore/save 子入口，key 包含缓存格式版本、runner OS、`tools/assets.lock.json`、`tools/sync_assets.mjs`、`tools/asset_metadata.mjs` 的摘要，不使用宽泛 `restore-keys`。同一已修补 Node 版本执行恢复后的检查，不降低脚本已有的哈希、路径或元数据处理约束。

### 4.2 命中、未命中与修复

| 状态 | 行为与失败条件 |
|---|---|
| 精确命中，文件均有效 | 只执行 `sync_assets.mjs --check`，不得调用 API/下载函数；日志输出命中及验证计数，`downloaded=0`。命中标志本身不代表内容有效。 |
| 精确命中，但缺失/损坏/符号链接 | 当前 job 失败，报告相对路径；不转入在线同步，不使用 `--force` 静默修好后称为“离线命中”。不保存损坏缓存。 |
| 未命中 | 按现有有界重试同步缺失文件，再执行离线 `--check`；全量通过后才允许缓存和构建。上游变更须与锁一致，否则失败，不能学习新哈希。 |
| 有效缓存的上游不可用 | 暖缓存检查成功，构建不因此访问上游；冷缓存仍会明确失败。这是可用性优化，不承诺所有首次构建脱网。 |
| 确认缓存损坏 | 维护者通过单独维护操作删除具体损坏 key，或审查后提高缓存格式版本，再从锁定来源补齐并重验。GitHub cache 不原地覆盖同一 key；不修改锁中的哈希迁就损坏文件。 |

首版 PR 只恢复缓存，保存限定为同仓库 `dev/main` 的可信 push 且验证成功；公开 PR/fork 只读恢复，未命中可运行受限下载并检查，但不提升为主线缓存。变更素材锁的 PR 首次可能仍需要下载，这是明确边界。缓存内容只有公开、可重验的数据，不放 token 或凭证；不引入 `pull_request_target` 执行 PR 代码。GitHub 对 [缓存分支范围与访问](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#restrictions-for-accessing-a-cache)的约束不是内容签名，不能替代哈希验证。

## 5. 平台、离线与失败边界

当前产品是 `SportGames-Windows-x86_64`：Linux x64 只负责 Godot 交叉导出，Windows x64 负责冻结和测试真实 EXE。PyInstaller 不是跨编译器，不能把 Linux 工具测试通过当作 Windows 冻结验证。[PyInstaller 支持说明](https://pyinstaller.org/en/stable/)明确区分了宿主构建平台。

公开仓库可使用官方列出的 `windows-11-arm` 托管 runner，但标签可用不代表当前 Godot 模板、Python、所有 WinRT/cryptography wheels 或 PyInstaller 产物已支持原生 ARM64。[GitHub runner 列表](https://docs.github.com/en/actions/reference/runners/github-hosted-runners#standard-github-hosted-runners-for-public-repositories)同时列有 x64 和 arm64。#43 不新增 ARM 发行；以后需独立目标、架构专属 editor/templates/wheel 摘要、原生 Windows ARM runner 和完整冻结/BLE 验证。x64 仿真测试应按仿真记录，不能写成原生 ARM 通过。

| 条件 | 预期结果 |
|---|---|
| 配置缺所需工件/声明摘要、摘要格式非法、版本/架构不匹配 | 在下载/执行前失败；禁止“无 expected 则继续”用于发行输入。 |
| SUMS 与配置不同、所需条目缺失/重复、工件与配置不符 | 失败且不解压/安装；更改本地预期摘要也应在输入验证处失败。 |
| Godot 缓存被替换或有 `.part` | 每次重验；无效数据不执行，未完成数据不当成命中；旧有效文件不被坏下载覆盖。 |
| 本地开发素材被改动 | 保持现有默认拒绝覆盖；仅开发者明确请求的 `--force` 可重取，仍必须满足原始与最终锁定摘要。CI 暖缓存不使用该选项。 |
| 离线 Godot 下载入口 | 增加明确的 `--offline`：不发请求；仅允许完整、已重验的缓存，缺文件或坏文件立即失败。声明来自仓库文本。 |
| 完整离线构建 | 前提是源码/大素材已就绪、已验证 Godot 工件和目标 Python 已提供，离线 wheelhouse 包含该目标全部哈希锁定 wheels；pip 使用 `--no-index --find-links <wheelhouse> --require-hashes --only-binary=:all:`。缺 wheel/平台不支持则失败，不回退网络、sdist 或临时编译。 |
| Python 清单有无归属文件、缺全文、版本不匹配、重复声明冲突 | 构建/打包失败；不能仅给警告后生成 ZIP。 |
| 非 Windows、解释器/目标/冻结 PE 架构不匹配 | 停止 Windows 包构建；通用跨平台锁含有某个 hash 并不证明该架构可用。 |

离线检查分层：`sync_assets --check` 只证明素材本地可验证；`download_godot --offline` 只证明引擎工件可用；完整离线发行还需冻结工具与 wheelhouse。三者不能互相替代。离线 wheelhouse 本身不进 Git，可按文件摘要从受控 artifact 提供；本设计不创建镜像、额外依赖或新的发布服务。

## 6. 可独立审查的最小实现切片

本轮只有本文。后续每片从当时最新 `dev` 建分支并重新对照上表，不把其他已合 PR 的工作重复实现。每片约定一名实现者；本表写角色，不另行分配他人任务。

| 顺序 | 文件/ownership | 可交付结果与轻量验收 |
|---|---|---|
| S1：Godot 输入与声明锁 | 工具负责人：`tools/release_config.json`、`tools/download_godot.py`、`tools/licenses/godot/4.7.2/*`、`tools/tests/test_release_tooling.py`；维护者审查跨区 `.github/workflows/ci.yml` | 一份来源与摘要、离线声明、两入口统一。fixture 覆盖工件/SUMS/声明分别篡改、缺条目/缺摘要、缓存无请求和离线路径。真实摘要录入证据单独审阅。 |
| S2：实际冻结组件清单 | 工具负责人：`tools/build_windows.py`、新增 `tools/freeze_inventory.py`、`tools/pyinstaller/{hub,launcher}.spec`、对应 `tools/tests/` fixture；中枢负责人复核 `hub/requirements-*.txt` 的使用关系 | 从冻结文件映射 distribution，区分工具、内嵌运行代码、CPython/原生组件；假环境装入 pytest/ruff 不污染未打包组件，namespace、多级声明同名、未归属 DLL 等 fixture 明确拒绝/归属。不随此片升级依赖或改 hub 行为。 |
| S3：声明清单打包门禁 | 工具负责人：`tools/package_archive.py`、`tools/build_windows.py`、`tools/release_notices.json`（仅确有旧 wheel/原生组件映射需要时新增）、`tools/tests/test_release_tooling.py`；发行负责人复核全文与条件 | BUILD_INFO 与 MANIFEST 的 schema/摘要/版本对应，缺 Godot/Python/运行包声明失败；保持 OFL 测试。S2 与 S3 合并前不可宣称 Python 许可问题已解决。 |
| S4：Poly Haven 暖缓存 | 工具负责人：`tools/sync_assets.mjs`、`tools/tests/asset_sync.test.mjs`；维护者审查 `.github/workflows/windows-release.yml` | 只缓存机器列表中的锁定原始文件；fixture 命中禁网、损坏命中失败、冷同步后验、跟踪路径交集拒绝；原始/最终摘要与安全路径规则不变。用两个受控 CI run 验证真实 miss/hit，而非本机拉取全部素材。 |
| S5：发行操作说明与一次整合验收 | 发行负责人：`docs/RELEASING.md`、`docs/DEVELOPMENT.md`、必要的 `docs/THIRD_PARTY.md` 相关行；维护者审查工作流整合 | 写清摘要更新、缓存修复、离线前提、运行清单与工具清单。整合后进行一次正式 Windows 包验证，证据绑定同一提交。保持现有 job 名；若确需修改，维护者同步 rulesets 与其测试。 |

S1 与 S4 可分别审查；S2 → S3 有依赖；S5 在各片合入后做一次集成验证，避免每个小文档/fixture 改动重复跑整套发行。所有切片保留 Actions SHA、Python 哈希锁、现有导入交接、构建隔离与冻结 BLE 自检；不自动发布、不合并、不创建标签、不改变标准 Godot 版本。

## 7. 验收分层与本次记录

### 7.1 本设计可以轻量检查的内容

本轮只检查当前源码、issue/PR 证据、锁的离线统计、本文相对链接、空白和敏感路径。未安装新依赖、未运行 Godot、未下载二进制/素材、未跑完整 pytest 或发行 CI。静态已确认表中的调用和配置，不将别的 PR 的历史测试结果记成这次实测。

未来 S1–S4 的行为测试使用小型字节 fixture、临时目录和注入的网络函数；Python 使用 `unittest.TestCase`，Node 使用现有内置测试框架。测试明确让不该发生的 urlopen/fetch 抛错，不能只靠没有 `Downloaded` 字样证明无网络。每片跑受影响测试及规范/隐私检查，不为纯文档改动启动引擎或重取 763 MiB。

### 7.2 关闭 #43 前必须补齐的发行验证

- 在同一实现提交完成真实缓存 miss/hit 两次 CI：第二次 API 与下载调用为零，离线检查覆盖全部 222 项；人为损坏的小型缓存 fixture 必须失败，真实损坏 key 的维护步骤可按说明操作。
- 按真实锁和仓库摘要验证一次官方 Godot editor/templates/SUMS 与两份声明；修改预期摘要、遗漏条目、替换工件时均失败。另做一次无 `.godot` 派生缓存构建，避免只证明暖缓存可以继续运行。
- Windows x64 原生冻结中枢和启动器，核对两份实际冻结内容与运行组件/声明清单，确认未打包的 pytest/ruff/其他工具不在 `dependencies` 与 `licenses/python/`；若构建工具确有内嵌运行文件，按独立组件解释其来源。保留完整 OFL、Godot 与 CPython 声明。
- 对最终 ZIP 运行 `validate_package`、现有冻结 BLE 后端自检和 `smoke_release.py`，检查 artifact 的 ZIP/SHA-256、BUILD_INFO、MANIFEST 对应同一提交；运行现有必需 CI 检查。不得从“fixture 全通过”直接推导真实发行成功。
- 在预置完整输入的环境做一次禁止外联的离线构建；缺一项引擎工件/wheel/素材时明确失败。验证只使用不触发 publish 的 PR 工作流；是否推进 main/标签由维护者另行决定，本文不修改现有触发器。

这些属于未来实现后的发行证据，不是本次设计文档已完成的验证。Windows ARM 原生、真实手柄/BLE、手机权限、HDR/VRR、GPU 画面性能不由本设计或无界面包检查证明；不得为完成 #43 顺带占用 RTX 实验或声称这些已经通过。
