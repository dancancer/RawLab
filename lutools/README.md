# Sony2Fuji / RawLab Core

将跨品牌 RAW 显影后应用富士 F-Log2 LUT 的 C++ 核心和命令行工具，历史 API 名称保留 `sony2fuji`。

A C++ core and CLI for developing cross-brand RAW files and applying Fujifilm F-Log2 LUTs. The historical `sony2fuji` API names remain unchanged.

原生桌面体验见 [RawLab Mac](../RawLabMac/README.md)。色彩流程与验收边界以[照片渲染约定](docs/color-contract.md)为准。

See [RawLab Mac](../RawLabMac/README.md) for the native desktop editor. The [photo rendering contract](docs/color-contract.md) defines the color pipeline and its verification limits.

## 功能 / Features

- LibRaw 解码、浮点相机矩阵、线性曝光与白平衡，保留负值和超白值。
  LibRaw decoding, floating-point camera matrices, and linear exposure/white balance preserve negative and super-white working values.
- F-Gamut 转换、F-Log2 编码和 CUBE 三线性插值，支持中性与胶片结果混合。
  F-Gamut conversion, F-Log2 encoding and trilinear CUBE interpolation, with neutral/film blending.
- 输出 JPEG 与真正的 16-bit PNG；共享 C API 供 Mac、iOS 和 Android 集成。
  JPEG and genuine 16-bit PNG output, with a shared C API for Mac, iOS and Android integration.
- Apple 平台提供 Metal 照片处理；Android 提供 OpenGL ES LUT 后端。RAW 解包和去马赛克仍由 CPU 执行。
  Metal photo processing is available on Apple platforms; Android has an OpenGL ES LUT backend. RAW unpacking and demosaicing remain on the CPU.

## 架构与目录 / Architecture and Layout

```text
Mac / iOS / Android / CLI
          |
     Shared C API
          |
  LibRaw -> Linear RGB -> F-Gamut / F-Log2 -> LUT -> Display / Export
```

| 路径 / Path | 用途 / Purpose |
| --- | --- |
| `src/core/` | RAW、白平衡、曝光、色域和 LUT / RAW, WB, exposure, gamut and LUT processing |
| `src/ffi/` | 共享 C API 实现 / Shared C API implementation |
| `src/gpu/` | Metal / OpenGL ES 后端 / Metal and OpenGL ES backends |
| `src/cli/` | 命令行入口 / CLI entry point |
| `include/sony2fuji/` | 公共 C/C++ 头文件 / Public C/C++ headers |
| `platform/` | 移动端集成 / Mobile integration |
| `tests/` | 数值、RAW 和 GPU 回归 / Numerical, RAW and GPU regressions |
| `F-Log2/`, `flog-2-new/` | LUT 文件和说明 / LUT assets and documentation |
| `examples/`, `docs/` | 示例与文档 / Examples and documentation |

## 构建依赖 / Dependencies

- CMake 3.15+、C++17 编译器、pkg-config、LibRaw、zlib。
  CMake 3.15+, a C++17 compiler, pkg-config, LibRaw and zlib.
- stb 图像编解码头文件随源码提供；OpenMP 为可选的 CPU 并行支持。
  stb image codec headers are included in the source; OpenMP is optional for CPU parallelism.
- Metal 构建需要 Apple 开发工具。移动端还需要对应 SDK 和目标平台的 LibRaw，不能链接宿主机库。
  Metal builds require Apple developer tools. Mobile builds also require the target SDK and target-platform LibRaw, not the host library.

## 快速开始 / Quick Start

以下命令在仓库根目录运行。构建 CLI：

Run these commands from the repository root to build the CLI:

```bash
cmake -S lutools -B lutools/build -DCMAKE_BUILD_TYPE=Release
cmake --build lutools/build -j 6
mkdir -p output
```

在当前工作空间的 macOS 环境中，必要时先设置 `DEVELOPER_DIR=/Library/Developer/CommandLineTools`。Mac 应用的 SDK 和打包流程由 `bash RawLabMac/build.sh` 管理。

In this macOS workspace, set `DEVELOPER_DIR=/Library/Developer/CommandLineTools` when needed. The Mac app's SDK selection and packaging are handled by `bash RawLabMac/build.sh`.

应用仓库内的 ETERNA LUT：

Apply the bundled ETERNA LUT:

```bash
lutools/build/sony2fuji RawLab/RawLab/Resources/Samples/DSC09067.ARW \
  -l lutools/flog-2-new/FLog2_to_ETERNA_65grid_V.1.00.cube \
  -o output/eterna.jpg
```

输出中性参考或调整曝光基准：

Render a neutral reference or select an exposure baseline:

```bash
lutools/build/sony2fuji input.ARW --no-lut -o output/neutral.png
lutools/build/sony2fuji input.ARW --raw-exposure preview --exposure 0.5 -o output/preview.jpg
```

CLI 每次接收一个输入文件，批处理需要 shell 循环，而不是把多个 RAW 作为位置参数：

The CLI accepts one input file per invocation. Use a shell loop for a batch instead of passing multiple RAW paths as positional arguments:

