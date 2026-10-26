# Changelog

Release history is kept here rather than in the project READMEs. Detailed
release notes include assets, installation requirements and validation limits.

## [0.9.0] - Unreleased

### Added

- A reorganized editor on macOS, iOS, Android and Windows: six adjustment
  groups with change markers and per-group reset, single-line numeric inputs,
  side-by-side and split comparison, and press-and-hold to view the photo
  before adjustments. iOS and Android add a tap for a clean photo preview;
  Android adds and iOS upgrades to a 256-bin RGB histogram.
- Copy adjustments and paste selected items to other photos, with session
  undo and redo.
- Named user presets, separate from built-in looks and imported LUT/DCP
  profiles.
- Black point, white point and vibrance; shadow/midtone/highlight color
  grading; a multi-point tone curve that keeps the previous S-curve control;
  clarity and dehaze in both directions. Agent recipes and exports support the
  new adjustments.
- Pick a color on the photo to adjust the matching HSL range directly.
- Photo collections: sync adjustments across photos, fine-tune one photo, and
  export each photo with its own frozen settings after confirmation.
- A local MCP server in `tools/mcp` exposing five tools over the existing Agent
  CLI on macOS and Windows.
- Desktop AI denoising and automatic updates, described below.

### Changed

- New edits use processing version 2: VNG demosaic for ordinary Bayer RAW
  files and an updated denoiser. Existing edits keep processing version 1 and
  their 0.8.2 rendering apart from the HSL change below; ordinary edits and
  resets do not upgrade them. macOS and Windows offer a processing-version
  choice.
- Active HSL adjustments preserve out-of-range color detail after contrast and
  saturation instead of clamping it away. Existing edits can render visibly
  differently; there is no switch to restore the old HSL behavior.
- HSL target adjustment stays active when the adjustment panel is collapsed.
  The canvas shows the selected axis and an exit control.
- This release does not support downgrading. Android 0.8.2 cannot read the new
  edit library. Saving photos after reverting macOS, iOS or Windows discards
  the newly added adjustment fields and processing-version markers.
- Windows allows one running RawLab instance. Opening another file through
  Open With or launching another instance asks the user to quit other RawLab
  instances, then exits the new process.

### Desktop AI denoising and updates

- macOS and Windows release packages include DualDn models and their inference
  runtimes. AI denoising requires a full-resolution first calculation; cached
  results are reused for subsequent exposure and look changes. The model and
  runtime files increase download size. Per-architecture package sizes and
  measured first-run time and memory requirements belong to the final release
  acceptance record.
- AI denoising requires a GPU backend: native Core ML on Apple Silicon with
  macOS 14 or later, or hardware DirectML/D3D12 on Windows x64. AI CPU mode is
  unsupported and Auto does not retry neural inference on CPU. Ordinary photo
  processing and the deterministic ISP may still use CPU. iOS and Android do
  not include AI denoising in this release. Intel builds do not support AI denoising.
- DualDn weights and converted models remain under CC BY-NC 4.0, and the
  Restormer generic RGB model keeps its upstream Academic Public License. Both
  are limited to noncommercial use, ship with upstream attribution and
  conversion notices, and are not relicensed under RawLab's GPL.
- This is the first release intended to include automatic desktop updates.
  Upgrading from 0.8.2 requires one manual installation. Windows automatic
  updates require the current-user Setup installation; ZIP packages use manual
  downloads. The Mac app must be in a location writable by the current user.
  Update packages are downloaded from GitHub Releases.
- The default distribution uses a fixed self-signed Mac code-signing
  certificate plus Sparkle EdDSA signatures, and a signed Windows release
  manifest binding the package size and SHA-256. It does not use Apple
  notarization or Windows Authenticode. First installation may require
  **System Settings → Privacy & Security → Open Anyway** on macOS, or
  **More info → Run anyway** in Windows SmartScreen.
- The move from 0.8.2 changes the Mac signing identity and may require granting
  folder access again. Permission retention across subsequent updates,
  Gatekeeper/App Management prompts and signed seed-to-update installation
  still require release acceptance with the actual signing identities.

