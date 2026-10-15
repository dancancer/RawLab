# Code Review: 20f6397

## Must-fix

（无）

## Should-fix

### [P2][测试隔离] 效果预览超时仍会绕过进程隔离并与输入清理并发

原 UI workflow 点击“查看”后等待 90 秒；若此时 native 效果预览仍未返回，新增的 `active` 判断会得到 false。效果预览不会把批次从 `SELECTING` 改成 `PREPARING/RUNNING`，也不会改变编辑器的 `operation`，因此 `finish(false)` 直接执行 `closeBatch()` 和资源删除，而不是终止进程、交由新进程清理。

- Evidence: [BatchWorkflowInstrumentedTest.kt:104](/Users/xupeng/.codex/worktrees/56c3/rawtools/RawLabAndroid/app/src/androidTest/java/com/rawlab/android/BatchWorkflowInstrumentedTest.kt:104)，触发等待位于同文件第 72-74 行。
- Trace: [BatchExportScreen.kt:108](/Users/xupeng/.codex/worktrees/56c3/rawtools/RawLabAndroid/app/src/main/java/com/rawlab/android/BatchExportScreen.kt:108) 的 `LaunchedEffect` 调用 [BatchExportModel.preview():493](/Users/xupeng/.codex/worktrees/56c3/rawtools/RawLabAndroid/app/src/main/java/com/rawlab/android/BatchExport.kt:493)，它在调用方 coroutine 的 IO context 中同步进入 JNI，不登记到模型的 `running`，也不更新上述状态。
- Cleanup: [BatchTestCleanup.finish():44](/Users/xupeng/.codex/worktrees/56c3/rawtools/RawLabAndroid/app/src/androidTest/java/com/rawlab/android/BatchTestCleanup.kt:44) 在 false 分支调用 close/clean；[EditorViewModel.closeBatch():511](/Users/xupeng/.codex/worktrees/56c3/rawtools/RawLabAndroid/app/src/main/java/com/rawlab/android/EditorViewModel.kt:511) 允许关闭 `SELECTING`，并先调用 `discardDraftOrCompleted()` 删除冻结输入。模型 `close()` 只处理自身 scope/export job，不持有或等待 UI preview。
- Consequence: coroutine cancellation 无法中断已进入的同步 `nativeProcess()`。冻结输入可能在 native 工作仍使用时被删除；旧 native 工作可以越过用例边界，并通过 JNI 的全局 `sessionsMutex` 阻塞后续 native 调用。新 wrapper 仅运行 GPU test class 的四个方法，不包含原 UI workflow，不能为此路径补足强制停止和新进程恢复。
- Confidence: high。源码分支及调用关系已确认；本轮未运行设备，实际 preview-timeout 分支为 **NOT REACHED**。历史成功日志中的 preview 用时 3692 ms，不能证明该失败分支安全。若 preview 已先退出，仅 UI 节点等待超时，则不属于本问题。
- Remedy: 将 UI preview 的 in-flight 工作纳入清理前的隔离判定，或在失败路径统一先终止拥有 native 工作的进程、再由新进程清理。补一个 `SELECTING + preview in-flight` 的失败探针，不修改 240 秒导出等待。

## 原问题逐项复核

