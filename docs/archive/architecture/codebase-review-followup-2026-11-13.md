# RawLab 整改跟进评审与台账核对（2026-11-13）

本文是 [全仓代码评审与整改清单（2026-11-12）](codebase-review-2026-11-12.md)（下称"评审"）的**跟进核对与补充**，
不是第二份全仓评审。它回答三个问题：

1. 评审点名的整改（PR #209–#262）落到代码后的真实状态——含几处"台账看起来修了、代码没修完"；
2. 整改**新引入或没有盖住的**问题；
3. 评审方法之外能看到的结构性风险。

评审已列条目不再重复描述；本文只引用其编号给出状态结论。整改结束后按根目录 `AGENTS.md`
的文档约定移入 `docs/archive/`。

## 1. 基线与阅读方式

- **基线**：`development` @ `d05c8d7d`（2026-11-13 15:22，等于 `origin/development`，PR #262）。
  评审正文基线 `9c4f7801`、补充评审基线 `191d8aba`（PR #239）。`9c4f7801..d05c8d7d` 共 140 个提交
  （PR #209–#262，其中 #240–#262 未纳入补充评审的行号与结论）。文中行号以 `d05c8d7d` 为准。
- **方法**：六个范围分头只读细读（核心 C++、对外接口/GPU/AI/X3F、Mac、iOS 与 `Shared/`、
  Android、Windows 与仓库/CI），汇总时对高影响结论逐条到代码复核；另做仓库级热点度量
  （近 300 提交文件触达次数、各端最大源文件、四端持久化文件触达频率）。
  没有运行构建或测试，没有修改任何文件；耗时/次数是静态读码得出，标注同评审（已复核/已读/待验证）。
- **编号**：新问题用各范围前缀加 `-N`（C-N1、G-N1…）；结构性观察用 `S`；
  "复核"列打 ✓ 表示汇总时又对照代码核对过。
- **整改中做对、不要再动的地方**：LibRaw 线程安全修复附带"多线程与单线程解码结果 memcmp
  逐位一致"的必跑合成用例；C ABI 布局 fixture 每次 CI 从 C 头重生成并用 clang AST 双重校验
  （拒绝 `long` 类非便携类型与 padding 内新增字段）；异常屏障测试注明"移除内层 @catch 必须失败"；
  批量日志损坏改名隔离 + 单次上报；导出 staging（O_EXCL、短写回调、权限保持、foreign-name 保护）
  链路完整。本文的批评都以此为参照系。

## 2. 结论总览

### 2.1 建议最先处理

| 顺序 | 编号 | 问题 | 严重度 | 复核 |
|---|---|---|---|---|
| 1 | R-N1 | fork 门禁漏掉 macos job——R1 点名的"物理 Mac 执行 PR 自带脚本"仍是敞口；连带 fork PR 的 CI result 恒红（R-N2） | 高 | ✓ |
| 2 | M1 | Mac HDR 取色"预览已变化"仍未修（评审第一批第 5 位；文件基线后 0 提交） | 中 | ✓ |
| 3 | W-N1 | 更新器退避只覆盖"检查阶段"：下载/中断类失败仍永久静默停摆、跨重启保留、主窗口无提示（W2 原始场景未修） | 中 | ✓ |
| 4 | A3 | Android HDR 外观导入按返回仍可能卡"忙"：守卫补了一半，operation 滞留 `IMPORT_LOOK` 且 BackHandler 同时失效 | 中 | 已读 |
| 5 | C-N1 | 128M 像素帽把 NATIVE 一起拒（>128MP 原生导出行为回退），且要到完整 RAW 解码之后才报；需先做产品决策 | 中 | ✓ |
| 6 | C-N4 | 取消回调会被核心内部线程池并发调用，这条契约仍未成文 | 中 | 已读 |
| 7 | S1 | 编辑记录持久化是四端独立实现、无共享 golden fixture，本轮"一条规则改四遍"已经漏了 Windows 一半（§5.1） | 中 | ✓ |
| 8 | A-N1 | #228 的历史快照锁没盖住 `EditorEditStore` 的两个可变引用（非 volatile，跨线程可见性） | 中 | ✓ |
| 9 | W-N2 | 更新 gate 定时器在 `Available+延迟退出安装` 态每秒手动复查，成功路径无限流 | 中 | 已读 |
| 10 | S3 | X2"热路径整文件读/哈希"四端未动且被新缓存代码显性化（§5.3） | 中 | ✓ |

### 2.2 台账核对的主要修正

评审 §12 第一批里，以下条目**实际没有或只有一半落地**（详见 §4）：
M1（未动）、W2（半修，原始场景未盖）、R1（半修，macos 漏 + fork 恒红）、C14（部分，NATIVE
回退与 JPEG 维度）、A3（半修）、C2/C6/C7（分块变体已存在但两处 GPU 后端没接上）、M4（仍成立）。
其余抽查（C1、C3、X4、X5、A4、A10、A11/A13、W1、W4、R2、I13/I15、I16、I18/I19、reset 隔离）
基本落地，其中 iOS/Android 相机整改的测试投入明显。

## 3. 整改后新出现或没盖住的问题

