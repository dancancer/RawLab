# RawLab

跨品牌 RAW 显影与富士胶片 LUT 工具，包含共享 C++ 处理核心、命令行工具和原生 Windows / Mac / Android / iOS 客户端。

Cross-brand RAW development and Fujifilm film LUT tools, with a shared C++ processing core, command-line tools and native Windows / Mac / Android / iOS editors.

## 功能预览 / Preview

![RawLab Mac：中性与 Velvia 效果对比 / Neutral and Velvia comparison](docs/images/rawlab-mac-velvia.png)

RawLab Mac 支持中性与胶片效果并排对比、胶片 LUT 切换、曝光与白平衡等参数调整，以及全分辨率导出。图中左侧为中性渲染，右侧为 Velvia 效果。

RawLab Mac provides side-by-side neutral/film comparison, LUT selection, exposure and white-balance adjustments, and full-resolution export. The screenshot shows the neutral render on the left and Velvia on the right.

当前源码中的 iOS / Android 编辑器支持双指缩放、放大后平移，以及双击切换适应画面与 100% 显示。100% 以精确预览图的像素为基准（一个预览像素对应一个屏幕物理像素），不是原始 RAW 全分辨率查看；调整期间的低分辨率预览保持同一视口。Android 对比模式下，单指拖动分割线，双指缩放和平移。

The current iOS / Android sources support pinch-to-zoom, panning, and double-tap to toggle fit and 100%. Actual-pixel scale uses the exact preview, not the full-resolution RAW; interactive previews retain the same viewport. Android comparison mode uses one finger for the wipe and two fingers for zoom/pan.

### 开发版降噪 / Development Denoising

当前源码的 macOS、Windows、iOS 和 Android 均提供线性光域小波降噪，默认关闭。
支持亮度、色度、粗层色斑三个 0-100 参数、保留细节 (0/46/50) 和干净优先
(10/72/100) 预设。关闭保留数值，重置恢复默认关闭状态。对比左侧固定为未调整原图，
调整或代理预览替换不会重置缩放和平移；精确预览和导出使用完整算法，不复用交互近似。
降噪在 CPU 执行，GPU Auto 自动回退，Force 不会把 CPU 结果标成 GPU。
此功能尚未包含在下方的 v0.4.1 安装包中。

The current macOS, Windows, iOS and Android sources include linear-light wavelet
denoising, disabled by default. Luma, chroma and coarse-chroma controls range from
0 to 100, with Detail (0/46/50) and Clean (10/72/100) presets. Disabling preserves
values; reset restores the disabled default. The original comparison stays fixed,
and preview replacement preserves zoom/pan. Exact previews and exports use the
full algorithm, never the interactive approximation. Denoising runs on CPU:
GPU Auto falls back and Force rejects unsupported execution. This feature is not
included in the v0.4.1 downloads below.

### 关于与更新检测 / About and Updates

