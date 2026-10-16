# iOS 裁切锁测试入口修复复核

## Must-fix

（无）。

## Should-fix

（无）。初轮“默认 UI 测试依赖未纳入构建的独立应用”已修复；初轮原生触摸 **NOT REACHED** 已由四项实际通过替代。

## 修复核对

- 默认 `setUpWithError` 在未设置 `RAWLAB_CROP_LOCK_HARNESS=1` 时先抛出 `XCTSkip`，不会启动 harness：`RawLab/RawLabUITests/CropLockUITests.swift:12`。默认入口日志为 **4 skipped／0 failures**，这些跳过不算测试通过。
- 新专用入口先编译、安装 harness，再显式启用并仅运行 CropLockUITests：`RawLab/tests/crop-lock-ui.sh:12`、`:40`、`:49`。复制 version-1 xctestrun 时把 `__TESTROOT__` 定位至原 build-products 路径，保留其余环境／替换：`:27`。只读比较保存的运行配置与原配置，结果恰好等于路径迁移后增加两个启用标记，无其他差异。
- UIKit 主机改用 `UISceneConfiguration` 与 `UIWindowSceneDelegate` 创建并持有窗口：`RawLab/tests/CropLockHarness.swift:262`、`:275`。manifest 的类名 `CropLockHarness.CropLockSceneDelegate` 与编译 module-name 一致：`RawLab/tests/crop-lock-harness.sh:22`、`:31`。四项测试能进入触摸断言，启动证据缺口关闭。
- 与初轮 snapshot 比较，测试体、真实 touch、isHittable、合法 geometry、writes／starts／ends 和恢复次数断言均未改；该复核结论 confidence：high。

## Review Scope／Coverage

self，`codex/ios-editor-v4`，基线／HEAD `3f87abb5d2188e36c3bbdfafe4ed070f71cffda6`；冻结 WIP 来自 `/tmp/rawlab-ios-v4-import-review-final.diff` 与 `final-source/manifest.txt`（16 files）。Dual 边界半唯一一次定点复核；维度为测试集成、原生触摸证据。

初轮 15/15 完整读取记录保留于 `self-ios-crop-lock-regression-20261014.md`。本輪已读全部指定修复 delta：`CropLockUITests.swift`、`CropLockHarness.swift`、`crop-lock-harness.sh`，以及新增完整 `crop-lock-ui.sh`，无指定范围遗漏。追踪默认 setup→skip；专用脚本→manifest／scene→窗口→真实 overlay／VM→四个测试。

本轮未扩展复审 IO、Rendering、ImportStateTests 的其他修复 delta，相关 resize／DNG 行为由另一个 reviewer 审定；不将初轮生产代码结论外推至未复核的新 delta。没有运行测试、构建、修改源码或模拟器。self 无提供方 CI／自动审查；无远端评论、review、approval。

## 验证与剩余证据边界

只读 `/tmp/rawlab-ios-v4-crop-lock-r2/crop-lock-ui.log`：四项分别通过（23.380／15.803／25.001／58.403 秒），4 tests／0 failures，`TEST EXECUTE SUCCEEDED`。默认日志 `/tmp/rawlab-ios-v4-crop-lock-default.log`：4 skipped／0 failures。另读取 core 最新日志末尾确认 167 assertions PASS，仅作为运行状态记录。

原生证据覆盖五个 handle 的正常合法变化、导入锁中写入／start 阻止、取消与迟到发布、新触摸，以及触摸首个 editing 回调触发导入后的取消。它使用真实 VM 和 production overlay，但不包含 PhotosPicker／完整 ContentView 导入流程；harness 的 ended 回调不执行 production `setSliderEditing`。来源 UUID 不变、已移动后仅由 isImporting 改变的取消过程，仍未由该原生 harness 单独证明。Binding 统计接受的写入，不能解释为“没有尝试调用 setter”。这些边界保留，未增加新缺陷或扩展工作。

结论：指定两项复核目标已关闭，无剩余 blocker；本轮不需要再次复核测试入口。
