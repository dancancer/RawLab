# S1 定向修复复核：ios-editor-v4 导入状态

## Must-fix

（无）

## Should-fix

（无）

## S1 结论

**已解决，confidence high。** 最终 `RawLab/RawLab/Core/ViewModel/RawEditorViewModel+Rendering.swift:20` 在清除过期 work/pending 后、消费 requested edge 前拒绝 busy；因此 `previewLongEdge` 保持原值。DNG 成功/失败结束 `RawEditorViewModel+IO.swift:466`、`:473` 重放时，相同 requested edge 仍满足 Rendering `:8` 的“未应用尺寸＋无 work”条件，随后使用最新 settings 渲染。

`RawLab/tests/ImportStateTests.swift:417` 新增两条先 resize 后真实 DNG 的用例：collector 扣住已完成 export，真实 0.2 秒 timer 到期；验证没有提前消费 edge/渲染，允许忙碌期间相同 edge 保留新 settings，然后 release 并验证 request 640、latest settings、实际像素/直方图变化、finish。成功验证实际输出 TIFF/DNGVersion/尺寸 64，失败验证真实 missing-source metadataUnavailable。

DNG completion 改经 `resultDelivery`（IO `:463`、`:470`）；`RawEditorViewModel.swift:81` 默认仍是 DispatchQueue.main.async。导出/渲染算法及 import/source guards 未放宽。delta 未发现新的可行动回归。

## Scope / evidence

self，Dual 行为半的唯一一次 S1 recheck；目标 `/Users/xupeng/mycode/rawtools/.worktrees/ios-editor-v4`，分支 `codex/ios-editor-v4`；base/merge-base/HEAD 均 `3f87abb5d2188e36c3bbdfafe4ed070f71cffda6`。证据：最终冻结 `/tmp/rawlab-ios-v4-import-review-final.diff` 与 `final-source/manifest.txt`/对应内容；同初轮快照逐文件比较，9 文件不变，6 文件 delta，1 新脚本。初轮15文件完整覆盖保留，本轮只复核 S1/相关 delta；不复审历史、不扩展 Root PhotosPicker 范围。无降级、无 bot 结论；CI N/A。

只读日志：`/tmp/rawlab-ios-v4-import-state-complete.log` **167 assertions PASS**，含成功/失败逆序时序；`import-viewport-r2.log` 3组 PASS；existing UI 日志2/0；`crop-lock-r2/crop-lock-ui.log` **4/4 PASS，TEST EXECUTE SUCCEEDED**。`crop-lock-default.log` 4 skips/0 fail，只证明未 opt-in 不启动专用 app。

真实触摸覆盖的是生产 EditorCropOverlay＋真实 VM 的独立 harness，已到达四角/move、导入锁、取消、新源恢复、触摸中断路径；不是 full-app PhotosPicker。**NOT REACHED：PhotosPicker acquisition→ContentView 请求替换→late error/restored 整条实际 UI 链，真实 RAW 成功，以及全 app 的旋转→DNG sheet 竞态。** 本轮未运行测试、构建或修改源码/模拟器；日志来自父线程提供的已完成运行。

## Coverage（最终 manifest 16/16，初轮＋delta，无遗漏）

- `RawLab/RawLab.xcodeproj/project.pbxproj`（不变）
- `RawLab/RawLab/Core/Models/PhotoImportTypes.swift`（不变）
- `RawLab/RawLab/Core/ViewModel/RawEditorViewModel+IO.swift`（delta）
- `RawLab/RawLab/Core/ViewModel/RawEditorViewModel+Rendering.swift`（delta）
- `RawLab/RawLab/Core/ViewModel/RawEditorViewModel.swift`（不变）
- `RawLab/RawLab/UI/ContentView+Helpers.swift`（不变）
- `RawLab/RawLab/UI/ContentView+Panels.swift`（不变）
- `RawLab/RawLab/UI/ContentView.swift`（不变）
- `RawLab/RawLab/UI/EditorState/EditorCropOverlay.swift`（不变）
- `RawLab/RawLab/UI/EditorState/EditorDrafts.swift`（不变）
- `RawLab/RawLabUITests/CropLockUITests.swift`（delta）
- `RawLab/tests/CropLockHarness.swift`（delta）
- `RawLab/tests/ImportStateTests.swift`（delta）
- `RawLab/tests/crop-lock-harness.sh`（delta）
- `RawLab/tests/import-state.sh`（不变）
- `RawLab/tests/crop-lock-ui.sh`（新增）

专用 scene lifecycle、opt-in 与 xctestrun复制/路径重定位已读；只写本报告。建议 S1 可关闭；其余限制保持明确。无远端评论、review 或 approval。
