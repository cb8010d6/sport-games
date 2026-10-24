# B1 画面返工：PR #31 评论 6377607695

本轮继续 B1 场馆画面，并接入审查明确要求的公共开场镜头。人物、回放、音效、领奖台和新地图仍未实现；球道碰撞、刚体参数、输入、机器人和计分不变。

## 最新画面调整

按用户随后指定的样式，移除 P1–P4 文字后独立的黑色底板，保留 MSDF、不透明预通过和深描边。保龄球五/十格计分板单独使用参考色 `#E3E5EF`、76% 不透明度，数字改用公共深色 `RSUi.INK`，让浅底上的投球标记、累计分和格号仍可读；公共玩家分数牌及框架主题不改。此前有黑底板的图只保留作历史对照，不能代替本次调整的最终图。

此样式的官方 4.7.2 场馆矩阵八例重新通过，共 4800 项、0 失败。首次测试仍按旧深色背景识别绘制单元，因观察器未更新而报告 4 项格数失败；保留该日志后，将观察器更新为实际的新背景标记，未减少原有格数、字体边界或玩法断言，八例完整重跑通过。新样式的真实截图仍须单独验收。

## 标牌返工范围（评论 6380640451）

该轮原方案仅涉及 bowling 场馆、bowling 专用遮板 shader、对应场馆测试和本说明：从公共标签字体复制独立的 3D MSDF 字体资源，不修改共享字体或导入设置；标牌使用不透明预通过与描边，原方案的深色底板已按后续样式要求移除。图案用屏幕导数过滤细线并降低 emission，环境 bloom 设为零，glow 继续服从公共画质设置。验收包含同机位四人 2560×1440 原生 / FSR 原生抗锯齿 / FSR 质量截图与 200% 标牌裁剪，以及 2560×1080 的 1/2/4 人实际画面；当前静态证据见文末，运动与性能尚待验收，继续保持 draft。

实现后的官方 4.7.2 headless 场馆矩阵已跑 2/4 人 × 中英文 × 100%/125%，八例共 4768 项检查、0 失败；覆盖独立 MSDF 字体源、间距、不透明预通过、描边和四块深底板，以及原有规则 / 碰撞 / HUD 回归。规范 0 错误、文案 0 缺失 / 0 多余。该结果尚不验证 GPU shader、标牌可读性或运动闪烁；截图和正式测量仍待完成。

