# 共享素材库：来源与许可总索引

`game/assets/shared/` 放两个及以上项目会用的成品与加工件（普通 Git，不用 LFS）。
目录、命名、导入、预算和来源记录规则见 [docs/ASSETS.md](../../../docs/ASSETS.md#共享素材库)，
总体规划见 issue #58。Poly Haven 原始文件仍在 `../polyhaven/`，由 `tools/sync_assets.mjs` 下载。

`tools/asset_policy.json` 把本目录登记为 `CC0-1.0`，证据是这份索引和各子目录的 CREDITS。
含项目原创几何 / 着色器（`MIT AND CC0-1.0`）的子目录，要在策略文件里加一条更窄的前缀规则，
放在 `game/assets/shared/` 之前。

| 子目录 | 内容 | 来源记录 | 文件数 |
|---|---|---|---:|
| `characters/` | 统一阵容身体、项目服装、去重纹理（P1） | [CREDITS](characters/CREDITS.md) | 0 |
| `crowd/` | 观众低模 + impostor 图集（P2，A2） | [CREDITS](crowd/CREDITS.md) | 0 |
| `arena/` | 看台、灯塔、记分牌、裁判椅等（P2，A1–A7） | [CREDITS](arena/CREDITS.md) | 0 |
| `equipment/` | 球拍、球、球网、拳套、拳台、水上摩托等（P5，B1–B10） | [CREDITS](equipment/CREDITS.md) | 0 |
| `materials/` | 非 Poly Haven 材质加工件，`RSPbr.maps("shared:<名>")`（P3 / P4） | [CREDITS](materials/CREDITS.md) | 0 |
| `vegetation/` | 树 / 灌木 impostor（P2，#26 合入后迁来） | [CREDITS](vegetation/CREDITS.md) | 0 |
| `vfx/` | 粒子图集、拖尾 / 冲击贴图（P6） | [CREDITS](vfx/CREDITS.md) | 0 |
| `signage/` | Logo、横幅、场地图案（P7） | [CREDITS](signage/CREDITS.md) | 0 |

新增文件时同步更新上表文件数、所在子目录 CREDITS、`docs/ASSET_MANIFEST.json`（重新生成）、
`docs/ASSETS.md` 的体积统计；外部来源另在 `docs/THIRD_PARTY.md` 增加一节。