确认程度标记沿用评审。位置行号以 `d05c8d7d` 为准。

### 3.1 核心库 `lutools`

- **C-N1 >128MP 的 NATIVE 输出被拒，且解码后才失败**｜中｜✓
  `lutools/src/ffi/sony2fuji_c.cpp:743-745`（128M 帽加在 computeTargetSize 收口，全模式共用）、
  `:527-530`（validateRequestSize 的 NATIVE 分支直接返回 OK）、`:2468-2474`（RAW 路径的
  computeTargetSize 在解码之后）。151MP 中画幅原生导出（基线只要求 int 不溢出）现在要完整解码
  一次才拿 `INVALID_ARGUMENT`。"防溢出"（2.1G 像素）与"128M 预算"两个目标被绑在一起，
  是否应限 NATIVE 需要先决定（同 G-N8）。
- **C-N2 JPEG 65535 单边限制只在编码器层报**｜低｜已复核
  `raw_processor.cpp:1129-1136`：`EXACT 100000×100`（100MP ≤ 帽）通过请求验证、跑完整渲染，
  最后 JPEG 报 ProcessingError；同请求 PNG/DNG 可正常导出。三种格式行为不一致、错误码不是
  InvalidArgument——"整套渲染跑完最后才失败"在 JPEG 维度回归。
- **C-N3 staging 的 O_CLOEXEC 被 `fdopen` 抵消**｜低｜待验证
  `raw_processor.cpp:990-997`：`open(O_CLOEXEC)` 后 `fdopen(fd,"wb")` 在 glibc/macOS 会清掉
  close-on-exec。整改意图（子进程不继承半写 fd）丢了一半。
- **C-N4 取消回调"可被内部线程池并发调用"未成文**｜中｜已复核
  `include/sony2fuji/ffi/sony2fuji_c.h:785-796` 只写"自己读的变量要原子、不抛不重入"；
  `src/core/parallel_pixels.h:15-31` 实际在 `cv::parallel_for_` 的多个 worker 线程里轮询同一
  回调（LibRaw progress handler 也调它，`raw_processor.cpp:76-86`）。客户端回调若非线程安全，
  属契约未写明的数据竞争。
- **C-N5 FINAL 编码阶段没有取消检查点**｜低｜已复核
  `raw_processor.cpp:1216-1246`（savePNG 逐行 deflate）、`:1093-1110`（JPEG 写回调）。取消亿级
  像素导出要等整个编码跑完才返回 CANCELLED；staging 保证不留半成品，但取消响应是秒级。
- **C-N6 preserveDestinationMode 是 stat+fchmod 的 TOCTOU，且跟随 symlink**｜低｜已读
  `src/core/output_file_mode.h:23-27`。共享目录/SMB 边界场景，契约已部分成文。
- **C-N7 ABI fixture 挡得住 64 位 struct 布局漂移，挡不住枚举、32 位与本地盲区**｜中｜✓
  `tools/abi-layout/generate_abi_layout.cpp:9-10`（硬断言 64 位）；fixture 无 enum 条目；
  本地 `test.sh`/ctest 不含该测试，漂移只在 Contracts job 暴露（详见 S4/G-N7）。
- **C-N8 Windows staging 分支未与 POSIX 同步改造**｜低｜已复核
  `raw_processor.cpp:958-975`：Win32 仍用 `GetTempFileNameW`+`_wfopen`；O_EXCL 重试、
  foreign-name 保护、umask 语义都只在 `#ifndef _WIN32` 分支。深目录/大量旧名时两端行为不一致。
- **C-N9 `ImageData::at()` 新边界防护是 assert**｜低｜已复核
  `include/sony2fuji/common.h:29-36`：NDEBUG（发布）下越界索引仍是静默 UB，C14 防线只兜
  debug/ctest。
- **C-N10 ProcessingCancelled 经 `ImageEncoder` 返回值"漏"进 C++ 调用方**｜低｜部分待验证
  `raw_processor.cpp:1176-1177,1282-1283`：saveJPEG/savePNG 现在可能重抛异常（ErrorCode 没有
  cancelled 枚举），FFI 层才映射。CLI 不装取消 scope 所以安全；直接链 `libsony2fuji_core.a`
  的调用方需要确认是否有人不经 FFI 调编码器。

### 3.2 对外接口、GPU、AI、X3F

- **G-N1 Force 错误码语义在路径间分裂**｜中｜待验证客户端影响
  #254 把会话显影路径"Force+无 GPU 后端"统一为 UNSUPPORTED，但独立 LUT 路径
  `lut_gpu.cpp:88-90,105-107` 与 rlook/DCP `sony2fuji_c.cpp:2399` 的 Force 失败仍返回
  PROCESSING_ERROR。客户端若按新契约只对 UNSUPPORTED 弹"强制 GPU 不可用"，独立 LUT/rlook
  会被误报为处理错误。测试只覆盖 photo_color/photo_effects 两条套件。
- **G-N2 首次 `set_ai_denoise` 配置失败残留 `enabled=true`**｜低到中｜已复核
  `sony2fuji_c.cpp:1920-1938`：configure 抛出时 `hadAI==false` 不回滚，会话留下 enabled 的
  半成品 AISession；set 返回 INVALID_ARGUMENT 之后每次渲染仍走 useAI 分支报错，而非干净关闭。
