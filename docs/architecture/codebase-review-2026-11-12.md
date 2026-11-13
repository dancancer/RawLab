# RawLab 全仓代码评审与整改清单（2026-11-12）

本文记录 2026-11-12 对 `development` 分支做的一次全仓只读评审，用来驱动后续多个整改 PR。
整改结束后按根目录 `AGENTS.md` 的文档约定移入 `docs/archive/`。

## 1. 基线与阅读方式

- 基线：`development` @ `9c4f7801`。文中行号都以这个提交为准。
- 方法：按七个范围分头细读，汇总时再抽查 24 处关键结论对照代码复核，24 处全部与细读结论一致。
  七个范围是：核心算法与构建、核心对外接口与 GPU、iOS 与 `Shared/`、Mac、Android、Windows、
  仓库级与跨端一致性。
- 没有运行任何构建、测试或应用。文中的耗时、内存、体积数字都是按代码推算的，没有实测。
- 文档只是线索。动手整改前，先按当前 `origin/development` 重新核对该条是否仍然成立。
- 2026-11-13 起对第 13.2 节"没有覆盖到的范围"做了补充评审，结果在第 14 节。补充评审的基线是
  `origin/development` @ `191d8aba`，第 14 节的行号以那个提交为准，与前面各节不同。

确认程度的标记：

| 标记 | 含义 |
|---|---|
| 已复核 | 细读得出，汇总时又对照代码核对过一次 |
| 已读 | 细读时读代码确认，汇总时没有再核对 |
| 待验证 | 代码结构已确认，但触发条件、频率或后果要运行或查外部设置才能确定 |

编号前缀：`X` 跨端共性，`C` 核心库 `lutools`，`M` Mac，`I` iOS 与 `Shared/`，`A` Android，
`W` Windows，`R` 仓库、CI 与跨端契约。

以下既有决定不在评审范围内，文中没有把它们当问题：

- 核心 OpenMP 在 Mac、iOS、Android 保持关闭，Windows 只对 `raw_processor.cpp` 开启。
- 不重构 Mac 预览接受规则，不做"统一完整渲染配置 / 合并 C ABI"。
- 几何预览复用缩小的视口源，精确渲染只在实际像素查看、最终结果和导出时做。
- GPU Auto 保留 CPU 回退，Force 不伪装成功；AI 降噪只在硬件 GPU 后端运行，不回退 CPU。
- 桌面更新走零预算签名方案；Windows 使用单实例锁；应用未上架商店。
- 跨端文案对齐（PR #74）已完成；X3F 模式与迁移回执的既定行为不变。

## 2. 结论总览

### 2.1 第一批：建议最先处理

| 顺序 | 编号 | 问题 | 严重度 | 确认程度 |
|---|---|---|---|---|
| 1 | W1 | Windows 手动安装包用户永远收不到新版本提示 | 高 | 已复核 |
| 2 | C1 | Mac 和 iOS 链接的是 LibRaw 的非线程安全版本 | 高 | 构建配置已复核，并发情况待验证 |
| 3 | R1 | 外部仓库的 PR 可以在自托管物理机上执行代码 | 高 | 工作流已复核，仓库设置待验证 |
| 4 | A3 | Android：HDR 外观导入中按返回，编辑器永久停在"忙" | 中 | 已复核 |
| 5 | M1 | Mac：带增益图的 HDR 照片无法画面取色 | 中 | 已复核 |
| 6 | X1 | Android 编辑记录写入不做落盘同步，可能静默丢失全部编辑 | 中 | 写入处已复核 |
| 7 | I1、A2 | iOS 和 Android 的应用私有存储只增不减 | 高 | iOS 已复核，Android 已读 |
| 8 | W2、W3 | Windows 自动更新一次失败后静默停摆；状态文件写失败锁住编辑区 | 中 | 已读 |
| 9 | R2 | Apple 两端 9 个文案键漏翻，CI 不检查 | 中 | 抽查 4 个已复核 |
| 10 | A4 | Android 普通导出无法中途取消 | 中 | 已复核 |
| 11 | C3 | 核心主渲染入口缺兜底的异常捕获 | 中 | 已复核 |
| 12 | X4 | 单张导出直接写最终路径，核心写 JPEG 发现不了写入失败 | 中 | 核心调用已复核，其余已读 |

### 2.2 最值得统一解决的共性

同一个设计在四个客户端各出了一遍问题，逐端零散修补不如统一处理：

- 编辑记录放在单个文件里，每次提交整份读、整份写（X1）。
- 热路径上反复整文件读取并算校验值（X2）。
- 每次操作都新建渲染引擎或会话，随之重新解析镜头库、重新解码 RAW（X3）。
- 单张导出不是"先写临时文件再替换"（X4）。
- 批量任务日志每次保存先读回再全量重写，一个坏日志拖垮全部任务（X5）。

### 2.3 数量

主要发现 81 条，次要问题约 70 条（见第 10 节）。按范围分布：跨端共性 6，核心库 24，Mac 6，
iOS 11，Android 10，Windows 10，仓库与流程 14。

以上是 2026-11-12 这一轮的数量。补充评审新增的条目另计，见第 14 节开头。

## 3. 跨端共性问题

### X1 编辑记录是单个文件，每次提交整份读、整份写，且逐条不容错

- 严重度：中（随编辑过的照片数量线性变差）｜确认程度：Mac 读写路径和 Android 写入处已复核，其余已读
- 位置：
  - Mac：`RawLabMac/Sources/Editor/Storage/EditPersistence.swift:66-81`、`:158-169`；
    `RawLabMac/Sources/Editor/Model/EditorModel+AdjustmentHistory.swift:24-49`；
    `RawLabMac/Sources/Editor/Storage/AdjustmentTransferSession.swift:111`、`:144`；
    解码即抛错 `RawLabMac/Sources/Adjustments/Adjustments.swift:775-820`；
    打开失败处理 `RawLabMac/Sources/Editor/Model/EditorModel+Workflow.swift:380-387`；
    无效的重试入口 `RawLabMac/Sources/Editor/View/EditorView.swift:500-505`
  - iOS：`RawLab/RawLab/Core/Persistence/EditPersistence.swift:131-141`、`:204-211`、`:361-385`、`:409-419`；
    `RawLab/RawLab/Core/ViewModel/IO/RawEditorViewModel+PersistenceAndExport.swift:29-70`；
    严格解码 `RawLab/RawLab/Core/Models/RawSettings.swift:529-584`、`Shared/HDRSettings.swift:527-558`
  - Android：`RawLabAndroid/app/src/main/java/com/rawlab/android/settings/EditPersistence.kt:54-58`、`:130-173`、`:181-205`；
    `.../editor/storage/EditorEditStore.kt:37`；`.../editor/EditorViewModel.kt:112`、`:276-294`、`:767`；
    `.../editor/controls/AdjustmentControls.kt:235-237`
  - Windows：`RawLabWindows/EditPersistence.cs:192-209`、`:216`、`:220-234`；`RawLabWindows/EditWorkflow.cs:41-67`；
    `RawLabWindows/EditedPhotoPreviews.cs:38-39`、`:125-129`；`RawLabWindows/AdjustmentTransferSession.cs:58`、`:87`
- 问题：
  1. 所有照片的调整都在一个文件里。每次松开滑杆都在主线程整份读入、整份序列化、整份写回。
  2. 记录、删除标记、迁移回执都只增不减，照片越多每次提交越慢。
  3. 缩略图刷新时，每张可见缩略图还要把整份文件再解码 2 到 6 次（Mac 见 M2，iOS 见 I3，
     Windows 见上面列出的 `EditedPhotoPreviews.cs`）。
  4. 批量粘贴到 N 张照片是 N 次整份读加 N 次整份写。
  5. Mac 和 iOS 把所有记录一次性严格解码。任何一条记录不被当前版本接受，整份解码失败，
     所有照片都打不开或无法保存，界面只有一个点了没用的"重试"。应用是自行安装分发，
     装回旧版本是可能发生的场景。Windows 每次读取也逐条校验，单条失败是否拖垮全部没有核对。
  6. Android 写完临时文件后不做落盘同步就改名（`EditPersistence.kt:195-196`），而草稿、批量日志、
     相机日志、预设库都做了。断电后可能得到空文件或全零文件，读取时被当成"零条记录"而不报错，
     等于静默丢失全部编辑。`replaceFile` 内部没有读，改之前先确认它是否已同步。
  7. Android 的 `EditorViewModel` 构造时在主线程读入并解码全部记录，拖慢冷启动；提交期间控件被禁用，
     期间按下的手指要抬起重按。
- 整改方向，按风险从低到高分三步：
  1. 立即可做：Android 补落盘同步；读到"非空文件却零条记录"时报错而不是当成空库。
  2. 进程内保留一份已解码的记录，用文件大小和修改时间判断是否需要重读；缩略图和批量流程复用它；
     批量提交合并为一次写；写入放到后台串行队列。
  3. 逐条容错：读不懂的记录原样保留并透传写回，其他照片照常可用；读失败时给出"另存损坏文件并重建"
     的入口。中期考虑按照片分文件。
- 注意：`RawLabMac/tests/EditMemoryTests.swift:89-97` 明确断言"未知处理版本要拒绝整个注册表且不改写文件"。
  "不覆盖"是有意的，要保留；要改的是"其余照片也全部不可用"这个连带后果，改时同步更新这条测试。
- 验收：各端补"一条坏记录不影响其他照片"的测试；Android 补"空文件报错"的测试；
  记录数达到几千条时测一次单次提交耗时。

### X2 热路径上反复整文件读取并算校验值

- 严重度：中｜确认程度：Mac 调度路径和 Android 相机加载已复核，其余已读；耗时未测
- 位置与表现：
  - Mac：`referenceSource` 每次都做 HDR 探测，核心侧映射整个文件并算 SHA-256。
    `RawLabMac/Sources/Editor/Model/EditorModel+HDR.swift:4-7`；每次调度 `EditorModel+Rendering.swift:88`；
    每次渲染完成 `:190`；打开时再各一次 `EditorModel+Workflow.swift:371`、`:390`、`:478`；
    代价依据 `Shared/Native/HDRSource.swift:122-131`、`lutools/src/platform/hdr_image_apple.mm:67-86`。
    只影响 JPEG/HEIC 输入，拖滑杆时每一格都在主线程做一次。
  - Mac 缩略图：`MacPhotoPreviewPlan` 每构造一次就把 LUT 文件整个读入算 SHA-256，一张缩略图要构造 4 次以上。
    `RawLabMac/Sources/Library/MacEditedPhotoPreviews.swift:132-137`、`:159-169`、`:203-237`
  - Windows：`IsHDRContainer` 只看扩展名，普通 JPEG 每帧预览被整文件读入两次，打开时还在界面线程探测一次。
    `RawLabWindows/RenderEngine.cs:178`、`:280-283`、`:608`；`RawLabWindows/PhotoInput.cs:13-24`；
    `RawLabWindows/MainWindow/Rendering.cs:30`；`lutools/src/platform/hdr_image_portable.cpp:48-69`、`:290`
  - Windows：每帧预览都重新读取 LUT 文件并算 SHA-256，每张编辑缩略图重复算 4 到 5 次。
    `RawLabWindows/MainWindow/Rendering.cs:173`；`RawLabWindows/EditedPhotoPreviewCache.cs:14-34`；
    `RawLabWindows/EditedPhotoPreviews.cs:59-60`、`:66`、`:100`、`:104`、`:116-119`
  - iOS：每次保存调整后，当前照片的缩略图校验对原片做约三遍整文件 SHA-256；"最近打开"网格里每张约四遍。
    `RawLab/RawLab/Core/Persistence/IOSPhotoPreviews.swift:27-56`、`:88-98`、`:147-162`、`:178-181`、`:194-246`；
    `RawLab/RawLab/Core/Persistence/RecentPhotoStore.swift:107-117`；`RawLab/RawLab/UI/Editor/ContentView.swift:196-201`
  - iOS：批量集合在主线程对整张原片算校验值。
    `RawLab/RawLab/Core/Batch/Model/IOSBatchSelection.swift:20-27`、`:30-36`、`:63-67`；
    `RawLab/RawLab/UI/Editor/ContentView+BatchSelection.swift:6-10`、`:51-58`；
    `RawLab/RawLab/UI/Export/IOSBatchSelectionView.swift:147-170`
  - Android：相机导入记录每次加载都重算所有历史照片的校验值，见 A1。
  - Android：加入选片集合时每张照片连续算两次。`.../editor/EditorCollections.kt:94`、`:98`
- 整改方向：每端做一个"文件身份"缓存，用路径、大小、修改时间、文件号做便宜的变更判断，
  只在不一致或真正要使用该照片时才重算校验值。打开照片时算一次指纹并放进模型，调度时只比较身份。
  LUT 的指纹同样按文件身份缓存。
- 验收：对 30MB 左右的 JPEG 拖动滑杆，确认主线程上不再出现整文件读取；补一条"文件被外部改动后能发现"的测试，
  防止缓存掩盖真实变化。

### X3 每次操作都新建渲染引擎或会话，随之重新解析镜头库、重新解码 RAW

- 严重度：中（iOS 上实测单次加载若达几十毫秒应升为高）｜确认程度：核心侧"每次设置都加载"已复核，其余已读
- 位置：
  - 核心：`lutools/src/ffi/sony2fuji_c.cpp:1531-1544` 每次调用都执行 `LensCorrectionDatabase::load`；
    `lutools/src/core/lens_correction.cpp:91-117` 没有进程级缓存，每次把约 5MB、55 个文件的镜头库整个解析一遍。
  - iOS：只有 RAW 预览复用会话。JPEG、HEIC、PNG、TIFF 和 HDR 的每个预览帧都新建会话。
    `RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor.swift:117-147`、`:489`、`:65`、`:276`、`:289`；
    `RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor+Lens.swift:145-158`；
    `RawLab/RawLab/Core/ViewModel/RawEditorViewModel+Rendering.swift:174-179`、`:306-316`
  - Mac：自动曝光、HDR 打开、粘贴预检各自新建引擎。
    `RawLabMac/Sources/Editor/Model/EditorModel+Workflow.swift:501`、`:417`；`EditorModel+HDR.swift:43`；
    `EditorModel+AdjustmentTransfer.swift:111`、`:118`、`:146`；依据 `RawLabMac/Sources/Rendering/Engine.swift:499`
  - Windows：粘贴预检每个 RAW 目标新建一个引擎并渲染一次，只为拿相机白平衡；每张编辑缩略图新建一个引擎。
    `RawLabWindows/MainWindow/AdjustmentCommands.cs:75-78`、`:86-94`；`RawLabWindows/EditedPhotoPreviews.cs:71`
  - Android：批量每加一张目标、粘贴每个目标都新建处理器解码一次。
    `.../batch/BatchExportModel.kt:272-289`；`.../editor/EditorAdjustmentTransfer.kt:69-80`
- 整改方向：
  1. 核心给镜头库加进程级共享缓存，按路径和指纹失效。这一处改动四端同时受益，建议最先做。
  2. 客户端在同一条队列上的操作复用现有引擎；批量预检共用一个引擎。
  3. iOS 的普通图片和 HDR 预览也复用会话；镜头校正关闭且输入是显示缓冲时不加载镜头库。
- 验收：iOS 补一个普通图片和 HDR 预览的耗时基准（现有 `RawLab/tests/PreviewPerformanceTests.swift:185-229`
  只测 RAW）；核心补"两个会话共享同一份镜头库"的测试。

### X4 单张导出直接写最终路径；核心写 JPEG 发现不了写入失败

- 严重度：中｜确认程度：核心用 stb 写 JPEG 已复核，其余已读
- 位置：
  - 核心：`lutools/src/core/raw_processor.cpp:911-949`、`:955`；`lutools/src/core/stb_image_write.h:284-287`、`:339-342`
  - 核心 HDR：`lutools/src/platform/hdr_image_portable.cpp:161-163`、`:283-288`、`:323-350`（发布前不做落盘同步）
  - Mac：`RawLabMac/Sources/Editor/Model/EditorModel+Workflow.swift:689-713`；`RawLabMac/Sources/Rendering/Engine.swift:690-717`；
    `Shared/ExportMetadata.swift:66-116`；退出不检查导出状态 `RawLabMac/Sources/System/MacGeometryWindowGuard.swift:148-168`
- 问题：
  1. 核心用 stb 写 JPEG 和 PNG，stb 不检查写入和关闭的返回值。磁盘写满或卷被拔掉时仍返回成功，留下截断文件。
  2. JPEG 和 PNG 直接写目标路径，失败会毁掉被覆盖的旧文件；只有 DNG 是暂存后替换。
  3. Mac 单张导出把结果直接写到用户选的路径，随后元数据步骤再整文件改写一次。元数据失败时界面报错，
     但目标位置已有一张没有拍摄信息的图。导出中按退出会直接结束进程。
  4. 批量导出四端都用了临时文件加改名，单张和批量两条路径不一致。
- 整改方向：核心复用已有的、带错误处理的 libjpeg-turbo 编码器（`lutools/src/core/hdr_jpeg.cpp:347-413`），
  并套用 DNG 的暂存替换方式，这也顺带消除两套 JPEG 编码器并存的重复。Mac 单张导出先写到目标目录的临时文件，
  全部成功后改名；退出时若正在导出先提示或等待。
- 验收：补"写入失败时目标位置的旧文件保持原样"的测试；Mac 补"元数据步骤失败不留残缺文件"的测试。

### X5 批量任务日志每次保存先读回再全量重写；一个坏日志拖垮全部任务

- 严重度：低到中｜确认程度：已读
- 位置：
  - iOS：`RawLab/RawLab/Core/Batch/Storage/BatchExportStorage.swift:20-27`；`RawLab/RawLab/Core/Batch/Execution/BatchExportRunner.swift:21-114`
  - Windows：`RawLabWindows/BatchExport.cs:165-170`、`:262-324`
  - Mac：`RawLabMac/Sources/Export/BatchExport.swift:180-185`；失败后未清理外观副本 `EditorModel+Workflow.swift:334-345`
  - Android：`.../batch/journal/BatchJournal.kt:81-93`、`:138-145`；`.../editor/EditorBatches.kt:78-89`；
    `.../photo/WorkingCopyCleanup.kt:10-19`
- 问题：
  1. iOS 和 Windows 每个目标保存 3 到 4 次日志，每次先读回并校验旧文件再整份写回，总开销随目标数平方增长。
  2. Mac 旧的任务文件读不出时，新建批量任务和选片集合导出都失败，应用内没有恢复入口。
  3. Android 任何一个日志读取抛异常，所有未完成任务都不显示；启动清理遇到同样的异常直接返回，
     缓存里的工作副本从此不再清理。
- 整改方向：日志只在首次保存时校验旧文件，逐项更新改为增量或节流；逐个任务捕获异常，
  坏日志单独标记为"无法读取，可放弃"，不影响其他任务和启动清理。
- 验收：补"存在一个损坏日志时其他任务仍可见、清理仍执行"的测试。

### X6 相机下载每传完一张就把整张卡重新列一遍

- 严重度：中｜确认程度：已读；单次往返耗时未测
- 位置：iOS `RawLab/RawLab/Core/Camera/SonyCameraSession.swift:115-132`、`:198`；
  Android `.../camera/protocol/SonyMobileSession.java:82-99`、`:122-124`
- 问题：下载完成后用整卡列表核对元数据没变，每页 100 条逐页往返。卡上有几千张时，
  总往返次数是"导入张数 × 卡上页数"。两端是同一套逻辑。
- 整改方向：只核对该照片所在的那一页，或每批结束统一核对一次。Mac 是功能基准，
  先确认 Mac 侧的相机导入是否有同样逻辑（本次没有读到）。

## 4. 核心库 `lutools`

本节路径省略前缀 `lutools/`，例如 `src/ffi/sony2fuji_c.cpp` 指 `lutools/src/ffi/sony2fuji_c.cpp`。

### C1 Mac 和 iOS 链接的是 LibRaw 的非线程安全版本

- 严重度：高（前提是同一进程里两个线程同时解 RAW）｜确认程度：链接目标和编译宏已复核；并发情况待验证
- 位置：`CMakeLists.txt:66`、`:72-75`；`platform/ios/build-framework.sh:55`；`RawLabMac/build-dependencies.sh:78-93`；
  上游 `LibRaw-cmake` 的 `CMakeLists.txt:476-478`（本地缓存在 `.cache/shared/ios-framework-libraw-0.22.2/sources/`）
- 问题：核心固定取 `raw` 目标，上游给它加了 `LIBRAW_NOTHREADS`。该宏下位缓冲、Sony 解密等用进程级静态变量，
  两个线程各用一个实例也会互相踩，结果是解码报错或像素悄悄出错。
  据细读，Windows 和 Android 自己编译 `raw`，没有这个宏（`RawLabWindows/native/CMakeLists.txt:29-33`、
  `RawLabAndroid/app/src/main/cpp/CMakeLists.txt:26`），这一点汇总时没有复核。
- 待验证：Mac 的编辑预览、缩略图、批量导出各有队列（如 `RawLabMac/Sources/Export/BatchExportModel.swift:90`），
  是否真会同时解码；iOS 有会话锁，可能已被串行化。
- 整改方向：改链 `raw_r`（pkg-config 名为 `libraw_r`）。`cmake/libraw/CMakeLists.txt:18` 的补丁循环已覆盖两个目标。
  改动会使 Apple 构建机上的依赖缓存失效，需要一并重建。
- 验收：补一条两个线程同时解码不同 RAW、结果与单线程逐位一致的测试。

### C2 Android 和 Windows 的 GPU 路径用了未分块的色度降噪

- 严重度：中到高（Android 上偏高）｜确认程度：调用关系已复核；内存数字是推算
- 位置：`src/gpu/gles_photo.cpp:297`；`src/gpu/d3d11_photo.cpp:216`；对照 `src/gpu/metal_photo.mm:1172`、
  `src/ffi/sony2fuji_c.cpp:2547`；实现 `src/core/chroma_denoise.cpp:209-251`、`:311-336`
- 问题：CPU 和 Metal 用按 128 行分块的 `applyChromaDenoiseWorking`；GLES 和 D3D11 在原始分辨率上用整图版本
  `applyChromaDenoise`，同时存活多张整幅临时图。按代码推算，在原图之外约多 56 到 76 字节每像素，
  6100 万像素约 3.4 到 4.6 GB。
- 整改方向：两处改用分块版本。两处的工作图都是渲染器自有、失败即丢弃，满足分块版本的前提。
- 验收：补一条两种实现结果一致的回归。

### C3 主渲染入口缺兜底的异常捕获，部分 Metal 路径不拦系统异常

- 严重度：中｜确认程度：`sony2fuji_process` 已复核，其余已读
- 位置：`src/ffi/sony2fuji_c.cpp:2682-2707`、`:2709-2723`、`:2877-2915`；对照 `:2168-2172`、`:2667-2671`、`:2770-2774`；
  `src/gpu/metal_lut.mm:160-181`；`src/gpu/metal_stats.mm:249`
- 问题：`sony2fuji_process`、`sony2fuji_preview_lut_compatibility`、`sony2fuji_analyze_image` 只接 `std::exception`。
  它们能到达的 `applyLutMetal` 和 `computeImageStatsMetal` 不拦 `NSException`，抛出就会越过 C 接口边界。
- 整改方向：三个入口补 `catch (...)`；两个 Metal 入口补 `@try` 和 `@autoreleasepool`。

### C4 独立 LUT 的 GLES 上下文绑定后不释放、不恢复

- 严重度：中到低｜确认程度：代码已复核；真机表现待验证
- 位置：`src/gpu/gles_lut.cpp:110-112`、`:191-196`、`:277-318`；对照 `src/gpu/gles_photo.cpp:38-57`、
  `src/gpu/gles_denoise.cpp:18-35`
- 问题：`applyLutGles` 只做绑定，返回时不解绑；另外两处实现都保存并恢复。上下文留在首个调用线程上，
  Android 有多个执行线程，其他线程再调用会绑定失败，Auto 模式静默回退 CPU。
- 整改方向：复用 `gles_photo.cpp` 里保存、恢复、解绑的写法；三份 EGL 初始化代码合并成一份。

### C5 GPU 非关闭时，"独立 LUT"分支整图处理，多出 2 到 3 份整幅浮点拷贝

- 严重度：中到高｜确认程度：已读
- 位置：`src/ffi/sony2fuji_c.cpp:891-893`、`:937-950`、`:2527-2530`；`src/gpu/lut_gpu.cpp:92-110`；
  `src/gpu/metal_lut.mm:34`、`:99-107`、`:160-181`
- 问题：`applyPhotoLook` 只按"GPU 模式不是关闭"就选整图分支，先拷一份，`applyLUTWithConfig` 再拷一份，
  Metal 再整幅上传；关闭模式只用 3 MiB 分块。Windows 没有独立 LUT 的 GPU 后端，这些拷贝完全白做。
  触发条件：显示输入（JPEG、HEIF、正常 X3F）或 GLES/D3D11 上的 DCP 外观，Auto 模式全尺寸导出，
  且 HSL、降噪、效果都未启用。
- 附带：`metal_lut.mm` 每次重建 LUT 纹理，并用硬件线性采样，与 CPU 和照片管线的显式三线性不同
  （是否造成可见差异待验证）。
- 整改方向：只有确实会尝试独立 LUT 的 GPU 路径时才走整图分支；Metal 侧分块处理并复用照片管线的显式插值。

### C6 D3D11 照片后端没有分块

- 严重度：中｜确认程度：已读；显存阈值未实测
- 位置：`src/gpu/d3d11_photo.cpp:52`、`:93-106`、`:134-147`、`:203-211`
- 问题：输入、两张处理缓冲、缩放结果、回读缓冲都是整幅并留在会话里；Metal 和 GLES 都按 16 MiB 分块。
  大图在显存较小的显卡上会创建失败，预览每帧都失败后回退。
- 整改方向：按行分块上传、处理、回读，至少对输入和回读缓冲分块。

### C7 GLES 和 D3D11 渲染器任何异常都销毁重建，失败没有记忆；着色器每个会话重新编译

- 严重度：中｜确认程度：已读
- 位置：`src/gpu/gles_photo.cpp:266-267`、`:327-333`；`src/gpu/d3d11_photo.cpp:80-88`、`:163`、`:231-233`；
  `src/gpu/denoise.cpp:47`；`src/gpu/d3d11_denoise.cpp:72`
- 问题：在不支持或必然失败的设备上，Auto 模式每次渲染都重新建上下文、编译着色器，再回退 CPU。
  D3D11 每个会话（含导出和迁移用的临时会话）都按最高优化级别现编译，没有进程级缓存。
- 整改方向：区分"设备不可用"和"本次请求失败"，前者记住并退避；编译结果进程内共享。

### C8 CPU 路径的非视口预览会移走大图的 RAW 缓存，下一次渲染整幅重解码

- 严重度：中｜确认程度：已读；实际体感取决于客户端调用顺序，待验证
- 位置：`src/ffi/sony2fuji_c.cpp:2306-2314`、`:2435-2437`、`:2456-2459`、`:1176-1179`；对照 `:1331-1334`
- 问题：缓存被直接移走，没有判断用途；而输出阶段却专门为"预览到缓冲"保留缓存，两处意图矛盾。
  触发条件：缓存超过 128 MiB（约 1100 万像素以上），走 CPU 路径，且是非视口预览（如实际像素查看的定格帧）。
- 整改方向：预览用途下保留缓存，或把"内存优先还是速度优先"交给平台决定。

### C9 CPU 管线里多个整图阶段实际是单线程

- 严重度：中｜确认程度：结构已读；耗时为推测
- 位置（均在 `src/core/`）：
  - 只靠 `#pragma omp` 的循环：`lut_applicator.cpp:56-61`、`:82-87`；`color_converter.cpp:44-51`、`:71-78`；
    `photo_lut.h:46-56`、`:65-75`；`photo_effects.cpp:145-151`；`hdr_jpeg.cpp:322-328`
  - 完全串行的循环：`color_converter.cpp:423-426`；`photo_color.cpp:95-101`；`photo_color_grading.cpp:83-90`；
    `photo_tone_controls.cpp:84-90`；`photo_geometry.cpp:139-158`；`display_lens_correction.cpp:50-65`；
    `rendered_dng.cpp:590-599`
- 问题：各出货构建都关了核心 OpenMP，这些 `#pragma` 等于死代码。较新的阶段已改用 `parallelPixelRanges`，
  两套机制并存。v3 调色、清晰度与去雾、JPEG 输入都强制走 CPU，所以这些循环在常见编辑和导出路径上。
- 整改方向：统一迁到 `parallelPixelRanges`，删掉失效的 `#pragma`。这不改变"OpenMP 保持关闭"的决定。
- 验收：迁移前后逐位一致；测一次 CPU 全尺寸导出耗时。

### C10 降噪和两个 GPU 后端内部没有取消检查点

- 严重度：中｜确认程度：已读
- 位置：`src/core/eaw_denoise_impl.h:111-190`；`src/core/chroma_denoise.cpp:311-416`；`src/core/wavelet_denoise.cpp:794-804`；
  `src/gpu/metal_photo.mm:1076-1162`、`:1214-1221`；`src/gpu/d3d11_photo.cpp:231-233`；
  对照 `src/gpu/gles_photo.cpp:164`、`:170`、`:184`、`:190`、`:327-328`
- 问题：小波和色度降噪的分块循环不检查取消，取消要等整幅滤完才生效。`applyWaveletDenoise` 的通用捕获会把
  取消变成处理错误，现在靠调用方返回后补查一次（`src/ffi/sony2fuji_c.cpp:2423-2424`）才没出错。
  Metal 的分块循环逐块同步等待却不查取消；Metal 外层和 D3D11 的通用捕获将来一旦内部加了检查点，
  会把取消当成 GPU 失败。
- 整改方向：按块加检查点，并在通用捕获之前单独放行 `ProcessingCancelled`。
- 验收：`tests/processing_cancellation_tests.cpp:55-91` 目前没覆盖降噪阶段，补上。

### C11 LUT 文本解析慢，且全局只缓存一张

- 严重度：中｜确认程度：结构已读；耗时为推测
- 位置：`src/core/lut_parser.cpp:124-208`、`:308-325`；同样的单槽缓存 `src/core/dcp_look.cpp:65-84`、`src/core/hdr_look.cpp:35-44`
- 问题：65 格 LUT 有 27 万行、7 到 10 MB，每行建两个字符串流。缓存只留最后一张，切回刚看过的外观也要重新解析。
  解析期间持有全局锁，批量导出和预览用不同 LUT 时互相阻塞并反复重解析。
- 整改方向：换成 `from_chars` 或 `strtof` 逐行解析；缓存改成少量条目的最近使用表。

### C12 预览曝光匹配每次 RAW 解码都重开文件、全尺寸解码内嵌 JPEG

- 严重度：中到低｜确认程度：已读
- 位置：`src/core/preview_exposure.cpp:44-102`；`src/core/raw_processor.cpp:415-428`
- 问题：为了取 128×128 个亮度采样，每次都新建 LibRaw、把最大 6400 万像素的内嵌 JPEG 整幅解成 RGB（最多约 192 MB），
  结果不按文件缓存。
- 整改方向：按文件缓存采样，或用 libjpeg-turbo 的 1/8 缩放解码（`src/core/hdr_jpeg.cpp:128-131` 已有这种用法）。

### C13 HSL 取样快照让小波输出缓存来回失效

- 严重度：中到低｜确认程度：已读
- 位置：`src/ffi/sony2fuji_c.cpp:2741-2743`、`:2395-2406`、`:2431-2432`；`src/core/wavelet_cache.h:24-27`、`:32-41`
- 问题：快照临时把 GPU 模式改成关闭，缓存的匹配条件又要求模式相同，于是 Auto 的结果被清掉重算，
  下一次正常渲染再清一次。v2 和 v3 在两种模式下结果相同，这次失效纯属浪费。
- 整改方向：快照只读命中、不写回；或让关闭与 Auto 共用结果。

### C14 输出尺寸没有上限，图像尺寸用 `int` 相乘

