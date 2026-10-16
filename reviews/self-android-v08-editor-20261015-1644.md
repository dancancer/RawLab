# Code Review: SELECTING Preview Isolation Fix

## Must-fix

（无）

## Should-fix

（无）本次限定范围未发现尚待修复的 P1/P2。此前 SELECTING 效果预览失败后提前清理的 P2 已关闭。

## 原 P2 复查

- [BatchWorkflowInstrumentedTest.kt:74](/Users/xupeng/.codex/worktrees/56c3/rawtools/RawLabAndroid/app/src/androidTest/java/com/rawlab/android/BatchWorkflowInstrumentedTest.kt:74) 在点击查看之前设置 `previewPending`，只有唯一目标的预览 Image 出现后才清零；[第 124 行](/Users/xupeng/.codex/worktrees/56c3/rawtools/RawLabAndroid/app/src/androidTest/java/com/rawlab/android/BatchWorkflowInstrumentedTest.kt:124) 将该标志纳入进程隔离条件，不再仅依赖批次 phase/editor operation。
- 清零顺序成立：`nativeProcess` 返回 -> Bitmap 拷贝 -> processor `use/close/nativeDestroy` 返回 -> `BatchExportModel.preview()` 返回 -> Compose 赋值 -> Image semantics 出现。缩略图没有该 contentDescription，目标文件名含唯一 fixture UUID，不会由其他图片满足完成条件。若预览抛错、被取消或等待超时，标志保持 true，保守地先 kill，再由新进程 cleanup。
- 失败探针要求同一线程栈同时包含 `NativeProcessor.nativeProcess` 和 batch preview coroutine，然后显式断言 `SELECTING`、`Operation.NONE`、输入存在。不是仅观察任意 native 线程或模拟渲染。
- [BatchTestCleanupInstrumentedTest.kt:85](/Users/xupeng/.codex/worktrees/56c3/rawtools/RawLabAndroid/app/src/androidTest/java/com/rawlab/android/BatchTestCleanupInstrumentedTest.kt:85) 的探针恢复要求 manifest 真正存在、旧 PID 已退出且不同于当前 PID、fixture/job 不同并各有两份非空输入；清理后验证目录、journal properties 和 manifest 均消失。没有 manifest 的无操作路径无法冒充成功接管。
- [batch-gpu.sh:47](/Users/xupeng/.codex/worktrees/56c3/rawtools/RawLabAndroid/tests/batch-gpu.sh:47) 在 recovery invocation 前 force-stop 并确认包 PID 消失；recovery 还会拒绝 `/proc/<oldPid>` 仍存在的 owner。失败后的资源删除没有发生在旧进程中。
- 原 UI 的 `240_000`（第 102 行）及 GPU 回归的 `240_000`（第 203 行）均未修改，原 UI preview `90_000` 也未修改。探针的 60 秒仅等待真实 native 栈出现，不替代或放宽正式等待。
- 生产代码、GPU 模式映射、恢复/重试接线、AUTO 回退逻辑完全未改；应用 APK SHA-256 与 `20f6397` 验证产物一致。没有临时生产错误接线。

## 本轮实际验证

证据目录：`/tmp/rawlab-android-v08-56c3/preview-p2/`。以下均为本轮新运行，不是沿用旧设备日志。

