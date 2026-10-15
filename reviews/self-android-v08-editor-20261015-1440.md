# Code Review: Android Batch GPU Preference

## Must-fix

（无）未发现这两个提交中的生产功能阻断问题。

## Should-fix

### [P2][测试覆盖] 目标导入校验的 GPU-off 分支缺少可观测断言

当前生产代码正确，但自动化测试不能保护三个 processor 创建点中的目标校验点。
如果只把 `BatchExport.kt:437` 的 `NativeProcessor(gpuMode, ...)` 退回默认 AUTO，关闭 GPU 后
`addUris -> copyTarget -> preview` 仍会尝试 GLES。在 AUTO 校验成功的正常设备上，现有断言不会
因此失败：恢复用例绕过 `addUris`，新增 new 用例只测试 GPU-on，而旧 GPU-off workflow 只检查
添加成功、后续效果预览和最终导出。后两处仍正确使用 CPU 时，最终 CPU 像素比对也可以通过。

- Evidence: `RawLabAndroid/app/src/main/java/com/rawlab/android/BatchExport.kt:437`。
- Test trace: `BatchGpuModeInstrumentedTest.kt:95-115`；`BatchWorkflowInstrumentedTest.kt:52-56`、`:89-92`。
- Consequence: 局部丢失目标校验的 GPU 开关传递仍可能全绿；当前全绿不能当作三个创建点都受自动化保护。
- Confidence: high（静态控制流已核对；本轮未执行该局部 mutation）。
- Remedy: 对 GPU-off 新任务的目标校验增加可观测的模式断言，再只错误接线这一处验证测试会失败；不要只重复最终像素比对。

### [P2][测试隔离] 超时清理没有隔离仍在运行的 native job，且可能与发布竞争

`BatchGpuModeInstrumentedTest` 的 finally 在检查 phase 之前先删除全部已记录的输出 URI。
如果 240 秒等待失败时任务仍在运行，它随后只调用 `cancel()`，不等待或隔离正在执行的 native
调用，并跳过 journal、输入目录和 managed look 清理。`cancel()` 只设置标记，`BatchRunner`
只在每行开始前检查它；单张任务当前 render 完成后仍会继续 publish。下一用例若在同一个
instrumentation 进程继续运行，旧工作可能占用 native 全局锁或资源，并留下额外产物。

此外，`saveAlbum()` 在打开/写入输出之前就 checkpoint URI，因此若超时发生在发布期间，
finally 的删除会与 writer/update 竞争。正常完成后的空目录和 MediaStore 检查只证明成功路径。

- Evidence: `RawLabAndroid/app/src/androidTest/java/com/rawlab/android/BatchGpuModeInstrumentedTest.kt:124-135`。
- Trace: `PhotoStorage.kt:179-185` -> `BatchExport.kt:127-129`；`BatchExport.kt:107-122`、`:424-426`、`:536-540`。
- Lifecycle check: `EditorViewModel.kt:536-542` 也没有 join；JNI `rawlab_jni.cpp:297` 的全局锁不会终止旧 job。
- Consequence: 一次超时可能使后续用例失败、阻塞或遗留文件；发布阶段还存在测试清理与写入的竞态。
- Confidence: high（静态触发路径确认；当前正确 HEAD 的超时清理运行分支为 NOT REACHED）。
- Remedy: 先按 active 状态分流，不删除活跃发布 URI；对不能取消的 native 超时采用测试进程隔离/终止，确认工作结束后再清理。保持原 240 秒预算，不以延长等待解决。

## 已确认正确

- `EditorViewModel.kt:448` 为 GPU-on -> AUTO、GPU-off -> CPU；`beginBatch()` 与 `resumeBatch()` 在 `:498`、`:503` 传入当前设置。
- `BatchExportModel` 在 `BatchExport.kt:291` 捕获不可变模式；最终导出、目标校验、效果预览分别在 `:373`、`:437`、`:495` 使用该值。
- 同一模型的 `retryFailed()` 在 `BatchExport.kt:419-421` 复用模式；重新恢复任务则读取当时编辑器开关。GPU 偏好没有被新增到 journal，进程死亡后保留该偏好不在本次承诺范围内。
- native AUTO 的 RLOOK CPU-only 路径与处理失败回退保留：`sony2fuji_c.cpp:1401-1416`、`:1510-1516`、`:1551-1558`；FORCE 不会在失败时伪装成 CPU 成功。
- 现有 CPU/FORCE 独立基准、CPU/GLES 差异断言、RLOOK FORCE 拒绝和 sentinel 保持有效；未把 preview backend 冒充 file-export backend。
- `LookTestFixtures.kt` 只抽取既有 RLOOK 字节生成逻辑，没有生产测试钩子或核心改动。