- 严重度：中到低｜确认程度：`ImageData` 构造已复核，其余已读
- 位置：`src/ffi/sony2fuji_c.cpp:620-677`、`:699-704`、`:1314-1318`；`include/sony2fuji/common.h:24`
- 问题：目标尺寸计算不限制结果，`w*h` 超过 2^31 是有符号溢出，回绕成较小正数时缩放会越界写。
  现有客户端都有限幅（Mac 最大 65535），目前的表现是"整套渲染跑完才在最后失败"。
- 整改方向：请求校验阶段按像素预算拒绝；`ImageData` 改用 `size_t` 乘法。

### C15 AI 降噪结果在会话里常驻，加载时还有瞬时双份

- 严重度：中到低｜确认程度：已读
- 位置：`src/ai/ai_session.cpp:147-172`；`src/ai/ai_session.h:60`；`src/ffi/sony2fuji_c.cpp:1133-1139`
- 问题：解码后的修正数据约 16 字节每像素，不释放，与 RAW 缓存并存；格式转换时两份同时存在。
  换白平衡会换缓存键，这份常驻数据很少被复用。
- 整改方向：解码成功后释放，或只对小图保留；转换改为分块。

### C16 Mac 普通 AI 路径不校验 Core ML 是否真在 GPU 上跑

- 严重度：低到中｜确认程度：代码已读；Core ML 是否会把算子排到 CPU 待验证
- 位置：`src/ai/coreml_graph.mm:32-37`、`:83-93`、`:100-125`；`src/ai/ai_session.cpp:319-321`（仅 HDR 路径校验），对照 `:177-279`
- 问题：计算单元配置允许 CPU 和 GPU，可用性判断只确认存在 GPU 设备，普通准备流程不做放置校验，
  后端一律记为 "CoreML"。这是"AI 降噪只在 GPU 上跑"这条决定下的一个缺口；Windows 侧已禁用 CPU 回退。
- 整改方向：普通路径也做一次放置校验，或在后端名称里如实标注。

### C17 HDR 缩小用的是不带预滤波的双线性，且有三份实现

- 严重度：中到低｜确认程度：算法已读；画质影响为推断
- 位置：`src/core/hdr_rendering.cpp:233-263`；`src/core/hdr_resample.h:6-18`；`src/core/hdr_stream.cpp:74`
- 问题：每个输出像素只取 4 个源像素，缩小超过 2 倍时会漏采样，细纹理容易出摩尔纹和锯齿。
  对比之下 DNG 预览用面积平均（`src/core/rendered_dng.cpp:376-407`）。
- 整改方向：缩小时改面积平均，并合并成一个实现。按 `docs/color-contract.md` 评估是否需要处理版本。

### C18 HDR 流式导出每读一个像素都要查哈希表、过三层 `std::function`

- 严重度：中到低｜确认程度：已读；耗时为推测
- 位置：`src/core/hdr_stream.cpp:22-50`、`:63-76`
- 整改方向：记住上一次命中的块指针；采样器改成模板或按行批量读取。

### C19 libjpeg-turbo 在所有平台都关了 SIMD，没有写原因

- 严重度：中到低｜确认程度：配置已复核；提速幅度未测
- 位置：`cmake/raw-jpeg.cmake:14`
- 问题：影响 HDR JPEG 的编解码、DNG 的全尺寸 JPEG 预览、LibRaw 的有损 JPEG 解码。
- 整改方向：至少在 arm64 上打开，或补上关闭的理由。

### C20 Apple 的 8 位显示图像被完整解码两次

- 严重度：低到中｜确认程度：已读
- 位置：`src/platform/display_image.cpp:318-324`、`:336-354`
- 问题：先整图解码一次只为检查色彩空间和位深，随即丢弃，再走缩略图接口解一次。
- 整改方向：检查用的那次不要立即缓存，或直接复用。

### C21 GLES 和 D3D11 通用滤波每块重新分配缓冲，细节滤波多一份整幅拷贝

- 严重度：低到中｜确认程度：已读
- 位置：`src/gpu/compute_denoise.cpp:10-16`、`:24-48`、`:61-65`、`:135-147`；`src/gpu/d3d11_denoise.cpp:81`、`:112-113`
- 整改方向：按最大块尺寸复用缓冲；只开一个通道时跳过外层拷贝。Metal 版已是复用的写法，可参照。

### C22 依赖外部 RAW 的测试在缺素材时直接不注册，而不是标记为跳过

- 严重度：中到低｜确认程度：已读
- 位置：`CMakeLists.txt:753-755`、`:934-936`、`:1129-1131`、`:1164-1176`、`:1193-1206`
- 问题：CI 没有设置 `SONY2FUJI_TEST_RAW`，这些测试在 CI 里根本不存在，汇总里也看不出少跑了。
  入库的 RAW 只有一张 DJI DNG，Sony ARW 的解码、裁切补丁、高光回归只能靠本地跑。
- 整改方向：始终注册，缺素材时返回 77（`SKIP_RETURN_CODE` 目前全文件只用了 4 处）。

### C23 没有调用方的代码

- 严重度：低｜确认程度：已读（全仓搜索）
- 位置：
  - `src/core/noise_aware_sharpen.cpp`、`src/core/noise_aware_sharpen.h:18`；`CMakeLists.txt:163`、`:189-194`、`:516-562`。
    `applyNoiseAwareSharpen` 只被测试和探针使用，却带着专门的编译选项、Metal 实现和 6 个测试目标。
  - `include/sony2fuji/ffi/sony2fuji_c.h:851-855`；`src/ffi/sony2fuji_c.cpp:2823-2875`。
    `sony2fuji_compute_histogram` 在客户端、CLI、测试里都没有引用，且不校验缓冲大小和行距。
  - `sony2fuji_session_inspect_lens_metadata`（v1）、`sony2fuji_hdr_probe_camera_raw`、`sony2fuji_compile_hdr_camera_dcp`
    只有测试在用。
- 整改方向：删除，或移到实验目标；保留的导出函数补上与 `sony2fuji_analyze_image` 相同的校验。
  删除导出函数前按根目录 `AGENTS.md` 检查四个客户端的调用方。

### C24 核心源码被编译两遍，两段链接配置靠手工保持一致

- 严重度：低｜确认程度：已读
- 位置：`CMakeLists.txt:235-287` 对 `:290-352`；`RawLabWindows/native/CMakeLists.txt:44`
- 问题：静态库和动态库各自编一遍，两段约 50 行的设置已有细微差别（245 行与 310 行的框架列表）。
- 整改方向：用 OBJECT 库，或抽一个函数统一设置。

## 5. Mac

本节路径省略前缀 `RawLabMac/`。编辑记录见 X1，主线程算校验值见 X2，重复新建引擎见 X3，单张导出见 X4。

### M1 带增益图的 HDR 照片，画面取色始终报"预览已变化"

- 严重度：中｜确认程度：已复核（未运行）
- 位置：`Sources/Editor/Model/EditorModel+HSLTarget.swift:15`；`Sources/Editor/Model/EditorModel+HDR.swift:4-7`；
  `Sources/Editor/Model/EditorModel+Rendering.swift:88`；类型定义 `Sources/Presentation/MacNeutralReference.swift:3-20`
- 问题：渲染请求里的来源身份由 `referenceSource(file)` 生成，带 `hdrFingerprint`；`beginHSLTarget` 用不带指纹的
  `MacReferenceSource($0, raster:)` 去比较。对带增益图的 JPEG/HEIC（macOS 15 及以上，探测成功时指纹非空），
  两者永远不相等，直接走"预览已变化"返回。普通 JPEG 和相机 RAW 指纹为空，不受影响。
  取色功能早于指纹加入，后者没有同步这一处。
- 整改方向：这里改用 `referenceSource(file)`（配合 X2 的缓存，避免在这里再算一次校验值）。
- 验收：补一条用带增益图素材的取色测试。

### M2 缩略图刷新时，每张可见缩略图把整份记录文件解码 2 到 5 次

- 严重度：中｜确认程度：已读
- 位置：`Sources/Library/MacEditedPhotoPreviews.swift:52-63`、`:132-137`、`:159-169`、`:177-193`、`:203-237`；
  `Sources/Library/MacWorkspaceBrowser.swift:407`；`Sources/Editor/View/EditorView.swift:177-189`
- 问题：每个缩略图任务以 `previews.revision` 和 `isEditorBusy` 为标识，任一变化就重跑。一次编辑提交会连续触发四次变化。
  每次重跑都新建 `EditPersistence`（构造时解码一次）再读状态（又一次），已编辑的照片还要再建一次并核对两次。
  侧栏有几十张缩略图时，每松一次滑杆后台就做上百次整份解码，不卡界面但持续占 CPU。
- 整改方向：缩略图工作器复用同一份已解码记录（X1 第 2 步）；把多个刷新来源合并成一次。

### M3 对照用的中性参考帧总按整幅原生分辨率渲染，附带一张从不显示的蒙版，不计入缓存上限

- 严重度：中｜确认程度：流程已读；耗时与内存为推算
- 位置：`Sources/Editor/Model/EditorModel+Rendering.swift:140-161`、`:280`、`:298-300`；`Sources/Rendering/Engine.swift:86-105`、`:742-755`；
  `Sources/Editor/View/EditorView.swift:430-441`
- 问题：
  1. 每打开一张 SDR 照片，先做一次整幅中性渲染再做预览，首帧等待里包含这次整幅渲染。
  2. 几何或镜头非默认时，还要再做一张带几何的整幅中性帧，每次应用裁切、旋转、镜头校正后都重做。
  3. 每一帧都生成同尺寸的溢出蒙版，中性帧的蒙版在界面上从不显示。
  4. 两张整幅帧不在 `MacExactPreviewCache` 的 512 MB 预算内。按 6000 万像素推算，两帧加蒙版接近 1 GB。
- 说明：代码注释把它称为"既有的整幅基准"，是否保留需要你决定；它不在既有决定清单里。
- 整改方向：中性帧不生成蒙版；参考帧延后到第一次开对比或按住看原图时再做，或先按预览尺寸做。

### M4 批量导出窗口的单张预览不能取消也不合并，带 AI 降噪时会挡住后面的导出

- 严重度：低到中｜确认程度：已读
- 位置：`Sources/Export/BatchExportModel.swift:109`、`:244-258`、`:349-385`
- 问题：每点一张就往串行队列里排一次 1600 像素渲染，快速点多张会全部执行。带 AI 的条目先做准备，
  没有任何取消入口。关闭预览只改界面状态，后台任务照跑；此时点开始，导出排在那次 AI 准备后面，
  界面显示"正在导出"却没有进度。
- 整改方向：预览任务带可取消标记，新预览或关闭时取消旧的；开始导出前先取消并等待预览结束。

### M5 构建脚本：非发布构建不清理旧包，依赖本机特定 SDK 路径，没有 git 目录时失败

- 严重度：低到中｜确认程度：已读（未执行）
- 位置：`build.sh:79-80`、`:136-138`、`:168-186`、`:200`；`build-dependencies.sh:6`；`prepare-sparkle.sh:4`、`:10-14`；`build-env.sh:73`
- 问题：
  1. 非发布构建在已有的应用包上原地叠加。源码里删掉的 LUT、图标、翻译、许可文件会一直留在包里，
     而胶片列表是枚举目录得到的，旧 LUT 会出现在开发包里，包内检查也在这份包上跑。
  2. `build.sh` 检测到 `MacOSX26.5.sdk` 目录时静默改用它，依赖脚本用 `xcrun` 给出的 SDK，应用和依赖可能用不同 SDK。
  3. `prepare-sparkle.sh` 无条件调用 `git rev-parse`，从源码压缩包构建会失败；下载用固定的临时文件名，
     两个工作区同时构建会互相覆盖。
  4. 依赖只按目录是否存在判断是否已解压，解压中断后的半截目录会被当作完整。
- 整改方向：非发布构建也先建到临时目录再整体替换；SDK 选择集中到 `build-env.sh`；
  Sparkle 脚本复用 `build-env.sh` 的缓存目录逻辑和下载函数；解压完成后写标记文件。

### M6 测试脚本的组织与盲区

- 严重度：低到中｜确认程度：抽查约 12 个文件，其余为对 105 个脚本的批量统计
- 位置：`tests/edit-model.sh:8-12`；`tests/render-scheduling.sh:5-8`；`tests/test_native_isolation.py:8`；
  `Sources/Editor/Model/EditorModel.swift:352-356`
- 问题：
  1. 每个脚本自己列一长串源文件再整体编译，没有共用清单（见 R14）。
  2. 73 个脚本把 SDK 写死为 `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`，只有 3 个用 `xcrun` 兜底。
  3. 38 个脚本的目标系统写死 `macosx26.0`，而应用最低是 14.0，macOS 14 的降级分支在这些测试里永远走不到。
  4. 11 个脚本用 `mktemp` 后不清理。
  5. 隔离检查只要求三个目录参数，没有 `presetDirectory:`。17 个测试文件构造 `EditorModel` 时没传它，
     会落到用户真实的预设目录。目前属于守卫漏洞，没有发现已发生的污染。
  6. 盲区：M1 的取色场景、记录文件读不出时模型层的表现、单张导出失败后的残留文件。
- 做得好的一面：测试几乎都直接编译生产源码来测，靠匹配源码文本的脆弱断言基本不存在。
- 整改方向：抽一个公共脚本提供 SDK、目标版本、临时目录清理和按模块划分的源码清单；隔离检查补上第四个目录。

## 6. iOS 与 `Shared/`

编辑记录见 X1，校验值重复计算见 X2，每帧新建会话见 X3，批量日志见 X5，相机重列整卡见 X6。

### I1 批量 DNG 输出和相机原件只增不减，用户没有清理入口

- 严重度：高｜确认程度：放弃操作不清理、文件共享未开启已复核，其余已读
- 位置：`RawLab/RawLab/Core/Batch/Storage/BatchExportStorage.swift:74-79`、`:138-163`；
  `RawLab/RawLab/Core/Batch/Execution/BatchExport.swift:445-449`；`RawLab/RawLab/UI/Export/BatchExportView.swift:66-70`、`:224`；
  `RawLab/RawLab/Resources/Info.plist:17`；`RawLab/RawLab/Core/Camera/CameraOriginalStore.swift:165-537`、`:220-222`；
  `RawLab/RawLab/UI/Camera/IOSCameraWorkspace.swift:188-199`
- 问题：
  1. 批量导出的 DNG 写到 `Documents/Exports/<任务>/`，点完成、放弃、另存后都不删，全仓没有清理代码。
  2. 没有开启文件共享，这个目录在"文件"应用里不可见，用户看不到也删不掉，还会进系统备份。
  3. 相机导入的原件没有删除接口和界面，只能删应用。
  4. 相机清单涨到 32 MB 上限后所有写入都抛错，相机导入和联机拍摄整体不可用，没有恢复路径。
- 整改方向：批量 DNG 另存成功后删除本地副本，或提供"清理已导出文件"的入口；若想让用户在"文件"里直接取，
  就开启文件共享的两个配置项。相机原件提供删除入口和占用空间显示；清单裁剪已完成的任务。

### I2 导出 RAW 前为了取尺寸多做一次完整解包，桥接层绕过共享 C 接口

- 严重度：中｜确认程度：已复核
- 位置：`RawLab/RawLab/Support/RawMetadataBridge.mm:7-21`；`RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor.swift:429-436`、`:544-546`；
  `RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor+Helpers.swift:39`；代价依据 `lutools/src/core/raw_processor.cpp:145-171`、`:587-625`
- 问题：`rawlab_get_raw_dimensions` 调用 `RAWProcessor::loadFile`，把整张 RAW 解包只为返回宽高。
  单张全尺寸导出、批量每个 RAW 目标、DNG 导出都会先白解一次；指定长边导出时这个宽高根本用不到。
  这个桥接直接包含核心的内部头文件，不走共享 C 接口，和预编译的框架之间没有版本约束。
- 整改方向：改用只读元数据的接口（同一个类已有 `inspectFile`，最好由 C 接口提供），只在需要原生尺寸时才调用。

### I3 每次保存调整都触发最近照片整体重载

- 严重度：中｜确认程度：已读
- 位置：`RawLab/RawLab/UI/Editor/ContentView.swift:196-201`；`RawLab/RawLab/UI/Editor/ContentView+RecentPhotos.swift:22-32`；
  `RawLab/RawLab/Core/ViewModel/IO/RawEditorViewModel+PersistenceAndExport.swift:63`；
  `RawLab/RawLab/Core/Persistence/RecentPhotoStore.swift:107-117`；`RawLab/RawLab/UI/Library/RecentPhotosView.swift:101-103`、`:128-166`
- 问题：每次保存后，对最多 100 张最近照片逐张读取状态，每次都把整份记录文件读出并解码。
  缩略图任务的标识里带库的修订号，重载完成后所有可见缩略图再跑一遍。
- 整改方向：记录提供一次读取、批量取状态的接口（X1 第 2 步）；重载合并，或只更新当前照片那一行。

### I4 RAW 导入时重复解码；被取消的导入仍跑完整个流程

- 严重度：中｜确认程度：已读
- 位置：`RawLab/RawLab/Core/ViewModel/IO/RawEditorViewModel+IO.swift:47-82`（重点 `:53-64`）、`:149-383`、`:387-402`
- 问题：`buildRawPreviewBase` 先用可复用会话解码 RAW，紧接着的 `processBuffer` 会销毁这个会话，
  后面只能再解码一次。它生成的 `draftPreviewBuffer` 对 RAW 没有任何读者，这一步是纯浪费。
  后台导入没有任何取消检查，被取消的导入仍把全部渲染做完，并和新导入抢同一把会话锁。
- 整改方向：RAW 路径去掉这次 `processBuffer`；各阶段之间检查导入是否仍是当前的，过期就提前返回。

### I5 HDR 预览每一帧都无条件改写提示消息

- 严重度：中（只影响 HDR 编辑）｜确认程度：赋值已复核；弹窗表现待验证
- 位置：`RawLab/RawLab/Core/ViewModel/RawEditorViewModel+Rendering.swift:188`；`RawLab/RawLab/Core/ViewModel/RawEditorViewModel.swift:24-29`；
  `RawLab/RawLab/UI/Editor/ContentView.swift:296-318`
- 问题：资源齐全时每帧赋空值，会关掉正在显示的提示（如"已保存到照片。"），同时清掉诊断状态和重试入口。
  外观或相机配置缺失时，每一帧都重新弹出同一条警告，用户关一次弹一次。
- 整改方向：只在缺失状态变化时提示一次，不用预览帧清空其他来源的消息；缺失提示改成面板内的常驻说明。

### I6 相机导入记录每个缩略图都整文件校验，并占用相机命令队列

- 严重度：中｜确认程度：已读
- 位置：`RawLab/RawLab/Core/Camera/CameraOriginalStore.swift:246-277`；`RawLab/RawLab/Core/Camera/CameraWorkspaceBackend.swift:435-437`、`:265-273`；
  `RawLab/RawLab/UI/Camera/IOSCameraController.swift:339-364`；`RawLab/RawLab/UI/Camera/IOSCameraBrowser.swift:272-295`
- 问题：列表每一行出现时对整个原件算校验值后才解缩略图，缓存只留 64 张，滚回去还要再算。
  这些校验排在相机唯一的串行队列上，和联机拍摄的轮询、快门、参数设置同队列，滚动列表会拖慢拍摄响应。
- 整改方向：缩略图只做便宜的存在性检查，完整校验留给"打开编辑"；缩略图解码移出相机命令队列。

### I7 `ContentView` 是单体视图，任何状态变化都重算整个界面，重算路径里有文件访问和图片加载

- 严重度：中｜确认程度：结构已读；对帧率的影响为推测
- 位置：`RawLab/RawLab/UI/Editor/ContentView.swift:33-162`；`RawLab/RawLab/UI/Preview/ZoomablePhoto.swift:57-58`、`:134-143`、`:566-583`；
  `RawLab/RawLab/UI/Editor/ContentView+Panels.swift:34-55`；`RawLab/RawLab/UI/Panels/LookPanels.swift:11-15`、`:138`；
  `RawLab/RawLab/Core/ViewModel/RawEditorViewModel+LUT.swift:25-30`、`:137-142`；`Shared/Localization.swift:37-52`
- 问题：编辑器全部状态（107 个 `@State`）都挂在 `ContentView` 上。照片每个滚动或缩放事件、滑杆每一格都让整个界面重算。
  重算时工具栏做最多 5 次文件可读性检查，外观面板逐个检查所有外观文件，配方面板对 14 个配方重新从文件读图。
  `L10n.text` 每次调用都重新读设置、解析语言、查找语言包，界面有 760 多处调用。
- 整改方向：把视口状态、预览区、各面板拆成各自持有状态的子视图；外观可用性和配方图片在数据变化时算一次并缓存；
  `L10n` 缓存当前语言对应的语言包，语言切换时失效（这一项 Mac 同样受益）。

### I8 HDR 画布在主线程逐像素做色调映射，并持续以每秒 30 帧渲染

- 严重度：中偏低｜确认程度：结构已读；耗时为推测
- 位置：`Shared/Native/HDRCanvas.swift:64-109`、`:116-134`；`Shared/Native/HDRPresentation.swift:50-70`；`Shared/HDRDisplay.swift:18-23`、`:63-113`
- 问题：绘制回调在主线程用标量循环整幅计算再上传纹理。屏幕动态范围余量用原始值做相等比较，
  系统渐变期间每帧都不相等、每帧整幅重算。画面不变时也每秒 30 次提交。这是 iOS 和 Mac 共用的代码。
- 整改方向：色调映射放进片元着色器，只上传一次线性纹理，余量作为参数传入；画面无变化时暂停绘制。
  按"Mac 是基准"的约定，先在 Mac 上改并验证。

### I9 普通图片整幅解码后常驻内存，导出时再解一份

- 严重度：中偏低｜确认程度：占用结构已读；是否会被系统因内存终止待验证
- 位置：`RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor.swift:605-632`；`RawLab/RawLab/Core/ViewModel/IO/RawEditorViewModel+IO.swift:88-89`、`:322`；
  `RawLab/RawLab/Core/ViewModel/RawEditorViewModel+Rendering.swift:276-284`、`:336`；
  `RawLab/RawLab/Core/ViewModel/IO/RawEditorViewModel+PersistenceAndExport.swift:216`、`:283`
- 问题：非 HDR 的普通图片忽略预览长边，总是整幅解码并在整个编辑期间保留（4800 万像素约 190 MB），
  每个预览帧都把整幅缓冲交给核心。导出时不复用它，又解一份，加上全尺寸输出，峰值约三份。
- 说明：上一轮架构优化里有"iOS 普通图片导出复用 `draftBuffer`"的改动，动手前先核对当前代码与那次改动的关系。
- 整改方向：导出时复用或先释放 `draftBuffer`；预览用一份按视口上限缩小的缓冲。

### I10 调整粘贴预检对每个目标整幅解码

- 严重度：低到中｜确认程度：已读
- 位置：`RawLab/RawLab/Core/ViewModel/RawEditorViewModel+AdjustmentTransfer.swift:13-18`、`:53`、`:96-98`、`:118-135`
- 问题：对每个普通图片目标整幅解码只为确认能读，结果丢弃，镜头校验里再解一次；对每个 RAW 目标新建处理器
  完整解码一次取白平衡。外观和配方是否可读在主线程按照片重复检查，而结果与照片无关。
- 整改方向：预检改用只读文件头的探测；外观可用性算一次复用。

### I11 死代码和留在正式代码里的测试开关

- 严重度：低｜确认程度：已读（全仓搜索）
- 位置：`RawLab/RawLab/Core/ViewModel/IO/RawEditorViewModel+PersistenceAndExport.swift:304-401`；
  `RawLab/RawLab/Core/ViewModel/IO/RawEditorViewModel+IOHelpers.swift:3-19`；`RawLab/RawLab/Core/ViewModel/RawEditorViewModel.swift:224-225`、`:231-232`；
  `RawLab/RawLab/UI/Editor/ContentView.swift:59`、`:544-554`；`RawLab/RawLab/App/RawLabApp.swift:14`；
  `RawLab/RawLab/Core/Models/RawSettings.swift:653-656`；`Shared/UsageAnalytics.swift:124`、`:189`
- 问题：`runBundledSampleSmokeTest` 依赖包内的 `sample.ARW`，工程里没有这个文件，也没有脚本设置对应环境变量，
  约 100 行代码走不到。`-RawLab.testBusyEditor` 启动参数在正式代码里直接生效。`rawLUTID`、`rawLUTApplied` 只写不读。
  `UsageAnalytics` 里的启动事件会被传输层丢弃，是多余的。
- 整改方向：删除冒烟测试整条链路和只写不读的状态；测试开关放进 `#if DEBUG`。

## 7. Android

本节用两个路径前缀：`J/` 指 `RawLabAndroid/app/src/main/java/com/rawlab/android/`，`N/` 指 `RawLabAndroid/app/src/main/cpp/`。
编辑记录见 X1，批量日志见 X5，相机重列整卡见 X6。

### A1 相机导入记录每次加载都重算所有历史照片的校验值，且每次启动应用都触发

- 严重度：高｜确认程度：加载路径已复核，其余已读；耗时未测
- 位置：`J/camera/CameraImportStore.kt:128-134`、`:158-191`、`:337-339`；`J/camera/CameraImportViewModel.kt:141-150`、`:513`、`:567`、`:621`；
  `J/camera/CameraTetherController.kt:207`、`:260`；`J/MainActivity.kt:72`、`:80`
- 问题：`load()` 对每个任务（含已完成的）逐张整文件算 SHA-256 并重写日志，任务日志从不删除，
  所以读取量等于历史上导入过的全部照片的总大小。`CameraImportViewModel` 在首次组合时创建并立即加载，
  加载期间扫描和连接都被挡住。联机拍摄开始和结束各跑一遍，从联机页打开刚拍的照片会连跑两遍。
- 整改方向：日常核对改用大小、修改时间、媒体库版本号等轻量信息，只在真正使用某张照片时算校验值；
  已完成且核对过的任务不再反复恢复；清理或归档旧任务日志。
- 验收：补一条加载耗时不随历史规模线性增长的测试。

### A2 批量导出和系统分享在应用私有目录留下无法回收的大文件

- 严重度：高｜确认程度：已读
- 位置：`J/batch/BatchExportModel.kt:137-160`、`:217-218`、`:272-289`、`:297-307`；`J/editor/EditorBatches.kt:93`；
  `J/batch/journal/BatchJournal.kt:138-145`；`J/batch/BatchSelection.kt:110-131`；`J/batch/publish/BatchOutputPublisher.kt:39`；
  `J/photo/WorkingCopyCleanup.kt:9-27`；`J/photo/SystemPhotoStore.kt:29-76`
- 问题（三处都没有任何启动清理能覆盖）：
  1. 打开批量页就把源片和每张目标整份复制进 `filesDir/RawLab/BatchJobs/<任务>/`，日志到点"开始"才写。
     此前进程被杀或页面被清理，副本成为孤儿，没有代码扫描无日志的目录。
  2. 每张照片的渲染结果先写到 `filesDir/render-*`，进程在渲染或发布途中被杀就永久残留（单张 DNG 可达数百 MB）。
  3. 经"打开方式"或"分享"进来的照片整份存入 `filesDir/system-photos/`，没有删除或淘汰逻辑，也没有管理入口。
- 整改方向：启动时删除没有对应日志的任务目录；渲染临时文件放进任务目录或缓存目录并纳入启动清理；
  给 `system-photos` 加"无编辑记录且长期未用即回收"的规则或清理入口。

### A3 HDR 外观导入期间按返回键，编辑器永久停在"忙"状态

- 严重度：中｜确认程度：逻辑已复核；界面时序待验证
- 位置：`J/editor/EditorViewModel.kt:691-712`（重点 `:703`）、`:943-962`；`J/editor/ui/EditorScreen.kt:145-150`、`:240`、`:247`；
  `J/editor/EditorState.kt:85`、`:95-98`
- 问题：`applyHDRLook` 把 `operation` 设为 `IMPORT_LOOK`，后台完成后若修订号变了就直接返回，不复位。
  返回键的处理不受 `controlsEnabled` 限制，会走 `discardDraft()` 使 `draftRevision` 加一。
  之后 `controlsEnabled` 恒为假，不能调参、换图、导出，只能重启应用。从云端选文件时这个窗口并不短。
- 整改方向：过期返回前把 `operation` 复位（只要它仍是本次设置的值）；或让 `discardDraft` 在 `operation` 非空闲时拒绝。
- 验收：目前没有任何测试覆盖 `applyHDRSilver` 和 `finishHDRLookImport`，补上这条时序。

### A4 普通（非 HDR）导出无法中途取消

- 严重度：中｜确认程度：JNI 一侧已复核；核心对导出是否响应取消回调待核对
- 位置：`N/rawlab_jni.cpp:1469`；`J/engine/NativeProcessor.kt:181-210`；`J/batch/BatchExportModel.kt:219-222`、`:264-270`；
  `J/batch/publish/BatchOutputPublisher.kt:74-75`
- 问题：JNI 在有输出文件时传 `-1`，不注册取消回调，`export()` 也不传取消代次。批量"停止"和退到后台
  只能等当前这张渲完；后台继续满负荷渲染会增加被系统杀掉的概率，并触发 A2 的残留。HDR 路径是可取消的，两者不一致。
- 注意：核心的 `sony2fuji_process` 目前只在"预览到缓冲"时启用取消（`lutools/src/ffi/sony2fuji_c.cpp:2688-2692`），
  所以这条需要核心和 JNI 一起改，并检查其他三端的导出是否有同样限制。
- 整改方向：导出也注册取消回调，取消后删除临时输出并把该行标为已取消。

### A5 多文件流程里重复做整文件复制、校验和完整解码，缺少空间预检

- 严重度：中｜确认程度：已读
- 位置：`J/batch/BatchExportModel.kt:272-289`；`J/editor/EditorAdjustmentTransfer.kt:42-127`（重点 `:58`、`:69-80`）；
  `J/editor/EditorViewModel.kt:1433-1438`；`J/editor/EditorCollections.kt:81-115`；`J/photo/WorkingCopy.kt:11-47`
- 问题：批量每加一张目标都整份复制并新建处理器做一次预览校验，导出时再解码一遍。粘贴或同步到 N 张要同时保留
  N 份完整副本直到面板关闭。复制都不传预期大小，写到一半才发现空间不足。准备和添加在整个循环期间一直持有
  存储的锁，编辑器渲染线程同期无法工作。
- 整改方向：校验改用只读文件头的轻量接口；校验值算一次后随条目传递；预检完成即释放副本；
  复制前按总大小做空间预检；锁按单个目标获取。

### A6 预览像素从核心到屏幕要拷三次，HDR 预览的浮点平面整块放在 Java 堆

- 严重度：中｜确认程度：拷贝次数已读；对卡顿和内存的实际影响未测
- 位置：`N/rawlab_jni.cpp:1563-1569`、`:1264-1289`；`J/engine/NativeProcessor.kt:64-66`；`J/editor/render/EditorRenderer.kt:386-396`；
  `J/editor/render/HDRBitmapAdapter.kt:29-47`
- 问题：每帧预览新分配整帧字节数组再拷进新位图，拖动滑尺时持续制造垃圾。同文件的 `nativeSdrBitmap`
  已示范了直接写位图的做法。HDR 预览每帧取两块浮点数组（1600 边长时各约 20 MB），对照帧和结果帧都要。
- 整改方向：主预览改为 JNI 直接写入调用方传入的位图；`nativePlane` 省掉中间拷贝；HDR 平面考虑放到 Java 堆外。

### A7 正式包没有启用代码压缩，却引入了完整的扩展图标库

- 严重度：中｜确认程度：配置已复核；体积影响未测
- 位置：`RawLabAndroid/app/build.gradle.kts:137-175`、`:199`
- 问题：没有任何正式构建类型的配置，默认不压缩、不裁剪资源；`material-icons-extended` 整库进包，还带 `x86_64` 原生库。
  也没有保留规则文件，将来开压缩时 JNI 按名字查找的类（`NativeFrame`、`NativeProcessingException`、
  `HDRProcessingException`、`DcpCompilationException`）没有保护。
- 整改方向：启用压缩并补上述类的保留规则，或把用到的图标改为按需引入；评估是否给真机单独出只含 `arm64-v8a` 的包。

### A8 相册里已编辑照片的缩略图复用了编辑器渲染器，每张多渲一张参考图并整文件复制原片

