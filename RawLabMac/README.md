# RawLab Mac

原生 SwiftUI/AppKit 桌面验证客户端，与 CLI/iOS 共用 C++ 处理管线。支持独立构建最低 macOS 15 的 Apple Silicon 和 Intel 版本；macOS 15 真机运行仍需验证。默认本机构建继续使用现有 Homebrew 依赖和 macOS 26 目标。

A native SwiftUI/AppKit desktop editor for visual verification, sharing the C++ pipeline with the CLI and iOS client. Separate Apple Silicon and Intel builds can target macOS 15; runtime verification on macOS 15 hardware is still pending. The default local build retains the existing Homebrew dependencies and macOS 26 target.

## 功能预览 / Preview

v0.5.0 新增逐照片本机调整记忆和“使用当前调整批量导出”。任务固定来源参数、降噪设置和外观，可多选 RAW、检查目标效果、选择 JPEG/16-bit PNG 与输出目录，支持取消、继续、失败重试和中断恢复；不覆盖原片或目标编辑记录。迁移到 `development` 后的验证见[验收记录](../docs/verification-edit-memory-batch-export-2026-10-10.md)。

![RawLab Mac：中性与 Velvia 效果对比 / Neutral and Velvia comparison](../docs/images/rawlab-mac-velvia.png)

左侧为中性渲染，右侧为 Velvia 胶片效果；底部集中提供胶片选择及曝光、明暗、色彩、白平衡和锐化调整。

The left pane is the neutral render and the right pane is Velvia. Film selection and exposure, tone, color, white balance and sharpening controls are grouped at the bottom.

## 构建和启动 / Build and Launch