- **G-N3 Metal/GLES 独立 LUT 上下文初始化失败被永久缓存**｜低｜待验证
  `metal_lut.mm:39-67`、`gles_lut.cpp:219-223`：`std::call_once` 下瞬态失败（启动竞态窗口的
  `MTLCreateSystemDefaultDevice()` nil）→ 进程生命周期内静默 CPU。与 C7"失败无记忆"互为镜像。
- **G-N4 三处 EGL Binding RAII 同款细节不一致 + 恢复顺序问题**｜低｜待验证
  `gles_lut.cpp:110-137`、`gles_photo.cpp:38-56`、`gles_denoise.cpp:18-33` 析构都先恢复
  context 后 `eglBindAPI`；调用线程现有 ctx 属其他 client API 时恢复会 EGL_BAD_MATCH（被忽略），
  正确顺序应先恢复 API。stub 测试的线程 api 默认值恰好从不触发该分支。
- **G-N5 metal_stats 捕获收窄留下逃逸窗口**｜低｜待验证
  `metal_stats.mm:240-241,249-262`：runKernel 从 `catch(...)` 收窄为 `catch(std::exception)`，
  非 std/foreign C++ 异常比基线少一层，靠外层 FFI 入口兜底。
- **G-N6 `compute_histogram` 仍未对照 `size_bytes`**｜低｜已复核
  `sony2fuji_c.cpp:2973-2982`：stride×height 与缓冲容量不比对，越界是静默内存读（与 C23 同型）。
- **G-N7 ABI fixture 未固化枚举值**｜低（前瞻）｜✓
  两 ffi 头共 50 个 struct 覆盖完整，但 16 个 `typedef enum` 的取值不在门禁内；
  Swift×2/Kotlin/C# 手工对齐，未来中间插值不会变红（基线至今枚举无漂移，干净）。见 S4。
- **G-N8 128M 帽波及 NATIVE 且预检滞后**：同 C-N1，不重述。
- **G-N9 `applyLutMetal` uint32 像素数截断无内部防线**｜低｜待验证
  `metal_lut.mm:168`：FFI 路径被 128M 帽兜住；internal/CLI >4G 像素会静默部分应用 LUT。
- **G-N10 X3F bridge panic 载荷被丢弃**｜低｜已读
  `lutools/x3f-bridge/src/lib.rs:220-222`：panic 统一折叠成固定文案，原因不透传 C 边界；
  dp1s 硬失败时排查只有"decoder failed"一句。

### 3.3 Mac

- **M-N1 缩略图刷新链仍把整份编辑记录全量解码，一次提交被多路刷新放大**｜中｜已复核
  `EditPersistence.swift:80-85`（init 无条件 `readRegistry()` 并丢弃结果；readRegistry =
  JSONSerialization 全量解析 + 切片全量扫描，两遍全文件）、`MacEditedPhotoPreviews.swift:615`
  （worker.record 每次新建实例 → 每张缩略图 ≥4 遍全文件解析）、`MacWorkspaceBrowser.swift:503` +
  `EditorView.swift:178-189`（films/didBecomeActive/adjustmentHistoryRevision/sourceRevision
  多路 `refresh()` 无合并）。M2 指出的"合并成一次刷新"未做。
- **M-N2 预览计划指纹每次构造都全量读 LUT 资源做 SHA256**｜中｜已复核
  `MacEditedPhotoPreviews.swift:66-69`：胶片/HDR 资源整文件哈希；一条渲染路径构造 plan 3 次。
  #239/#240 为保证缓存正确性引入的新热点。
- **M-N3 "已编辑"判定出现两套 raster 分类**｜低到中｜待验证
  `EditPersistence.swift:326-338`（`UTType` 含 `.image` 不含 `.rawImage`）vs
  `MacEditedPhotoPreviews.swift:16-21`（`RenderEngine.isRasterInput`）。特定格式（TIFF/HEIC）
  两条路径归类可能分叉，活动缩略图状态抖动。
- **M-N4 外观变更失效：主线程逐条解析全部记录，坏记录 `try?` 静默跳过**｜低到中｜已读
  `EditPersistence.swift:295-305`、`MacEditedPhotoPreviews.swift:394-407`。删/换胶片时
  O(全部记录) 主线程解码；那条不可读记录的缩略图在胶片删除后仍显示旧图。
- **M-N5 批量列表首帧在主线程同步读记录+探测 RAW，`try?` 吞错**｜低到中｜已读
  `BatchExportModel.swift:140-147`：X3F"普通模式不支持 AI"提示探测失败即静默消失且缓存 nil。
- **M-N6 批量校验/预览/导出共用一条串行队列，预览与校验不可取消**｜中｜✓
  `BatchExportModel.swift:91,183-216,426-464`：AI 预览用空 progress 闭包不挂取消
  （`:446-448`），`start()` 不等预览。M4 现象原样保留（见 §4）。
