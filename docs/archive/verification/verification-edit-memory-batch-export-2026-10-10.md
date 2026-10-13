# Development 迁移验收

日期：2026-10-10。基线：`origin/development` / `c3a2e4c850c64e81addaa35955c5c7eb6373a0f9`。分支：`codex/edit-memory-batch-export`。本报告只记录新 worktree 的验证，不沿用 [10 月 9 日记录](verification-edit-memory-batch-export-2026-10-09.md) 作为新基线证据。

## 范围

- 迁移 Mac、Windows、Android、iOS 的本机逐照片调整记忆、冻结当前设置的批量 RAW 导出、取消/重试/中断恢复，以及 iOS 白平衡和 Android 参数对齐。
- 保留 development 已有的四端降噪、原生处理调用、构建配置和版本号。未带入原工作区的 AI 仿色、暗角、颗粒或其他依赖改动。
- 降噪的启用状态、亮度、色彩、粗色斑参数进入编辑记录、任务快照和只读参数摘要。旧记录缺少降噪字段时恢复关闭状态；重置、失败重试和任务恢复均保留既有语义。
- 原工作区混有其他功能，未清理或回退原文件。本报告记录提交前的验证结果，不代表已发布版本。

## 回归证据

先给 Windows、Android、iOS 的迁移测试加入非默认降噪设置，三个平台均在旧序列化实现上失败：Windows 未识别仅降噪变化，Android 重开编辑记录和任务日志丢失降噪，iOS 重开记录丢失降噪。修复字段编码/解码、Windows 快照比较和编辑回调后，相关测试通过。Mac 复用了 development 已有 Codable 降噪模型，并验证任务日志和实际输出。

独立只读核验未发现迁移集成缺陷，范围限于降噪字段链路、JNI 参数顺序、基线能力保留和无关改动混入，不代替下列运行结果。

## Mac

通过：`edit-memory.sh`、`edit-model.sh`、`batch-export.sh`、`look-import-model.sh`、`build.sh`，以及共享核心 `ctest --test-dir lutools/build-macos --output-on-failure`（11/11）。

```sh
bash RawLabMac/tests/batch-render.sh "$RAWLAB_TEST_DNG"
bash RawLabMac/tests/batch-render.sh "$RAWLAB_TEST_ARW"
```

实际 `BatchExportModel.start()` 使用非默认小波降噪，与单张 `RenderEngine` 的 JPEG/16-bit PNG 解码像素一致：DJI DNG 为 3072x3072，Sony ARW 为 4672x7008，原始文件身份未改变。核心由此 worktree 重新编译，链接现有固定版本依赖，LibRaw 为 0.22.2；未复用原工作区的核心静态库。

另启动此 worktree 生成的原生应用，检查真实 DNG 编辑器、批量菜单、空选中确认页、来源缩略图、全部调整展开和取消返回。零目标时导出禁用，文字和控件未重叠。应用随后关闭。

## Windows

通过：

```sh
dotnet run --project RawLabWindows/tests/editing/EditWorkflow.Tests.csproj
dotnet run --project RawLabWindows/tests/denoise/DenoiseSettingsTests.csproj
dotnet build RawLabWindows/RawLabWindows.csproj -p:EnableWindowsTargeting=true
```

WPF 构建为 0 warnings / 0 errors。Host 测试覆盖编辑重开、旧记录兼容、降噪快照变化、批量参数冻结、重名、逐项失败、取消重试和任务恢复。未运行 Windows 原生 WPF、native DLL 实际导出或 ExifTool 部署验证；Mac 上的交叉构建不能替代这些结果。

## Android

通过：`testDebugUnitTest`、`lintDebug`、`assembleDebug`（arm64-v8a / x86_64），以及 `request_test.cpp` 原生适配器测试。

设备验证命令：

```sh
ANDROID_SERIAL=emulator-5554 RAWLAB_TEST_RAW="$RAWLAB_TEST_DNG" \
  ./gradlew connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.rawlab.android.BatchWorkflowInstrumentedTest,com.rawlab.android.DenoiseControlsTest
```

API 35 arm64 模拟器临时使用 `-memory 8192`，3/3 通过。覆盖包含降噪的真实 RAW 单张/批量像素一致、目标编辑记录不变、旋转和 Activity 重建保留任务、效果检查、图库写入、已知残缺输出清理、放弃任务以及紧凑降噪控件。

低内存边界：原 AVD 配置 `hw.ramSize=2G` 的首次运行被 `lowmemorykiller` 终止，日志记录 RawLab 当时 RSS 457432 kB、swap 1527528 kB。增大虚拟机内存后复测通过，不表示低内存问题已修复；本次没有修改共享降噪算法或永久改写 AVD 内存配置。未操作已连接的实体手机。

截图和首次失败记录位于忽略的 `build/verification/edit-memory-batch-export-migration/`。

## iOS

通过：`edit-memory.sh`、`batch-export.sh`、`presentation.sh`。`lutools/platform/ios/build-framework.sh` 在此 worktree 重建 device arm64、simulator arm64/x86_64，框架校验通过。

`processor-export.sh` 在 iOS 26.4 arm64 模拟器通过，覆盖原生小波降噪、交互/精确输出隔离、关闭降噪恢复、相机/自定义 RAW 白平衡、校准信息和输出元数据。

原生 UI 复测 2/2 通过：`testEditMemoryAndBatchWorkflow` 和 `testLargeText`。覆盖实际照片选择器、编辑后退出重开恢复、零目标禁用、批量选片、横竖屏确认页、实际保存到 Photos 和最大辅助字号布局。结果位于 `/tmp/rawlab-migration-ios-clean-ui.xcresult`；截图已导出到忽略的验证目录。

首次复用了包含以前 JPEG 成片的模拟器，测试选到了非 RAW，批量入口按约定禁用；大字号测试也暴露了单次滑动假设。加入 RAW 前置条件断言和最多三次滚动定位后，改用只预置一张 DNG 的独立模拟器完成上述复测，没有删除原模拟器数据。两台本次使用的模拟器均在验证结束后关闭。

```sh
xcrun simctl addmedia "$IOS_DEVICE" "$RAWLAB_TEST_DNG"
xcodebuild -project RawLab/RawLab.xcodeproj -scheme RawLab \
  -configuration Debug -destination "platform=iOS Simulator,id=$IOS_DEVICE" \
  -derivedDataPath build/ios-migration \
  -only-testing:RawLabUITests/EditorUITests/testEditMemoryAndBatchWorkflow \
  -only-testing:RawLabUITests/EditorUITests/testLargeText test
```

## 限制

- Windows 原生运行验证未完成。
- Android 低内存设备上的全分辨率降噪仍存在被系统终止的风险。
- 没有穷举 Photos/SAF 权限撤销、云端资源不可用或磁盘耗尽等系统故障组合。
- RAW、成片和运行截图仅作为本机忽略的验证产物，不纳入功能源码。
