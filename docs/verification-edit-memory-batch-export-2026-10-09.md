# 调整记忆与批量导出验收

历史记录：以下结果来自 2026-10-09 的原工作区，不代表新 `development` worktree。迁移后证据见[2026-10-10 验收记录](verification-edit-memory-batch-export-2026-10-10.md)。

日期：2026-10-09。范围：[已确认设计](design/2026-10-09-edit-memory-batch-export/README.md)。改动保留在当前工作区，未提交、推送或发布。原有 RAW 兼容性、依赖升级和降噪改动不属于本次交付，不以本报告替代其验证。

## 实现范围

- 四端均增加按原始照片身份索引的本机编辑记录，原子写入，失败保留内存设置并提供重试。未编辑照片使用默认设置；不创建 sidecar，不跨设备同步。
- 批量任务固定来源设置与外观资源，不叠加目标已有调整、不写入目标编辑记录；逐张原始分辨率导出，保留目标自己的可读取元数据，不覆盖原片或已有成片。
- Mac/Windows 使用独立原生任务窗口；Android/iOS 使用原生任务页。支持选片、来源/参数确认、单目标效果检查、进度、取消/继续、逐项错误、失败重试与启动恢复。
- Mac/Windows/Android 支持 JPEG 和 16-bit PNG；iOS 固定 JPEG 到照片图库。图库写入和任务记录之间的未知结果不自动重跑，要求核对，避免重复生成。
- iOS RAW 白平衡采用拍摄时/自定义、去马赛克前 Kelvin 语义；普通图片保持独立路径。Android 补齐高光、阴影、对比度、S 曲线、饱和度、锐化及 JNI 映射。

## Mac

通过：

```sh
bash RawLabMac/tests/edit-memory.sh
bash RawLabMac/tests/batch-export.sh
bash RawLabMac/tests/edit-model.sh
bash RawLabMac/tests/render-scheduling.sh
bash RawLabMac/build.sh
PKG_CONFIG_PATH="$PWD/build/macos15-deps/arm64/install/lib/pkgconfig" \
  bash RawLabMac/tests/batch-render.sh lutools/examples/DSC06251.ARW
PKG_CONFIG_PATH="$PWD/build/macos15-deps/arm64/install/lib/pkgconfig" \
  bash RawLabMac/tests/batch-render.sh lutools/examples/DJI_20250602164503_0444_D.DNG
```

`BatchRenderTests` 直接调用实际 `BatchExportModel.start()` 和 `RenderEngine`。Sony ARW 的 JPEG/PNG 输出为 4672x7008，DJI DNG 为 3072x3072；同一输入单张/批量解码后的像素一致，原片身份不变。另在原生 Mac 窗口完成 DNG + ARW 两张目标的选择、确认、目录选择、进度与实际 JPEG 导出，结果为成功 2、失败 0。原生截图检查未发现文字重叠，目标和来源缩略图均真实显示。

构建环境边界：默认 Homebrew `libraw` 为 0.21.5，`build.sh` 编译/打包检查通过，但该默认产物的 Sony RAW smoke 报 `processing error`。使用仓库已构建的 LibRaw 0.22.2 依赖后，临时应用 `/tmp/rawlab-mac-022.app` 的 Sony/DJI smoke 和上述真实批量验证通过。测试命令保留显式 `PKG_CONFIG_PATH`，未改动无关依赖构建策略。

## Windows

通过：

```sh
build/tools/dotnet/dotnet run --project RawLabWindows/tests/editing/EditWorkflow.Tests.csproj
build/tools/dotnet/dotnet build RawLabWindows/RawLabWindows.csproj -p:EnableWindowsTargeting=true --no-restore
```

Host 测试覆盖记录重开、同名身份、白平衡、重置、快照隔离、重名输出、逐项失败、取消/重试与恢复。WPF 交叉构建为 0 warnings / 0 errors。

未运行：Windows 原生 WPF 窗口、实际 native DLL 导出、EXIF 工具部署和 Windows 权限/磁盘异常交互。当前机器没有 Windows runtime；交叉构建不能替代这些结果。

## Android

通过：

```sh
cd RawLabAndroid
ANDROID_HOME=/Users/xupeng/Library/Android/sdk \
JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk-17.jdk/Contents/Home \
ANDROID_SERIAL=emulator-5554 \
RAWLAB_TEST_RAW=/Users/xupeng/mycode/rawtools/lutools/examples/DJI_20250602164503_0444_D.DNG \
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug \
  :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.rawlab.android.BatchWorkflowInstrumentedTest
```

