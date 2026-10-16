# iOS 裁切锁独立边界审查

## Must-fix

（无）。未确认生产锁、拖动取消或异步发布的可达缺陷。

## Should-fix

### 默认 UI 测试依赖未纳入构建的独立应用

新测试加入默认 `RawLabUITests` 编译集合，但每项都启动 `com.rawlab.tests.crop-lock`。在未预先执行安装脚本的新模拟器上，普通全量 `xcodebuild test -scheme RawLab` 会执行这四项并无法启动目标应用。

- 维度：工作流状态／测试回归；confidence：high（静态调用链确认，本轮未运行新模拟器）。
- Evidence：`RawLab/RawLab.xcodeproj/project.pbxproj:524`、`RawLab/RawLabUITests/CropLockUITests.swift:114`。
- Trace：默认 `RawLab.xcscheme` TestAction → RawLabUITests → `launchHarness()`；项目仅构建 RawLab 与 UITests，唯一 harness 安装路径为 `RawLab/tests/crop-lock-harness.sh:29`。
- Small remedy：让专用测试入口负责构建、安装并运行 harness，并将依赖该入口的测试明确隔离或设为显式启用，避免默认全量测试依赖模拟器历史状态。

## Review Scope

self；`codex/ios-editor-v4`；基线与 HEAD 均为 `3f87abb5d2188e36c3bbdfafe4ed070f71cffda6`。只审冻结的新 WIP（unstaged＋5 个 untracked），采用 `/tmp/rawlab-ios-v4-import-review.diff` 与 source snapshot。Dual 独立边界半；覆盖功能正确性、并发／取消、工作流状态、测试覆盖。未构建、运行、修改模拟器或源码；无远端操作、评论或审批；self 无提供方 CI／自动审查。

## Coverage

15/15 完整读取，无遗漏（以下均为仓库相对路径）：

- `RawLab/RawLab.xcodeproj/project.pbxproj`
- `RawLab/RawLab/Core/Models/PhotoImportTypes.swift`
- `RawLab/RawLab/Core/ViewModel/RawEditorViewModel.swift`
- `RawLab/RawLab/Core/ViewModel/RawEditorViewModel+IO.swift`
- `RawLab/RawLab/Core/ViewModel/RawEditorViewModel+Rendering.swift`
- `RawLab/RawLab/UI/ContentView.swift`
- `RawLab/RawLab/UI/ContentView+Helpers.swift`
- `RawLab/RawLab/UI/ContentView+Panels.swift`
- `RawLab/RawLab/UI/EditorState/EditorCropOverlay.swift`
- `RawLab/RawLab/UI/EditorState/EditorDrafts.swift`
- `RawLab/RawLabUITests/CropLockUITests.swift`
- `RawLab/tests/CropLockHarness.swift`
- `RawLab/tests/ImportStateTests.swift`
- `RawLab/tests/crop-lock-harness.sh`
- `RawLab/tests/import-state.sh`

追踪：PhotosPicker→任务身份／文件释放→VM 导入身份；overlay→CropDragSession→草稿 Binding→预览；锁／来源变化→取消→GestureState 重置／消失；迟到图片、错误、直方图、结束回调；测试 scheme→harness 安装。另读未改 GeometrySettings、GeometryControls、AdjustmentPanels、EditorLayout、scheme 与相关 UI 调用方。

## 证据与限度

五个 handle 测试设计包含合法变化、锁中无写入／无 start、取消＋迟到发布、新触摸；harness 使用真实 VM 计算与真实 overlay，Binding 仅计接受的写入。导入起于首个 editing 回调，因此未证明“已移动后，仅 isImporting 改变且来源 UUID 不变”的取消过程；harness 的结束回调也不执行生产 `setSliderEditing`，锁中不排旧预览由源码守锁和 VM 测试分别支撑。PhotosPicker／ContentView 完整流程不在该 harness。

只读日志快照：import-state 136 assertions PASS；viewport 3 组 PASS；existing UI 2 tests／0 failures。crop-lock UI 4 tests／4 failures，均停在 `CropLockUITests.swift:117` 等待 harness 状态；安装日志确认同 UDID 已安装，启动根因未确认，触摸断言 **NOT REACHED**。不得称原生裁切锁验收通过。

建议先修测试入口并完成原生验证；Shared／RAW processor 未改，本轮不重新宣称 RAW 导出验证。无阻塞审批，审查完成。
