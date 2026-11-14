# 处理并发与取消契约

本文定义 `lutools` 共享核心（`sony2fuji_c.h` 与 `sony2fuji_hdr.h`）在当前实现中的线程、会话序列化与协作式取消契约。所有结论均以仓库实际代码为准。

## 1. 谁能调用核心（线程亲和性与 UI 线程）

- **无主线程／UI 线程亲和性**：核心入口均在**当前调用线程同步执行**，不会隐式派发到主线程或后台队列（例如 AI 准备进度回调注释 `lutools/include/sony2fuji/ffi/sony2fuji_c.h:469` 明确只在调用线程同步触发）。
- **能否在 UI 线程直接调**：纯内存／轻量查询（如 `sony2fuji_sample_tone_curve`、`sony2fuji_validate_look`、已在串行时机读取的缓存 getter）技术上可在任意线程调用；但 `sony2fuji_process`、`sony2fuji_session_prepare_ai`、`sony2fuji_session_create_hsl_probe`、`sony2fuji_session_migrate_processing` 及 `sony2fuji_hdr_*` 解码／渲染／导出包含同步磁盘 I/O、CPU 多线程计算和 GPU 等待，**不得在 UI 线程直接调用以免阻塞界面**，应由宿主的后台 worker 线程调用（参见 `sony2fuji_c.h:540,614`）。
- **调用线程局部状态与返回指针生命周期**：
  - 协作式取消作用域安装在调用线程的 `thread_local ProcessingCancellation processingCancellation` 上（`lutools/src/core/processing_cancellation.h:20-29`）。
  - Android GLES 在每次渲染期间绑定独立 `EGLContext`，退出时恢复调用线程原有的 `EGLDisplay`/`EGLSurface`/`EGLContext`（`lutools/src/gpu/gles_photo.cpp:38-57`）。
  - 返回 `const char*` 的诊断接口不得跨并发调用持有：`sony2fuji_ai_get_devices` 使用 `thread_local std::string`（`lutools/src/ffi/sony2fuji_c.cpp:1877`），其余 session 级错误字符串（`get_ai_diagnostics`、`get_ai_error`、`get_ai_backend`、`x3f_error`）绑定所属 `session` 的生命周期与下一次调用。

## 2. 必须序列化到什么粒度

- **同一 `sony2fuji_session` 必须由调用方严格串行化**：`struct sony2fuji_session`（`lutools/src/ffi/sony2fuji_c.cpp:63-122`）内部没有任何互斥锁，直接持有可变的 `raw_cache`、`raw_processor`、`x3f_processor`、`wavelet_cache`、`dehaze_analysis`、`lens_report`、`geometry_width/height`、`last_backend`、`cancellation_callback/context`、GPU 渲染器与 AI 状态。
  - 所有传入同一 `session` 的函数——包括 setter、`sony2fuji_process`、HDR session 入口，以及签名为 `const sony2fuji_session*` 的 getter、`sony2fuji_session_create_hsl_probe`（会临时改写并恢复 `session->gpu_config`、`last_backend` 和 `geometry_width/height`，见 `sony2fuji_c.cpp:2877-2888`）和 `sony2fuji_session_migrate_processing`（读取 `source` 字段构造私有栈上 `worker` 会话，见 `sony2fuji_c.cpp:2714-2736`）——**均不得在同一 `session` 上并发执行**。
  - 唯一允许跨线程并发写的是宿主自己的原子取消标志（由后台会话串行调用 `sony2fuji_session_set_cancellation_callback` 注册后，由 UI／调度线程更新其上下文中的原子量，`sony2fuji_c.h:790-795`）。
- **跨 `session` 与无状态入口无需宿主加同一把会话锁**：
  - 不同 `sony2fuji_session*` 实例拥有各自独立的缓存与处理器，可由不同后台线程并发驱动（例如交互预览 session 与导出／迁移／兼容预览独立 worker session，`sony2fuji_c.h:614`）。
  - 已生成的 `sony2fuji_hsl_probe*` 在销毁前只读，可脱离原 `session` 调用 `sony2fuji_hsl_probe_sample`（`sony2fuji_c.cpp:2903-2948`）；`sony2fuji_hdr_image_pair_v1` 的句柄表由内部 `ownersMutex` 保护（`lutools/src/ffi/sony2fuji_hdr.cpp:45,145,213,1123`）。

