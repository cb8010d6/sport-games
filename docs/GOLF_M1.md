# 高尔夫 M1：实现与验收记录

依据[G0设计](GOLF_DESIGN.md)累计交付G1–G3，PR #33仍为draft。本文合并G1、G2、G3-A/B与mip前置修复的阶段证据；历史切片保留在Git中，不再维护多份小阶段文档。当前性能冻结源码为`c36e1b0`（B+mip），尚未完成M1球物理、精确OB、图像/录屏和配对性能验收。

已实现两图×三洞、1–4人独立球与视口、纯规则、共边果岭细化和私有mip纹理缓存。**球仍为144 tick占位抛物线，A/B/C是占位输入，所有局`can_record()`恒false。** 没有正式挥杆、弹跳/滚动、水/树/球洞sweep；地形射线通过不代表这些已经实现。未注册菜单或catalog，`--game=golf`仍不可当作正式入口。

## 已决节奏与框架接入

[Issue #26更正](https://github.com/cb8010d6/sport-games/issues/26#issuecomment-6378856754)及[PR #33评审](https://github.com/cb8010d6/sport-games/pull/33#issuecomment-6379666347)撤回真人完成即换洞：所有玩家（含电脑）进洞或封顶才换洞。当前`_round_players`终态屏障正确；冻结版仍含电脑180 tick瞄准等待，终态后跳过等待/4倍调度尚待独立协调提交及引擎验证，不能写成已完成。

协调约定：至少一名真人且所有真人终态后，电脑READY立即出手；以同一120Hz时钟最多4倍消费固定步，飞行/滚动不截断、不放大步长，150秒预算随同一比赛时钟累计。暂停、洞卡不加速；纯demo保持1倍。等价测试双方均采用新跳过等待策略，只改变调度批大小，比较同种子杆数、积分、落点和封顶原因。当前只能验证占位骨架，正式球物理接入后必须重测。

PR #27主题、#34公共测试临时端口已在`cf88966`正常merge进入。`1e50744`移除了两个专用runner的固定47800探测；当前统一用`RS_TEST_MODE=1`、临时APPDATA/LOCALAPPDATA/XDG目录，不改ControllerHub子类，不停止其他会话。G6沿用[公共UI_THEME](UI_THEME.md)，本M1没有另造主题。

## 场景、规则与时钟

- `golf_game.gd/.tscn`继承RSPartyGame，沿用倒数、暂停、重开、分屏及成绩。每人`p.data`持有RSGolfState，世界场地/洞次共享；球不互撞。G1占位A循环60/120/220米、B按住再松开、C取消；球144 tick到推荐目标，半径0.12m为可见性占位。
- `RSGolfRules`只持整数、枚举、数组和RefCounted令牌，没有Node、Vector3、场地、协议或存档依赖。state处理输入队列及占位球，事件数组复用，无事件tick不分配令牌/数组/字典。
- 每洞18000个120Hz比赛步；渲染积压全部消费，暂停保留原半步但不累计。进入洞卡/RESULTS即停止剩余积压，不把卡片delta赠给下一洞。洞卡目前6秒，正式卡片/开场/HUD在后续M2。
- Command.tick指上一个已完成步：17999可出手，18000不能新出手；已有球在18000末的接触先结算。每步依次处理输入/机器人、飞行、事件、超时；最后一洞全员终态只提交一次结果。
- 断线/roster离线事件立即取消armed/排队release；同轮轮询重连也不能消费旧释放。保留球和时钟，不改变`p.fake`或自动接管。重连须新按B。

| RSGolfRules API | 契约 |
|---|---|
| `reset_round(pars,slot)` / `start_hole(index)` | 三个正par、P1–P4；递增epoch清局，洞只按顺序前进。病态布局assert失败。 |
| `command_key(seq,at_tick)` / `try_stroke(command)` | 新合法命令+1杆并返回ShotKey。同上下文递增seq观察即消费，FLIGHT/DROP时拒绝的释放不能日后重放。 |
| `resolve_tick(next_tick,events)` | 连续步；重复已完成步无副作用，跳步assert失败。先接触事件，后deadline；只接受当前FLIGHT/ShotKey/步号。 |
| `complete_drop(shot)` | 仅当前DROP原ShotKey确认一次；旧局/洞/shot、另一rules、封顶后均拒绝。 |
| `ready/finished/stroke_count/score/summary` | 未完成洞0分；summary为独立快照，含每洞par/杆/罚杆/分/状态/原因及总分、总杆、相对par、上限数。 |

CommandKey/ShotKey使用`StrokeKey`（slot/epoch/hole/seq/tick），另带每rules独有owner；ShotKey还验证当前对象身份，同数字跨玩家不能结算，不序列化成网络协议。事件按order先后、同order按HOLED/WATER/OB/REST排序，重复只处理一次。

规则状态`UNPLAYED → READY → FLIGHT → READY/DROP/HOLED/CAPPED`。最后`par+4`杆仍可进洞；REST才封顶。WATER/OB每杆+1罚，触顶立即CAPPED、不drop；否则返回WATER_BACKTRACK/PREVIOUS_SHOT并阻止出手，确认不再加罚。几何触水/OB、上一杆坐标和合法drop搜索仍未实现。

Stableford为`max(0,2+par-strokes)`，只累加终态洞到`p.score`。`[4,3,5]`与`[3,2,9]`分别12杆/E与14杆/+2，但同为6分并列第一；不以总杆破同分，不改core高分纪录语义。结果明细分列杆/分，占位局始终禁纪录。

| 固定输入 | 验收期望 |
|---|---|
| seq5出手，FLIGHT拒绝seq6，REST重传6 | 仍1杆，必须新release；DROP阻塞相同。 |
| WATER/OB重复，drop重复或跨rules/旧上下文确认 | 只罚一次、只确认一次；非法token不重开洞。 |
| par4第8杆HOLED/REST/WATER | 都8杆0分；HOLED实际进洞，另两者CAPPED。 |
| 已完成步17999/18000请求出手；接触17999/18000/18001 | 出手仅17999可；前两种接触有效，后一种已经timeout。 |
| release后离线再同帧重连；暂停中释放 | 不意外出手，不接管，恢复须新按B。 |
| 30/60/144Hz及1秒积压 | 同一240 tick终态一致；暂停、洞间、重开/换图/玩家与场景释放无旧局残留。 |

## 共享地形与纹理

G3-A把原粗网格抽成`RSGolfSurface`，course保留HOLES/SDF/噪声种子/RNG、公式准备顺序、水树/材质/球洞/环境。A原2.5m网格、两种旧差分法线和最大边缘`vertices-1.001`行为保持等价；course由885降至835行。该历史粗版不是当前细网格实现。

G3-B用同一规范三角缓存供渲染和查询：

- `build(origin,cells,sampler,patches)`接受粗单元半开矩形、并集去重；course以各果岭最大半径加`5+sqrt(2)`m外对齐2.5m，覆盖果岭/边缘。规范key步长0.25m，细格步长0.5m，fan中心为粗格中心；每唯一顶点仅采样一次，Callable/字典不保留到运行期。
- 细格每粗单元5×5小格/50三角；普通粗格2三角；邻k条细边的粗格按对应边插4点并发出`4+4k`片中心fan。全16种mask及chunk48共边无T形裂缝；所有chunk复制全局面积加权顶点法线。
- `height_at/normal_at/geometric_normal_at`分别为实际三角重心高度、全局顶点法线插值、向上面法线。`triangle_at/cell_triangles/triangle_vertex`只读真实缓存，域外triangle=-1；高度/法线保留有限域外夹取，最大边缘改为精确闭边界。无raw/双线性回退。
- 无效域/矩形/索引/采样/非有限查询明确报错，失败build不暴露旧有效缓存；域内找不到三角即失败。坐标/高度限±4096m，粗格≤250000、三角≤300000，矩形先减法检查避免end溢出。
- 两图实际257730/207920片地形三角、54/42个chunk。tee/pin/green/route的XZ不改；高度锚点跟随同一surface。`contains_xz`仅网格域，不是精确OB。

`RSGolfTextures.load_mipped(path,normal_map)`在课程构建时准备六路地面sampler：有mips返回原Texture2D；缺mips则复制Image、必要解压、`generate_mipmaps(normal_map)`并创建私有ImageTexture，所有normal传true。按路径+flag缓存，不按chunk/帧生成，不写盘、不改共享纹理/import；失败明确诊断、不缓存。参见[Godot Image API](https://docs.godotengine.org/en/4.7/classes/class_image.html#class-image-method-generate-mipmaps)。此独立提交可同时应用到粗/细版，作为公平性能对照的共同前置。

## 阶段证据与失败记录

下表都是Godot4.7.2的已完成记录，不以当前文档整理代替重新测量。切片在同机Windows验证；跨平台尚未实际运行。

| 内部切片/源码 | 已完成证据 |
|---|---|
| G1 `d6d238a`（图像）/`3241470` | 两图demo1/2/4各47/51/59，共314项，0失败/错误/环境诊断/纪录或泄漏诊断。工具69+130子测试、Hub62、Node8、规范0错误（3个原SIZE警告）、i18n475/0/0、Ruff、素材222一致/0下载通过。 |
| G2 `451d8ac` | 两图demo1/2/4各142/146/154，加两个非法delta拒绝，共886项通过。规则幂等、owner隔离、期限/封顶、断线、暂停/重开/换图/释放/禁纪录通过；同版本配套工具69+130、Hub62、Node8及静态检查通过。 |
| G3-A `ae17d06` | surface639项、375040次独立三角查询（实际地图374714片），高度误差输出9位小数为0，面法线距离max0.000000182。旧78查询、96chunk和全部顶点/法线/索引hash/样本全等；地图仍211434/163280片、54/42chunk。886及smoke15通过，strict publication1170文件/0发现。 |
| G3-B `952cb8e` | surface2508项+11隔离拒绝、468442个三角查询、105次真实引擎射线，高度max0.000001580m、面法线误差0；地图三角/共边预算实测符合。886通过；工具71+130、Hub62、Node8、规范0错误/3旧SIZE、i18n477/0/0、Ruff、publication1190文件/0发现。 |
| mip `c36e1b0` | 专用155项+2隔离拒绝，DXT1复制解压、原像素/尺寸/mips不变、normal mip重归一化、实际八张纹理缓存、两图96chunk共享材质及六sampler接入通过；无额外错误/环境/纪录。smoke15、规范/i18n/Ruff、publication1197文件/0发现通过。 |

历史失败没有删除或当作成功样本：

- G1首次WeakRef严格类型解析失败和测试音频收尾问题修正后，重跑全部六组。首批误进入plane的GPU采集判为无效，未作为高尔夫证据；后续有效截图有明确场景身份断言。
- G2首次managed import超时，保留原输出、放宽受控导入时限后成功；内部类型名冲突及单人提前完成的测试期望修正后重跑886。
- G3-A测试漏写WeakRef类型导致解析失败，修正后重跑。旧私有golden夹具曾硬编码`runtime_commit=3241470`，其字段或整JSON hash不能证明新源码SHA；等价结论仅指查询/mesh数据及各chunk hash。
- G3-B首轮平滑法线1e-5附加断言失败，最小解析平面证实ArrayMesh回读存在16位八面体量化；cache/query误差0，mesh距离约6.20e-5。追加全地图逐顶点codec断言又暴露脚本double标量乘法在截断阈值与原生float32不同，改用Vector2乘法后所有96chunk逐值匹配显式codec。未为测试改运行时；高度1mm及独立全局area/cache法线1e-5不变。mesh编码另用`12/65535`预算，实际顶点max0.000111748、插值mesh/query max0.000105140。
- 受控导入新增47组编辑器默认import字段逐一核对后还原，真实新脚本UID保留，原素材不改。所有专用测试严格拒绝额外错误/环境诊断/泄漏/纪录；公共smoke沿用仓库对既有静态资源退出诊断的明确排除，不据此声称全项目无泄漏。

原始日志在忽略目录`audit-output/golf-g1/`、`golf-g2/`、`golf-g3-a/`、`golf-g3-b/`、`golf-mips/`，B首轮/codec失败另保存在`golf-g3-b-initial/`及`golf-g3-b-codec-initial/`；导入、聚合runner与smoke日志同在audit-output。未把本机运行目录或真实玩家资料写入公共证据。

## 当前可复验入口

```sh
python tools/import_game.py --godot <Godot>
python tools/test_golf.py --godot <Godot>
python tools/test_golf_surface.py --godot <Godot>
python tools/test_golf_textures.py --godot <Godot>
python tools/smoke_game.py <Godot> --project game
<Godot> --headless --fixed-fps 60 --path game res://scenes/golf/golf_game.tscn -- --map=0 --demo=4
```

`<Godot>`为官方4.7.2；专用runner使用公共RS_TEST_MODE、隔离用户目录、受控自有子进程和超时日志。G1/G2/A早期记录中的固定47800占用检查仅是历史口径，当前已移除。规则与surface非法输入分别要求唯一指定拒绝错误、退出1，其他额外诊断仍失败；不停止别人的进程。

surface验收含非共面ABC0/D10（归一化.25/.25→0、.75/.75→5、最大角→10）、解析斜面、一次采样/释放Callable、全16邻边mask、对角/重叠patch、独立edge计数/投影面积/全局法线、跨chunk48、每实际三角重心及mesh构建碰撞体射线≤1mm。A数值golden `game/tests/data/golf_surface_coarse.json`保持原值：78查询、96chunk计数、30mesh样本，跨平台用数值容差，不以同机hash作为跨平台门槛。B只保留未细化/过渡粗格内部原高度样本，不改旧法线/边缘期望伪称等价。

## 截图与来源

以下为G1运行版本`d6d238a`保存的原始PNG，未编辑：2026-10-24、官方4.7.2、Radeon780M、交流供电、独立隐藏桌面、1600×900原生分辨率、中画质、关闭升频。场景/地图/人数/语言/尺寸断言通过，维护者目视检查；它们不是当前细化版或最终M1图像验收。

| 场景 | 大厅 | 比赛 |
|---|---|---|
| 海岸林克斯、中文、2人 | [大厅](screenshots/golf-g1-links-p2-zh-lobby.png) | [比赛](screenshots/golf-g1-links-p2-zh-play.png) |
| 夕阳庄园、英文、4人 | [大厅](screenshots/golf-g1-park-p4-en-lobby.png) | [比赛](screenshots/golf-g1-park-p4-en-play.png) |

截图使用真实高尔夫场景和合成demo玩家；当时私有视觉夹具采用不监听网络的ControllerHub子类，避免外部会话输入，当前新测试改用公共RS_TEST_MODE。两组有效采集无引擎/环境错误或纪录，不验证UDP、真实手柄或手机连接；Dummy音频也不验证音效。

截图包含MIT程序场地/界面及既有CC0-1.0贴图、HDRI和树，组合许可`MIT AND CC0-1.0`，沿用[第三方清单](THIRD_PARTY.md)，无新增外部素材或真实设备/玩家资料。最终M1仍需两图demo2/4截图与录屏。

## 尚未验收与性能口径

- 当前仍未实现RSGolfBall、精确62m OB、sphere sweep、水/树干碰撞、合法drop、洞杯/停球；全员终态后的跳过停顿/加速协调需独立提交和验证。M1不能因占位弧线能结束而合并为完整物理。
- 粗网格早期四人中档实渲染仅约2.114–2.873FPS且波动明显，属于诊断样本，不能作为达到体验目标的基线。旧半窗口实验未改变玩家viewport，不能作像素成本对照；静态相机材质/mip消融也不是试玩或配对验收。
- 正式细化成本须用同配置A+mip与B+mip配对；旧无mip粗版与新有mip细版不能混比。保留原始设置、源码SHA、采样健康与载入时间；四人平均FPS下降>5%或载入增加>1s即暂停评审，不牺牲0.5m共享坡面精度。目前未宣布通过。
- 维护者正协调2560×1440四人（每格约1280×720）及既有FSR质量档的独立隐藏桌面测量；本片不改生产FSR/core。实际画面、HDR/VRR、帧率、Regina/手机手感、正式单人/纪录/教学及最终2/4人录屏仍须按对应里程碑验证。
