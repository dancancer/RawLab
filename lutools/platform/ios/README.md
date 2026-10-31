# iOS 集成指南 / iOS Integration

[下载 v0.9.2 未签名 IPA / Download unsigned IPA](https://github.com/dancancer/RawLab/releases/download/v0.9.2/RawLab-iOS-0.9.2-unsigned.ipa) · [发布说明 / Release notes](../../../docs/releases/v0.9/v0.9.2.md)

IPA 需要自行给应用及内嵌 Framework 重新签名，不能直接安装；不是 App Store 或 TestFlight 发行版。最低 iOS 18.0，物理设备安装和峰值内存尚未验证。

Re-sign both the app and embedded framework before installation. This is not an App Store or TestFlight release. Requires iOS 18.0; physical-device installation and peak memory remain unverified.

通过共享 C API 将 Sony2Fuji 核心接入 Swift/Objective-C 应用。此目录是集成文档，不包含可直接运行的独立 iOS 示例项目。

Integrate the Sony2Fuji core into a Swift/Objective-C app through the shared C API. This directory contains integration documentation, not a standalone runnable iOS sample.

旧版文档中的直接 C++ 桥接示例未覆盖完整的 F-Log2 和显示输出处理，已改为调用共享照片 API，避免移动端实现另一套色彩流程。桌面验证结果不代表 iOS 设备已验证。

The former direct-C++ bridge examples omitted parts of F-Log2 and display-output processing. Use the shared photo API instead of implementing a second mobile color pipeline. Desktop verification does not establish iOS device coverage.

RawLab iOS 新编辑显式选择 `rawlab/2/standard`（C5），缺少 `processing` 的旧记录保留版本 1。
C5 在 CPU 上分块滤波；Auto 可以继续 Metal 显示渲染，Force 不支持需要执行 C5 的请求。
移动端预览仍使用既有尺寸策略，完整导出不静默改用其他算法。亮度、色度和粗色斑强度可调，
高强度可能削弱低对比度纹理。处理身份随预览、导出、自动曝光、中性对比图及批量快照传递。

## 1. 构建准备 / Build Prerequisites

正常 X3F 显影需要 Rust 1.88+（CI 使用 1.99.1）、Python 3.11+ 和宿主 libclang。
安装 `aarch64-apple-ios`、`aarch64-apple-ios-sim`、`x86_64-apple-ios` 目标及
`rust-docs`；构建脚本为每个切片设置匹配的 Xcode SDK，许可随框架打包。
`RAWLAB_IOS_SOURCE_CACHE` 可指向共享源码下载目录，编译结果仍按架构隔离。
支持的机型和保存参数见 [X3F 契约](../../docs/x3f-rendering.md)。

需要 macOS、完整 Xcode/iOS SDK、CMake 和 curl。从仓库根目录运行以下入口，自动下载并校验 LibRaw 0.22.2、Adobe DNG SDK 1.7、应用共享相机补丁，编译三个架构并生成应用使用的 XCFramework。iOS 构建不再通过宿主机 `pkg-config` 查找 LibRaw。

Requires macOS, full Xcode/iOS SDK, CMake and curl. From the repository root, this entry point downloads and verifies LibRaw 0.22.2 and Adobe DNG SDK 1.7, applies the shared camera patches, builds three architectures and packages the application's XCFramework. iOS no longer discovers LibRaw through the host `pkg-config`:

```bash
bash lutools/build.sh ios
bash lutools/platform/ios/verify-framework.sh
```

脚本见 [build-framework.sh](build-framework.sh)。默认最低 iOS 18.0，与 RawLab 应用一致；可通过 `IOS_DEPLOYMENT_TARGET` 覆盖，但必须受所选 SDK 支持。`DEVELOPER_DIR` 可选择完整 Xcode，`JOBS` 默认 6。不再要求宿主机 Homebrew LibRaw，也不会混用旧版 0.21.5 依赖。若已有合规的 SDK 源码目录，可将 CMake cache 覆盖参数传给脚本：

See [build-framework.sh](build-framework.sh). The default minimum is iOS 18.0, matching RawLab; `IOS_DEPLOYMENT_TARGET` may override it within the selected SDK's supported range. `DEVELOPER_DIR` selects full Xcode, and `JOBS` defaults to 6. Host Homebrew LibRaw is not required, and old 0.21.5 dependencies are not reused. If a compliant SDK source directory is already available, pass the CMake cache override through the script:

```bash
bash lutools/platform/ios/build-framework.sh \
  -DFETCHCONTENT_SOURCE_DIR_RAWLAB_DNG_SOURCE=/path/to/dng_sdk_1_7_1
```

The production script does not contain a machine-specific SDK path; the shared
`lutools/cmake/dng-sdk.cmake` helper owns the pinned download and checksum.

X-Trans 去马赛克新增每像素 8 字节的只读副本，40 MP 约增加 304 MiB 峰值内存；尚未完成移动设备内存验证，不能把 Mac 实测通过等同于 iOS 大图可用。

X-Trans demosaic adds an eight-byte-per-pixel immutable copy, about 304 MiB for 40 MP. Mobile memory behavior is not yet validated; Mac test success does not establish large-image usability on iOS.

各架构依赖和编译缓存独立存放，旧目录不删除：

Architecture-specific dependencies and build caches are isolated; old directories are retained:

```text
lutools/build-ios-libraw/0.22.2/sources/LibRaw-0.22.2
lutools/build-ios-libraw/0.22.2/core-iphoneos-arm64
lutools/build-ios-libraw/0.22.2/core-iphonesimulator-arm64
lutools/build-ios-libraw/0.22.2/core-iphonesimulator-x86_64
```

框架静态链接目标平台 LibRaw 和 Adobe DNG SDK 1.7，仅动态依赖 iOS 系统库。许可证随 Framework 的 `Licenses` 目录打包，其中完整 DNG SDK notice 位于 `Licenses/dng-sdk/`。生成物通过版本、架构、许可证及动态依赖检查后才替换 `build-ios/sony2fuji.xcframework`；上一份保存在 `build-ios/previous.*/`。

The framework statically links target-platform LibRaw and Adobe DNG SDK 1.7 and dynamically depends only on iOS system libraries. License notices are included in its `Licenses` directory, with the complete DNG SDK notices under `Licenses/dng-sdk/`. Version, architecture, license and dependency checks run before replacing `build-ios/sony2fuji.xcframework`; the previous artifact is retained under `build-ios/previous.*/`.

## 2. Framework 与 Xcode / Frameworks and Xcode

当前 CMake 的 iOS 共享目标生成 `sony2fuji.framework`；共享 raw wrapper 会按当前 Apple SDK 架构构建 LibRaw 与 DNG SDK。设备与模拟器构建必须分别使用对应 SDK。

The current iOS shared CMake target produces `sony2fuji.framework`; the shared raw wrapper builds LibRaw and the DNG SDK for the active Apple SDK architecture. Device and simulator builds require their corresponding SDK.

构建入口已自动将 arm64/x86_64 模拟器二进制合并为一个切片，并与 arm64 设备切片组成 XCFramework；不需要手动重复打包。Xcode 项目继续使用同一路径，无需修改 Framework 引用。

The build entry point combines arm64/x86_64 simulator binaries into one slice and packages it with the arm64 device slice. No manual repackaging or Xcode framework-reference change is needed.

1. 将 Framework/XCFramework 加入目标的 `Frameworks, Libraries, and Embedded Content`，动态 Framework 使用 `Embed & Sign`。
   Add the framework/XCFramework to the target's `Frameworks, Libraries, and Embedded Content`; use `Embed & Sign` for the dynamic framework.
2. 配置头文件搜索路径指向 `lutools/include`，在桥接头中引入下面的 C 头文件。
   Point header search paths to `lutools/include` and import the C header below in the bridging header.
3. Framework 已静态包含目标架构的 LibRaw 与 DNG SDK；仍需按应用签名要求处理 C++ 运行库和嵌入路径。
   The framework statically contains target-architecture LibRaw and the DNG SDK; handle the C++ runtime and embedding paths according to the app's signing requirements.

```objc
#include "sony2fuji/ffi/sony2fuji_c.h"
```

## 3. 共享 C API / Shared C API

以下示例演示一次全分辨率文件导出。输入、LUT 和输出路径由调用方提供，输出不得覆盖原 RAW；不要用 `EXACT` 配合零宽高表示原尺寸。

The example performs one full-resolution file export. The caller supplies input, LUT and output paths; output must not overwrite the RAW. Do not use `EXACT` with zero dimensions to request native size.

```c
#include "sony2fuji/ffi/sony2fuji_c.h"

sony2fuji_status render_photo(const char* input, const char* lut, const char* output) {
    sony2fuji_session* session = NULL;
    sony2fuji_status status = sony2fuji_session_create(&session);
    if (status != SONY2FUJI_STATUS_OK) return status;

    sony2fuji_request request = {0};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_RAW;
    request.input_path = input;
    request.lut_path = lut;
    request.lut_strength = 1.0f;
    request.wb_mode = SONY2FUJI_WB_CAMERA;
    request.temperature = 6500.0f;
    request.brightness = request.contrast = request.saturation = 1.0f;
    request.intent = SONY2FUJI_INTENT_FINAL;
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    request.output_target = SONY2FUJI_TARGET_FILE;
    request.output_path = output;
    request.output_format = SONY2FUJI_OUTPUT_PNG;

    status = sony2fuji_process(session, &request, NULL);
    sony2fuji_session_destroy(session);
    return status;
}
```

交互编辑应复用 session，而不是每个滑杆事件都创建一个。所有同一 session 的调用串行执行；释放输出缓冲用 `sony2fuji_release_buffer`，结束会话用 `sony2fuji_session_destroy`。失败时读取 `sony2fuji_status_message`。

For editing, reuse a session rather than recreating it for every slider event. Serialize all calls on that session. Release output buffers with `sony2fuji_release_buffer` and sessions with `sony2fuji_session_destroy`; inspect `sony2fuji_status_message` on failure.

`SONY2FUJI_WB_CAMERA` 配合 6500 K/0 tint 表示不附加相对 RGB 偏移，不表示相机拍摄色温固定为 6500 K。绝对 RAW Kelvin 使用 `SONY2FUJI_WB_TEMPERATURE`，拍摄值通过 getter 获取。

With `SONY2FUJI_WB_CAMERA`, 6500 K/0 tint adds no relative RGB shift; it does not assert that the camera shot at 6500 K. Use `SONY2FUJI_WB_TEMPERATURE` for absolute RAW Kelvin and the getter for estimated as-shot values.

## 4. Metal 与预览 / Metal and Previews

在已创建的 session 上设置 GPU 模式。Auto 在加速失败时回退 CPU，Force 用于显式验证 GPU，不能作为所有设备都支持的保证。

Set GPU mode on an existing session. Auto falls back to CPU if acceleration fails; Force is for explicit GPU validation, not a guarantee that every device supports it.

```c
sony2fuji_gpu_config config = {0};
config.version = SONY2FUJI_GPU_CONFIG_VERSION;
config.struct_size = sizeof(config);
config.mode = SONY2FUJI_GPU_AUTO;
sony2fuji_session_set_gpu_config(session, &config);
```

预览使用 `SONY2FUJI_INTENT_PREVIEW` 和 `preview_long_edge`；需要输出像素时选择 BUFFER 并传入缓冲结构。缩小预览和交互 half-size 不能替代完整导出；请保留精确渲染与导出的质量隔离。

Use `SONY2FUJI_INTENT_PREVIEW` and `preview_long_edge` for previews. Select BUFFER and supply a buffer struct when requesting pixels. Reduced previews and interactive half-size processing must not replace full-quality exports.

## 5. Swift、资源与性能 / Swift, Resources and Performance

- 使用轻量 Swift/Objective-C 封装调用 C API，在后台串行队列处理图像，在主线程更新 UI。
  Call the C API from a thin Swift/Objective-C wrapper, process images on a serial background queue, and update UI on the main thread.
- 将选择的 CUBE 加入应用资源，传入实际资源路径。例如仓库的 `FLog2_to_ETERNA_65grid_V.1.00.cube`；不能假定 `ETERNA_BT709.cube` 已存在。
  Add the selected CUBE to app resources and pass its real path, such as the repository's `FLog2_to_ETERNA_65grid_V.1.00.cube`; do not assume `ETERNA_BT709.cube` exists.
- 大图会同时占用 RAW、浮点图像、GPU 和显示缓冲内存。限制在途任务、复用当前会话，并及时释放缓冲。
  Large images consume RAW, floating-point, GPU and display buffers. Limit in-flight work, reuse the current session and release buffers promptly.
- 当前应用侧适配可参考 [iOS 处理封装](../../../RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor.swift)；不要把 AppKit 代码直接搬到 iOS。
  See the [iOS processing adapter](../../../RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor.swift); do not copy AppKit-specific code into iOS.

## 6. 排错与参考 / Troubleshooting and References

| 问题 / Symptom | 检查 / Check |
| --- | --- |
| Framework 加载失败 / Framework fails to load | Embed & Sign、SDK、架构、动态依赖路径 / Embedding, signing, SDK, architecture and dependency paths |
| 找不到符号 / Missing symbols | C++、LibRaw 及其依赖是否链接到正确目标 / Correct linkage of C++, LibRaw and its dependencies |
| 输出尺寸无效 / Invalid output size | NATIVE 或正数 EXACT 尺寸 / NATIVE or positive EXACT dimensions |
| 内存或延迟过高 / Excessive memory or latency | 有界预览、串行队列、释放缓冲 / Bounded previews, serial work and buffer release |

[公共头文件](../../include/sony2fuji/ffi/sony2fuji_c.h)是当前接口依据；[C API 说明](../../docs/ios-api.md)中的历史示例应与头文件和本页核对。[色彩约定](../../docs/color-contract.md)定义 LUT 输入及白平衡行为。

The [public header](../../include/sony2fuji/ffi/sony2fuji_c.h) is the current interface reference. Cross-check historical examples in the [C API notes](../../docs/ios-api.md) against the header and this page. The [color contract](../../docs/color-contract.md) defines LUT input and white-balance behavior.

2026-10-09 已完成三个架构的 XCFramework、模拟器 Debug 应用和未签名设备 Release 应用构建；iOS 模拟器上 9 款相机通过 RAW/白平衡回归，其中 3 款通过 Metal 回归，并通过真实 Sony RAW 的应用导出测试。Nikon HE* 样片按预期返回不支持错误。详见[相机兼容性验证记录](../../../docs/archive/compatibility/raw-2026-10-09.md)。设备构建通过不等于真机运行或内存验证。

On 2026-10-09, all three XCFramework architectures, the simulator Debug app and the unsigned device Release app built successfully. On the iOS simulator, nine cameras passed RAW/white-balance regressions, three passed Metal regressions, and the app export test passed with a real Sony RAW. A Nikon HE* fixture returned the expected unsupported error. See the [compatibility report](../../../docs/archive/compatibility/raw-2026-10-09.md). Device build success does not establish physical-device runtime or memory coverage.

```bash
# Use the UUID of a booted simulator and external RAW fixtures.
bash lutools/platform/ios/raw-compatibility.sh <simulator-uuid> /path/to/sample.RW2
RAWLAB_TEST_GPU=1 bash lutools/platform/ios/raw-compatibility.sh <simulator-uuid> /path/to/sample.CR3
```

The compatibility harness links its small native test executables against the
LibRaw headers in `build-ios-libraw/0.22.2/sources/LibRaw-0.22.2`; it no longer
expects a separately installed per-architecture LibRaw package.

## 7. DNG JPEG XL 回归 / DNG JPEG XL Regression

JPEG XL DNG 必须使用专用 harness 验证；旧的 `raw-compatibility.sh` 直接
引用 LibRaw `unpack`，没有 Adobe DNG SDK host，不能作为 JPEG XL 解码依据。
先构建并验证 XCFramework，再使用一个 arm64 模拟器 UUID 运行四个仓库
fixture（普通 JPEG XL、未压缩参考、GainMap、独立双倍参考），可选地追加
外部 DNG。脚本只读取外部文件，并将副本放入被忽略的临时目录：

```bash
JOBS=4 bash lutools/platform/ios/build-framework.sh \
  -DFETCHCONTENT_SOURCE_DIR_RAWLAB_DNG_SOURCE=/path/to/dng_sdk_1_7_1
bash lutools/platform/ios/dng-jxl.sh <arm64-simulator-uuid> \
  /path/to/optional.dng
```

The dedicated harness links `tests/dng_jxl_tests.cpp` against the packaged
simulator framework, stages the four repository fixtures in an ignored local
simulator-test directory, and sets `TMPDIR` there so the deliberately corrupt
JPEG XL copy is created and removed outside the source tree. It verifies lossless
linear output, GainMap behavior, decoder reuse, CPU/Auto-matching C ABI
rendering, and `PROCESSING_ERROR` for corrupt JPEG XL rather than an I/O or
unsupported error. Set `RAWLAB_KEEP_TEMP=1` to retain the staged files and log
for diagnosis.