- 严重度：低｜确认程度：已读
- 位置：`J/photo/EditedPhotoPreviews.kt:56-83`；`J/editor/render/EditorRenderer.kt:223-230`
- 问题：渲染器对新照片总是先渲一张 1600 边长的中性参考图（编辑器对比用），缩略图只用 512 的结果图。
- 整改方向：给缩略图单独一条只渲结果图的路径。

### A9 蓝牙一断开就判定整次连接失败，不区分阶段；开启 Wi-Fi 阶段没有超时

- 严重度：低｜确认程度：代码路径已读；触发频率待真机验证
- 位置：`J/camera/SonyCameraConnection.kt:188-189`、`:597`、`:725-736`
- 问题：进入网络传输阶段后蓝牙已不再需要，但它断开仍会判失败并注销网络请求，Wi-Fi 传输随之中断。
  三分钟的蓝牙超时只处理配对和蓝牙两个阶段；`startScan()` 的返回值被忽略。
- 整改方向：到达网络阶段后主动关闭蓝牙连接或忽略其断开；给开启 Wi-Fi 阶段加超时；扫描被系统限流时给提示。

### A10 编辑历史的几个字段被后台提交线程和主线程无同步地读写

- 严重度：低｜确认程度：无同步读写已读；触发窗口只有毫秒级，待构造时序验证
- 位置：`J/editor/EditorAdjustmentHistory.kt:15-18`、`:23-29`、`:86-104`；`J/editor/EditorViewModel.kt:406`、`:442`、`:1846-1858`
- 问题：`commit()` 在后台线程读写 `loaded`，主线程换图时可能插在中间，之后 `loaded` 指向旧照片，
  新照片每次保存都报"原片已更改"，只能重新打开。接受外观时会等提交结束，换图时不会；
  退到后台时即使换图正在进行也会保存旧照片。
- 整改方向：这些字段统一在一个线程赋值，或换图时同样等待提交结束。

## 8. Windows

本节路径省略前缀 `RawLabWindows/`。编辑记录见 X1，每帧读两遍源文件和重算 LUT 校验值见 X2，
粘贴预检新建引擎见 X3，批量日志见 X5。

### W1 手动安装包用户永远收不到新版本提示

- 严重度：高｜确认程度：已复核；线上发布页的实际文件名没有联网核对，依据是仓库自己的打包脚本和发布文档
- 位置：`UpdateRelease.cs:20-22`；`build.ps1:237`；`docs/process/desktop-release.md:116`；`tests/updates/Program.cs:10`
- 问题：`UpdateRelease.Parse` 要求发布文件名以 `win-x64.zip` 结尾，而打包产物叫 `RawLab-Windows-<版本>-x64.zip`，
  匹配不上，结果永远是"未发现适用于 Windows 的新版本"。ZIP 版和未配置更新信任的构建都走这条检查
  （`MainWindow.xaml.cs:234`、`MainWindow/SoftwareUpdates.cs:57-58`），这批用户恰好只能手动更新。
  测试数据仍用旧名字 `RawLab-Windows-0.5.0-win-x64.zip`，所以没拦住。
- 整改方向：同时接受两种命名，或改为只比较版本号；测试数据换成当前真实文件名。
- 验收：用 v0.10.0 发布页的真实返回内容做一条测试。

### W2 自动更新遇到一次下载失败或异常退出后静默停摆

- 严重度：中｜确认程度：状态机已读；"开着应用关机不走正常退出流程"是按 WPF 默认行为推断，待验证
- 位置：`Updates/DesktopUpdateController.cs:142-143`、`:178-179`；`Updates/UpdateState.cs:97-105`；
  `MainWindow/SoftwareUpdates.cs:57-60`；`MainWindow/InteractionExport.cs:189-191`
- 问题：自动检查遇到"失败且失败阶段不是检查"就直接返回。后台下载中途断网、下载中进程被杀或崩溃，
  都会进入这个状态。此后自动检查不再运行，主窗口只在"有可用更新"时显示提示，用户看不到任何迹象，
  必须自己打开"软件更新"点重试。开了"自动下载并在退出时安装"的用户最容易中招。
- 整改方向：下载失败、校验失败和"被中断"也按天自动重试；失败状态在主窗口给出提示。
- 验收：补"失败之后下一天是否还会自动检查"的测试。

### W3 更新状态文件一次写盘失败就锁住整个编辑区

- 严重度：中｜确认程度：已读；触发概率未验证
- 位置：`Updates/UpdateStore.cs:138-149`；`Updates/DesktopUpdateController.cs:31`、`:43`、`:278-288`；
  `MainWindow/SoftwareUpdates.cs:62-63`；`Updates/SoftwareUpdateWindow.cs:65-67`；对照 `EditPersistence.cs:110-149`
- 问题：`AtomicJson.Write` 针对"替换正被打开的文件会短暂失败"做了 2 秒重试，`UpdateStore.WriteAtomic` 没有。
  保存一失败就设置存储错误，编辑区被禁用，本次会话无法修复，界面提示"请保留全部文件并联系支持"，只能重启。
  每日自动检查会写两次；更新待安装期间每秒轮询，状态每变一次就写一次。
- 同类问题：原子写盘至少还有五处各写各的，耐久和重试策略互不相同：
  `LookLibrary.cs:373-391`、`UpdateChecker.cs:94-109`、`FileLibrary.cs:175`、`UsageAnalytics.cs:358-371`、
  `EditedPhotoPreviewCache.cs:56-67`。
- 整改方向：统一走一个带重试的原子写；运行期的保存失败只停用更新功能，不锁编辑。

### W4 没有任何未处理异常的兜底，个别异步入口会直接崩溃

- 严重度：中｜确认程度：缺少兜底已读（汇总时的复核命令没跑成功）；具体崩溃触发为推测，需用内嵌预览损坏的样片验证
- 位置：`Program.cs:25-31`；`App.xaml.cs:51-99`；`MainWindow/Rendering.cs:90-108`；`RenderEngine.cs:622-627`、`:640`
- 问题：全工程没有全局异常处理，却有 31 个 `async void`。`Main` 只捕获两种异常，其他类型直接崩溃且不留日志。
  `PumpEmbedded` 只过滤五种异常，`ReadEmbeddedPreview` 内部只捕获三种，内嵌 JPEG 损坏时可能抛出的异常两层都接不住，
  打开这张 RAW 就会崩溃。`App.OnStartup` 是 `async void` 且没有 try/catch，启动阶段的异常会无提示崩溃。
- 整改方向：加全局兜底，写本地崩溃日志并提示；`PumpEmbedded` 改为全捕获，预览失败只降级；启动失败显示原因。

### W5 HDR 预览每帧在托管层做多遍逐像素标量转换

- 严重度：中｜确认程度：已读；耗时为估算
- 位置：`RenderEngine.cs:156`、`:368-373`、`:379-381`、`:464`；`HDRDisplay.cs:13`、`:22-33`、`:46-54`、`:56-73`、`:75-80`、`:82-107`、`:109-136`
- 问题：每帧先把两块浮点缓冲逐元素拷进托管数组并逐元素检查，再分别为统计和位图各做一遍每通道 `MathF.Pow`
  的 sRGB 编码。`SDRBitmap` 是属性，每次访问都重新编码整张图。HDR 容器在 SDR 模式下编辑、HSL 取样、
  自动曝光，每次都重新拷贝并编码整个源。按 2000 像素预览估算，每帧约 1600 万次 `Pow`。
- 整改方向：sRGB 编码只做一次，位图和统计共用；改用查表或向量化；转换结果挂在源缓存条目上。

### W6 界面线程的高频路径里有同步文件读取，`LayoutUpdated` 上挂了全局回调

- 严重度：中（本地固态盘上不明显，网络盘上明显）｜确认程度：已读
- 位置：`MainWindow.HDR.cs:23`、`:61-89`；`MainWindow.Viewing.cs:32-37`、`:114-117`；`PhotoCanvas.cs:180`；
  `WindowsFileIdentity.cs:45-56`；`Rendering/HDR/Surface.cs:50`、`:77-81`
- 问题：`ReferenceCurrent` 每次都打开原片读取文件身份。开启对比或"查看调整前"后，它在每次 `LayoutUpdated`
  和每次平移缩放时都被调用，等于每次布局、每次鼠标移动都在界面线程开一次文件。
  即使不在 HDR 编辑，`LayoutUpdated` 回调每次也要分配数组并做两次原生调用。
- 整改方向：文件身份在打开照片或文件变化事件时更新并缓存；HDR 呈现刷新只在相关状态变化时调用。

### W7 安装器启动前的校验失败，被当成"安装到一半"处理

- 严重度：低到中｜确认程度：已读；这种保守处理有测试固定，属于有意设计的边界，改之前需要你确认
- 位置：`Updates/VelopackUpdateAdapter.cs:83-91`；`Updates/DesktopUpdateController.cs:42`、`:93-94`、`:252-259`；
  `tests/updates-sdk/ControllerChecks.cs:147-155`
- 问题：`Install` 的前四步（元数据核对、描述符过期检查、包重新校验、签名校验）都在真正启动安装器之前，
  但此时阶段已记为"安装中"。这些步骤失败后会当场锁编辑，下次启动进入"更新恢复"窗口，
  该版本还被写入跳过列表并关闭自动安装。常见诱因是安装包被杀毒软件隔离，或应用开着跨过了描述符有效期。
- 整改方向：把这四步挪到记录"安装中"之前；只有安装器已启动之后的失败才要求恢复。

### W8 `HDRSourceCache` 在全局锁里做解码

- 严重度：低｜确认程度：已读
- 位置：`HDRSourceCache.cs:43-61`、`:66`；`App.xaml.cs:53`；Apple 端同类写法 `Shared/Native/HDRImage.swift:397-400`
- 问题：持着全局锁解码可能耗时数秒，主预览、缩略图、自动曝光、批量检查共用这把锁，连释放也要等。
  后台给别的照片解码时，主窗口的 HDR 预览会被挡住。Apple 端的 `HDRSourceCache.shared` 也是解码期间一直持锁，
  而且别的文件的预览请求会清空编辑器当前照片的缓存。
- 整改方向：锁内只做查表和占位，解码放到锁外。

### W9 主预览没有用上已有的协作取消；取消状态码的处理不一致

- 严重度：低｜确认程度：已读
- 位置：`MainWindow/Rendering.cs:155-176`；`Adjustments.cs:420-431`；`RenderEngine.cs:72-81`、`:114`、`:298-301`；
  `RenderEngine.AIDenoise.cs:68`
- 问题：核心和引擎都支持预览取消，缩略图在用，主窗口没用，过期的精确预览必须跑完下一帧才开始。
  普通渲染路径没把状态 7 转成取消异常，会变成"照片处理失败"；目前靠调用方的请求号挡住，没有可见问题。
- 整改方向：主预览为每个任务挂取消令牌，新任务提交时取消旧的非交互预览；统一映射状态 7。

### W10 临时文件和目录的清理缺口

- 严重度：低｜确认程度：已读
- 位置：`RumUsageAnalyticsTransport.cs:67-68`、`:184-187`；`UsageAnalytics.cs:234-242`；`MainWindow/InteractionExport.cs:162`、`:185`；
  `LUTCompatibilityPreview.cs:45`、`:121`
- 问题：统计 SDK 每次启动在系统临时目录新建随机名目录，退出等待超时（离线时 3 秒就放弃）或崩溃都会留下，
  启动时不清扫，上次没发出去的缓存也不会被重用。单张导出的临时文件放在用户选的输出目录，
  进程被杀后留在那里。LUT 预览的临时目录只在正常释放时删。
- 整改方向：启动时清扫本应用前缀的过期临时目录；统计缓存改用固定目录。

## 9. 仓库、CI 与跨端契约

### R1 外部仓库的 PR 可以在自托管的物理机上执行代码

- 严重度：高（有前提）｜确认程度：工作流没有来源防护已复核；仓库是否公开、外部 PR 审批是否为默认值待验证
- 位置：`.github/workflows/ci.yml:4-6`、`:120`、`:530`；`scripts/ci/affected_platforms.py:48-50`、`:66-69`、`:171-175`；
  对照 `.github/workflows/pr-cache-cleanup.yml:16`；`scripts/ci/test_workflow.py:493`；`docs/process/ci.md:296-299`、`:420-425`
- 问题：任何非草稿 PR 只要改到共享或 Apple 相关文件，就会在物理 Mac 上执行 PR 里的 `scripts/ci/apple-models.sh`。
  外部仓库把分支命名为 `hotfix/x` 还会被当成热修复，触发全平台冷构建并用到专用 Windows 机。
  `ci.md` 自己写明这些机器只能跑可信代码。清理工作流判断了来源，主工作流没有。
- 第一步：先在 GitHub 仓库设置里确认是否对所有外部贡献者开启了"运行前审批"。这一步不需要改代码。
- 整改方向：平台选择逻辑里对来源不是本仓库的 PR 改走托管机，或跳过自托管任务；
  "发布、热修复"的判定只对本仓库分支生效；补一条策略测试。

### R2 Apple 两端"代码用到的文案键必须在词表里"的检查不在 CI 里，而且已经漏键

- 严重度：中｜确认程度：抽查的 4 个键已复核在英文词表里查不到；其余为静态比对结果，没有运行该测试本身
- 位置：`.github/workflows/ci.yml:101`；`tests/test_localization.py:28-29`、`:233`、`:288-299`；`RawLabMac/tests/localization.sh`
- 已漏的键：
  - Mac：`RawLabMac/Sources/Looks/LUTCompatibilityDialog.swift:134`（"确定"）
  - iOS：`RawLab/RawLab/UI/Editor/ContentView+Panels.swift:90`（"直方图"）；
    `RawLab/RawLab/UI/EditorState/EditorLayout.swift:168`（"定向调整"）、`:171`（"直方图"）；
    `RawLab/RawLab/UI/Camera/IOSCameraTether.swift:92`、`:98`、`:183`（"上一张""下一张""最近照片"）；
    `RawLab/RawLab/UI/EditorState/EditorDrafts.swift:101` 及同文件另一处（草稿保存、恢复失败提示）
- 问题：`LocalizationTests` 整个类依赖 macOS 的 `plutil`，没有任何 CI 入口。缺键时界面直接显示中文原文。
  涉及的 iOS 文件最近改于 2026-11-10，晚于 v0.10.0，会进下一版。Windows 有静态键检查，Android 缺键会编译失败，
  只有 Apple 两端是空档。`docs/process/localization.md:64` 推荐的整文件测试命令现在应当会失败。
- 整改方向：先按"Mac 是基准"补齐这些键；再把词表读取改用 `scripts/localization/formats.py` 里已有的纯 Python 解析，
  让整个类在 Linux 契约任务里跑。

### R3 调整参数的范围、默认值、步长没有单一来源，共享测试向量只覆盖少数字段

- 严重度：中｜确认程度：已读（覆盖数为脚本统计）
- 位置：Mac `RawLabMac/Sources/Adjustments/AdjustmentTypes.swift:588-610`；iOS `RawLab/RawLab/Core/Models/AdjustmentKind.swift:100-158`、
  `RawLab/RawLab/Core/Models/RawSettings.swift:56-63`、`:307-309`；
  Android `RawLabAndroid/app/src/main/java/com/rawlab/android/settings/EditSettings.kt:68-82`、`:187-200`；
  Windows `RawLabWindows/Adjustments.cs:50-55`、`RawLabWindows/PhotoEffectsSettings.cs:35-44`；
  交换格式的三份字段表 `Shared/AdjustmentTransfer.swift:119-138`、Android `.../adjustments/AdjustmentField.kt`、
  `RawLabWindows/AdjustmentPayload.cs`；共享向量 `Shared/fixtures/adjustment-transfer-v1.json`
- 现状：四端的范围和默认值目前一致，三份字段表的 71 个非 HDR 键完全一致，处理版本和配方版本标识也一致。
- 问题：这些一致靠人手同步。共享向量（四端快速测试都读）里出现过的字段键只有 23 个，字段表共 81 个。
  暗角与颗粒 8 个、几何与镜头 12 个、锐化、饱和度、阴影、曝光模式、HDR 字段 8 个完全没有向量，R7 正落在这个空档里。
- 整改方向：给每个字段至少补一条"合法边界、非法值、小数值"向量；或把范围、默认值、步长整理成一份机器可读清单，
  由契约任务校验各端表格。

### R4 版本号分散在四个入库文件，桌面发布时又由外部参数另行注入，没有一致性校验

- 严重度：中｜确认程度：分散与无校验已读；后果为推测
- 位置：`RawLabMac/Info.plist:15-16`；`RawLab/RawLab/Resources/Info.plist:13-16`；`RawLabAndroid/app/build.gradle.kts:145-146`；
  `RawLabWindows/RawLabWindows.csproj:13-15`；`scripts/release/macos_config.py:18-21`、`:44`；`RawLabMac/release-config.sh:4-5`；
  `RawLabWindows/build.ps1:5`、`:14`、`:135`
- 问题：当前四端都是 0.10.0 / 19，没有走样。但没有检查保证四个文件互相一致、发布参数等于入库值、二者等于标签。
- 整改方向：契约任务里加一条比对四处版本和构建号的测试；发布脚本拒绝"传入版本不等于入库版本"。

### R5 同一分支上手动触发的验证会互相取消（已知）

- 严重度：中｜确认程度：已复核
- 位置：`.github/workflows/ci.yml:25-28`；`scripts/ci/test_workflow.py:55-57`；`docs/process/ci.md:59-60`、`:250-252`
- 问题：并发分组只含事件名和分支，不含平台和检查组。按平台分别手动触发时，后一次会取消前一次。
- 整改方向：手动触发时把两个输入加进分组，同步改策略测试和 `ci.md`。

### R6 Windows 原生门禁按"允许名单"挑核心测试，新加的测试默认不在 Windows 上跑

- 严重度：中｜确认程度：名单方式已读；名单外有多少测试能在 Windows 上通过为推测
- 位置：`.github/workflows/ci.yml:396-397`；对照 macOS 的排除名单 `:220-223`；`docs/process/ci.md:225-231`
- 问题：核心登记的测试约 130 多个，Windows 即使在发布前的完整门禁里也只跑 23 个名字加 `dualdn_.*`。
  曲线、颜色分级、效果、HSL、几何、HDR 等都不在名单里。名单是有意选择的，缺陷在于没有机制要求新测试被归类。
- 整改方向：改成"排除名单，每项写原因"；或加一条策略测试，把 `ctest -N` 的结果与"允许加明确排除"两份名单对账，
  出现未归类的测试就失败。

### R7 暗角、颗粒等参数的精度分成桌面和移动两派，对小数值的处理四端各不相同

- 严重度：低｜确认程度：已读；移动端步长较粗是否有意为之没找到书面决定
- 位置：Mac 取 0.1 `RawLabMac/Sources/Adjustments/Adjustments.swift:214`；Windows 取 0.1 `RawLabWindows/Adjustments.cs:344`、
  `RawLabWindows/PhotoEffectsSettings.cs:28`；iOS 取整 `RawLab/RawLab/Core/Models/RawSettings.swift:128-131`、`:224`，
  粘贴遇小数拒收 `RawLab/RawLab/Core/Models/IOSAdjustmentTransfer.swift:140-143`；
  Android 控件取整 `.../settings/EditSettings.kt:224-227`，粘贴接受小数 `.../adjustments/AdjustmentTransferValues.kt:118-122`；
  字段目录只写范围不写精度 `docs/design/editing-iteration/field-catalog.md:82-89`
- 问题：同一个字段，Mac 和 Windows 能产生 12.3，iOS 会拒收，Android 会原样收下。目前调整数据不跨设备交换，
  实际影响只是各端滑杆精度不同；但"同一份交换格式"的含义已经分叉，以后做跨设备预设会直接出错。
- 整改方向：在字段目录里写明每个字段的精度，并规定收到更细的值是取整还是拒绝；配合 R3 补向量。

### R8 PR 改目标分支不会重新跑检查

- 严重度：低｜确认程度：触发类型已读；"改目标分支只产生 `edited` 事件"是依据 GitHub 行为的判断，未实测
- 位置：`.github/workflows/ci.yml:5`；`scripts/ci/affected_platforms.py:48-50`、`:61`
- 问题：一个指向 `development`、只跑过模型测试的 PR，改指 `main` 或 `release/**` 后沿用旧结果，
  绕过发布、热修复的完整冷构建门禁。
- 整改方向：触发类型加 `edited`，选择逻辑只对目标分支变化做出反应。

### R9 三组测试没有任何 CI 入口

- 严重度：低｜确认程度：已读
- 位置：`scripts/release/tests/test_release.py`；`scripts/rum/test_embed_ios.py`；`tools/camera-transfer/README.md:114-115`；
  `.github/workflows/ci.yml:99`
- 整改方向：前两组加进契约任务或 Mac 模型测试。相机传输工具若仍是实验性质可不加，但应写明。

### R10 `.gitignore` 把 `/reviews`、`/release-artifacts` 整个忽略，但 30 个文件仍在库里

- 严重度：低｜确认程度：已复核
- 位置：`.gitignore:74`、`:76`；`reviews/` 24 个文件；`release-artifacts/windows/2026-10-08/` 6 个文件
- 问题：新文件被无声忽略，旧文件继续随仓库分发。`reviews/` 是单次改动的自评，按 `AGENTS.md` 应写进 PR 说明。
  另外 `reviews/self-main-20260927-1115.md` 与 `docs/archive/reviews/` 下的同名文件内容不同，两份并存。
- 整改方向：要么移出跟踪，要么把仍有价值的移到 `docs/archive/` 并删掉这两条忽略规则。

### R11 各端目录里留着十几份 v0.8 的单次验证和实现记录，迭代总账也没归档

- 严重度：低｜确认程度：抽读 5 份，其余按文件名判断
- 位置：`RawLabWindows/VERIFICATION-v08.md`、`IMPLEMENTATION-v08.md`、`VERIFICATION-agent-v08.md`、`IMPLEMENTATION-agent-v08.md`、
  `verification.md`、`performance.md`；`RawLabMac/verification-native-v08-2026-10-15.md`；
  `RawLabAndroid/` 根部 6 份和 `RawLabAndroid/docs/` 下 3 份；`docs/integration/editing-iteration/README.md`
- 问题：这些是某次验证或排查的过程记录，按 `AGENTS.md` 应写进 PR 说明或归档；放在客户端目录里，
  改它们还会触发该平台的 CI。迭代总账自己写着"本轮结束后移入 `docs/archive/`"，但仍停在"#129 进行中"。
- 注意：`RawLabWindows/build.ps1:200` 把其中两份和 README 拷进发布包，移动时要同步改脚本。
- 整改方向：统一移入 `docs/archive/` 或删除；总账更新状态后归档。

### R12 iOS 把整个 `Shared/BundledLooks` 目录打进包，其余三端只取运行需要的文件

- 严重度：低｜确认程度：已读工程文件，未检查实际构建产物
- 位置：`RawLab/RawLab.xcodeproj/project.pbxproj:59`、`:315`；对照 `RawLabMac/build.sh:172-177`、
  `RawLabAndroid/app/build.gradle.kts:95-99`、`RawLabWindows/RawLabWindows.csproj:29-33`；`Shared/tests/test_bundled_looks.py:29-33`、`:71-74`
- 问题：四端确实同源，但 iOS 包里多带了 `REDISTRIBUTION_BLOCKED.md`、`adaptation-report.json` 和含本机绝对路径的
  `Artwork/generated-*.json`。现有测试只检查构建文件里有没有出现某个字符串，发现不了整目录引用。
- 整改方向：iOS 改为只引用运行所需文件；测试改为核对实际打包清单。

### R13 入库文件里有 109 处含本机用户名的绝对路径

- 严重度：低｜确认程度：已读；只扫了当前提交，没有扫历史
- 位置：`docs/design/2026-10-09-edit-memory-batch-export/prompts.json`；`Shared/BundledLooks/Artwork/generated-*.json`；
  `RawLabMac/Resources/FilmIcons/generated-*.md`；`reviews/` 多份及 R11 所列的验证记录
- 其他扫描结果：没有发现私钥、令牌、口令或内网地址。签名材料只以环境变量名出现；
  `RawLabWindows/Updates/UpdateTrust.json` 只有公钥和更新源地址。
- 整改方向：把来源记录里的本机路径改成相对描述；配合 R10、R11、R12 清理。

### R14 三个平台的测试都靠"每个脚本手写源码清单"来编译

- 严重度：低到中｜确认程度：已读（抽查加统计）
- 位置：Mac `RawLabMac/tests/edit-model.sh:8-12` 等 105 个脚本；iOS `scripts/ci/apple-models.sh:21-27`、
  `RawLab/tests/processor-export.sh:16-30` 等约 70 个脚本；Windows `RawLabWindows/tests/editing/EditWorkflow.Tests.csproj` 等 12 个工程
- 问题：
  1. 应用新增依赖文件时要逐个脚本改，容易漏；Mac 全量跑时同一批核心文件被重复编译上百次。
  2. iOS 的 CI 快速通道只跑其中 11 个脚本，导入状态、处理器导出、批量导出等都靠手动。
     `RawLab/tests/DisplayLensTests.swift` 没有任何脚本或工程引用，从不编译运行。
  3. Windows 是 12 个独立控制台工程，自写断言，第一条失败后同一套件后面的检查不再执行；
     测的不是发布的程序集；`tests/PerformanceChecks.cs` 只打印不断言。
  4. Android 有按源码文本做断言的用例（`.../settings/HDRNeutralReferenceTest.kt:37-44`），
     `BatchRunner.retryFailed` 在正式代码里没人调用却有 9 处测试引用；16 个设备测试文件共 34 处固定睡眠。
  5. iOS 的桥接文件在应用里按 `gnu++14` 编译，测试脚本按 `c++17` 编译（`project.pbxproj:1501`、`:1616` 对 `processor-export.sh:19`）。
- 整改方向：每个平台把共用源码清单抽成一份供各脚本引用；给无人引用的测试补运行入口或删除；
  源码文本断言改成行为断言。长期考虑 Windows 迁到标准测试框架。

## 10. 次要问题

每条一句话加位置，按范围排列。确认程度都是"已读"，标了"推测"的除外。

### 10.1 核心库

1. 核心库直接向标准输出和标准错误打印，CLI 只能临时重定向来规避：`lutools/src/core/raw_processor.cpp:160`、`:710`、`:943`、`:947`。
2. CLI 的 `std::stoi`、`std::stof` 没有捕获异常，参数写错会直接崩溃：`lutools/src/cli/main.cpp:99`、`:123`、`:130`。
3. ACES 白点常量与矩阵行和不一致，中性色约有 0.07% 的偏色：`lutools/src/core/color_converter.cpp:211-225` 对 `:307`、`:312`。
4. DNG 光源表不全，遇到未列出的光源时色温白平衡只用第一张矩阵：`lutools/src/core/white_balance.cpp:35-49`、`:120`。
5. 输出镜头厂商名前没有判空，同文件另一处判了：`lutools/src/core/lens_correction.cpp:26` 对 `:36`。
6. `applyHsl` 每个像素都重新比较 24 个参数：`lutools/src/core/photo_color.cpp:57`。
7. 两处条件编译的两个分支完全相同：`lutools/src/core/proraw_source.cpp:210-214`、`lutools/src/cli/agent_commands.cpp:258-262`。
8. 公共头文件里的示例已经跑不通，`lutools/build.sh:100`、`:121` 也已过时：`lutools/include/sony2fuji/sony2fuji.h:22-44`。
9. 核心头文件反过来依赖对外接口头文件：`lut_preview_comparison.h:2`、`wavelet_cache.h:3`、`photo_tone_curve.h:3`、`hdr_rendering.h:9`。
10. LUT 遇到未知关键字报的是解析错误而非"不支持"：`lutools/src/core/lut_parser.cpp:197-200`。
11. HDR 边界的兜底分支把所有未知异常都报成"非有限值"：`lutools/src/ffi/sony2fuji_hdr.cpp:88-90`。
12. 核心自己发布的 HDR 图像对，每次渲染或导出仍全幅扫描是否有限：`lutools/src/ffi/sony2fuji_hdr.cpp:112-119`、`:167`。
13. 取消回调会被核心内部线程并发调用，头文件没写明：`lutools/include/sony2fuji/ffi/sony2fuji_c.h:787-795`。
14. AI 缓存在全局锁内做整文件 SHA-256，别的会话也会被挡住：`lutools/src/ai/dualdn_cache.cpp:99-108`。
15. Windows 上每次 HDR AI 操作都重新枚举显卡并逐个创建设备，一次解码做三轮：`lutools/src/ffi/sony2fuji_c.cpp:1358-1365`、`:1377`、`:1770-1773`。
16. 解码结果超过 128 MiB 就立即释放 RAW 处理器，高像素相机连半尺寸交互白平衡也要重开文件：`lutools/src/ffi/sony2fuji_c.cpp:1176-1179`。
17. Windows 的临时文件路径受 `MAX_PATH` 限制，深目录会失败：`lutools/src/platform/hdr_image_portable.cpp:323-350`、`lutools/src/core/rendered_dng.cpp:135-141`。
18. `sony2fuji_session_set_gpu_config` 不校验模式，未知值静默当成关闭；请求校验不检查白平衡模式和用途：`lutools/src/ffi/sony2fuji_c.cpp:498-507`、`:510-583`、`:1683`。
19. Force 加 rlook 在非 Metal 构建返回处理错误，其他"Force 不支持"都返回不支持；完全没有 GPU 后端的构建里 Force 的中性渲染会在 CPU 上成功：`lutools/src/ffi/sony2fuji_c.cpp:2260-2262`、`:2273-2275`。
20. Windows 导出的 `rawlab_display_preview` 不在公共头文件里：`lutools/src/platform/display_image_windows.cpp:1417`。

### 10.2 Mac

1. 导出文件名里的"无外观"名称不一致，有的用 `"neutral"` 有的用 `"中性"`：`RawLabMac/Sources/Editor/Model/EditorModel+Workflow.swift:337`、`:679`，`Sources/Export/BatchExportModel.swift:58`，`Sources/Export/BatchSelection.swift:137`。
2. "按保存的胶片编号找胶片"在至少 6 处各写一遍：`EditorModel+Workflow.swift:413`、`:469`，`EditorModel+AdjustmentHistory.swift:129`，`BatchExportModel.swift:54`，`BatchSelection.swift:133-135`，`MacEditedPhotoPreviews.swift:31-33`。
3. 写入磁盘的枚举值直接用中文界面文案，改文案等于改存储格式，结合 X1 会让旧记录整体读不出：`RawLabMac/Sources/Adjustments/AdjustmentTypes.swift:61-72`。
4. `MasterRecipe` 里留着相对当前目录的开发期查找路径，`lutURL()` 每次调用做多次文件存在性检查又被高频调用：`RawLabMac/Sources/Looks/MasterRecipe.swift:51-66`、`:100-126`。
5. 只被测试调用的生产代码：`Sources/Rendering/AgentRecipe.swift:5`、`Sources/Adjustments/Adjustments.swift:878-886`、`Sources/Editor/Storage/EditPersistence.swift:140-156`、`Sources/Presentation/PhotoCanvas.swift:18`、`:149`。
6. 应用入口内嵌了整段 `--smoke` 自测逻辑，编辑器还接受 `--sample` 启动参数，都随正式包发布：`Sources/System/RawLabMacApp.swift:13-54`、`Sources/Editor/View/EditorView.swift:301-306`。
7. 会话历史只增不减，`canUndoPhoto` 每次线性扫描全部事务：`Sources/Editor/Storage/AdjustmentTransferSession.swift:59`、`:64`、`:179-182`。
8. 处理版本上限 `3` 在迁移判断里写死两处：`Sources/Editor/Model/EditorModel+ProcessingMigration.swift:29`、`Sources/Editor/Storage/EditPersistence.swift:96`。
9. 更新包会下载两次，第一次下载期间不上报进度（进度表现为推测）：`Sources/System/Updates/SparkleUpdateAdapter.swift:68-99`。
10. 应用代理写在 `MacGeometryWindowGuard.swift` 里；`Sources/Editor/Model/EditorModel.swift:279-280` 的注释与实际读写线程不符；`Resources/` 下有生成说明类文档。

