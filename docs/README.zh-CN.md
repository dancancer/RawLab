# RawLab

[English](../README.md) | [简体中文](README.zh-CN.md)

跨品牌 RAW 显影与胶片外观工具，基于共享 C++ 处理核心，提供原生 Windows、macOS、Android 和 iOS 编辑器。

![RawLab Mac：中性显影与 Velvia 效果并排对比](images/rawlab-mac-velvia.png)

## 项目介绍

RawLab 用于显影相机 RAW 文件、应用兼容的富士胶片模拟 LUT 和自定义外观，并在不修改原始文件的前提下导出成片。这是独立项目，不是 Fujifilm 官方产品；胶片外观不承诺与相机直出的 JPEG 完全一致。

## 主要功能

- RAW 显影，支持曝光、相机空间白平衡、明暗、色彩和锐化调整。
- 支持普通不透明 RGB8 SDR 图像：四端均可输入 JPEG/PNG，macOS、iOS 和 Windows 另支持 TIFF，macOS/iOS 另支持 HEIF。普通图像复用编辑与导出核心，不额外应用 RAW 显影曲线或相机专属设置；HDR、高位深、透明及多帧等不支持的输入会明确拒绝。格式与验收边界见[普通图像输入记录](verification-raster-input-all-platforms-2026-10-16.md)。
- 四端新照片默认使用“匹配内嵌预览”曝光基准，提供一次性自动曝光和八色 HSL 调整；保留旧照片已保存的曝光基准。
- 内置胶片外观，强度范围为 0-200%，支持兼容 CUBE/RLOOK 导入及原图与调整效果对比。
- 四端统一提供 14 个大师配方与风格图标。应用配方覆盖六项调色及全部 24 项 HSL，0-200% 强度整体缩放当前配方参数、HSL 和 LUT；编辑记录与冻结批量任务保留手动修改，并按目标 RAW 解析拍摄白平衡。
- 移动端胶片与配方列表直接拖动，桌面端提供溢出滚动按钮；iPad 自适应横竖屏布局。iOS 参数范围、步进与高光方向和 macOS 对齐，保留旧 RAW 记录的原生成片效果；普通图像改用上述显示图像约定。
- 四端提供一致的暗角、固定种子颗粒及线性光域小波降噪，可分别调整亮度、色度和粗层色斑；共享降噪与效果内核使用 Metal、GLES 3.1 和 D3D11 加速。
- 逐照片本机编辑记忆和可恢复的批量导出，任务固定参数，支持取消和失败重试，不改写 RAW。
- 照片信息叠层、缩放和平移，支持原始尺寸或指定长边导出；桌面文件树可定位照片，并经确认应用当前设置。
- Windows、macOS 和 Android 导出 JPEG 与 16-bit PNG，iOS 导出 JPEG；保留可读取的拍摄元数据，更新成片尺寸和方向。
- 在支持的平台使用 Metal、Direct3D 11 或 OpenGL ES，HSL 接入平台 GPU 显影链路，并保留 GPU 失败时的自动 CPU 回退。RAW 解码和文件编码仍在 CPU 执行。
- 共享 C++17 核心、命令行工具及桌面 LUT 准备工具。
- 桌面 Agent 提供完整编辑参数、能力查询、预览和最终导出，与界面和冻结批量任务复用参数及处理核心。
- 支持裁切、旋转、拉直、翻转和透视校正；打开照片默认仅显示预览图，按需开启前后对比。

## 支持平台

| 客户端 | 系统要求 |
| --- | --- |
| Windows | Windows 10/11，x64 |
| macOS | 最低部署目标为 macOS 14，支持 Apple Silicon 或 Intel；最低系统实机覆盖仍有限 |
| Android | Android 8.0+，ARM64 或 x86_64 |
| iOS | iOS 18+，iPhone 和 iPad；下载的 IPA 需要自行重新签名 |

## 下载与文档

- [文档索引](README.md)
- [下载最新版本](https://github.com/dancancer/RawLab/releases/latest)
- [v0.8.0 发布说明（构建 12）](releases/v0.8.0.md)
- [安装与分发说明](installation.md)
- [将 RawLab 安装到自己的 iPhone](ios-installation.zh-CN.md)
- [更新日志](../CHANGELOG.md)
- [产品路线图](roadmap.md)
- [Windows 客户端](../RawLabWindows/README.md)
- [macOS 客户端](../RawLabMac/README.md)
- [Android 客户端](../RawLabAndroid/README.md)
- [iOS 核心构建与集成](../lutools/platform/ios/README.md)
- [处理核心与命令行工具](../lutools/README.md)
- [LUT 准备工具](../lutools/docs/lut-preparation.md)
- [RAW 与色彩处理约定](../lutools/docs/color-contract.md)

## 许可

Copyright (c) 2026 RawLab contributors。本版本的项目原创代码采用 [GNU General Public License v3.0 only](../LICENSE)（`GPL-3.0-only`），并按 GPLv3 第 7 节提供范围明确的[阿里云 RUM SDK 链接例外](../LICENSE-ALIYUN-RUM-EXCEPTION)。第三方库、LUT 和其他附带资源保留各自的许可证与版权声明，详见[许可与归属说明](licensing.md)。