- **M-N7 journal"未来版本"识别写死多处版本上限**｜低｜已读
  `BatchExport.swift:331-377`：`hdr≤8、record≤9、camera_dev≤1、recipe≤4` 等硬编码；
  枚举漏项时未来任务会被误判 corrupt 并 quarantine，用户任务"消失"。
- **M-N8 编辑提交仍主线程同步整文件读-改-写，通知里的修订摘要也在调用线程算**｜低到中｜已读
  `EditorModel+AdjustmentHistory.swift:24-55` → `EditPersistence.swift:319-361,490-499`。
  原子写/flock/容错设计自洽；记录条数增长后提交时长线性上升。
- **M-N9 文件换代窗口内旧字节的解码结果仍回给等待者**｜低｜待验证
  `FileLibrary.swift:601-625`：b9e1c5ba 只堵了"入缓存"一侧；外部替换文件后首帧可能短暂显示
  旧字节缩略图，下一轮 revision 自愈。
- **M-N10 预览磁盘缓存每次写入全目录扫描做 LRU**｜低｜已读
  `Shared/EditedPhotoPreviewCache.swift:43-72`：全局锁内目录级 I/O，批量生成期间每次发布都触发。
- **M-N11 缩略图 worker 单 actor 串行，一次 AI prepare 阻塞全部缩略图**｜低（有意）｜已读
  `MacEditedPhotoPreviews.swift:564-568,636-638`：缺进度提示。

### 3.4 iOS 与 `Shared/`

- **I-N1 #262 把 reset 挂起状态机变成不可达死代码**｜中｜✓
  `EditorDrafts.swift:255-264` + `ContentView.swift:119-122,430-433`：全仓 `resetRestoreTool`
  没有任何非 nil 赋值点（赋值只剩置 nil），`resetWaitingForReady`/`resetDraftSuspended` 的
  挂起分支、`continuePendingAllReset()` 及 3 个 `onChange` 全部不可达。行为已按"草稿活跃时
  draftConflict 直接拦截"变更（有意），遗留的是误导性死代码。
- **I-N2 每次保存 ≈ 101 次整文件读，I3 成本未降反显性化**｜中｜✓
  `ContentView.swift:200-203` 每次提交触发 `photoPreviews.reload`；worker 端新建 EditPersistence
  （再整读一次）+ 每张最近照片 `readState` 各自 `readStore()` 整文件读（`IOSPhotoPreviews.swift:147-164`、
  `EditPersistence.swift:234-241,395-444`）。X1 建议的"一次读取、批量取状态"接口未出现。
- **I-N3 缩略图渲染对同一原图整文件 SHA-256 做 4–5 遍**｜中低｜✓
  `IOSPhotoPreviews.swift:27-56,196-248`：`IOSPhotoPreviewPlan.init` 全文件哈希（含每个
  LUT/配方资源），`isCurrent` 每次再重建 plan 再哈希。40MB RAW 渲染 320px 缩略图哈希 4–5 遍，
  与 I6 同类，滚动库集中爆发。
- **I-N4 相机"跳过失败项"集合不持久，重启后坏文件反复重试**｜中低｜✓
  `IOSCameraController.swift:101,239-250`：`skippedAssets` 是内存数组；savedKeys 不含失败条目。
- **I-N5 `isItemFailure` 字符串黑名单把瞬时错误也永久标 failed**｜中低｜✓
  `CameraWorkspaceBackend.swift:350-366`：下载期"metadata/chunk size changed"这类会话级瞬时
  错误也判单项失败；`requiresNewImport` 仍靠英文文案相等判断（14.3.3 #9 同源）。建议错误细分枚举。
- **I-N6 photoLimitExceeded 只修了导入半边，tethering 仍整会话断开**｜低到中｜✓
  `CameraWorkspaceBackend.swift:144-148`：`where run.mode == .importing`，tethering 下同一错误
  走 default → 停止 + 通用失败文案。I15 只修了浏览/导入。
- **I-N7 `.atomic` 写崩溃残留的 edits.json 临时副本无人清理**｜低｜待验证
  `EditPersistence.swift:159`：#249 启动清理不含 `Application Support/RawLab/Edits`。量小。
- **I-N8 I7 只删了死代码，单体重算结构未动**｜低｜✓
  `ContentView.swift` 现有 110 个 `@State`（评审基线 107）；`EditorWorkspaceResetControl` 是
  首个外提持状态子视图，方向对，其余不变。
- **I-N9 #258 的 532 行回归测试在 Xcode scheme 外的独立 harness**｜低｜待验证
  `RawLab/tests/CameraSkipAndLimitTests.swift` + `camera-skip-and-limit.sh`：按
  `RawLab/AGENTS.md`，standalone harness 不全进 scheme；核心逻辑覆盖扎实（假 session 注入），
  风险在 CI 是否真正执行它。

### 3.5 Android

- **A-N1 #228 的快照锁没盖住 `EditorEditStore` 的可变引用**｜中｜✓
  `EditorEditStore.kt:34-36`：`store`/`adjustmentSession` 是普通 `var`（非 volatile）；后台
  `adjustmentQueue` 的 `recoverSource → reopen()` 重建这两个引用
  （`EditorAdjustmentHistory.kt:175`），主线程 getter（`EditorViewModel.kt:118-121,:256`）
  与渲染线程无同步读取。"一致快照"只保护了快照本身。