### 10.3 iOS 与 `Shared/`

1. `BatchExportModel.addPickerItems` 和 `addFiles` 在非主线程读取发布属性：`RawLab/RawLab/Core/Batch/Execution/BatchExport.swift:150-153`、`:187-190`。
2. 后台队列直接读 `lutMap` 和 `editPersistence`，线程安全只靠界面"忙碌时禁用"：`RawLab/RawLab/Core/ViewModel/IO/RawEditorViewModel+IO.swift:168`、`:196`、`:229`。
3. 对 RAW 点一次自动曝光会销毁预览会话，前后多解码两次：`RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor.swift:289`。
4. 调整传输会话的事务和结果无上限增长：`RawLab/RawLab/Core/Persistence/IOSAdjustmentTransferSession.swift:61`、`:67`、`:176`、`:322`。
5. 处理版本迁移拟合失败时不写回执，每次重开照片都再做一次全尺寸拟合：`RawLab/RawLab/Core/ViewModel/RawEditorViewModel+ProcessingMigration.swift:52-57`、`:69`。
6. iOS 能导入和改名外观但没有删除入口，共用库和 Mac 都有；是否有意保留差异没法确认：`RawLab/RawLab/Core/Looks/LookImportCoordinator.swift:65-261`、`Shared/LookLibrary.swift:319-334`。
7. `HDRCanvasRenderer` 用对象标识判断纹理是否已上传但不持有对象，有地址复用误判的可能（推测）：`Shared/Native/HDRCanvas.swift:34`、`:74`、`:84`。
8. 相机实时取景帧和大预览图在主线程解码，下载进度每 64KB 触发一次界面刷新：`RawLab/RawLab/UI/Camera/IOSCameraController.swift:136-141`、`:166-179`。
9. `RawLab/RawLab/Resources/x100vi-3d-lut-v100/` 的 5 个文件与 `lutools/F-Log2/` 字节相同，工程里没有引用。

### 10.4 Android

1. JNI 一把全局锁把所有原生会话串行化，HDR 渲染期间还一直握着图像表的锁；目前界面基本互斥所以没有可见问题，但属于隐性约束：`RawLabAndroid/app/src/main/cpp/rawlab_jni.cpp:54-61`、`:1466`、`:1108-1131`、`:1333`、`:1355`。
2. 死代码：`.../camera/CameraImportStore.kt:148`；`.../editor/storage/EditorEditStore.kt:46`、`:60-67`；`.../settings/EditPersistence.kt:45`、`:61-62`、`:94`、`:126`；`.../editor/EditorViewModel.kt:492-498` 连写三次相同赋值。
3. `MasterRecipe.load` 每次调用都重读并解析资产文件，配方生效时每帧预览都走一次：`.../looks/MasterRecipe.kt:25-26`、`.../photo/PhotoStorage.kt:371`。
4. 主线程上的磁盘操作：`.../batch/BatchExportModel.kt:394-402`、`.../editor/ui/AdjustmentPresetSheet.kt:57-64`、`:96`、`.../RawLabApplication.kt:16-17`。
5. 来源拿不到普通文件描述符时，每次提交编辑都整份读原片算校验值（影响为推测）：`.../photo/OriginalPhotoSource.kt:36-42`。
6. `nativeExportProRAW`、`nativeSampleHsl` 没有单独处理内存不足，走不到"内存不足"提示：`rawlab_jni.cpp:1075-1076`、`:1170-1171`。
7. `onCleared` 靠"恰好 6 次回调"决定何时关闭存储：`.../editor/EditorViewModel.kt:1881-1886`。
8. 相机媒体登记表每导入一张就同步重写整个文件且从不清理；每发布一张照片重写两次整份任务日志：`.../photo/MediaPhotoLibrary.kt:72-78`、`.../camera/CameraImportStore.kt:203`、`:241`、`:254`。
9. 清单对全应用允许明文流量；`.gitignore` 未忽略 `.p12`：`RawLabAndroid/app/src/main/AndroidManifest.xml:29`、`RawLabAndroid/.gitignore:6-7`。
10. `RawLabAndroid/README.md:346-347` 中英文对"重开后是否恢复"的说法相反；`unitTests.isReturnDefaultValues = true` 会掩盖 Android 接口误用（`app/build.gradle.kts:175`）。

### 10.5 Windows

1. 导出的 EXIF 软件名写死为 `RawLab 0.2`：`RawLabWindows/ExportMetadata.cs:46`。
2. 死代码：关于窗口的两个更新处理函数已无界面引用；若干原生声明在应用代码里没有调用：`AboutWindow.xaml.cs:54`、`:66`，`PInvokeNative.cs:25-31`，`Native.cs:168-185`、`:328`、`:330`、`:351`、`:362`、`:406-409`。
3. 应用已在运行时再次启动：静默等 5 秒后弹错误框，文案里直接带内部标记 `other_instance`，也不把已有窗口提到前台。拒绝第二实例是既定行为，这里只指体验：`SystemPhotoOpen.cs:66-84`、`Program.cs:25-31`。
4. 切换语言时新字典先发布再填充，后台线程可能读到正在写的字典：`Localization.cs:62-68`。
5. 更新下载的重定向主机写死为两个域名，GitHub 一旦更换下载域名，应用内更新会同时失效（推测）：`Updates/SignedUpdateSource.cs:80-83`。
6. 批量窗口刷新对条目做平方级查找，AI 进度每跳一次都触发：`BatchExportWindow.xaml.cs:117-123`、`:402-403`。
7. 批量导出每项导出前有一次结果被丢弃的 32 像素预渲染（成本为推测）：`BatchExportWindow.xaml.cs:413-414`。
8. 粘贴预检的闭包在后台线程读取界面线程字段，没有同步：`MainWindow/AdjustmentCommands.cs:57-58`。
9. `README.md:76` "不自动安装"与 `:41` "支持自动更新"自相矛盾。
10. 只读的原生输入结构都按引用传，每次调用多一次回拷；预览键里放了原生请求结构，每帧用反射比较：`Native.cs:357`、`:395-396`，`RenderEngine.cs:22-23`。

### 10.6 仓库与流程

1. `docs/process/ci.md:222-224` 写 macOS 排除 3 个测试，实际是 5 个，Intel 还多 1 个（`.github/workflows/ci.yml:220-221`）。
2. rustup 安装器的校验值与安装器来自同一服务器，只能防损坏不能防替换：`scripts/ci/prepare-rust.sh:20-24`。
3. 根目录的 `raw_decode_check.swift` 是遗留的一次性诊断脚本。
4. `experiments/` 里有被正式流程依赖的脚本（`Shared/BundledLooks/catalog.json:11`、`RawLabWindows/README.md:74`）；`RawLabMac/Sources/Looks/MasterRecipe.swift:115` 引用了库里不存在的 `experiments/hamada-neural/`。
5. 最小裁剪尺寸 Mac 是 0.001，Windows 是 0.0001：`RawLabMac/Sources/Adjustments/AdjustmentTypes.swift:464-465`、`RawLabWindows/GeometrySettings.cs:26`。
6. 仓库历史约 1.64 GiB，工作区约 340 MiB，没有用大文件存储；`docs/images/rawlab-mac-velvia.png` 单张 11 MB。

## 11. 做得好、不要改动的地方

整改时注意不要破坏这些已经做对的设计。

- **预览调度防旧结果覆盖**：四端都只保留最新请求，结果回到主线程前按修订号、文件身份逐项核对。
  按"旧结果覆盖新状态"的思路逐条推过，没有找到会显示错图的路径。
  Mac 的 `RawLabMac/Sources/Rendering/RenderScheduling.swift` 只有 80 行，规则集中且有独立测试。
- **批量导出的落盘与中断恢复**：临时文件、先记"发布中"再改名、重启后按文件身份判断是否已发布。
  iOS 区分"正在保存"和"待确认"，中断后不会重复写相册。Android 的日志用"快照加带代次和校验的追加记录"。
- **桌面更新的校验链**：Mac 和 Windows 都没有发现可绕过的路径。签名的更新源、哈希、版本和时效校验、
  安装前再次核对、压缩包条目的路径穿越检查、安装前的数据备份和回滚都在。
- **C 接口的使用**：缓冲区和会话成对释放，结构体带版本和大小前缀并逐一校验。Windows 的结构体布局逐个对照头文件一致，
  回调委托保持存活。Android 的 JNI 用不透明编号代替原生指针，没有全局引用，没有原生线程回调 Java。
  Rust 桥把解码整体包在 `catch_unwind` 里。
- **Metal 照片管线**：16 MiB 分块、缓冲复用、全部成功才发布、显式三线性、系统异常包装齐全。
- **Force 语义**：在有 GPU 后端的构建里逐条看过分支，没有发现悄悄走 CPU 后报成功的路径。
- **相机协议的防御性解析**：两端都有操作码白名单、长度和条数上限、超时、下载后核对文件头和校验值。
- **核心的文件格式边界检查**：DCP 编译器和 RLOOK 读取按公式精确校验大小；渲染型 DNG 先预检、写暂存、成功后替换。
- **文案单一来源**：四端六语词表由 `Shared/strings` 生成并逐字节比对。
- **CI 的平台选择和缓存键**：未归类的路径一律选全平台，取不到差异就全跑；缓存键严格，没有模糊兜底。
  逐一核对客户端目录之间的引用后，没有找到改了共享代码却漏选平台的情况。
- **工作流基本安全做法**：动作钉到完整提交哈希，默认只读权限，不保留检出凭据，不使用密钥。
- **凭据管理**：仓库里没有口令和私钥，Android 签名口令通过文件传递。

## 12. 整改分批建议

各批之间尽量互不依赖，可以并行分派。每条整改都按根目录 `AGENTS.md` 的流程走：先补能证明问题的回归测试，
再做最小充分改动；涉及功能的先改 Mac 再移植；改共享 C 接口时检查四个客户端的调用方。

### 第一批：改动小、收益直接、互不依赖

| 编号 | 内容 | 涉及范围 |
|---|---|---|
| W1 | 更新提示的文件名匹配 | Windows |
| M1 | HSL 取色的来源身份比较 | Mac |
| A3 | HDR 外观导入的状态复位 | Android |
| X1 第 1 步 | 编辑记录落盘同步、空文件报错 | Android |
| R2 | 补齐 9 个文案键，并把检查接进 CI | Mac、iOS、CI |
| C3 | 三个入口补兜底捕获，两处 Metal 补异常包装 | 核心 |
| C2、C4 | 色度降噪改用分块版本；GLES 上下文恢复 | 核心 |
| I5 | HDR 预览不再每帧改写提示 | iOS |
| R10、R11、R13 | 文档和忽略规则清理 | 仓库 |

### 第二批：需要先验证或先做决定

| 编号 | 先要确认什么 |
|---|---|
| C1 | Mac 和 iOS 是否真有两个线程同时解 RAW；改链后 Apple 构建机的依赖缓存要重建 |
| R1 | GitHub 仓库是否公开、外部 PR 的运行前审批设置 |
| A4 | 核心的导出路径目前不启用取消，需要核心和 JNI 一起改，并检查其他三端 |
| W2、W3、W7 | 更新状态机的三处行为，其中 W7 有测试固定，是否调整需要决定 |
| M3 | 整幅中性参考帧是否保留 |
| R7 | 移动端滑杆精度较粗是否有意为之 |

### 第三批：存储回收

I1（iOS 批量 DNG 和相机原件）、A2（Android 孤儿副本和临时文件）、W10（Windows 临时目录）、X5（批量日志容错）。
这一批涉及删除用户设备上的文件，每条都要先明确"什么算可以删"，并补测试证明不会删掉仍在使用的文件。

### 第四批：编辑记录改造（X1 第 2、3 步）

按 Mac、iOS、Windows、Android 的顺序做。先做进程内缓存和后台写入，再做逐条容错。
持久化格式不变，所以不需要跨端同步发布；若后续决定按照片分文件，再单独设计迁移。

### 第五批：共性性能问题

- X3 的核心镜头库缓存先做，四端同时受益。
- X2 各端的文件身份缓存。
- C9（单线程阶段迁移）、C11（LUT 解析与缓存）、C12、C13、C19。
- 各端自己的项：M2、I3、I4、I7、I8、A1、A5、A6、W5、W6。

这一批每条都要先测基线再改，文中的耗时数字都是推算。

### 第六批：工程与流程

R3（参数向量覆盖）、R4（版本号校验）、R5、R6（Windows 测试对账）、R8、R9、R12、R14（测试脚本共用清单）、
C22（缺素材的测试标记为跳过）、C23 和各端的死代码清理、M5（Mac 构建脚本）、A7（Android 代码压缩）。

## 13. 待验证事项与未覆盖范围

### 13.1 需要运行或查外部设置才能确定的事项

| 编号 | 待确认内容 |
|---|---|
| C1 | 客户端是否存在并发解码；能否复现像素损坏 |
| R1 | 仓库公开性和外部 PR 审批设置 |
| W1 | 线上发布页的实际文件名 |
| A4 | 核心导出路径对取消回调的响应 |
| W2 | 开着应用关机时是否走正常退出流程 |
| W4 | 内嵌预览损坏时抛出的具体异常类型 |
| X3 | iOS 上单次镜头库加载的实际耗时 |
| C5 | 独立 LUT 的硬件采样与显式三线性是否有可见差异 |
| C6 | D3D11 大图创建失败的显存阈值 |
| C16 | Core ML 是否会把算子排到 CPU |
| I9 | 与上一轮"导出复用 `draftBuffer`"改动的关系（补充评审已核实：问题仍在，见 14.3.2） |
| X6 | Mac 的相机导入是否有同样的整卡重列逻辑（补充评审已核实：Mac 没有相机导入代码，见 14.8） |
| 全部性能条目 | 耗时和内存数字都是按代码推算的 |

### 13.2 没有覆盖到的范围

以下是 2026-11-12 的状态。其中大部分已在第 14 节补读，补读之后各方向仍没读到的内容见 14.1 到 14.7 各自的最后一小节。

- **界面层**：四端的界面代码大多只略读或做了关键字检索，没有系统分析刷新和重组次数。
  Windows 除关于窗口外的全部 XAML、iOS 和 Android 的各调整面板与相机界面、Mac 的大部分控件都没有细读。
- **调整传输的字段规则**：四端的复制粘贴、预设、同步只核对了会话与持久化流程，没有逐字段核对取值和兼容规则。
- **着色器**：`lutools/src/gpu/` 下各着色器文件没有逐行与 CPU 公式对照。
- **核心未读部分**：`lutools/src/cli/edit_recipe.cpp` 只读了约一半；`lutools/cmake/` 下多个文件未读；
  `lutools/src/ai/` 下的桥接、几何、噪声估计、模型包等未读；`lutools/src/platform/` 的 HDR 元数据和 HEIF 颜色未读；
  X3F 桥的 `dp1s.rs`、设置相关文件只扫了不安全代码点；`lutools/docs/color-contract.md` 第 764 行以后未读。
- **相机**：Android 的 `SonyTetherSession.java`、`SonyLegacyImportSession.java` 及联机队列未细读；
  iOS 的 `CameraProtocol.swift`、`CameraIncrementalImport.swift` 未细读；Mac 的相机导入没有读到。
- **测试**：各端都只抽查了组织方式和少数文件，没有逐个评估断言质量；界面测试内容没有读。
- **脚本与工具**：`tools/mcp`、`tools/camera-transfer` 的源码没审；Windows 除 `build.ps1` 外的脚本未读；
  `scripts/ci` 的运行机配置脚本只查了下载校验。
- **文档**：`docs/` 只抽查，没有系统核对发布说明和各 README；翻译内容没有逐条核对。
- **仓库历史**：敏感信息只扫了当前提交，没有扫 git 历史。
- **两条没来得及核实的线索**：自带的 libtiff 关掉了 JPEG 编解码（`lutools/cmake/tiff-dependencies.cmake:26`）
  而桌面用系统 libtiff，DNG 预览在两种配置下的行为可能不同（补充评审已核实，前提不成立，见 14.1.2）；
  随包外观的再分发许可是记录在案的所有者决定，没有重新评估。

## 14. 补充评审（2026-11-13 起）

这一节把第 13.2 节列出的未覆盖范围按方向逐个补读，每补完一个方向追加一小节。

- **基线**：`origin/development` @ `191d8aba`，本节行号以它为准。
- **方法**：与前面相同，只读，没有运行构建或测试。标"已复核"的是汇总时又对照代码核对过的。
- **编号**：沿用各范围的前缀接着往下编（核心库从 C25 起）。
- **新增数量**：主要发现 40 条（C25–C30、I12–I19、A11–A20、W11–W17、M7–M11、R15–R18），次要问题 85 条。
- **进度**：七个方向都已补完（2026-11-13）。补完后各方向仍没读到的内容列在 14.1 到 14.7 各自的最后一小节，
  它们取代第 13.2 节里对应的条目。
- **先看哪里**：唯一一条高严重度是 R15（14.7.2）。跨端重复出现的问题汇总在 14.8，Mac 作为参考端的行为在 14.6.1。
  哪些补充发现看起来已经有整改合入、哪些还没有，见 14.9。

### 14.0 基线之后已经在整改的条目

`9c4f7801` 到 `191d8aba` 之间合入了 86 个提交（PR #209–#239），其中不少是按本文整改的。
下表是**按 PR 分支名推断**的对应关系，没有逐条核对修复内容，动手前仍要看代码。

| 发现 | 看起来对应的 PR |
|---|---|
| C1 | #227 `feature/libraw-threadsafe` |
| C3 | #226 `feature/render-entry-guard` |
| C4 | #229 `feature/gles-binding-restore` |
| C14 | #223 `fix/output-size-cap` |
| C22 | #211 `feature/ctest-skip-codes`、#237 `feature/ctest-sample-skip` |
| X1（部分） | #214 `feature/win-edit-durability`、#221 `feature/record-isolation` |
| X4 | #230 `feature/export-write-verify` |
| X5 | #231 `feature/batch-journal-isolation` |
| A4 | #234 `feature/android-export-cancel` |
| W4 | #232 `feature/win-global-exception` |
| R1（部分） | #222 `feature/fork-guard-self-hosted`：只保护了 Windows 和 iOS 作业，macOS 作业漏了，见 R15 |
| R2（部分） | #212 `feature/loc-ci-gate`、#218 `feature/localization-docs` |

另外，本机 `../rawtools-worktrees/` 下有以这些编号命名的整改工作区：A3、A4、A10、C1、C3、C4、C14、
M1、M2、M4、R1、W1、W2、W3、W4、W7、X4、X5，说明这些条目已经处理或正在处理。

补充评审中顺带确认**仍然存在**的：C2（已复核，`lutools/src/gpu/gles_photo.cpp:297`、
`lutools/src/gpu/d3d11_photo.cpp:216` 仍调用整图版）、C10（已读）。

### 14.1 核心算法与构建

补读范围：`lutools/src/cli/edit_recipe.cpp` 剩余部分、`lutools/cmake/` 下此前没读的文件、
`lutools/docs/color-contract.md` 第 764 行以后、`lutools/tests/` 取样、libtiff 线索。
这些文件在两个基线之间基本没有变化（只有 `ai-denoise.cmake` 多了 4 行）。

#### 14.1.1 新的主要发现

**C25 构建用的 Meson 和 Ninja 没有钉校验值**

- 严重度：中到低｜确认程度：已复核（Linux 选包可能选错一条是推测）
- 位置：`lutools/cmake/build-lens-dependencies.py:66-87`；对照同文件 `:22-42` 和
  `lutools/cmake/lens-dependencies.json:2-10`
- 问题：其余依赖都用仓库里写死的 SHA-256 校验，只有这两个构建工具例外。脚本只钉了版本号
  （meson 1.12.1、ninja 1.13.2），校验值取自同一次 PyPI 响应里的 `digests`，只能防下载损坏，
  防不了内容被换。它们在构建机上直接执行，iOS、Android、Windows 的 Lensfun 构建都经过这里。
  另外（推测）Linux 上按文件名后缀 `_<machine>.whl` 取第一个匹配，PyPI 同时提供 manylinux 和
  musllinux 两种包时，取到哪个取决于返回顺序。
- 整改方向：把两个安装包的文件名和 SHA-256 写进 `lens-dependencies.json`，走同一个 `fetch`，
  并允许从源码缓存取。
- 验收：断网且缓存齐全时能完成构建；改动任一安装包内容后构建报校验失败。

**C26 GLES 照片管线在核心的 ctest 里没有像素级测试**

- 严重度：中｜确认程度：注册条件已复核，其余已读（只查了 `lutools` 的 ctest，Android 工程里有没有设备测试没查）
- 位置：`lutools/CMakeLists.txt:891-896`、`:897-909`、`:910-914`；
  `lutools/tests/gpu_photo_tests.cpp:168-183`；`lutools/docs/color-contract.md:861-862`
- 问题：CPU 与 GPU 的逐像素对照 `gpu_photo` 只在 `APPLE OR WIN32` 时注册，代码里只有 D3D11 和 Metal
  两个分支。GLES 只有两类测试：`gles_shader`（用 glslang 校验着色器能否编译）和
  `gpu_gles_lut_binding`（用 `tests/gles_stub/` 的假头文件测上下文绑定，不出像素）。
  文档把 Android 的一致性交给真机记录。C2、C7 的整改都要动 `gles_photo.cpp`，目前没有自动化手段发现算错。
- 整改方向：在能跑 GLES 3.1 的环境（Android 模拟器或桌面 EGL 软件实现）里复用
  `gpu_photo_tests.cpp` 的用例，加一个 GLES 分支。做不到的话，至少在 CI 说明里写明这条路径靠人工验收。
- 验收：故意改错 GLES 着色器里一个系数，CI 能变红。

#### 14.1.2 对已有发现的证实、推翻或补充

- **libtiff 线索：前提不成立，关闭。**
  - 各平台来源：iOS、Android、Windows 默认用 `lutools/cmake/tiff-dependencies.cmake` 的自带静态库
    （`lutools/CMakeLists.txt:24-33`、`lutools/platform/ios/build-framework.sh:65`、
    `RawLabWindows/native/CMakeLists.txt:64`）。Mac 应用用的也不是系统库，而是
    `RawLabMac/build-tiff-dependency.sh:7-17` 自己编的静态库，同一个 4.7.1 源码包、同一个 SHA-256，
    同样关了 JPEG（已复核）。真正用到系统 libtiff 的只有直接跑 `lutools/test.sh` 这类开发构建
    （`lutools/CMakeLists.txt:35`）。
  - 两处用法都不依赖 libtiff 自己的编解码：DNG 写出时预览的 JPEG 由 libjpeg 压好，用
    `TIFFWriteRawStrip` 原样写入（`lutools/src/core/rendered_dng.cpp:293`、`:314-345`），主图不压缩
    （`:570`、`:598`）；TIFF 读取只有 Apple 的分页标记检查，只读目录不解像素
    （`lutools/src/platform/display_image.cpp:207-221`）。
  - 剩余差异：Mac 那份没关 zlib、LZW、PackBits、CCITT，自带那份全关了
    （`tiff-dependencies.cmake:17-30`）。"没配置的压缩方式不会让读目录失败"是凭对 libtiff 的了解判断的，
    没有读它的源码。想坐实，可以给 `display_image_tests` 加一张 LZW 压缩的双目录 TIFF。
  - 顺带：`lutools/CMakeLists.txt:22-23` 的注释写"桌面用系统包、移动端用固定副本"，与实际不符。
- **C2 补充**：函数级的"整图版与分块版结果一致"回归已经有了
  （`lutools/tests/chroma_denoise_tests.cpp:52-67`，5 种尺寸、2 种模式，误差上限 0.0002；`:68-80` 还有 GPU 版）。
  整改时不必新写函数级测试，缺的是 GLES、D3D11 渲染器这一层的覆盖（见 C26）。
  `lutools/docs/color-contract.md:815-817` 明确写了内部色度降噪用有界分块，所以 C2 也是对文档承诺的偏离。
- **C8 补充**：`lutools/docs/color-contract.md:843-845` 写的是"导出释放大的 RAW 缓存，预览可以保留一份供反复调整"，
  支持 C8 的整改方向。这一条在新基线下是否已变没有核对。
- **C10 仍然成立**：`lutools/tests/processing_cancellation_tests.cpp` 比旧基线多了 66 行，
  但全文仍没有小波、色度、降噪相关的取消用例。
- **C12 补充**：文档写明内嵌 JPEG 用自带的 stb_image v2.30 解码，且"不需要额外系统库"
  （`lutools/docs/color-contract.md:884`）。如果按 C12 改用 libjpeg-turbo 缩放解码，这句文档要同步改。
- **C19 补充**：Lensfun 也在所有平台关了 SSE 和 SSE2，同样没写原因
  （`lutools/cmake/build-lens-dependencies.py:292-293`）。另外 Mac 依赖脚本另编了一份默认带 SIMD 的
  libjpeg-turbo 3.1.3（`RawLabMac/build-dependencies.sh:45-49`），C19 说的"所有平台都关了"在 Mac 上是否成立，
  要对照 `raw-jpeg.cmake` 的启用条件再核一次。
- **C22 的同类残留**（不是 RAW 素材）：依赖模型包的 5 个 AI 测试仍是"没给路径就不注册"
  （`lutools/cmake/ai-denoise.cmake:116-129`）；`gles_shader` 是"没找到 glslang 就不注册"
  （`lutools/CMakeLists.txt:891-896`，已复核）。CI 里装了 glslang，本地不一定有。

#### 14.1.3 次要问题

配方解析（`lutools/src/cli/edit_recipe.cpp`）：

1. SDR 序列化只校验了曲线、色调控制、氛围、调色轮（`:681-728`），曝光、HSL、效果、几何等数值直接写出
   （`:744-791`），NaN 会被写成 `null`；HDR 一侧则整体回过一遍解析（`:505-506`）。
   目前唯一调用点在解析成功之后（`lutools/src/cli/agent_commands.cpp:374-377`），是潜在问题。
2. HDR 序列化遇到当前版本装不下的字段时直接不写、不报错（`:483-504`），SDR 一侧会抛错（`:682-728`），
   两边原则不一致。同样只在程序内构造配方时才会碰到。
3. SDR 的 `lens_correction.profile_id` 没有长度和控制字符检查，HDR 的 `lens_profile` 有
   （`:224-225` 对 `:322-327`）。
4. `lutools/docs/edit-json.md` 的 v5 一节没有写 SDR 的 `edits.effects.clarity` 和 `dehaze`，
   解析器是接受的（`:186-192`）。

构建脚本（`lutools/cmake/`）：

5. `dng-sdk/CMakeLists.txt:27-37` 的四处替换不检查是否命中；LibRaw 和 wavelib 的补丁都会检查。
   源码包钉了校验值，风险只在升级 SDK 时出现。
6. `patch-libraw.cmake:6-22` 的 `replace_libraw` 会替换所有匹配，不检查锚点是否唯一，
   只有 A1 II 一处手工查了（`libraw-cameras.cmake:141-147`）。建议在函数里统一数一遍。
7. `libraw-cameras.cmake:13-44`（已复核）：A1 II 裁切分支里第一个 `if` 没和后面的 `else if` 连起来，
   8672×5784 的文件设好尺寸后仍会落到最后的 `else`，被打上 `LIBRAW_WARN_VENDOR_CROP_SUGGESTED`。
   核心代码没有引用这个标志，目前无影响；是否照搬上游没核对。
8. `patch-libraw.cmake:246-248` 让 X-Trans 去马赛克每次多拷一份整幅快照，按代码推算 4000 万像素约 320 MB。
   这是为了并行和串行结果一致，属于有意为之，移动端大图要留意。
9. `wavelib-iswt2.c.inc:137-143`：快速路径申请两块缓冲失败时，退回到 `rawlab_iswt2_phases`，
   后者要申请八块更大的缓冲且不判空（`:51-58`、`:31`），内存不足时反而更容易崩。
10. `build-lens-dependencies.py:52` 的 `extractall(filter="data")` 需要较新的 Python，
    而 `lens-dependencies.cmake:2` 只要求 3.11；`hdr_sources.py:98` 做了兼容。
    另外已解包目录不再校验（`:45-47`），`hdr_sources.py:50-69` 会逐文件核对。
11. `build-lens-dependencies.py:110`、`:118`、`:219`：Android 上不是 `arm64-v8a` 的架构一律当成 x86_64，
    传入其他架构不会报错。
12. `hdr_sources.py:122-123` 把两个包的文件名和目录名写死在脚本里，其余三个取自清单，升级要改两处
    （改漏会报错，不会静默）。`:105` 每次准备都把解包目录全部重算一遍校验值。
13. `ai-denoise.cmake:66-71` 只检查 ONNX Runtime 的头文件和库是否存在，不核对版本。

测试与文档：

14. GPU 对照的断言是 8 位下最大差 2（`lutools/tests/gpu_photo_tests.cpp:102-122`；
    `lutools/tests/acceleration_tests.cpp:40-46`、`:111`、`:133`），整体偏 1 到 2 级也能过。
    `gpu_photo_tests.cpp:131` 的 LUT 只有 2 格，测不出格点间插值的差别。
15. `lutools/tests/test_edit_recipe_schema.py:15-18`（已复核）：没装 `jsonschema` 时，
    schema 校验全部跳过，测试仍报通过。CI 的依赖清单里有它（`scripts/ci/requirements.txt:2`），
    是否每个跑 ctest 的作业都装了没核实。
16. `lutools/tests/core_tests.cpp:383`：没设 `SONY2FUJI_TEST_GPU` 时 Metal 与 CPU 的 LUT 对照不执行，也不提示。
17. `lutools/docs/color-contract.md:886` 提到"随仓库的 Sony ILCE-7CM2 样片"，仓库里没有任何入库的 ARW。

#### 14.1.4 读过后确认没问题、不要改动的地方

- **配方解析的严格性**：未知字段、重复键、1 MiB 上限、NUL、整数必须是整数写法、失败时不改目标对象
  （`edit_recipe.cpp:16-24`、`:514-525`、`:667`）。各版本的字段范围与 `lutools/docs/edit-json.md` 逐段对过，一致。
- **版本身份不会被悄悄丢掉**：X3F 模式、处理版本、曲线、调色在旧版本下都拒绝序列化（`edit_recipe.cpp:682-728`）。
- **配方测试质量好**：`lutools/tests/edit_recipe_tests.cpp:74-82` 的拒绝用例同时检查错误信息含字段名、目标未被改动。
- **范围内的下载都校验 SHA-256**（C25 除外）：`dng-sdk.cmake:5-6`、`build-lens-dependencies.py:35-41`、
  `hdr_sources.py:83-89`、`download-archive.cmake:8-27`、`tiff-dependencies.cmake:32-42`。
  `hdr_sources.py:94-97` 还拒绝越界路径和链接。
- **LibRaw 和 wavelib 补丁不会静默失效**：锚点找不到直接报错（`patch-libraw.cmake:16-19`；
  `wavelib/CMakeLists.txt:19-22`、`:27-29`），重复执行不会重复插入。
- **wavelib 逆变换替换有金值测试**：与 PyWavelets 比到 1e-11，另有单线程与双线程逐位一致
  （`lutools/tests/wavelet_denoise_tests.cpp:79-116`、`:50-68`）。
- **用 `assert` 的测试没有被 Release 构建架空**：抽查的 20 个目标都能找到去掉 `NDEBUG` 的设置。
- **`color-contract.md` 第 764 行以后抽查 8 处数值和行为断言，都与代码一致**
  （D3D11 功能级别、OpenCV 版本、内存测试预算、128 MiB 保留预算、F-Log2 锚点、512 KiB 线程栈测试、
  stb_image 版本、HSL 取样灰度门槛）。

#### 14.1.5 这个方向仍然没有覆盖到的

- **配方**：`validToneCurve` 的实现、`agent_commands.cpp` 里的 `renderHDR`、各版本 schema JSON 的逐字段内容没读。
  一条未核实的线索：schema 7 的 `normal-v1` 模式下，解析层不拒绝自动白平衡、RAW 降噪和镜头校正，
  渲染层是否明确报错没查。