## 3. 取消回调是否可能被多个内部线程并发调用

**是。** 取消回调 `sony2fuji_cancel_callback` 在单次核心调用期间**会被多个内部工作线程并发调用**，回调实现必须无锁（如读取 `std::atomic`）或自行加锁，且不得抛异常、不得重入当前 `session`（`sony2fuji_c.h:791-795`）。

主要并发调用链如下：

1. **OpenCV 并行像素分块（`parallelPixelRanges`）**：
   - 调用线程在 `lutools/src/core/parallel_pixels.h:14-16` 从 `thread_local` 拷贝 `const auto cancellation = processingCancellation;` 并先执行一次 `cancellation.check()`；
   - 当启用色度／小波降噪且像素数 `count >= 4 * 16384`（65536）时，`parallel_pixels.h:24-28` 调用 `cv::parallel_for_` 将任务切分为 16384 像素块分发到 OpenCV 线程池；
   - **多个 OpenCV worker 线程同时执行 `bounded`**（`parallel_pixels.h:17-21`），每 16384 像素调用一次 `!cancellation.cancelled()` → `callback(context)`（`processing_cancellation.h:16`）。工作线程内只提前跳出分块循环、不跨线程抛异常；待 `cv::parallel_for_` 汇合后，由调用线程在 `parallel_pixels.h:29` 调用 `cancellation.check()` 抛出 `ProcessingCancelled`。
   - 该模板被基础影调、氛围、色调控制、X3F 后处理及 HDR 细节／渲染广泛调用（如 `photo_basic_controls_v3.cpp:69`、`photo_atmosphere.cpp:33`、`sony2fuji_c.cpp:815,943,2659`、`sony2fuji_hdr.cpp:413,880`）。
2. **OpenMP 并行循环**：当 `SONY2FUJI_ENABLE_OPENMP` 开启且像素数达到 `65536` 时，`#pragma omp parallel for` 的多个 OpenMP 线程并发调用 `cancellation.cancelled()`（`lutools/src/core/color_converter.cpp:45-52,72-79`、`photo_effects.cpp:145-152`、`photo_lut.h:47-57,66-76`、`raw_processor.cpp:472-503,1176-1188`、`sony2fuji_c.cpp:972-979`）。
3. **Normal X3F 轮询线程**：`X3fCancellation`（`lutools/src/core/x3f_processor.cpp:30-50`）在解码期间启动独立 `std::thread` 每 10 ms 调一次 `cancellation.cancelled()`，并在触发时调用 `rawlab_x3f_cancel(token)`，与调用线程并发运行。

## 4. 取消语义与生效阶段

### 生效入口与返回码

- **生效范围**：
  - `sony2fuji_process`：仅当 `output_target == SONY2FUJI_TARGET_BUFFER || intent == SONY2FUJI_INTENT_FINAL` 时安装会话取消回调（`sony2fuji_c.cpp:2830-2834`）；**`PREVIEW + FILE` 明确忽略取消回调**。
  - 始终响应会话取消回调的入口：`sony2fuji_session_create_hsl_probe`（`sony2fuji_c.cpp:2894`）、`sony2fuji_session_migrate_processing`（`sony2fuji_c.cpp:2711`）、`sony2fuji_session_prepare_ai`（P2-15/C10 起安装 `ProcessingCancellationScope`，在身份哈希、tile 进度与缓存发布前轮询）、带 `session` 的 `sony2fuji_hdr_*` 解码／AI 准备／ProRAW 导出／HSL probe／流式导出（`sony2fuji_hdr.cpp:322,613,716,730,749,948,981`；其中 `sony2fuji_hdr_export_stream` 同时合并 `session` 回调与 `source->is_cancelled`，见 `:1088-1091`；`sony2fuji_hdr_render` 在启用 look／细节／效果时生效，见 `:574-575`）。
  - 独立机制或不支持会话取消的入口：`sony2fuji_preview_lut_compatibility` 与 `sony2fuji_session_estimate_auto_exposure` 不读取 `session->cancellation_callback`。`sony2fuji_session_prepare_ai` 的专属 `sony2fuji_ai_progress_callback` 返回 `0` 取消语义保留，并与会话取消回调双通道并存：任一通道取消都返回 `SONY2FUJI_STATUS_CANCELLED`，且不发布新的 AI 缓存文件（`cache.store` 的 `beforePublish` 在 rename 前抛出）。