### Fixed

- Large-image processing and export on Android and iOS. JPEG/PNG input accepts
  up to 128 million pixels, and iOS no longer runs out of memory on the tested
  61 MP and 100 MP RAW files. Output keeps full resolution while temporary
  processing memory stays bounded.

Version `0.9.0`, build `15` (release preparation). See the
[release notes](docs/releases/v0.9/v0.9.0.md) and
[Chinese update announcement](docs/releases/v0.9/v0.9.0-xiaohongshu.md).

## [0.8.2] - 2026-10-20

### Added

- Direct import of supported DCP color profiles on macOS, iOS, Android and
  Windows, without a separate conversion tool.
- Nikon HE/HE* NEF decoding, Sony ARW6 / Compressed RAW 2 decoding, Sigma X3F
  input and JPEG-compressed DNG decoding. Camera recognition also includes
  Sony A7 V/A1 II, Canon R50 V and PowerShot V1.

### Changed

- Faster CPU look processing and geometry rendering, with viewport-sized
  interactive geometry previews and full-resolution final exports.
- Speed up iOS ordinary-image preview initialization and reuse decoded pixels
  for single-image JPEG/DNG exports, reducing repeated decoding and peak memory.

### Fixed

- Windows accepts valid JPEGs carrying both ICC and EXIF color metadata and
  displays correct colors in scaled first previews. White-balance rounding
  now matches the other clients.
- iOS imported-file lifetime across asynchronous import, editing, cancellation
  and frozen batch exports.
- Correct the embedded iOS statistics framework's minimum-system metadata
  during packaging, without modifying the vendor binary or shared SDK cache.
- Android batch progress, restart recovery and checkpoint-failure handling,
  with incremental journal updates for larger jobs.
- Remaining interface wording, translations, error messages and accessibility
  labels.

Version `0.8.2`, build `14`. See the
[release notes](docs/releases/v0.8/v0.8.2.md) and
[Chinese update announcement](docs/releases/v0.8/v0.8.2-xiaohongshu.md).

## [0.8.1] - 2026-10-18

### Changed

- Usage statistics are on by default on all four clients. Release builds
  include the Alibaba Cloud RUM SDK and report feature-use counts to the
  production environment, stored in mainland China. A random installation ID
  counts active devices and is deleted when statistics are turned off. No
  photos, previews, file names, paths, EXIF or AI content are recorded; the
  vendor SDK may collect device, system, network/IP, region and session data.
- Android no longer requests phone-state, network-state or installed-app
  visibility permissions.
- Every client's catalogs are generated from one shared copy source with
  macOS as the reference; iOS, Windows and Android follow Mac's wording.

### Fixed

- Statistics and privacy text is translated into all six interface languages.
- Master recipe names written in Chinese characters follow the interface
  language on every client.
- iOS recipe tiles show the artwork without a second icon, the recipe panel no
  longer repeats the recipe name, and the settings menu has a VoiceOver name.
- Android shows recipe artwork and no longer falls back to Chinese text when a
  screen is created before the app finishes starting.
- Windows photo-effect controls use complete translation entries.
- Counts no longer read as plural for a single photo; batch summaries use the
  editor's setting names and show disabled switches as Off.
- Interface details on macOS, iOS and Windows: toggle states, truncated or
  mid-word-broken labels, duplicated values and reset buttons, menu placement,
  distinct icons, and system menus in the chosen language.
- Translation fixes in German, French, Spanish and Japanese, and one name
  ("Look") for imported looks.
- Android interface details: changed-value marker position, menu alignment,
  distinct icons and reset buttons.

Version `0.8.1`, build `13`. See [release notes](docs/releases/v0.8/v0.8.1.md) and
[source rebuild instructions](docs/releases/v0.8/v0.8.1-source.md). The shared
processing core is unchanged from 0.8.0.

## [0.8.0] - 2026-10-17

### Added

