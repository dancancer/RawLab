# 平台集成指南

Sony2Fuji 库支持多平台集成,包括桌面命令行工具和移动端应用。

RAW 默认采用标准显影曝光基准。`sony2fuji_session_set_raw_exposure_mode` 可选择 `SCENE`、`PREVIEW`、`SENSOR`；`sony2fuji_session_get_raw_exposure` 返回最近成功解码 RAW 的基础 EV 和元数据 EV（不含用户曝光）。新函数不改变 v2 request 布局，切换模式会更新 RAW 缓存身份。中性输出使用独立显示映射，富士 LUT 不叠加该映射，详见 [色彩契约](color-contract.md)。

## 支持的平台

- **命令行工具**: Linux, macOS, Windows
- **iOS**: iOS 13.0+
- **Android**: Android API 24+ (Android 7.0+)

## 架构概览

```
┌─────────────────────────────────────────────────────────┐
│                  应用层 (Application Layer)              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐             │
│  │   CLI    │  │   iOS    │  │ Android  │             │
│  │  Tool    │  │   App    │  │   App    │             │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘             │
├───────┼─────────────┼─────────────┼───────────────────┤
│       │             │             │                    │
│       │        ┌────▼─────────────▼────┐               │
│       │        │  Platform Wrappers    │               │
│       │        │  (Swift/Kotlin/Java)  │               │
│       │        └────┬──────────────────┘               │
│       │             │ JNI/C++           │               │
├───────┼─────────────┼───────────────────┼──────────────┤
│       └─────────────▼───────────────────┘               │
│            C++ Core Library (sony2fuji)                 │
│  ┌──────────────────────────────────────────────────┐  │
│  │ RAW Processing │ LUT Application │ Color Convert │  │
│  │    (libraw)    │ (Trilinear)     │   (Matrices)  │  │
│  └──────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

## 快速开始

### 1. 构建核心库

首先构建 C++ 核心库:

```bash
# 安装依赖
# macOS
brew install cmake libraw pkg-config

# Ubuntu/Debian
sudo apt-get install cmake libraw-dev pkg-config

# 构建
mkdir build && cd build
cmake ..
make -j$(nproc)
```

### 2. 平台特定构建

#### 命令行工具 (所有桌面平台)

```bash
# 构建后直接使用
./sony2fuji input.ARW -l lut.cube -o output.jpg
```

#### iOS

详见 [iOS 集成指南](ios/README.md)

主要步骤:
1. 使用 CMake 构建 iOS Framework
2. 添加到 Xcode 项目
3. 使用 Swift/Objective-C wrapper

#### Android

详见 [Android 集成指南](android/README.md)

主要步骤:
1. 使用 NDK 构建 .so 库
2. 创建 JNI wrapper
3. 在 Kotlin/Java 中使用

## 核心功能

所有平台都支持以下核心功能:

### 1. RAW 文件处理
- 支持 Sony RAW 格式 (.ARW)
- 白平衡调整
- 曝光补偿
- 线性输出

### 2. LUT 应用
- 解析 .cube 格式 LUT
- 三线性插值
- 33x33x33 采样网格

### 3. 色彩空间转换
- Sony Native → Fuji F-Gamut
- 支持多种色彩空间
- 3x3 矩阵变换

### 4. 图像输出
- JPEG (可调质量)
- PNG (16-bit)

## API 一致性

不同平台的 API 保持一致的工作流程:

### C++ (核心 API)

使用 `sony2fuji_process` C API 共享完整流程，不再手动拼接 native 矩阵和 LUT。可编译示例见 `examples/simple_example.cpp`；输出原始有效尺寸使用 `SONY2FUJI_SIZE_NATIVE`。输入/显示的色彩约定见 [color-contract.md](color-contract.md)。

### Swift (iOS)

```swift
let processor = Sony2Fuji()
try processor.processImage(
    rawPath: "input.ARW",
    lutPath: "lut.cube",
    outputPath: "output.jpg"
)
```

### Kotlin (Android)

```kotlin
val processor = Sony2FujiProcessor()
processor.processImage(
    rawPath = "input.ARW",
    lutPath = "lut.cube",
    outputPath = "output.jpg"
)
```

## 性能考虑

### 内存使用

典型 24MP RAW 文件的内存占用:
- RAW 解码: ~145 MB (24MP × 3 channels × 2 bytes)
- LUT 数据: ~1 MB (33³ × 3 × 4 bytes)
- 总计: ~150-200 MB

### 处理时间 (参考)

在现代设备上处理 24MP RAW 文件:
- 桌面 (Intel i7): ~2-5 秒
- iPhone 14 Pro: ~5-10 秒
- Android 旗舰: ~5-15 秒

### 优化建议

1. **使用后台线程**: 避免阻塞 UI
2. **批处理**: 一次性加载 LUT 用于多张图片
3. **降采样**: 预览时可以使用较低分辨率
4. **缓存**: 缓存常用 LUT

### GPU 加速 (移动端)

- iOS: Metal compute
- Android: OpenGL ES 3.1 compute (自动回退到 CPU)
- iOS/Android 构建默认使用 AUTO 模式，可显式设置为 OFF

```c
sony2fuji_gpu_config gpu_config = {
    .version = SONY2FUJI_GPU_CONFIG_VERSION,
    .struct_size = sizeof(sony2fuji_gpu_config),
    .mode = SONY2FUJI_GPU_AUTO
};
sony2fuji_session_set_gpu_config(session, &gpu_config);
```

## 依赖项

### 核心依赖
- **libraw**: RAW 文件处理
- **stb_image_write**: 图像编码 (已包含)
- C++17 编译器

### 平台特定依赖

#### iOS
- Xcode 14+
- iOS 13.0+ SDK

#### Android
- Android NDK r25+
- CMake 3.22+
- Gradle 8.0+

## 许可证

核心库: [GPLv3 only](../../LICENSE)（`GPL-3.0-only`）
依赖库: 各自的许可证 (libraw: LGPL/CDDL)

## 贡献

欢迎贡献代码和反馈!

### 添加新平台支持

1. 创建 `platform/your_platform/` 目录
2. 编写平台特定的 wrapper
3. 添加构建脚本
4. 编写集成文档

### 优化建议

- SIMD 优化 (SSE, NEON)
- GPU 加速 (Metal, Vulkan)
- 多线程处理 (OpenMP 可选, 桌面端优先)

## 技术支持

- GitHub Issues: 报告问题
- 文档: 查看各平台的详细文档
- 示例: 参考 `examples/` 目录

## 路线图

- [ ] 支持更多 LUT 格式 (.3dl, .spi1d)
- [x] GPU 加速处理 (iOS Metal, Android GLES)
- [ ] 批量处理 API
- [ ] 实时预览支持
- [ ] 更多相机支持 (Fuji, Canon, Nikon)
- [ ] Web Assembly 支持
