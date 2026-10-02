# RawLab Android

真实 RAW 仪器测试使用外部样片：设置 `RAWLAB_TEST_RAW` 或传入
`-PrawlabTestRaw=/path/to/photo.ARW`。构建时仅复制到测试 APK 的 `sample.RAW`；
照片不再随仓库分发，也不进入正式 APK。

原生 Kotlin / Jetpack Compose RAW 编辑器，通过 JNI 复用仓库的 C++ 显影核心。

Native Kotlin / Jetpack Compose RAW editor using the shared C++ pipeline through JNI.

## 功能 / Features

- 应用内 RAW 相册、按相册筛选、系统文件导入。相册权限被拒绝时仍可使用文件入口。
  In-app RAW albums with album filtering and a system document-picker fallback.
- Android 14+ 支持部分照片授权和重新选择；打开相册时才申请权限，不申请所有文件访问权限。
  Android 14+ partial photo access and reselection; no all-files permission.
- 十种内置胶片、中性/结果对比、胶片强度、曝光、拍摄时/自定义色温与色调、单项/全部重置。
  Ten film looks, neutral/result comparison, strength, exposure and calibrated RAW white balance.
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

只处理 RAW，不是 JPEG/HEIC 修图器。原始文件不写回；编辑参数不跨进程退出保存。

RAW inputs only, not a JPEG/HEIC editor. Originals are never rewritten; edits are session-only.

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

Gradle wrapper 带下载校验；LibRaw 0.21.5 固定源版本和 SHA-256，由 NDK 为每个 ABI 编译。
无需 Homebrew LibRaw，也不使用旧的 `lutools/build.sh android`。构建时从现有仓库资源生成 LUT、
胶片图标、应用图标和许可 assets，不提交重复图片或预编译库。

The wrapper verifies its download. LibRaw 0.21.5 is source-pinned and checksum-verified,
then built per ABI with the NDK. No host LibRaw or prebuilt `.so` is required.
Assets are generated from existing repository resources rather than duplicated in Git.

## Release

[下载 Android v0.1.0 / Download Android v0.1.0](https://github.com/dancancer/RawLab/releases/tag/android-v0.1.0)

正式 APK 使用专用发布密钥签名，不使用 debug key。密钥和密码文件必须放在仓库外，
后续更新使用同一密钥；请单独安全备份。构建脚本不创建或上传密钥。

The release APK uses a dedicated signing key. Keep and securely back up the keystore
and password file outside Git; future updates must use the same key. The build script
never creates or uploads credentials.

```sh
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

设备测试使用仓库 Sony ARW 样片，验证 7008x4672 原尺寸 16-bit PNG，不把样片放进正式应用 APK。
测试报告位于 `app/build/reports/`，APK 位于 `app/build/outputs/apk/debug/`。
实际验证记录见 [verification.md](verification.md)。

Device tests use the repository Sony fixture, including a 7008x4672 16-bit PNG check.
The fixture is packaged only into the test APK. See [verification.md](verification.md) for actual coverage.

## 边界 / Limitations

- GLES 3.1 加速缩放、曝光/色彩转换、中性映射、胶片及强度和逐像素明暗处理。RAW 解码、去马赛克、文件编码仍在 CPU。
  GLES 3.1 accelerates resizing, exposure/matrices, neutral mapping, LUT/blending and pointwise tone. RAW decoding/demosaic and encoding stay on CPU.
- 当前界面未提供的锐化/降噪邻域运算不走 GLES；C API Auto 回退 CPU，Force 报错。真机数据见 [GPU 验证记录](gpu-verification.md)。
  Neighborhood sharpening/denoise are not accelerated by GLES: C API Auto falls back, Force fails. See [GPU verification](gpu-verification.md).
- 全尺寸 RAW 显影需要较多 native 内存。低内存设备可能失败或被系统终止；没有验证所有相机和像素尺寸。
  Full-resolution RAW development is memory-intensive; low-memory devices may fail or be killed by the OS.
- LibRaw 启用 zlib，不编译可选 LCMS/JPEG/JasPer/RawSpeed/DNG SDK 集成；有损 JPEG DNG、JPEG2000 等依赖这些可选组件的格式不保证支持。
  Optional LibRaw codecs/integrations are disabled; lossy JPEG DNG and JPEG2000-dependent inputs are not guaranteed.
- 相册仅显示被系统媒体库收录且已授权的 RAW。未收录文件可通过系统文件入口导入。
  Albums show authorized, indexed RAW media; unindexed files use the document picker.
- 进程被系统终止后，不恢复未保存的编辑或进行中的导出。长时间导出需保持应用前台。
  Process death does not resume edits or exports; keep the app foreground during export.
- 通过 GitHub Release 提供签名 APK，尚未发布到应用商店；不承诺所有设备的性能。
  Signed APKs are distributed through GitHub Releases, not an app store; performance varies by device.

颜色处理遵循 [共享色彩约定](../lutools/docs/color-contract.md)。许可可从空编辑页的“开源许可”查看，
具体来源见 `app/src/main/notices/ThirdPartyNotices.txt`。

Rendering follows the [shared color contract](../lutools/docs/color-contract.md). Notices are accessible from the empty editor.