- **构建**：`cmake/libraw/CMakeLists.txt` 没重读，`sony_arw6` 和 `rawlab_nikon_he` 两组源码如何进入编译列表没有追；
  `third_party/` 下被补丁拷入的源码和校准表没读，各相机补丁是否忠实于上游没有比对；
  `RawLabMac/build-env.sh`、`build-lens-dependency.sh`、`build-wavelet-dependency.sh` 没读。
  一条线索：本机共享缓存里有两份 LibRaw 源码没有最新的 Sony 裁切补丁标记，Mac 每次重新解包并核对补丁指纹
  （`RawLabMac/build-dependencies.sh:33-36`、`:95`），iOS 等脚本是否有同样保证没查。
- **测试**：`lutools/tests/` 约 190 个条目只取样读了 9 个文件。`display_image_tests.cpp`、HDR、几何、DCP、
  X3F 各组、`raw_thread_safety_tests.cpp`、降噪质量的 Python 脚本都没读；CI 各作业实际跑哪些测试没核对。
- **`color-contract.md`**：客户端行为（764-770、780、850-852 行）、`sony2fuji_analyze_image`（864-867 行）、
  HSL 取样除灰度门槛外的语义（890-921 行）没有与代码对照。
- **C1 的并发前提**：C1 已有整改合入，没有再核对。

### 14.2 核心对外接口、GPU、平台解析、AI 降噪与 X3F 桥接

补读范围：`lutools/src/gpu/` 三套着色器与 CPU 公式的对照、`lutools/src/platform/` 里解析外部文件的代码、
`lutools/src/ai/` 此前没读的文件、`lutools/x3f-bridge/src/` 的四个 Rust 文件。
`lutools/platform/ios/` 下的其余打包脚本这次仍然没读。

#### 14.2.1 新的主要发现

**C27 Windows 扫描 JPEG 时，过短的 Exif 段会导致越界读**

- 严重度：中｜确认程度：越界读已复核；能否稳定触发崩溃是推测
- 位置：`lutools/src/platform/display_image_windows.cpp:191-194`（`equalBytes`）、`:537-538`（调用处）、
  `:232-261`（`parseExifOrientation`）
- 问题：`equalBytes` 用 `strlen` 算比较长度，`"Exif\0\0"` 只算出 4，所以只比较前四个字节，也只要求段长不小于 4。
  调用处随后直接传 `payload.data() + 6` 和 `payload.size() - 6`，没有检查段长是否够 6。
  APP1 段内容只有 4 或 5 字节且以 "Exif" 开头时，长度相减下溢成一个极大值，`size < 8` 的检查失效，
  随后读到缓冲区之外。正常情况只越界读几个字节然后报"不支持"；如果堆里残留的字节恰好像 TIFF 头，
  后面会按残留的 32 位偏移去读任意位置，可能访问违规崩溃（这一步是推测，没有实测）。
- 整改方向：调用处先判断 `payload.size() >= 6`，并用显式长度 6 做比较；`equalBytes` 改为传入显式长度，
  不对含 `\0` 的字面量用 `strlen`。
- 验收：构造 APP1 长度字段为 6 和 7、内容为 "Exif" 的 JPEG，在开启页堆或地址检查的构建下打开，
  确认没有越界读，结果是"忽略该段"或"不支持"。
- 备注：这个扫描在哪些入口触发（是否包括缩略图浏览）没有确认，只确认了 `:1208-1210` 的调用点。

**C28 非 Apple 平台的 EXIF 解析没有累计复制上限，小文件可放大成数 GB 内存**

- 严重度：中｜确认程度：代码结构已复核；内存数字是按代码推算的最坏情况
- 位置：`lutools/src/platform/hdr_metadata.cpp:95-135`，关键行 `:111-113`、`:124-126`、`:132`；
  调用方 `lutools/src/platform/hdr_heif.cpp:121-135`、`lutools/src/platform/hdr_image_portable.cpp:72-74`、`:86`
- 问题：`TIFF::directory` 把每个条目的数据整段复制进 `Entry.bytes`，再存进 `primary`、`exif`、`gps` 三张表。
  累计预算 `copiedBytes` 只在 `rawSource` 为真时才检查（`:113`），普通 JPEG/HEIF 的 EXIF 只有
  "单条不超过整块大小"的限制。每个目录最多 4096 条，每条都可以声明"数据就是整个 EXIF 块"。
  按代码推算：HEIF 的 Exif 项上限 1 MiB，三张表最多留住约 12 GiB；JPEG 的 64 KB EXIF 约 0.8 GB。
  打开一张带增益图声明的恶意照片就会走到这里，结果是进程被系统杀掉或长时间卡顿。
  Apple 平台走 ImageIO，不经过这段代码；受影响的按文件名和调用关系判断是 Android 和 Windows，没有核对 CMake。
- 整改方向：对非 RAW 来源也加累计预算（例如总复制量不超过原始块大小的若干倍）；
  或者只复制真正要用的标签，其余只记偏移和长度。
- 验收：构造三个各 4096 条、每条都指向整块数据的 EXIF，确认很快以"元数据损坏"失败，内存占用有界。

**C29 GLES 着色器缺少"sRGB 输入 LUT"分支，Android 上这类 LUT 永远走 CPU**

- 严重度：低到中｜确认程度：已复核；这类 LUT 的常见程度没有核实
- 位置：`lutools/src/gpu/gles_photo.cpp:261`；`lutools/src/gpu/gles_photo_shader.h:144-149`；
  对照 `lutools/src/gpu/d3d11_photo_shader.h:17`、`:115-119`、`lutools/src/gpu/d3d11_photo.cpp:198`、
  `lutools/src/gpu/metal_photo.mm:434-439`
- 问题：Metal 和 D3D11 都有"LUT 输入是 sRGB"的分支，GLES 着色器没有，`render` 入口遇到这类 LUT 直接返回失败。
  Auto 模式下整帧静默回退 CPU，预览和导出都是。Force 模式返回的是"处理错误"而不是"不支持"。
- 整改方向：GLES 着色器补上同样的分支（与 D3D11 那几行等价），去掉入口的提前返回。
  如果是有意不支持，就在契约文档写明，并让 Force 返回"不支持"。
- 验收：Android 真机用一张 sRGB 输入的 LUT 做 GPU 与 CPU 的像素对比；Force 模式不再返回处理错误。
  这条与 C26 相关：没有 GLES 像素级测试，补分支后只能靠真机验收。

**C30 旧版降噪在预览时按缩小后的分辨率做，与导出不一致；GLES 的规则又和另外三条路径不同**

- 严重度：低到中｜确认程度：条件分支已复核；观感差异是推断
- 位置：`lutools/src/ffi/sony2fuji_c.cpp:2646-2648`、`:878-884`、`:898-900`；
  `lutools/src/gpu/metal_photo.mm:1030-1032`；`lutools/src/gpu/d3d11_photo.cpp:208-209`、`:219`；
  对照 `lutools/src/gpu/gles_photo.cpp:293`；iOS 传参
  `RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor+Helpers.swift:288`
- 问题：CPU 的注释写着"按像素半径的滤镜必须在原始分辨率上做，保证预览和导出一致"，
  但 CPU、Metal、D3D11 三处"先缩小再处理"的条件只排除了锐化，没有排除 `noise_reduction`。
  于是预览里 3×3 模糊作用在缩小图上，覆盖范围相当于原图的好几倍，比导出结果糊；
  把锐化从 0 调到大于 0 时预览切回原始分辨率处理，降噪观感跟着跳变。
  GLES 把 `noise_reduction > 0` 也算进"原始分辨率处理"，与另外三条路径规则不同。
  iOS 在新降噪关闭时会传这个参数；Mac 用的是 RAW 级降噪开关；Android 主代码里没搜到这个参数；Windows 没有确认。
- 整改方向：统一规则。要么三处条件都加上 `noise_reduction <= 0`，要么确认这是有意的性能取舍，
  把 GLES 改成一致并修正注释。
- 验收：补一条回归：`noise_reduction > 0`、`sharpening == 0` 时，缩小预览与"全尺寸处理后再缩小"的结果在容差内一致。

#### 14.2.2 对已有发现的证实、推翻或补充

没有推翻任何已有结论。

- **C2、C6、C7 证实仍然存在**：C2 见 14.0；`lutools/src/gpu/d3d11_photo.cpp:117-133`、`:203-230` 仍是整幅缓冲，
  `:231-233` 任何异常都销毁重建。
- **C9 补充**：还有几处串行的整图循环不在原清单里：`lutools/src/ai/scene_rgb_adapter.cpp:84-89`、
  `lutools/src/ai/dualdn_bridge.cpp:101-121`、`lutools/src/platform/hdr_image_apple.mm:412-427`
  （每通道一次 `pow`）、`:563-570`。
- **C15 补充**：`rgbCameraCorrection` 运行时同时存在 13 份单精度平面，约 52 字节每像素
  （`lutools/src/ai/dualdn_bridge.cpp:85-109`）。按代码推算，3300 万像素约 1.7 GB，6100 万像素约 3.2 GB。
- **C17 补充**：普通（非 HDR）管线的缩小同样是 4 点双线性、没有预滤波，四条路径公式一致
  （`lutools/src/ffi/sony2fuji_c.cpp:749-797`、`lutools/src/gpu/metal_photo.mm:191-212`、
  `lutools/src/gpu/gles_photo_shader.h:174-186`、`lutools/src/gpu/d3d11_photo_shader.h:140-145`），
  所以是画质问题，不是后端不一致。
- **C23 补充**：`lutools/src/gpu/metal_sharpen.mm:84-89` 一次分配 12 块整图缓冲，合计约 152 字节每像素，
  没有分块，还持有全局锁。如果决定保留并接入产品，需要先分块；这也是倾向删除的一个理由。
- **契约文档 `lutools/docs/color-contract.md:854-862`（Android GLES）**：大部分成立
  （运算顺序与 CPU 相同、LUT 是显式三线性、按行分块上传、只缓存缩小后的线性预览、
  只有 GPU 真正完成才报 GLES 后端、失败时保留 CPU 源）。不精确的是第 856 行
  "邻域细节滤镜在 Auto 用 CPU、Force 失败"：这只对清晰度、去雾、v3 基础影调成立
  （`lutools/src/ffi/sony2fuji_c.cpp:2363`、`:2373`、`:2379-2380`），锐化、旧版降噪、颗粒暗角、
  色度降噪实际在 GLES 路径内调用 GPU 实现（`lutools/src/gpu/gles_photo.cpp:293-300`）。建议改成列出具体滤镜。

#### 14.2.3 次要问题

1. **非 Apple 平台的 EXIF 解析过严**（发生频率是推测）：类型编号大于 13 就整体判为损坏，
   Exif 3.0 的 UTF-8 类型 129 会中招，同目录重复标签、两个 Exif 段也是
   （`lutools/src/platform/hdr_metadata.cpp:109-110`、`:173`）；导出时任一文本标签没有以 0 结尾或超过 16 KB，
   整个导出失败，而不是丢弃该标签（`:149`）。可能拒绝 Apple 平台能打开的文件。
2. **Apple 的 HDR JPEG 元数据回写是"一条失败全部失败"**：`lutools/src/platform/hdr_image_apple.mm:320-357`。
   `:292-294` 已经手工剔除了 6 个写不进去的键；新机型出现别的不可映射键时，该照片的 HDR 导出会整体失败
   （推测，需用多机型样片验证）。建议单键失败时跳过并记录。
3. **流式 JPEG 导出的文件权限是 0600**：`lutools/src/platform/hdr_image_apple.mm:366-395` 用 `mkstemp`
   后直接改名，没有调整权限；非流式路径权限随 umask。Mac 上导出到共享目录时其他账户读不了。
4. **路径不是合法 UTF-8 时会抛系统异常**：`lutools/src/platform/hdr_image_apple.mm:275-284` 的 `differentFile`
   没有判空，`:495-496` 同理。客户端传入的路径正常都合法，优先级低。
5. **Windows AI 降噪的文件变更监听常驻进程**：`lutools/src/ai/windows_file_changes.h:108-135`。
   照片监听最多 128 个，只按最近使用淘汰，会话关闭时不释放，每个持有一个打开的文件或目录句柄。
   推测会导致存储卡无法安全弹出，需在 Windows 上验证。
6. **Windows 判断"是否 SDR 色彩配置"用的是描述文字里的子串**：
   `lutools/src/platform/display_image_windows.cpp:944-952`。"pq"、"hdr"、"extended" 等会误伤
   （例如描述里带 "Compaq" 的配置）；对 v4 配置的 `mluc`（UTF-16）又完全匹配不到。
7. **Windows 扫描 PNG 时把图像数据整段读一遍**：`lutools/src/platform/display_image_windows.cpp:166-174`、
   `:357-358` 的 `skip` 是读取丢弃而不是移动文件指针，大 PNG 在解码前多读一遍全文件。
8. **AI 模型包的校验是"清单与文件互相印证"**：`lutools/src/ai/model_package.cpp:58-67`、`:76-82`。
   清单本身没有被固定摘要或签名约束，能防下载损坏，防不了本地替换。
   另外 `raw/isp/rgb.onnx` 没有做符号链接检查（`:80`），而 `blind_rgb.onnx`（`:103`）和
   Core ML 资源（`:33`、`:39`）做了，三处不一致。
9. **`sceneRGBCorrection` 每块重新分配约 4.9 MB 的输入张量**：`lutools/src/ai/scene_rgb_adapter.cpp:40-41`；
   `runTiles` 是复用的（`lutools/src/ai/dualdn_geometry.cpp:123`）。
10. **`validate_sppa` 每次调用都重新解析内置 JSON**：`lutools/x3f-bridge/src/native_settings.rs:68-70`；
    `dp1s.rs:171-178` 用了一次性初始化，可以对齐。
11. **`dp1s.rs` 的 `interpolate` 遇到 NaN 会 panic**：`lutools/x3f-bridge/src/dp1s.rs:53-64`。
    只有增益乘场景值溢出成无穷时才可能出现，且外层有 `catch_unwind`，后果只是这次解码报错。

#### 14.2.4 读过后确认没问题、不要改动的地方

- **三套照片着色器的逐点公式一致**：中性显示曲线、F-Log 和 F-Log2 的常数与分段点、LUT 域归一化与三线性、
  高光阴影、旧版曲线、自定义曲线、对比度饱和度、黑白点、自然饱和度、HSL、调色，在 Metal、GLES、D3D11
  之间以及与 CPU 之间系数、顺序、钳制范围一致。黑白点、自然饱和度、调色、曲线求值三端共用同一段着色器文本，
  这个做法应保留。
- **GLES 精度**：三个计算着色器都没有 `mediump`，`gles_photo_shader.h:8-9` 和 `gles_denoise.cpp:42-43`
  显式声明高精度。
- **GLES 分块上传的行范围**：`gles_photo.cpp:222-250` 上下各多留一行，足以覆盖 GPU 与 CPU 的浮点取整差异。
- **小波与引导滤波着色器**：Metal 版与 GLES/D3D11 共用体在滤波系数、边界、阈值公式上一致。
- **暗角与颗粒**：Metal、共用着色器体、CPU（`photo_effects.cpp`）公式、哈希常数、归一化一致。
- **DCP 着色器的查表下标与 CPU 一致**（`dcp_look.cpp:150-153`），加载时强制饱和度分格不少于 2，不会下溢。
- **`hdr_metadata.cpp` 的边界检查**（C28 的累计上限除外）：JPEG 分段扫描、Apple 厂商注释解析、ICC 分片拼装、
  XMP 解析都在界内；目录访问有去重和深度上限，不会死循环。
- **`hdr_heif_color.cpp`**：盒子解析每次读取都有界，循环必然前进；各传递函数的分段点和基色坐标核对无误。
- **`display_image_windows.cpp` 的其余扫描**（C27 除外）：PNG、TIFF、MPF 缩略图、ICC 标签表的长度与偏移检查完整，
  元数据总量有 16 MiB 预算，像素数有上限。
- **`hdr_image_apple.mm`**：分条读像素的步长与长度校验、系统对象的释放、临时文件的清理、
  发布前再次核对源文件校验值都正确。
- **AI 几何与分块**：`runTiles`、`packBayer`、`unpackBayer`、`pairBayerMosaics` 的下标都在界内，
  模型输出的尺寸和有限性逐块校验，取消在每块前后检查。Core ML 资源的路径穿越、符号链接、未登记文件检查完整。
- **X3F 桥接**：`settings.rs` 和 `native_settings.rs` 对文件数据的访问全部先验长度或用带检查的切片，
  损坏文件只会返回错误；不支持的已存调整会明确报错；`lib.rs:190` 的 `catch_unwind` 有效。

#### 14.2.5 这个方向仍然没有覆盖到的

- **着色器**：`metal_dcp_shader.h` 的 HSV 往返与影调曲线没有逐行对照 `dcp_look.cpp`；
  `metal_sharpen_shader.h` 没有与 CPU 对照（该功能按 C23 没有调用方）；小波和引导滤波着色器没有与
  `wavelet_denoise.cpp`、`chroma_denoise.cpp` 的 CPU 实现逐行对照；D3D11 常量缓冲与 C++ 结构体的字段布局
  没有逐字段核对；`denoise.cpp` 没有读。
- **平台**：`display_image_windows.cpp` 第 1040 行之后（色彩来源处理、解码）没有读。
- **AI**：几个头文件和 `model_sha256.cpp` 没有单独打开；这些模块抛出的异常在 `ai_session.cpp` 里如何转成提示
  没有复读；`loadModelPackage` 是否每次都重算全部模型文件的校验值没有确认。
- **iOS 打包脚本**：`lutools/platform/ios/dng-jxl.sh`、`raw-compatibility.sh` 等没有读。
- **需要运行才能确定的**：C27 的崩溃可行性、14.2.3 第 2、5 条的系统行为、所有内存和耗时数字。

### 14.3 iOS 与 `Shared/`

补读范围：调整复制粘贴的字段规则、相机联机导入、编辑规则与草稿及重置流程、`Shared/` 里此前没细读的模型代码；
界面层只取样。I16、I18、I19 里"是否与 Mac 一致"都没有核对（这次没读 Mac 端）。

#### 14.3.1 新的主要发现

**I12 相机导入清单每存一张照片就整份重写约 4 次**

- 严重度：中｜确认程度：写入方式已复核，写入量为估算
- 位置：`RawLab/RawLab/Core/Camera/CameraOriginalStore.swift:213-231`（整份编码、写临时文件、落盘、改名、再同步目录）、
  `:309-323`（`begin` 1 次）、`:324-385`（`complete` 最多 3 次）；
  `RawLab/RawLab/Core/Camera/CameraWorkspaceBackend.swift:334-357`
- 问题：清单是单个 JSON 文件，任务的全部条目入队时就写进去，之后每张照片的每次状态变化都把整份清单重写并落盘。
  清单又只增不减（见 I1 第 4 点），历史越长每次越贵。按每条约 500 字节估算，一次 2000 张的增量导入
  约产生 8000 次整份重写、约 8 到 10 GB 写入。另外 `complete` 在 `:329` 把刚下载的文件再整读一遍算校验值，
  而下载时已经算过一次（`RawLab/RawLab/Core/Camera/SonyCameraSession.swift:183-206`）。
- 整改方向：条目状态改成追加式日志或按任务分文件；至少去掉 `begin` 那次落盘，把 `sourceDigest` 与 `prepared` 合并成一次。
  这条与 X1、X5 是同一类问题。
- 验收：导入 N 张时清单写入次数与写入字节数随 N 线性增长；`RawLab/tests/CameraOriginalStoreTests.swift`
  的中断恢复用例仍通过。

**I13 一个坏文件会让整次增量导入停在原地**

- 严重度：中｜确认程度：中断逻辑已复核，其余已读
- 位置：`RawLab/RawLab/Core/Camera/CameraWorkspaceBackend.swift:334-357`（任一张失败就中断并抛出）、
  `:126-137`（除两种错误外一律断开连接）；`RawLab/RawLab/Core/Camera/CameraOriginalStore.swift:29`、`:40-50`
  （待处理条目包含失败条目）；`RawLab/RawLab/UI/Camera/IOSCameraIncrementalImport.swift:44-53`、`:181-189`
- 问题：某张照片有持续性的错误时（文件头与扩展名不符、相机对该文件返回错误、JPEG 无法按设置重编码），
  连接被直接断开。重连后"继续未完成"按原顺序从同一张重试，再次失败、再次断开，没有跳过的办法。
  "开始新的增量导入"重新扫描后仍会把这张排进去，它后面的照片都导不进来，除非用户自己把起点挪到它之后。
- 整改方向：单张校验类错误只标记该条失败并继续后面的；只有连接级错误才中断；界面给"跳过此文件"。
- 验收：用假相机让第 k 张文件头校验失败，第 k+1 张起仍然保存，任务显示 1 张失败，连接不断，再次继续不会死循环。

**I14 换一次连接，增量导入就不认之前的进度**

- 严重度：中｜确认程度：行为已复核；是否有意为之（安全优先）需要确认
- 位置：`RawLab/RawLab/Core/Camera/SonyCameraSession.swift:8`（每次连接新的 `id`）；
  `RawLab/RawLab/Core/Camera/CameraIncrementalImport.swift:76-84`（边界必须 `owner` 相同才算确认，
  代码注释写明"卡槽和照片元数据不足以确认重连后的存储卡"）；
  `RawLab/RawLab/UI/Camera/IOSCameraController.swift:281-284`；
  `RawLab/RawLab/Core/Camera/CameraOriginalStore.swift:133-141`、`:344-356`（整张下载完才按校验值去重）
- 问题：边界和"已保存"集合都绑定在单次连接的标识上。只要断开重连，上次完成的边界就判为"无法确认"，
  界面要求重新选起点（默认是相机时间当天零点，没有用上次边界的日期）。自选起点后不再排除已导入的文件，
  这些文件会经无线完整重下一遍，下载完才发现"已在本机"。一天内多次连接拍摄时，每次都要重传当天已导入的全部照片。
- 整改方向：若坚持"不信任卡"，至少把上次边界日期作为默认起点；更进一步，用文件名、大小、时间加上已保存的
  源校验值做便宜的抽样核对（例如只比对开头一段），通过就跳过下载。
- 验收：同一张卡重连后，默认起点等于上次边界；已导入文件不产生整文件下载（可按传输字节数断言）。

**I15 卡上照片超过上限时整张卡列不出来，提示还是"校验未通过"**

- 严重度：中偏低｜确认程度：上限已复核；实际触发频率为推测
- 位置：`RawLab/RawLab/Core/Camera/SonyCameraSession.swift:121-132`（最多 100 页 × 100 条，文件数上限 1 万）、
  `:137-143`（旧协议 1 万个句柄）、`:151-152`（出错即关闭连接）；`RawLab/RawLab/UI/Camera/IOSCameraController.swift:397`
- 问题：新协议下，卡上超过 5000 次 RAW+JPEG 拍摄，或条目总数达到 1 万，列表直接抛错并关闭连接，
  浏览和导入都不可用。提示文案是"相机数据或原件校验未通过，已暂停。"，用户无从知道原因是照片太多。
- 整改方向：给出专门提示；增量模式下列到早于起点就停（先确认相机返回顺序），或提高上限、分段列出。
- 验收：假相机提供 12000 条时，要么能列出，要么给出"照片过多"的明确提示且连接仍可用。

**I16 iOS"重置全部调整 / 重置分组"的入口所在代码没有任何调用方**

- 严重度：中｜确认程度：无调用方已复核；界面测试是否仍在执行没有核对
- 位置：`RawLab/RawLab/UI/Editor/ContentView+Panels.swift:553-619`（`toolStrip`，全工程无调用）、
  `:306-363`（`adjustmentHeader`，只在 `:615` 被 `toolStrip` 使用）。`requestEditorReset` 的其余调用点都只传
  `.tool(...)`：`RawLab/RawLab/UI/EditorState/EditorLayout.swift:158`、
  `RawLab/RawLab/UI/Panels/AdjustmentPanels.swift:55`、`:64`、
  `RawLab/RawLab/UI/Editor/ContentView+Helpers.swift:225`、`:229`、`:233`
- 问题：
  1. iOS 当前只能重置"当前工具"。重置全部、重置分组、重置单个 HSL 颜色、重置单个颜色分级分区都没有可达入口
     （HSL 和颜色分级面板自身是否另有重置没有核对）。Mac 是功能参考端。
  2. 为"重置全部"写的整套状态（`RawLab/RawLab/UI/EditorState/EditorDrafts.swift:402-466`、
     `RawLab/RawLab/Core/ViewModel/EditorResetTransaction.swift:167`）实际走不到。
  3. 界面测试仍在引用这个入口：`RawLab/RawLabUITests/EditorV4UITests/NativeControls.swift:58`、`:534-538`、
     `:608`、`:625`，`RawLab/RawLabUITests/HDRPhotoUITests.swift:1085`。
  4. 如果恢复入口还有一处要改：工具工作区打开时，对其他工具或分组的重置会被
     `EditorResetTransaction.swift:139-149` 拦下，提示却是"预览尚未就绪，请稍后重试。"。
  5. HDR 模式下分组重置覆盖不到显示映射参数和相机显影设置，只有"重置全部"能清
     （`RawLab/RawLab/Core/Models/EditorAdjustmentRules.swift:299-327`），而它没有入口。
- 整改方向：先做产品决定。要保留就把入口接回新布局并修第 4 点；不保留就删掉 `toolStrip`、`adjustmentHeader`、
  重置全部的状态和对应界面测试。
- 验收：入口可达且相关界面测试实际执行通过；或死代码与失效测试一并删除。

**I17 打开非"曝光"工具时，从顶部菜单复制、粘贴或查看历史，会被"有未完成草稿"挡住**

- 严重度：中｜确认程度：推演（代码路径已读，是否触发取决于 SwiftUI `onChange` 的回调时序），需真机验证一次
- 位置：`RawLab/RawLab/UI/Editor/ContentView+AdjustmentTransfer.swift:55-69`；
  `RawLab/RawLab/UI/Editor/ContentView.swift:377-378`；`RawLab/RawLab/UI/EditorState/EditorDrafts.swift:56-60`、
  `:148-174`；`RawLab/RawLab/Core/Persistence/IOSAdjustmentTransferSession.swift:123`
- 问题：菜单动作先把工具切到"曝光"并重建草稿，再手动把 `hasAdjustmentDraft` 置为 false。
  但草稿快照变化的观察者随后又把它设回 `draft.isActive`，而只要工具工作区开着这个值就是 true。
  之后弹出的复制或粘贴页检查"当前照片无草稿"失败，报"请先应用或放弃未完成的输入和几何草稿。"。
  原工具恰好是没动过的"曝光"时不触发；菜单里的撤销和重做是同步执行的，不受影响。
- 验证方法：打开"对比度"工具不做修改，点顶部菜单的"复制调整"，看复制页是否可用。
- 整改方向：`hasAdjustmentDraft` 改为"草稿有改动"，或这些动作前直接关闭工具工作区。
- 验收：任意工具打开且无改动时，复制、粘贴到当前照片、历史里的撤销都能完成。

**I18 带配方的普通照片粘贴到 HDR 照片时，不按配方强度换算**

- 严重度：低到中｜确认程度：已读（汇总时确认了这段函数没有引用配方）
- 位置：`Shared/HDRAdjustmentTransfer.swift:83-114`；对照
  `RawLab/RawLab/Core/Models/IOSAdjustmentTransfer.swift:110-116`、`:184-193`（普通目标会换算）
- 问题：配方照片复制出去的曝光、对比度、高光、阴影、饱和度是"配方逻辑值"，实际效果要乘配方强度。
  粘到普通照片时会换算，粘到 HDR 照片时原样写入。例如强度 50%、逻辑曝光 +1.0（实际 +0.5），HDR 目标得到 +1.0。
  触发条件较窄：来源带配方且强度不是 100%，复制范围只含这五项和几何。
  这段在 `Shared/`，Mac 若走同一函数也受影响（没有读 Mac 调用方）。
- 整改方向：HDR 的 `prepare` 对带配方的普通来源按同一公式换算，或直接判为不兼容。
- 验收：在 `RawLab/tests/AdjustmentTransferTests.swift` 加用例：强度 0.5、曝光 1.0 的来源粘到 HDR 目标，
  结果为 0.5 或返回不兼容。

**I19 从普通图片复制后粘到 RAW，会把 RAW 的曝光基准改成"传感器基准"**

- 严重度：低到中｜确认程度：已读；是否是既定的跨端规则没有核对
- 位置：`RawLab/RawLab/Core/Models/IOSAdjustmentTransferValues.swift:46`；`Shared/AdjustmentTransfer.swift:441-447`、
  `:73`；`RawLab/RawLab/Core/Models/IOSAdjustmentTransfer.swift:136-139`、`:39-45`
- 问题：普通图片没有曝光基准，复制时固定写成 `sensor`。粘到 RAW 且范围含"曝光基准"（"全部"范围，
  或自定义范围里保留默认勾选）时，RAW 从默认的"匹配内嵌预览"变成"传感器基准"，亮度基线跟着变。
  白平衡有"不适用"取值可以表达这种情况，曝光基准没有。"仅已修改"范围不受影响。
- 整改方向：给曝光基准加"不适用"语义，或普通来源的这一项在 RAW 目标上不生效。
- 验收：JPEG"全部"复制后粘到 RAW，目标的 `exposureMode` 不变。

#### 14.3.2 对已有发现的证实、推翻或补充

- **I9 证实，问题仍在（已复核）**。"上一轮已复用 `draftBuffer`"在这个基线上不成立：导出 JPEG 的普通图片分支在
  `RawLab/RawLab/Core/ViewModel/IO/RawEditorViewModel+PersistenceAndExport.swift:238`、导出 DNG 的分支在 `:305`，
  都重新调用 `loadRasterBuffer(url:)` 整幅解码；`draftBuffer` 的读取方都不在导出路径上。
  "整幅常驻"这一半也没变：`loadRasterBuffer` 只在 HDR 来源分支用到 `previewLongEdge`
  （`RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor.swift:605-617`），普通图片仍整幅解码并保留。
  I9 原文的行号 `:216`、`:283` 现在是 `:238`、`:305`。
- **X6 证实并收窄范围**：整卡重列只发生在新协议分支（`SonyCameraSession.swift:198`），旧协议分支只对该文件
  前后各查一次。另有一处同类开销：联机恢复时 `originalDigest`（`:175-177`）把已保存的原件整张重下一遍算校验值，
  再重列一次卡，上限 64 张。
- **I10 证实仍在**。补充：HDR 目标每张还会把整份外观文件读出来算一次 SHA-256
  （`RawLab/RawLab/Core/Models/IOSAdjustmentTransfer.swift:64`，实现在 `Shared/HDRSettings.swift:244-249`），属于 X2 一类。
- **I6、I1 第 4 点、10.3 第 8 条、X1（HDR 设置严格解码，`Shared/HDRSettings.swift:527-560`）证实仍在**。
- **I11 补充死代码**：`toolStrip` 与 `adjustmentHeader`（见 I16）；`RawSettings.resettingAdjustments()` 无调用方
  （`RawLab/RawLab/Core/Models/RawSettings.swift:593-600`），而且规则与现行的"重置全部"不同：它保留 `hdr`，
  现行规则会丢掉 `hdr` 和 `proRAWDecodeVersion`（`EditorAdjustmentRules.swift:245-249`）。

#### 14.3.3 次要问题

1. 裁切拖动会反复安排内容不变的预览：几何工具下预览用的设置把裁切清零（`EditorDrafts.swift:62-71`），
   但是否刷新预览比较的是含裁切的设置（`ContentView.swift:377-383`）；`schedulePreviewUpdate` 一进来就把
   `previewRendering` 置 true（`RawEditorViewModel+Rendering.swift:505-534`），使 `:103` 的去重失效。实际开销待确认。
2. 增量导入页每次重绘都重新扫描整份相机列表，拨动起点日期时也是
   （`IOSCameraIncrementalImport.swift:16-19`、`:181-189`；`CameraIncrementalImport.swift:70-115`）。
   1 万个文件时估算每次重绘 0.1 到 0.3 秒。
3. 退出草稿的提示标题固定是"保留这次几何或镜头修改？"，但所有工具的草稿都会弹
   （`ContentView.swift:531`、`EditorDrafts.swift:132-136`）。没有对照 Mac 文案。
