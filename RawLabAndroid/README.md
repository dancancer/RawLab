# RawLab Android
镜头校正与共享核心一致，支持畸变、横向色差、自动/手动匹配及自动裁边，配置接入逐照片记忆和批量任务。离线数据库、依赖和功能边界见[跨平台说明](../docs/lens-correction-platforms.md)。
源依赖构建当前支持 macOS/Linux 主机，需要 Python 3.11+、POSIX shell 和 make。Windows 主机的 GNU libiconv 交叉构建尚未支持；不要将 Windows 托管检查当作 Android 原生构建通过。


真实 RAW 仪器测试使用外部样片：设置 `RAWLAB_TEST_RAW` 或传入
`-PrawlabTestRaw=/path/to/photo.ARW`。构建时仅复制到测试 APK 的 `sample.RAW`；
照片不再随仓库分发，也不进入正式 APK。

原生 Kotlin / Jetpack Compose RAW 编辑器，通过 JNI 复用仓库的 C++ 显影核心。

Native Kotlin / Jetpack Compose RAW editor using the shared C++ pipeline through JNI.

## 功能 / Features

- 几何面板支持百分比裁切、90° 旋转、水平/垂直翻转、±100% 水平/垂直透视及 ±45° 拉直；透视和拉直自动保留中心无黑边画面。所有操作在 RAW 方向校正之后、输出缩放之前执行，顺序为旋转/翻转→透视→拉直→裁切，裁切坐标基于变换后的画面。参数接入逐照片记忆与批量快照；旧基础几何记录保留原有设置并将透视设为零，无几何记录保持原图。原图对比使用同一几何，原始 RAW 不写回。当前几何在 CPU 执行，Auto 可回退，Force 不隐藏 CPU 混合处理。
  Geometry controls support normalized cropping, clockwise quarter-turns, horizontal/vertical flips, ±100% horizontal/vertical perspective and ±45° straightening within an inscribed centered canvas. Geometry follows RAW orientation and precedes output resizing, in the order turns/flips → perspective → straightening → crop. Crop percentages refer to the transformed canvas. Edit memory and batch snapshots retain the full settings; legacy basic geometry records keep their settings with zero perspective, and records without geometry default to identity. Neutral comparison uses the same geometry; source RAWs remain unchanged. Geometry currently executes on CPU; Auto retains fallback and Force rejects mixed CPU processing.