- **A-N2 导出持全局 `sessionsMutex`，批量与编辑器原生调用完全互斥**｜中｜已复核
  `rawlab_jni.cpp:1469-1470` + `NativeProcessor.kt:476-482`：批量导出期间编辑器每次预览最坏
  等一次全尺寸导出；取消是唯一缓解（10.4#1"隐性串行"在取消落地后变成可感知阻塞）。
- **A-N3 export 的 `cancellationSignal` 参数全仓无调用方；迟到取消丢弃已完成文件**｜低｜已复核
  `NativeProcessor.kt:404-412` + `rawlab_jni.cpp:1548-1556`：最后关头取消会删掉已完整渲染的
  文件（语义一致但用户"白等"）；死参数建议删除或 UI 提示。
- **A-N4 `openSaved/openTetherSaved` 提前 return 不复位 preparing，协程不受 onBackground 跟踪**｜低｜待验证
  `CameraImportViewModel.kt:615,173-179,603-611`。saved-photo 打开异常时界面可能滞留"准备中"。
- **A-N5 `preview()` 在 IO 线程读主线程可变字段 `assets`**｜低｜已读
  `CameraImportViewModel.kt:247`：`session`/`cameraId` 特意加 @Volatile 而 `assets` 没有，
  防御不对称说明是遗漏。
- **A-N6 启动清理在主线程全量扫目录+读全部批量 journal，无上限**｜低｜已读
  `RawLabApplication.kt:19-25` + `WorkingCopyCleanup.kt:53-87`：冷启动线性增长，无护栏。
- **A-N7 BatchExportModel 的 journal 操作是主线程同步磁盘 IO**｜低｜已读
  `BatchExportModel.kt:374-407`：Main.immediate 内 journal 整文件读写/删除（X5 同族），
  千行批量任务的准备/放弃界面可能掉帧。
- **A-N8 主线程 SharedPreferences `.commit()` 与 VM 构造期 4 次 getSharedPreferences**｜低｜已读
  `EditorViewModel.kt:209-210,281-311`。VM 首次创建有磁盘延迟。
- **A-N9 releaseStorage"恰好 6 次"魔数**｜低｜已读
  `EditorViewModel.kt:252,268-280,1998-2002`：任何 close 回调缺失/多触发即泄漏或错过关闭；
  新增队列要手改数字。建议 `>=6` 或清单化。
- **A-N10 `EditorAdjustmentHistory.begin()` 已有 interaction 时不校验身份即返回 SAVED**｜低｜待验证
  `EditorAdjustmentHistory.kt:134`：换图与未完成交互编辑交错时，新照片首次编辑可能拿到假
  SAVED、随后 finish 失败被静默中止（A10 原场景残留窗口）。

### 3.6 Windows

- **W-N1 下载/校验/中断类 Failed 永久抑制自动检查，主窗口无提示**｜中｜✓
  `UpdateState.cs:105-115`（`ShouldSkipAutomaticCheck` 对非 Checking 阶段失败无时限 skip）、
  `DesktopUpdateController.cs:175-179,266-267`（自动补查只认 Checking/trust_temporary）、
  `RestoreAfterLaunch` 原样保留 Failed（跨重启）。**#233/#235 的退避只覆盖检查阶段**，
  W2 的原始场景（一次下载失败 → 从此静默）仍在。
- **W-N2 gate 定时器在 Available+延迟退出安装态每秒打一次更新源**｜中｜已读
  `DesktopUpdateController.cs:261-264` + `SoftwareUpdates.cs:14,28`：manual 复查绕过每日节流，
  成功（同 identity）保留 Choice 回到 Available → 下一秒继续，直到失败退避才停。GitHub API
  匿名配额可被整会话消耗。
- **W-N3 预览失败白名单两层都接不住时走模态兜底、默认退出**｜低到中｜已读
  `MainWindow/Rendering.cs:98`（5 种异常）+ `RenderEngine.cs:648`（3 种）：Overflow、
  ObjectDisposed 等逃逸进 `UnhandledExceptionCoordinator`，对话框默认 Exit。W4 兜底有效，
  但"预览失败只降级"未落实（W4 整改方向的另一半）。
- **W-N4 五处同类原子写仍各自为政；新重试只针对共享违规**｜低｜已读
  `UpdateChecker.cs:94-109`、`LookLibrary.cs:373-391`、`FileLibrary.cs:175`、
  `EditedPhotoPreviewCache.cs:58-67`、UsageAnalytics：仍是裸 `File.Move(overwrite)`
  （UpdateChecker 还用固定名 `.tmp`）；杀软瞬时锁文件即一次异常失败。
- **W-N5 编辑/更新状态保存可在 UI 线程同步阻塞至 5s/约 0.7s**｜低｜已读
  `EditPersistence.cs:46-59`（取锁 `Thread.Sleep(10)` 轮询）+ `UpdateStore.cs:253-279`：
  网络盘或残留实例持锁时界面可感知冻结（跨进程互斥本身正确）。
