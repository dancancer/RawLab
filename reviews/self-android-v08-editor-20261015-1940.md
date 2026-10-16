# Code Review: Android Batch Boundaries Final WIP

## Must-fix

(无)。最终修改中未发现仍可确认的 P1。

## Should-fix

(无)。本轮已确认的 P2 均已修复并定向复验；这不代表所有真机性能诊断已完成。

## Review Scope

- Mode: self，`feature/android-v08-editor` 本轮局部 WIP，不是整条功能分支的重新评审。
- Base/head: `20f63978a75834dd19b253a7fca1253435801094`。本轮未新建提交；相对该基线 committed diff 为空，staged diff 为空，检查 unstaged 和相关 untracked 源码、测试、脚本、配置及验证记录。
- 维度：GPU 模式传递和真实 backend、AUTO 回退、恢复/重试、预览及导出超时后的进程隔离、资源归属、并发和测试假阳性；另覆盖用户追加的保存反馈布局。
- 执行：主代理复核关键调用链，独立只读代理分工检查 JNI/CPU 原因、存储和崩溃边界、UI、最终 MissingLook 增量。没有额外 worktree、远端写入或自动评审服务。
- 最终可执行快照：`/tmp/rawlab-android-v08-56c3/boundaries/missing-look-final-source-sha256.txt`，132 个源码/配置/测试/脚本条目全部匹配。更早批处理计时对应各自冻结 APK，不冒充最终增量结果。
- 最终 APK：app `415cacb8a3dbaa0ddd0f0b5cbda3b12de55110a9cf6e4b5db984ecbba4f455b7`；test `763d1514a16d6f11db1f214c3261f1183452c34ec0c3071eaa3eabd401e5e7d4`。
- Hosted CI：NOT REACHED，遵守只做本地验证要求。样片、APK、截图、构建产物、设备 framework 和诊断日志均在 Git 范围外；原有三份评审报告保留。

## 逐项复查

1. **GPU 关闭的目标校验断言没有用空集合通过。** `BatchGpuModeInstrumentedTest.kt:44` 要求真实 processor 构造模式恰为 `[CPU]`；原单点错误接线已恢复。新建/恢复批处理使用编辑器模式，AUTO 仍允许 CPU-only RLOOK 回退，FORCE 必须失败且输出 sentinel 不变。
2. **实际导出 backend 没有被参考渲染冒充。** `NativeProcessor.kt:72` 以 -1 初始化输出，`:81-84` 检查 native 已写入；JNI 在原有 sessionsMutex 锁内读取本次 session backend 并写数组。`BatchExport.kt` 日志包含实际 job UUID，测试只接受 own PID 下该 UUID 的一条记录。没有硬编码成功值。
3. **已移除第二次 getter 锁竞争。** 最初 nativeLastBackend getter 可在文件完成、metadata 返回后等待另一真实 CPU preview；并发测试 RED 证明 export 未返回。最终输出数组不重新申请全局锁，GREEN 在第二 preview 仍 native-active 时 export 已返回 backend 0。并发探针若未达到争用条件明确失败，不伪装覆盖。
4. **SELECTING 不再被当作“没有任务”。** `BatchWorkflowInstrumentedTest.kt:74` 起单独跟踪 previewPending；`:163-167` 失败清理把它并入 active。active 先终止测试进程，不 close/delete native 正在使用的文件；wrapper 等待 owner 消失后才在新进程恢复。真实 90 秒超时和短失败探针分别记录，未混为一种证据。
5. **Look 导入只恢复明确归属的事务。** `LookLibrary.kt:74-98` 先登记 UUID marker，再 stage/validate/commit；`:128-159` 使用 canonical-root JVM monitor 和进程文件锁。损坏 registry、已提交 Look 和未知归属 legacy final 文件保留。跨进程等待、kill 后锁释放、单点去锁 RED/GREEN 均有证据。这里只保证进程死亡恢复，不声称断电 fsync 耐久性。
6. **更早的发布及删除窗口已覆盖。** cleanup 在 native validator 中记录 exact managed ID；pending 输出按 exact fixture 文件名登记，覆盖 MediaStore insert 后、checkpoint 前。重复清理移除 exact-ID orphan，保留独立同名 Look；fixture 和 job 两份输入仅在 owner 死后删除。
7. **新增发现的 MissingLook 漏传已修复。** `EditorViewModel.kt:121-125` 在真实 validation 前设置 `work.gpuMode`，只在 debug 构建观察本次 NativeFrame backend。`RestoredLookGpuModeTest.kt:42-70` 先确认 fixture 实际支持 GLES，再按 own-PID append-only cursor 要求 off=0/on=2。修复前 off 实际为 2；真机和 AVD 修复后均通过，不使用后续 session 探针替代首帧。
8. **新增测试自身的崩溃清理也已修复。** `RestoredLookGpuModeTest.kt:33-46,90-94` 把编辑记录和 PhotoStorage 随机 cache 放进已登记 fixture；`:62` 断言真实工作副本归属。正常路径清除 ViewModel、等待结构化协程和正在执行的 storage 操作；进程死亡路径由已有 dead-owner recovery 递归删除 exact fixture，不依赖未执行的 finally，也不猜测其他 cache 文件。
9. **语言和窗口前置条件没有造假。** cleanup 在语言规则前捕获原始 app locale，死 owner 后恢复；最终 AVD 实际 preview crash 恢复 `de`。Lenovo framework 强制语言改写的失败保留，未改生产语言策略来凑六语言通过。ForegroundTestRule 用 ExternalResource.before 阻止锁屏时继续跑 body；只给测试窗口加 KEEP_SCREEN_ON，不改全局息屏或绕过 PIN。
10. **保存反馈不再改变 dock 尺寸。** 状态移到照片 overlay，信息区按同次 Column 测量约束并可滚动；没有 onSizeChanged 反馈竞态。最终六语言、两种 viewport、两种字体、保存状态、触摸重试、滚动、草稿抑制和 null preview 均通过，另回归五个原有 canvas 手势用例。正常 Native 算法、质量和共享 C ABI 未改。