1. **GPU-off 目标导入模式断言：未发现假阳性。** 新测试从真实 `EditorViewModel.setGpuEnabled(false)` 进入新批次并调用 `addUris()`；每次使用独立 UUID fixture、目标及 batch，避免命中已存在的目标副本。断言发生于目标导入完成后、任何 batch preview/export 之前，要求 factory 恰好记录 `[CPU]`，且 factory 返回真实 `NativeProcessor(mode, database)`。编辑器普通 import/preview 不经过该 batch factory，不能替代目标校验来满足断言。跳过目标校验、绕过注入 factory 或传 AUTO 都不能满足该断言。
2. **单点错误接线负向证据有效，但未在本轮重跑。** 已读取 `validation-single-site-red/disabledNewBatchValidatesImportedTargetWithCpu.log`，单点 AUTO 探针为 `expected:<[0]> but was:<[1]>`、`FAILURES!!!`、1 test / 1 failure，不能冒充正常通过。最终正常日志为 `modes=[0]`、`OK (1 test)`。
3. **GPU 模式传递、恢复和重试：未发现新问题。** 当前 `gpuMode()` 保持 false -> CPU、true -> AUTO；`beginBatch()` 与 `resumeBatch()` 都传递模式和 factory。目标校验、效果预览、最终导出三个创建点均调用 `processorFactory(gpuMode, ...)`。重试沿用同一个模型捕获的模式。
4. **AUTO 控制有效，未把 FORCE 或全局 CPU 当作 AUTO。** eligible GLES 控制同时要求 batch 与 FORCE 像素一致、与 CPU 不同；预览控制先要求 CPU/GLES fixture 本身可区分。RLOOK 用例要求 FORCE 抛错且不覆盖 sentinel，直接 AUTO preview 的 backend 为 0，batch preview/export 与 CPU 结果一致。export API 不返回 backend，最终导出这里证明的是行为与像素，不把 preview backend 冒称为 export backend。
5. **RUNNING/PREPARING 导出失败隔离有实质修复，但覆盖不完整。** 这些状态先记录 ownership，再 cancel + kill；旧进程死亡后 wrapper 才在新 invocation 中 recover/clean。pending 输出既按 journal URI 又按 fixture 唯一名字查询，带 `include_pending`，避免漏掉未 checkpoint 的 writer；删除前后查询以及 stale URI 去重/幂等处理未发现新的竞态。该结论不能扩展到上面的 `SELECTING` 效果预览分支。
6. **240 秒保持不变。** [BatchGpuModeInstrumentedTest.kt:203](/Users/xupeng/.codex/worktrees/56c3/rawtools/RawLabAndroid/app/src/androidTest/java/com/rawlab/android/BatchGpuModeInstrumentedTest.kt:203) 与 [BatchWorkflowInstrumentedTest.kt:82](/Users/xupeng/.codex/worktrees/56c3/rawtools/RawLabAndroid/app/src/androidTest/java/com/rawlab/android/BatchWorkflowInstrumentedTest.kt:82) 均为 `compose.waitUntil(240_000)`，相对父提交未改。效果预览的 90 秒等待也未改。
7. **临时错误接线已恢复。** 当前生产默认 factory 是真实 `NativeProcessor(mode, database)`；三个 batch 创建点没有硬编码 AUTO/CPU/FORCE。提交中的 7 个代码/测试/脚本 blob 与 `/tmp/rawlab-android-v08-56c3/gpu-p2/final-source-sha256.txt` 的最终恢复快照一致。`batchAbortProbe` 和 `batchLookAbortProbe` 是默认关闭、仅 instrumentation 的显式失败探针，不是生产错误接线。

## Review Scope

- Mode: self，只读本地 review。
- Target: `/Users/xupeng/.codex/worktrees/56c3/rawtools`，`feature/android-v08-editor`。
- Revision: parent/base/merge-base `0521ad14d184444e8c30a02832ca9e1aa8eb9b64` -> head `20f63978a75834dd19b253a7fca1253435801094`。仅此单提交，9 个文件，547 insertions / 29 deletions；不是整个 feature 相对 development 的评审。
- Local coverage: 提交内容；开始时 staged/unstaged 为空。已有未跟踪 `reviews/self-android-v08-editor-20261015-1440.md` 不纳入代码结论且保持原样。结束前 head、分支、index、工作树和旧报告 hash 均未漂移。
- Dimensions: GPU 模式断言及假阳性、开关传递/恢复/重试/AUTO 回退、失败后的进程隔离和资源清理、240 秒预算、临时错误接线恢复。
- Intensity: Dual。两个独立只读 reviewer 完整覆盖相同的 9 文件快照，主线程核验关键调用链；另对效果预览候选做定向反证。无降级、无新 worktree。
- Automated review: 本地单提交，不调用远程自动评审；无 CodeAnt/provider 证据。
- CI snapshot: N/A；未 fetch、未检查远程 CI，未 push、提 PR 或发布任何远程评论/审批。
- Evidence gaps: 本轮未构建、未启动模拟器/ADB、未运行 instrumentation 或 mutation。以下运行证据均为重新读取既有本地产物，不是本轮重新执行。真实设备 GPU 和当前远程 CI 不在验证范围。