- Complete desktop Agent/CLI JSON editing, capability and image information,
  preview and FINAL export through the existing processing core.
- Crop, rotate, straighten, flip and perspective correction with shared
  preview/export geometry, committed drafts and frozen batch settings.
- Ordinary JPEG/PNG input on all clients, TIFF on Apple/Windows and HEIF on
  Apple, including native-size exports and mixed RAW/image batches.
- Twenty-nine additional creative looks and consistent artwork, including the
  independently authored Ektar look. Third-party attribution and UNCONFIRMED
  redistribution records remain intact under the owner's release decision.
- A six-check hosted CI workflow, including native macOS arm64 and Intel
  app/parity builds. Exact candidate run results are recorded separately.

### Changed

- Open photos with a single preview; before/after comparison is explicitly enabled.
- Combine temperature/tint under White Balance and simplify collapsed vignette controls.
- Target macOS 14 on both Apple Silicon and Intel, with architecture/minimum-OS
  isolated dependency builds and runtime-available ImageIO checks.
- Keep optional usage statistics SDK-free in default distribution builds.

### Fixed

- Preserve master-recipe tint while clearing dormant camera-only settings in
  raster-source to RAW-target batches on every client.
- Reject profiled non-RGB Apple images and malformed Android PNG color/end
  metadata while accepting legal SDR cICP and structured RGB ICC profiles.
- Complete native iPhone/iPad Files import/cancellation/busy/draft regression
  coverage and restore renderer-independent Windows batch-model compilation.

Version `0.8.0`, build `12`. See [release notes](docs/releases/v0.8/v0.8.0.md),
[source rebuild instructions](docs/releases/v0.8/v0.8.0-source.md) and
[release acceptance](docs/archive/releases/v0.8/preparation.md). AI denoise/upscaling,
HDR export, video generation and mobile Agent/MCP are not part of this release.

## [0.7.0] - 2026-10-14

### Added

- JPEG XL-compressed DNG decoding through the pinned Adobe DNG SDK.
- Rendered float32 DNG export alongside JPEG and 16-bit PNG, retaining
  independent FINAL rendering and frozen batch settings.
- English, Simplified Chinese, German, French, Japanese and Spanish on all
  four clients, including Lens and DNG controls and dynamic states.
- Lensfun profile-based lens correction, manual profile selection and
  auto-crop with persistent per-photo and batch settings.

### Changed

- Use viewport-sized previews and reusable denoise analysis while keeping
  Lens/profile/crop/database and exposure-baseline cache identities isolated.
- Reduce the measured Android denoise memory working set without changing
  the controlled experiment's 1,800,000,000-byte budget or export assertions.
- Integrate shared SDK/JXL, TIFF and Lensfun dependencies and their notices,
  and document one-owner shared-file and validation-resource coordination.

### Fixed

- Avoid overlapping full-resolution Sony CPU buffers during denoise, preserving
  byte-identical JPEG/PNG/DNG exports and existing memory/quality thresholds.
- Replay pending iOS viewport/settings changes after rendered-DNG export
  success and failure, using a reproduced RED/GREEN regression.
- Remove non-system absolute runtime search paths from Mac package copies,
  ensuring actual processing dependencies load from the signed bundle.

Version `0.7.0`, build `11`. Available release packages include signed Android,
ad-hoc signed macOS15 arm64 and Windows x64; iOS distribution signing is absent.
See [release notes](docs/releases/v0.7/v0.7.0.md),
[release verification](docs/archive/releases/v0.7/0.7.0-release.md) and
[corresponding-source instructions](docs/releases/v0.7/v0.7.0-source.md).

## [0.6.0] - 2026-10-12

### Added

- Fourteen master recipes on macOS, iOS, Android and Windows, with shared
  calibrated parameters, style artwork and editable HSL presets.
- An eight-channel HSL mixer, one-shot automatic exposure and selectable RAW
  exposure baselines on all four clients. New RAW edits default to matching the
  embedded camera preview; saved exposure modes remain unchanged.
- iPad support with window-size-driven portrait and landscape editor layouts.

