# Code Review: Android Batch GPU P2 Fixes

## Must-fix

（无）

## Should-fix

（无）

未发现这次本地修复中的新阻塞缺陷，两项原 P2 已关闭。以下结论区分生产接线、测试构造模式、实际 native 行为和失败路径，不把预期 crash 算作测试通过。

## 逐项复核

### GPU 关闭时的目标导入校验

- `EditorViewModel` 保留 `(Application)` 构造器，默认 factory 仍返回真实 `NativeProcessor(mode, database)`；新建和恢复均传递当前 `gpuMode()` 与 factory，没有更改 GPU 偏好生命周期。[EditorViewModel.kt](/Users/xupeng/.codex/worktrees/56c3/rawtools/RawLabAndroid/app/src/main/java/com/rawlab/android/EditorViewModel.kt:72)
- 批导出、目标导入校验、效果预览三个创建点均使用捕获的 mode；重试仍使用同一个 model 的配置。[BatchExport.kt](/Users/xupeng/.codex/worktrees/56c3/rawtools/RawLabAndroid/app/src/main/java/com/rawlab/android/BatchExport.kt:438)
- 新测试通过编辑器关闭 GPU，再 `beginBatch -> addUris`，在任何批效果预览/导出前断言恰好一次 CPU 创建。factory 不 mock 渲染。[BatchGpuModeInstrumentedTest.kt](/Users/xupeng/.codex/worktrees/56c3/rawtools/RawLabAndroid/app/src/androidTest/java/com/rawlab/android/BatchGpuModeInstrumentedTest.kt:29)
- 单点负对照只将 `copyTarget` 的 factory 参数改为 AUTO，得到 `expected [0] but was [1]`；已恢复，最终正常跟进再次记录 `[0]`。不是用全局开关 mutation 代替此处验证。

### Active 失败隔离与清理

- finally 记录实际 job ID 后，先判断 active。active 分支只取消并终止失败 instrumentation 进程，未先删输出、输入、journal 或 look，也未增加 native join 等待。[BatchTestCleanup.kt](/Users/xupeng/.codex/worktrees/56c3/rawtools/RawLabAndroid/app/src/androidTest/java/com/rawlab/android/BatchTestCleanup.kt:44)
- host wrapper 每方法独立调用；失败后先 force-stop、确认 PID 消失，再新进程 recovery。任何 crash/失败保持整体非零，不自动重跑失败导出。[batch-gpu.sh](/Users/xupeng/.codex/worktrees/56c3/rawtools/RawLabAndroid/tests/batch-gpu.sh:17)
- recovery 拒绝仍存活的 owner；图库查询包含 pending，按 MediaStore ID 去重，存在才删、删后复查，避免 URI alias 或已清理 URI 的重复删除异常。唯一名字覆盖 insert 成功而 checkpoint 未完成的窗口。只清记录的两个 ID、对应 checkpoint `.tmp`、新增 render 文件和预记录原始名的 managed look。[BatchTestCleanup.kt](/Users/xupeng/.codex/worktrees/56c3/rawtools/RawLabAndroid/app/src/androidTest/java/com/rawlab/android/BatchTestCleanup.kt:63)
- writer probe 覆盖无 checkpoint、已有 checkpoint、已删除的 checkpoint URI，确认 active 不关闭/删除、live owner 不允许接管。dead-owner probe 确认两个目录/properties 和临时 checkpoint 被清理，已有 render 与无关输入保留。[BatchTestCleanupInstrumentedTest.kt](/Users/xupeng/.codex/worktrees/56c3/rawtools/RawLabAndroid/app/src/androidTest/java/com/rawlab/android/BatchTestCleanupInstrumentedTest.kt:13)
- 实际 native probe 在 `nativeProcess` 活跃时注入断言：旧 PID 6107 退出，新 PID 6165 清理；managed-look 导入返回后立即退出的 probe 由 PID 6212 到 6278 接管。两次 runner 都报告 `Process crashed`，wrapper 均 exit 1，属于预期负向结果，不是成功的 240 秒用例。
- 去掉 cleanup 的 pending 查询条件会使 writer probe 明确失败，最终查询发生在兜底删除之前，没有清理动作掩盖断言的假阳性。