v0.4.0 构建 6 的 Mac、Windows、Android 新增“关于 RawLab”，包含 [GitHub 仓库](https://github.com/dancancer/RawLab) 和 [作者的小红书主页](https://www.xiaohongshu.com/user/profile/6474b1560000000010037c8e)。Mac 从应用菜单进入，Windows 从工具栏信息按钮进入，Android 从“更多”菜单进入。

启动后默认在后台检查 GitHub 正式发布，每 24 小时最多自动请求一次；可在“关于”关闭，手动检查不受间隔限制。只提示具有本平台安装包的新版本，并打开官方发布页面供下载，不自动安装、不上传照片。离线失败不会弹窗打断编辑。

The v0.4.0 build 6 Mac, Windows and Android apps add About with repository and author links, optional startup update checks at most once per 24 hours, and an unrestricted manual check. Checks read public GitHub release metadata, require an asset for the current platform, and open the official release page without installing updates or uploading photos. Background failures do not interrupt editing.

## 下载 / Download

Windows 新包已加入快速内嵌预览、原尺寸缩放缓存、多核 RAW 处理及远程桌面下的 WPF 画布硬件加速：选中照片先显示预览，双击立即放大并后台补齐细节，拖动时复用图像图层。构建方法见 [Windows 文档](RawLabWindows/README.md)，测量条件与结果见 [性能记录](RawLabWindows/performance.md)。

The new Windows package adds fast embedded previews, cached full-resolution zoom, multicore RAW processing and hardware-accelerated WPF composition in supported remote desktop sessions. Selection shows a preview first; double-click zoom responds immediately while detail loads, and panning reuses image layers. See the [Windows build instructions](RawLabWindows/README.md) and [performance measurements](RawLabWindows/performance.md).

[下载 RawLab v0.4.1 / Download v0.4.1](https://github.com/dancancer/RawLab/releases/tag/v0.4.1)

v0.4.1 构建 7 是 RAW 兼容性修复版，Windows、macOS 双架构、Android 和 iOS 均从本次源码重新构建，使用带共享补丁的 LibRaw 0.22.2。Windows 不再复用旧 native 库；iOS 同步提供新的未签名 IPA。此版本不包含开发中的批量导出、编辑记忆或新增 RAW 降噪功能。

v0.4.1 build 7 rebuilds Windows, both Mac architectures, Android and iOS with the shared LibRaw 0.22.2 compatibility patches. Windows includes newly built native libraries, and iOS has a refreshed unsigned IPA. In-progress batch export, edit persistence and new RAW noise-reduction work are not part of this release.

| 平台 / Platform | 下载 / Download | 系统要求 / Requirements |
| --- | --- | --- |
| Windows x64 | [ZIP](https://github.com/dancancer/RawLab/releases/download/v0.4.1/RawLab-Windows-0.4.1-win-x64.zip) | Windows 10/11 x64 |
| Mac Apple Silicon | [arm64 ZIP](https://github.com/dancancer/RawLab/releases/download/v0.4.1/RawLab-Mac-0.4.1-macOS15-arm64.zip) | macOS 15+，M 系列 / M-series |
| Mac Intel | [x86_64 ZIP](https://github.com/dancancer/RawLab/releases/download/v0.4.1/RawLab-Mac-0.4.1-macOS15-x86_64.zip) | macOS 15+，Intel |
| Android | [签名 APK / Signed APK](https://github.com/dancancer/RawLab/releases/download/v0.4.1/RawLab-Android-0.4.1.apk) | Android 8.0+，ARM64 / x86_64 |
| iOS | [未签名 IPA / Unsigned IPA](https://github.com/dancancer/RawLab/releases/download/v0.4.1/RawLab-iOS-0.4.1-unsigned.ipa) | iPhone，iOS 18+，须自行签名 / Re-signing required |

[v0.4.1 校验文件 / Checksums](https://github.com/dancancer/RawLab/releases/download/v0.4.1/SHA256SUMS.txt)

### 安装说明 / Installation Notes

- **Windows**：解压后运行 `RawLab.exe`，保留完整目录；已包含 .NET 8、Visual C++ 运行库、LUT 和 ExifTool，程序未签名。
  Extract and run `RawLab.exe`, keeping the entire directory. Includes .NET 8, Visual C++ runtime, LUTs and ExifTool; the app is unsigned.
- **Mac**：按芯片选择对应版本，将 `RawLab Mac.app` 放入 Applications。采用 ad-hoc 签名、未经过 Apple 公证，系统可能阻止默认打开。主程序及依赖的最低版本均为 macOS 15；尚未在 macOS 15 真机验证，Intel 版在 Rosetta 下测试。
  Choose the matching architecture and move `RawLab Mac.app` to Applications. Ad-hoc signed and not notarized; macOS may block opening it. The app and dependencies target macOS 15, but macOS 15 hardware testing is pending; Intel testing used Rosetta.
- **Android**：v0.4.1 沿用正式发布密钥，支持从同签名的旧正式版覆盖升级；无法覆盖不同签名的 debug 版。卸载 debug 版前先导出未保存的编辑。
  v0.4.1 retains the release key for updates from earlier release-signed versions. It cannot replace a differently signed debug build; export unsaved edits before uninstalling a debug build.
- **iOS**：**未签名 IPA 不能直接安装**。需使用自己的有效证书和 provisioning profile 对应用及内嵌 framework 重新签名；不是 App Store 或 TestFlight 发行版，尚未进行真机安装验证。
  **The unsigned IPA cannot be installed directly.** Re-sign the app and embedded framework with your own valid certificate and provisioning profile. This is not an App Store or TestFlight release and has not been installation-tested on physical devices.

## v0.4.1 更新 / What's New

- 修复 Panasonic S5 II 等 encoding 8 RW2 解码、Canon R6 III 偏色、Sony a7R VI 超大内嵌预览、OM-1 白平衡切换、X-Trans 并行显影不一致和 Hasselblad X2D II 裁切，并补充精确机型色彩矩阵。
  Fixes encoding 8 RW2 decoding, R6 III metadata/color, oversized a7R VI previews, OM-1 white-balance matrix switching, X-Trans parallel demosaic consistency and X2D II active crop, with additional exact-model matrices.
- Mac 的 26 款公开样片中 24 款通过修复后验证；Nikon Z6III / Z50II 的 HE* 样片仍不支持，现明确拒绝而不输出坏图。样片结果不代表所有拍摄模式均已验证。
  Of 26 public camera samples tested on Mac, 24 pass. Nikon Z6III/Z50II HE* samples remain unsupported and are explicitly rejected. These results do not certify every shooting mode.
- Windows 新增 Mac 发起的远程编译入口；iOS 新增可复现的三架构 XCFramework 构建。移动设备峰值内存及 Windows 真显卡验证的边界见发布说明。
  Adds remote Windows builds from Mac and reproducible three-architecture iOS frameworks. See release notes for mobile memory and Windows hardware-GPU validation limits.

详见 [v0.4.1 发布说明](docs/releases/v0.4.1.md)和[逐机型兼容性记录](docs/verification-raw-compatibility-2026-10-09.md)。

See the [v0.4.1 release notes](docs/releases/v0.4.1.md) and [camera compatibility report](docs/verification-raw-compatibility-2026-10-09.md).

## v0.4.0 更新 / Previous Features

- 构建 6 增加三端“关于”、作者主页和自动/手动更新检测，并沿用原下载链接覆盖安装包。
  Build 6 adds About, author links and automatic/manual update checks on Mac, Windows and Android, replacing installers at the existing download URLs.
- Windows 加快选片首帧、重复原尺寸缩放和平移绘制，保留精确显影后才能导出的约束。
  Windows speeds up first previews, repeated full-resolution zoom and panning while requiring exact rendering before export.
- Mac 和 Android 增加持久化自定义外观库，支持批量导入 CUBE/RLOOK、重命名和删除；失败逐文件汇总，成功项保留。Windows 支持多选导入，仍使用本次会话的外部文件引用。
  Mac and Android add persistent custom-look libraries with batch CUBE/RLOOK import, rename/delete and per-file failure reports. Windows supports multiple selection while retaining session-only external file references.
- 支持声明正确色彩约定的 Fuji F-Log/F-Log2/F-Log2C CUBE，包括技术 Log 输出；共享核心为 Metal、GLES 和 Direct3D 11 提供对应 GPU 路径，Auto 在后端失败时回退 CPU。
  Fuji F-Log/F-Log2/F-Log2C CUBEs with valid color contracts, including technical Log outputs, have shared-core GPU paths for Metal, GLES and Direct3D 11, with Auto fallback on backend failure.

详见 [v0.4.0 发布说明](docs/releases/v0.4.0.md)。可导入外观不等于完整复刻原厂或 Adobe 显影。

See the [v0.4.0 release notes](docs/releases/v0.4.0.md). Import support does not certify identical manufacturer or Adobe rendering.

## v0.3.0 更新 / Previous Features

- Android 相册可切换方形缩略图和原始比例，支持每行 1-6 张，保留视图选择和浏览位置。
  Android albums offer square/original-ratio thumbnails, 1-6 columns, and retained view choices and browsing position.
- 新增桌面 LUT 准备工具，要求显式声明色彩约定；DCP 可编译为 `.rlook`，由共享核心直接计算矩阵、HSV 表和曲线，Mac 支持原生 Metal 加速。
  The desktop LUT preparer uses explicit color contracts. Supported DCPs compile to `.rlook` for direct matrix/HSV/tone evaluation, with native Metal acceleration on Mac.
- v0.3.0 的 Mac 自定义外观导入支持 `.cube` 和 `.rlook`；该版本不包含移动端自定义外观导入、完整 Lightroom 渲染或全部 DCP 阶段。
  In v0.3.0, Mac imports `.cube` and `.rlook`; that release does not include mobile custom-look import, full Lightroom rendering or complete DCP-stage coverage.

详见 [v0.3.0 发布说明](docs/releases/v0.3.0.md)和 [LUT 准备工具文档](lutools/docs/lut-preparation.md)。

## v0.2 更新 / Previous Features

- 四个平台的胶片强度范围统一为 **0–200%**，默认及重置仍为 **100%**。
  All four editors support **0–200%** film strength, with **100%** as the default and reset value.
- 应用导出保留可读取的相机、镜头、拍摄时间、快门、光圈、ISO 和 GPS 等 EXIF，更新成片方向和尺寸，不改写原始照片。Mac / Windows / Android 支持 JPEG 和 16-bit PNG；iOS 导出 JPEG。
  App exports retain readable capture EXIF, including camera, lens, date, exposure, ISO and GPS, while updating output orientation and dimensions without modifying originals. Mac / Windows / Android support JPEG and 16-bit PNG; iOS exports JPEG.
- Mac 增加 macOS 15 的 arm64 / x86_64 包；iOS 更新编辑界面和内置 LUT；共享 LUT 校验允许自定义效果名称，仍要求兼容的输入和输出声明。
  Adds macOS 15 arm64 / x86_64 packages, an updated iOS editor and LUT set, and custom display-look names in shared LUT validation while retaining compatible input/output requirements.

Windows 默认使用 Direct3D 11，Mac 使用 Metal，Android 使用 GLES；支持自动回退 CPU。RAW 解码与文件编码仍在 CPU，不代表全流程 GPU 显影。

Windows uses Direct3D 11, Mac uses Metal, and Android uses GLES, with automatic CPU fallback. RAW decoding and file encoding remain on the CPU; this is not an all-GPU pipeline.

## 文档 / Documentation

- [Windows 客户端：原生 WPF、Direct3D 11 加速、构建与验证 / Windows editor](RawLabWindows/README.md)
- [Android 客户端：相册权限、构建与验证 / Android editor: album access, build and verification](RawLabAndroid/README.md)
- [Mac 客户端：构建、使用与验证 / Mac editor: build, use and verification](RawLabMac/README.md)
- [iOS 核心构建与集成 / iOS core build and integration](lutools/platform/ios/README.md)
- [处理核心与命令行工具 / Processing core and CLI](lutools/README.md)
- [RAW、色彩空间与 LUT 处理约定 / RAW, color-space and LUT contract](lutools/docs/color-contract.md)

## 开源协议 / License

项目原创代码采用 [MIT License](LICENSE)。第三方库、LUT 及其他附带资源遵循各自许可证与版权声明；详见各客户端的第三方说明。

Original project code is licensed under the [MIT License](LICENSE). Third-party libraries, LUTs and other bundled assets retain their respective licenses and copyright notices.