## 验证结果

- 最终 Gradle build/JVM/lint：通过。88 JVM tests，0 failures/errors/skips；lint 0 errors、32 条既有 warnings；8 个 arm64/x86_64 库和两个 APK 的 16 KB alignment 通过。
- AVD 冻结默认完整六用例及六次恢复：12 OK，wrapper 0。原尺寸 CPU 恢复导出 127010 ms，完整 UI 导出 124096 ms，均在原有 240 秒内完成，尺寸和独立参考像素断言通过。
- 最终 MissingLook 增量：真机和 AVD 各 off/on 两用例及两次恢复，4 OK、wrapper 0。refined RED 的 off=2、expected=0 仍记录为失败。
- 最终 UI 增量：保存反馈六语言矩阵 41.183 s，五个 canvas 回归和六次恢复通过，12 OK、wrapper 0；已查看当前窄/宽英文/德文代表截图。
- 真实 preview 自然超时：90096 ms，旧进程 5226 退出后新进程 5364 恢复。另一次真实 preview 崩溃从 7394 到 7496 恢复原始 locale `de`。这些 wrapper 均保留 exit 1，只有后续恢复通过。
- 两处 `240_000` 和原 `90_000` 等待值与基线一致。`git diff --check`、shell syntax 和源码 hash 复核通过；无临时错误接线、去锁或 getter mutation 留在最终实现。

## 超时归因与未验证项

- AVD 原尺寸 AUTO 在 SwiftShader/ANGLE 软件 GPU 上真实超过 240 秒；没有完成的 batch backend 返回值，后续 new/reference 未达。真机 Adreno 同类恢复/新建导出 105426/81955 ms，实际 backend 2 且 FORCE 像素一致。证据支持软件 GPU 吞吐瓶颈，不支持把它当作新的核心回归。
- 真机 CPU 完整 UI 在当前与独立 `20f6397` 基线分别 240064/240067 ms 超时。预览已先完成；单 row timed window 只做一次 final render，独立参考在计时后。CPU 样本持续单 worker 100%、wchan 0、高 native RSS，和既有 Android 大图六层 SWT 的单 stripe 路径一致。没有样本支持主要在全局锁等待。
- 但不能宣称真机硬上限：同设备恢复 CPU 230179 ms 已通过，UI retained native state、请求和系统状态有差异；最终安全锁屏阻止前台受控 current/baseline 对照。debuggerd/simpleperf 权限也阻止获得物理 native 函数级 profile。未绕过 root、PIN 或系统安全策略。该验证缺口不是已修复或“全绿”。
- Lenovo 真机六语言 literal guard 真实失败；最终 physical Chinese-only UI 因锁屏 NOT REACHED。六语言通过来自 API35 AVD，未冒充真机覆盖。