## 本地验证

- 正常 GPU 回归 4/4：目标导入 CPU 模式；恢复原尺寸 Clean JPEG 导出 132005 ms、4672x7008、CPU 像素完全相同；新建/恢复 GLES 与 FORCE 一致且区别于 CPU；新建/恢复 RLOOK AUTO 回退与 CPU 一致、FORCE 拒绝。
- 原 UI workflow 2/2，295.369 s 总计：原尺寸 Clean 批导出 139828 ms，旋转/重建、效果查看、发布/关闭、单图像素对比及目标编辑记录/输入保护通过。运行时图库输出 4672x7008、`is_pending=0`。
- 两个正式导出等待仍为 `240_000`，未降原尺寸 Clean 质量。方法总时长还包含独立 reference 导出，不是延长了该等待。
- 最终 cleanup suite 3/3；最终清理增量后又跑目标导入与新建/恢复 AUTO RLOOK 两方法，wrapper exit 0。
- Gradle JVM/lint/应用与测试 APK 构建通过：82 JVM 测试，0 failure/error/skip，lint 0 errors/32 原有 warnings；APK 与 8 个 native 库 16 KB alignment 通过；`bash -n`、`git diff --check` 无问题。部分任务合法复用 up-to-date 结果，非 clean build。
- 最终设备中任务目录、manifest、render 临时文件和图库均无残留，look registry `count=0`；样片 SHA-256 不变。

渲染回归使用测试 APK `7f0df4ef...922ea4`。随后只修改清理代码及清理测试；最新测试 APK `15eb2b0d...f1b205` 完成 cleanup suite、两项 crash probe 和两方法正常跟进。两阶段应用 APK 都是 `b1fa8390...9f9fbc1`，设备安装文件 hash 已核对。未把先前渲染调用冒充为后一个测试 APK 的全量执行。

## Review Scope

- 审查时为 Self review，分支 `feature/android-v08-editor`，base/HEAD `0521ad14d184444e8c30a02832ca9e1aa8eb9b64` 加本地 WIP；当时无 staged 内容。
- 完整检查 8 个本次代码/文档文件：`BatchExport.kt`、`EditorViewModel.kt`、`BatchGpuModeInstrumentedTest.kt`、`BatchWorkflowInstrumentedTest.kt`、新增 `BatchTestCleanup.kt`、新增 `BatchTestCleanupInstrumentedTest.kt`、新增 `tests/batch-gpu.sh`、验证文档。旧 `1440` 报告保持原样。
- 维度：GPU 参数契约、新建/恢复/重试、AUTO 回退、并发与资源清理、测试假阳性。Solo 独立子代理审查，多次有界增量复核，由主代理核实具体代码与设备证据。
- 外部自动 review / hosted CI：N/A，仅本地验证。没有网络发布、远端评论、review 或 approval。
- 证据目录：`/tmp/rawlab-android-v08-56c3/gpu-p2/`；详细命令、各阶段 hash 和失败/成功日志见 [验证记录](/Users/xupeng/.codex/worktrees/56c3/rawtools/RawLabAndroid/batch-gpu-preference-verification.md:192)。

## 边界与结论

仅验证 task-private API 35 ARM64 / SwiftShader。未覆盖物理 GPU、其他相机/设备和 hosted CI；未新增 GPU 偏好持久化或可中断的生产 native API。这是已记录 export 任务的测试隔离，不承诺任意外部进程死亡发生在 job 所有权落盘前的原子恢复，也不清除无关应用缓存。

本地修复与验证完成；本报告记录的是整理本地 commit 前的审查快照。后续提交整理未改动已验证的实现或回归测试代码，提交前重新核对源文件/APK/RAW hash 并执行 host 门禁，设备用例未重跑。任务模拟器和私有 ADB 已退出，shared ADB 未操作。未 push、未提 PR、未发布。