- **W-N6 state.json 结构校验偏严：升级后回滚会触发"存储修复"门禁**｜低｜待验证
  `UpdateStore.cs:52-67`：旧版读不懂新枚举 Phase → `startupStorageBlocked` 挡住编辑区。
  与 Velopack 回滚组合未实测。

### 3.7 仓库与 CI

- **R-N1 #222 的 fork 门禁漏掉 macos job**｜高｜✓
  `.github/workflows/ci.yml:127-131`：macos 的 `if:` 只有 `needs.changes.outputs.macos`，
  没有 windows（`:279-283`）/ios（`:544-548`）那样的来源判断；而它的 arm64 矩阵 runner 就是
  自托管物理 Mac（`scripts/ci/affected_platforms.py:65-70`）。fork PR 改任何共享文件 →
  PR 自带脚本继续在物理机上执行（R1 主体路径未修）。策略测试判定
  （`test_workflow.py:80-84`）用 `"self-hosted" in str(runs-on)` 嗅探，macos 的
  `${{ matrix.runner }}` 表达式天然漏检——**判定方式本身建议换成显式输入字段**。
- **R-N2 fork PR 的 CI result 恒红**｜中｜已读
  `affected_platforms.py:117-121`：select 不感知 fork，windows/ios 仍输出 true；job skip 后
  verify 按 `expected success` 报 mismatch。等于把 fork 支持修成"必红"，而不是路由到托管机
  （R1 建议的方案）。
- **R-N3 fork PR 的缓存无人清理**｜低｜已读
  `pr-cache-cleanup.yml:14-16`：清理 job 本身有来源门禁，但 fork 仍按 merge-ref 写缓存，
  合并后滞留只靠配额 LRU。
- **R-N4 push 基线查询只接受 `run_attempt==1`**｜低｜已读
  `affected_platforms.py:126-135`：绿跑被手动重跑（attempt≥2）后基线"失踪"→ 首个 push 全平台
  冷跑。方向安全，成本放大。
- **R-N5 R5 未修：同分支多次手动触发互相取消**｜低（已知）｜已读
  `ci.yml:25-28`：group 不含 `inputs.platform/checks`。

## 4. 整改台账状态核对

按 PR 名推断的对应关系（评审 §14.0）逐条到代码验证后的结论。"状态"指 `d05c8d7d` 的实际代码，
不是 PR 标题。

### 4.1 基本落地（抽查确认）

| 条目 | 关键证据 |
|---|---|
| C1 LibRaw 线程安全 | `lutools/CMakeLists.txt:64-79` 链 `raw_r`+REQUIRED；52 个测试脚本同步 `-lraw_r`；`raw_thread_safety_tests.cpp` 多线程 memcmp 逐位一致、合成 DNG 必跑 |
| C3 异常兜底 | FFI 入口 `catch(...)`；Metal @try+内层 catch；测试注明"删内层 @catch 必须失败" |
| C4 EGL 绑定恢复 | `gles_lut.cpp:110-137` RAII + fake-EGL 测试（细节见 G-N4；真机 GLES 返回 77 skip） |
| C14 尺寸上限（主体） | 128M 帽 + `ImageData` size_t 化；残留见 C-N1/N2/N9 |
| C27/C28 EXIF | APP1 显式长度 + 复制预算（`display_image_windows.cpp:191-194`、`hdr_metadata.cpp:117-121`） |
| C30 降噪预览分辨率 | CPU/Metal/D3D11 早缩条件补齐 `noise_reduction<=0`，四路径一致 |
| X4 导出写盘可见性 | staging + 短写回调 + 权限保持 + foreign-name 保护（Windows 分支除外，C-N8） |
| X5 坏批量日志隔离 | 损坏改名 quarantine + 单次上报 + `validate()` 取代读回 |
| A4 / #234 导出取消 | Kotlin+JNI+核心三层闭环；`ExportCancellationTest` 462 行（残留见 A-N2/N3） |
| A10 / #228 历史同步 | 单 `AtomicReference<Snapshot>`+CAS；残留见 A-N1/N10 |
| A11/A13 / #257 相机容错 | 单张失败 continue、limit 保连接+专属文案、canSkip 有 UI 入口 |
| W1 更新包名匹配 | `UpdateRelease.cs:11-27` 双格式+版本校验，测试数据换成真实包名 |
| W3 状态写盘（主链路） | `UpdateStore.WriteAtomic` 共享违规重试；运行期失败只记 StorageError 不锁编辑（"五处统一"未做，W-N4） |
| W4 全局兜底 | 三层协调器 + sync-context 回灌；无滥吞（降级策略未做，W-N3） |
| R2 文案键 CI | `tests/test_localization.py` 进 contracts，纯 Python 解析可跑 Linux |
| I13/I15 / #258 | skip/limit 逻辑落地 + 假 session 注入测试（残留 I-N4/N5/N6） |
| I16 / #256/#262 reset 入口 | group/all 可达、消息分离、HDR rendition 重置补齐（新增死代码 I-N1） |
| I18/I19 / #250 跨模式粘贴 | 配方强度换算公式双端一致，Mac/iOS 同提交各带测试 |
| X1 原子写/容错（四端） | flock/原子写/单坏记录隔离/tombstone 方向一致；读侧整文件问题见 §5.3 |