4. 粘贴不看处理版本：`source.processingVersion` 只校验取值范围（`Shared/AdjustmentTransfer.swift:422`），
   目标保留自己的版本。不同版本下同一组数值的观感是否不同属于推测。
5. HDR 相机 RAW 的"全部"复制在来源为默认相机显影时不带这一项，目标上已有的自定义相机白平衡和降噪级别会保留
   （`Shared/HDRAdjustmentTransfer.swift:56-59`）。是否有意为之需确认。
6. 普通图片"全部"复制粘到 RAW 时白平衡被改回"拍摄时设置"
   （`RawLab/RawLab/Core/Models/IOSAdjustmentTransferWB.swift:56-69`、`:123-125`）。比 I19 更说得通，一并留意。
7. 滑杆结束时如果编辑器正忙，`setSliderEditing` 直接返回，不结束已开始的交互（`ContentView+Helpers.swift:303-307`），
   之后任何一次 `cancelSliderInteraction` 都会把设置恢复到那次拖动之前。属推演，条件少见。
8. 快门速度显示：0.4 秒会显示成"1/2 s"（`Shared/PhotoInformation.swift:85-87`）。Mac 共用这段代码。
9. 任务条目里存的是英文错误原文（`CameraWorkspaceBackend.swift:349`），界面再用字符串相等判断走哪个流程
   （`IOSCameraIncrementalImport.swift:185-187`）。改一次措辞，旧任务的判断就失效。
10. 一次 PTP 交换最多读 1 万个包（`RawLab/RawLab/Core/Camera/CameraPTPClient.swift:107`、`:145`），
    相机若按小包发送大文件会被判超限并断开。属推测，取决于相机分包大小。
11. `CameraWorkspaceBackend` 里多处 `!run.receiving` 判断（`:360`、`:374`、`:391`、`:399`、`:410`、`:418`）
    在检查时恒为假，无害，但读起来像有并发保护。
12. `DCPCompiler.compile(source:)` 最多读 128 MB 进内存，自己不判断超限（`Shared/DCPCompiler.swift:49-56`），
    依赖核心返回"过大"。
13. `AdjustmentRulerView.configure` 每次界面更新都无条件重绘、重建颜色数组和无障碍动作
    （`RawLab/RawLab/UI/Adjustments/AdjustmentRuler.swift:23-29`、`:107-115`），叠加 I7 后每次重算都会重画可见标尺。
14. `groupNavigation` 在单行模式下也先算按钮宽度，每次重绘至少构建 6 套文字排版对象
    （`EditorLayout.swift:36-44`、`ContentView+Panels.swift:491`）。影响很小。

#### 14.3.4 读过后确认没问题、不要改动的地方

- **相机数据解析的边界检查完整**：读取器、分页与各项预算、旧协议对象、属性表、取景帧边界、取景地址校验
  （`RawLab/RawLab/Core/Camera/CameraProtocol.swift:36-67`、`:168-290`）；PTP 交换的长度、事务号、声明大小核对
  （`CameraPTPClient.swift:106-144`）。
- **网络层**：只连私有 IPv4 且限定无线接口；连接、读、写都有超时，超时即关闭
  （`RawLab/RawLab/Core/Camera/CameraNetwork.swift:35-41`、`:54-106`）。
- **文件名与落盘位置**：文件名校验加按 UUID 分目录存放，没有路径穿越。相机临时文件清理闭环。
- **调整数据包校验严格**：未知字段、取值范围、组合关系都校验（`Shared/AdjustmentTransfer.swift:397-509`）；
  超范围不钳制而是整体拒绝，行为一致。
- **HDR 与普通模式之间不会串**：HDR 专属字段出现在普通数据包里会被拒；HDR 到普通只放行公共项；
  普通到 HDR 拒绝影调、颜色、效果、细节。
- **工具草稿模型**：`EditorToolDraft` 的更新、撤销、重做和"只投影本工具字段"使已提交设置被撤销或粘贴改掉时
  不会被旧草稿盖回去（`RawLab/RawLab/Core/Models/EditorToolDraft.swift:42-125`）。
- **撤销后界面会回退**；**手势结束不漏提交**（标尺结束、取消、离开窗口、失去焦点都会通知）。
- **缓存键完整**：`RecipeWhiteBalanceCache` 的键含路径、大小、修改时间、文件号、处理版本、X3F 模式。
- **曲线、HSL、颜色分级解码都做合法性检查**；`makeHDRRequest` 按处理版本逐级填结构体，没有发现问题。

#### 14.3.5 这个方向仍然没有覆盖到的

- **完全没读**：`Shared/LUTCompatibility*`、`Shared/ExportMetadata.swift`、`Shared/CropOverlay.swift`、
  几何与镜头控件、`ExportSizePicker.swift`、`AdjustmentScale.swift`，以及 `Shared/` 下曲线、色轮、HSL 的界面文件。
- **相机**：`IOSCameraConnection.swift`（连接握手）、`CameraOriginalStore.swift:436-537`（联机恢复与登记）、
  `IOSCameraBrowser.swift`、`IOSCameraTether.swift`、`IOSCameraWorkspace.swift` 没读。
- **调整传输**：`IOSAdjustmentTransferSession.swift` 只做了关键字检索；预设相关界面和
  `Shared/AdjustmentPresetStore.swift` 没读，预设库的版本迁移和容错没有结论。
- **只读了片段**：`RawSettings.swift`、`RawEditorViewModel+Rendering.swift`、`ContentView.swift`、
  `ContentView+Helpers.swift`、`AdjustmentPanels.swift`。
- **工程配置和测试**：scheme 文件、构建阶段脚本、测试断言质量都没看。
- **没有运行验证**：I17 需要真机走一遍；I12 的写入量、14.3.3 第 1、2 条的耗时都是估算。

### 14.4 Android

补读范围：相机联机导入与联机拍摄、调整复制粘贴的字段规则、设置的编解码与迁移、编辑规则与重置、
外观库与外部图片校验、几个原生头文件；界面重组只取样。
本节沿用第 7 节的写法：`J/` = `RawLabAndroid/app/src/main/java/com/rawlab/android/`，
`N/` = `RawLabAndroid/app/src/main/cpp/`。

A11、A12、A13 与 iOS 的 I13、I14、I15 是同一类问题，A17、A18 与 I18、I19 相同，整改时应四端一起定规则。

#### 14.4.1 新的主要发现

**A11 相机导入：一张持续出错的照片会让整次导入停住，增量模式下没有跳过的办法**

- 严重度：中｜确认程度：队列逻辑已复核，其余已读
- 位置：`J/camera/CameraImportQueue.kt:13-36`；`J/camera/CameraImportViewModel.kt:509-515`、`:524-528`；
  `J/camera/CameraIncrementalImport.kt:92-99`；`J/camera/CameraImportStore.kt:196-199`、`:359-363`
- 问题：队列按顺序逐张下载，只跳过"相机上已不存在"的条目。除"带增益图"和"内存不足"外，
  任何单张错误都直接抛出，整个任务暂停并主动断开连接。单张错误包括：相机对这张文件返回错误码、
  文件头与扩展名不符、文件名不合规、开了"调整 JPEG"后手机解不开这张图。
  增量模式按拍摄时间升序排队，坏文件之后的照片全部轮不到；重连后新一轮扫描仍把它排在原位。
  能绕开的办法只有手动选一个更晚的起始日期，或改用手动选片，界面没有提示。
- 整改方向：区分"连接级错误"和"单张错误"。单张错误记到该条目上（类似现有的 `problem` 字段），继续下一张，
  不断开连接；任务结束时标明"有 N 张未导入"，任务页给重试和跳过入口。增量检查点不要悄悄越过被跳过的文件。
- 验收：补测试：队列中间一张下载或发布抛错时，后面的照片仍然导入，任务以"部分完成"结束，连接不断开。

**A12 相机导入：断开重连后不认上次进度**

- 严重度：中｜确认程度：已读；属有意的保守设计，这一判断只来自代码注释
- 位置：`J/camera/CameraImportViewModel.kt:319`、`:66-77`、`:476-479`、`:588-589`；
  `J/camera/CameraIncrementalImport.kt:77-85`、`:127-141`（重点 `:138`）；`J/camera/CameraImportStore.kt:199`、
  `:203-216`；`J/camera/CameraTetherQueue.kt:50-55`、`:93-94`；
  `RawLabAndroid/app/src/main/res/values-b+zh+Hans/strings.xml:179`、`:188`
- 问题：
  1. 每次连接成功都生成一个新的随机"会话标记"，增量检查点只有标记相同才算数。重连后只要有过检查点，
     就要求用户重新选起始日期。
  2. 选了起始日期后"已保存"集合被置空，该日期之后的照片全部整张重新下载，下载完算出校验值才发现重复。
     估算：上午导入 300 张、每张 25 MB，下午重连要白下约 7.5 GB。
  3. 没传完的任务跨连接续传时，要求每张未保存的照片已有校验值（`:138`），而从没下载过的照片不可能有。
     所以手动任务重连后点"继续"必然报"相机上的照片已变化或不属于这台相机，请重新挑选"。
  4. 失败时的提示却是"请重新连接后继续"，两句文案互相矛盾。切到后台也会触发断开，所以这条很容易遇到。
  5. 联机拍摄续接时，会把已保存的照片从相机整张重新下载一遍来核对，上限 64 张或 2 GB；超过就不能续接。
- 整改方向（要先做产品决定）：导入时多存一份便宜的身份凭据，例如首块数据的校验值加文件名、大小、拍摄时间，
  重连后只下一块就能确认是同一个文件；允许"文件名、大小、时间、卡槽都一致"的未下载条目续传；
  至少先把两句文案对齐。
- 验收：补测试：重连后已导入的照片不再整张下载；未完成的手动任务可以继续，或者提示与实际行为一致。

**A13 卡上文件超过上限时整张卡列不出来，提示是"相机连接已断开"**

- 严重度：中｜确认程度：上限已复核，其余已读
- 位置：`J/camera/protocol/SonyMobileSession.java:87-98`；`J/camera/protocol/SonyTetherSession.java:215-216`、
  `:450-460`；`J/camera/CameraImportViewModel.kt:310`、`:335-336`、`:349`；`J/camera/CameraTetherJournal.kt:72`
- 问题：列表最多翻 100 页、每页 100 条，照片文件数超过 10000 就抛错。RAW+JPEG 双存时一条记录算两个文件，
  约 5001 组就会触发；视频也占页数。按每组 45 MB 估算，一张 256 GB 的卡就能装到这个数。
  抛错后被当成"连接断开"处理并真的断开，用户看不出是照片太多。联机拍摄同样有 10000 上限，报的是"连接未完成"。
- 整改方向：超限时不要整体失败，改为只列最近的 N 张并明确提示；或按内容条数而不是文件数计上限。
  增加专门的失败原因和文案。
- 验收：用假会话返回 10001 个文件，界面给出"照片过多"的提示，连接保持。

**A14 联机拍摄：按过快门后断线或切后台，之后点"重新连接"必然在约 35 秒后再次失败**

- 严重度：中｜确认程度：结束等待的条件已复核，其余已读（未运行）
- 位置：`J/camera/CameraTetherController.kt:51`、`:118`、`:128`、`:181-182`、`:298`、`:307-313`、`:416-417`；
  `J/camera/CameraTetherQueue.kt:43`；`J/camera/CameraTetherJournal.kt:55`；`J/camera/CameraTetherScreen.kt:145-146`、`:341`
- 问题：按快门时把"已请求快门"的时间写进记录。如果照片没收到就断开（Wi-Fi 掉线、切后台、35 秒超时），
  这个标记留在记录里。续接时界面进入"等待"状态，快门不可用；清除标记的唯一条件是"本次连接里确认过的快门请求
  收到了新照片"，而续接的连接里这个条件永远为假。续接还会把卡上现有照片全部并入基线，所以那张"结果未知"的照片
  也不会再被当成新照片接收。结果是等 35 秒后再次报"拍摄结果未知"，界面仍显示"重新连接"按钮，再点就再循环一次。
  注释说需要"人工确认"，但代码里没有任何确认入口，只能"更换相机"或回首页新开一轮。
- 整改方向：续接时如果带着这个标记，就明确提示"上一张的结果请到相机上核对"并清掉标记；或提供确认按钮。
  至少在这个状态下不要把"重新连接"当成续接。
- 验收：补测试：带快门标记的记录续接后能回到"就绪"，不会 35 秒后再次失败。

**A15 联机拍摄空闲时每 1.5 秒把整张卡重列一遍并全量核对；旧协议机型每次逐个对象查询**

- 严重度：中｜确认程度：已读；单次耗时未测
- 位置：`J/camera/CameraTetherController.kt:132-133`、`:166-171`、`:419-423`；
  `J/camera/CameraTetherTransport.kt:31-36`、`:47-54`、`:125-138`；
  `J/camera/protocol/SonyTetherSession.java:447-461`、`:480-482`、`:203-205`、`:222-229`；
  `J/camera/protocol/SonyLegacyImportSession.java:37`；`J/camera/CameraTetherJournal.kt:33-37`、`:58-75`、`:119-132`
- 问题：
  1. 新协议机型：主循环每 250 毫秒转一圈，距上次核对满 1.5 秒就重列整卡（每页 100 条逐页往返），
     再把全部照片做一遍身份核对。卡上几千张时列表本身可能就超过 1.5 秒，等于一直在列；循环被占住，
     快门请求要等这一轮结束。
  2. 每收一张照片后还要再整卡列一次（`SonyTetherSession.java:480-482`），与 X6 是同一种写法。
  3. 旧协议机型：每 2 分钟或每拍一张，就停掉取景、关掉遥控会话、新开内容会话（固定等 3.5 秒）、
     对卡上每个对象各发一次查询、再重建遥控会话（再等 3.5 秒）。`listLegacyPhotos` 有"跳过已知对象"的参数，
     但正式代码没有用它。
- 整改方向：轮询只取"上次游标之后"的新条目；下载后的核对只查该照片所在页。旧协议把已知对象编号作为基线传入。
  注意 `reserve` 目前要求"以前见过的照片必须全部还在当前列表里"，改增量时这条约定要一起调整。
- 验收：用假会话统计往返次数，空闲 1 分钟内的列表请求数不随卡上张数增长。

**A16 一个读不出的相机日志让相机导入和联机拍摄整体不可用**

- 严重度：低到中（触发少，后果是整个功能不可用）｜确认程度：读取方式已复核，其余已读
- 位置：`J/camera/CameraImportStore.kt:297-299`、`:301-335`、`:113`、`:203`、`:128-134`、`:271-295`；
  `J/camera/CameraTetherJournal.kt:77-97`；`J/camera/CameraImportViewModel.kt:142-149`；
  `J/camera/CameraTetherController.kt:207-208`、`:260`
- 问题：`readJobs()` 把目录里所有任务日志逐个严格解析，任何一个抛错就整体失败；新建任务和每张照片发布时的去重
  也走它。后果：历史不显示；开始导入时报"无法保存导入记录或原件。请检查可用空间后重试"（与真实原因无关）；
  联机拍摄启动失败。联机记录的 `load()` 同样一坏全坏。应用内没有恢复入口。
  可能读不出的情况：版本号或枚举值是别的版本写的、文件损坏、单个日志超过 8 MB（写入时不查大小而读取时查）。
  X5 的隔离整改只覆盖了批量任务日志，相机这两处还是老样子。
- 整改方向：逐个文件捕获，坏日志标成"无法读取，可放弃"，其他任务照常。注意 `load()` 会把"没被任何日志引用"的媒体
  交给 `cleanupOrphans` 清理（`:131-132`），跳过坏日志时这一步也要跳过，否则可能误删。
- 验收：补测试：目录里放一个损坏日志，其他任务仍可见、可新建导入、清理不误删。

**A17 带配方（强度不是 100%）的普通照片粘贴到 HDR 照片时不按配方强度换算**

- 严重度：中｜确认程度：已读（汇总时看过这几行，HDR 分支直接用取到的值）
- 位置：`J/adjustments/AdjustmentTransfer.kt:237-241`，对照 `:154-163` 与 `J/settings/HDRSettings.kt:213-220`
- 问题：与 I18 相同。粘到普通照片时，曝光、对比度、高光、阴影、饱和度都先乘上来源的配方强度（`sourceEffective`），
  粘到 HDR 照片的分支直接用原值。同一处"普通转 HDR 模式"的初始化（`HDRSettings.from`）是乘了配方强度的，
  说明粘贴这里是遗漏。只在自定义勾选这五项加几何时发生。
- 整改方向：`prepareHDR` 对来自普通照片的这五个字段先过 `sourceEffective` 再写入。
- 验收：在跨端共享的测试向量里加一条"配方强度 0.5 的普通照片粘到 HDR"，四端一起对。

**A18 从普通图片复制"全部"粘到 RAW，会把 RAW 的曝光基准改成 sensor**

- 严重度：中｜确认程度：取值已复核，其余已读
- 位置：`J/adjustments/AdjustmentTransferValues.kt:71`；`J/adjustments/AdjustmentTransfer.kt:53`、`:131-134`；
  `J/adjustments/AdjustmentPayload.kt:75`；默认值 `J/settings/EditSettings.kt:48`
- 问题：与 I19 相同。普通图片没有曝光基准，取值时固定写成 "sensor"，校验还强制它必须是 "sensor"。
  "全部"范围包含这个字段，粘到 RAW 时目标的 `exposureMode` 被改成 2（RAW 默认是 1），画面亮度随之变化，没有任何提示。
- 整改方向：来源不是 RAW 时不带这个字段；或粘贴时发现来源不是 RAW 就保留目标的曝光基准。四端规则一起定。
- 验收：补测试：普通图片"全部"粘到 RAW 后 `exposureMode` 不变。

**A19 普通模式下"重置全部"会丢掉未启用的 HDR 调整，"全部"的已修改标记也会一直亮**

- 严重度：低到中（是否符合预期要对照 Mac 决定）｜确认程度：已读（未运行）
- 位置：`J/editor/EditorViewModel.kt:1117`；`J/editor/EditorAdjustmentRules.kt:54`、`:89-91`、`:138-140`、`:150`；
  对照 `J/settings/HDRSettings.kt:274-275`、`:291-293` 与 `J/settings/EditSettings.kt:88-90`
- 问题：重置用的"默认值"是一个空的 `EditSettings()`，不是这张照片自己的默认值，与 `:54` 的注释不符。
  支持 HDR 的照片切到普通模式后，HDR 那一份调整仍保存在记录里；此时点"重置全部"，结果里 `hdr` 为空，
  那份调整被丢弃。反过来不对称：HDR 模式下"重置全部"会保留普通模式那份快照。
  另外只要有那份未启用的 HDR 记录，"全部"就一直被判为"已修改"，即使普通模式的参数都是默认值。
  iOS 的现行规则同样会丢掉 `hdr`（见 14.3.2 的 I11 补充）。
- 整改方向：对照 Mac 决定预期。若应保留：重置时沿用当前记录的 `hdr` 与 `proRAWDecodeVersion`，
  判断"已修改"时不比较未启用的那份。
- 验收：补测试：普通模式重置全部后切回 HDR，原 HDR 调整仍在（或按决定的行为）；参数全默认时"全部"不显示已修改。

**A20 每次列出外观都把所有导入的 LUT 校验一遍；使用导入外观时每次取文件都要加文件锁并读两遍索引**

- 严重度：低到中｜确认程度：调用结构已读；原生校验是否完整解析没有读，耗时未测
- 位置：`J/looks/LookLibrary.kt:55-63`、`:138-140`、`:145-153`、`:155-177`；`J/photo/PhotoStorage.kt:237`、
  `:355-357`、`:369-371`；`J/editor/render/EditorWork.kt:160`、`:191`、`:195`、`:199`；
  `J/editor/EditorAdjustmentTransfer.kt:49`
- 问题：`list()` 对登记表里每个外观都调用一次原生校验，打开编辑器、导入、改名、删除、每次粘贴预检都会走一遍。
  如果校验是完整解析（C11 提到 LUT 文本解析慢），导入几十个 65 格 LUT 后每次都是秒级。
  另外每个操作（包括渲染路径上的 `fileFor`）都要打开锁文件、加进程间文件锁、读索引、列两次目录做残留清理、
  再读一次索引。
- 整改方向：校验结果按文件大小和修改时间缓存，或只在导入和实际使用时校验；索引在内存里缓存，
  残留清理每个进程只做一次。
- 验收：导入 30 个 LUT 后测一次改名和打开编辑器的耗时；补"外观文件被外部删除后能发现"的测试，防止缓存掩盖变化。

#### 14.4.2 对已有发现的证实、推翻或补充

没有推翻任何已有发现。

- **X6 证实并扩大**：联机拍摄的会话也是"每传完一张整卡重列"（`J/camera/protocol/SonyTetherSession.java:480-482`），
  另有空闲轮询，见 A15。旧协议下载只查单个对象，没有这个问题。
- **A1 证实仍在**。补充：联机记录目录 `camera-tether-runs` 同样只增不减，没有任何删除代码；
  每条记录带整张卡的基线清单，每次启动全部读入（`J/camera/CameraTetherJournal.kt:77`）。
- **X5 补充**：批量日志的隔离没有覆盖相机的两个日志目录，见 A16。
- **X1 补充**：Android 编辑记录在新基线下已有逐条隔离（`J/settings/EditPersistence.kt:213-233`），
  迁移回执解不出时只丢回执不丢记录。同类"一条坏全坏"还剩两处：预设库
  （`J/presets/AdjustmentPresetStore.kt:108-138`，连新建也失败）和外观索引（见 14.4.3 第 5 条）。
- **A5、X3 补充**：粘贴预检每个目标读两次整份记录（`J/editor/EditorAdjustmentTransfer.kt:65` 与
  `J/adjustments/AdjustmentTransferSession.kt:95`）；选了镜头字段时每个目标再多一次新建处理器加解码
  （`EditorAdjustmentTransfer.kt:102-110`）。相机导入每张照片在下载之外还有三遍整文件读写
  （`J/camera/CameraImportStore.kt:198`、`:243`、`:244`）。
- **10.4 第 8 条补充**：`CameraImportStore.kt:203` 是"每发布一张照片把全部历史任务日志重新读入并解析一遍"，
  不只是重写。联机记录每拍一张要整份重写 2 到 3 次，每次都带整卡基线。
  iOS 的"清单是单个文件"在 Android 不成立（每个任务一个文件），但"每张重写好几次"成立。
- **10.4 第 2 条补充死代码**：`J/settings/EditSettings.kt:88-90` 的 `reset()`、`J/editor/AdjustmentDraft.kt:72`
  的 `reset()` 在正式代码里没有调用方。
- **R3 补充一例**：曝光的传输取值范围是 ±20（`J/adjustments/AdjustmentField.kt:115`），普通记录只接受 ±5
  （`J/settings/EditSettings.kt:73`），HDR 只接受 ±4（`J/settings/HDRSettings.kt:145`）。越界是拒绝而不是钳制。
- **A2 补充（程度更轻）**：LUT 兼容性预览在缓存目录建 `lut-preview-<随机>`，里面有原片副本（上限 1 GB）和 LUT 副本，
  只在对话框关闭时删除（`J/looks/LUTCompatibilityPreview.kt:51`、`:218`），进程被杀就留下，没有启动清理。

#### 14.4.3 次要问题

1. **相机 JPEG 调整尺寸后丢拍摄信息**：只拷 7 个 EXIF 字段加方向，快门、光圈、ISO、焦距、GPS 都丢；
   导出用的是完整白名单，两处不一致（`J/camera/CameraJPEGProcessing.kt:109-125` 对 `J/format/ExportMetadata.kt:13-37`）。
2. **HDR 相机显影参数只有"重置全部"能复位**：机内白平衡、曝光基准、镜头开关、相机配置文件，分组和单项重置都不碰，
   已修改标记也不反映（`J/editor/EditorAdjustmentRules.kt:161-187`）。是否有意需要确认。iOS 有同样的情况（I16 第 5 点）。
3. **外部 JPEG 可让校验器栈溢出**（已复核）：`nextJpegMarker` 遇到 `FF 00` 递归调用自己，段与段之间连续几十万字节的
   `FF 00` 会抛 `StackOverflowError`，外层只捕获 `IOException`（`J/raster/RasterContainerValidator.kt:227-239`、`:49`）。
   扫描数据段用的是另一个循环写法的函数（`:212-225`），正常照片不会触发，只有构造的文件会。
4. **外部 PNG 的文本块可占大量内存**：单块上限 64 MB，整块读入后再转字符串、转小写找增益图标记，
   瞬时约三倍（估算），内存不足同样不被捕获（`RasterContainerValidator.kt:80`、`:87-89`、`:117`、`:247-250`）。
5. **外观索引写入不做落盘同步，读不出时全部操作失败**，没有恢复入口
   （`J/looks/LookLibrary.kt:247-248`、`:145-157`、`:179-211`）。
6. **普通 JPEG 校验逐字节扫描整个文件**，每个新建的处理器对每张普通图片做一次
   （`RasterContainerValidator.kt:212-225`、`J/raster/RasterImageDecoder.kt:41`），会叠加到批量和粘贴预检上。
7. **像素上限与手机内存不匹配**（估算）：普通图片上限 1.28 亿像素，约 512 MB 位图；16 位 PNG 上限 3200 万像素，
   原生缓冲 256 MB（`RasterContainerValidator.kt:26-27`、`RasterImageDecoder.kt:62-67`、`N/rawlab_jni.cpp:444`）。
8. **下载时每块数据被拷约四次**，每块 3 MB，包头用逐字节读取
   （`J/camera/protocol/SonyMobileSession.java:215-239`、`:260-264`）。
9. **联机取景让整个页面跟着重组**：每帧新建一张位图并更新整个状态对象，`saved`、`pendingCount` 是每次读取都重算的属性
   （`J/camera/CameraTetherController.kt:52-61`、`:385-387`，`J/camera/CameraTetherScreen.kt:60-61`、`:70`）。
10. **编辑页把整个 `EditorState` 传给调整面板**，每帧预览返回都会重组整个面板（取样结论，未测量；
    `J/editor/ui/AdjustmentDock.kt:101`、`:115`、`:128-130`）。
11. **提示与原因不符**：选中的照片里有一张超过 1 GB，整个任务创建失败并提示"检查可用空间"
    （`J/camera/CameraImportStore.kt:106-108`）。
12. **旧协议机型若不支持取缩略图会被当成断线**（是否有这样的机型是推测；`SonyTetherSession.java:233`、
    `SonyLegacyImportSession.java:51-54`）。
13. **翻页游标用拍摄时间**：同一时间戳的内容达到 100 条会报"游标没有前进"而列表失败
    （`SonyMobileSession.java:94-96`、`:143`）。
14. **版本范围写死在多处**：处理版本、HDR 版本、配方设置版本没有引用同一个常量
    （`J/adjustments/AdjustmentPayload.kt:53`、`:61`、`:63`，`J/settings/EditSettings.kt:9`、`:69`）。
15. **调整历史只在会话内累积、每次提交整份复制**，没有上限（`J/adjustments/AdjustmentTransferSession.kt:37`、`:263-271`）。

#### 14.4.4 读过后确认没问题、不要改动的地方

- **相机协议解析的边界检查**：包长度、读取器越界、声明长度与实际长度、操作白名单、属性表与数组上限、
  取景帧偏移与长度、取景地址只接受相机本机地址、流式下载总长核对
  （`SonyMobileSession.java:138-166`、`:191-303`，`SonyTetherSession.java:296-328`、`:589-648`）。
- **超时与断连**：命令通道有读超时；任何读写异常都同时关掉两个通道，不在错位的字节流上继续发命令。
- **快门安全**：按下后在 `finally` 里释放，停止时有 2 秒硬截止；写操作白名单；选片导入会话不能发任何写命令。
- **相机导入的临时文件**：下载暂存文件在 `finally` 里删除；启动时和单任务恢复时清理残留；
  先登记系统相册条目再写入，中途退出可按记录恢复。
- **日志写入方式**：相机任务、联机记录、预设库、草稿都是"临时文件、落盘同步、原子改名"。
- **调整传输的整体规则**：数据包严格校验，越界一律拒绝不钳制；HDR 与普通之间按字段组整体拦截；
  多目标里有一个预检失败时全部先挡住等用户决定。
- **设置编解码**：字段范围、未知字段、HDR 记录版本与结构一致性都严格检查；浮点往返不丢精度
  （`J/settings/StructuredSettingsCodec.kt:48-98`、`:155-233`）。
- **ICC 与 16 位 PNG**：标签表偏移和大小、曲线采样数、解压上限都有检查；`N/png16_color.h` 的下标不会越界。
- **原生头文件**：`N/render_request.h` 的参数范围和缓冲大小检查、`N/recipe_white_balance_cache.h` 的缓存键都合理。
- **`RawLabAndroid/scripts/fetch-rum-sdk.sh`**：只走 HTTPS，下载后比对 SHA-256，不符即删除并失败。
- **外观导入**：有事务标记和残留清理，失败不留半成品。

#### 14.4.5 这个方向仍然没有覆盖到的

- **相机**：`SonyCameraConnection.kt`（蓝牙与 Wi-Fi 连接，845 行）、`CameraConnectionPanel.kt`、`CameraImportSettings.kt`、
  `SonyCameraModel.kt` 等没读；`MediaPhotoLibrary.kt` 的 `cleanupOrphans` 实现没读；相机相关单元测试没读。
- **调整传输**：`AdjustmentTransferWB.kt`、`AdjustmentTransferRefinement.kt` 读了但没有逐分支对照共享测试向量推演；
  `AdjustmentSummary.kt` 及相关界面没读。
- **设置**：`HslTargetAdjustment.kt`、`ColorGradingSettings.kt`、`ToneCurveSettings.kt`、`GeometrySettings.kt` 没读；
  `EditPersistence.kt` 只检索了异常处理位置。
- **编辑器**：`EditorViewModel.kt` 只读了片段，重置和草稿在界面上的完整流程没有走查。
- **其他**：`LUTCompatibilityDialog.kt`、`MpfThumbnails.kt`、`C2paJpegMetadata.kt`、`N/png16_decoder.h` 没读；
  `N/rawlab_jni.cpp` 只读了一小段；`NativeProcessor.validateLook` 的原生实现没读（影响 A20 的耗时判断）。
- **界面重组**：只取样，`ToneCurveControls.kt` 和 `BatchExportScreen.kt` 没有结论。测试断言质量没有取样。

### 14.5 Windows

补读范围：调整复制粘贴与预设的字段规则、编辑规则与重置、HDR 设置读写、LUT 兼容导入、
`AgentRecipe.cs` 与 `PhotoInfo.cs`、六个构建与依赖脚本；界面逻辑取样读了 9 个文件。
本节同一条里重复出现的文件，第二次起只写文件名，目录都在 `RawLabWindows/` 下。

iOS 和 Android 上确认的复制粘贴两条在 Windows 都一样（W11、W12）；
Android 的"普通模式重置全部会丢 HDR 调整"在 Windows 也一样（W13）。

#### 14.5.1 新的主要发现

**W11 非 RAW 照片的调整粘到 RAW，会把曝光基准改成 sensor，并把白平衡改回相机白平衡**

- 严重度：中｜确认程度：采集和粘贴两处已复核，其余已读
- 位置：采集 `RawLabWindows/AdjustmentTransferValues.cs:61-65`；粘贴曝光基准 `RawLabWindows/AdjustmentTransfer.cs:116-119`；
  粘贴白平衡 `RawLabWindows/AdjustmentTransferWB.cs:38`、`:48`、`:91-101`；范围定义 `RawLabWindows/AdjustmentPayload.cs:178`、
  `:255`、`RawLabWindows/AdjustmentScopeEditor.cs:23`；资料库"应用当前设置" `RawLabWindows/MainWindow/Library.cs:281`；
  对照批量导出的做法 `RawLabWindows/PhotoInput.cs:109-114`
- 问题：来源不是 RAW 时，采集固定写入曝光基准 `"sensor"` 和白平衡 `"none"`，这只是占位值。
  目标是 RAW 时，粘贴把占位值当真：`ExposureMode` 被写成 2，自定义白平衡被改回相机白平衡。
  范围比 I19、A18 报的更大：不只是"全部"，下拉第一项范围（`AdjustmentScope.Standard`）也带这四个字段；
  预设、同步、资料库"应用当前设置"走同一条路。"仅已修改"范围不受影响。
  批量导出遇到"普通图片来源、RAW 目标"时已显式改回 `ExposureMode=1`，粘贴这条路没有同样处理。