v0.5.0 新增逐照片本机调整记忆和批量 RAW 导出。任务固定当前参数、降噪设置和外观，支持相册/文件多选、目标效果检查、图库/目录输出、取消继续、失败重试与启动恢复；不改写 RAW 或目标编辑记录。新增高光、阴影、对比度、S 曲线、饱和度和锐化，参数约定与桌面对齐。验证见[验收记录](https://github.com/dancancer/RawLab/blob/a38ac6065f747cc43ddbee1c8df232c049b288d2/docs/archive/verification/verification-edit-memory-batch-export-2026-10-10.md)。

- 应用内 RAW 相册、按相册筛选、系统文件导入。相册权限被拒绝时仍可使用文件入口。
  In-app RAW albums with album filtering and a system document-picker fallback.
- 相册右上角的视图菜单可切换方形缩略图和原始比例，并选择每行 1-6 张，默认原始比例、3 列。返回编辑页再打开相册或旋转屏幕时保留视图选择。
  The album view menu switches between square thumbnails and original aspect ratios, with 1-6 columns; defaults are original ratios and 3 columns. View choices survive editor navigation and activity recreation.
- Android 14+ 支持部分照片授权和重新选择；打开相册时才申请权限，不申请所有文件访问权限。
  Android 14+ partial photo access and reselection; no all-files permission.
- 十种内置胶片、中性/结果对比、胶片强度、曝光、拍摄时/自定义色温与色调、单项/全部重置。
  Ten film looks, neutral/result comparison, strength, exposure and calibrated RAW white balance.
- v0.4.0 支持从胶片栏的加号导入兼容 CUBE/RLOOK v1/v2，复制到 `filesDir/looks`，不依赖外部 URI 或 RAW 缓存。导入后自动选中，可重命名、删除并在重启后恢复；原文件删除不影响托管副本，同名导入不会覆盖。缺失外观记录保留可删除，损坏索引不会被静默清空。
  v0.4.0 imports prepared CUBE/RLOOK looks into a persistent managed library. Copies survive original removal and restart, support rename/delete, and never overwrite same-name imports.
- 富士 F-Log/F-Log2/F-Log2C CUBE 在声明匹配的输入色域和 BT.709 输出后可直接导入。技术 Log 输出会解码并转换为显示图像，均支持 GLES；Auto 在后端失败时回退 CPU，Force 要求实际 GPU 执行。
  Declared Fuji F-Log/F-Log2/F-Log2C CUBEs can be imported directly. Technical Log outputs are decoded and display-rendered on GLES. Auto falls back on backend failure; Force requires successful GPU execution.
- 外观选择器可一次选择多个文件，作为单个顺序任务导入。部分失败不回滚成功项，完成后选中最后成功外观；失败文件集中显示在可滚动的结果对话框中，不会被随后完成的预览清除。全部失败保留原选择，取消选择不启动任务。
  Multiple look files import sequentially in one task, preserving partial success and selecting the last successful look. A scrollable result dialog identifies failures and survives preview completion. All-failed batches preserve selection; cancelling the picker starts no task.
- 胶片强度支持 0–200%，默认及重置均为 100%。
  Film strength supports 0-200%, with 100% as the default and reset value.
- 1000px 交互预览、1600px 精确预览；串行渲染只保留最新待处理调整。旋转屏幕保留当前编辑。
  Bounded interactive/exact previews with serialized latest-request scheduling and rotation-safe state.
- 双指缩放、放大后平移；双击在适应画面与 100% 精确预览像素显示之间切换。缩放不触发全分辨率 RAW 显影。参数调整和对比切换保留视口，导入新图复位；对比模式下单指拖分割线、双指缩放和平移。
  Pinch to zoom, pan, and double-tap between fit and exact-preview pixels, without full-resolution RAW rendering. Edits/comparison preserve the viewport; a new photo resets it. In comparison mode, one finger moves the wipe and two fingers zoom/pan.
- 默认启用 GLES 像素加速，失败自动回退 CPU；更多菜单可关闭。画布只显示处理进度，不显示后端和耗时角标。
  GLES pixel acceleration defaults to Auto with CPU fallback; the menu can disable it. The canvas shows processing progress without backend/timing badges.
- 竖屏采用单画面滑动对比、可收起底栏、固定底部工具行；色温与色调分别调整，无需滚动整个工具栏。
  Portrait uses a full-size before/after wipe, collapsible controls, a fixed bottom tool row, and separate temperature/tint tools.
- 原尺寸 JPEG (quality 95) / 16-bit PNG。Android 10+ 可直接保存到相册；所有支持版本均可保存到文件。
  Native-resolution JPEG/16-bit PNG, saved to albums on Android 10+ or to a document on every supported version.
- 单张和批量支持渲染型 DNG 文件导出，保留当前全部调整和导出尺寸。DNG 只保存到文件或所选目录，不写入图库；批量通过文件流发布，不把整个 DNG 复制到 Java 堆。
  Single and batch rendered DNG exports retain current adjustments and final sizing. DNG uses documents/selected folders only, with streamed batch publication rather than full-file Java heap copies.
- JPEG/PNG 导出保留可读取的相机、镜头、拍摄时间、快门、光圈、ISO 和 GPS 等拍摄 EXIF，更新成片方向、尺寸及 sRGB 标记，不复制旧缩略图或 RAW 专有 MakerNotes。
  JPEG/PNG exports retain readable capture EXIF, including camera, lens, date, exposure, ISO and GPS, and update output orientation, dimensions and sRGB tags without copying old thumbnails or opaque RAW MakerNotes.
- 渲染型 DNG 固化外观，不是传感器 RAW，也不提供可恢复的调整滑块。不复制来源拍摄 EXIF；未压缩 float32 RGB 约占每像素 12 字节。格式和存储边界见[渲染型 DNG 契约](../lutools/docs/color-contract.md#rendered-dng)。
  Rendered DNG bakes appearance, not sensor RAW or reversible controls. It omits source capture EXIF and uses about 12 bytes per pixel for uncompressed float32 RGB. See the linked verification for runtime limits.

只处理 RAW，不是 JPEG/HEIC 修图器。原始文件不写回；编辑参数按原始资源身份在本机自动保存，重选同一资源可恢复。

RAW inputs only, not a JPEG/HEIC editor. Originals are never rewritten; edits persist locally by original resource identity.

外观导入只接受已制备成品，不直接执行源 DCP/XMP。先在桌面按 [LUT Preparation](../lutools/docs/lut-preparation.md) 制备，再传给手机；Android 不安装 Python/OCIO。RLOOK 在 Android 使用 CPU，Auto 不会伪装成 GLES 原生 DCP 加速。可导入和可运行不等于已验证原厂或 Adobe 外观忠实度。卸载应用会移除托管外观，保留原始预设备份。

Prepare source assets on a desktop, then transfer the finished look; Python/OCIO is not required on Android. RLOOK uses CPU, not native-DCP GLES acceleration. Runtime support is not manufacturer/Adobe appearance certification. Uninstalling the app removes its managed library.

## 构建 / Build

Requirements: JDK 17 or 21, Android SDK 35, build-tools 35.0.0,
NDK 27.2.12479018, CMake 3.22.1. Minimum Android 8.0 / API 26.
The APK includes `arm64-v8a` and `x86_64`; target SDK is 35.

在 Android Studio 中打开此目录，或安装官方 SDK command-line tools 后执行：

Open this directory in Android Studio, or install the official SDK command-line tools:

```sh
export ANDROID_HOME="$HOME/Library/Android/sdk" # Use your SDK path on Linux/Windows.
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
  "platform-tools" "platforms;android-35" "build-tools;35.0.0" \
  "ndk;27.2.12479018" "cmake;3.22.1"
cd RawLabAndroid # From the repository root.
./gradlew :app:assembleDebug
"$ANDROID_HOME/platform-tools/adb" install -r app/build/outputs/apk/debug/app-debug.apk
"$ANDROID_HOME/platform-tools/adb" shell am start -n com.rawlab.android/.MainActivity
```

SDK 安装按官方工具提示确认许可。也可通过本地、不提交的 `local.properties` 设置 `sdk.dir`。
首次构建需要访问 Google Maven、Maven Central、Gradle 和 GitHub。

Review SDK licenses through the official installer. `local.properties` can set `sdk.dir` locally.
First build requires Google Maven, Maven Central, Gradle and GitHub access.

Gradle wrapper 带下载校验；LibRaw 0.22.2 固定源版本和 SHA-256，由 NDK 为每个 ABI 编译，支持 Panasonic S5 II RW2 的 encoding 8。
无需 Homebrew LibRaw，也不使用旧的 `lutools/build.sh android`。构建时从现有仓库资源生成 LUT、
胶片图标、应用图标和许可 assets，不提交重复图片或预编译库。

The wrapper verifies its download. LibRaw 0.22.2 is source-pinned and checksum-verified,
then built per ABI with the NDK, including Panasonic S5 II encoding 8 support. No host LibRaw or prebuilt `.so` is required.
Assets are generated from existing repository resources rather than duplicated in Git.

## Release

[下载 Android v0.8.1 APK / Download Android v0.8.1 APK](https://github.com/dancancer/RawLab/releases/download/v0.8.1/RawLab-Android-0.8.1.apk) · [完整发布说明 / Release notes](https://github.com/dancancer/RawLab/releases/tag/v0.8.1) · [SHA-256](https://github.com/dancancer/RawLab/releases/download/v0.8.1/SHA256SUMS.txt)

发布 APK 为 `versionName=0.8.1`、`versionCode=13`，沿用正式发布签名，支持同签名旧正式版覆盖升级。0.8.1 默认开启使用统计（正式包带阿里云 RUM SDK，可在关于页关闭），不再申请电话状态、网络状态和应用列表权限，并修正配方插图、配方名语言和若干界面细节，见[发布说明](../docs/releases/v0.8.1.md)。0.8 系列：新增 JPEG/PNG 普通图像输入和混合批量，复用既有 RAW、胶片外观、配方、几何、降噪与导出核心。开发源码的 API35 真机回归覆盖原尺寸预览、FINAL 导出、ICC/cICP 和 RAW 切换；不把这一结果扩展成所有设备/最低系统通过。详见[发布验收](../docs/archive/releases/v0.8/preparation.md)。

The release APK uses version 0.8.1/code 13 and the existing release identity. 0.8.1 turns usage statistics on by default (release builds include the Alibaba Cloud RUM SDK; turn it off in About) and drops phone-state, network-state and app-list permissions; see the [release notes](../docs/releases/v0.8.1.md). JPEG/PNG input and mixed batches use the common rendering core while preserving RAW behavior. See [release acceptance](../docs/archive/releases/v0.8/preparation.md) and package provenance for actual candidate/device coverage.

正式 APK 使用专用发布密钥签名，不使用 debug key。密钥和密码文件必须放在仓库外，
后续更新使用同一密钥；请单独安全备份。构建脚本不创建或上传密钥。

The release APK uses a dedicated signing key. Keep and securely back up the keystore
and password file outside Git; future updates must use the same key. The build script
never creates or uploads credentials.

正式包默认携带阿里云 RUM Android SDK 2.3.2（`env=PROD`，使用统计默认开启，用户可在“关于”里关闭）。
SDK 不进 Git：先用 `bash scripts/fetch-rum-sdk.sh` 从供应商 Maven 仓库下载到主工作区的
`.cache/shared/aliyun-rum/android/2.3.2/`（worktree 也指向主工作区，位置见 `../scripts/rum/shared-cache.sh`），
版本与 SHA-256 固定在 `scripts/rum-sdk.env`，不符即失败。缺少 SDK 时 Release 构建直接报错；
只有离线打包才显式设置 `RAWLAB_RUM_RELEASE=false`（Gradle 为 `-PrawlabRumRelease=false`）。
Debug 默认不带 SDK；`-PrawlabRumLocal=true` 是本地验证构建（`.rumlocal` 包名、`env=LOCAL`、独立同意存储、默认不开启）。

Release builds carry the pinned Aliyun RUM Android SDK (`env=PROD`; analytics on by default, user can turn it
off in About). Fetch it once with `bash scripts/fetch-rum-sdk.sh`; Release fails when it is missing or its
SHA-256 differs. Use `RAWLAB_RUM_RELEASE=false` only for an explicit offline package. Debug builds carry no SDK.

```sh
bash scripts/fetch-rum-sdk.sh
export RAWLAB_RELEASE_KEYSTORE="/absolute/private/path/rawlab-android-release.p12"
export RAWLAB_RELEASE_PASSWORD_FILE="/absolute/private/path/store-password.txt"
export JAVA_HOME="/path/to/jdk-17-or-21"
export ANDROID_HOME="$HOME/Library/Android/sdk"
bash scripts/build-release.sh
```

产物为 `app/build/outputs/apk/release/RawLab-Android-release.apk`，包含签名验证和 16 KB 对齐检查。
Release 与 debug 包使用相同应用 ID、不同签名，不能相互覆盖安装；先保存编辑并导出结果，
再自行卸载旧 debug 包、安装 Release。卸载会删除应用私有数据，不会删除相册原图。

The script verifies the APK signature and 16 KB alignment. Release and debug builds
share an application ID but have different signing keys, so they cannot update each
other. Save/export your work before manually uninstalling a debug build; uninstalling
removes app-private data, not the original album photos.

## 验证 / Verification

Android Debug 的 CPU 降噪依赖 `wavelib`、`opencv_core`、`opencv_imgproc` 与调用方一样使用
`-O3`，仍保留调试符号和断言，不启用 fast-math；仅优化调用方不能优化依赖中的 SWT 和滤波循环。
构建后用实际生成的两份编译数据库检查最后生效的优化选项，不能只搜索是否出现 `-O3`：

```sh
# From RawLabAndroid; replace <build-hash> with the directory from this build.
python3 -B -m unittest discover -s tests -p test_check_cpu_build.py
python3 -B tests/check-cpu-build.py \
  app/.cxx/Debug/<build-hash>/arm64-v8a/compile_commands.json \
  app/.cxx/Debug/<build-hash>/x86_64/compile_commands.json
# Compare snapshots from the same ABI/build directory; repeat for x86_64.
python3 -B tests/check-cpu-build.py --compare /path/to/before-arm64.json \
  app/.cxx/Debug/<build-hash>/arm64-v8a/compile_commands.json
```

检查器严格拒绝不安全浮点选项，即使后面出现相反选项也不视为完全抵消；拒绝未展开的
response/config 文件和 `-Xclang`/`-mllvm` 转发，避免隐藏生效参数。标准的 precise/strict、
contract on/off、IEEE denormal 模式允许通过；限制只作用于被检查的 CPU 目标。
`--compare` 按构建目录规范化后的源文件与输出对象配对，分别报告编译记录数和唯一源文件数。
重复或缺失对象标识会失败；非预期选项变化、对象删除或新增非数值测试对象也会失败。
必需源文件按当前检出和该 ABI 构建目录下的默认 CMake 依赖布局核对完整路径，不接受其他
目录下的同名替代文件；比较时最多允许新增一个当前检出的 `wavelet_denoise_tests` 对象。
检查的是数据库元数据，不要求历史源文件仍在磁盘，也不代替源码、产物哈希或实际运行验证。

`wavelet_denoise_tests` 也可作为 Android CMake 的独立 `EXCLUDE_FROM_ALL` 目标构建，
在设备上执行现有的 SWT golden、纹理/颜色边缘、缓存和逐像素一致性测试；不打包进 APK。
原尺寸 CPU 批处理仍以既有 240 秒用例验证，GPU 开关的模式约定和画质不变。
热点证据、逐像素对照和真机结果见 [CPU 性能验证](cpu-denoise-performance-verification.md)。

```sh
# Repository root: shared rendering regressions.
bash lutools/test.sh
# Android directory: settings/permissions/scheduling/copy tests, lint, APK.
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
# Running emulator or USB device: UI, storage and real Sony RAW integration.
./gradlew :app:connectedDebugAndroidTest
bash scripts/check-native.sh
# Host-only native request contract test (from repository root).
c++ -std=c++17 -I RawLabAndroid/app/src/main/cpp -I lutools/include \
  RawLabAndroid/tests/request_test.cpp -o /tmp/rawlab-android-request-test
/tmp/rawlab-android-request-test
```

设备测试通过 `RAWLAB_TEST_RAW` 或 `-PrawlabTestRaw=/path/to/photo.ARW` 使用外部样片，只将其放入测试 APK，不放入正式应用 APK。v0.2 使用 Sony 样片验证了 7008x4672 原尺寸 JPEG / 16-bit PNG 和 EXIF，并在正式签名 APK 上通过了 10 项模拟器测试。
测试报告位于 `app/build/reports/`，APK 位于 `app/build/outputs/apk/debug/`。
实际验证记录见 [verification.md](verification.md)。

Device tests use an external fixture through `RAWLAB_TEST_RAW` or `-PrawlabTestRaw=/path/to/photo.ARW`, packaged only into the test APK. v0.2 verified native 7008x4672 JPEG/16-bit PNG and EXIF with a Sony fixture, and passed 10 emulator tests against the release-signed APK. See [verification.md](verification.md) for coverage details.

JPEG XL 原生回归使用已运行的本机模拟器，不安装应用，也不修改原始 RAW：

```bash
bash RawLabAndroid/tests/dng-jxl.sh \
  RawLabAndroid/app/.cxx/Debug/<build-id>/arm64-v8a emulator-5554 \
  "$RAWLAB_TEST_JXL_DNG"
```

先运行 `:app:assembleDebug`。测试会比较无损 JPEG XL 和未压缩像素，验证必需的
Stage2 GainMap、白平衡重载、解码器复用、损坏文件错误分类以及 C ABI CPU/Auto 输出。
测试仅使用独立模拟器临时目录，并在结束时删除测试副本。

## 边界 / Limitations

- GLES 3.1 加速缩放、曝光/色彩转换、中性映射、胶片及强度、明暗处理、细节、暗角/颗粒、小波过滤和显示色度引导滤波。RAW 解码、去马赛克、噪声估计、OpenCV Lab 转换及文件编码仍在 CPU。
  GLES 3.1 accelerates resizing, exposure/matrices, neutral mapping, LUT/blending, tone, detail, vignette/grain, wavelet filtering and display-chroma guided filtering. RAW decoding/demosaic, noise estimation, OpenCV Lab conversion and encoding stay on CPU.
- 暗角/颗粒的 8 项参数与 Mac/iOS/Windows 一致，预览、导出、编辑记忆和批量快照均传递完整配置。Auto 在 GPU 失败时回退 CPU；Force 不隐藏失败。新能力的真机范围见 [跨平台验证记录](https://github.com/dancancer/RawLab/blob/a38ac6065f747cc43ddbee1c8df232c049b288d2/docs/archive/verification/verification-cross-platform-effects-gpu-denoise-2026-10-10.md)，历史基线见 [GPU 验证记录](gpu-verification.md)。
  All eight effect parameters match Mac/iOS/Windows and survive preview, export, edit memory and batch snapshots. Auto retains CPU fallback; Force reports GPU failure. See the [cross-platform verification](https://github.com/dancancer/RawLab/blob/a38ac6065f747cc43ddbee1c8df232c049b288d2/docs/archive/verification/verification-cross-platform-effects-gpu-denoise-2026-10-10.md) for current coverage.
- 全尺寸 RAW 显影需要较多 native 内存。低内存设备可能失败或被系统终止；没有验证所有相机和像素尺寸。
  Full-resolution RAW development is memory-intensive; low-memory devices may fail or be killed by the OS.
  X-Trans 并发修复新增每像素 8 字节的只读输入副本，40 MP 约增加 304 MiB 峰值内存；本轮仅验证 Android 构建，未验证这些机型在设备上的内存表现。
  The X-Trans concurrency fix adds an eight-byte-per-pixel immutable input copy, about 304 MiB for 40 MP. This camera sweep validates Android compilation only, not device memory behavior for these models.
- LibRaw 启用 zlib 和 Adobe DNG SDK 1.7.1 的 JPEG XL DNG 解码；其他 RAW 仍使用现有 LibRaw 路径。不编译可选 LCMS/JPEG/JasPer/RawSpeed；有损 JPEG DNG、JPEG2000 等仍不保证支持。
  JPEG XL DNG uses the pinned Adobe DNG SDK 1.7.1; other RAWs retain the existing LibRaw path. Optional LCMS/JPEG/JasPer/RawSpeed remain disabled.
- 相册仅显示被系统媒体库收录且已授权的 RAW。未收录文件可通过系统文件入口导入。
  Albums show authorized, indexed RAW media; unindexed files use the document picker.
- 相册缩略图由系统媒体库提供；Android 10+ 根据显示尺寸请求有界缩略图，Android 8-9 使用系统 `MINI_KIND` 缩略图。尺寸元数据缺失时，原始比例在缩略图加载后确定。
  Album thumbnails come from MediaStore. Android 10+ requests bounded thumbnails for the display size; Android 8-9 uses system `MINI_KIND` previews. Missing dimension metadata falls back to the loaded thumbnail's ratio.
- 已保存的编辑和未完成批量任务可在重开后恢复；未知的图库写入结果需先核对，避免重复输出。不承诺后台持续导出，长时间导出需保持应用前台。
  Process death does not resume edits or exports; keep the app foreground during export.
- 通过 GitHub Release 提供签名 APK，尚未发布到应用商店；不承诺所有设备的性能。
  Signed APKs are distributed through GitHub Releases, not an app store; performance varies by device.

颜色处理遵循 [共享色彩约定](../lutools/docs/color-contract.md)。许可可从空编辑页的“开源许可”查看，
具体来源见 `app/src/main/notices/ThirdPartyNotices.txt`。

Rendering follows the [shared color contract](../lutools/docs/color-contract.md). Notices are accessible from the empty editor.
