# Godot 4.7.2 本地修复

基线为 Godot `4.7.2-stable`，提交 `ed1daf0bf001b61586d9930840f2f1394092c079`。

`dummy-rid-thread-safety.patch` 回移 Godot 上游 [PR #121958](https://github.com/godotengine/godot/pull/121958)，合并提交 `b460ec416dd94fc121d1c2597aa521359a0d588e`。修改无头渲染器的五个 RID owner，启用已有的线程安全模板参数，覆盖 mesh、multimesh、shader、material 和 texture。源码保留 Godot MIT 许可；本目录附同版本的完整许可。

无头模式下，资源的 RID 可从多个线程直接分配；原有 owner 缺少并发保护，可能破坏空闲列表、分配计数或槽位状态。项目级串行导入只能减少触发机会，无法修复调用者主动多线程创建资源的情况。补丁直接修复引擎的 owner。

独立回归项目在 `tools/engine_tests/`，不含游戏资源、自动加载或编辑器插件。运行：

```sh
python tools/test_engine.py --godot /path/to/godot --runs 3
```

测试在主线程和四个工作线程上分配 / 释放各类 RID，要求正常退出、完成标记及零引擎错误，资源泄漏也判为失败。原版 Windows 4.7.2 本地复现 mesh、material 的 `0xC0000005`，以及 texture RID 泄漏。

此补丁针对已复现的引擎并发缺陷；历史弹窗只有非法内存写入事件，没有调用栈，不能把两者直接视为同一次故障。

## 本地对照

| 独立测试 | 原版官方 4.7.2 | 本地修复版 |
|---|---|---|
| mesh / multimesh | 3 次均为 `0xC0000005` | 10 次通过，零错误 |
| shader / material | 3 次均为 `0xC0000005` | 10 次通过，零错误 |
| texture | 3 次均有 RID 错误或退出泄漏 | 10 次通过，零错误 |

测试没有修改系统 JIT 配置，失败不会被吞掉。两组构建的编译器不同；补丁依据为未加锁的资源分配状态、上游修复及本地故障复现。原始日志只留在本地 `audit-output/engine-stock-repeated/` 和 `audit-output/engine-patched-30/`。

## 在 Windows 重建

需要 Git 和 64 位 Python 3.11+，不需要安装 Visual Studio 或 Windows SDK：

```sh
python tools/build_godot.py --jobs 6
```

脚本按 `build-lock.json` 下载固定版本源码、便携 LLVM-MinGW（校验 SHA-256）及独立环境中的 SCons，应用补丁，构建带调试符号的 Windows 编辑器。构建日志在 `audit-output/engine-build-llvm.log`。工作区以外的工具链和系统配置不变；已应用补丁的源码可以直接增量构建。

安装前去除调试段以减小运行文件，完整符号保留在源码 `bin/` 目录。只有打包后的三类并发测试各通过三轮，才安装到 `tools/godot/Godot_v4.7.2-regina-ridfix1.exe`，并保存二进制 SHA-256、源码提交、构建选项、Godot 许可及第三方版权说明。`--no-install` 只构建和验证。默认六个编译任务；内存充足时可自行增加。

Python 导入 / 测试工具优先选择本地修复版；显式 `--godot` 或 `REGINA_GODOT` 仍可选择其他引擎。普通游戏启动仍选择完整官方版本；若要用本地修复版运行 Vulkan 游戏，可用 `REGINA_GODOT` 指定上述文件。原版可执行文件保留，不会覆盖。未构建修复版的机器继续使用原有引擎，因此项目仍保留串行导入作为兼容规避措施。

该本地构建保留 Vulkan、OpenGL、Jolt 和 3D 支持；未包含需要额外 SDK 的 D3D12、ANGLE、AccessKit 与 WinRT。它不是完整官方发行包的替代品；这些可选后端的功能不属于本次回归范围。调试符号和构建产物体积较大，只留在本地，不提交 Git。