- 整改方向：来源不是 RAW 时不产出这四个字段，或粘贴时跳过。跨端一起改，以 Mac 为准。
- 验收：补测试：JPEG 用 Standard 和"全部"范围复制，粘到曝光基准为 preview、白平衡自定义的 RAW，两项保持不变。

**W12 带配方的普通照片粘到 HDR 照片，五项基础调整不按配方强度换算**

- 严重度：中（触发面较窄）｜确认程度：已复核（整个文件没有引用配方）
- 位置：`RawLabWindows/HDRAdjustmentTransfer.cs:9`、`:75-91`；对照普通目标 `RawLabWindows/AdjustmentTransfer.cs:103-107`、
  `:148-159`；对照同一张照片切到 HDR `RawLabWindows/HDRSettings.cs:194-204`；摘要提示 `RawLabWindows/AdjustmentSummary.cs:26-27`
- 问题：与 I18、A17 相同。复制出来的是配方的逻辑值，粘到普通照片会乘强度，粘到 HDR 照片原样写入曝光、对比度、
  高光、阴影、饱和度。强度 50% 的配方，HDR 目标得到两倍效果，而摘要还写着"会按此强度换算"。
  只有自定义范围（只选这五项和几何）才能从普通照片粘到 HDR，其他范围会被整份拒绝；预设和同步同样受影响。
- 整改方向：`PrepareSettings` 对这五项按 `Source.Recipe.Strength` 换算，越界仍按现有规则拒绝。
- 验收：补测试：强度 50%、曝光逻辑值 +0.6 的来源，HDR 目标得到 +0.3。

**W13 普通模式下"重置全部调整"会丢掉未启用的 HDR 调整**

- 严重度：低到中｜确认程度：已复核
- 位置：`RawLabWindows/EditorAdjustmentRules.cs:93-106`、`:162-168`、`:269-274`；`RawLabWindows/EditWorkflow.cs:132`；
  对照 `RawLabWindows/Adjustments.cs:408`
- 问题：与 A19 相同。关掉 HDR 只是把 `Mode` 改成 Sdr，HDR 调整还留着。此时点"重置全部调整"，候选直接取默认值，
  而默认值不含 HDR，`HDR`、`ProRAWDecodeVersion`、`HDRCameraAIEnabled` 一并清空，包括 HDR 外观和相机配置。
  反过来不对称：HDR 模式下重置全部只清 HDR 的值，普通调整、外观、配方都保留。本次会话内可以撤销。
- 整改方向：需要先定规则。要么普通模式重置时保留 HDR 记录，要么两种模式都全清并在确认框写明。跨端一致，以 Mac 为准。
- 验收：按定下的规则补"普通模式重置全部后 HDR 记录的状态"测试。

**W14 批量编辑窗口每次刷新都重建全部行、重新解码全部缩略图，并在界面线程逐张读文件身份**

- 严重度：中（照片多时明显，耗时未测）｜确认程度：刷新触发点已复核，其余已读
- 位置：`RawLabWindows/BatchSelectionWindow.cs:46`、`:49-77`、`:78-81`；`RawLabWindows/BatchSelection.cs:12-16`、`:64-67`；
  `RawLabWindows/MainWindow/BatchSelection.cs:33`、`:38`、`:40`；`RawLabWindows/RenderEngine.cs:610-624`
- 问题：窗口每次被激活都调 `Refresh()`，全选、取消全选、移除、关掉子对话框也都触发。每次刷新清空并重建所有行，
  再为每张照片起一个后台任务解码缩略图，没有缓存、不取消旧任务、不限并发。JPEG 和 HEIC 的缩略图还会先做一次
  HDR 探测（代价见 X2）。每次刷新先调 `RefreshFailures()`，在界面线程对每张照片打开一次文件读身份。
- 整改方向：按照片 ID 复用行，只更新变化的部分；缩略图按文件身份缓存，或复用资料库已有的；
  刷新和关闭时取消旧任务；身份校验放后台。
- 验收：300 张照片的集合反复切换窗口焦点，不再出现新的解码任务，界面线程没有逐张文件打开。

**W15 LUT 兼容导入预览：只读的照片或 LUT 会让预览一直失败，并在临时目录留下整张照片的副本**

- 严重度：低到中｜确认程度：代码已复核；触发后果依赖 .NET 的删除行为，没有实测
- 位置：`RawLabWindows/LUTCompatibilityPreview.cs:56`、`:67`、`:117-122`、`:133-136`、`:145-149`
- 问题：预览开始时把 LUT 和整张照片复制到临时目录，`File.Copy` 会连只读属性一起复制。
  释放时 `Directory.Delete(directory, true)` 只接 `IOException`，而删除只读文件抛的是 `UnauthorizedAccessException`，接不住。
  `Load` 里先 `worker?.Dispose()` 再置空，异常抛出后 `worker` 仍指向已释放的旧对象，之后每次换照片都在同一处失败，
  只能关掉对话框重开；关闭时的释放同样失败，含整张 RAW 副本的目录留在临时目录。
  相机里"保护"过的照片拷到电脑后带只读属性，这个场景不罕见。
- 整改方向：复制后清掉只读属性；`Dispose` 接住全部文件类异常，并保证先把 `worker` 置空；和 W10 的启动清扫一起做。
- 验收：用只读照片做预览后再换一张，仍能生成；关闭后临时目录被清掉。

**W16 拖动滑杆时每一格都整面刷新检查器，并在界面线程打开一次原片**

- 严重度：中（本地固态盘不明显，网络盘明显；耗时未测）｜确认程度：触发点和读身份已复核，中间调用链已读
- 位置：触发点 `RawLabWindows/MainWindow.xaml.cs:208-214`（普通滑杆每一格）、`RawLabWindows/MainWindow/HslTarget.cs:78-83`
  （HSL 画面取色拖动）、`RawLabWindows/MainWindow.Transform.cs:36-45`（裁切拖动）；调用链
  `RawLabWindows/MainWindow/Tools.cs:368-537` → `:533` → `:250-253` → `:237-249` →
  `RawLabWindows/EditWorkflow.cs:103-104` → `RawLabWindows/WindowsFileIdentity.cs:45-48`
- 问题：和 W6 是同一类问题，但这条路径不依赖对比模式，任何拖动都走。每次刷新还会：对 6 个分组和约 23 个工具
  各算一次"是否已修改"，每次都重建设置对象和默认值（`Tools.cs:253-273`、`RawLabWindows/EditorAdjustmentRules.cs:79-84`、
  `:162-168`、`:328-334`）；刷新全部编辑器，不管是否可见；每个 `ParameterRow.Refresh` 都重新量两次文字宽度
  （`RawLabWindows/ParameterRow.cs:93-101`、`:136`）。
- 整改方向：文件身份在打开照片时缓存，和 W6 同一处修；拖动期间只刷新当前行，松手后再整面刷新；
  "是否已修改"按设置快照缓存。
- 验收：拖动滑杆时界面线程没有文件打开；网络盘上的照片拖动不顿。

**W17 预设库里一条读不懂的预设让整个预设库不可用**

- 严重度：低到中｜确认程度：已复核｜Android 有同样的问题（见 14.4.2 的 X1 补充）
- 位置：`RawLabWindows/AdjustmentPresetStore.cs:109-138`、`:52-56`、`:71-86`；`RawLabWindows/AdjustmentPayload.cs:172-173`、
  `:350-355`；`RawLabWindows/MainWindow/QuickPresets.cs:113-116`
- 问题：任何一条预设解析或校验失败，整个库读取抛错。新建、覆盖、改名、删除都要先读库，所以全部失败，
  界面只显示一条错误，没有恢复入口。未知字段名和超范围版本号都会触发，装回旧版本后新版本写的预设就是这种情况。
  不覆盖文件是对的，要改的是"其余预设也全部不可用"。
- 整改方向：逐条容错。读不懂的条目原样保留并透传写回，列表里标为"需要更新版本"，其余照常可用。
- 验收：库里混入一条带未知字段的预设，其余可列出、可应用、可新建；坏条目写回后内容不变。

#### 14.5.2 对已有发现的证实、推翻或补充

- **X1（Windows）第 5 点，原文"没有核对"，现在可以下结论**：
  - 一条坏记录不影响其他照片：读取只解析外层，逐条原样保留，只解析被请求的那条，写回时其余透传
    （`RawLabWindows/EditPersistence.cs:193-224`、`:238-254`、`:283-285`、`:298-309`）。
  - 坏的那条是整条作废：任何一个字段不合规都判整条不可用，例如 HDR 子对象多一个未知键
    （`RawLabWindows/HDRSettings.cs:325-328`、`:333-335`、`:355`）。普通调整、外观、几何跟着不可用。
  - 打开这张照片时弹窗，只有"取消"和"重置全部调整"（`RawLabWindows/EditWorkflow.cs:190-195`、`:216-251`）。
    选重置就整条删除（`EditPersistence.cs:316-337`），不留备份，也不区分"来自更新版本"和"损坏"。
  - 建议：删除前把原始内容另存一份；识别出版本号更高时提示升级。
- **X1 第 1–4 点在 Windows 仍然存在**：每次读写都整份读入并把每条记录各克隆一次（`EditPersistence.cs:196`、`:206-209`），
  整份写回（`:309`），都在调用线程上。
- **X2 仍然存在**：`IsHDRContainer` 只看扩展名（`RawLabWindows/PhotoInput.cs:13-16`），缩略图路径也先探测
  （`RawLabWindows/RenderEngine.cs:616`）。
- **X3 仍然存在，并多三处**：粘贴预检每个 RAW 目标新建引擎（`RawLabWindows/MainWindow/AdjustmentCommands.cs:76-79`、
  `:87-90`、`:92-94`）；快速预设每点一次走同一预检（`RawLabWindows/MainWindow/QuickPresets.cs:70`）；
  HDR 相机设置每次"应用"新建引擎（`RawLabWindows/MainWindow.HDR.cs:338-343`）。
- **W4**：全局兜底已经有了（`RawLabWindows/App.xaml.cs:31`、`:47-51`）。仍有一个会漏到兜底的异步入口：
  批量编辑窗口的"同步调整"按钮（`RawLabWindows/BatchSelectionWindow.cs:40-43`）在 try 之外读来源文件身份
  （`RawLabWindows/MainWindow/BatchSelection.cs:108`），来源照片被移走或盘被拔掉时弹的是"未处理异常"对话框。
- **W6**：新增一条更常走的路径，见 W16。
- **W10**：LUT 预览目录在正常释放时也可能删不掉，见 W15。
- **10.5 第 2 条（死代码）补充**：`Adjustments.ResetAll`（`RawLabWindows/Adjustments.cs:373`）和 `Adjustments.ResetGroup`
  （`:362-372`）应用内没有调用，只有测试在用。应用真正的重置走 `EditorAdjustmentRules.PrepareReset`，两套规则不同，
  所以这些测试覆盖的不是上线路径。`ResetEffects`（`:357-359`）应用和测试都没有调用。
  另有应用内没有调用方的：`RenderEngine.AgentRecipe`（`RawLabWindows/AgentRecipe.cs:8`）、`EditStore.Save` 两个重载
  （`EditPersistence.cs:417-438`）、`SaveSettingsCopy` 和 `SaveSettingsCopies`（`EditWorkflow.cs:157-166`）。
- **10.5 第 8 条仍然存在**。

#### 14.5.3 次要问题

1. HDR 模式下，各分组重置都不包含"HDR 输出与 SDR 底图"和"HDR RAW"两组设置，只有"重置全部"能还原
   （`RawLabWindows/EditorAdjustmentRules.cs:272-327`），这两个对话框自己也没有重置入口。
   iOS、Android 有同样的情况。是否有意需确认。
2. 来源开着 AI 降噪时复制"全部"或"仅已修改"直接失败，提示是"所选调整与目标不兼容，请调整范围或跳过目标"。
   复制阶段没有目标，文案不对（`RawLabWindows/AdjustmentTransfer.cs:38-39`、
   `RawLabWindows/AdjustmentTransferPresentation.cs:79`）。
3. "不适用的字段"处理不一致：RAW 的自定义白平衡粘到普通图片是整份拒绝（`RawLabWindows/AdjustmentTransferWB.cs:76-86`），
   镜头校正同理，曝光基准却是忽略。带自定义白平衡的 RAW 预设因此完全不能用在普通图片上。需确认。
4. 粘贴时不比较来源和目标的处理版本（`RawLabWindows/AdjustmentPayload.cs:314`、`:354`）。iOS 相同。
   不同处理版本下同一数值效果是否不同没核对。
5. 外观搜索每敲一个字就重建整条外观列表（`RawLabWindows/MainWindow/LookBrowsing.cs:61-65` → `Tools.cs:320-367`），
   每个外观查两次文件是否存在，并在界面线程同步解码一张封面图，不限解码尺寸。外观多时输入会顿，耗时未测。
6. 选外观后在界面线程带落盘同步地写 `recent-looks.json`（`LookBrowsing.cs:32`），工作区宽度同理
   （`RawLabWindows/MainWindow/Workspace.cs:73`）。文件很小。
7. `RefreshControls` 带副作用：普通图片每次刷新都把 `settings` 换成新克隆，并改 GPU 下拉框（`Tools.cs:378-385`）。
   没发现现成的错误，但异步流程容易拿到旧对象。
8. LUT 兼容对话框每次 `Update()` 都对每个候选整份深拷贝描述数据（`RawLabWindows/LUTCompatibilityDialog.cs:73`、`:106`）。
   数据小，影响低。
9. 批量导出检查对话框一失去焦点就取消检查，切走再回来要重新点（`BatchSelectionWindow.cs:135`、`:174-179`）。看起来是有意的。
10. 构建脚本：
    - `RawLabWindows/build-host-python.ps1:7-12`：缓存的压缩包损坏后不会重新下载，每次都报校验失败，要手工删。
      `build-exiftool.ps1:11-14` 的写法（不匹配就重下）可以照抄。
    - `RawLabWindows/build-exiftool.ps1:5`、`:12`：唯一下载源是个人站点；缓存在各工作区自己的 `build/tools`，
      不是约定的主工作区 `.cache/shared/`。有校验，所以只是可用性和重复下载的问题。
    - `RawLabWindows/build-remote.py:81-82`、`:99-144`：远端和本地的按时间戳目录每次新建，从不清理。
    - `RawLabWindows/scripts/provision-build-tools.ps1:21-25`：.NET SDK 已装也要求安装包在场。

#### 14.5.4 读过后确认没问题、不要改动的地方

- **复制数据的校验**：未知键、重复键、越界一律拒绝，不钳制；外观 ID 拒绝路径分隔符（`AdjustmentPayload.cs:323-414`）。
- **粘贴流程**：先准备后应用，准备阶段不改会话；应用前重新核对文件身份和编辑代次；撤销重做按顺序核对
  （`RawLabWindows/AdjustmentTransferSession.cs:85-141`、`:171-205`）。粘贴结果用真实渲染请求的数值做相等比较，表示不了就拒绝。
- **HDR 与普通之间不会串**（W12 除外）：HDR 专属字段进不了普通照片的复制数据；两个方向都拒绝对方不支持的组；
  HDR 记录版本随粘入字段自动升级；HDR 外观缺文件时拒绝。
- **普通模式的分组重置和单项重置**：覆盖字段和工具分组表一致。外观组重置会先把配方数值落成独立调整，
  并核对最终渲染值不变（`RawLabWindows/EditorAdjustmentRules.cs:117-137`、`:347-356`）。
- **重置事务**：核对文件、打开版本、编辑版本、外观和草稿，过期不提交（`RawLabWindows/EditorResetTransaction.cs:21-23`、`:64-71`）。
- **预设库写入**：原子写、带文件锁，改名覆盖删除先比对期望内容（`AdjustmentPresetStore.cs:52-97`、`:164-173`）。
- **LUT 预览服务**：单线程队列，窗口关闭后排队释放，不会在原生调用运行中释放会话；对话框关闭时取消全部任务。
- **`AgentRecipe.cs` 与核心配方格式**：按关键字对照了几个新增字段，没发现不一致。
- **拖动时的渲染和保存**：渲染请求是合并的，只保留最新一条（`Adjustments.cs:439-449`）；拖动中不落盘。
- **异步流程的过期判断**：预检、快速预设、集合导出检查、HDR 相机预检都用"代次、打开版本、编辑版本、当前文件"判断，
  切换照片或关闭后结果被丢弃。
- **事件订阅**：取样的界面文件里没发现泄漏。
- **构建脚本的下载和凭据**：三处联网下载都固定版本，解压或执行前校验 SHA-256；`provision-build-tools.ps1` 不联网，
  先比对校验值再验签名；`build-remote.py` 严格校验主机密钥，只传密钥文件路径，命令行和日志里没有口令或令牌。

#### 14.5.5 这个方向仍然没有覆盖到的

- **调整传输界面**：`AdjustmentSummaryView.cs` 没读，`AdjustmentScopeEditor.cs`、`AdjustmentPresetDialogs.cs` 只看了几行，
  各确认框的文案没核对。
- **相关流程**：`MainWindow/X3fModeReset.cs`、`MainWindow/ProcessingMigration.cs` 没读；`MainWindow.Commands.cs` 只读了一段。
- **界面**：`SettingsWindow.cs`、`PhotoCanvas.Geometry.cs`、`PhotoCanvas.cs`、`MainWindow/WorkspaceBrowser.cs`、
  `WorkspaceLayout.cs`、`WorkspacePhotoSelection.cs`、全部 XAML 没读。
- **测试**：`NativeTests.cpp` 和其他测试的断言质量没看。
- **没有实测**：W15 的触发后果、W14 和 W16 的耗时。

### 14.6 Mac

补读范围：调整复制粘贴的字段规则、重置规则与入口、更新状态机、`Shared/` 里的预设库、外观库和使用统计、
几个构建脚本；视图层只取样了三个文件。Mac 是参考端，所以这一节先回答"其他三端重复出现的问题在 Mac 上是什么行为"。

本节 Mac 路径省略前缀 `RawLabMac/Sources/`，`Shared/`、`scripts/`、`RawLabMac/tests/` 等写全。

#### 14.6.1 参考端行为：其他端重复出现的问题在 Mac 上怎样

**a. 普通图片复制后粘到 RAW：曝光基准被改成"传感器基准"，自定义白平衡被改回相机白平衡（已复核）**

- 复制时写入占位值：`Adjustments/MacAdjustmentTransferValues.swift:71`（曝光基准固定 `"sensor"`）、
  `:74-76`（白平衡 `"none"`、色温和色调为空）。
- 粘贴曝光基准：`Adjustments/MacAdjustmentTransfer.swift:159-162`，只要数据里带这一项，RAW 目标就写成 `.sensor`。
- 粘贴白平衡：`Adjustments/MacAdjustmentTransferWB.swift:34-45`、`:140`、`:157`，
  "来源不是 RAW 且无配方"直接解析成相机白平衡。
- 受影响的复制范围："全部"、"自定义"的默认勾选、资料库"应用当前设置"
  （`Editor/Model/EditorModel+Workflow.swift:329`）、用这些范围存的预设。"仅已修改"不受影响。
- 复制页把这种白平衡显示为"不适用"（`Shared/AdjustmentTransferSummary.swift:139`、`:147-151`），
  粘贴却当成"相机白平衡"执行。
- **Mac 的测试把曝光基准这条固定为预期**：`RawLabMac/tests/AdjustmentTransferTests.swift:568-570`，
  用例是"显式只选曝光基准、来源是普通图片时，RAW 目标保持 sensor"。要改规则得同时改这条测试。
  注意这条用例是用户显式选了这一项；问题在于"全部"和默认勾选会不声不响地带上它。
- 被改的字段比其他端报的更多，见 M10。

**b. 带配方（强度不是 100%）的普通照片粘到 HDR 照片：不按配方强度换算，五项原样写入（已复核）**

- 目标是 HDR 时，`Adjustments/MacAdjustmentTransfer.swift:78-92` 直接调 `Shared/HDRAdjustmentTransfer.swift:83-114`，
  那段不读配方；目标是普通照片时会换算（`:146`、`:206-217`）。
- 粘贴页只要来源带配方就显示"按实际生效值应用，已包含配方强度。"
  （`Editor/View/AdjustmentTransferView.swift:110-112`），对 HDR 目标这句话不成立。

**c. "重置全部调整"：两种模式各清各的，另一种模式的调整保留（已复核）**

- 普通模式：`Adjustments/Adjustments.swift:453-472` 先存下 `hdr` 和 `hdrCameraAI`，清空后放回。
  **未启用的 HDR 调整保留，iOS、Android、Windows 都与 Mac 不一致。**
- HDR 模式：只调 `hdr?.reset()` 并关掉 HDR 的 AI 降噪，普通模式的调整不动。
- 没有核对的：落盘路径没有重读，以上是内存规则；"无法恢复调整"弹窗走 `resetToUnmodified`
  （`Editor/Model/EditorModel+Workflow.swift:540-556`），会清掉整条记录，触发条件没读全。

**d. HDR 显示映射只有"重置全部"能复位；相机显影另有自己的"重置"按钮，但分组和单项重置都管不到它**

- 显示映射（亮度上限、SDR 底图曝光、对比度、饱和度）的控件在"照片处理设置"面板
  （`Editor/View/EditorView.swift:365-370`、`Shared/Native/HDRMonitoring.swift:33-74`），没有重置按钮，
  `Adjustments.swift:729-760` 的单项和分组分支都不碰它。
- 相机显影面板内有"重置"（`Shared/Native/HDRMonitoring.swift:213-217`）。重置菜单管不到：
  "重置细节组"不清 FBDD 级别（`Adjustments.swift:753-755`），"重置曝光"不清曝光基准，
  "重置几何与镜头组"里的镜头工具在 HDR 下是空操作（`:756-757`）。

**e. 粘贴时不比较处理版本，也不提示，目标保留自己的处理版本**

- `Shared/AdjustmentTransfer.swift:422` 只校验来源版本范围；`Adjustments/MacAdjustmentTransfer.swift:190`
  的注释写明处理版本沿用目标。

**f. Mac 的重置入口**

- 工具栏重置菜单（`Editor/View/EditorView.swift:670-689`）：随当前工具变化的一段
  （颜色分级的"重置当前分区 / 重置颜色分级"，HSL 的"重置当前颜色 / 重置全部 HSL"，其他工具的"重置当前工具"），
  加固定两项"重置分组"、"重置全部调整"。没有改动的项置灰。
- 另有：侧栏工具标题的右键菜单、颜色分级面板内的重置、降噪面板和暗角颗粒面板各自的重置、几何工作区的重置、
  单个滑杆的双击与右键重置、HDR RAW 面板的"重置"。
- 范围共七种（`Adjustments/AdjustmentTypes.swift:391-397`）：工具、分组、单个 HSL 颜色、全部 HSL、
  单个分级分区、全部分级、全部。全部、分组、全部 HSL、全部分级需要二次确认。
- 对照 I16：iOS 目前只有"重置当前工具"可达。

**g. 预设库里一条读不懂的预设：整个预设库不可用，连删除那条坏预设都做不到（已复核）**

- `Shared/AdjustmentPresetStore.swift:170-180` 把整份文件一次严格解码，任何一条不过就整体抛错；
  列出、新建、覆盖、改名、删除都先调这次读取（`:88`、`:94`、`:123`、`:134`）。
- 界面只显示"预设库无法读取，原文件保持不变。请从备份恢复后重试。"，没有应用内的恢复入口。
- 在 Mac 上后果更大：会让更新被判失败，见 M9。

#### 14.6.2 新的主要发现

**M7 安装器还没启动就失败，也被记成"装到一半"**

- 严重度：中（触发概率低，后果重）｜确认程度：先存状态后调安装已复核；哪些情况会触发部分是推测
- 位置：`System/Updates/DesktopUpdateController.swift:265-271`、`:31`、`:33`、`:38-44`、`:56`、`:76-97`；
  `System/Updates/SparkleUpdateAdapter.swift:111-117`；`System/Updates/UpdateState.swift:99-109`；
  `System/Updates/MacUpdateTrust.swift:94-122`；`Presentation/SoftwareUpdateView.swift:68`、`:111`、`:126`
- 问题：控制器先把状态存成 `installing`，再调 `adapter.install`。`install` 的前两步还没把安装交给 Sparkle
  （重新校验本机应用、检查准备好的安装回调是否还在），任一抛错，失败阶段都记成 `installing`。后果：
  1. 编辑区立即被禁用，菜单命令被撤掉；"重试"不显示，"检查更新"置灰，"取消"无效。
  2. "恢复更新前的数据"按钮本次运行内不出现，因为它依赖只在启动时计算的 `recoveryStartup`。
  3. 界面提示"请先安装更新前的同一可信版本，再恢复数据"，而此时运行的就是旧版，什么都没被替换。
  4. 出路是退出、重开、点"恢复更新前的数据"、再退出重开；恢复还会把这个版本标成跳过，并关掉自动安装。
- 触发情况：已确认的是本机校验抛错或回调不在；推测自签名模式下需要应用包在检查更新后被改动、移动或目录变成不可写。
  Developer ID 模式下校验会调 `spctl`，30 秒超时算"临时失败"，安装这里没有区分可重试的错误。
- 与 W7 是同一类问题。
- 整改方向：把这两步前置校验挪到写入 `installing` 之前；交给 Sparkle 之前的失败记成普通失败
  （阶段留在 `readyToInstall`），丢弃刚建的备份，允许重试。
- 验收：用一个在交接前抛错的适配器替身做测试，断言 `requiresRecovery` 和 `blocksEditing` 为假、备份已删除、"重试"可用。

**M8 更新状态文件写盘失败一次，编辑区就被锁住，本次运行内没有出口**

- 严重度：中｜确认程度：已复核
- 位置：`System/Updates/DesktopUpdateController.swift:311-324`、`:31`、`:40`、`:52`、`:68-74`、`:154-155`、`:211`；
  `System/Updates/UpdateStore.swift:136-140`、`:80-82`；`Presentation/SoftwareUpdateView.swift:57-63`
- 问题：任何一次保存失败都会设置 `storageError`，它直接进入 `blocksEditing`。能清掉它的只有"重建更新设置"，
  但那个按钮要求有修复快照，快照只在启动时读取失败才生成。运行中写失败后，界面只显示
  "无法确认更新或恢复状态，请保留全部文件并联系支持。"，没有任何按钮。
  保存发生得很频繁：启动时的自动检查、每次状态变化、等待安装时的每秒轮询。磁盘临时写满或目录临时不可写就会触发，
  即使当时只是"正在检查"。实际出路是重启应用，提示里没说。
- 与 W3 是同一类问题。
- 整改方向：只有在"正在安装、等待重启、恢复中"这几个关键阶段写失败才锁编辑；其余阶段改成不挡编辑的提示，
  并提供"重试保存"。
- 验收：存储替身在"开始检查"那次保存失败时，`blocksEditing` 为假；在记录 `installing` 时失败，仍然为真。

**M9 安装前不检查预设库和外观库能否读取，安装后的健康检查却要求它们可读**

- 严重度：中（需要先有一条坏记录，但之后每次更新都失败）｜确认程度：健康条件和门禁已复核，其余已读
- 位置：`Editor/Model/EditorModel+Updates.swift:4-6`（健康条件）、`:8-20`（安装前门禁）；
  `System/Updates/MacUpdateRuntime.swift:55-61`；`System/Updates/DesktopUpdateController.swift:108-133`；
  `Shared/AdjustmentPresetStore.swift:170-180`；`Shared/LookLibrary.swift:224-243`
- 问题：新版首次启动的健康检查要求四样都正常：编辑记录、外观库、批量任务日志、预设库。
  安装前的门禁只看其中两样（编辑记录、任务日志）。预设库和外观库都是"一条读不懂、整库读不出"。后果：
  1. 用户带着一条坏预设或坏外观记录去更新。旧版里只是预设页报错，其他正常。
  2. 新版首启健康检查不过，更新被记成失败，编辑器不打开。
  3. 界面要求"先安装更新前的同一可信版本，再恢复数据"，用户只能手动装回旧版。
  4. 恢复出来的数据里那条坏记录还在，下次更新重演。错误详情只有 `interrupted`，不说是哪份数据读不出。
- 整改方向：安装前门禁加上"预设库、外观库可读"，不可读时给出明确的阻止原因；健康检查失败时记录是哪一项失败；
  更根本的做法是让预设库和外观库逐条容错（与 W17 一起做）。
- 验收：放一份损坏的 `presets.json`，门禁返回新的阻止原因，状态到不了 `installing`；
  健康检查失败的错误码能区分数据原因。

**M10 普通图片来源的占位值还会关掉 RAW 目标的镜头校正和 RAW 降噪**

- 严重度：低到中｜确认程度：复制一侧已复核，粘贴一侧已读
- 位置：`Adjustments/MacAdjustmentTransferValues.swift:93`、`:102-107`（复制）、`:116-121`、`:139-171`（粘贴）；
  范围定义 `Shared/AdjustmentTransfer.swift:72-73`
- 问题：来源不是 RAW 时，RAW 降噪固定写 0，五个镜头字段固定写"全关、自动裁切开、配置为空"，
  目标是 RAW 时这些值被当真。RAW 降噪属于"细节"组，在"自定义"的默认勾选里：从 JPEG 用默认范围粘到 RAW，
  RAW 的降噪级别被清零。镜头字段属于"几何"组，只在"全部"范围里：从 JPEG 用"全部"粘到 RAW，镜头校正被关掉。
  与 14.6.1 a 是同一个根因。字段定义在 `Shared/`，iOS 很可能相同；Android 和 Windows 的情况见 14.7。
- 整改方向：与 I19、A18、W11 一起定规则。来源不是 RAW 时，不产出只对 RAW 有意义的字段
  （曝光基准、白平衡三项、RAW 降噪、镜头五项），或粘贴时跳过。
- 验收：JPEG 用"全部"和默认自定义范围复制，粘到开了镜头校正、RAW 降噪和自定义白平衡的 RAW，这几项保持不变。
  同时更新 `RawLabMac/tests/AdjustmentTransferTests.swift:568-570`。

**M11 粘贴预检不能取消，重复触发会并发叠加**

- 严重度：低到中｜确认程度：流程已读；耗时为推算
- 位置：`Editor/View/AdjustmentTransferView.swift:314-336`、`:301-309`、`:127`；
  `Editor/Storage/AdjustmentTransferSession.swift:106-130`；
  `Editor/Model/EditorModel+AdjustmentTransfer.swift:98-100`、`:106-122`、`:136-151`
- 问题：每次"重新检查"或重选目标，都往全局队列派一个新的预检任务。旧任务只是结果被丢弃，本身继续跑完所有目标，
  关闭粘贴页也一样。每个目标至少探测一次 RAW 和 HDR 来源；带配方、带 RAW 降噪或开镜头校正时，
  还要新建引擎做一次 256 像素渲染（见 X3）。目标几百张时连点几次，就有几轮解码同时跑。
- 整改方向：预检放到一个串行队列，带可取消标记；新一轮开始或页面关闭时取消旧的，循环内每个目标前检查标记。
- 验收：连续触发两次预检，第一轮在当前目标结束后停止。

#### 14.6.3 对已有发现的证实、推翻或补充

- **I18**："Mac 若走同一函数也受影响"已证实，调用点是 `Adjustments/MacAdjustmentTransfer.swift:81`。
- **I19**："是否是既定的跨端规则"的答案是 Mac 有测试把它固定为预期（见 14.6.1 a）。
- **W3、W7**：Mac 有同样的行为，见 M8、M7。
- **W17 和 14.4.2 的补充**：Mac 相同；外观库 `Shared/LookLibrary.swift:224-243` 也是一条不合规整库读不出。
  两者在 Mac 上会连带导致 M9。
- **10.2 第 9 条（更新包下载两次）**：仍然存在，并且进度条实际上始终不动，原文"进度表现为推测"可以改成已读确认：
  第一次下载（`System/Updates/SparkleUpdateAdapter.swift:79-98`）不发进度，下载完就切到"正在校验"；
  Sparkle 第二次下载的进度事件（`:165-169`）因为阶段不是"正在下载"被 `System/Updates/UpdateState.swift:63-66` 丢弃。
