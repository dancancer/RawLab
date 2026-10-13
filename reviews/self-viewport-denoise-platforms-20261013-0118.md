# 视口降噪优化最终复审

## Must-fix

（无已确认的新代码缺陷）

## Should-fix

（无）

## 推广门禁

- Windows 尚未执行编译、WPF、D3D11 和真实 RAW 测试。本机没有 .NET/Windows 构建环境，已询问可用的独立 Windows runner。不能把静态复审当作运行通过。
- Android 2.5GB 隔离模拟器在真实 Panasonic 6000x4000 RAW 原尺寸降噪 PNG 阶段被 LMK 杀进程。串行独立基准也重现；6GB 模拟器完整通过。一次运行采样为 PSS 2132263KB、RSS 2238668KB、native heap allocated 2620301KB，不是峰值测量。没有优化前同环境基线，尚不能证明这是本次引入的回归；低内存设备仍不得标为验收通过。
- iOS 仅验证模拟器，真实设备的内存、延迟和后台行为未验证。Android 仅构建/运行 arm64，未构建 x86_64 或测量真机表现。

这些限制不重新打开已验证的 core/macOS 两个 P2，但阻止把本轮移植宣布为所有平台完整验收通过。没有提交、推送或发布。

## 评审范围

- Mode: self；仓库 `rawtools`，分支 `review/viewport-denoise-cache`，仅操作附属 worktree。
- Base/head: `b31827cf9c4a3237eaebf3c3d4f8f6fa58422f13`，无新增提交或 staged diff，覆盖相关 unstaged/untracked 修改。
- Core/macOS P2 门禁另见 `self-p2-cache-export-20261013.md`，完成测试后由两位独立评审者复核。
- 新平台最终 diff: `/tmp/rawlab-platform-review-20261013-final.patch`，SHA256 `22aad10d4b233ed130a5122fbb6c0be4cee2788eb7d78c7391de38692551c5c9`。
- 新文件 `RawLab/tests/ViewportStateTests.swift` SHA256 `59a5d31aa5e1b4115a344900553f73188faa48aa005f503a6f03b297e07d5f8f`；`viewport-state.sh` SHA256 `f83a4000d087b059c416dc65eafb44df12197dd310abce43df9c69262b72619f`。
- 维度：缓存失效、尺寸/DPI/缩放和忙态重放、队列/旧结果、原尺寸 JPEG/PNG、C ABI 与测试覆盖。强度：Dual，两位独立评审加主线程实际调用链核验。修复后只重查变更路径；最终指纹重新核对一致。
- 依据：用户要求、`AGENTS.md`、`RawLab/AGENTS.md`、`lutools/docs/color-contract.md`。本地 WIP 无 PR 自动审查或 exact-head remote CI；本地验证如下。

### 覆盖清单

- iOS：`Sony2FujiProcessor.swift`/`+Helpers.swift`，`RawEditorViewModel.swift`/`+IO.swift`/`+Rendering.swift`，`ContentView+Panels.swift`、`PhotoZoomGeometry.swift`、`ZoomablePhoto.swift`，`PhotoZoomTests.swift`、`ProcessorExportTests.swift`、`ViewportStateTests.swift`、`viewport-state.sh`；补读 LUT、导入/批量及持久化调用关系。
- Android：`EditorViewModel.kt`、`EditorScreen.kt`、`MainActivity.kt`、`PhotoCanvas.kt`、`PhotoZoom.kt`、`rawlab_jni.cpp`；`PhotoZoomTest.kt`、`EditorStateReducerTest.kt`、`EditorViewModelRaceInstrumentedTest.kt`、`NativeProcessorTest.kt`、`PhotoCanvasTest.kt`；补读 NativeProcessor、RenderQueue、Reducer、export request。
- Windows：`PhotoCanvas.cs`、`MainWindow.xaml.cs`、`Native.cs`、`RenderEngine.cs`；`DenoiseChecks.cs`、`InteractionChecks.cs`、`PreviewChecks.cs`；补读 LatestWork、Adjustments 和原有导出路径。
- `color-contract.md` 本轮新增平台约束。Core/macOS 生产代码未在推广阶段再次修改，沿用已完成的独立 P2 复审，不重复整套审计。未遗漏新增文件或超过 30 行修改的生产文件。

