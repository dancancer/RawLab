# Apple ProRAW 转 HDR

ProRAW 使用独立的来源类型。macOS 和 iOS 共用 Core Image 解码适配器，再将已定向的 HDR 浮点主图
和同画布的 SDR 底图交给现有 HDR 渲染、几何调整和 JPEG 导出。首批范围依据 Mac 与 iPhone 的实测
能力开放。Android 和 Windows 使用下述独立版本的 DNG SDK 后端，再进入相同的 HDR 编辑和分块
JPEG 流程。已有的 SDR RAW 打开路径继续服务默认 SDR 编辑，不自动切换处理家族。

## 解码与参考白

- 以 DNG 元数据和解码器能力识别来源。首批识别条件包括 Apple iPhone 来源、线性 RAW 主图、
  Apple ProRAW 配置特征以及可用的 `CIRAWFilter`。用普通 Bayer DNG、转换过的 DNG 和损坏文件
  验证分类，避免只凭扩展名、设备名或单个标签判定。已测文件包含两种位深和两种解码器标识。
- 采用 Apple 默认白平衡、`BaselineExposure` 和局部色调。HDR 主图用 `extendedDynamicRangeAmount=1`
  渲染到扩展线性 sRGB，SDR 底图用 `extendedDynamicRangeAmount=0` 渲染到 sRGB。两者保持一致的
  方向和画布。主图保留高于参考白的值及有限负分量，参考白为线性亮度 1。
- 现有 HDR 编辑中的曝光和相对白平衡作用于解码后的双呈现。Apple 基线曝光只在解码时应用一次。
  为 ProRAW 解码配置单独版本化，将配置、实际系统解码器、文件身份、预览尺寸和质量纳入缓存身份。
  不套用相机 Bayer RAW 的参考白映射或按单张照片的峰值归一化。
- 保留单独的线性诊断模式，用于隔离基线、色调和色域映射的影响。线性 DNG 与 Apple 默认 EDR
  显影属于不同阶段，使用同一张原片做比较，避免以大于 1 的像素数量判断传感器是否饱和。

## 接入现有 HDR 流程

1. 在 `HDRSourceInfo` 和 `HDRImage` 的 Apple 来源入口接入 ProRAW。先保留当前来源类型及其
   解码规则。Apple 解码器提供匹配的图像尺寸、预览标记和来源 SHA-256。预览采用有界
   `scaleFactor`，校验实际输出长边后才进入现有预览缓存。
2. 用现有 HDR 浮点双图契约调用 `sony2fuji_hdr_render`。Swift 持有解码缓冲并借给核心；
   核心先复制为独占输入，再移动给渲染器，避免重复复制整幅双图。已发布的核心 owner 保持只读，
   继续使用复制路径。Core Image 按行块写入 RGB，保留负分量、高光和从上到下的位图行序。
   完整任务进入 Core Image 和共享核心前完成内存准入，并在各阶段检查取消。预览不充当全尺寸输入。
3. ProRAW 默认走 SDR 编辑，显式切换 HDR。沿用独立 SDR/HDR 调整和上次模式恢复的交互，
   保存 ProRAW 来源配置版本。只在成功解码后切换模式，打开失败、取消或资源不足时保留原编辑记录。
4. 用当前 HDR JPEG 增益图编码和 SDR JPEG 导出。冻结来源身份、模式和调整后，从原片执行
   FINAL 解码，保留原始画布与方向。源 DNG 保持只读。JPEG 迁移机型、镜头、拍摄时间、
   曝光时间、光圈、ISO 和焦距等拍摄 EXIF；按输出重写尺寸、方向和色彩空间，排除 MakerNote
   和 RAW 专有结构。原片 SHA-256 必须与解码时一致；增益图元数据由当前编码器生成。
5. 各端的复制、预设、同步和统一参数批量仅对明确探测为 ProRAW 的 RAW 开放 HDR 调整传递。
   每个目标保留自己的 HDR/SDR 模式和未选择调整。手动复制、预设、同步中的相对白平衡不跨
   模式隐式转换，选中该字段时整个目标预检拒绝；只选曝光等公共字段可跨模式应用。统一参数
   批量沿用现有规则：中性相对白平衡不改变 SDR 目标白平衡，非中性值在预检时拒绝该目标。