## Change Overview

- 生产代码：为 batch processor 增加实例级 factory，贯穿 editor 新建/恢复及 batch 三个创建点，默认行为不变。
- 测试：增加目标导入 CPU 模式断言、ownership manifest 和跨进程 cleanup、pending writer/recovery probes；GPU 和原 UI workflow 接入 helper。
- 工具与记录：新增按 GPU 单方法隔离的 host wrapper，补充验证记录及先前自查报告。
- Impact radius: Android batch 测试生命周期与生产 processor 构造路径，影响集中但涉及 native 并发/进程终止/MediaStore 资源，不是纯外围文档改动。

## 本轮检查与历史证据

- `git show --format= --check 20f6397`：通过，无输出。
- `bash -n RawLabAndroid/tests/batch-gpu.sh`：通过，exit 0。
- 7 个提交 blob 与最终源码 SHA-256 清单比对：全部一致。最终 app/test APK 和 RAW 的 `shasum -a256 -c` 通过；这些产物未加入 Git，也未重新安装。
- 历史 `final-batch-gpu/` 四个方法均 `OK (1 test)`；GPU-off 原尺寸 Clean 导出 132005 ms，4672x7008，CPU reference 像素一致。原 UI workflow `final-workflow.log` 为 `OK (2 tests)`，原尺寸导出 139828 ms。
- 历史 cleanup suite `final-cleanup-tests.log` 为 `OK (3 tests)`，覆盖未 checkpoint、已 checkpoint、checkpoint URI 已删除及旧 owner 恢复；native/look abort 记录 `Process crashed` 后由新 PID recovery 得到 `OK (1 test)`。wrapper 的 failure 标记保持非零，负向探针不是绿色回归。
- 验证文档正确区分 rendering test APK `7f0df4ef...922ea4` 与最终 cleanup test APK `15eb2b0d...f1b205`。未将前者的完整重渲染冒充为后者重新跑过全部重渲染。

## Reconciliation

- GPU 断言、240 秒和生产接线结论由主线程与独立 reviewer 的源码核对一致支持。
- 独立 reviewer 初始未发现 preview 漏检；主线程找到后，定向反证确认没有其他 phase、operation、job ownership 或生命周期 join 能覆盖该 native 调用。最终仅保留这一项可达 P2。
- 另一 reviewer 指出的第二个 workflow 方法缺少 manifest ownership，方法及 finally 在父提交已相同，未证明本提交引入回归；不列为本提交新增缺陷。
- managed-look import 中途任意进程死亡可能留下未登记 stage/orphan 文件，属于更广的 crash-recovery 边界。当前 opt-in kill 在 import 成功返回后才执行，普通异常已有文件清理；本次没有 import 中途终止路径的运行证据，不把它升级为本次 P2。
- 先前提交内自查报告对 active export cleanup 的结论可保留，但“所有失败后清理均安全/两项 P2 完全关闭”的整体结论过宽，需排除本报告的 SELECTING preview 分支。

## Recommendation

提交前先修。此处是对已存在本地提交的后续修复建议，不执行修改或对外发布。

本轮除新增本评审报告外没有修改文件，没有构建、操作设备、注入错误接线、commit、push、提 PR 或发布远程评论、review、approval。
