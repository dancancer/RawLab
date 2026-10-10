# RawLab

[English](../README.md) | [简体中文](README.zh-CN.md)

跨品牌 RAW 显影与胶片外观工具，基于共享 C++ 处理核心，提供原生 Windows、macOS、Android 和 iOS 编辑器。

![RawLab Mac：中性显影与 Velvia 效果并排对比](images/rawlab-mac-velvia.png)

## 项目介绍

RawLab 用于显影相机 RAW 文件、应用兼容的富士胶片模拟 LUT 和自定义外观，并在不修改原始文件的前提下导出成片。这是独立项目，不是 Fujifilm 官方产品；胶片外观不承诺与相机直出的 JPEG 完全一致。

## 主要功能

- RAW 显影，支持曝光、相机空间白平衡、明暗、色彩和锐化调整。
- 内置胶片外观，强度范围为 0-200%，支持兼容 CUBE/RLOOK 导入及原图与调整效果对比。
- 线性光域小波降噪，可分别调整亮度、色度和粗层色斑；macOS 另提供暗角、颗粒和 Metal 加速降噪。
- 逐照片本机编辑记忆和可恢复的批量导出，任务固定参数，支持取消和失败重试，不改写 RAW。
- 照片信息叠层、缩放和平移，支持原始尺寸或指定长边导出；桌面文件树可定位照片，并经确认应用当前设置。
- Windows、macOS 和 Android 导出 JPEG 与 16-bit PNG，iOS 导出 JPEG；保留可读取的拍摄元数据，更新成片尺寸和方向。
- 在支持的平台使用 Metal、Direct3D 11 或 OpenGL ES，并保留自动 CPU 回退。RAW 解码和文件编码仍在 CPU 执行。
- 共享 C++17 核心、命令行工具及桌面 LUT 准备工具。

## 支持平台

| 客户端 | 系统要求 |
| --- | --- |
| Windows | Windows 10/11，x64 |
| macOS | macOS 15+，Apple Silicon 或 Intel |
| Android | Android 8.0+，ARM64 或 x86_64 |
| iOS | iOS 18+，iPhone；下载的 IPA 需要自行重新签名 |

## 下载与文档

- [下载最新版本](https://github.com/dancancer/RawLab/releases/latest)
- [安装与分发说明](installation.md)
- [更新日志](../CHANGELOG.md)
- [Windows 客户端](../RawLabWindows/README.md)
- [macOS 客户端](../RawLabMac/README.md)
- [Android 客户端](../RawLabAndroid/README.md)
- [iOS 核心构建与集成](../lutools/platform/ios/README.md)
- [处理核心与命令行工具](../lutools/README.md)
- [LUT 准备工具](../lutools/docs/lut-preparation.md)
- [RAW 与色彩处理约定](../lutools/docs/color-contract.md)

## 许可

Copyright (c) 2026 RawLab contributors。本版本的项目原创代码以 [GNU General Public License v3.0 only](../LICENSE)（`GPL-3.0-only`）发布。第三方库、LUT 和其他附带资源保留各自的许可证与版权声明，详见[许可与归属说明](licensing.md)。
