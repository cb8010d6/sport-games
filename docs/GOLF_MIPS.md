# 高尔夫地面纹理 mip 前置修复

这是高尔夫地面缺失mip的独立修复，也是M1粗/细网格公平性能对照的共同前置，与G3-B细化分开提交。六个地面albedo/normal sampler在course构建时调用`RSGolfTextures.load_mipped(path, normal_map)`，不改shader、共享import、素材、公共框架或几何。

已有mip链的Texture2D保留原资源身份。缺mip时复制Image，必要时解压，调用`generate_mipmaps(normal_map)`后创建私有ImageTexture；所有normal sampler传true。缓存键包含路径和normal flag，跨chunk/重建课程复用；不写磁盘、不修改共享Texture或原Image。读取、类型、解压、生成或创建失败均明确报错，失败结果不缓存。[Godot Image API](https://docs.godotengine.org/en/4.7/classes/class_image.html#class-image-method-generate-mipmaps)说明压缩图须先解压，normal mip应重新归一化。

专用检查：`python tools/test_golf_textures.py --godot <Godot>`。覆盖原始数据/尺寸/mips不变、已有mips身份、normal向量重归一化、DXT1复制解压、实际八张sampler/cache重复调用、两图所有chunk共享材质及六路mip接入、跨地图复用和两个隔离错误用例。使用公共RS_TEST_MODE及临时用户目录，不接受额外引擎/环境错误或纪录文件。

Godot4.7.2受控导入和专用155项+两个隔离拒绝用例通过，无额外错误、环境诊断或纪录文件；保留两个新脚本真实UID。规范0错误、翻译477/0/0、Ruff、发布扫描1197文件/0发现及公共smoke15项通过。smoke沿用公共脚本既有静态资源退出诊断排除，不能作为无泄漏证明；专用测试没有该排除。本片未做GPU测量。

维护者后续将同一独立提交应用到冻结粗网格，比较A+mip与B+mip；旧粗网格诊断不能替代该配对，也未宣称细化成本满足5%/1s门槛。
