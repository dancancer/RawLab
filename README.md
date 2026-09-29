# RawLab

跨品牌 RAW 显影与富士胶片 LUT 工具，包含共享 C++ 处理核心、命令行工具和原生 Windows / Mac / Android 客户端。

Cross-brand RAW development and Fujifilm film LUT tools, with a shared C++ processing core, command-line tools and native Windows / Mac / Android editors.

## 功能预览 / Preview

![RawLab Mac：中性与 Velvia 效果对比 / Neutral and Velvia comparison](docs/images/rawlab-mac-velvia.png)

RawLab Mac 支持中性与胶片效果并排对比、胶片 LUT 切换、曝光与白平衡等参数调整，以及全分辨率导出。图中左侧为中性渲染，右侧为 Velvia 效果。

RawLab Mac provides side-by-side neutral/film comparison, LUT selection, exposure and white-balance adjustments, and full-resolution export. The screenshot shows the neutral render on the left and Velvia on the right.

## 下载 / Download

[下载 RawLab v0.2 / Download v0.2](https://github.com/dancancer/RawLab/releases/tag/v0.2)

v0.2 汇集 Windows / Mac / Android / iOS 的 200% 胶片强度与导出保留 EXIF 源码。
当前提供 Windows x64 安装包，其他平台附件后续补充；旧版本下载见下方链接。

v0.2 includes 200% film strength and EXIF-preserving export source for Windows,
Mac, Android and iOS. The Windows x64 package is available first; other platform
packages will follow. Earlier downloads remain linked below.

支持 Windows 10/11 x64。解压后运行 `RawLab.exe`；独立运行包包含 .NET 运行时，默认 Direct3D 11 硬件加速，可自动回退 CPU。

Requires Windows 10/11 x64. Extract the ZIP and run `RawLab.exe`. The package includes the .NET runtime and supports Direct3D 11 acceleration with CPU fallback.

[下载 RawLab Mac v0.1 / Download v0.1](https://github.com/dancancer/RawLab/releases/tag/v0.1)

支持 Apple Silicon（arm64）和 macOS 26 或更高版本。应用采用 ad-hoc 签名，未经过 Apple 公证。

Requires Apple Silicon (arm64) and macOS 26 or later. The app is ad-hoc signed and has not been notarized by Apple.

[下载 RawLab Android v0.1.0 / Download Android v0.1.0](https://github.com/dancancer/RawLab/releases/tag/android-v0.1.0)

支持 Android 8.0+，提供 ARM64 / x86_64 通用签名 APK；GLES 不可用时自动回退 CPU。

Requires Android 8.0+. The signed APK includes ARM64 / x86_64 and falls back to CPU when GLES is unavailable.

## 文档 / Documentation

- [Windows 客户端：原生 WPF、Direct3D 11 加速、构建与验证 / Windows editor](RawLabWindows/README.md)
- [Android 客户端：相册权限、构建与验证 / Android editor: album access, build and verification](RawLabAndroid/README.md)
- [Mac 客户端：构建、使用与验证 / Mac editor: build, use and verification](RawLabMac/README.md)
- [处理核心与命令行工具 / Processing core and CLI](lutools/README.md)
- [RAW、色彩空间与 LUT 处理约定 / RAW, color-space and LUT contract](lutools/docs/color-contract.md)

## 开源协议 / License

项目原创代码采用 [MIT License](LICENSE)。第三方库、LUT 及其他附带资源遵循各自许可证与版权声明；详见各客户端的第三方说明。

Original project code is licensed under the [MIT License](LICENSE). Third-party libraries, LUTs and other bundled assets retain their respective licenses and copyright notices.