```bash
for raw in lutools/examples/*.ARW; do
  [ -f "$raw" ] || continue
  name="$(basename "$raw" .ARW)"
  lutools/build/sony2fuji "$raw" \
    -l lutools/flog-2-new/FLog2_to_ETERNA_65grid_V.1.00.cube \
    -o "output/$name.jpg"
done
```

## RAW 与 LUT 兼容性 / RAW and LUT Compatibility

RAW 格式支持取决于 LibRaw。现有回归覆盖 Sony ARW 和本地可选 DJI DNG，不代表所有品牌、机型或光源都经过颜色标定。

RAW format support depends on LibRaw. Current regressions cover Sony ARW and an optional local DJI DNG fixture; this does not establish color calibration for every brand, model or illuminant.

照片 API 接受声明兼容 F-Gamut / F-Log2 输入、BT.709 输出色域的 LUT，不再限制胶片输出名称。`Gamma` 必须为 `F-Log2 to <非空外观名称>`；纯 `F-Log2 to F-Log2` 技术转换仍被拒绝。自定义 LUT 应提供符合应用 sRGB 约定的显示输出；校验不分析表格的实际传递函数。桌面胶片选择器排除技术转换 LUT 和 WDR。

The photo API accepts LUTs declaring F-Gamut / F-Log2 input and BT.709 output gamut without a film-name allowlist. Gamma must declare `F-Log2 to <nonempty look name>`; the technical `F-Log2 to F-Log2` conversion is still rejected. Custom LUTs must provide display output matching the application's sRGB convention; validation does not analyze the table's actual transfer behavior. The desktop film picker excludes technical conversion LUTs and WDR.

`FLog2 -> FLog2 BT.709` 是技术色域转换，不是照片胶片外观。F-Gamut C、Log 输出或未声明输入约定的 LUT 不能直接当成兼容照片 LUT。

`FLog2 -> FLog2 BT.709` is a technical gamut conversion, not a display film look. F-Gamut C, Log-output LUTs and LUTs without a declared input contract are not interchangeable with compatible photo LUTs.

## 渲染流程 / Rendering Pipeline

1. LibRaw 处理黑电平、有效区域、相机白平衡和去马赛克；不启用自动亮度。
   LibRaw handles black levels, the active area, camera-space WB and demosaicing without auto brightness.
2. 转成浮点线性 RGB，应用固定基础曝光及用户输入调整，保留工作范围。
   Convert to floating-point linear RGB and apply the fixed exposure baseline and user input adjustments without prematurely clipping the working range.
3. 胶片分支转换至 F-Gamut / F-Log2 后查 LUT；中性分支使用保留高光层次的显示映射。
   The film branch converts to F-Gamut / F-Log2 before LUT lookup; the neutral branch uses a highlight-preserving display mapping.
4. 混合强度、成片微调和编码导出。精确渲染与导出不会使用低质量交互 RAW 缓存。
   Apply strength blending, finishing adjustments and output encoding. Exact rendering and export never reuse reduced-quality interactive RAW caches.

## 验证 / Verification

```bash
bash lutools/test.sh
```

该脚本配置 `lutools/build-verify`、构建并运行 CTest。可在支持 Metal 的 Mac 上显式运行通用 LUT 的 GPU/CPU 对比：

The script configures `lutools/build-verify`, builds it and runs CTest. On a Metal-capable Mac, explicitly enable the generic LUT GPU/CPU comparisons:

```bash
SONY2FUJI_TEST_GPU=1 ctest --test-dir lutools/build-verify -R color_contracts --output-on-failure
```

缺少可选 RAW 样片时会跳过对应测试；不要将缺失覆盖或本地成功当成所有移动设备验证。

Tests requiring optional RAW fixtures are omitted when those files are absent. Missing coverage or local success is not evidence that every mobile device has been validated.

## 集成与参考 / Integration and References

- [Mac 客户端 / Mac editor](../RawLabMac/README.md)
- [平台集成说明 / Platform integration](docs/platform-integration.md)
- [iOS 指南 / iOS guide](platform/ios/README.md)
- [Android 指南 / Android guide](platform/android/README.md)
- [富士 F-Log2 LUT 说明 / Fujifilm F-Log2 LUT overview](F-Log2/F-Log2_LUT_overview_Ver.1.1E.pdf)
- [LUTCalc 参考实现 / LUTCalc reference implementation](https://github.com/cameramanben/LUTCalc)

## 许可证与致谢 / License and Acknowledgments

MIT License。第三方代码和素材仍受各自许可证约束，见 [Mac 分发的第三方说明](../RawLabMac/Resources/ThirdPartyNotices.md)。

MIT License. Third-party code and assets remain subject to their own licenses; see the [Mac distribution notices](../RawLabMac/Resources/ThirdPartyNotices.md).

感谢 LibRaw、stb 和 LUTCalc 提供 RAW 处理、图像编解码及 LUT 参考实现。

Thanks to LibRaw, stb and LUTCalc for RAW processing, image codecs and LUT reference implementations.