两项 instrumentation 用例在 API 35 arm64 模拟器通过：

- 真实 RAW 调整持久化、冻结来源、旋转/Activity 重建保留任务、实际目标效果预览、图库 JPEG 输出、单张/批量像素一致、目标旧编辑记录和 RAW 原片不变。
- 恢复时清理已记录 URI 的未完成输出，保留未处理状态，放弃任务后删除 journal。全成功任务在后续扫描时清理工作副本。

Host `request_test.cpp` 使用 `clang++ -std=c++17` 编译运行通过，包含高光 +25% 到核心 -0.25 的方向映射。单元测试还覆盖 PNG 命名、取消后继续、发布阶段 checkpoint、未知结果不自动重跑、原子记录失败不污染内存。

本机截图在 `build/verification/edit-memory-batch-export/android-*.png`，包含确认页横竖屏、效果检查和成功结果。没有在连接的个人 Android 真机上安装测试包。

未运行：真实 SAF 云文件提供者、Android 8/9 目录授权、外部撤销权限和强杀发生在系统创建 URI 与首次 journal checkpoint 之间的窄窗口。该未知窗口保留“待核对”状态，不自动生成第二份输出。

## iOS

通过的 host/processor 检查：

```sh
bash RawLab/tests/edit-memory.sh
bash RawLab/tests/batch-export.sh
bash RawLab/tests/presentation.sh
bash RawLab/tests/processor-export.sh <built-simulator-RawLab.app> <simulator-id>
```

涵盖调整/模式恢复、同名隔离、保存失败、白平衡切换保留另一轴、Photos checkpoint 与未知结果、取消/失败重试、临时选片文件的拥有与释放；真实 RAW 请求验证 camera/custom 白平衡、校准信息、200% 强度、JPEG 拍摄时间/镜头/GPS/方向和尺寸。

原生流程验证使用单独创建的 `RawLab Batch Verification`（iPhone 17e / iOS 26.4）及外部 DJI DNG，不涉及其他模拟器的照片。发现并修复 FileRepresentation 临时 URL 生命周期、原始 RAW 资源读取及恢复提示覆盖导航栏的问题。PhotosPicker 明确使用 `.current` 和 `.shared()`；需要时通过正常读取授权使用 `PHAssetResourceManager`，不把已知 RAW 失败静默改成 JPEG。

读取底层原始资源采用 [Apple 的 PHAssetResourceManager API](https://developer.apple.com/documentation/photos/phassetresourcemanager)，不从系统照片数据库获取应用数据。

原生 `testEditMemoryAndBatchWorkflow` 与 `testLargeText` 共 2 项通过，0 failures / 0 skipped：实际 DNG 导入、修改、关闭重开恢复、选入批量、横竖屏确认页和 Photos 保存完成，以及编辑器大字号横竖屏操作。结果包为 `/tmp/rawlab-batch-ios-verified.xcresult`，截图导出在 `build/verification/edit-memory-batch-export/ios/`。

截图复核发现旧任务来源缩略图丢失，追到 iOS 更新应用后 Data Container 路径变化：journal 中的绝对私有路径过期。已添加先失败后通过的迁移回归测试，在读取 journal 时将任务拥有的来源/目标/外观文件定位到当前容器；不重写外部原片路径。相同读取入口也清理已完成任务的副本。最终构建通过，当前源码的原生批量流程再次通过（`/tmp/rawlab-batch-ios-current-head.xcresult`，1 passed / 0 failed），并确认来源与目标缩略图都正常显示；最新截图在 `build/verification/edit-memory-batch-export/ios-current/`。

测试使用正常 simulator ad-hoc signing，不使用 `CODE_SIGNING_ALLOWED=NO`。人为预设 `photos` 与 `photos-add` 曾造成冲突授权，TCC 日志显示重复申请 full access 被拒绝；重置该测试 App 的两个权限并通过系统授权流程后已解除。没有改动系统权限数据库。

## 剩余验收边界

- Windows 原生运行仍需要 Windows runner。
- 未覆盖所有平台的大批量内存/存储压力、断电、iCloud 离线和全部第三方文件提供者；已覆盖的状态机/写入异常不能代表这些完整平台场景。
- 移动端按前台任务执行；离开应用请求停止当前批次，不承诺后台持续显影。
- 截图和外部样片只存放于本机构建/测试产物，未将个人 RAW 或生成的真实照片加入版本控制。