### 4.2 半修或未修（本文 §2.2 的来源）

| 条目 | 实际状态 | 差距 |
|---|---|---|
| M1 HDR 取色 | **未动** | 比较侧仍不带 `hdrFingerprint`（`EditorModel+HSLTarget.swift:13-16`）；文件基线后 0 提交 |
| W2 更新停摆 | **半修** | 检查阶段退避有了；下载/中断阶段仍永久停摆（W-N1）、无主窗口提示 |
| R1 fork 代码执行 | **半修** | macos job 无门禁（R-N1）+ fork result 恒红（R-N2）；"发布判定只对本仓库分支"未做 |
| C14 | **部分** | NATIVE 回退（C-N1）、JPEG 维度（C-N2）、Release 下 assert 失效（C-N9） |
| A3 HDR 外观导入返回键 | **半修** | 守卫补了一半；修订号变化路径仍滞留 `IMPORT_LOOK` 且 BackHandler 失效（`EditorViewModel.kt:757-778,1011-1016`、`EditorScreen.kt:243`） |
| C2/C6/C7 | **仍成立** | 分块变体 `applyChromaDenoiseWorking` 已存在，`gles_photo.cpp:297`/`d3d11_photo.cpp:216` 未接；D3D11 异常全重建仍无退避记忆 |
| M2 | **部分** | 缓存/去重/generation 做了；`record()`/`cachedImage()` 每次仍新建 EditPersistence 全量解码、多路刷新不合并（M-N1） |
| M3 | **仍成立** | SDR 开图仍先整幅中性参考帧且不计 512MB 预算（`EditorModel+Rendering.swift:142-162,303-304`） |
| M4 | **仍成立（微调）** | inspect 只加了 changedInput 校验；串行队列/预览不可取消不变（M-N6） |
| A1 启动重算 | **仍成立** | 只有坏日志隔离落地；恢复仍全量 SHA256（`CameraImportStore.kt:378-380`） |
| I1 / #249 存储回收 | **部分** | tmp 导入副本+无 journal 任务目录有清理；Documents/Exports DNG 与相机原件仍无删除入口，无 UIFileSharingEnabled |
| I7/I8 | **仍成立** | ContentView 110 个 @State；HDRCanvas 主线程逐像素 + 30fps 空闲提交（`HDRPresentation.swift:50-70`、`HDRCanvas.swift:122`） |
| R6 / R8 | **仍成立** | Windows 白名单 23 个测试名无对账机制；`edited` 事件被固化为契约不重跑 |
| reset 模式隔离（#253/#255/#256/#257） | **三端对齐，Windows 漏半条** | Mac/iOS/Android 保留休眠 HDR（含 proRAWDecodeVersion）；Windows `Adjustments.cs:370` `ResetAll` 仍 `hdr.Reset()` 只保 Mode，休眠 HDR 调整被清（✓） |
| §10.1.13 取消回调契约 | **部分** | 提交点/禁抛成文；"可被内部线程池并发调用"仍未写（C-N4） |

## 5. 结构性观察

评审按"端 × 问题"组织；本节按"机制 × 漂移风险"给出评审方法看不到的四个度量结论。

### 5.1 S1 编辑记录：四端独立实现，无共享一致性基线｜中｜✓

同一份"编辑记录"JSON 持久化在四端是**四份独立实现**（Mac/iOS 各一份 Swift、Kotlin、C#，
连序列化方式都不同）。仅最近 60 个 PR：Mac/iOS/Android/Windows 的 `EditPersistence` 各被
触碰 5/3/3/3 次，全部是同一族语义（原子写、容错、迁移回执、reset 保留）。`lutools/docs/edit-json.md`
+ schema 只覆盖 **agent recipe** 格式，不覆盖这个应用侧记录格式；四端各自单测，没有共享
golden fixture。**本轮已经付出的代价**：reset 隔离拆成 4+1 个 PR 后 Windows 仍漏半条
（§4.2），而这条规则在 Mac 上是有测试的参考端行为。
**建议**：建一份跨端 golden fixtures（代表性记录 × 版本 × 迁移/重置场景，含损坏样本），
每端一个 conformance 测试挂进 CI。它同时是 R3（参数字段向量）、R7（精度分派）的落点。

### 5.2 S2 热点与上帝对象：改动最频繁的文件恰是最大文件｜中｜✓

近 300 提交触达次数：Android `EditorViewModel.kt` **24 次**（全仓第一），而它正是全仓最大
源文件（**2004 行**，第二名 845 行）；核心侧 `sony2fuji_c.cpp` 3106 行是所有契约的单一咽喉
（16 次）。iOS `ContentView.swift` `@State` 从 107 涨到 110。Android VM 已出现用魔数对账
生命周期（`releases == 6`，A-N9）。不必大重构，但 Android VM 与 `sony2fuji_c.cpp` 值得按
职责切分排期，否则"每次整改都在最大文件里加 guard"会持续。

### 5.3 S3 X2"热路径整文件读/哈希"是四端共同的最大遗留性能块｜中｜✓