## 清理与建议

两套真机测试包的 owned gallery（含 pending）及 jobs 均为空；Look registry count=0。只卸载最初不存在的四个 isolated app/test 包、删除六个已观察的任务截图。原 app APK SHA 和版本/安装元数据不变，Sony-memory 包保留。测试 AVD、private ADB 5063/5065 已退出，USB 已回到共享 5037；共享 ADB PIDs 23749/51027 未变。

建议：代码修复可以保留为本地 WIP；性能结论保留上述范围，不延长等待来制造通过。初轮前台对照受安全锁屏阻塞，用户随后解锁后的补验见下节。本轮没有 commit、push、PR、远端评论、review 或 approval。

## 用户解锁后补验（2026-10-15）

本节更新上文关于前台 CPU、真机中文 UI 和真机 preview locale recovery 的 NOT REACHED 状态。可执行源码未改，132 项源文件 hash 仍一致；重新安装的是已校验包名及 SHA 的同一冻结 APK。没有重编译，也没有与 AVD 或 host build 并发运行性能用例。

- 基线 `20f6397`：前台保屏下真实超时 `240071 ms`，preview `5228 ms`，`phase=RUNNING`、`batchNativeProcess=true`。owner 5910 退出后 recovery 7232 通过，wrapper 1。
- 当前版本：前台保屏下真实超时 `240063 ms`，preview `5174 ms`，同样处于 batch native export。owner 8183 退出后 recovery 9235 通过，wrapper 1。
- 两侧中段及末段均 `showing=false`、屏幕 ON、AWAKE；各自隔离包持有测试窗口 SCREEN_BRIGHT_WAKE_LOCK。单 DefaultDispatch 工作线程约 96.2-100% CPU，editor native worker 空闲，采样 thermal status 均为 0。相同 ForegroundTestRule 源码逐字节一致。
- 这排除了安全锁屏/息屏是该 CPU 预算失败的必要原因。两次数字都是固定预算下的删失点，不是渲染完成耗时，不能据此说性能完全相同。结合此前 shared core/编译参数一致，证据支持基线已存在 CPU 预算问题；仍不证明硬件上限或精确 native 热点，也不排除超时点之后的较小吞吐差异。
- 真机中文保存反馈布局矩阵通过 `6.287 s`，随后 fresh recovery 通过，wrapper 0。未将它冒充 Lenovo 六语言通过。
- 真机 SELECTING + preview nativeProcess 故障探针从 owner 9603 到 recovery 9974；两份输入保留至旧进程退出，原始 app locale `de` 恢复并由 shell 独立读回，随后资源清理通过。故障调用仍失败，wrapper 1；这是短故障探针，不冒充自然 90 秒超时。
- 独立只读证据复核未发现新增可定位代码缺陷。函数级 native profile 仍缺失；没有通过 root、属性改写、质量降低或延长 240 秒来补齐。

证据目录：`/tmp/rawlab-android-v08-56c3/boundaries/unlocked/`，主要日志为 `baseline-cpu-wrapper.log`、`current-cpu-wrapper.log`、`chinese-ui-wrapper.log`、`preview-de-recovery-wrapper.log` 及两侧 window/power/top/thermal 快照。

本次补验只更新记录、计划和此补充评审。再次清理四个隔离包及六个任务截图；owned gallery/jobs 为空、wake locks 为 0，原 app APK/版本/安装元数据不变。private ADB 5063 已退出，USB 回到共享 5037，共享 PIDs 23749/51027 未变。没有 staging、commit、push、PR 或远端评审。
