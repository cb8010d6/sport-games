# B1 画面返工：PR #31 评论 6377607695

本轮继续 B1 场馆画面，并接入审查明确要求的公共开场镜头。人物、回放、音效、领奖台和新地图仍未实现；球道碰撞、刚体参数、输入、机器人和计分不变。

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

1. 相同机位的四人旧场景对照、双人 / 四人中英文画面、125% 字号和开场镜头，由主任务在隔离隐藏桌面串行运行。专用工具新增 `--quality`（默认 2）和 `--text-size 100 125`；截图文件名包含玩家数、语言索引、字号与 `intro` / `play` / `hall` 后缀。同机位对照须使用旧图的高画质和同一相机姿态，不能拿扫场视角替代。
2. 已合入的 `tools/bench.py --games bowling --players 2 4 --quality 2 --repeat 3` 正式测量，由主任务安排。
3. 新截图的来源 / 许可登记由主任务统一处理。运行时只复用既有锁定资产，无新依赖或外部素材。本轮仍是 B1，不能以此关闭整个 #25。