### Changed

- Applying a recipe replaces exposure, shadows, highlights, contrast,
  saturation, tint and all 24 HSL values. Strength scales the current values
  and LUT together from 0 to 200%; other adjustments remain independent.
- Refine all fourteen creative LUTs using reference-assisted, style-preserving
  calibration, with additional constrained HSL refinements where accepted.
- Present recipe artwork above its name and secondary description, without an
  outer frame. Mobile film/recipe lists use direct dragging; desktop overflow
  lists provide left/right buttons that disappear when all items fit.
- Preserve recipe identity, manual edits and strength in edit memory and frozen
  batch jobs; resolve camera-relative recipe tint separately for each target RAW.

### Fixed

- Fade hue-dependent HSL lightness offsets near gray consistently on CPU,
  Metal, GLES and D3D11, preventing tiny color differences from becoming
  brightness speckles under strong HSL settings.

- Align iOS highlight direction, percentage ranges, sharpening maximum and
  slider steps with macOS while retaining old native stored values.
- Keep existing macOS recipe records and frozen jobs compatible with their
  independently saved HSL until a recipe is explicitly reapplied.
- Invalidate macOS RAW/WB caches when a file is replaced at the same path with
  unchanged size and modification time.

Version `0.6.0`, build `10`, with all clients rebuilt from the release source.

See the [v0.6.0 release notes](docs/releases/v0.6/v0.6.0.md),
[source rebuild instructions](docs/releases/v0.6/v0.6.0-source.md),
[release verification](docs/archive/releases/v0.6/0.6.0.md),
[Chinese update notes](docs/releases/v0.6/master-recipes-update.md),
[cross-platform verification](docs/archive/recipes/cross-platform-master-recipes-20261011.md)
and [recipe HSL calibration](docs/archive/recipes/master-recipes-hsl-20261011.md).

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