评审把它列为共性第二批，至今四端都未动，而整改期间新增的缓存与身份校验代码把它**显性化**了：
Mac 每张可见缩略图 ≥4 遍全文件 JSON 解析 + LUT 资源每次构键整文件 SHA256（M-N1/N2）；
iOS 每次滑杆提交 ≈101 次整文件读（I-N2）、单缩略图 4–5 遍原图哈希（I-N3）；Android 启动
全量 SHA256（A1 仍成立）；Windows W6 同类。四端缺同一件基础设施：**带失效语义的文件身份
缓存（stat 指纹优先、内容哈希兜底）+ "一次读取、批量取状态"的记录接口**。建议按 Mac 缩略图链
→ iOS 保存路径 → Android 启动恢复的顺序做，收益随用户库规模线性增长。

### 5.4 S4 ABI 守护扎实但有一个已知缺口｜低｜✓

fixture 覆盖两个 ffi 头全部 50 个 struct、Contracts job 每次重生成 diff、Windows 托管镜像
消费同一 fixture——比多数同类项目严。缺口：① 16 个 `typedef enum` 的**取值顺序**不在门禁内
（生成器只记 struct），四端手工对齐，未来中间插值静默漂移（G-N7）；② 生成器硬断言 64 位，
32 位 ABI 不在射程；③ 本地 `test.sh`/ctest 不含它，漂移只在特定 CI job 暴露。修复成本低：
生成器把 enum 常量并入 JSON 即可。

### 5.5 S5 取消已经变成跨层契约，但文档和响应性没跟上｜中｜已读

核心 checkpoint → JNI/FFI → UI 三层这次打通（值得肯定），留下三件事：契约未写"回调并发调用"
（C-N4）；编码阶段无检查点、大导出取消响应秒级（C-N5）；Android 迟到取消会删掉已完整渲染的
文件（A-N3，"白等"体验）。建议集中写一份 processing-cancellation 文档（或并入
color-contract.md），把状态码、检查点粒度、迟到取消语义一次说清。

### 5.6 S6 更新器状态机两周内 5 个补丁，仍是最脆弱模块｜中｜✓

#225/#233/#235/#236/#241 各修一角，W-N1/N2/N6 说明状态机仍按"补丁可达性"而非全矩阵演化。
建议停止增量打补丁，先写一张 `Phase × Failure.Stage × 重启/回滚/杀进程` 的矩阵测试，再收口；
顺带把 5 处裸原子写并进带重试的统一实现（W-N4）。

## 6. 建议处理顺序

1. **R-N1/R-N2**（几行 CI + 策略测试判定方式）：补 macos 门禁、verify 适配 fork-skip。安全属性，
   成本最低，先修。
2. **M1、A3、Windows reset 保留休眠 HDR**：三条"台账说修了"的回归测试先行，修正整改总账；
   每条改动都不大。
3. **更新器收口（S6）**：矩阵测试 + W-N1/N2/N6 + W-N4 一次性做完。
4. **128M 帽决策（C-N1）**：确认 >128MP 原生导出是否该支持；支持则 NATIVE 补解码前预检、
   JPEG 65535 上移到验证层（C-N2），不支持则写进契约文档并给客户端明确 UNSUPPORTED/尺寸类错误码。
5. **取消契约文档化（S5/C-N4）** + Android volatile 补齐（A-N1）+ iOS reset 死代码清理（I-N1）。
6. **X2 批次（S3）**：Mac 缩略图链与 iOS 保存路径优先；新增"文件身份缓存 + 批量取状态"接口。
7. **golden fixtures 一致性基线（S1）**：作为 S3/R3/R7 的公共底座，宜在 X2 改造前建立，
   避免改造再写第四遍语义。
8. 小步清理（一天量级）：`applyChromaDenoiseWorking` 接上两处 GPU 后端、`set_ai_denoise`
   失败回滚（G-N2）、`compute_histogram` 容量校验（G-N6）、X3F panic 载荷透传（G-N10）、
   `at()` Release 有效边界（C-N9）、ABI enum 入 fixture（S4）、journal 版本上限清单化（M-N7）。

## 7. 覆盖缺口与限制

- 未运行任何构建、测试或应用；所有行为结论来自静态读码，"待验证"沿用上文标注。
- 界面层仍只做了关键字检索与取样（SwiftUI 重组/Compose recomposition/WPF 绑定未系统量化）；
  着色器与 CPU 公式的逐行对照、`x3f-bridge` 的 `dp1s.rs`/`settings.rs` 细节、Windows
  `#214` +175 行的逐行 diff、`AbiLayoutChecks.cs` 内部逻辑未全覆盖。
- GitHub 仓库设置（是否公开、fork PR 审批默认、CI result 是否分支保护必需）无法离线核实，
  直接影响 R-N1/R-N2 的严重度定级；W1 类"线上发布页实际文件名"同理。
- 四端 UI 测试按仓库约定不含在普通 CI 内；#258/#262 新增的独立 harness 是否在本地验证记录中
  执行，需查对应 PR 描述（I-N9）。
- 本文行号只对 `d05c8d7d` 有效；继续整改后引用前先重查。