## 临时错误接线恢复核验

已确认源码、提交树和存留 APK 都没有临时错误模式残留：

1. 当前 `gpuMode()` 与 `a3c6651`/`d1db748` 的正确映射一致，不是常量 CPU，也不是 true FORCE / false AUTO。
2. `git diff d1db748 0521ad1 -- RawLabAndroid/app/src/main Shared lutools` 为空；索引、工作树和相关未跟踪源码在复核前后均为空。
3. 实时重新计算应用 APK SHA-256 为 `6f9bf756b1b8b24be79730a7a2b9633437f67351b60cc86dd9ac7debd356a9d5`，与 d1db748 的验证记录及最终运行证据一致。
4. Test APK SHA-256 为 `ef846817198b6018ef948cd724a36a98643909c73f8d33c45fade2a8f9017a36`，与最终四项测试记录一致。
5. 已有 mutation 日志分别记录预期的 2 项失败和 1 项失败，最终日志为 `OK (4 tests)`、413.86 秒；这些是本轮重新读取的既有证据，不是重新执行的设备验证。

## Review Scope

- Mode: self，本地指定两提交复核，不是整个 UI 功能分支的重新评审。
- Repository: `/Users/xupeng/.codex/worktrees/56c3/rawtools`；branch `feature/android-v08-editor`。
- Base / merge-base: `a3c6651d5027a947dc26622ce07c9258dc5abd69`。
- Commits: `d1db7488fde79ae5b21b475d72b59417bd55aaa6`、`0521ad14d184444e8c30a02832ca9e1aa8eb9b64`。
- Head: `0521ad14d184444e8c30a02832ca9e1aa8eb9b64`，结束前重新核对未变。
- Local coverage: 仅 committed；开始/结束时 staged、unstaged、相关 untracked 均无差异。唯一新增文件是本评审报告。
- Dimensions: 功能正确性、契约、恢复/重试状态和并发、测试覆盖及假阳性。
- Intensity: Dual；两位独立只读 reviewer 均覆盖全部 9 个变更文件，另由主代理核对 native 边界、日志、APK hash 和争议项。未降级。
- Standards: 根 `agent.md`、用户提供的 AGENTS 约定；Android 下无额外 AGENTS。
- Intent: 采用本聊天明确要求，不另行推断产品行为。
- Automated review / CI: N/A，本地 self review；未访问 provider、CI 或远端。
- 本轮没有构建、设备操作、测试运行、源代码修改或新 mutation。

## Change Overview

- d1db748: 6 文件，+139/-15；编辑器两个入口传递 GPU 模式，三个 batch processor 创建点使用该模式，原完整 workflow 改为 CPU 对照并记录证据。
- 0521ad1: 4 文件，+325/-20；新增三个设备用例覆盖五次批处理，抽取 RLOOK fixture，补充验证记录。
- 总计 9 个去重文件全部阅读。影响为 Android 局部生产批处理流程，涉及恢复/重试，风险中等；无 Shared/core ABI、持久化格式或其他平台变更。

## Reconciliation and Limits

- 两路均未发现生产 GPU 传递或 AUTO fallback 的具体缺陷。单路提出超时隔离问题，主代理沿 checkpoint、cancel、onCleared 和 native 全局锁复核，另一 reviewer 进行了反证式确认。
- 主代理识别目标校验测试盲点，独立 reviewer 复核确认；没有把它误报成当前生产行已写错。
- 之前的 inactive 清理问题已核对：现在实际 batch id 和 fixture id 都会 discard；不是当前遗留问题。
- 没有把 `pending()` 主动清理完成任务判为缺陷；这是该断言有意调用的生产行为。
- CPU/GLES 非零像素差异是当前 fixture/driver 的已测前提，不是所有 GPU 的通用数值合约；可能产生跨设备误失败，不是当前假通过。
- 既有记录：新增设备组 4/4；JVM 82 项无失败/错误/跳过；lint 0 错误、32 警告。只读核对记录，不声称本轮新跑通过。
- 资源超限 fallback 是现有 native buffer 控制，不等于在 batch file export 中注入真实驱动故障。真机 GPU、context loss、全相机和 GPU-on 原尺寸 Clean 性能仍未验收。

## Recommendation

当前生产修复没有发现阻断级问题；继续集成前应补齐上述两项 P2 测试保护和失败隔离，再针对性复核。
本次仅给出评审意见，没有修复代码，没有提交、push、PR、远端评论或批准操作。