- **10.2 第 7 条（会话历史只增不减）**：仍然存在，行号变为 `Editor/Storage/AdjustmentTransferSession.swift:64`、
  `:186-191`。`outcomes` 字典（`:59`）同样只增不减。
- **X1**：`AdjustmentTransferSession` 的两处位置现在是 `:117`（每个目标读一次）和 `:150`（每个目标存一次）。
  粘贴的"应用并保存"在主线程串行执行（`Editor/View/AdjustmentTransferView.swift:158-165`），
  目标多时主线程连续做多次整份重写。耗时为推算。
- **X3**：`Editor/Model/EditorModel+AdjustmentTransfer.swift:111`、`:118`、`:146` 三处仍是每次新建引擎。
- **M1 到 M6**：这次没有重读相关文件，没有新信息。

#### 14.6.4 次要问题

1. 下载或已校验阶段仍可点"检查更新"：`System/Updates/UpdateState.swift:45-50` 的 `beginCheck` 不看当前阶段，
   会丢掉下载进度或已校验的包，控制器只靠 `canCheck` 拦。按钮是否真的可点取决于 Sparkle，需要实际点一次验证。
2. 任何失败都显示"更新未完成，请查看恢复说明"，包括一次普通的检查失败；下面那行还是进行时的"正在检查更新…"
   （`Presentation/SoftwareUpdateView.swift:50-56`）。
3. 检查途中被强退，下次启动会显示失败，自动重试要等满 24 小时
   （`System/Updates/UpdateState.swift:119-131`、`System/Updates/DesktopUpdateController.swift:150-152`）。
4. 选"立即重启安装"时如果有阻止项，阻止项消失后不会自动继续，要再选一次；只有"任务结束后安装"会自动继续
   （`DesktopUpdateController.swift:194-200`、`:208-215`）。
5. HDR 降噪量在复制页显示成"旧版降噪"，数值是 0 到 1 的小数，滑杆上是百分比
   （`Editor/View/AdjustmentTransferPresentation.swift:35`、`Shared/AdjustmentTransferSummary.swift:86-88`）。
6. 普通模式"重置全部"保留 HDR 调整，却不保留 `proRAWDecodeVersion`（`Adjustments/Adjustments.swift:69`、`:459-469`）。
   是否造成画面变化是推测，目前可能只有一个解码版本。
7. 粘贴页的目标列表不是惰性的（`Editor/View/AdjustmentTransferView.swift:131-135`），每行渲染时做一次路径解析
   和四次线性查找，几百个目标时每次勾选"跳过"全部重算。耗时为推算。
8. 预设库每次读取都逐字节扫描整份文件，每遇到一个键新建一个 `JSONDecoder`
   （`Shared/AdjustmentPresetStore.swift:208-250`）。预设多时每次列出都有这笔开销，为推算。
9. 外观导入的两个小缺口（`Shared/LookLibrary.swift:268-305`、`:336-354`）：文件移到正式位置后、登记写入前崩溃，
   会留下没人引用的外观文件；同一个文件被核心解析两遍。
10. 使用统计默认开启：从未选择过即视为开启（`Shared/UsageAnalytics.swift:68`）。是否有首次启动告知没有核对，这是产品决定。
11. 构建脚本：RUM SDK 校验失败后坏文件留在共享缓存，之后每次都失败，提示没说要删缓存
    （`scripts/rum/prepare-macos.sh:12-20`、`scripts/rum/prepare-ios.sh:25-34`）；两个工作区同时首次下载会写同一个
    `.download` 文件；OpenCV 和 iOS RUM 用的是 GitHub 按标签自动打包的压缩包，这类包的字节不保证长期不变，
    固定校验值将来可能失配（`RawLabMac/build-chroma-dependency.sh:13-16`）；镜头依赖的日志固定写
    `/tmp/rawlab-lens-dependency-<版本>-<架构>.log`，同架构并行构建会互相覆盖（`RawLabMac/build-lens-dependency.sh:21-22`）。
12. 发布配置只校验模型的 `manifest.json` 校验值，三个模型目录只检查是否存在
    （`scripts/release/macos_config.py:39-43`）。清单是否含各文件校验值、别处是否校验，没有核对。

#### 14.6.5 读过后确认没问题、不要改动的地方

- **配方强度换算**（普通照片之间）：换算与反算成对使用，粘贴后逐字段核对实际生效值，不能表示就报错
  （`Adjustments/MacAdjustmentTransfer.swift:183-189`、`:206-232`）。
- **白平衡的相对与绝对处理**：相机白平衡按目标照片解析，不复制来源的校准；目标缺相机白平衡时明确报错。
- **HDR 与普通之间的隔离**：两个方向都拒绝对方不支持的分组；相机显影只带可移植的五项，目标的镜头和相机配置保留。
- **粘贴会话**：预检记下编辑代次，应用时再核对身份和代次，过期就判冲突；撤销和重做核对历史顺序。
- **重置**：先生成候选、提交前再核对照片和修订号；去掉配方时把实际效果折算回参数，折不回就拦下并说明
  （`Adjustments/Adjustments.swift:547-595`）。
- **更新流程**：每一步都带令牌，过期事件被丢弃；进度事件只改内存不落盘；安装前先备份并校验；
  每秒轮询里的安装尝试有防重入；更新包要求 HTTPS、同主机、带 EdDSA 签名和校验值，拒绝增量包。
- **预设库写入**：文件锁加原子替换，修改前核对预期内容，删除过的标识不再复用。
- **外观库删除**："先改名、登记写入为提交点、启动时补做"。
- **使用统计**：只有五种事件（启动、导入照片、选择胶片类别、导出完成、批量导出结果计数），不含文件名、路径或照片信息；
  安装标识随机生成，关闭即删除；统计失败不影响编辑；有开关（`Shared/UsageAnalytics.swift:8-38`、`:72-89`、`:146-194`）。
- **构建侧**：这几份脚本里没有凭据；RUM SDK 下载固定校验值，命中缓存也每次校验；
  镜头依赖构建后检查架构、最低系统版本、没有混入 Homebrew 的库。
- **视图取样**：滑杆拖动期间不落盘，松手才提交；裁切拖动以按下时的矩形为基准，预览或比例变化时作废旧手势。

#### 14.6.6 这个方向仍然没有覆盖到的

- **视图层**：只读了 `AdjustmentRow.swift`、`AdjustmentDock.swift` 后半、`MacCropOverlay.swift` 前 200 行、
  `SoftwareUpdateView`。`MacCanvasInput`、`MacRotationRuler`、`FileBrowser`、`MacWorkspaceBrowserState`、
  `BatchSelectionView`、`BatchExportView` 没读。
- **`Shared/` 的 HDR 文件**：`HDRRecipe.swift`、`HDRDisplay.swift`、`Shared/Native/` 下的 `HDRImage`、`HDRSource`、
  `HDRCanvas`、`HDRPresentation` 没读。
- **使用统计的传输实现**（`UsageRUM` 及 SDK 接入）没读：SDK 自身是否自动采集设备、网络或崩溃信息没有结论。
- **更新**：`UpdateAdapter.swift`、`MacUpdatePackage.swift`、`UpdateStore.swift` 第 200 行以后（备份校验、恢复、回滚）、
  `UpdateAvailabilityBanner` 没读；Sparkle 自身的行为没有核实。
- **测试**：`RawLabMac/tests/` 的断言质量没做，只看了与 14.6.1 a 相关的几行。
- **细节**：`EditPersistence.saveState` 的落盘行为、`MacHSLMixer` 面板内有无单色重置没有核对。

### 14.7 仓库、CI 与跨端契约

补读范围：跨端表里没核对的几格、HDR 设置与处理版本的跨端一致性、编辑配方格式与桌面端生成代码的逐字段比对、
`tools/mcp` 与 `tools/camera-transfer`、CI 工作流与运行机配置脚本、文档取样、git 历史里的敏感信息。
本节 `J/` = `RawLabAndroid/app/src/main/java/com/rawlab/android/`。

这个方向最重要的一条是 R15：**R1 的整改漏了 macOS 作业**。

#### 14.7.1 跨端表里补上的几格

**a. 来源是普通图片时，RAW 降噪和镜头校正字段**

| 端 | 复制时写什么 | 粘到 RAW 目标的结果 |
|---|---|---|
| Mac | RAW 降噪字段非 RAW 写 0，镜头强制默认（全关）。`RawLabMac/Sources/Adjustments/MacAdjustmentTransferValues.swift:93-94`、`:102-107` | 清零目标的 RAW 降噪（`:116-121`），关掉镜头校正（`:147-171`） |
| iOS | 另一个降噪字段非 RAW 写 0；镜头原样写记录值。`RawLab/RawLab/Core/Models/IOSAdjustmentTransferValues.swift:63-64`、`:74-79` | 清零目标的降噪（`:85-88`）；镜头按来源值覆盖（`:109-128`），普通图片的记录通常是默认值，所以同样关掉 |
| Android | 两个降噪字段恒 0；镜头原样写。`J/adjustments/AdjustmentTransferValues.kt:82`、`:95-98` | 降噪不受影响（0 是空操作，Android 没有 RAW 降噪强度这个设置）；镜头按来源值覆盖（`:132-145`） |
| Windows | 两个降噪字段恒 0；镜头非 RAW 强制默认。`RawLabWindows/AdjustmentTransferValues.cs:72`、`:78` | 降噪不受影响（`:87-88`）；镜头被关掉（`:116-126`） |

- **镜头**：四端实际效果一致，只要数据里带镜头字段，RAW 目标的镜头校正就被关掉。镜头字段属于几何组，
  只有"全部"或自选范围才带上。
- **RAW 降噪**：只有 Mac 和 iOS 会清零目标，而且走的是两个不同字段（见 R17）。降噪字段在通用集合里，
  默认范围就会带上。
- 顺带看到：Windows 目标开着 AI 降噪时，数据里只要有任一降噪字段就整次拒绝
  （`RawLabWindows/AdjustmentTransferValues.cs:89-90`），Mac 的对应位置没有这个检查，没核对 Mac 是否在别处拦。

**b. Android 粘贴时不比较处理版本**，与另外三端一样。`processingVersion` 只在复制、校验取值范围和序列化时出现
（`J/adjustments/AdjustmentTransfer.kt:57`、`:215`，`J/adjustments/AdjustmentPayload.kt:61`、`:86`），
粘贴的几个入口都没有与目标比较。

**c. 共用测试向量覆盖了什么**

- 文件是 `Shared/fixtures/adjustment-transfer-v1.json`，80 条（已复核），每条只有 `id`、`valid`、`payload`，
  约 20 条另带 `neutral_effective`。
- 只测两件事：数据能否被接受并原样往返；粘到一个中性 RAW 目标后实际生效数值是否相等。
- **三类场景都没有**：普通图片粘到 RAW（来源为普通图片的 3 条只测接受与否）；带配方的普通照片粘到 HDR
  （全文件没有任何 HDR 向量，已复核）；普通模式重置全部后 HDR 记录的状态（格式里没有"重置"和"目标初始状态"的概念）。
- 四端都读同一份，且都在 CI 快速通道里跑：iOS `RawLab/tests/AdjustmentTransferTests.swift:607-622`、
  Mac `RawLabMac/tests/AdjustmentTransferTests.swift:748-768`、Android 的 `AdjustmentPayloadTest.kt:15-27` 与
  `AdjustmentTransferTest.kt:268-280`、Windows `RawLabWindows/tests/editing/AdjustmentTransferChecks.cs:37-53`。
- 两个小差别：Android 把条数写死为 80，加向量必须同步改；Android 比较允许 1e-6 误差，另外三端要求完全相等。
- **测试该加在哪里**：现有格式装不下这三类场景。建议新开一份带"目标类型、目标初始值、期望结果或期望错误"的场景向量，
  四端各加一个读取入口。HDR 场景目前只有 Swift 共用测试（`Shared/tests/HDRTransferTests.swift`），
  Android 和 Windows 各写各的，统一规则时这部分也要并进共用向量。

#### 14.7.2 新的主要发现

**R15 macOS 作业仍会在自托管的物理 Mac 上执行外部 PR 的代码**

- 严重度：高（前提与 R1 相同）｜确认程度：工作流和脚本已复核；仓库是否公开、外部 PR 是否需审批仍待验证
- 位置：`.github/workflows/ci.yml:127-131`、`:176-183`；`scripts/ci/affected_platforms.py:65-70`、`:48-50`；
  对照 `.github/workflows/ci.yml:279-282`（Windows）、`:545-548`（iOS）；`scripts/ci/test_workflow.py:82-84`
- 问题：Windows 和 iOS 作业已加"只允许本仓库分支"的条件，macOS 作业的条件仍只有
  `needs.changes.outputs.macos == 'true'`。`macos_matrix` 对任何检查组都返回自托管 `rawlab-apple` 那一行，不看来源。
  外部 PR 改到共享文件或 Mac 文件，就会在物理 Mac 上执行 PR 里的 `scripts/ci/apple-models.sh macos`。
  策略测试只在 `runs-on` 字面含 `self-hosted` 或作业名是 windows、ios 时才要求保护；macOS 的 `runs-on` 是矩阵表达式，
  测试拦不住。另外外部分支叫 `hotfix/x` 仍会被判成冷构建（`is_cold_pull_request` 没看来源仓库）。
- 汇总时又对照了更新的远端（`origin/development` @ `d05c8d7d`）：这个作业的条件没有变，问题仍在。
- 整改方向：给 `macos` 作业加同样的来源条件，或让矩阵生成对外部 PR 不产出自托管行；策略测试把 macos 明确列入；
  冷构建判定只对本仓库分支生效。
- 验收：`test_workflow.py` 新增断言能在去掉条件时失败；用外部 PR 的事件样例跑 `affected_platforms.py select`，
  确认不会落到自托管机。

**R16 外部 PR 只要选中 Windows 或 iOS，汇总结果必然失败**

- 严重度：低到中（取决于是否接受外部贡献）｜确认程度：校验逻辑已复核，按代码推演，没有实际触发
- 位置：`scripts/ci/affected_platforms.py:157-167`、`:171-175`；`.github/workflows/ci.yml:279-282`、`:545-548`、`:635-650`
- 问题：保护是整作业跳过，但 `verify` 要求"选中的平台结果必须是 success"，被跳过的会报错，
  所以这类 PR 的汇总结果永远是红的。普通 PR 的 Windows 本来用托管机 `windows-2022`，不涉及自托管机，
  却也一并被跳过，白白少了一层检查。`docs/process/ci.md` 里没有外部 PR 的处理说明。
- 整改方向：Windows 的来源条件只在选到自托管机时生效；`verify` 对"因来源被拦"的平台接受跳过并写明未验证；
  在 `ci.md` 写清外部 PR 的流程。若决定不接受外部 PR，只补文档即可。
- 验收：`test_affected_platforms.py` 增加外部 PR 用例。

**R17 "RAW 降噪强度"在交换格式里各端用的字段不同，互相拒收**

- 严重度：低（目前不跨设备交换，性质同 R7）｜确认程度：Mac 与 iOS 的写法已复核，其余已读
- 位置：Mac `RawLabMac/Sources/Adjustments/MacAdjustmentTransferValues.swift:93-94`、`:113-115`；
  iOS `RawLab/RawLab/Core/Models/IOSAdjustmentTransferValues.swift:63-64`、`:84`；
  Android `J/adjustments/AdjustmentTransferValues.kt:82`、`:105-107`；Windows `RawLabWindows/AdjustmentTransferValues.cs:72`、`:87-88`
- 问题：Mac 把强度写在 `detail.denoise.raw_level` 并拒收非 0 的 `post_rgb`；iOS 反过来；
  Android 和 Windows 两个都恒写 0、非 0 都拒收。同一份格式里这两个键的含义已经分叉。
  共用向量 `legacy-denoise` 只测能否解析，没有暴露。
- 整改方向：在字段目录里规定这两个键各自的含义，以及没有该功能的端收到非 0 值是忽略还是拒绝；
  配合 R3 补"粘到目标后的结果"向量。
- 验收：四端对同一条非 0 降噪向量给出目录规定的同一种结果。

**R18 桌面端的配方生成函数只有测试在调用，两端能力不对等**

- 严重度：低｜确认程度：无正式调用方已复核，两端差异已读；相机 RAW 的后果是推测
- 位置：`RawLabMac/Sources/Rendering/AgentRecipe.swift:5`、`:7-15`；`RawLabWindows/AgentRecipe.cs:8`、`:10`；
  `Shared/HDRRecipe.swift:61`、`:63`；`lutools/src/cli/edit_recipe.cpp:286-293`；`RawLabWindows/README.md:109`
- 问题：两个函数都只被各自的测试引用，源码里也找不到"复制配方"的入口，`RawLabWindows/README.md:109` 却写
  "复制配方会要求先关闭 AI"。Mac 有 HDR 分支，Windows 没有也不拦：HDR 编辑状态会被写成普通的 v5 配方。
  HDR 生成器固定写 `input.type = "hdr_raster"`，不写 `camera_development`，也不会产出 v14，
  而核心解析器和 v14、v15 的 schema 都支持 `raw`、`proraw`。
  推测：相机 RAW 或 ProRAW 的 HDR 编辑经这条路生成的配方，要么被拒绝，要么丢掉相机显影参数。
- 整改方向：先定这两个函数的定位。只是测试用的对照工具，就移到测试代码并改 README；
  要成为功能，就补 Windows 的 HDR 分支和相机 RAW 的 v14、v15 输出。
- 验收：README 的说法与代码一致；若保留，两端对同一份 HDR 编辑生成的配方都能通过 CLI 的 `validate_recipe`。

**配方逐字段比对的结论**：v5、v7（Mac、Windows）和 v6–v15（`Shared/HDRRecipe.swift`）的顶层键、`edits` 下的键、
版本号映射、取值范围，都没有发现写出 schema 不接受的字段或漏写必需字段。差异有这几处：

- `jpeg_quality`：Mac 写死 95（`RawLabMac/Sources/Rendering/AgentRecipe.swift:91`），Windows 用当前导出质量
  （`RawLabWindows/AgentRecipe.cs:54`）。
- `long_edge` 上限三处不一致：v5、v7 的 schema 和普通配方解析器是 4294967295（`lutools/src/cli/edit_recipe.cpp:662-663`），
  HDR 解析器是 65535（`:436`），Mac 生成器两条路径都限 65535，Windows 不检查。
- `s_curve`、`sharpening`：Windows 生成时再夹一次范围，Mac 直接用请求值。
- 降噪：Mac 有小波设置时把 `chroma_mode` 写 0，否则可写 `raw_level`；Windows 的 `raw_level` 恒 0，
  `chroma_mode` 不管小波是否开启都照写。都在范围内，语义不同。

#### 14.7.3 对已有发现的证实、推翻或补充

- **R1**：部分修复。Windows、iOS 已加来源条件，macOS 没加，见 R15。
- **R2**：CI 入口已补上，契约作业跑 `scripts/localization/generate.py --check` 和 `tests/test_localization.py`
  （`.github/workflows/ci.yml:100-101`）。当时漏的键是否已补，没有核对。
- **R3 仍然成立**：80 条向量里出现的真实字段键仍是 23 个，`processing_version` 全是 2，没有 HDR 向量；
  向量格式没有目标状态（见 14.7.1 c）。
- **R4**：四个文件仍是 0.10.0 / 19，是否已加一致性校验没有核对。
- **R5、R6、R8 仍然存在**（`.github/workflows/ci.yml:25-28`、`:411-412`、`:5`）。
- **R9**：发布脚本和 RUM 两组测试仍没有 CI 入口；`tools/mcp` 的测试在契约作业里。
- **R13 补上了历史扫描**（四条只读命令，只看提交号和路径，不输出命中内容）：
  - 私钥头、常见令牌前缀：命中两个提交里 `docs/superpowers/plans/` 下 4 份计划文档，复核后是误报
    （宽松模式匹配到普通连字符单词，严格模式零命中）。
  - 口令式赋值：命中 `3607d768`，都在 `docs/design/camera-transfer/prototype/`、`tools/camera-transfer/` 的说明和测试里，
    按特征归类是原型演示值、文档示例、测试假数据。
  - 敏感文件类型：历史上只加过 `RawLabAndroid/scripts/rum-sdk.env`，里面只有 SDK 版本号和校验值，是公开值。
  - 局限：不扫二进制文件，只覆盖本地可达的引用，模式有限。
- **10.6 第 1、2、4 条仍然存在**。第 2 条补充：Windows 作业里内联了同样的做法，安装器和校验值来自同一服务器
  （`.github/workflows/ci.yml:335-339`）。
- **R10–R14**：这次没有重新核对。

#### 14.7.4 次要问题

1. **处理版本迁移的启动条件各端不同**，没找到书面规则。Mac：非 HDR 编辑、无配方、未启用 AI 降噪、来源不是 SDR 兜底
   （`RawLabMac/Sources/Editor/Model/EditorModel+ProcessingMigration.swift:26-31`）。iOS：只要来源是 HDR 图片就跳过，
   哪怕在普通模式下编辑（`RawLab/RawLab/Core/ViewModel/RawEditorViewModel+ProcessingMigration.swift:23-26`）。
   Android：只看非 HDR 编辑和无配方（`J/editor/EditorViewModel.kt:1164-1167`）。Windows 的启动条件没找到。
2. **HDR 记录的 `geometry` 子对象严格程度三套不同**，而其他子对象三端都是键集必须完全相等。
   Apple 缺键取默认、未知键忽略（`Shared/GeometrySettings.swift:35-47`）；Android 必须恰好 10 个键
   （`J/settings/StructuredSettingsCodec.kt:216-217`）；Windows 未知键拒收、缺键取默认（`RawLabWindows/HDRSettings.cs:339-342`）。
3. **HDR 外观名、相机配置名、镜头配置名的"控制字符"判定不同**：Apple 用 `CharacterSet.controlCharacters`，
   Android 用 `isISOControl`，Windows 用 `char.IsControl`。按文档前者还包含零宽连接符这类格式字符，
   所以含这类字符的文件名只在 Apple 端被判无效。依据文档，没有运行验证。
4. **`lens_vignetting` 的写法不同**：Windows 只在为真时写，Android 总是写。各端解码都当可选，只是字节不同。
5. **MCP 的输入路径是先检查再交给 CLI 打开**，CLI 拿到的是未解析符号链接的路径
   （`tools/mcp/src/rawlab_mcp/adapter.py:240-258`、`:330-333`）。两步之间替换符号链接可以读到允许目录之外，
   但前提是攻击者已能写允许目录，风险低。
6. **原生依赖缓存键把整个作业定义算进去**（`scripts/ci/native_cache.py:57-76`），给作业加一个无关的测试步骤
   也会让缓存失效、触发冷构建。只是成本问题。

#### 14.7.5 读过后确认没问题、不要改动的地方

- **HDR 设置的版本规则三套实现一致**：处理版本 1–8 由记录结构推出，声明值与结构不符就拒收
  （`Shared/HDRSettings.swift:366-375`、`:533-540`；`J/settings/HDRSettings.kt:157-167`；`RawLabWindows/HDRSettings.cs:99-100`、`:332-335`）。
  各字段取值范围三端一致；顶层和各子对象的未知键三端都拒收（`geometry` 除外）。
- **普通处理版本四端一致**：都是 1、2、3，交换数据里的 `processing_version` 校验都是 1..3。
- **`tools/mcp`**：只走 stdio，不监听网络端口；用参数列表启动 CLI，不经过 shell；路径必须是绝对路径，
  解析后必须落在允许的读写目录内；输出先写到私有暂存目录，再以"不覆盖"的方式发布；输出大小、超时、进程回收都有上限。
- **`tools/camera-transfer`**：主机必须是显式的私有、链路本地或回环地址；SSH 先核对指纹再发口令，
  隧道只允许转到 15740 端口；口令从凭据文件读取，不走命令行参数；文件名禁止路径分隔符；不经过 shell。
- **工作流**：每个作业都有超时；第三方 action 全部按提交号固定；顶层权限只读；整个 `ci.yml` 没有使用任何仓库密钥；
  清理工作流不执行仓库代码。
- **运行机配置脚本**：Mac 脚本拒绝管理员账户并校验安装包的固定校验值；Android 脚本只在虚拟机里运行并校验工具校验值。
  两者都不保存令牌。
- **文档取样**：13 份文档里引用的仓库路径都存在；README 和 CHANGELOG 的版本号与代码一致；
  `tools/mcp/README.md` 的说法与代码一致。

#### 14.7.6 这个方向仍然没有覆盖到的

- **CI 与脚本**：`scripts/ci/provision-windows-runner.ps1`、`prepare-rust.sh`、`ai-inputs.py`、`check-ios-sdk.sh` 没读；
  `test_workflow.py`、`native_cache.py` 只读了一部分；缓存键的输入清单没有逐项对照构建脚本实际读取的文件。
- **`tools/`**：`camera-transfer` 的协议客户端、恢复逻辑、凭据文件的读取和权限检查没读；`tools/mcp` 的测试没读。
- **配方**：`edit-json.md` 的文字说明没有与 schema 对照；v1–v4、v6、v8–v14 只比了键清单；
  Windows 和 Mac 在生成前对普通图片的归一函数没读。
- **文档**：发布说明正文、各 README 的功能声明基本没核对。翻译键缺失没有抽查；`experiments/` 只做了引用检索。
- **外部设置**：GitHub 上的仓库公开性、分支保护、外部 PR 审批无法从库内核实，R1、R15、R16 的实际风险取决于它们。

### 14.8 补充评审里跨端重复出现的问题

下面这些在不止一个平台上出现，应当先统一定规则，再各端一起改。Mac 是功能参考端，它的行为见 14.6.1。

| 问题 | Mac（参考端） | iOS | Android | Windows |
|---|---|---|---|---|
| 普通图片的调整粘到 RAW，占位值被当真：改掉曝光基准、白平衡改回相机白平衡 | 相同（14.6.1 a） | I19，白平衡见 14.3.3 第 6 条 | A18 | W11 |
| 同上，"全部"范围还会关掉 RAW 目标的镜头校正 | 会（M10） | 会（14.7.1 a） | 会（14.7.1 a） | 会（14.7.1 a） |
| 同上，默认范围还会把 RAW 目标的降噪清零 | 会（M10） | 会（14.7.1 a） | 不会 | 不会 |
| "RAW 降噪强度"在交换格式里用的字段 | `raw_level` | `post_rgb`（与 Mac 相反，R17） | 两个都恒 0 | 两个都恒 0 |
| 带配方的普通照片粘到 HDR 照片，不按配方强度换算 | 相同，粘贴页说明文字还与实际不符 | I18 | A17 | W12 |
| 普通模式"重置全部"丢掉未启用的 HDR 调整 | **不同：Mac 保留** | 丢（14.3.2） | A19 丢 | W13 丢 |
| HDR 的显示映射、相机显影参数只有"重置全部"能复位 | 显示映射相同；相机显影面板内另有"重置" | I16 第 5 点 | 14.4.3 第 2 条 | 14.5.3 第 1 条 |
| 粘贴时不比较来源和目标的处理版本 | 相同，注释写明沿用目标版本 | 14.3.3 第 4 条 | 相同（14.7.1 b） | 14.5.3 第 4 条 |
| 预设库一条读不懂，整个库不可用 | 相同，还会连带让更新失败（M9） | 很可能相同（共用 `Shared/AdjustmentPresetStore.swift`，调用方没有读） | 14.4.2 的 X1 补充 | W17 |
| 重置入口 | 七种范围都有入口 | 只剩"重置当前工具"可达（I16） | 没有核对 | 没有核对 |
| 相机导入：一张坏文件卡住整次导入 | 无此功能 | I13 | A11 | 无此功能 |
| 相机导入：重连后不认上次进度 | 无此功能 | I14 | A12 | 无此功能 |
| 相机导入：卡上文件超过 1 万个时列不出来，提示不对 | 无此功能 | I15 | A13 | 无此功能 |

怎么读这张表：

- **前两行四端一致，是规则本身的问题**，不是某一端偏离。Mac 还有测试把"显式选曝光基准时保持 sensor"固定为预期，
  所以整改要先决定规则（建议：来源不是 RAW 时不产出只对 RAW 有意义的字段），再四端和共用测试向量一起改。
- **第三行是其他三端偏离参考端**，按 Mac 的做法改即可：普通模式重置时保留未启用的 HDR 调整。
- **预设库和外观库的逐条容错**在 Mac 上优先级更高，因为会连带让更新失败（M9）。
- **共用测试向量目前测不到这些场景**（14.7.1 c）：现有 80 条只测"能否接受"和"粘到中性 RAW 后的数值"，
  没有目标初始状态，也没有任何 HDR 向量。定规则的同时要新开一份带目标状态和期望结果的场景向量，四端一起跑。

相机导入只有 iOS 和 Android 有：按文件名检索，`RawLabWindows/` 和 `RawLabMac/` 下都没有相机导入或联机拍摄的代码。
第 13.1 节里"Mac 的相机导入是否有同样的整卡重列逻辑"（X6）因此不成立。

### 14.9 补充发现的整改进度对照（截至 `origin/development` @ `d05c8d7d`）

补充评审进行期间，远端又从 `191d8aba` 走到了 `d05c8d7d`（PR #240–#262）。下表是**按 PR 分支名推断**的对应关系，
除 R15 外都没有看修复内容，动手前仍要看代码。第 14.1 到 14.7 节的行号仍以 `191d8aba` 为准。

| 补充发现 | 看起来对应的 PR |
|---|---|
| C25 | #244 `fix/lens-toolchain-pins` |
| C27 | #243 `fix/win-exif-segment-bounds` |
| C28 | #245 `fix/exif-metadata-budget` |
| C29（可能部分） | #254 `test/gpu-force-unsupported` |
| C30 | #248 `fix/denoise-preview-resolution` |
| I13、I15 | #258 `fix/ios-camera-skip-and-limit` |
| I16 | #262 `fix/ios-reset-entry` |
| I18、I19、A17、A18 | #250 `fix/transfer-recipe-and-exposure-baseline` |
| A11、A13 | #257 `fix/android-camera-skip-and-limit` |
| A16 | #252 `fix/android-camera-log-tolerance` |
| A19 | #253 `fix/reset-mode-isolation-android` |
| iOS 重置全部丢 HDR（14.3.2） | #256 `fix/reset-mode-isolation-macios` |
| W11、W12、W13 | #255 `fix/win-reset-and-transfer-rules` |
| W15、W17 | #251 `fix/win-preset-and-lut-preview` |
| 14.1.3 第 3、4 条 | #259 `fix/recipe-lens-profile-and-effects-doc` |
| 14.2.3 第 3 条 | #261 `fix/hdr-export-permissions` |

**还看不到对应 PR 的主要发现**（19 条）：

- 核心库：C26（GLES 没有像素级测试）。
- iOS：I12（导入清单反复整份重写）、I14（重连不认进度）、I17（菜单复制粘贴被草稿挡住，需真机先验证）。
- Android：A12（重连不认进度）、A14（快门后断线无法续接）、A15（空闲时反复列整张卡）、A20（外观反复校验）。
- Windows：W14（批量窗口反复重建）、W16（拖动时整面刷新并读文件）。
- Mac：M7、M8、M9（更新流程的三处锁死）、M10（占位值关掉镜头校正和 RAW 降噪）、M11（粘贴预检不能取消）。
- 仓库：R15（**已对照 `d05c8d7d` 的工作流确认仍在**）、R16、R17、R18。

建议的处理顺序：

1. **R15**：一行条件加一条测试断言，风险最高、改动最小。
2. **M7、M8、M9**：都会把用户锁在编辑器外，M9 与预设库、外观库的逐条容错（W17 的同类）一起做。
3. **14.8 表的前几行**：#250、#255 合入的规则与 Mac 现有测试（`RawLabMac/tests/AdjustmentTransferTests.swift:568-570`）
   以及 M10、R17 是否一致，需要对照一次；同时把场景向量补上。
4. **A14、A12、I14**：相机联机的续接与重连，要先做产品决定。
5. 其余性能类（I12、A15、A20、W14、W16、M11）和测试类（C26）。
