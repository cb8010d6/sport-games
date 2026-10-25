# 共享素材：materials

用途：非 Poly Haven 材质加工件：`<来源>_<id>/`，如 `acg_net004a/`；贴图用 Poly Haven 命名，`RSPbr.maps("shared:<来源>_<id>")` 直接加载

常见来源：外部 CC0（ambientCG 等）。规则见 [docs/ASSETS.md](../../../../docs/ASSETS.md#共享素材库) 与 [总索引](../CREDITS.md)。

目前没有文件。新增文件时每个文件一行，不留空项：

| 文件 | 来源类型 | 原始页面 / 生成脚本 | 资产 ID / 标题 | 作者 | 许可 | 下载日期 | 原始文件名与 SHA-256 | 加工步骤（脚本 + 参数） |
|---|---|---|---|---|---|---|---|---|

- 外部 CC0（ambientCG、Kenney 等）：填原始页面 URL、作者、下载日期、原始文件名与 SHA-256，并在
  `docs/THIRD_PARTY.md` 增加该来源一节。
- 项目脚本生成：脚本放 `tools/blender/`；写清输入素材（逐个来源）、Blender / MPFB 版本、命令与参数。
  输入全为 CC0 的记 `CC0-1.0`；含项目原创几何 / 着色器的记 `MIT AND CC0-1.0`，并在
  `tools/asset_policy.json` 里为这个目录加一条更窄的前缀规则（放在 `game/assets/shared/` 之前）。
- 不收 CC-BY / CC-BY-SA / “royalty free” / 来源不明的素材，不含真实商标。