独立复核随后发现 MSDF 距离范围 16 不足以覆盖 10 像素描边；按 [FontFile 官方约束](https://docs.godotengine.org/en/stable/classes/class_fontfile.html#class-fontfile-property-msdf-pixel-range)改为 24，并增加范围至少为描边两倍的断言。范围 16 的截图单独保留，不能代替该修正后的画面验收。

修正后八组矩阵重新运行，共 4800 项检查、0 失败。范围 16 的上一版本另跑公共启动 15 组通过（仓库既有退出缓存诊断仍按原工具规则排除）；范围 24 仅改字体参数和对应断言，不将旧版画面或旧版全量测试写成最新版结果。

## 参考与取舍

仅通过官网查看参考，不下载、不将参考图片放入仓库，不复制品牌标志或原作图案：

- [All Star Lanes Brick Lane，官方场馆图册第 8 页](https://www.allstarlanes.co.uk/wp-content/uploads/2025/01/Venue-Hire_Full-brochure.pdf)：休息区、软包座位、桌面与远处球道形成前中后景。应用为有圆边的座椅、圆桌、回球设备，避免空场和方块占位。
- [All Star Lanes The Loft，官方图册第 4 页](https://www.allstarlanes.co.uk/wp-content/uploads/2025/01/The-Loft_STRD_brochure-final.pdf)：球道尽头的亮色几何与霓虹标识形成视觉焦点，低照度空间保留暖色局部灯光。应用为原创几何图案遮板、灯框与独立打光，不复刻品牌文字。

## 实装方向

- 提亮现有锁定的扫描灰泥、砖墙、地砖、木饰面；墙面增加砖裙墙、木饰条、踢脚灯带和几何灯箱，天花增加成组吸音构件与格栅。
- 使用真正的聚光灯在球道形成光池，瓶区单独打光；发光灯具采用有厚度和圆边的灯壳，霓虹继续使用 emission / glow 并遵守画质设置。
- 遮板采用新增的原创 MIT 程序图案 shader [`game/shaders/bowling_mask.gdshader`](../game/shaders/bowling_mask.gdshader)、玩家四色灯框和 `RSUi.font_label()`，不新增外部贴图。该 shader 仅由 bowling 引用，共享 shader 不变。
- 复用程序倒角网格构建软包座椅、圆桌与回球设备，重复部件使用 MultiMesh；球道箭头和引导点加强对比。
- 自绘计分格使用 `RSUi` 色值、数字字体和方角 `draw_box`。计分板随字号整体扩大，10 格时按分屏宽度限制布局，保持数字与格子的比例。开场只通过 `RSIntro` 与 `draw_title_card` 接入原倒数阶段，常规玩法相机锚点保留。

## Headless 验证

使用官方 `4.7.2.stable.official.ed1daf0bf`，隔离临时数据和 `RS_TEST_MODE=1`；全部通过后冻结代码，再进行画面审查。没有运行真实渲染、截图或性能测量：

| 检查 | 结果 |
|---|---|
| `tools/import_game.py --godot <official-4.7.2>` | 首轮通过；新 shader UID 由引擎生成。47 个无关导入描述符仅新增官方默认字段，核对后恢复 |
| `tools/test_bowling_environment.py --godot <official-4.7.2>` | 2/4 人 × 中/英文 × 100%/125%，默认 quality=2，八例 4656 项检查、0 失败、0 引擎错误 |
| `tools/smoke_test.py --games bowling --players 2` / `--players 4` | 两场完整机器人回合均通过 |
| `tools/test_lifecycle.py --games bowling --players 2 4 --languages zh en` | 四例合计 108 项检查通过；合成控制器入场、暂停、重开、断连 / 重连及返回菜单 |
| `tools/test_game.py --party` | shell、存档 62 项及重新打开、三项目派对流程通过；存档故障注入的预期报错仍按原工具分类 |
| `tools/smoke_game.py <official-4.7.2> --project game` | 15 个公共启动案例通过；原工具已明确排除的其他项目退出缓存资源诊断保留在日志中 |
| 规范 / 文案 / Ruff | 0 错误；规范仅有既有滑板 / 滑雪 SIZE 警告，文案 0 缺失 / 0 多余 |
| 工具 / 中枢 / Node 测试 | 71 项及 130 个子测试 / 62 项 / 8 项通过 |
| 素材校验 / 隐私检查 | 222 个现有锁定文件校验通过，下载 0；隐私扫描 0 发现 |

专用 suite 保留缺 HDRI fallback、碰撞布局 / 摩擦 / 质量、计分、四色与光源配置检查；新增开场各段端点、暂停、重开、原瞄准 / 跟球机位与 FOV，以及两种镜头晃动设置下无额外抖动的断言。实际 HUD 绘制记录覆盖 5/10 格满分、末格三次投球标记和中文 fallback。首轮实测发现 10 格布局越出双人视口，随后 125% 字体度量发现文字越出格顶；失败日志与边界保留，修复整个网格的缩放与限宽后八例重跑通过。

headless 不验证灯光观感、shader 实际渲染、字体视觉可读性或 GPU 开销。历史 B1 截图与旧短采样不能作为本轮画面验收。

## 待画面审查与性能验收

1. 同机位四人 QHD 对照与最新宽屏双人 / 四人静态证据已补入文末；完整中英文 1/2/4 人宽屏原图另留私有验收索引。125% 字号、开场镜头最终目视及运动闪烁 / 拖影仍待验收。专用工具提供 `--quality`（默认 2）和 `--text-size 100 125`；截图文件名包含玩家数、语言索引、字号与 `intro` / `play` / `hall` 后缀。同机位对照使用旧图的高画质和同一相机姿态，不能拿扫场视角替代。
2. 已合入的 `tools/bench.py --games bowling --players 2 4 --quality 2 --repeat 3` 正式测量，由主任务安排。
3. 文末新增截图已登记来源 / 许可。运行时只复用既有锁定资产，无新依赖或外部素材。本轮仍是 B1，不能以此关闭整个 #25。

## 2026-10-24 最终样式的静态画面证据

最新画面对应 `fb3af56008647e82a7b34598a687358e0ead8f5a`：P1–P4 标牌移除独立黑色底板，保留专用 MSDF 字体（pixel range 24、size 128）、10 像素深色描边和 opaque prepass；遮板细线使用 `fwidth` 过滤，环境 bloom 为 0，glow 仍服从公共画质设置。保龄球计分格采用取色值 `#E3E5EF`、alpha 0.76（76% 不透明度），格内数字使用深色 `RSUi.INK`。

以下六张为未经缩放、重编码或合成的原始 PNG；文件哈希、源码与 fixture/pose 标识、官方引擎、实际 GPU、输出和玩家视口、AA/scale 及对象比较记录见 [visuals.json](benchmarks/bowling-b1-revision/visuals.json)。旧场馆原生参考来自 `cf889669aa515790d2d8ab6b77a354c55afa3fb6`。截图内容使用合成 P1–P4。

| 画面 | 配置与用途 | 原始 PNG |
|---|---|---|
| 旧场馆四人参考 | 2560×1440，quality=2，原生，Radeon 780M | [旧场馆原生](screenshots/bowling-b1-r2-before-qhd-native.png) |
| 最终样式四人 | 2560×1440，quality=2，原生，Radeon 780M | [最新原生](screenshots/bowling-b1-r2-after-qhd-native.png) |
| 最终样式四人 | 2560×1440，quality=2，FSR 原生抗锯齿，scale=1.00，Radeon 780M | [FSR 原生抗锯齿](screenshots/bowling-b1-r2-after-qhd-fsr-native-aa.png) |
| 最终样式四人 | 2560×1440，quality=2，FSR 质量，scale≈0.67，Radeon 780M | [FSR 质量](screenshots/bowling-b1-r2-after-qhd-fsr-quality.png) |
| 最终样式中文双人 | 2560×1080，quality=2，原生，GeForce RTX 4060 Laptop GPU | [宽屏双人 PLAY](screenshots/bowling-b1-r2-after-wide-2p-zh-play.png) |
| 最终样式英文四人 | 2560×1080，quality=2，原生，GeForce RTX 4060 Laptop GPU | [宽屏四人 PLAY](screenshots/bowling-b1-r2-after-wide-4p-en-play.png) |

四份 QHD 使用同一冻结首个 PLAY 夹具：P1 为 AIM，P2–P4 为布置在瓶区前方的跟球观察机位，FOV 均为 50；保留真实 HUD、隐藏共享 GO，44 个刚体冻结。旧/新原生的 fixture 与 pose 哈希、实际相机、root viewport 及全部 44 个冻结对象相同，相机与物体变换的最大数值差均为 0。最新三档也保持相机姿态、投影、分屏布局与冻结对象相同，AA 和渲染 scale 按档位变化。这是固定静态观察画面，不是自然玩法重放。

宽屏图来自独立的普通 demo PLAY 夹具，用于检查双人/四人布局。实际 PNG readback 为 2560×1080；内容基准为 1600×900，展开后的 root 逻辑可见区域为 2133×900，玩家实际视口分别为 1062×896（双人）和 1062×446（四人）。Godot 的 root ViewportTexture advertised size 单独保留在元数据，不替代实际 PNG readback。宽屏与 QHD 的 GPU、夹具和布局不同，不能用于同条件性能作差。

### P1 远望 P4 的 200% 裁剪

以下均为上表原图中同一源像素框 `[858,252,928,318]`（左/上包含，右/下不包含），70×66 像素以最近邻放大 2 倍为 140×132。它们是已披露的裁剪放大图，不是原始尺寸截图；源图与裁剪 SHA256、框坐标和缩放 provenance 均记入 `visuals.json`。

| 旧场馆原生参考 | 最新原生 | 最新 FSR 原生抗锯齿 | 最新 FSR 质量 |
|---|---|---|---|
| ![旧场馆 P1 远望 P4，200% 裁剪放大](screenshots/bowling-b1-r2-before-qhd-native-p1-distant-p4-200pct.png) | ![最新原生 P1 远望 P4，200% 裁剪放大](screenshots/bowling-b1-r2-after-qhd-native-p1-distant-p4-200pct.png) | ![最新 FSR 原生抗锯齿 P1 远望 P4，200% 裁剪放大](screenshots/bowling-b1-r2-after-qhd-fsr-native-aa-p1-distant-p4-200pct.png) | ![最新 FSR 质量 P1 远望 P4，200% 裁剪放大](screenshots/bowling-b1-r2-after-qhd-fsr-quality-p1-distant-p4-200pct.png) |

### 静态观察与边界

主任务已逐张查看最新三档 QHD、宽屏双人/四人原图及以上四份 200% 远 P4 裁剪：标牌在这些静止画面中可辨，没有观察到新增布局越界；浅色半透明计分格下仍可见场景。这个结论仅覆盖这些画面和机位。运动闪烁、拖影、真实手柄手感、正式性能、HDR/VRR 与跨平台行为未由此图包验证；没有以截图或冻结夹具声称帧率门槛通过。

新增截图沿用项目 MIT 代码/程序几何及既有已登记 CC0 素材的来源，联合画面登记为 **MIT AND CC0-1.0**；字体及其他既有资源记录见 [THIRD_PARTY.md](THIRD_PARTY.md)。本段补充当前静态证据，历史测试和短采样数字仍保留其原始版本含义，B1 之外的 #25 工作也不因此完成。