- **统一返回与状态保证**：内部检查点通过 `ProcessingCancelled` 异常中断管线，在 FFI 边界映射为 `SONY2FUJI_STATUS_CANCELLED`（`sony2fuji_c.cpp:2836-2837`、`sony2fuji_hdr.cpp:102`）。取消**绝不触发 GPU Auto 向 CPU 的回退**（`lutools/src/gpu/gles_photo.cpp:327`、`lutools/src/gpu/metal_photo.mm` 与 `lutools/src/gpu/d3d11_photo.cpp` 的 `ProcessingCancelled` 重抛、`sony2fuji_c.cpp:2836`），不污染已有缓存，且同一 `session` 可继续处理后续请求。

### 五个阶段的行为

| 阶段 | 代码检查点依据 | 触发取消后的行为 |
| :--- | :--- | :--- |
| **1. 解码前** | `processImpl` 入口及参数／路径准备处（`sony2fuji_c.cpp:2312,2422`） | 立即返回 `SONY2FUJI_STATUS_CANCELLED`；`out_buffer` 置空，`geometry_width/height` 清零，已有 `raw_cache`／`wavelet_cache` 保持不变。 |
| **2. 解码中** | LibRaw 进度回调 `RawCancellationScope`（`raw_processor.cpp:75-87,172,254,266,806`）；X3F 10 ms 监控线程与 `rawlab_x3f_decode` 返回码 `4`（`x3f_processor.cpp:34-50,120-125`）；内存输入每 4096 像素（`sony2fuji_c.cpp:1285`）；ProRAW DNG `Sniff()`（`proraw_source.cpp:137,283-298`） | 中止解码并回收半成品解码器状态，不写入 `raw_cache`／`base_` 缓存，清理 ProRAW 临时目录，返回 `CANCELLED`。 |
| **3. 处理中** | CPU：`parallelPixelRanges` 每 16384 像素（`parallel_pixels.h:19`）、OpenMP 分块、逐 4096 像素／逐行几何缩放循环（`photo_geometry.cpp:100,126,143`、`sony2fuji_c.cpp:860,965-1039,2521-2626`）；GPU：GLES 分带上传／dispatch／读回边界（`gles_photo.cpp:164-190`） | 已提交的单个 GPU dispatch 或外部单核调用跑完当前步后在下一检查点停下，跳过后续阶段，不进入 CPU fallback，不产出半成品 buffer 或 HSL probe。 |
| **4. 编码中** | 内存输出逐行检查（`writeOutputBuffer`，`sony2fuji_c.cpp:1357`）；JPEG 量化分块与每写出 16 KiB `longjmp` 中断（`raw_processor.cpp:1084-1121,1166-1211`）；PNG 每满 65536 像素扫描线检查（`raw_processor.cpp:1305-1312`）；Rendered DNG 预览与 16-bit 扫描线每满 65536 像素检查（`rendered_dng.cpp:453-460,574,608-615,635`）；HDR JPEG 扫描线检查（`hdr_jpeg.cpp:402,476`） | 未提交内存由 RAII 释放，`out_buffer` 保持 `{nullptr, 0}`；文件编码仅写入目标同目录 staging 临时文件（`.rawlab-*`／`rl*.tmp`），中断时析构函数关闭并删除 staging 文件，目标路径不创建或与取消前逐字节一致。 |
| **5. 提交点与提交点之后** | 提交点：编码及 flush 完成后、原子替换前的最后一次 `checkProcessingCancellation()`（`raw_processor.cpp:1221,1338`、`rendered_dng.cpp:644`、`hdr_image_apple.mm:405`、`hdr_image_portable.cpp:279,296`）；提交操作：`rename`／`MoveFileExW`（`raw_processor.cpp:1032-1047`） | **提交点前**取消仍删除 staging、保留原目标文件并返回 `CANCELLED`。**一旦原子替换成功（提交点之后）**，不再执行任何取消检查（`finishOutput` 直接更新 `geometry_width/height` 并返回 `SONY2FUJI_STATUS_OK`，`sony2fuji_c.cpp:1413-1418`）：迟到的取消信号**绝不删除已发布文件，也绝不把返回状态改成 `CANCELLED`**。 |