- RED：未修复时，PID 3096 命中 preview native / SELECTING / NONE；旧进程仍执行 `cleanupComplete`。新进程恢复 FAIL 于缺失 ownership manifest，wrapper exit 1，证明探针能抓到原问题。
- 修复后负向探针：3369 -> 3462、3515 -> 3612、4621 -> 4706 三次均有真实 native-entry、deferred cleanup、crash、输入保留和新进程清理记录；三个 wrapper 均保持 exit 1，不把预期崩溃变为绿色测试。后两次还运行后续正常 native/partial recovery 方法，均通过。
- 正常默认 wrapper：6 个 GPU/UI 方法及 6 个新进程 recovery invocation 全部通过，12 次 `OK (1 test)`，exit 0。
- 恢复 CPU 原尺寸 Clean JPEG 导出 148315 ms，4672x7008，独立 CPU reference 像素一致。原完整 UI workflow 导出 135464 ms，效果预览 3386 ms，独立 CPU reference、输入字节、目标编辑记录、旋转/重建及发布/关闭均通过。
- GPU-on eligible GLES：恢复/新建导出 5141/5378 ms，与 FORCE 一致且不同于 CPU。AUTO RLOOK：9708/8451 ms，与 CPU 一致，FORCE 拒绝且 sentinel 不变。
- Cleanup suite：`OK (3 tests)`，0.208 s，包括 pending writer、live-owner 拒绝和 simulated dead-owner 检查。
- Gradle JVM/lint/app/test APK gates 通过，82 JVM results，0 failures/errors/skips；lint 0 errors/32 existing warnings。使用有效 up-to-date 输出，不是 clean build。APK/native 16 KB 对齐、脚本语法、diff whitespace 和最终源码/APK/RAW checksum 检查均通过。没有 Gradle build 与设备测试重叠。
- 最终已安装 APK 与记录 hash 一致；batch 目录、manifest、render 临时文件及含 pending 的 RawLab gallery 为空，looks 仅 registry 且 count=0。task-owned emulator/private ADB 已退出，共享 ADB PID 保持不变。

## Review Scope

- Mode: self，修复后的本地 WIP 复查。
- Target: `/Users/xupeng/.codex/worktrees/56c3/rawtools`，`feature/android-v08-editor`。
- Revision: HEAD/base `20f63978a75834dd19b253a7fca1253435801094` + 4 个已跟踪 WIP 文件，190 insertions / 6 deletions；index 为空，未 commit。
- Coverage: 两个 instrumentation 测试文件、batch wrapper、GPU 验证文档；另沿 UI `LaunchedEffect`、batch preview、processor close、cleanup/recovery 和 JNI 生命周期核验。已有 `1440`、`1612` 未跟踪报告保持不变，不纳入交付文件改动。
- Dimensions: 进程隔离/清理顺序、预览探针和恢复断言假阳性、wrapper selector/失败语义、正式等待及错误接线恢复。
- Intensity: Focused Solo。主线程实现和设备验证；一位独立 reviewer 复查全部改动并对最终脚本/文档增量复查，另有独立探针设计反证核验。无新 worktree。
- Automated review/CI: N/A，本地任务。未 fetch 或访问远程自动评审/CI，没有远程评论或审批。
- Evidence boundary: 三次 crash probe 是 native 进入后的注入失败，不是等待真正 90 秒超时；修复覆盖真实超时所走的相同 finally。physical GPU、其他设备及 hosted CI 为 NOT REACHED。不扩展为任意应用崩溃或所有非 native IO 的原子恢复保证。

## Reconciliation

- 独立核验确认 native close 早于 Image 发布，`previewPending` 清零不存在同一预览尚在 native 的窗口；主线程复核相同调用链。
- reviewer 提出的 recovery 失败时不继续运行，按资源 ownership 安全边界明确为有意 fail-fast，而非错误；主测试失败但 recovery 成功时继续，整体非零状态保持。
- 全限定 selector 兼容已补齐并用真实 invocation 验证。正常六方法运行后才修改 selector 归一化，没有编辑运行中的脚本；后续定向验证覆盖全部三种 selector 形式，两个 APK/测试源码未变。文档区分两个 wrapper 快照，没有声称最后 parser 重新全量渲染。
- 历史 commit preparation 的七文件加文档清单确属 `gpu-p2` 目录，当前 `preview-p2` 清单只有两测试加 wrapper。已用完整历史路径消除同名清单歧义，没有虚报文档或生产代码 checksum 覆盖。

## Recommendation

本次 P2 修复与本地验证完成，可保留为当前未提交改动。无需为该问题延长任何等待。

没有 commit、push、提 PR、release 或发布远程 comment、review、approval。样片、APK、构建产物和临时运行证据均未暂存或加入 Git。
