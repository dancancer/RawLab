# iOS 集成指南 / iOS Integration

[下载 v0.5.0 未签名 IPA / Download unsigned IPA](https://github.com/dancancer/RawLab/releases/download/v0.5.0/RawLab-iOS-0.5.0-unsigned.ipa) · [发布说明 / Release notes](../../../docs/releases/v0.5.0.md)

IPA 需要自行给应用及内嵌 Framework 重新签名，不能直接安装；不是 App Store 或 TestFlight 发行版。最低 iOS 18.0，物理设备安装和峰值内存尚未验证。

Re-sign both the app and embedded framework before installation. This is not an App Store or TestFlight release. Requires iOS 18.0; physical-device installation and peak memory remain unverified.

通过共享 C API 将 Sony2Fuji 核心接入 Swift/Objective-C 应用。此目录是集成文档，不包含可直接运行的独立 iOS 示例项目。

Integrate the Sony2Fuji core into a Swift/Objective-C app through the shared C API. This directory contains integration documentation, not a standalone runnable iOS sample.

旧版文档中的直接 C++ 桥接示例未覆盖完整的 F-Log2 和显示输出处理，已改为调用共享照片 API，避免移动端实现另一套色彩流程。桌面验证结果不代表 iOS 设备已验证。

The former direct-C++ bridge examples omitted parts of F-Log2 and display-output processing. Use the shared photo API instead of implementing a second mobile color pipeline. Desktop verification does not establish iOS device coverage.

## 1. 构建准备 / Build Prerequisites

需要 macOS、完整 Xcode/iOS SDK、CMake、pkg-config 和 curl。从仓库根目录运行以下入口，自动下载并校验 LibRaw 0.22.2、应用共享相机补丁、编译三个架构并生成应用使用的 XCFramework：

Requires macOS, full Xcode/iOS SDK, CMake, pkg-config and curl. From the repository root, this entry point downloads and verifies LibRaw 0.22.2, applies the shared camera patches, builds three architectures and packages the application's XCFramework:

```bash
bash lutools/build.sh ios
bash lutools/platform/ios/verify-framework.sh
```

脚本见 [build-framework.sh](build-framework.sh)。默认最低 iOS 18.0，与 RawLab 应用一致；可通过 `IOS_DEPLOYMENT_TARGET` 覆盖，但必须受所选 SDK 支持。`DEVELOPER_DIR` 可选择完整 Xcode，`JOBS` 默认 6。不再要求宿主机 Homebrew LibRaw，也不会混用旧版 0.21.5 依赖。

See [build-framework.sh](build-framework.sh). The default minimum is iOS 18.0, matching RawLab; `IOS_DEPLOYMENT_TARGET` may override it within the selected SDK's supported range. `DEVELOPER_DIR` selects full Xcode, and `JOBS` defaults to 6. Host Homebrew LibRaw is not required, and old 0.21.5 dependencies are not reused.

X-Trans 去马赛克新增每像素 8 字节的只读副本，40 MP 约增加 304 MiB 峰值内存；尚未完成移动设备内存验证，不能把 Mac 实测通过等同于 iOS 大图可用。

X-Trans demosaic adds an eight-byte-per-pixel immutable copy, about 304 MiB for 40 MP. Mobile memory behavior is not yet validated; Mac test success does not establish large-image usability on iOS.

各架构依赖和编译缓存独立存放，旧目录不删除：

Architecture-specific dependencies and build caches are isolated; old directories are retained:

```text
lutools/build-ios-libraw/0.22.2/install/iphoneos-arm64/lib/pkgconfig
lutools/build-ios-libraw/0.22.2/install/iphonesimulator-arm64/lib/pkgconfig
lutools/build-ios-libraw/0.22.2/install/iphonesimulator-x86_64/lib/pkgconfig
```

框架静态链接目标平台 LibRaw，仅动态依赖 iOS 系统库。许可证随 Framework 的 `Licenses` 目录打包。生成物通过版本、架构及动态依赖检查后才替换 `build-ios/sony2fuji.xcframework`；上一份保存在 `build-ios/previous.*/`。

The framework statically links target-platform LibRaw and dynamically depends only on iOS system libraries. License notices are included in its `Licenses` directory. Version, architecture and dependency checks run before replacing `build-ios/sony2fuji.xcframework`; the previous artifact is retained under `build-ios/previous.*/`.

## 2. Framework 与 Xcode / Frameworks and Xcode

当前 CMake 的 iOS 共享目标生成 `sony2fuji.framework`。设备与模拟器构建必须分别使用对应 SDK 和 LibRaw。

The current iOS shared CMake target produces `sony2fuji.framework`. Device and simulator builds require their corresponding SDK and LibRaw.

构建入口已自动将 arm64/x86_64 模拟器二进制合并为一个切片，并与 arm64 设备切片组成 XCFramework；不需要手动重复打包。Xcode 项目继续使用同一路径，无需修改 Framework 引用。

The build entry point combines arm64/x86_64 simulator binaries into one slice and packages it with the arm64 device slice. No manual repackaging or Xcode framework-reference change is needed.

1. 将 Framework/XCFramework 加入目标的 `Frameworks, Libraries, and Embedded Content`，动态 Framework 使用 `Embed & Sign`。
   Add the framework/XCFramework to the target's `Frameworks, Libraries, and Embedded Content`; use `Embed & Sign` for the dynamic framework.
2. 配置头文件搜索路径指向 `lutools/include`，在桥接头中引入下面的 C 头文件。
   Point header search paths to `lutools/include` and import the C header below in the bridging header.
3. 同时处理目标架构的 LibRaw、C++ 运行库和其他动态依赖，并检查签名与加载路径。
   Include target-architecture LibRaw, the C++ runtime and other dynamic dependencies, checking signatures and load paths.

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

2026-10-09 已完成三个架构的 XCFramework、模拟器 Debug 应用和未签名设备 Release 应用构建；iOS 模拟器上 9 款相机通过 RAW/白平衡回归，其中 3 款通过 Metal 回归，并通过真实 Sony RAW 的应用导出测试。Nikon HE* 样片按预期返回不支持错误。详见[相机兼容性验证记录](../../../docs/verification-raw-compatibility-2026-10-09.md)。设备构建通过不等于真机运行或内存验证。

On 2026-10-09, all three XCFramework architectures, the simulator Debug app and the unsigned device Release app built successfully. On the iOS simulator, nine cameras passed RAW/white-balance regressions, three passed Metal regressions, and the app export test passed with a real Sony RAW. A Nikon HE* fixture returned the expected unsupported error. See the [compatibility report](../../../docs/verification-raw-compatibility-2026-10-09.md). Device build success does not establish physical-device runtime or memory coverage.

```bash
# Use the UUID of a booted simulator and external RAW fixtures.
bash lutools/platform/ios/raw-compatibility.sh <simulator-uuid> /path/to/sample.RW2
RAWLAB_TEST_GPU=1 bash lutools/platform/ios/raw-compatibility.sh <simulator-uuid> /path/to/sample.CR3
```