预编译版本：[GitHub Release v0.5.0](https://github.com/dancancer/RawLab/releases/tag/v0.5.0)。按芯片下载 [Apple Silicon arm64](https://github.com/dancancer/RawLab/releases/download/v0.5.0/RawLab-Mac-0.5.0-macOS15-arm64.zip) 或 [Intel x86_64](https://github.com/dancancer/RawLab/releases/download/v0.5.0/RawLab-Mac-0.5.0-macOS15-x86_64.zip)，解压后可将 `RawLab Mac.app` 放入 Applications。两版均以 macOS 15.0 为最低版本；采用 ad-hoc 签名，没有 Developer ID 签名或 Apple 公证，macOS 可能阻止默认打开。尚未在 macOS 15 真机验证；Intel 版在 Rosetta 下测试。

Prebuilt apps: [GitHub Release v0.5.0](https://github.com/dancancer/RawLab/releases/tag/v0.5.0). Choose [Apple Silicon arm64](https://github.com/dancancer/RawLab/releases/download/v0.5.0/RawLab-Mac-0.5.0-macOS15-arm64.zip) or [Intel x86_64](https://github.com/dancancer/RawLab/releases/download/v0.5.0/RawLab-Mac-0.5.0-macOS15-x86_64.zip), extract the ZIP and move `RawLab Mac.app` to Applications. Both target macOS 15.0 or later. They are ad-hoc signed, without Developer ID signing or notarization, so macOS may block opening them. macOS 15 hardware testing is pending; Intel testing used Rosetta.

构建 6 新增应用菜单“关于 RawLab”和“检查更新”。“关于”包含 GitHub 仓库、作者小红书主页及自动检测开关；启动后每 24 小时最多后台检查一次，手动检查不受间隔限制。发现新版本后打开官方发布页，不自动替换应用。

Build 6 adds About RawLab and Check for Updates to the app menu. About includes repository/author links and an automatic-check toggle. Startup checks run at most once per 24 hours; manual checks bypass the interval. Updates open the official release page without replacing the app automatically.

在仓库根目录执行：

Run from the repository root:

```bash
bash RawLabMac/build.sh
open "build/RawLab Mac.app"
```

依赖 CMake、pkg-config、LibRaw 0.22.2+ 和 Apple Command Line Tools。Panasonic S5 II 的 RW2 使用 encoding 8，旧版 LibRaw 0.21.x 会错误解码为噪点。若 Homebrew 版本不足，使用下方源码依赖构建，不要只替换应用内动态库，因为 LibRaw 0.22 改变了 ABI。脚本默认以 26.0 为 deployment target；具备更低版本依赖时可显式设置 `MACOSX_DEPLOYMENT_TARGET`。CLT 27 的 SwiftUI 宏插件不完整时，脚本使用本机已有的 26.5 SDK，也可用 `SDKROOT` 指定。

Requires CMake, pkg-config, LibRaw 0.22.2+ and Apple Command Line Tools. Panasonic S5 II RW2 uses encoding 8, which LibRaw 0.21.x incorrectly decodes as noise. If Homebrew is older, use the source dependency build below; do not replace only the bundled dylib because LibRaw 0.22 changes its ABI. The default deployment target is 26.0. Set `MACOSX_DEPLOYMENT_TARGET` only when the dependencies also support the lower target. When the CLT 27 SwiftUI macro plugin is unavailable, the script uses the locally installed 26.5 SDK; `SDKROOT` can override it.

构建脚本打包所需 Homebrew 动态库并进行本地 ad-hoc 签名，不做分发公证，不修改系统 Xcode license 状态。

The build script embeds the required Homebrew libraries and applies a local ad-hoc signature. It does not notarize the app or change Xcode's license acceptance state.

构建时会重新复制动态依赖、将递归依赖改为应用内 `@rpath`，并运行 `tests/bundle.sh` 检查不存在本机 Homebrew 路径。依赖许可证随应用保存在 `Contents/Resources/Licenses`；[第三方说明](Resources/ThirdPartyNotices.md)记录来源，Release 同时提供 LibRaw 对应版本的源代码归档。

Each build refreshes the embedded libraries, rewrites transitive dependencies to in-app `@rpath` references, and runs `tests/bundle.sh` to reject Homebrew paths. Licenses are included under `Contents/Resources/Licenses`; the [third-party notices](Resources/ThirdPartyNotices.md) identify their sources. The release also provides a LibRaw source archive for the corresponding version.

应用图标采用深灰底上的黄色/青色交叠画幅，表达 RAW 与显影结果之间的色彩转换。无相机、光圈或品牌文字，使用扁平几何图形。源图位于 `Resources/AppIcon.png`；构建时由 `build-icon.sh` 生成覆盖 16–1024 像素的原生 `.icns`，并通过 `CFBundleIconFile` 注册。图像生成说明见 `Resources/AppIcon.md`。

The flat app icon uses overlapping yellow/cyan frames on charcoal to suggest the RAW-to-render color transformation, without camera, aperture or brand lettering. The source is `Resources/AppIcon.png`; `build-icon.sh` generates a native 16-1024px `.icns`, registered through `CFBundleIconFile`. Generation provenance is in `Resources/AppIcon.md`.

## macOS 15 双架构构建 / macOS 15 Builds

从固定版本的上游源码重建第三方动态库，分别输出两个应用，避免覆盖默认产物。需要 CMake、pkg-config、make 和 Apple Command Line Tools；依赖下载使用 curl。Intel 的 libjpeg SIMD 优化需要可选的 NASM，缺失时仍可正常解码。保留 OpenMP、JPEG、DNG deflate 和 LCMS；LibRaw 0.22 不再启用旧 RedCine/JasPer 路径，不承诺原有 JPEG2000 覆盖。

Rebuild third-party libraries from pinned upstream source archives and produce two separate apps without overwriting the default build. Requires CMake, pkg-config, make, Apple Command Line Tools, and curl. NASM optionally enables Intel libjpeg SIMD acceleration; decoding still works without it. OpenMP, JPEG, DNG deflate and LCMS are retained. LibRaw 0.22 no longer enables the legacy RedCine/JasPer path; prior JPEG2000 coverage is not promised.

新版相机校准、R6 III 元数据、X2D II 裁切及 X-Trans 并发修复由 `lutools/cmake/patch-libraw.cmake` 应用到源码依赖。未打补丁的 Homebrew/系统 LibRaw 0.22.2 不包含这些修复；请使用下列源码构建和对应 `PKG_CONFIG_PATH`。逐样片结果及 HE* 限制见[兼容性报告](../docs/verification-raw-compatibility-2026-10-09.md)。

Camera calibration, R6 III metadata, X2D II crop and X-Trans concurrency fixes are applied to source dependencies by `lutools/cmake/patch-libraw.cmake`. Unpatched Homebrew/system LibRaw 0.22.2 does not include them; use the source build and matching `PKG_CONFIG_PATH` below. See the [compatibility report](../docs/verification-raw-compatibility-2026-10-09.md) for per-sample results and HE* limitations.

```bash
for arch in arm64 x86_64; do
    RAWLAB_ARCH="$arch" MACOSX_DEPLOYMENT_TARGET=15.0 bash RawLabMac/build-dependencies.sh
    RAWLAB_ARCH="$arch" MACOSX_DEPLOYMENT_TARGET=15.0 \
      PKG_CONFIG_PATH="$PWD/build/macos15-deps/$arch/install/lib/pkgconfig" \
      RAWLAB_BUILD_DIR="$PWD/lutools/build-macos15-$arch" \
      RAWLAB_APP_PATH="$PWD/build/macos15-$arch/RawLab Mac.app" \
      bash RawLabMac/build.sh
done
```

打包校验会检查主程序及所有内嵌动态库的架构、最低系统版本、签名和依赖完整性。新包仍为 ad-hoc 签名，不是已公证发行版。

Packaging checks verify the architecture, minimum OS, signature, and dependency closure of the executable and every embedded library. These builds remain ad-hoc signed, not notarized releases.

## 使用 / Usage

- 胶片强度支持 0–200%，默认及重置均为 100%。

  Film strength supports 0-200%, with 100% as the default and reset value.
- 打开或拖入 RAW；内置十种 Fuji 胶片 LUT，也可导入兼容 CUBE 或准备好的 RLOOK v1/v2。

  Open or drag in a RAW file. Ten Fuji film LUTs are bundled; import compatible CUBE or prepared RLOOK v1/v2 files.
- 支持声明 BT.709 输出色域的 F-Log、F-Log2、F-Log2C 富士 CUBE。F-Log2C 使用独立色域转换；技术 Log 输出会解码后正常显示。这些类型均支持 Metal，Auto 只在后端失败时回退。原厂文件无需重新制备。

  Declared Fuji F-Log/F-Log2/F-Log2C CUBEs with BT.709 output can be imported directly. F-Log2C uses its own gamut conversion; technical Log outputs are decoded and display-rendered. All these contracts support Metal, with Auto fallback on backend failure.
- 外观选择器支持一次多选 CUBE/RLOOK，按顺序导入。单个失败不影响其余文件；批次结束后选中最后成功项，并汇总失败文件。全部失败或取消选择时保留原选择。

  The look picker accepts multiple CUBE/RLOOK files. Imports run sequentially, retain partial success, select the last successful look and report failed filenames. All-failed or cancelled batches preserve the existing selection.
- v0.4.0 将导入外观复制到 `~/Library/Application Support/RawLab/Looks`，使用原子写入的 `registry.json` 保存稳定 ID、名称、格式和源文件名。删除外部原文件不影响外观，重启后会恢复。外观右键菜单支持重命名和删除；删除仅影响托管副本，内置外观不受影响。导入先走共享 native 校验，失败保留原选择，不接受源 DCP/XMP。制备步骤见 [LUT Preparation](../lutools/docs/lut-preparation.md)。

  v0.4.0 manages imported looks in Application Support with a persistent registry. Imported copies survive source removal and app restart; context menus rename or remove only managed copies. Native validation rejects incompatible files without changing selection. Compile supported source DCPs on the desktop first; XMP execution is not implemented.
- 左侧文件树支持添加多个本地目录、按需展开子目录和点击 RAW 缩略图选片，可从工具栏收起。目录列表会保留；从侧栏移除目录不会删除原文件。缩略图只读取内嵌预览，不自动触发完整显影。

  Add multiple local directories, expand subdirectories on demand and select RAW thumbnails in the collapsible left file tree. The directory list persists; removing an entry never deletes files. Thumbnails use embedded previews rather than full RAW development.
- 中性与结果并排对比，共享缩放和平移。适合模式使用 2000 像素预览；100% 模式重新渲染完整分辨率。

  Neutral and film panes share zoom and pan. Fit mode uses a 2000px preview; 100% mode renders the original resolution.
  双击任一照片画布可在适合窗口与 100% 实际像素之间切换，同时复位平移；手动缩放后双击回到适合窗口。
  Double-click either photo canvas to toggle fit and 100% actual pixels and reset pan; after manual zoom, double-click returns to fit.
- 曝光在线性域处理。RAW 白平衡默认“拍摄时设置”：通过相机原始白平衡增益和校准矩阵推算 Kelvin/色调，绝非固定 6500 K。色温范围 2000–50000 K，调高偏暖；色调范围 -150–150，负值偏绿、正值偏洋红。选择“拍摄时设置”恢复相机原始增益，分组/全部重置保留每张照片自己的基准。

  Exposure runs in linear space. RAW white balance starts at As Shot, with Kelvin/tint estimated from camera gains and calibration rather than fixed at 6500 K. Temperature spans 2000-50000 K and higher values warm the image; tint spans -150 to +150, from green to magenta. As Shot restores the original gains; group and global resets retain each photo's baseline.
- 自定义白平衡在去马赛克和富士 LUT 之前以相机通道增益应用，采用 Adobe DNG SDK 的色温/色度转换模型与 LibRaw 的相机校准，不使用显示 RGB 的黑体颜色染色。滑杆使用倒色温刻度。Kelvin 是配置相关的估计值，不承诺与 Lightroom 私有相机配置显示相同数字。缺少有效三通道校准的 RAW 仍可使用拍摄白平衡，但禁用 Kelvin/色调调整。

  Custom WB applies camera-channel gains before demosaicing and the Fuji LUT, using the Adobe DNG SDK temperature/chromaticity model and LibRaw calibration, not black-body tinting of display RGB. The slider uses reciprocal Kelvin. Displayed Kelvin is profile-dependent and is not promised to match Lightroom's proprietary profiles. RAW files without valid three-channel calibration retain camera WB, but Kelvin/tint controls are disabled.
- 默认“标准显影”：基础曝光为 +0.7 EV 加有效的 DNG BaselineExposure；不读取 JPEG 估计默认曝光，也不自动撤销拍摄时的曝光补偿。这是公开的工作流起点，不是逐机型绝对标定。

  Standard Development starts at +0.7 EV plus valid DNG BaselineExposure. It neither meters the JPEG for the default exposure nor automatically cancels in-camera exposure compensation. This is a documented workflow starting point, not absolute per-camera calibration.
- “曝光基准”菜单可切换“匹配内嵌预览”和“传感器基准”，界面显示实际基础偏移。前者是可选的近似匹配，后者关闭基础曝光补偿。切换模式会使 RAW 缓存失效。

  The Exposure Baseline menu also offers Match Embedded Preview and Sensor Baseline, showing the actual base offset. Preview matching is an optional approximation; Sensor Baseline disables compensation. Switching modes invalidates the RAW cache.
- 中性预览使用保留高光层次的 sigmoid 显示映射。富士 LUT 使用另一分支，直接接收线性 RGB 转换后的 F-Gamut / F-Log2，不会先套中性的显示曲线。

  Neutral previews use a highlight-preserving sigmoid display mapping. The Fuji LUT branch receives F-Gamut / F-Log2 converted directly from linear RGB, without first applying the neutral display curve.
- 右上角悬浮直方图可收起，折叠状态不因换片重置。RGB 共用线性像素计数纵轴，填充重叠产生黄/青/洋红和灰色，不再使用对数细线。统计最终 sRGB 显示图，不代表传感器已过曝，也不等同于 Lightroom Develop 的内部宽色域统计。

  The upper-right histogram collapses independently of photo selection. RGB channels share a linear pixel-count axis; filled overlaps produce yellow/cyan/magenta and gray, not logarithmic outlines. It measures the final sRGB display image, not sensor clipping or Lightroom Develop's internal wide-gamut histogram.
- 所有调整集中在右侧工作区底部。胶片与强度、曝光、明暗、色彩、细节参数处于同一排圆形工具中；选择胶片后，下方展示方形包装正面图案，能放下时居中，超出宽度时横向滚动。图片参照实际包装的配色和版式生成，不是官方原图；无对应实体产品的模拟使用标注 `FILM SIMULATION` 的概念图案。

  All controls sit at the bottom of the right workspace. Film selection is a peer of strength, exposure, tone, color and detail in one circular tool row. Film labels below are centered when they fit and scroll horizontally otherwise. The square artwork is generated from packaging colors/layouts, not official imagery; simulations without physical film use concept labels marked `FILM SIMULATION`.
- 拖动调整栏顶部边界可改变高度；点击收起按钮或顶部调整图标可完全隐藏，再次点击顶部调整图标恢复先前高度和参数。左侧文件树贯穿内容区全高，不被调整栏截断。

  Drag the dock's upper edge to resize it. Collapse it completely and restore its previous height and settings using the toolbar adjustment icon. The left file tree spans the full content height and is not cut off by the dock.
- 顶部缩放菜单集中提供适合窗口、100% 实际像素、放大和缩小；对比为单个切换按钮。画布无顶部黑色标题条，右上角直方图使用半透明背景和纯图标标题。

  The zoom menu provides Fit, 100%, Zoom In and Zoom Out. Comparison uses one toggle. There is no black title strip above the canvas; the histogram has a translucent surface and icon-only header.
- 每项支持滑杆、直接输入数字、单项重置；另有分组和全部调整重置。黄色进度环以默认值为起点，正向顺时针、负向逆时针，两侧按各自可调范围归一化。重置不会更换当前 RAW 或选中的 LUT。

  Each adjustment has a slider, numeric input and individual reset, alongside group/global resets. Yellow rings start at the default: positive values fill clockwise, negative values counterclockwise, normalized separately for each side of the range. Resets do not change the RAW or selected LUT.
- 每张照片的参数和胶片选择在本机自动保存，重开同一原始文件可恢复；新照片使用默认调整。保存失败可重试，不写回 RAW，也不创建 sidecar。

  Per-photo adjustments and look identities persist locally across launches. New photos start with defaults; failed saves are retryable. No RAW modifications or sidecars are created.
- 明暗组提供对比度、高光、阴影、S 曲线强度；色彩组提供饱和度；细节组提供锐化。六项 UI 默认均为 0，对比度/饱和度映射到核心的恒等系数 1，其他项映射为 0。高光/阴影正值提亮、负值压暗。这些是 LUT 后成片微调，不是 RAW 高光重建，也不是 darktable 完整模块的移植。

  Tone includes contrast, highlights, shadows and S-curve strength; color includes saturation; detail includes sharpening. All six controls default to 0 in the UI, with contrast/saturation mapped to identity factor 1 in the core. Positive highlight/shadow values brighten and negative values darken. These are post-LUT finishing controls, not RAW highlight reconstruction or a full port of darktable modules.
- 启用锐化时先在原图像素尺度处理，再缩小预览，避免预览和导出锐化半径不一致；预览会比未锐化时慢。100% 视图可检查真实像素细节。本批不暴露简单模糊式降噪。

  Sharpening runs at source-pixel scale before preview reduction to keep its radius consistent with export, so sharpened previews take longer. Use 100% view for real pixel inspection. Simple blur-based noise reduction is not exposed in this UI.
- JPEG/16-bit PNG 导出使用原始 RAW 重新全分辨率渲染，不放大 8-bit 预览。导出不会覆盖原始 RAW 路径。

  JPEG and 16-bit PNG exports render at full RAW resolution rather than enlarging an 8-bit preview. Export cannot overwrite the input RAW path.
- 导出保留 ImageIO 能读取的拍摄时间、相机/镜头、曝光、ISO、GPS 等拍摄元数据。方向和尺寸按成片更新，色彩空间标记为 sRGB；不复制旧缩略图、RAW 传感器布局或不透明 MakerNotes。JPEG 无需再次压缩；PNG 通过无损编码写入标准 eXIf，仍为 16-bit。该行为由 Mac/iOS 共用的 `Shared/ExportMetadata.swift` 实现，不改变 CLI/C API 文件编码。

  App exports retain ImageIO-readable capture time, camera/lens, exposure, ISO and GPS metadata. Orientation, dimensions and color space describe the rendered sRGB image; old thumbnails, RAW sensor layout and opaque MakerNotes are excluded. JPEG metadata is attached without recompression; PNG is losslessly encoded with standard eXIf while retaining 16-bit samples. The Mac/iOS shared Swift helper implements this behavior; CLI/C API file encoding is unchanged.
- 渲染串行执行，最多保留一个在途请求和一个最新待处理请求。拖动滑杆时使用 1000 像素交互预览，松手后自动替换成 2000 像素或原尺寸的精确结果；精确结果完成前禁止导出。数字输入直接触发精确渲染。

  Rendering is serial, with at most one in-flight and one latest pending request. Dragging uses a 1000px interactive preview; release replaces it with an exact 2000px or native-resolution result. Export stays disabled until exact work completes. Numeric input requests exact rendering directly.
- 会话保留当前 RAW 的解包数据和一份线性结果；连续 Kelvin/色调变化复用解包数据，但仍重新执行相机空间白平衡、去马赛克和高光处理。拍摄/自动/自定义白平衡模式之间的切换可能重新识别文件。交互白平衡使用 LibRaw half-size 处理；已有匹配的完整质量缓存可直接供交互预览使用，反之不允许。文件导出和 FINAL 请求始终忽略交互质量标志。

  The session retains unpacked RAW data and one linear result. Numeric Kelvin/tint changes reuse unpacked data but rerun camera-space WB, demosaicing and highlight handling. Switching camera/auto/custom WB may re-identify the file. Interactive WB uses LibRaw half-size processing; a matching full-quality cache can serve a proxy, never the reverse. File export and FINAL requests ignore the interactive-quality flag.
- Mac 默认使用 Metal Auto，支持色域矩阵、曝光、F-Log2、3D LUT、强度、明暗/色彩、细节和缩放；失败回退 CPU。LibRaw 解包、去马赛克、高光重建和文件编码仍在 CPU。中间 GPU 图像使用两个交替复用的缓冲区，避免每一阶段都保留原尺寸副本。

  Mac defaults to Metal Auto for gamut matrices, exposure, F-Log2, 3D LUT, strength, tone/color, detail and resize, with CPU fallback on failure. LibRaw unpacking, demosaicing, highlight reconstruction and file encoding remain on the CPU. GPU stages reuse two intermediate buffers instead of retaining a full-size copy per stage.
- 直方图和裁切蒙版已移到 C++，同时提供 Metal 实现。本机实测 CPU 对这些已回读的像素更快，因此 Auto 使用优化后的 CPU 统计，不为使用 GPU 而增加上传/回读开销。

  Histogram and clipping-mask generation now run in C++, with a Metal implementation also available. CPU was faster on this machine for pixels already read back, so Auto uses optimized CPU statistics rather than adding unnecessary GPU transfers.

### 暗角、颗粒与 GPU 降噪 / Effects and GPU Denoising

底部工具栏新增“暗角”和“颗粒”。暗角强度为 -100 至 100，负值压暗、正值提亮，
同时提供中点、圆度、羽化和高光保护；高光保护只在负强度下可用。颗粒提供 0 至 100 的
强度、大小和粗糙度，相同参数重复渲染保持一致。两项默认关闭，支持单参数、整项及效果组
重置；新参数跟随逐照片调整状态，缺少新字段的旧序列化记录按关闭处理。

暗角和颗粒在 Metal 上按原图分辨率执行，然后缩放预览。小波降噪的 SWT 分解、阈值和重建，
以及色度降噪的引导滤波也支持 Metal，可与暗角和颗粒同时启用。GPU 失败时 Auto 回退 CPU；
Force 不隐藏失败。噪声估计/校准、OpenCV 色彩转换及部分辅助处理仍在 CPU，旧 FBDD、RAW
解码和文件编码也仍在 CPU。结果不是 Lightroom 像素级复刻或实测胶片模型。

The dock adds Vignette (Amount, Midpoint, Roundness, Feather, Highlights) and
Grain (Amount, Size, Roughness), both defaulting off. Effects run at source
resolution on Metal before resizing. Metal also accelerates wavelet SWT filtering
and display-chroma guided filtering, retaining CPU estimation/calibration and
OpenCV color/resampling semantics. Auto has CPU fallback; Force does not hide GPU
failure. Legacy FBDD, RAW decoding and file encoding remain CPU operations.
See the [shared contract](../lutools/docs/color-contract.md#metal-denoising).

## 验证 / Verification

RAW 样片不再随仓库分发。运行真实 RAW 测试前设置 `RAWLAB_TEST_RAW=/path/to/sample.ARW`；
独立 CMake 构建使用 `-DSONY2FUJI_TEST_RAW=/path/to/sample.ARW`。下面的历史报告可能引用已删除的旧样片。

验证文档中的 `/tmp` 和 `.impeccable/review` 路径记录本机产物，不随 Git 发布；本地 RAW 样片也不随本次提交上传。缺少可选样片时，CMake 会跳过对应测试。

Paths under `/tmp` and `.impeccable/review` in verification reports refer to local artifacts, not published Git files. Local RAW fixtures are also excluded from the release commit. CMake omits tests whose optional fixtures are absent.

```bash
bash lutools/test.sh
SONY2FUJI_TEST_GPU=1 ctest --test-dir lutools/build-verify -R color_contracts --output-on-failure
bash RawLabMac/tests/smoke.sh
bash RawLabMac/tests/adjustments.sh
bash RawLabMac/tests/export-metadata.sh
bash RawLabMac/tests/presentation.sh
bash RawLabMac/tests/photo-effects-presentation.sh "$RAWLAB_TEST_RAW" .impeccable/review
bash RawLabMac/tests/photo-effects-render.sh "$RAWLAB_TEST_RAW" /path/to/film.cube wavelet
bash RawLabMac/tests/photo-effects-render.sh "$RAWLAB_TEST_RAW" /path/to/film.cube chroma
bash RawLabMac/tests/app-icon.sh
bash RawLabMac/tests/histogram.sh
bash RawLabMac/tests/render-scheduling.sh
RUN_PROGRESSIVE_RENDER=1 bash RawLabMac/tests/progressive-render.sh
```

Smoke 模式验证 Sony ARW 和存在时的 DJI DNG，输出全分辨率 PNG/JPEG、预览统计和 JSON 至临时目录，并验证缺失输入报错。使用交互界面检查文件选择、参数调整、视图切换和缩放。

Smoke mode checks Sony ARW and, when present, DJI DNG; it writes native-resolution PNG/JPEG, preview statistics and JSON to a temporary directory and checks missing-input errors. Use the interactive app to inspect file selection, adjustments, view switching and zoom.

`adjustments.sh` 验证设置映射、数值范围/非法输入、各级重置，并自动枚举 `lutools/examples` 下的 RAW（包括被 Git 忽略的样片）。每张照片逐项验证六项参数确实改变渲染且不改变 RAW 基础曝光，检查复位结果与 100% 缓冲/16-bit PNG 导出的像素一致性。

`adjustments.sh` checks control mappings, numeric bounds/invalid input and resets, enumerating RAW files under `lutools/examples`, including Git-ignored fixtures. For each photo it checks that all six controls affect output without altering the RAW exposure baseline, that reset restores the result, and that native-resolution display/16-bit PNG pixels agree.

`presentation.sh` 验证原生图标、正负进度环计算、连续缩放与 Retina 实际像素比例、逐照片参数隔离，以及包含 ARW/ARQ/DNG 的目录筛选。

`presentation.sh` checks native symbols, signed adjustment rings, continuous zoom and Retina actual-pixel scale, per-photo isolation, and directory filtering for ARW/ARQ/DNG.

加速回归由 `ctest --test-dir lutools/build-macos --output-on-failure` 执行，包含真实 Sony/DJI RAW 的 CPU/Metal 一致性、交互/精确/导出隔离，以及直方图和裁切蒙版逐值一致性。`render_benchmark` 是显式运行的性能工具，不对机器速度设置 CI 阈值：

`ctest --test-dir lutools/build-macos --output-on-failure` covers real Sony/DJI CPU/Metal parity, interactive/exact/export isolation, and exact histogram/mask agreement. `render_benchmark` is opt-in and does not impose machine-speed thresholds in CI:

```bash
cmake --build lutools/build-macos --target render_benchmark
lutools/build-macos/render_benchmark RawLab/RawLab/Resources/Samples/DSC09067.ARW lutools/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube
```

具体工作空间、曝光约定、LUT 要求见 `../lutools/docs/color-contract.md`。相机颜色准确度仍需要受控光源/灰卡/色卡标定；能够处理 RAW 不等同于复刻 Fuji 机内 JPEG。

See the [color contract](../lutools/docs/color-contract.md) for working spaces, exposure and LUT requirements. Camera color accuracy still requires controlled lighting and gray/color-chart calibration; processing a RAW is not equivalent to reproducing Fuji in-camera JPEGs.