## 验证结果

| 范围 | 已执行结果 |
| --- | --- |
| Core/macOS | 新缓存测试先失败再修复，最终 CTest 24/24；真实 RAW viewport/native JPEG/16-bit PNG 和模型测试通过；完整记录见 `docs/verification-preview-p2-2026-10-13.md` |
| iOS framework | 当前 core 独立构建 iphoneos-arm64、simulator-arm64/x86_64 XCFramework，架构、LibRaw 补丁及许可证检查通过 |
| iOS app | `xcodebuild -quiet -project RawLab/RawLab.xcodeproj -scheme RawLab -sdk iphonesimulator -configuration Debug -derivedDataPath build/ios-viewport-review CODE_SIGNING_ALLOWED=NO build` 通过 |
| iOS 回归 | geometry、presentation、edit-memory、viewport-state 通过；`processor-export.sh` 使用真实 Panasonic，降噪视口尺寸变化后原尺寸 6000x4000 buffer/JPEG 与独立 FINAL 完全一致；iOS 产品本来仅支持 JPEG，未增加 PNG 功能 |
| Android 构建 | JDK21、SDK/NDK27.2，`:app:assembleDebug :app:assembleDebugAndroidTest :app:testDebugUnitTest :app:lintDebug`，`-Pandroid.injected.build.abi=arm64-v8a` 通过；52/52 单元测试，lint 无 Error/Fatal，35 Warning/1 Information |
| Android 运行 | API35、read-only、6GB 模拟器，7/7 focused 测试通过（149.036s）：应用降噪、视口/交互往返、原尺寸 JPEG/16-bit PNG 对独立 FINAL、窗口/手势/对比几何；最后 busy replay/density 修改后重新构建，2/2 定向测试通过（10.625s） |
| Windows | 仅静态复审和 `git diff --check`；新测试已编写，未执行 |

Android 初次 assemble 因 Adobe 下载中断失败；使用已有校验来源的依赖路径覆盖后构建通过，未修改依赖声明。200px 上降噪像素变化断言不适合这张低噪声样片，改为 1600px 后证明滤波实际生效；没有据此改动生产滤波算法。6GB 与 2.5GB 结果分别保留，未用大内存通过结果掩盖低内存失败。

本次临时模拟器已停止，采用 read-only/no-snapshot，不保存安装或数据变更。iOS 测试以独立命令运行，没有替换用户现有 app。

证据产物：`/tmp/rawlab-ios-export.qs87An`、`/tmp/rawlab-ios-viewport-state.eq1wPI`、`/tmp/rawlab-android-2g-export-failure.log`、`/tmp/rawlab-android-6g-verification.log`；macOS 最终产物 `/tmp/rawlab-viewport-preview.gHIJ9J`。

## 核验与取舍

- 两个 P2：真实 RAW FBDD/WB 往返先重现过期命中（8963 字节不同），只在证明后把实际 baseline EV 的精确 float identity 加入源 key；改锚点不命中，未改锚点仍可命中。原尺寸 JPEG/PNG 通过独立 exact 输出对比，PNG 位深与尺寸均检查。
- 已处理的移植问题：iOS 忙时尺寸重放、同 bounds 下 displayScale 更新；Windows actual-pixel 拖动 bounded、resize 期间禁用方法级导出/应用及关闭降噪取消 timer；Android 保持视口 edge、关闭降噪取消 timer、pending 指示及忙态 demand 重放。
- 撤回误报：Android 使用 `constraints.maxWidth/maxHeight`，是物理像素整数，不是 `maxWidth/maxHeight` 的 Dp；density=3 的独立数值断言已通过，不额外乘 density。
- 撤回误报：iOS 首次 adjusted raster 的输入已经是 1280 的 baseBuffer，不是完整原图；相同尺寸下缺少 viewport opt-in 没有证明不同处理顺序或 full-source 计算，未为配置外观统一修改该路径。
- 最终两位评审均无 Must/Should；运行门禁仍按上文保留。

## 建议

core/macOS 两个 P2 已关闭。其他平台代码已接入，继续完成 Windows 实机/runner 和移动端内存验收，再决定正式推广；本报告不是发布批准。

未发布任何远程评论、review 或 approval。