macOS 开放 12 MP 和 48 MP 的全尺寸 JPEG 导出。iOS 首批在 iPhone 14 Pro Max 的 iOS 27 上
开放 12 MP、48 MP 的分块 HDR/SDR JPEG 导出，其他设备保留 HDR 预览和编辑。当前内存不足时，
已开放的设备仍会拒绝该次导出。iOS 整图 PNG/DNG 路径仍仅开放已验证设备的 12 MP。
JPEG 导出使用下述分块 FINAL 路径；缩小输出仍读取完整原片，不以预览替代。PNG/DNG 的整图
路径保持独立门槛。iOS ProRAW 几何源预览固定为 2048 长边上限，几何处理后再按视口缩放，避免
几何缩小的画布反复触发更小的源解码。普通预览沿用 1280 视口所需的源尺寸，为导出保留内存。

## 分块 JPEG 导出

Mac 和 iOS 的编辑器、批量 JPEG 导出使用 `sony2fuji_hdr_export_stream`。来源回调逐行提供
完整、已定向的 FINAL HDR/SDR RGB32F；原始尺寸、解码配置版本、实际解码器和来源 SHA-256
与本次任务绑定，预览和局部块不能伪装成完整 `HDRImage` 双图。

1. 独立 Metal Core Image context 关闭中间缓存，按 256 行生成 HDR/SDR 像素。逐块应用现有
   颜色算法，写入任务私有 RGB32F 临时文件，保留负分量及参考白以上的值。
2. 有界 tile cache 在全局坐标中复用几何采样，再执行输出 resize。顺序保持颜色 → 几何 →
   resize，保留两次插值、原画布中心、边界和舍入规则；不按块重置旋转或透视中心。
3. 生成 HDR half-float 和 SDR 8-bit 紧凑输入，逐一映射、提交并解除映射。codec 复制后立即
   释放调用方输入，编码前释放解码器。继续使用 libultrahdr 的 `BEST_QUALITY`、全尺寸多通道
   增益图和全图统计，重封装前释放不再需要的 owner。
4. 每次只发布用户选定的一种 JPEG。沿用 EXIF 映射、源文件摘要复核和 hardlink/同文件保护；
   写入相邻临时目标、同步后原子 rename，失败保留已有目标。SDR JPEG 使用共享 libjpeg
   编码与显式 sRGB ICC，不带增益图；不宣称与 ImageIO SDR JPEG 逐字节相同。
5. 解码、codec 和 metadata 重封装分别进行内存准入；临时空间按原始像素及输出像素预检。
   RAII 清理成功、取消和失败路径的任务文件；下次导出通过 marker 与非阻塞独占锁回收
   异常终止遗留的像素文件，保留活跃任务和无标记目录。调用方负责所有回调中断后的解码资源清理。

全尺寸 48 MP 的临时像素文件约 1.8 GB，空间准入连同压缩产物余量要求约 2.2 GB 可用空间。codec 内仍有整图缓冲，内存占用仍随照片尺寸增长。
当前 codec 调用无法中途抢占，取消在返回后阻止后续发布。iOS 单张和批量把取消传入解码/渲染，
在写入 Photos 前再次检查；进入 Photos 写入后的中断沿用 checkpoint/待确认机制，避免重复发布。
Mac 批量取消沿用当前目标结束后停止的行为。

## 实现门槛

- 同一原片比较 Apple 默认 SDR、EDR 及线性诊断。在原始尺寸确认参考白以上的不同亮度级能
  随降低曝光进入 SDR 范围，并检查旋转、尺寸、色偏和重复应用基线。
- 对 12 MP、48 MP 在 Mac 和 iPhone 分别记录冷预览、热编辑、完整导出及峰值内存。先通过
  对应分辨率的内存、取消及失败恢复验证，再开放该设备上的全尺寸导出。
- 验证重开恢复独立调整，HDR JPEG 的增益图能解码回 HDR，SDR JPEG 没有增益图，两种输出
  保持预期尺寸，原片哈希一致。再用同一 iPhone 和同一高反差场景补充 12 MP、48 MP 配对样片，
  并覆盖不同 iOS 解码器版本、非 ProRAW DNG 和传感器饱和场景。

