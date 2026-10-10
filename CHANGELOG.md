# Changelog

Release history is kept here rather than in the project READMEs. Detailed
release notes include assets, installation requirements and validation limits.

## [0.5.1] - 2026-10-10

### Added

- Matching vignette and deterministic grain controls on iOS, Android and Windows,
  using the same eight parameters, defaults and render order as macOS.
- GLES 3.1 and D3D11 compute kernels for wavelet and display-chroma filtering,
  alongside the existing Metal implementation. Auto retains CPU fallback;
  Force requires actual native-backend execution and reports failures.
- Full effects state in edit memory, batch snapshots, preview invalidation,
  reset and final export. Older saved records default to effects off.
- Repository Gitflow guidance: feature PRs target `development`; versioned
  release branches merge to `main` and back to `development`.

### Fixed

- Reflow Windows effects controls at narrow editor widths so all vignette labels
  fit, with scrolling for the remaining adjustment rows.
- Preserve the previous EGL context and correctly order GLES filter teardown.

See [v0.5.1 release notes](docs/releases/v0.5.1.md),
[release verification](docs/verification-v0.5.1.md) and
[the cross-platform implementation evidence](docs/verification-cross-platform-effects-gpu-denoise-2026-10-10.md).

## [0.5.0] - 2026-10-10

### Added

- Linear-light wavelet denoising on all four clients, with luma, chroma and
  coarse-chroma controls and Detail/Clean presets.
- Per-photo local edit memory and resumable batch RAW export. Jobs freeze
  settings and looks, preserve originals, and support cancellation and retries.
- Photo information overlays and original-size or custom long-edge export
  controls on all four clients.
- Desktop file-tree actions to reveal files or apply current settings to
  confirmed photos or a folder's immediate RAW children.
- macOS vignette and grain controls, plus Metal acceleration for photo effects,
  wavelet filtering and display-chroma guided filtering.

### Changed

- Publish the current `development` feature set with version `0.5.0`, build `8`.
- Separate the introductory English README from its linked Chinese translation
  in `docs/README.zh-CN.md`; move installation notes and release history out.
- Distribute original project code under `GPL-3.0-only`, retain third-party and
  historical copyright notices, and include the license with client packages.
- Rebuild Windows, both macOS architectures, Android and iOS from the release
  source rather than reuse previous installers or native libraries.

See [v0.5.0 release notes](docs/releases/v0.5.0.md) and
[release verification](docs/verification-v0.5.0.md).

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

## [0.2.1]

- Fix macOS file-browser scroll jumps in large folders.
- Restore Android album filters and scroll positions after editing, refresh,
  backgrounding and Activity recreation.
- Rebuild macOS and Android as `0.2.1` / build `3`; Windows and iOS remain on v0.2.

See [v0.2.1 release notes](docs/releases/v0.2.1.md).

## v0.2 更新 / Previous Features

- 四个平台的胶片强度范围统一为 **0–200%**，默认及重置仍为 **100%**。
  All four editors support **0–200%** film strength, with **100%** as the default and reset value.
- 应用导出保留可读取的相机、镜头、拍摄时间、快门、光圈、ISO 和 GPS 等 EXIF，更新成片方向和尺寸，不改写原始照片。Mac / Windows / Android 支持 JPEG 和 16-bit PNG；iOS 导出 JPEG。
  App exports retain readable capture EXIF, including camera, lens, date, exposure, ISO and GPS, while updating output orientation and dimensions without modifying originals. Mac / Windows / Android support JPEG and 16-bit PNG; iOS exports JPEG.
- Mac 增加 macOS 15 的 arm64 / x86_64 包；iOS 更新编辑界面和内置 LUT；共享 LUT 校验允许自定义效果名称，仍要求兼容的输入和输出声明。
  Adds macOS 15 arm64 / x86_64 packages, an updated iOS editor and LUT set, and custom display-look names in shared LUT validation while retaining compatible input/output requirements.

Windows 默认使用 Direct3D 11，Mac 使用 Metal，Android 使用 GLES；支持自动回退 CPU。RAW 解码与文件编码仍在 CPU，不代表全流程 GPU 显影。

Windows uses Direct3D 11, Mac uses Metal, and Android uses GLES, with automatic CPU fallback. RAW decoding and file encoding remain on the CPU; this is not an all-GPU pipeline.

## [0.1]

- Initial macOS editor with RAW development, built-in film LUTs, neutral/film
  comparison, Metal processing and full-resolution JPEG/16-bit PNG export.
- Initial [Android release](docs/releases/android-v0.1.0.md) and
  [Windows release](https://github.com/dancancer/RawLab/releases/tag/windows-v0.1.0).

See [macOS v0.1 release notes](docs/releases/v0.1.md).

[0.5.0]: https://github.com/dancancer/RawLab/releases/tag/v0.5.0
[0.2.1]: https://github.com/dancancer/RawLab/releases/tag/v0.2.1
[0.1]: https://github.com/dancancer/RawLab/releases/tag/v0.1