### 平台侧消费方规则（Q12 裁定）

第 5 行的提交点语义同样约束平台导出包装层：平台不得在核心已返回 `SONY2FUJI_STATUS_OK` 之后再用自己的取消标志把结果删掉或改判，否则会重新引入「提交点之后迟到的取消删掉已渲染文件、用户白等」的问题。

- **判据**：对文件目标，`status == OK` 当且仅当提交点（原子替换）已成功且文件已发布；`status == CANCELLED` 当且仅当取消到达在提交点之前的检查点。平台侧「完成时取消到达」= `OK` + 平台自身取消世代（generation）已失配。
- **后果**：该情形平台不得删除已发布文件，不得把结果改写成取消；导出继续发布到最终目的地（系统相册／SAF、批量输出等）并提示完成。提交点之前的取消维持删除暂存、返回取消的既有语义（#289/#293）。
- **Android 落地**：`rawlab_jni.cpp` 仅在 `status == CANCELLED` 时清理目标路径；`NativeProcessor.executeExport`、`EditorRenderer` 普通／HDR 导出分支与 `BatchRunner` 行循环把提交点之后的取消观察统一按完成收尾；编辑器 `cancelExport()` 使结果 revision 失效时，由 `EditorStateReducer.lateExportCompleted` 在 discard 路径提示完成（文案 `export_done`）而非取消成功。

BUFFER（预览）路径没有已发布文件，不受本规则约束：迟到取消仍按取消处理。

## 5. 多个会话是否真并行

不同 `sony2fuji_session` 在解码与像素缓冲上相互独立（内建 LibRaw 补丁与 `qDNGThreadSafe=1` 支持多线程独立实例解码，由 `lutools/tests/raw_thread_safety_tests.cpp` 验证），但跨会话并发仍受以下**进程级全局锁与共享线程池**约束，并非完全无共享并行：

- **单槽全局 Look 缓存互斥锁**：`LUTParser::loadLUTCached`（`lutools/src/core/lut_parser.cpp:315-324`）、`loadDcpLookCached`（`lutools/src/core/dcp_look.cpp:72-80`）和 `hdr::loadLook`（`lutools/src/core/hdr_look.cpp:35-40`）各自持有一把 `static std::mutex` **横跨磁盘读取与解析全过程**，且只缓存最后 1 个路径；多会话交替加载不同 `.cube`／`.dcp` 时会串行等待并互相驱逐单槽缓存。
- **GPU 后端全局互斥与共享队列**：
  - 小波／导向滤波通用计算上下文 `computeContext().mutex`（`lutools/src/gpu/denoise.cpp:18,37`）在进程内串行化所有经该后端的 GPU 滤波调用；独立 GLES LUT 路径同样由全局 `gles_mutex` 串行化（`lutools/src/gpu/gles_lut.cpp:32,306`），`sharedDisplay()` 初始化带静态锁（`gles_photo.cpp:29-30`）。
  - macOS／iOS Metal 旧版独立降噪／锐化路径持有 `ctx.work` 全局互斥锁（`lutools/src/gpu/metal_denoise.mm:21,106,146`、`metal_sharpen.mm:23,83`）；主渲染路径共用进程级单例 `MTLCommandQueue`（`metal_photo.mm:90`），且在查找／上传 LUT 与 DCP 纹理缓冲时加 `gLUTCacheMutex`／`gDcpCacheMutex`（`metal_photo.mm:113,126,675,759,782`）。
- **AI 磁盘缓存与文件跟踪锁**：AI tile 缓存目录写入与 Windows 文件变更跟踪使用进程级静态互斥锁（`lutools/src/gpu/ai/dualdn_cache.cpp:95-99`、`lutools/src/core/windows_file_changes.h:110-114`）。
- **共享内部 CPU 线程池**：各会话共用进程内的 OpenCV `cv::parallel_for_` 线程池与 OpenMP 线程组（含 LibRaw VNG／X-Trans 并行插值及 `hdr_heif.cpp:51` 的 libheif 多线程解码）；多会话同时跑满大图 CPU 管线时，会竞争同一组硬件线程。