Apple 的 ProRAW 文件结构和默认显影接口见 [Capture and process ProRAW images](https://developer.apple.com/videos/play/wwdc2021/10160/)。

## 可移植解码边界

Android/Windows 的解码配置版本为 2，区别于 Apple Core Image 的版本 1。Adobe DNG SDK 1.7.1
通过完整 `dng_negative` / `dng_render` 链路应用原始白平衡、基线曝光、嵌入相机 profile 和
`ProfileGainTableMap`。SDR 保留原始嵌入 profile；HDR 在其副本上设置 HDR dynamic-range 信息
及 4 倍最大输出提示，启用 overrange 浮点输出。仅把最终像素类型设为 `ttFloat` 不足以获得 HDR。
这套显影与 Apple Core Image 的局部色调、参考白和 EDR 策略不等价，不保证逐像素一致。
保存的未知或不兼容版本会被拒绝，不能静默按当前版本重写。

原生 `dng_image` 使用私有文件保存 stage 和显影结果，按块读写；SDK allocator 对 JPEG XL 等绕过
图像存储的内存分配另外准入。预览返回有界双图，Android 源预览最高 1600 长边；全尺寸和缩小
JPEG 都由 `sony2fuji_hdr_export_proraw` 重新读取完整原片，复用共享分块颜色、几何和发布流程。
SDK stage 文件使临时空间需求高于 Apple 回调路径，原片与 codec 缓冲仍需要运行时内存准入。
不能把磁盘分块视为任意设备都可完成 48 MP 导出。
导出前按同一卷上的 stage 与 stream 合计预检：`112 × 原始像素数 + 20 × HDR 输出像素数 + 192 MiB`；
SDR JPEG 的输出项改为每像素 4 字节。原尺寸 48 MP HDR 约需 6.2 GiB 临时可用空间，缩小输出
仅减少输出项。各阶段仍再次检查，其他进程占用空间导致的后续 I/O 失败继续保留原有目标。

Android 单张和批量将取消传入原生解码/导出，并在 MediaStore/SAF 发布前再次检查；已进入外部
发布的操作保留原有 checkpoint/待确认语义。Windows 使用相同的原生取消与临时文件恢复契约。
物理 HDR 显示和移动设备的大图性能仍须独立验收，模拟器和远程桌面不提供这类证据。
严格的分辨率对照样片须为同一机型、镜头、等效焦距和高反差场景的 12 MP/48 MP 原片；
相近时间但不同镜头或裁切倍率的照片只用于扩充场景覆盖。

## 回归入口

- `RawLabMac/tests/hdr-bridge.sh <ProRAW 原片>...` 检查分类、分块行序、有界预览、完整编辑、
  JPEG 元数据和增益图往返。原片使用共享素材目录，不入库。
- `RawLabMac/tests/proraw-stream.sh <ProRAW 原片>...` 对照整图参考验证几何、缩放、JPEG、
  来源 headroom、EXIF/ICC、取消、最终 rename 失败和再次导出。
- `hdr_stream_geometry`、`hdr_stream`、`hdr_stream_api` 覆盖核心采样、编码和来源/发布契约。
- `proraw_hdr_portable` 通过 `RAWLAB_TEST_PRORAW` 接收外部原片；比较有界存储与独立 SDK
  整图参考，并验证完整来源导出。`RAWLAB_TEST_PRORAW_JXL=1` 额外生成无损 JPEG XL 测试副本。
  `RAWLAB_TEST_PRORAW_SPACE_ONLY=1` 在独立受限临时卷上验证合计空间不足时尚未开始解码；
  该卷需能容纳单个 stage 预算，但无法容纳完整合计预算，不能对日常数据卷填盘造故障。
- Android `-PrawlabTestProRAW=/path/to/source.dng` 只将原片复制进测试 APK；
  `ProRAWNativeInstrumentedTest` 和 `HDRWorkflowTest` 覆盖原生预览、分块导出、取消恢复、
  模式持久化及实际相册回读。
- 两端 `hdr-model.sh` 覆盖 ProRAW 能力、模式保留与相对白平衡拒绝规则。
- Mac 的 `hdr-batch.sh` 可设置 `RAWLAB_TEST_PRORAW`；iOS 的 `hdr-batch.sh` 使用专用
  模拟器和已构建的模拟器应用，通过 `SIMCTL_CHILD_RAWLAB_TEST_PRORAW` 传入同一原片路径。
  该可选分支检查新目标保持 SDR、已有 HDR 目标保留独立 SDR 调整，以及预检不写入编辑记录。
- iOS `HDRPhotoUITests` 的 ProRAW 用例在专用样片应用中执行复制、预设应用、模式切换、
  重开恢复和导出入口检查。`ProRAWStreamUITests` 在获准真机上覆盖 48 MP 几何/缩放、
  单张与批量取消后恢复、12 MP/48 MP 混合批量，以及 HDR/SDR Photos 原始资源回读。
