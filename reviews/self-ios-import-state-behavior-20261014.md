# 独立行为审查：ios-editor-v4 导入状态 WIP

## Must-fix

（无）

## Should-fix

### S1：DNG 导出吞掉已经排队的降噪预览 resize

- 证据：`RawLab/RawLab/Core/ViewModel/RawEditorViewModel+Rendering.swift:38`；同文件 `:18`–`:21` 先清 pending/work、更新 `previewLongEdge`，随后渲染被新增 busy guard 拒绝。
- 触发/调用链：降噪启用；先排队 0.2 秒 resize，再启动持续超过该延迟的 DNG 导出。导出尺寸 sheet 打开后旋转产生 viewport 回调（`UI/ZoomablePhoto.swift:111` → `UI/ContentView+Panels.swift:78`）；sheet 确认只校验尺寸（`UI/ExportSizePicker.swift:101`），经 `UI/ContentView.swift:171` → `UI/ContentView+Helpers.swift:133` → `Core/ViewModel/RawEditorViewModel+IO.swift:447` 设置 busy。
- 后果：实际图像仍用旧尺寸，状态却记录新尺寸；导出完成 `RawEditorViewModel+IO.swift:466`/`:473` 的重放被 Rendering `:7`–`:8` 的相等尺寸条件跳过，放大预览可持续显示旧分辨率，直到另一次编辑。静态路径 confirmed；上述真实 UI 时序未运行。
- Confidence：high（状态路径）；Remedy：resize commit 清除 work/pending 后，若 busy 就保留 requested/settings 并返回，等结束重放再更新 `previewLongEdge`；增加“先 resize、后 DNG”的成功/失败回归。现有 `ViewportStateTests.swift:25`–`:38` 只测反向顺序。

## Scope / evidence

self；目标 `/Users/xupeng/mycode/rawtools/.worktrees/ios-editor-v4`，分支 `codex/ios-editor-v4`；base/merge-base/HEAD 均 `3f87abb5d2188e36c3bbdfafe4ed070f71cffda6`。仅冻结 diff `/tmp/rawlab-ios-v4-import-review.diff` 与 source snapshot 中的新 WIP，10 modified＋5 untracked；不复审历史系列。Dual 行为半：功能、并发/取消、状态流程、测试覆盖，独立审查，无降级、无 bot 结论；旧 AGENTS 限制按父线程授权撤销。CI N/A。

导入 acquisition 前后/catch/restored 的 request guards，以及 VM success/error、RAW/raster preview/error/histogram/finish 的 import/source/render guards均已追踪；默认 delivery 主队列。取消保留已载源；几何 Apply/Cancel/Reset 调用链已读。

日志只读证据：import-state 136 assertions；viewport 3 项 PASS；existing UI 2/0，TEST EXECUTE SUCCEEDED。crop-lock UI 4/4，TEST EXECUTE FAILED，均卡在 `CropLockUITests.swift:117` 的 harness source 等待；触摸行为 **NOT REACHED**。PhotosPicker → ContentView 整条请求替换/晚错误链、真实 RAW 成功和 S1 UI 时序未运行；loader tests 仅覆盖 PhotoImportFile，不能替代该链。未构建、运行或改动模拟器。

## Coverage（15/15，无遗漏）

- `RawLab/RawLab.xcodeproj/project.pbxproj`
- `RawLab/RawLab/Core/Models/PhotoImportTypes.swift`
- `RawLab/RawLab/Core/ViewModel/RawEditorViewModel+IO.swift`
- `RawLab/RawLab/Core/ViewModel/RawEditorViewModel+Rendering.swift`
- `RawLab/RawLab/Core/ViewModel/RawEditorViewModel.swift`
- `RawLab/RawLab/UI/ContentView+Helpers.swift`
- `RawLab/RawLab/UI/ContentView+Panels.swift`
- `RawLab/RawLab/UI/ContentView.swift`
- `RawLab/RawLab/UI/EditorState/EditorCropOverlay.swift`
- `RawLab/RawLab/UI/EditorState/EditorDrafts.swift`
- `RawLab/RawLabUITests/CropLockUITests.swift`
- `RawLab/tests/CropLockHarness.swift`
- `RawLab/tests/ImportStateTests.swift`
- `RawLab/tests/crop-lock-harness.sh`
- `RawLab/tests/import-state.sh`

调用链补读：AdjustmentPanels、GeometryControls、EditorLayout、ZoomablePhoto、ExportSizePicker、ViewportStateTests。建议提交前修 S1，并完成真实触摸验证。无远端评论、review 或 approval；仅写本报告。