See [v0.5.1 release notes](docs/releases/v0.5/v0.5.1.md),
[release verification](docs/archive/releases/v0.5/0.5.1.md) and
[the cross-platform implementation evidence](https://github.com/dancancer/RawLab/blob/a38ac6065f747cc43ddbee1c8df232c049b288d2/docs/archive/verification/verification-cross-platform-effects-gpu-denoise-2026-10-10.md).

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

See [v0.5.0 release notes](docs/releases/v0.5/v0.5.0.md) and
[release verification](docs/archive/releases/v0.5/0.5.0.md).

## v0.4.1 更新 / What's New

- 修复 Panasonic S5 II 等 encoding 8 RW2 解码、Canon R6 III 偏色、Sony a7R VI 超大内嵌预览、OM-1 白平衡切换、X-Trans 并行显影不一致和 Hasselblad X2D II 裁切，并补充精确机型色彩矩阵。
  Fixes encoding 8 RW2 decoding, R6 III metadata/color, oversized a7R VI previews, OM-1 white-balance matrix switching, X-Trans parallel demosaic consistency and X2D II active crop, with additional exact-model matrices.
- Mac 的 26 款公开样片中 24 款通过修复后验证；Nikon Z6III / Z50II 的 HE* 样片仍不支持，现明确拒绝而不输出坏图。样片结果不代表所有拍摄模式均已验证。
  Of 26 public camera samples tested on Mac, 24 pass. Nikon Z6III/Z50II HE* samples remain unsupported and are explicitly rejected. These results do not certify every shooting mode.
- Windows 新增 Mac 发起的远程编译入口；iOS 新增可复现的三架构 XCFramework 构建。移动设备峰值内存及 Windows 真显卡验证的边界见发布说明。
  Adds remote Windows builds from Mac and reproducible three-architecture iOS frameworks. See release notes for mobile memory and Windows hardware-GPU validation limits.

详见 [v0.4.1 发布说明](docs/releases/v0.4/v0.4.1.md)和[逐机型兼容性记录](docs/archive/compatibility/raw-2026-10-09.md)。

See the [v0.4.1 release notes](docs/releases/v0.4/v0.4.1.md) and [camera compatibility report](docs/archive/compatibility/raw-2026-10-09.md).

## v0.4.0 更新 / Previous Features

- 构建 6 增加三端“关于”、作者主页和自动/手动更新检测，并沿用原下载链接覆盖安装包。
  Build 6 adds About, author links and automatic/manual update checks on Mac, Windows and Android, replacing installers at the existing download URLs.
- Windows 加快选片首帧、重复原尺寸缩放和平移绘制，保留精确显影后才能导出的约束。
  Windows speeds up first previews, repeated full-resolution zoom and panning while requiring exact rendering before export.
- Mac 和 Android 增加持久化自定义外观库，支持批量导入 CUBE/RLOOK、重命名和删除；失败逐文件汇总，成功项保留。Windows 支持多选导入，仍使用本次会话的外部文件引用。
  Mac and Android add persistent custom-look libraries with batch CUBE/RLOOK import, rename/delete and per-file failure reports. Windows supports multiple selection while retaining session-only external file references.
- 支持声明正确色彩约定的 Fuji F-Log/F-Log2/F-Log2C CUBE，包括技术 Log 输出；共享核心为 Metal、GLES 和 Direct3D 11 提供对应 GPU 路径，Auto 在后端失败时回退 CPU。
  Fuji F-Log/F-Log2/F-Log2C CUBEs with valid color contracts, including technical Log outputs, have shared-core GPU paths for Metal, GLES and Direct3D 11, with Auto fallback on backend failure.

详见 [v0.4.0 发布说明](docs/releases/v0.4/v0.4.0.md)。可导入外观不等于完整复刻原厂或 Adobe 显影。

See the [v0.4.0 release notes](docs/releases/v0.4/v0.4.0.md). Import support does not certify identical manufacturer or Adobe rendering.

## v0.3.0 更新 / Previous Features

- Android 相册可切换方形缩略图和原始比例，支持每行 1-6 张，保留视图选择和浏览位置。
  Android albums offer square/original-ratio thumbnails, 1-6 columns, and retained view choices and browsing position.
- 新增桌面 LUT 准备工具，要求显式声明色彩约定；DCP 可编译为 `.rlook`，由共享核心直接计算矩阵、HSV 表和曲线，Mac 支持原生 Metal 加速。
  The desktop LUT preparer uses explicit color contracts. Supported DCPs compile to `.rlook` for direct matrix/HSV/tone evaluation, with native Metal acceleration on Mac.
- v0.3.0 的 Mac 自定义外观导入支持 `.cube` 和 `.rlook`；该版本不包含移动端自定义外观导入、完整 Lightroom 渲染或全部 DCP 阶段。
  In v0.3.0, Mac imports `.cube` and `.rlook`; that release does not include mobile custom-look import, full Lightroom rendering or complete DCP-stage coverage.

详见 [v0.3.0 发布说明](docs/releases/v0.3/v0.3.0.md)和 [LUT 准备工具文档](lutools/docs/lut-preparation.md)。

## [0.2.1]

- Fix macOS file-browser scroll jumps in large folders.
- Restore Android album filters and scroll positions after editing, refresh,
  backgrounding and Activity recreation.
- Rebuild macOS and Android as `0.2.1` / build `3`; Windows and iOS remain on v0.2.

See [v0.2.1 release notes](docs/releases/v0.2/v0.2.1.md).

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
- Initial [Android release](docs/releases/v0.1/android-v0.1.0.md) and
  [Windows release](https://github.com/dancancer/RawLab/releases/tag/windows-v0.1.0).

See [macOS v0.1 release notes](docs/releases/v0.1/v0.1.md).

[0.6.0]: https://github.com/dancancer/RawLab/releases/tag/v0.6.0
[0.5.0]: https://github.com/dancancer/RawLab/releases/tag/v0.5.0
[0.2.1]: https://github.com/dancancer/RawLab/releases/tag/v0.2.1
[0.1]: https://github.com/dancancer/RawLab/releases/tag/v0.1
