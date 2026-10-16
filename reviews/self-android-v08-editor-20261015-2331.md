# Code Review: Android v0.8 Delivery

## Must-fix

无。此次交付复查确认的生产预览关闭竞态已修复。

## Should-fix

无未处理的已确认生产问题。SAF 清理 helper 的能力限制保留为未覆盖项，不冒充已验证。

## Scope

- 完整交付基线：`origin/development` 为 `6f0dcf09dde2a5fbb9685496d3bb9f4610a2406b`。
- `bac08d3` 包含用户确认一并交付的此前 Android WIP 和 CPU checker 修复，共 36 文件。
- `eb8fac81966de03677ec20de2ab8f1ba8895df7b` 无冲突接入上述 development；
  仅加入 68 个 Mac/iOS 目标分支文件，Android、共享 CMake 和 Android 使用的资源未改。
- 当前增量相对 `eb8fac8`：生产预览生命周期、两个既有测试的清理等待、五项新回归及记录。
- 一个独立只读 reviewer 覆盖此前未提交修改及关键调用链，结合已完成的 editor、GPU、
  清理、CPU 性能和 checker 专项复查；随后复核新生产修复。主线程复现、修复并执行验证。
- 77 文件原始 PR 范围以 Android v0.8 编辑器及相关修复为主，不把 target-only Mac/iOS
  变更算作本 PR 的实现；并非重跑其他平台全部验收。

## Finding and Resolution

原生产路径允许在 SELECTING 的效果预览尚未结束时关闭对话框、再退出批次。
Compose caller 取消并不终止同步 native 段，原 `discardDraftOrCompleted()` 会先删冻结输入。
先前的 `previewPending` 仅保护测试失败恢复，不能代替生产生命周期管理。

修复后的 `BatchExportModel.preview()` 在 model scope 中创建 async child，调用方只等待
结果。取消 caller 后 child 仍由 parent 跟踪，直至阻塞工作真正退出。parent 的 Job
原子管理 child 登记和取消，不使用可能被下一次预览覆盖的单一 previewJob 字段。

删除登记在 parent 完成回调中，不在已取消的 scope 中再 launch 清理；完成信号在删除
之后才发出。`EditorViewModel.closeBatch()` 等待该信号，再刷新未完成批次。关闭后的
新预览不会执行 factory。Deferred 保存的是 NativeFrame，不保存无人接收的 Bitmap。
PREPARING/RUNNING 的拒绝关闭/丢弃规则不变，也没有改变渲染参数、GPU 选择或等待时间。

两个既有测试立即 `discard()` 后断言 journal 不存在，现先等待清理信号，避免将生产
延迟删除误当作测试失败。它们的原有 240 秒预算及输出断言未改弱。

## Validation

- Lenovo TB320FC，隔离包 `com.rawlab.android.batchprobe56c3[.test]`，private ADB 5063。
- 修复前真实模型测试 3/3 失败：两个入口提前删除输入，以及关闭后仍进入 factory。
  ADB 命令退出 0 不被当作成功，JUnit 的 `FAILURES / 3 failures` 明确记录为 RED。
- 修复后 `BatchPreviewLifetimeTest` 5/5 通过，0.611 秒。两个 owner 分别释放，第一项结束
  后仍要求输入存在、清理未完成；最后一项结束后才确认删除。直接 close 保留输入，
  原始文件始终保留。文件读取次数及内容断言确保测试确实进入受控工作段。
- 这是不可中断 factory 段的生命周期测试，不声称实际进入 JNI、完成降噪或验证画质。
- 最终 Gradle gates 包括明确 `--rerun` 的 88 项 JVM、lint、Debug app/test APK 构建；
  Python 24 项、两 ABI checker、16 KB alignment 和 diff whitespace 检查通过。
- 独立增量复核确认生命周期修复，没有发现新的 P1/P2 生产回归。

## Evidence Boundaries

- CPU 画质/完整批处理性能记录仍属于原冻结 WIP/APK。原 212 项清单现在 206 项匹配，
  其余为两 Python、两生产文件及两既有测试的明确增量；新生命周期测试单独记录。
- 最后两条既有测试的 await 调整发生于五项 GREEN APK 之后，已编译检查，未重跑 SAF
  目录或完整工作流。GREEN 对应的五项测试和生产修复内容未再改变。
- `BatchTestCleanup` 目前是图库测试 helper，不支持把 DocumentsProvider URI 当作
  MediaStore 数字 ID。本次调用均为图库或无输出；已有 SAF DNG 测试自行维护
  `ownedOutputs`，不使用此 helper。未扩展 SAF 设备矩阵，不宣称通用输出清理覆盖。
- 没有重新进行全尺寸 CPU/GPU 性能、全部相机、低内存、Release 或 x86 runtime 实验。
  本地验证不等于 hosted CI；远端检查状态须以 PR 最终 head 的查询为准。

## Cleanup and Recommendation

测试后隔离包中的 batch journals 和 cache 为空。只移除本轮最初不存在的两个隔离包，
停止自己启动的 PID 85146/private ADB 5063，设备已回到共享 5037。共享 PIDs 23749/51027
未变，没有修改原应用数据、个人图库、锁屏设置，也没有提交样片、APK 或临时计时代码。

本地源码和验证允许进入 PR 交付。仅在最终 source/base、冲突、远端检查及新反馈均核对
完成后，按用户授权合入 development；不绕过保护规则，不在此报告预先宣称远端合并成功。
