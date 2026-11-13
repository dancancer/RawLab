<!--
活台账：由主评审 + 整改后复审 + 实际合并台账合成，随任务推进持续更新。
更新纪律（每次合入后必做）：
  1. 只改「状态」与「依据」两列；依据写成 `PR #NNN @ <commit>`，合入前写 `PR #NNN（待合入）`。
  2. 任何状态从「未修/部分修复」变成「已修（已合入）」时必须同时写清验证锚点：
     脚本/命令 + 断言名 + 撤掉修复后应红的位置。
  3. 文末「变更记录」追加一行：日期 · PR · 涉及编号 · 状态变化。
复核说明：独立复核请直接按「依据」列的命令与断言复跑，并撤掉对应修复确认变红——
本表的「已修」只以代码核实和红/绿证据为准，不以 PR 标题为准。
文档来源：codebase-review-2026-11-12.md、codebase-review-followup-2026-11-13.md、
architecture-review-2026-11-13.md。
路线、阶段、验收不变量与产品决策登记见 remediation-roadmap-2026-11-13.md；
本台账只负责「每条任务现在什么状态、依据是什么」。
-->

# RawLab 综合整改任务清单（两份评审 + 实际合并台账，2026-11-13）

- **代码基线**：`origin/development` @ `0cf4a88a`（PR #269）。本机工作区 HEAD 停在 `d05c8d7d`，所以全部代码核实都用 `git show 0cf4a88a:<path>` 和 `git grep … 0cf4a88a` 完成，没有读工作区文件。
- **输入**：主评审 `docs/architecture/codebase-review-2026-11-12.md`（下称“主”）；复审 `docs/architecture/codebase-review-followup-2026-11-13.md`（下称“复”，基线 `d05c8d7d`）；台账 PR #240–#269 和两条在飞工作。
- **行号**：表里写的行号都按 `0cf4a88a` 实测。`git diff --stat d05c8d7d 0cf4a88a` 只改了 58 个文件，**不在其中的文件，复审行号仍然有效**；这类引用标“文件未改，沿用复审”。主评审的行号（基线 `9c4f7801` 或 `191d8aba`）没有逐条重核的，标“沿用主评审”。
- **只读**：没有改任何受版本控制的文件，没有 git 写操作，没有构建，也没有跑测试。唯一跑过的东西是 `/tmp/lead-plan/cloexec.c`，一段核实 C-N3 的小程序。
- **负责人图例**：Core 核心、Mac、iOS、And(roid)、Win(dows)、CI、Apple（Mac 和 iOS 同一个 PR）、Shared；“主”指与协调者同一模型，“轻”指机械改动，可用轻量模型。

## A. 执行摘要

1. **完成度**：B 表共 178 行（两份文档全部主要发现、复审全部 N 项、S1–S6、台账在飞项，以及本次新发现 5 条）。其中已修 43、部分修复 10、进行中 2、需产品决策 7、未修 113、已复核不再成立 3。
2. 主评审第一批 14 个编号（§2.1 加上 §12 的 C2、C4、I5、R10、R11、R13 另算）：W1、C1、R1、W3、R2、A4、C3、X4 已修；A3、X1、I1、A2、W2 部分修复；M1 未修。§12 第一批里，C2、I5、R10、R11、R13 也仍未修。
3. 补充评审的 40 条主要发现：已修 25，进行中 1（M10），未修 14。复审新增的 61 条：只有 R-N1 由 #265 修复；C-N3、I-N9、R-N4 核实后不成立；其余都未动。
4. **安全项**：高严重度的 R1/R15/R-N1 已由 #265 关闭（`ci.yml:130-134`）。剩下的 fork 问题是 R16/R-N2“结果恒红”，属于可用性问题，不是代码执行敞口。
5. **本轮之后仍是高或中到高的未完成项共 5 行**：A1（Android 启动全量 SHA256）、I1 和 A2 的残留（存储回收）、C2/C6/C7（GLES 和 D3D11 未分块降噪）、C5。全部是性能或存储问题，没有安全类。
6. **最该先做的 8 项**：① 合入在飞的 M10＋场景向量（P0-01）；② 合入 Windows flaky 加固（P0-02）；③ R16＋L1，让 CI 结果可信（fork 恒红、AX 静默跳过）；④ M1、A3、I5：第一批里漏掉的三条小修复；⑤ S6：Windows 更新器矩阵测试，带上 W-N1、W-N2、W-N4、W-N6；⑥ Android 按场景向量移植 A17、A18 和白平衡、镜头占位规则，并修 A12；⑦ C-N4 写进契约，A-N1 补 volatile；⑧ C2/C6 接上分块色度降噪。
7. **与台账不符**：#267 没改任何 Android 文件，A12 仍未修；#250 也没改 Android，A17、A18 仍未修（主 §14.9 的映射错了）；复审 §4.2 说的“Windows 重置漏半条”在生产路径上已由 #255 修好。详见 E.3。

## B. 综合任务清单

排序：P0（本轮在飞）→ P1（下一轮优先）→ D（需产品决策）→ P2 → P3 → 完成（已修和已复核不再成立）。同一问题在两份文档里编号不同时合并成一行，编号列写作“甲 ＝ 乙”。

状态计数：未修 113、部分修复 10、进行中 2、需产品决策 7、已修（已合入） 43、已复核不再成立 3（共 178 行）。

| 序号 | 编号 | 标题 | 严重度 | 来源 | 平台 | 状态 | 依据（0cf4a88a 文件:行 / PR） | 建议负责人·模型 | 依赖或前置决策 | 验收要点 |
|---|---|---|---|---|---|---|---|---|---|---|
| P0-01 | M10 ＋ 14.8 行1–3（Mac/iOS） | 非 RAW 来源占位值：关掉 RAW 目标镜头、清零 RAW 降噪、白平衡改回相机 | 低到中（跨端规则） | 主 §14.6.2 M10、§14.6.1a、§14.3.3#6、§14.7.1a/c、§14.8 | Mac、iOS、Shared | 已修（已合入） | 0cf4a88a 仍是旧行为：`MacAdjustmentTransferWB.swift:140`、`MacAdjustmentTransferValues.swift:93,102-107,116-121`、`IOSAdjustmentTransferWB.swift:125`、`IOSAdjustmentTransferValues.swift:63-64,74-79,85-88`；`Shared/fixtures/` 尚无 `adjustment-transfer-scenarios-v1.json`；**PR #270（待合入）** 已改 Mac/iOS 两端并新增该夹具与 `scripts/ci/test_transfer_scenarios.py`；**#270 @ 7c883991** 已合入 | Apple·主 | 无；场景向量与契约文档是 Android/Windows 移植的前置 | JPEG 用“全部”和默认自定义范围粘到开镜头＋RAW 降噪＋自定义白平衡的 RAW，三项不变；`RawLabMac/tests/AdjustmentTransferTests.swift:568-570` 同步改；撤掉跳过逻辑后场景向量用例变红 |
| P0-02 | T-W1 | Windows `updateSdk` 中 `ControllerChecks.RuntimeSaveFailureRecovery` 偶发失败 | 低（CI 可信度） | 台账（两份文档均未列） | Windows | 已修（已合入） | `RawLabWindows/tests/updates-sdk/ControllerChecks.cs:42,524`；**PR #272（待合入）** 加测试专用串行 `SynchronizationContext` + 按待落盘目标状态注入；**#272 @ 5e5400cc** 已合入 | Win·主 | 无 | CI `pwsh ./scripts/ci/windows-models.ps1` 连续多次全绿；撤掉串行上下文能复现原竞态 |
| P1-01 | R16 ＝ R-N2 | fork PR 的 CI result 恒红；#265 后 macOS 也被跳过，红的范围更大 | 中（取决于是否接受外部 PR） | 主 §14.7.2 R16；复 §3.7 R-N2 | CI | 已修（已合入） | `scripts/ci/affected_platforms.py:91-97`（select 不看来源仓库）、`:163-173`（verify 要求已选平台结果为 success）；`.github/workflows/ci.yml:130-134`（macOS 新增来源门禁，job 会被 skip）；**PR #273（待合入）** 让 select 对外部 PR 剔除 `SELF_HOSTED_ONLY` 并在 reason 说明；**#273 @ 992be9d5** 已合入；复审补充发现：`windows` 作业的源门禁连托管路由也拦 fork（selector 期望 success、作业被 skip，选中 Windows 的 fork PR 恒红），缺口由 **PR #281 @ 508f8f49** 关闭（已合入，carbon 评审 approve） | CI·轻 | Q2（裁定：接受） | `test_affected_platforms.py` 加 fork 事件样例：select 对自托管平台输出 false，或 verify 把“因来源被拦”判为可接受的 skipped 并在汇总里写明未验证；删掉这段逻辑后用例变红 |
| P1-02 | L1（本次新发现） | #269 在 AX 未授权时打印 SKIP 后直接 return：CI 上这个 UI 断言可能一直空跑却显示通过 | 低到中 | 本次核实（两份文档未覆盖） | Mac、CI | 已修 | `RawLabMac/tests/HDRRenditionUITests.swift:79-81`（`guard AXIsProcessTrusted() else { print("SKIP…"); return }`）；该脚本在 CI 模型套件里：`scripts/ci/apple-models.sh:12`；**PR #271（待合入）** 加 `RAWLAB_REQUIRE_AX`；**#271 @ 6e12fd66** 已合入；**#280 @ 83381e8e**（carbon 复审 approve）以 `hdr-rendition-reset.sh`（无 AX 依赖的表示层断言，穿透真实 `NSButton` 的 `isEnabled`/`performClick`）替换 CI 模型套件里的 AX 套件，ci.md 记录门禁口径（Q14 根治，已合入） | CI·轻 | 无 | **实测结论：自托管 macOS runner 没有辅助功能授权**，这条 UI 断言在 CI 上从未真正执行。PR #271 改为打印 `::warning::` 注解（CI 可见）并保留 `RAWLAB_REQUIRE_AX` 开关；真正覆盖需改成不依赖 AX 的表示层断言，见后续任务 |
| P1-03 | M1 | Mac 带增益图的 HDR 照片，画面取色始终报“预览已变化” | 中 | 主 §5 M1（第一批第 5 位）；复 §2.2、§4.2 | Mac | 已修（已合入） | `EditorModel+HSLTarget.swift:15` 构造比较值时用 `MacReferenceSource($0, raster:)`，没带 `hdrFingerprint`；其他构造点带了（`EditorModel+HDR.swift:6`、`EditorModel+Workflow.swift:498`）；`git log 9c4f7801..0cf4a88a` 这个文件 0 提交；**#276 @ 57dbea99** 已合入 | Mac·主 | 无 | 模型测试：带增益图的 HDR 源加上已接受的请求，`beginHSLTarget` 之后 `hslTargetNotice != .stale`；撤修复变红 |
| P1-04 | A3 | Android HDR 外观导入期间修订号一变，operation 停在 IMPORT_LOOK，返回键无效 | 中 | 主 §7 A3（第一批第 4 位）；复 §2.2、§4.2 | Android | 已修（已合入） | `EditorViewModel.kt:769` 修订号不一致时 `return@launch`，不复位 operation；`EditorScreen.kt:249-250` 没有处理 IMPORT_LOOK 的 BackHandler；**#274 @ d5d62af7** 已合入 | And·主 | 无 | 单测：applyHDRLook 进行中把 editRevision 加 1，operation 回到 NONE；Compose 测试按返回键能退出忙状态；撤修复变红 |
| P1-05 | I5 | iOS HDR 预览每一帧都无条件改写提示消息 | 中 | 主 §6 I5（第一批）；两份文档的台账都没跟踪 | iOS | 已修（已合入） | `RawEditorViewModel+Rendering.swift:188`：每帧执行 `self.statusMessage = hdr.missingResourceMessage`；**#275 @ 77297393** 已合入 | iOS·轻 | 无 | 模型测试：先设“已保存到照片。”，再交付一帧资源齐全的 HDR 预览，消息仍在；缺失警告只在状态变化时出现一次 |
| P1-06 | W2 ＝ W-N1 | Windows 下载、校验或中断类失败后永久不再自动检查，跨重启保留，主窗口无提示 | 中 | 主 §8 W2；复 §3.6 W-N1、§4.2 | Windows | 部分修复 | `DesktopUpdateController.cs:176`（Failed 且 Stage≠Checking 一律跳过）、`:266-267`（自动补查只认 Checking 或 trust_temporary）；`UpdateState.cs:110`（RestoreAfterLaunch 原样保留 Failed） | Win·主 | S6 矩阵测试先行 | 矩阵用例：Downloading 阶段失败并重启，退避期过后自动检查恢复，主窗口有提示；撤修复变红 |
| P1-07 | W-N2 | Windows gate 定时器在“有更新＋退出时安装”状态下每秒查一次更新源 | 中 | 复 §3.6 W-N2 | Windows | 未修 | `DesktopUpdateController.cs:261-264`（`CheckAsync(true)` 绕过每日节流）；`MainWindow/SoftwareUpdates.cs:14`（1 秒定时器） | Win·主 | 与 W-N1 同一个 PR（S6） | 假时钟推进 60 秒，适配器 check 最多调用 1 次（成功路径也要节流） |
| P1-08 | W-N4 | 五处同类原子写各写各的，只有一处有共享冲突重试 | 低 | 复 §3.6 W-N4、§5.6 | Windows | 未修 | `UpdateChecker.cs:94-109`、`LookLibrary.cs:373-391`、`FileLibrary.cs:175`、`EditedPhotoPreviewCache.cs:58-67`（这些文件在 d05c8d7d 之后没改，沿用复审行号） | Win·轻 | 放进 S6 的 PR | 统一成一个带重试的 helper；注入一次 HResult 32 的 IOException 后写入仍成功 |
| P1-09 | W-N6 | state.json 结构校验偏严，回滚到旧版会触发“存储修复”门禁 | 低（待验证） | 复 §3.6 W-N6 | Windows | 未修 | `UpdateStore.cs:52-67`（文件未改，沿用复审行号） | Win·主 | Q13（回滚兼容策略） | 矩阵用例：新版写入旧版不认识的 Phase，旧版读取时不锁编辑区 |
| P1-10 | A17 | Android 带配方的普通照片粘到 HDR，不按配方强度换算 | 中 | 主 §14.4.1 A17；主 §14.9 把它误配到 #250 | Android | 未修 | #250 没改任何 Android 文件（`git diff --stat 6b5e7783^1 6b5e7783`）；`AdjustmentTransfer.kt:220-243` 的 prepareHDR 直接写入数值 | And·主 | 阶段 1 的场景向量 | 读共享场景向量里的 HDR 配方用例：强度 50% 时写入值按 Shared/HDRAdjustmentTransfer.swift:107 的公式换算；撤修复变红 |
| P1-11 | A18 ＋ Android 白平衡与镜头占位 | Android 普通图片来源粘到 RAW：曝光基准改成 sensor、白平衡改回相机、镜头被覆盖 | 中 | 主 §14.4.1 A18、§14.7.1a、§14.8 行1–2 | Android | 未修 | `AdjustmentTransfer.kt:131-134`（不判断 source.isRaw）、`AdjustmentTransferWB.kt:26`、`AdjustmentTransferValues.kt:95-98,132-137`；**#283 已把 9 条真实分歧棘轮登记**（`knownScenarioDivergences`，键集含 `value:`/`changed:` 覆盖曝光基准·白平衡·镜头，修复后清空必红） | And·主 | 阶段 1 的场景向量和规则文档 | 在 Android 上跑共享场景向量，曝光基准、白平衡、镜头三类用例全过（#283 起为棘轮例外，非红灯） |
| P1-12 | 14.8-W 镜头 | Windows 普通图片来源用“全部”粘到 RAW，镜头校正被关掉 | 低到中 | 主 §14.7.1a、§14.8 行2 | Windows | 未修 | `AdjustmentTransferValues.cs:78-80`（复制时写默认值）、`:110-118`（粘贴时覆盖）；#255 只修了曝光基准和白平衡（`AdjustmentTransfer.cs:116`、`AdjustmentTransferWB.cs:68`）；**#283 已把 6 条真实分歧棘轮登记**（`KnownScenarioDivergences`，键集=`changed:` 镜头字段，修复后键集清空必红） | Win·主 | 阶段 1 的场景向量 | Windows 跑共享场景向量的镜头用例（#283 起为棘轮例外，非红灯） |
| P1-13 | C-N4 ＋ C-N5（S5） | 取消回调会被内部线程池并发调用，契约没写；FINAL 编码阶段没有取消检查点 | 中、低 | 复 §3.1 C-N4/C-N5、§5.5 | 核心，以及四端回调 | 已修（已合入） | **PR #278 @ 593b10d2**：`lutools/docs/processing-concurrency.md` 五问契约 + `sony2fuji_c.h` 回调并发性条款（注释级改动，ABI fixture 逐字节无差异）；JPEG `setjmp/longjmp`（stb 回调无返回值）+ 量化循环每 16384 px、PNG 每 65536 px、`rendered_dng` 预览与 16-bit 扫描线每 65536 px 的编码期检查点 | Core·主 | 无（文档部分） | 31MP（6200×5000）编码中取消实测 JPEG 0.94–1.03 ms、PNG 7.72–10.66 ms；`processing_cancellation_tests`；带/不带回调输出逐字节一致 |
| P1-14 | A-N1 | Android `EditorEditStore` 的 `store` 和 `adjustmentSession` 不是 volatile，跨线程读写 | 中 | 复 §3.5 A-N1 | Android | 未修 | `editor/storage/EditorEditStore.kt:34-35`（普通 var；复审写的路径少了 `storage/`）；`:40-42` reopen 会重建这两个引用 | And·主 | 无 | 两个引用合并进一个 AtomicReference 快照，或加 @Volatile；并发单测反复 reopen 和读取，不出现 NPE 或旧引用 |
| P1-15 | M2 ＝ M-N1 | Mac 缩略图刷新链每张缩略图至少全量解码记录 4 遍，多路刷新不合并 | 中 | 主 §5 M2；复 §3.3 M-N1、§4.2 | Mac | 部分修复 | `EditPersistence.swift:84`（init 无条件 `readRegistry()`）；`MacEditedPhotoPreviews.swift:615`；#240 已做缓存、去重、generation | Mac·主 | 建议先有 S1 的编辑记录 golden fixture | 计数探针：一次提交触发的 readRegistry 次数不超过可见缩略图数＋1；撤修复后计数回升 |
| P1-16 | M-N2 | Mac 每次构造预览计划指纹都整文件 SHA256 一遍 LUT 资源 | 中 | 复 §3.3 M-N2 | Mac | 未修 | `MacEditedPhotoPreviews.swift:66-69`（文件在 d05c8d7d 之后未改） | Mac·主 | 和 M2 同一个 PR（S3 第一段） | stat 指纹命中时 SHA256 调用 0 次；文件 mtime 或 size 变化后重新哈希 |
| P1-17 | M4 ＝ M-N6 ＋ M11 | Mac 批量预览、校验、导出共用一条串行队列且不可取消；粘贴预检不可取消，会叠加 | 中、低到中 | 主 §5 M4、§14.6.2 M11；复 §3.3 M-N6、§4.2 | Mac | 未修 | `BatchExportModel.swift:446-447`（AI prepare 传空的 progress 闭包，没挂取消）；M11 位置见主 §14.6.2 | Mac·主 | 无 | 连续触发两次预检，第一轮在当前目标结束后停止；start() 能中断正在跑的 AI 预览 |
| P1-18 | I-N1 | iOS 的重置挂起状态机已成死代码 | 中（可维护性） | 复 §3.4 I-N1 | iOS | 已修（已合入） | `ContentView.swift:119,410`、`EditorDrafts.swift:255,377,444-446`：`resetRestoreTool` 只剩置 nil 的赋值；**#275 @ 77297393** 已合入 | iOS·轻 | 无 | 删掉 `resetRestoreTool` 和相关的 3 个 onChange 后，`RawLab/tests/ios-reset-entry-ui.sh` 仍全绿 |
| P1-19 | I-N4 ＋ I-N5 ＋ I-N6 | iOS 相机：跳过集合不持久；字符串黑名单把瞬时错误判成单项失败；联机拍摄遇到张数上限仍整会话断开 | 中低 | 复 §3.4 I-N4/5/6 | iOS | 未修 | `IOSCameraController.swift:103,254-257`（内存数组）；`CameraWorkspaceBackend.swift:350`（isItemFailure）、`:144`（`where run.mode == .importing`） | iOS·主 | 无 | CameraSkipAndLimitTests 加 3 例：重启后跳过集合还在；“chunk size changed” 不标 failed；联机拍摄 photoLimit 时会话保持 |
| P1-20 | G-N2 ＋ G-N6 ＋ C-N9 | `set_ai_denoise` 首次失败后残留 enabled；直方图不核对 size_bytes；`ImageData::at()` 在 Release 下没有边界检查 | 低到中 | 复 §3.1 C-N9、§3.2 G-N2/G-N6 | 核心 | 未修 | `sony2fuji_c.cpp:1920-1938`（只有 `if (hadAI)` 时才回滚）、`:2968-2990`（不比较 size_bytes）；`common.h:32-39`（只有 assert） | Core·轻 | 无 | ctest：configure 抛错后 session 的 AI 为空或 enabled=false；stride×height 大于 size_bytes 时返回 INVALID_ARGUMENT |
| P1-21 | C2 ＋ C6 ＋ C7 | GLES 和 D3D11 没接分块色度降噪；D3D11 没有分块；渲染器出任何异常都整个重建，没有退避 | 中到高 | 主 §4 C2/C6/C7；复 §2.2、§4.2 | 核心（Android、Windows） | 未修 | `gles_photo.cpp:297`、`d3d11_photo.cpp:216` 仍调整图版 `applyChromaDenoise`；对照 `metal_photo.mm:1172`、`sony2fuji_c.cpp:2687` 用分块版 | Core·主 | Windows 硬件 GPU、Android 真机验收 | ctest 比较分块与整图结果逐像素一致；Android 真机记录 6100 万像素峰值内存下降 |
| P1-22 | S4 ＝ C-N7 ＋ G-N7 | ABI fixture 不含枚举，生成器硬断言 64 位，本地 ctest 不跑 | 中、低 | 复 §3.1 C-N7、§3.2 G-N7、§5.4 | 核心，以及四端绑定 | 已修（已合入） | **PR #279 @ de64c3f0**：fixture 保留 `version:1` 兼容（Windows 现有消费者硬断言）并新增 `fixture_version:2`；functions 95 + enums 23（103 值）入 `Shared/fixtures/abi-layout-v1.json`；生成器补 64 位断言；新增 ctest 用例 `abi_layout_fixture`（`scripts/ci/test_abi_layout.py`） | Core·轻 | 无 | 改动任一枚举中间取值或函数签名 → `ctest -R abi_layout_fixture` 与 Contracts 同时变红（三项红/绿记录在 #279 PR） |
| P1-23 | A12 | Android 相机断开重连后不认上次进度 | 中 | 主 §14.4.1 A12、§14.8；台账写的是 #267 覆盖 | Android | 未修 | #267 只改了 iOS 文件；`CameraIncrementalImport.kt:79,128,138` 仍按 sessionOwner 和 digest 判断；191d8aba 之后只有 #257 改过这块 | And·主 | Q7（是否照搬 iOS 三段抽样） | 假会话：上午导入后重连，已导入的照片不再整张下载；未完成的手动任务能继续，或者提示与实际行为一致 |
| P1-24 | S6 矩阵（Win，Mac 复用） | 更新器状态机两周 5 个补丁，缺 `Phase × Failure.Stage × 重启/回滚/杀进程` 的矩阵测试 | 中 | 复 §5.6 | Windows（Mac 可复用） | 未修 | `RawLabWindows/tests/updates-sdk/` 没有矩阵式用例；Mac 这边由 #268 又改了三处（`DesktopUpdateController.swift` +131 行） | Win·主 | 无 | 一张表驱动测试覆盖所有 Phase×Stage 组合，W-N1、W-N2 的场景在其中先红后绿 |
| P1-25 | A1 | Android 相机导入记录每次加载都重算全部历史照片的校验值，每次启动都触发 | 高 | 主 §7 A1；复 §4.2 | Android | 未修 | `CameraImportStore.kt:378-380`（validContent 每条整文件 contentDigest） | And·主 | 无；做完后并入 S3 的公共设施 | stat 指纹（size＋mtime）优先，内容哈希兜底；1000 条历史时冷启动不做整文件哈希（计数探针） |
| D-01 | C-N1 ＝ G-N8（＋C-N2） | 128M 像素帽把 NATIVE 一起拒，而且要等完整 RAW 解码后才报；JPEG 65535 单边限制只在编码器层报 | 中 | 复 §3.1 C-N1/C-N2、§3.2 G-N8、§6#4 | 核心，以及四端错误提示 | 评审通过（should-fix 收口中） | Q1=A 已落地（**PR #284**，分支 `fix/native-output-size-limit` @ f4b0587a，已 rebase 到 678c90e7）：`kMaxOutputPixels`=INT32_MAX（2.1G 像素溢出保护，`uint64` 乘法判溢，BUFFER 的 `uint32 stride_bytes` 同步保护）；NATIVE 解码前头部探测三态 `ProbeSizeResult{Probed,DeferredPostDecode,Unsupported}`（PNG IHDR、JPEG SOFn+Exif Orientation count==1、LibRaw `probeOutputSize` 计入 inset crop(3)、TIFF/BigTIFF IFD 兜底；JXL DNG 与 normal X3F 延后到解码后复核，避免未裁切 IFD 误拒）；JPEG 65535 单边限制上移到请求验证+解码前预检，`stb_image_write` 行偏移改 `size_t`，PNG 行偏移 `size_t`+分片 deflate；ABI 未改。本机全量 ctest 129/129（19 项样片 SKIP）。carbon 复审 **approve**（0 blocking / 3 should-fix / 3 note），正收口：DNG Classic TIFF 715.82M 容量上限前置为 `INVALID_ARGUMENT`、打开失败不污染探测缓存、800MP mmap 测试稳健化 | Core·主 | Q1（裁定：支持 >128MP） | 撤实现后 `color_contracts` 9 条 FAIL、恢复全绿；NATIVE 超限在 unpack/LUT 分配前拦截（不存在的 LUT 路径哨兵区分解码前/后发现）；NATIVE+缺失输入保持 IO_ERROR |
| D-02 | R17 | “RAW 降噪强度”在交换格式里各端用的字段不同（`raw_level` 和 `post_rgb`），互相拒收 | 低 | 主 §14.7.2 R17、§14.8 行4 | 四端 | 需产品决策 | Mac `MacAdjustmentTransferValues.swift:93-94,113-114`；iOS `IOSAdjustmentTransferValues.swift:63-64,84-86`；Android `AdjustmentTransferValues.kt:82,105`；Windows `AdjustmentTransferValues.cs:72,87` | 用户决策 → Apple·主 | Q3 | 字段目录写明两个键的含义；四端对同一条非 0 降噪向量给出同一种结果 |
| D-03 | 14.8 处理版本 | 粘贴时四端都不比较来源和目标的处理版本，也不提示 | 低到中 | 主 §14.6.1e、§14.3.3#4、§14.5.3#4、§14.7.1b | 四端 | 需产品决策 | `Shared/AdjustmentTransfer.swift:422` 只校验来源版本是否在 1–3；Android `AdjustmentTransfer.kt` 粘贴入口不比较 | 用户决策 | Q4 | 规则定下后进场景向量：v1 来源粘到 v3 目标的期望结果（提示、拒绝或沿用目标版本）四端一致 |
| D-04 | M3 | Mac 中性参考帧总按整幅原生分辨率渲染，不计入 512MB 预算 | 中 | 主 §5 M3；复 §4.2 | Mac | 需产品决策 | `EditorModel+Rendering.swift:142-146`（`edge: nil`） | 用户决策 → Mac·主 | Q8 | 决定保留后：参考帧计入预算或限制长边；6100 万像素原图开图时峰值内存下降（本机测量写进 PR） |
| D-05 | R7 | 暗角、颗粒等参数的精度分桌面和移动两派，小数值四端处理不同 | 低 | 主 §9 R7 | 四端 | 需产品决策 | 沿用主评审位置（未重核） | 用户决策 | Q3（与 R17 一起定） | 字段目录写明步长；共享向量加小数值用例，四端结果一致 |
| D-06 | R18 | 桌面端配方生成函数只有测试在调用，README 却描述了“复制配方” | 低 | 主 §14.7.2 R18 | Mac、Windows | 需产品决策 | 沿用主评审：`RawLabMac/Sources/Rendering/AgentRecipe.swift:5`、`RawLabWindows/AgentRecipe.cs:8`、`RawLabWindows/README.md:109` | 用户决策 | Q9 | 定位为测试工具：移进 tests 并改 README；定位为功能：补 Windows HDR 分支，两端产物都能通过 `validate_recipe` |
| D-07 | A-N3 | Android export 的 cancellationSignal 参数无调用方；迟到的取消会删掉已经完整渲染的文件 | 低 | 复 §3.5 A-N3、§5.5 | Android、核心 | 需产品决策 | `NativeProcessor.kt:188-200`（只有预览路径用这个信号）；导出侧沿用复审 `rawlab_jni.cpp:1548-1556` | 用户决策 → And·轻 | Q12 | 定下语义后：要么删掉这个死参数，要么提交点之后的取消保留文件并提示 |
| P2-01 | S1 编辑记录 golden fixture（含 X1 读侧） | 编辑记录在四端是四份独立实现，没有共享的一致性基线 | 中 | 复 §5.1；主 §3 X1（第 2、3 步） | 四端 | 部分修复 | 阶段 1 只新建了调整传输场景向量（进行中）；编辑记录本身没有共享 fixture；`lutools/docs/edit-json.md` 只覆盖 agent recipe | Shared·主 | 阶段 1 的向量格式 | 新建 `Shared/fixtures/edit-records-v1.json`（代表性记录×版本×迁移/重置×损坏样本）；四端各一个 conformance 测试进 CI 快速通道；改坏任一端的 reset 保留规则都会变红 |
| P2-02 | X2 ＝ S3 | 热路径反复整文件读取并算校验值，四端都没动 | 中 | 主 §3 X2；复 §5.3 | 四端 | 未修 | Mac 见 M-N1/M-N2，iOS 见 I-N2/I-N3，Android 见 A1，Windows 见 W6 | 各端·主 | S1 | 按 Mac 缩略图链、iOS 保存路径、Android 启动恢复的顺序分 3 个 PR，每个 PR 带调用次数探针 |
| P2-03 | X3 | 每次操作新建渲染引擎或会话，跟着重新解析镜头库、重新解码 RAW | 中 | 主 §3 X3 | 核心，以及四端 | 部分修复 | 核心已改为会话内惰性加载一次（`sony2fuji_c.cpp:181-186` `lens_database_tried`）；没有进程级缓存，客户端每次新建会话仍会重新解析 | Core·主 | 无 | 进程级 LensCorrectionDatabase 缓存；连续新建 10 个会话只解析 1 次 |
| P2-04 | I3 ＝ I-N2 | iOS 每次保存约 101 次整文件读；最近照片整体重载 | 中 | 主 §6 I3；复 §3.4 I-N2 | iOS | 未修 | `ContentView.swift:200`（每次提交都 `photoPreviews.reload`）；`IOSPhotoPreviews.swift:147-164`（文件未改） | iOS·主 | S1 | 提供“一次读取、批量取状态”的接口；一次提交的整文件读次数不超过 2 |
| P2-05 | I-N3 | iOS 缩略图渲染对同一张原图整文件 SHA-256 做 4–5 遍 | 中低 | 复 §3.4 I-N3 | iOS | 未修 | `IOSPhotoPreviews.swift:27-56,196-248`（文件未改） | iOS·主 | 与 I-N2 同一个 PR | 文件身份缓存命中时每张缩略图哈希不超过 1 次 |
| P2-06 | I1 | iOS 批量 DNG 输出和相机原件只增不减，没有清理入口 | 高 | 主 §6 I1；复 §4.2 | iOS | 部分修复 | #249 加了启动清理（`RawLabApp.swift` 的 init 调 `removeStaleImports`、`removeOrphanedJobDirectories`）；Documents/Exports 和相机原件仍没有删除入口；App 的 Info 里没有 UIFileSharingEnabled（只在测试脚本里出现） | iOS·主 | Q6 | 设置页显示占用并提供删除；删除前核对编辑记录和批量 journal 不再引用（测试证明不会删掉在用的文件） |
| P2-07 | A2 | Android 批量导出和系统分享在私有目录留下无法回收的大文件 | 高 | 主 §7 A2 | Android | 部分修复 | #247 `WorkingCopyCleanup.kt:53-77`（临时导出文件、LUT 预览目录、没有 journal 的任务目录）；#264 `SystemPhotoStore.kt:113-123`（手动清理系统相册副本）；`camera-tether-runs` 目录（`CameraImportViewModel.kt:137`）仍没有删除逻辑 | And·主 | Q6（联机记录保留策略） | 联机记录按条数或天数回收；测试证明进行中的联机记录不会被删 |
| P2-08 | C14 | 输出尺寸上限与 int 相乘 | 中到低 | 主 §4 C14；复 §4.1/§4.2 | 核心 | 部分修复 | 128M 帽（`sony2fuji_c.cpp:511-515`）和 size_t 化（`common.h:27-30`）已落地；残留问题见 C-N1、C-N2、C-N9 | Core | C-N1 的决策 | 见 C-N1、C-N9 两行 |
| P2-09 | G-N1 | Force 模式的错误码在不同路径上不一致：会话路径返回 UNSUPPORTED，独立 LUT 和 rlook 返回 PROCESSING_ERROR | 中 | 复 §3.2 G-N1 | 核心，以及四端提示 | 未修 | `lut_gpu.cpp:88`（Force 返回 ProcessingError）；#254 只改了 photo_color、photo_effects 两组测试的期望 | Core·主 | 检查四端怎么处理 UNSUPPORTED | 独立 LUT 在 Force 且没有后端时返回 UNSUPPORTED；四端都弹“强制 GPU 不可用” |
| P2-10 | C29 | GLES 着色器缺“sRGB 输入 LUT”分支，Android 上这类 LUT 永远走 CPU | 低到中 | 主 §14.2.1 C29；主 §14.9 写的是“#254 可能部分” | 核心（Android） | 未修 | `gles_photo.cpp:261`（`inputTransfer()==SRGB` 直接 return false）；#254 只改了测试期望 | Core·主 | Android 真机（没有 GLES 像素测试，见 C26） | 真机上用 sRGB 输入 LUT 比较 GPU 和 CPU 像素；Force 不再返回处理错误 |
| P2-11 | C26 | GLES 照片管线在核心 ctest 里没有像素级测试 | 中 | 主 §14.1.1 C26 | 核心 | 未修 | 沿用主评审（真机 GLES 测试返回 77 跳过，复审 §4.1 C4 行） | Core·主 | Android 真机或 SwiftShader 类软件 GLES | CI 上能跑的 GLES 像素比对用例，删掉任一着色器分支会变红 |
| P2-12 | C5 | GPU 非关闭时，独立 LUT 分支整图处理，多 2 到 3 份整幅浮点拷贝 | 中到高 | 主 §4 C5 | 核心 | 未修 | 沿用主评审（未逐行重核） | Core·主 | 无 | 分块处理；峰值内存测量写进 PR |
| P2-13 | C8 | CPU 非视口预览会移走大图的 RAW 缓存，下一次渲染整幅重解码 | 中 | 主 §4 C8 | 核心 | 未修 | 沿用主评审（未重核） | Core·主 | 无 | 预览后的导出不再重解码（解码计数探针） |
| P2-14 | C9 | CPU 管线里好几个整图阶段实际是单线程 | 中 | 主 §4 C9 | 核心 | 未修 | 沿用主评审（未重核） | Core·主 | 先测基线 | 改成 parallel_for 后结果逐位一致，耗时写进 PR |
| P2-15 | C10 | 降噪和两个 GPU 后端内部没有取消检查点 | 中 | 主 §4 C10；主 §14.0 说仍存在 | 核心 | 未修 | 沿用主评审 | Core·主 | 与 C-N5 一起（S5） | 长降噪过程中取消，在 1 秒内返回 CANCELLED |
| P2-16 | 预设库与外观库逐条容错（Mac、iOS、Android） | 预设库或外观库有一条读不懂，整个库都不可用 | 低到中 | 主 §14.6.1g、§14.4.2 X1 补充、§14.8 行9；M9 整改方向里的“根本做法” | Mac、iOS、Android | 未修 | `Shared/AdjustmentPresetStore.swift:170-180`（整份严格解码）；`Shared/LookLibrary.swift:236`（readLooks 整份校验）；`RawLabAndroid/…/presets/AdjustmentPresetStore.kt:108-130`；Windows 已由 #251 改好（`AdjustmentPresetChecks.cs:177`） | Apple·主＋And·主 | 参照 Windows 的 `ListUnreadable` 语义 | 用共享 fixture 里一条坏预设：列表只少这一条，坏条目原样保留，并且可以删除 |
| P2-17 | A-N2 | Android 导出持有全局 `sessionsMutex`，批量导出期间编辑器预览被阻塞 | 中 | 复 §3.5 A-N2 | Android | 未修 | `rawlab_jni.cpp:1469-1470`、`NativeProcessor.kt:476-482`（沿用复审行号） | And·主 | 无 | 批量导出时预览的等待时间有上限（锁改成按会话粒度）；测试里两个会话的调用可以并发 |
| P2-18 | W-N3 | Windows 预览失败的白名单两层都没接住时，走模态兜底，默认退出 | 低到中 | 复 §3.6 W-N3 | Windows | 未修 | `MainWindow/Rendering.cs:98`、`RenderEngine.cs:648`（文件未改） | Win·主 | 无 | 预览路径抛 OverflowException 时只降级显示，不弹退出对话框 |
| P2-19 | W6 | Windows 界面线程的高频路径里有同步文件读取，LayoutUpdated 上挂了全局回调 | 中 | 主 §8 W6 | Windows | 未修 | 沿用主评审 | Win·主 | S3 | 界面线程的文件 IO 计数为 0（探针） |
| P2-20 | W14 | Windows 批量窗口每次刷新都重建全部行、重新解码全部缩略图 | 中 | 主 §14.5.1 W14 | Windows | 未修 | 主 §14.9 列为没有对应 PR；之后也没有相关提交 | Win·主 | 无 | 刷新只更新变化的行；缩略图解码次数等于新增行数 |
| P2-21 | W16 | Windows 拖动滑杆时每一格都整面刷新检查器，并在界面线程打开原片 | 中 | 主 §14.5.1 W16 | Windows | 未修 | 同上 | Win·主 | S3 | 拖动过程中界面线程不打开文件（探针） |
| P2-22 | I12 | iOS 相机导入清单每存一张照片就整份重写约 4 次 | 中 | 主 §14.3.1 I12 | iOS | 未修 | 主 §14.9 列为没有对应 PR；#267 在同一文件新增抽样逻辑，但没有改写入次数 | iOS·主 | 无 | 每张照片最多写 1 次清单（计数探针） |
| P2-23 | R3 | 调整参数的范围、默认值、步长没有单一来源，共享向量只覆盖少数字段 | 中 | 主 §9 R3、§14.7.3 | 四端 | 未修 | `Shared/fixtures/adjustment-transfer-v1.json` 仍是 80 条、没有 HDR 向量（主 §14.7.3）；阶段 1 的场景向量只补一部分 | Shared·主 | S1 | 字段目录生成各端常量，或者有一致性测试；新增字段不进目录时 CI 变红 |
| P2-24 | R6 | Windows 原生门禁按允许名单挑核心测试，新测试默认不在 Windows 上跑 | 中 | 主 §9 R6；复 §4.2 | CI、Windows | 未修 | 沿用复审（23 个测试名没有对账） | CI·轻 | 无 | 对账脚本：ctest 列表减去允许名单再减去“已知不适用”名单为空，否则 Contracts 失败 |
| P2-25 | I2 | iOS 导出 RAW 前为了取尺寸多做一次完整解包，桥接层绕过共享 C 接口 | 中 | 主 §6 I2 | iOS | 未修 | 沿用主评审 | iOS·主 | 无 | 导出时解包计数为 1 |
| P2-26 | I17 | iOS 打开非“曝光”工具时，从顶部菜单复制、粘贴、看历史会被“有未完成草稿”挡住 | 中 | 主 §14.3.1 I17 | iOS | 未修 | 主 §14.9：需要先在真机验证 | iOS·主 | 先在真机复现 | UI 测试：打开 HSL 工具后，菜单里的复制可用 |
| P3-01 | C-N6 | preserveDestinationMode 是 stat 加 fchmod 的 TOCTOU，而且跟随 symlink | 低 | 复 §3.1 C-N6 | 核心 | 未修 | `src/core/output_file_mode.h:23-27`（沿用复审） | Core·轻 | 无 | 改用 fstat 加 fchmod（对 fd 操作）；目标是 symlink 时不改链接目标的权限 |
| P3-02 | C-N8 （X4 的 Windows 残留） | Windows staging 分支没跟 POSIX 一起改 | 低 | 复 §3.1 C-N8 | 核心（Windows） | 未修 | `raw_processor.cpp:965-969`（`GetTempFileNameW`＋`_wfopen`） | Core·主 | Windows 环境 | Windows 上 O_EXCL 语义等价（`CREATE_NEW` 加重试）；foreign-name 保护测试在 Windows 上通过 |
| P3-03 | C-N10 | ProcessingCancelled 经 ImageEncoder 的返回值漏到 C++ 调用方 | 低 | 复 §3.1 C-N10 | 核心 | 未修 | 沿用复审 `raw_processor.cpp:1176-1177,1282-1283` | Core·轻 | 无 | ErrorCode 增加 Cancelled，或在编码器边界转换；grep 确认没有绕过 FFI 直接调编码器的地方 |
| P3-04 | G-N3 | Metal 和 GLES 独立 LUT 上下文初始化失败后被永久缓存 | 低 | 复 §3.2 G-N3 | 核心 | 未修 | 沿用复审 `metal_lut.mm:39-67`、`gles_lut.cpp:219-223` | Core·轻 | 无 | 瞬时失败后可以按退避重试 |
| P3-05 | G-N4 | 三处 EGL Binding RAII 的恢复顺序有问题 | 低 | 复 §3.2 G-N4 | 核心（Android） | 未修 | `gles_lut.cpp:110`（Binding 结构）等三处 | Core·轻 | 无 | 先恢复 API 再恢复 context；stub 测试覆盖“当前线程是另一种 client API”的分支 |
| P3-06 | G-N5 | metal_stats 的 catch 收窄后留下逃逸窗口 | 低 | 复 §3.2 G-N5 | 核心（Apple） | 未修 | 沿用复审 `metal_stats.mm:240-262` | Core·轻 | 无 | 恢复 catch(...) 兜底 |
| P3-07 | G-N9 | `applyLutMetal` 用 uint32 记像素数，超过 4G 像素时截断 | 低 | 复 §3.2 G-N9 | 核心 | 未修 | 沿用复审 `metal_lut.mm:168` | Core·轻 | 无 | 内部入口在超过 UINT32_MAX 时拒绝 |
| P3-08 | G-N10 | X3F bridge 的 panic 载荷被丢弃 | 低 | 复 §3.2 G-N10 | 核心 | 未修 | 沿用复审 `x3f-bridge/src/lib.rs:220-222` | Core·轻 | 无 | panic 信息透传到错误文本 |
| P3-09 | M-N3 | Mac“已编辑”判定有两套 raster 分类 | 低到中 | 复 §3.3 M-N3 | Mac | 未修 | 沿用复审 `EditPersistence.swift:326-338` 与 `MacEditedPhotoPreviews.swift:16-21` | Mac·轻 | 无 | 统一用 `RenderEngine.isRasterInput`；TIFF、HEIC 用例两条路径结果一致 |
| P3-10 | M-N4 | Mac 外观变更时主线程逐条解析全部记录，坏记录被 try? 静默跳过 | 低到中 | 复 §3.3 M-N4 | Mac | 未修 | 沿用复审 | Mac·主 | S3 | 放到后台；坏记录在日志里可见 |
| P3-11 | M-N5 | Mac 批量列表首帧在主线程同步读记录、探测 RAW | 低到中 | 复 §3.3 M-N5 | Mac | 未修 | 沿用复审 `BatchExportModel.swift:140-147` | Mac·主 | 无 | 移到后台；探测失败有可见状态 |
| P3-12 | M-N7 | Mac 的 journal“未来版本”判断在多处写死了版本上限 | 低 | 复 §3.3 M-N7 | Mac | 未修 | 沿用复审 `BatchExport.swift:331-377`（文件未改） | Mac·轻 | 无 | 集中成一份版本清单；枚举加一项时测试提示更新清单 |
| P3-13 | M-N8 | Mac 提交编辑时主线程同步整文件读改写 | 低到中 | 复 §3.3 M-N8 | Mac | 未修 | 沿用复审 | Mac·主 | S1、S3 | 后台写入；1 万条记录时提交耗时测量写进 PR |
| P3-14 | M-N9 | Mac 文件换代窗口内，旧字节的解码结果仍回给等待者 | 低 | 复 §3.3 M-N9 | Mac | 未修 | 沿用复审 `FileLibrary.swift:601-625` | Mac·轻 | 无 | revision 不一致时丢弃结果 |
| P3-15 | M-N10 | Mac 预览磁盘缓存每次写入都全目录扫描做 LRU | 低 | 复 §3.3 M-N10 | Mac、iOS（Shared） | 未修 | 沿用复审 `Shared/EditedPhotoPreviewCache.swift:43-72` | Apple·轻 | 无 | 维护内存索引；写入时不做目录级 IO |
| P3-16 | M-N11 | Mac 缩略图 worker 是单个串行 actor，一次 AI prepare 会阻塞所有缩略图 | 低（有意） | 复 §3.3 M-N11 | Mac | 未修 | 沿用复审 | Mac·轻 | 无 | 加进度提示 |
| P3-17 | M5 | Mac 构建脚本：非发布构建不清理旧包，依赖本机 SDK 路径 | 低到中 | 主 §5 M5 | Mac | 未修 | 沿用主评审 | Mac·轻 | 无 | 在干净 checkout（没有 .git）下构建通过 |
| P3-18 | M6 | Mac 测试脚本的组织方式与盲区 | 低到中 | 主 §5 M6 | Mac | 未修 | 沿用主评审 | Mac·轻 | R14 | 见 R14 |
| P3-19 | I-N7 | iOS `.atomic` 写崩溃后残留的 edits.json 临时副本没人清理 | 低 | 复 §3.4 I-N7 | iOS | 未修 | 沿用复审 `EditPersistence.swift:159` | iOS·轻 | 无 | 启动清理覆盖 Application Support/RawLab/Edits 目录下的临时文件 |
| P3-20 | I7 ＝ I-N8 | iOS ContentView 是单体视图（110 个 @State） | 中 | 主 §6 I7；复 §3.4 I-N8 | iOS | 未修 | `git show 0cf4a88a:RawLab/RawLab/UI/Editor/ContentView.swift \| grep -c @State` 结果是 110 | iOS·主 | S2 | 按状态拆子视图，每个 PR 减少的 @State 数写进 PR |
| P3-21 | I8 | iOS HDR 画布在主线程逐像素色调映射，空闲时也以 30fps 提交 | 中偏低 | 主 §6 I8；复 §4.2 | iOS | 未修 | 沿用复审 `HDRPresentation.swift:50-70`、`HDRCanvas.swift:122` | iOS·主 | 无 | 空闲时帧率为 0；色调映射移出主线程 |
| P3-22 | I4 | iOS RAW 导入时重复解码；被取消的导入仍跑完全程 | 中 | 主 §6 I4 | iOS | 未修 | 沿用主评审 | iOS·主 | 无 | 取消后 1 秒内停止 |
| P3-23 | I6 | iOS 相机导入记录每个缩略图都整文件校验，并占着相机命令队列 | 中 | 主 §6 I6 | iOS | 未修 | 沿用主评审 | iOS·主 | S3 | 缩略图路径不做整文件校验 |
| P3-24 | I9 | iOS 普通图片整幅解码后常驻内存，导出时再解一份 | 中偏低 | 主 §6 I9、§14.3.2 | iOS | 未修 | 主 §14.3.2 已核实仍在 | iOS·主 | 无 | 导出复用 draftBuffer |
| P3-25 | I10 | iOS 调整粘贴预检对每个目标整幅解码 | 低到中 | 主 §6 I10 | iOS | 未修 | 沿用主评审 | iOS·主 | 无 | 预检只读元数据 |
| P3-26 | I11 | iOS 死代码和留在正式代码里的测试开关 | 低 | 主 §6 I11 | iOS | 未修 | 沿用主评审 | iOS·轻 | 无 | grep 找不到测试开关 |
| P3-27 | A-N4 | Android `openSaved`、`openTetherSaved` 提前 return 时不复位 preparing | 低 | 复 §3.5 A-N4 | Android | 未修 | 沿用复审 `CameraImportViewModel.kt:615,173-179` | And·轻 | 无 | 出异常后 preparing 变为 false |
| P3-28 | A-N5 | Android `preview()` 在 IO 线程读主线程上的可变字段 `assets` | 低 | 复 §3.5 A-N5 | Android | 未修 | 沿用复审 `CameraImportViewModel.kt:247` | And·轻 | 无 | 改成 @Volatile 或快照传参 |
| P3-29 | A-N6 | Android 启动清理在主线程全量扫目录、读所有批量 journal | 低 | 复 §3.5 A-N6 | Android | 未修 | `WorkingCopyCleanup.kt:53-87`（#247 之后扫描范围更大了） | And·轻 | 无 | 移到后台线程；冷启动主线程不做目录扫描 |
| P3-30 | A-N7 | Android BatchExportModel 的 journal 操作是主线程同步磁盘 IO | 低 | 复 §3.5 A-N7 | Android | 未修 | 沿用复审 `BatchExportModel.kt:374-407` | And·轻 | 无 | 移到 Dispatchers.IO |
| P3-31 | A-N8 | Android 主线程 SharedPreferences `.commit()`，VM 构造期间 4 次 getSharedPreferences | 低 | 复 §3.5 A-N8 | Android | 未修 | 沿用复审 `EditorViewModel.kt:209-311` | And·轻 | 无 | 改成 apply()，并延迟初始化 |
| P3-32 | A-N9 | Android releaseStorage 用“恰好 6 次”的魔数 | 低 | 复 §3.5 A-N9 | Android | 未修 | `EditorViewModel.kt:2001` `if (releases == 6)` | And·轻 | 无 | 改成按清单计数；多触发一次或少触发一次都有测试覆盖 |
| P3-33 | A-N10 | Android `EditorAdjustmentHistory.begin()` 在已有 interaction 时不校验身份就返回 SAVED | 低 | 复 §3.5 A-N10 | Android | 未修 | 沿用复审 `EditorAdjustmentHistory.kt:134` | And·主 | 无 | 换图后的第一次编辑不会拿到假的 SAVED |
| P3-34 | S2 | 热点文件和上帝对象：改动最频繁的文件恰好是最大的文件 | 中 | 复 §5.2 | Android、核心、iOS | 未修 | `EditorViewModel.kt` 2004 行、`sony2fuji_c.cpp` 3106 行、ContentView 110 个 @State（`wc -l` 与 `grep -c` 在 0cf4a88a 上实测） | 各端·主 | 无 | 每次碰这些文件顺手拆出一块职责；不单独排大重构 |
| P3-35 | A5 | Android 多文件流程重复做整文件复制、校验和完整解码，缺空间预检 | 中 | 主 §7 A5 | Android | 未修 | 沿用主评审 | And·主 | S3 | 先做空间预检 |
| P3-36 | A6 | Android 预览像素从核心到屏幕要拷 3 次 | 中 | 主 §7 A6 | Android | 未修 | 沿用主评审 | And·主 | 无 | 拷贝次数降到 2 以下 |
| P3-37 | A7 | Android 正式包没开代码压缩，却引入完整的扩展图标库 | 中 | 主 §7 A7 | Android | 未修 | 沿用主评审 | And·轻 | 无 | R8 开启后 APK 体积下降，UI 测试通过 |
| P3-38 | A8 | Android 相册里已编辑照片的缩略图复用编辑器渲染器 | 低 | 主 §7 A8 | Android | 未修 | 沿用主评审 | And·轻 | 无 | 缩略图不渲染参考图 |
| P3-39 | A9 | Android 蓝牙一断就判整次连接失败；开启 Wi-Fi 阶段没有超时 | 低 | 主 §7 A9 | Android | 未修 | 沿用主评审 | And·轻 | 真机 | 分阶段判断加超时 |
| P3-40 | A20 | Android 每次列外观都把导入的 LUT 全部校验一遍 | 低到中 | 主 §14.4.1 A20 | Android | 未修 | 主 §14.9 列为没有对应 PR | And·主 | S3 | 列外观时不做整文件校验 |
| P3-41 | W5 | Windows HDR 预览每帧在托管层做多遍逐像素标量转换 | 中 | 主 §8 W5 | Windows | 未修 | 沿用主评审 | Win·主 | 无 | SIMD 化或移到 GPU，耗时测量写进 PR |
| P3-42 | W8 | Windows `HDRSourceCache` 在全局锁里解码 | 低 | 主 §8 W8 | Windows | 未修 | 沿用主评审 | Win·轻 | 无 | 解码移到锁外 |
| P3-43 | W9 | Windows 主预览没用上已有的协作取消；取消状态码处理不一致 | 低 | 主 §8 W9 | Windows | 未修 | 沿用主评审 | Win·主 | S5 | 预览能被取消 |
| P3-44 | W-N5 | Windows 编辑和更新状态的保存会在 UI 线程同步阻塞，最长约 5 秒 | 低 | 复 §3.6 W-N5 | Windows | 未修 | 沿用复审 `EditPersistence.cs:46-59`、`UpdateStore.cs:253-279` | Win·主 | 无 | 保存移出 UI 线程 |
| P3-45 | L2（本次新发现） | Windows `Adjustments.ResetAll()` 仍会清空 HDR，只有测试在调；生产路径的规则已经不同 | 低 | 本次核实 | Windows | 未修 | `Adjustments.cs:370`（`HDR = hdr.Reset() with { Mode = hdr.Mode }`）；生产代码里搜不到 `.ResetAll()` 调用（只有 tests 下有） | Win·轻 | 无 | 删掉这个方法，或改成调 `EditorAdjustmentRules.PrepareReset(All)`；测试改用生产路径 |
| P3-46 | L3（本次新发现，推断） | Mac 更新门禁的 status 闭包每次求值都整读预设库和外观库 | 低 | 本次核实（#268 引入） | Mac | 未修 | #268 commit 07d7b8cb：`EditorModel+Updates.swift` 的 registerUpdateGate 里 `presetStore.list()` 和 `lookLibrary?.isReadable`（每次重新解码 registry）；按主 §14.6.2 M8，等待安装时有每秒轮询（推断，没有测量） | Mac·轻 | 无 | 可读性结果按文件 mtime 缓存；轮询 60 秒，读取次数不超过 1 |
| P3-47 | L4（本次新发现，推断） | iOS #267 的三段抽样复用：每一项都在锁内遍历全部历史任务；“3×64KiB 加元数据一致就复用”这个设计权衡没写进文档 | 低 | 本次核实 | iOS | 未修 | `CameraOriginalStore.swift` 新增的 samplingCandidate（遍历 `state.jobs`×`items`）；b9975bf2 的提交说明 | iOS·轻 | 无 | 历史 1 万条时单项查找耗时有测试上限；在相机导入文档里写明复用条件和误判风险 |
| P3-48 | L5（本次新发现） | fork 门禁的策略测试仍按作业名单判断，复审建议的显式字段没做 | 低 | 复 §3.7 R-N1 的建议；本次核实 | CI | 未修 | `scripts/ci/test_workflow.py:83` `name in ("windows", "ios", "macos")` | CI·轻 | 放进 R16 的 PR | 作业级显式标记（例如 `env.RAWLAB_SELF_HOSTED`）；新增一个自托管作业但没加门禁时测试变红 |
| P3-49 | R-N3 | fork PR 的缓存没人清理 | 低 | 复 §3.7 R-N3 | CI | 未修 | `.github/workflows/pr-cache-cleanup.yml:16`（只处理本仓库来源） | CI·轻 | Q2 | fork 不写缓存，或者清理 job 改用有写权限的 trigger |
| P3-50 | R5 ＝ R-N5 | 同一分支多次手动触发的验证会互相取消 | 低（已知） | 主 §9 R5；复 §3.7 R-N5 | CI | 未修 | `ci.yml:25-28`：group 里没有 inputs.platform 和 inputs.checks | CI·轻 | 无 | group 加上 inputs；test_workflow 断言 group 字符串里包含 inputs.platform |
| P3-51 | R4 | 版本号分散在四个入库文件，没有一致性校验 | 中 | 主 §9 R4 | 仓库 | 未修 | 沿用主评审 | CI·轻 | 无 | Contracts 检查四处版本一致 |
| P3-52 | R8 | PR 改目标分支后不会重新跑检查 | 低 | 主 §9 R8；复 §4.2 | CI | 未修 | `ci.yml:5` types 里没有 edited | CI·轻 | 无 | types 加 edited 并按 base 是否变化过滤 |
| P3-53 | R9 | 三组测试没有任何 CI 入口 | 低 | 主 §9 R9 | CI | 未修 | 沿用主评审 | CI·轻 | 无 | 每组都有入口，或者在文档里写明只在本地跑 |
| P3-54 | R10 | `.gitignore` 忽略了 /reviews 和 /release-artifacts，但库里仍有 30 个文件 | 低 | 主 §9 R10（第一批） | 仓库 | 未修 | `.gitignore:74,76`；`git ls-tree -r 0cf4a88a reviews release-artifacts` 共 30 个文件 | 仓库·轻 | 按 AGENTS 文档约定移到 docs/archive 或删除 | 这两个目录下没有被跟踪的文件 |
| P3-55 | R11 | 各端目录留着十几份 v0.8 的单次验证记录 | 低 | 主 §9 R11（第一批） | 仓库 | 未修 | 沿用主评审（未重核） | 仓库·轻 | 无 | 移进 docs/archive |
| P3-56 | R12 | iOS 把整个 Shared/BundledLooks 打进包 | 低 | 主 §9 R12 | iOS | 未修 | 沿用主评审 | iOS·轻 | 无 | 包里只有运行需要的文件 |
| P3-57 | R13 | 入库文件里有含本机用户名的绝对路径 | 低 | 主 §9 R13（第一批） | 仓库 | 未修 | `git grep -c /Users/xupeng 0cf4a88a`：26 个文件、102 处（主评审写的是 109 处） | 仓库·轻 | 无 | Contracts 加检查，命中数为 0 |
| P3-58 | R14 | 三个平台的测试都靠每个脚本手写源码清单来编译 | 低到中 | 主 §9 R14 | CI | 未修 | 沿用主评审 | CI·主 | 无 | 共用一份清单生成 |
| P3-59 | C11 | LUT 文本解析慢，全局只缓存一张 | 中 | 主 §4 C11 | 核心 | 未修 | 沿用主评审 | Core·主 | 无 | LRU 缓存多张 |
| P3-60 | C12 | 预览曝光匹配每次 RAW 解码都重开文件、全尺寸解码内嵌 JPEG | 中到低 | 主 §4 C12 | 核心 | 未修 | 沿用主评审 | Core·主 | 无 | 内嵌 JPEG 按会话缓存 |
| P3-61 | C13 | HSL 取样快照让小波输出缓存来回失效 | 中到低 | 主 §4 C13 | 核心 | 未修 | 沿用主评审 | Core·主 | 无 | 取样不让缓存失效 |
| P3-62 | C15 | AI 降噪结果在会话里常驻，加载时还有瞬时双份 | 中到低 | 主 §4 C15 | 核心 | 未修 | 沿用主评审 | Core·主 | 无 | 峰值内存下降 |
| P3-63 | C16 | Mac 普通 AI 路径不校验 Core ML 是否真的在 GPU 上跑 | 低到中 | 主 §4 C16 | 核心（Mac） | 未修 | 沿用主评审（待验证） | Core·主 | 需要先确认 Core ML 是否会把算子排到 CPU | 不在 GPU 上时明确提示（符合 AGENTS 里 AI 降噪的规定） |
| P3-64 | C17 | HDR 缩小用的是不带预滤波的双线性，还有三份实现 | 中到低 | 主 §4 C17 | 核心 | 未修 | 沿用主评审 | Core·主 | 无 | 统一成一份带预滤波的实现 |
| P3-65 | C18 | HDR 流式导出每读一个像素都要查哈希表、过三层 std::function | 中到低 | 主 §4 C18 | 核心 | 未修 | 沿用主评审 | Core·主 | 无 | 耗时测量写进 PR |
| P3-66 | C19 | libjpeg-turbo 在所有平台都关了 SIMD，没写原因 | 中到低 | 主 §4 C19 | 核心 | 未修 | 沿用主评审 | Core·主 | 无 | 开启 SIMD，或者写明原因 |
| P3-67 | C20 | Apple 的 8 位显示图像被完整解码两次 | 低到中 | 主 §4 C20 | 核心（Apple） | 未修 | 沿用主评审 | Core·主 | 无 | 解码次数为 1 |
| P3-68 | C21 | GLES 和 D3D11 通用滤波每块重新分配缓冲 | 低到中 | 主 §4 C21 | 核心 | 未修 | 沿用主评审 | Core·主 | 与 C2 一起 | 缓冲复用 |
| P3-69 | C23 | 没有调用方的代码 | 低 | 主 §4 C23 | 核心 | 未修 | 沿用主评审 | Core·轻 | 无 | 删除 |
| P3-70 | C24 | 核心源码被编译两遍，两段链接配置靠手工保持一致 | 低 | 主 §4 C24 | 核心 | 未修 | 沿用主评审 | Core·主 | 无 | 一个 object library 复用 |
| P3-71 | X6 | 相机下载每传完一张就把整张卡重列一遍 | 中 | 主 §3 X6、§14.4.2 | iOS、Android | 部分修复 | Android 联机拍摄已由 #260 改成增量轮询（commit 8e3f85e2）；导入路径和 iOS 没有核实 | And·主、iOS·主 | 无 | 导入每张照片的列卡次数为 0（探针） |
| 完成-01 | R1 ＝ R15 ＝ R-N1 | 外部 PR 能在自托管物理机（含 macOS 作业）上执行代码 | 高 | 主 §9 R1、§14.7.2 R15；复 §3.7 R-N1、§2.2 | CI | 已修（已合入） | #265：`ci.yml:130-134` 加了 `head.repo.full_name == github.repository`；`test_workflow.py:83` 把 macos 列入必须保护；`affected_platforms.py:48-56` 外部分支不判冷构建 | — | 仓库设置（是否公开、fork 是否需审批）仍无法离线核实 | 删掉 macOS 的条件后 `test_workflow.py` 变红（断言在 :84） |
| 完成-02 | M7 | Mac 安装器还没启动就失败，也被记成“装到一半” | 中 | 主 §14.6.2 M7 | Mac | 已修（已合入） | #268 commit 1991e917：`DesktopUpdateController.swift` 在记录 installing 之前调用 `adapter.prepareInstall()`；`UpdateAdapter.swift` 新增 prepareInstall；测试 `DesktopUpdateControllerTests.swift` preHandoffFailureAllowsRetry | — | — | 交接之前抛错的适配器替身：requiresRecovery 和 blocksEditing 都为假，“重试”可用 |
| 完成-03 | M8 | Mac 更新状态文件写盘失败一次就锁住编辑区 | 中 | 主 §14.6.2 M8 | Mac | 已修（已合入） | #268 commit e4eb2ff6：新增 `storageBlocksEditing`、`isCriticalSave`、`retrySave`；测试 storageFailureCriticalityAndRetry（`DesktopUpdateControllerTests.swift:285-298`） | — | — | 开始检查那次保存失败时不锁编辑，并且 canRetrySave 为真 |
| 完成-04 | M9 | Mac 安装前不检查预设库和外观库能否读取 | 中 | 主 §14.6.2 M9 | Mac | 已修（已合入） | #268 commit 07d7b8cb：门禁加了 presetsFailed 和 looksFailed（`UpdateInstallGate.swift`）、`LookLibrary.isReadable`（`Shared/LookLibrary.swift:231`）；测试 `DesktopUpdateControllerTests.swift:396-425` | — | 逐条容错没做，见“预设库与外观库逐条容错”一行 | 损坏的 presets.json 让门禁返回 presets 这个阻止原因 |
| 完成-05 | W10 | Windows 临时文件和目录的清理缺口 | 低 | 主 §8 W10 | Windows | 已修（已合入） | #266：`TempCleanup.cs`（新增 608 行），`App.xaml.cs:174` 调 `TempCleanup.SweepStartup()`；测试 `tests/usage/TempCleanupTests.cs` | — | 这个测试工程是否进 CI 没有核实 | — |
| 完成-06 | I14 | iOS 换一次连接，增量导入就不认之前的进度 | 中 | 主 §14.3.1 I14、§14.8 | iOS | 已修（已合入） | #267 commit b9975bf2：`CameraOriginalStore.swift` 的 sampleOffsets 和 samplingCandidate、`CameraWorkspaceBackend.swift` 的 reuseByMobileSampling；`CameraSkipAndLimitTests.swift` +529 行 | — | 残留见 L4 | — |
| 完成-07 | A14 | Android 联机拍摄按过快门后断线，重新连接必然在约 35 秒后再次失败 | 中 | 主 §14.4.1 A14 | Android | 已修（已合入） | #260 commit 97b86dd1：续接时清掉未确认的快门标记（`CameraTetherController.kt:276`）；`CameraTetherLivenessTest.kt` 778 行 | — | — | — |
| 完成-08 | A15 | Android 联机拍摄空闲时每 1.5 秒把整张卡重列一遍 | 中 | 主 §14.4.1 A15 | Android | 已修（已合入） | #260 commit 8e3f85e2（增量轮询，下载后核对有上限） | — | — | — |
| 完成-09 | I13 | iOS 一个坏文件让整次增量导入停住 | 中 | 主 §14.3.1 I13 | iOS | 已修（已合入） | #258；复 §4.1 | — | 残留见 I-N4、I-N5 | — |
| 完成-10 | I15 | iOS 卡上照片超过上限时整张卡列不出来 | 中偏低 | 主 §14.3.1 I15 | iOS | 已修（已合入） | #258（导入路径） | — | 联机拍摄这一半见 I-N6 | — |
| 完成-11 | I16 | iOS“重置全部”和“重置分组”入口没有调用方 | 中 | 主 §14.3.1 I16、§14.8 行10 | iOS | 已修（已合入） | #262：`EditorWorkspaceResetControl.swift`；`RawLab/tests/ios-reset-entry-ui.sh` 在 `scripts/ci/apple-models.sh:24` | — | 死代码见 I-N1 | — |
| 完成-12 | I18 | iOS 带配方的普通照片粘到 HDR 不按配方强度换算 | 低到中 | 主 §14.3.1 I18 | iOS、Mac | 已修（已合入） | #250：`Shared/HDRAdjustmentTransfer.swift:107` | — | — | — |
| 完成-13 | I19 | iOS 普通图片粘到 RAW 时曝光基准被改成 sensor | 低到中 | 主 §14.3.1 I19、§14.6.1a | iOS、Mac | 已修（已合入） | #250：`IOSAdjustmentTransfer.swift:136`、`MacAdjustmentTransfer.swift:159` 加了 `payload.source.isRaw \|\| !context.isRaw` | — | 白平衡这一半是进行中的 M10 | — |
| 完成-14 | A11 | Android 一张持续出错的照片让整次导入停住 | 中 | 主 §14.4.1 A11 | Android | 已修（已合入） | #257；复 §4.1 | — | — | — |
| 完成-15 | A13 | Android 卡上文件超过上限时整张卡列不出来 | 中 | 主 §14.4.1 A13 | Android | 已修（已合入） | #257 | — | — | — |
| 完成-16 | A16 | Android 一个读不出的相机日志让相机功能整体不可用 | 低到中 | 主 §14.4.1 A16 | Android | 已修（已合入） | #252：`CameraImportStore.kt`、`CameraTetherJournal.kt` 加了容错和测试 | — | — | — |
| 完成-17 | A19 | Android 普通模式“重置全部”丢掉未启用的 HDR 调整 | 低到中 | 主 §14.4.1 A19、§14.8 行6 | Android | 已修（已合入） | #253：`HDRResetTest.kt` | — | — | — |
| 完成-18 | iOS 重置全部保留 HDR | iOS 普通模式“重置全部”丢掉未启用的 HDR 调整 | 低到中 | 主 §14.3.2、§14.8 行6 | iOS、Mac | 已修（已合入） | #256：`RawLab/tests/EditMemoryTests.swift`、`HDRModelTests.swift` | — | — | — |
| 完成-19 | W11 | Windows 普通照片粘到 RAW 时曝光基准和白平衡被改 | 中 | 主 §14.5.1 W11 | Windows | 已修（已合入） | #255：`AdjustmentTransfer.cs:116`、`AdjustmentTransferWB.cs:68` | — | 镜头这一半见“14.8-W 镜头”一行 | — |
| 完成-20 | W12 | Windows 带配方的普通照片粘到 HDR 不按强度换算 | 中 | 主 §14.5.1 W12 | Windows | 已修（已合入） | #255：`HDRAdjustmentTransfer.cs:80` | — | — | — |
| 完成-21 | W13 | Windows 普通模式“重置全部”丢掉未启用的 HDR 调整 | 低到中 | 主 §14.5.1 W13；复 §4.2 写的是“Windows 漏半条” | Windows | 已修（已合入） | 生产路径 `EditorAdjustmentRules.PrepareReset(All)` 用的是 `Defaults(edit)`，它带上了 HDR、HDRCameraAIEnabled、ProRAWDecodeVersion（`EditorAdjustmentRules.cs:100,106` 与 #255 的 diff）；测试 `tests/editing/HDRChecks.cs:134-158`。复审引用的 `Adjustments.cs:370 ResetAll` 没有生产调用方（见 L2） | — | — | — |
| 完成-22 | W15 | Windows LUT 兼容预览：只读文件导致失败，并留下副本 | 低到中 | 主 §14.5.1 W15 | Windows | 已修（已合入） | #251，#266 又补了 owner marker（`LUTCompatibilityPreview.cs:56,127`） | — | — | — |
| 完成-23 | W17 | Windows 预设库里一条读不懂就整库不可用 | 低到中 | 主 §14.5.1 W17 | Windows | 已修（已合入） | #251：`tests/editing/AdjustmentPresetChecks.cs:177`（ListUnreadable 隔离） | — | — | — |
| 完成-24 | W1 | Windows 手动安装包用户收不到更新提示 | 高 | 主 §8 W1 | Windows | 已修（已合入） | 复 §4.1；文件是 `RawLabWindows/UpdateRelease.cs`（复审写的 `Updates/` 路径不对），测试 `tests/editing/UpdateReleaseAssetChecks.cs` | — | 线上发布页的实际文件名无法离线核实 | — |
| 完成-25 | W3 | Windows 更新状态文件写失败就锁住编辑区 | 中 | 主 §8 W3 | Windows | 已修（已合入） | 复 §4.1（主链路） | — | “五处统一”见 W-N4 | — |
| 完成-26 | W4 | Windows 没有未处理异常的兜底 | 中 | 主 §8 W4 | Windows | 已修（已合入） | 复 §4.1 | — | “只降级”这一半见 W-N3 | — |
| 完成-27 | W7 | Windows 安装器启动前的校验失败被当成“装到一半” | 低到中 | 主 §8 W7 | Windows | 已修（已合入） | `DesktopUpdateController.cs:305-316`：VerifyBeforeInstall 在记录 Installing 之前执行，失败时走 FailVerification | — | — | — |
| 完成-28 | C1 | Mac 和 iOS 链接 LibRaw 的非线程安全版本 | 高 | 主 §4 C1 | 核心（Apple） | 已修（已合入） | `lutools/CMakeLists.txt:66,72`（raw_r，REQUIRED libraw_r）；`lutools/tests/raw_thread_safety_tests.cpp` | — | — | — |
| 完成-29 | C3 | 主渲染入口缺兜底的异常捕获 | 中 | 主 §4 C3 | 核心 | 已修（已合入） | `sony2fuji_c.cpp` 有 33 处 `catch (...)`；复 §4.1 | — | — | — |
| 完成-30 | C4 | 独立 LUT 的 GLES 上下文绑定后不恢复 | 中到低 | 主 §4 C4 | 核心 | 已修（已合入） | `gles_lut.cpp:110` Binding RAII | — | 细节见 G-N4 | — |
| 完成-31 | C22 | 缺素材的测试直接不注册，而不是标记为跳过 | 中到低 | 主 §4 C22 | 核心 | 已修（已合入） | `lutools/CMakeLists.txt` 有 40 处 `SKIP_RETURN_CODE 77`（如 :464、:496） | — | — | — |
| 完成-32 | C25 | Meson 和 Ninja 没钉校验值 | 中到低 | 主 §14.1.1 C25 | 核心 | 已修（已合入） | #244：`lutools/cmake/lens-dependencies.json` 带 sha256；#263 拒绝未知的 Android ABI | — | — | — |
| 完成-33 | C27 | Windows 扫描 JPEG 时过短的 Exif 段越界读 | 中 | 主 §14.2.1 C27 | 核心（Windows） | 已修（已合入） | #243：`display_image_windows.cpp:191-194` equalBytes 带显式长度 | — | — | — |
| 完成-34 | C28 | 非 Apple 平台的 EXIF 解析没有累计复制上限 | 中 | 主 §14.2.1 C28 | 核心 | 已修（已合入） | #245：`hdr_metadata.cpp` 加了 budget；测试 `hdr_portable_tests.cpp` | — | — | — |
| 完成-35 | C30 | 旧版降噪预览分辨率与导出不一致 | 低到中 | 主 §14.2.1 C30 | 核心 | 已修（已合入） | #248：`sony2fuji_c.cpp:2648`、`d3d11_photo.cpp:209`、`metal_photo.mm:1031`；GLES 在 `gles_photo.cpp:293` 走 noise_reduction>0 的分支 | — | — | — |
| 完成-36 | X4 | 单张导出直接写最终路径 | 中 | 主 §3 X4 | 核心，以及四端 | 已修（已合入） | #230、#242（staging）；`processing_cancellation_tests.cpp:195-213` | — | Windows 分支见 C-N8 | — |
| 完成-37 | X5 | 批量日志读回再全量重写，一个坏日志拖垮全部 | 低到中 | 主 §3 X5 | 四端 | 已修（已合入） | #231；复 §4.1 | — | — | — |
| 完成-38 | X1 | 编辑记录写入不容错（第 1 步：落盘同步与逐条隔离） | 中 | 主 §3 X1 | 四端 | 部分修复 | 复 §4.1（原子写、flock、单条隔离已落地）；读侧整文件的问题见 S1 和 X2 | — | — | — |
| 完成-39 | A4 | Android 普通导出无法中途取消 | 中 | 主 §7 A4 | Android、核心 | 已修（已合入） | `RawLabAndroid/app/src/test/java/com/rawlab/android/engine/ExportCancellationTest.kt`；复 §4.1 | — | 残留见 A-N2、A-N3 | — |
| 完成-40 | A10 | Android 编辑历史字段被两个线程无同步读写 | 低 | 主 §7 A10 | Android | 已修（已合入） | #228；复 §4.1 | — | 残留见 A-N1、A-N10 | — |
| 完成-41 | R2 | Apple 文案键 CI 不检查 | 中 | 主 §9 R2 | CI | 已修（已合入） | `ci.yml:101` 跑 `python tests/test_localization.py` | — | — | — |
| 完成-42 | 14.1.3#3/#4 | 配方 profile_id 校验；Effects 清晰度文档 | 低 | 主 §14.1.3 | 核心 | 已修（已合入） | #259：`edit_recipe.cpp:219-225` | — | — | — |
| 完成-43 | 14.2.3#3 | HDR 导出经 staging 后权限丢失 | 低 | 主 §14.2.3 | 核心 | 已修（已合入） | #261：`hdr_image_portable.cpp` 引入 output_file_mode | — | — | — |
| 完成-44 | #246 CI UTF-8 | CI 脚本按系统编码读写文本 | 低 | 台账（主 §14.7 次要） | CI | 已修（已合入） | #246：`scripts/ci/native_cache.py:57,160,168` 用 `encoding="utf-8"` | — | — | — |
| 完成-45 | C-N3 | staging 的 O_CLOEXEC 被 fdopen 抵消 | 低 | 复 §3.1 C-N3 | 核心 | 已复核不再成立 | macOS 实测：用 O_CLOEXEC 打开，fdopen("wb") 之后 FD_CLOEXEC 仍为 1（临时程序 /tmp/lead-plan/cloexec.c 的输出）；按 libc 语义，glibc 和 bionic 的 fdopen 也不会清这个标志（推断，没有实测） | — | — | 如需完全确认，在 Linux/Android 上跑同一段程序 |
| 完成-46 | I-N9 | #258 的回归测试在 scheme 外，CI 可能不跑 | 低 | 复 §3.4 I-N9 | iOS | 已复核不再成立 | `RawLab/tests/camera-originals.sh:13` 会调用 `camera-skip-and-limit.sh`，而 `camera-originals.sh` 在 `scripts/ci/apple-models.sh:23` 的 iOS 模型套件里 | — | — | — |
| 完成-47 | R-N4 | push 基线查询只接受 run_attempt==1 | 低 | 复 §3.7 R-N4 | CI | 已复核不再成立 | 在 d05c8d7d 和 0cf4a88a 的 `scripts/ci` 与 `.github` 里 `git grep attempt` 都是 0 命中；`affected_platforms.py:123-134` 只按 branch、event、status=success 查询 | — | — | GitHub 列表 API 对重跑的处理没有在线验证 |

### B.1 复审 §2.2“实际没有或只有一半落地”的条目，在 0cf4a88a 的真实状态

| 条目 | 复审结论（d05c8d7d） | 0cf4a88a 实际状态 | 证据 / 还差什么 |
|---|---|---|---|
| M1 | 未动 | **未修**，没有变化 | `EditorModel+HSLTarget.swift:15` 比较值不带 `hdrFingerprint`；这个文件 9c4f7801 之后 0 提交 |
| W2 | 半修 | **部分修复**，没有变化 | `DesktopUpdateController.cs:176`、`:266-267`；还差：非 Checking 阶段的失败要有退避后的自动恢复，以及主窗口提示（W-N1） |
| R1 | 半修（macOS 漏了，fork 恒红） | **执行敞口已修**（#265）；**恒红仍在，而且更严重** | `ci.yml:130-134` 加了来源门禁，`affected_platforms.py:48-56` 外部分支不判冷构建；但 select（`:91-97`）不感知 fork，verify（`:163-173`）仍要求 success，macOS 现在也会被 skip，所以 fork PR 只要碰到 Mac 文件也是红的（这一点由代码推演，没有实际触发） |
| C14 | 部分 | **部分修复**，没有变化 | 帽和 size_t 化已在；还差 C-N1（NATIVE 和预检，`sony2fuji_c.cpp:528-529,740-742,2472`）、C-N2（JPEG 维度）、C-N9（`common.h:32-39` 只有 assert） |
| A3 | 半修 | **部分修复**，没有变化 | `EditorViewModel.kt:769` 早退不复位；`EditorScreen.kt:249-250` 没有处理 IMPORT_LOOK 的返回键 |
| C2/C6/C7 | 仍成立 | **未修** | `gles_photo.cpp:297`、`d3d11_photo.cpp:216` 仍是整图版；D3D11 异常全量重建的路径没有改动 |
| M4 | 仍成立 | **未修** | `BatchExportModel.swift:446-447`：AI prepare 用空的 progress 闭包，没挂取消（这个文件 d05c8d7d 之后没改） |

另外两条，复审 §2.2 没点名，但同样“台账以为做了、其实没做”：**I5**（主评审第一批，`RawEditorViewModel+Rendering.swift:188`）和 **R10、R13**（第一批的仓库清理，30 个被跟踪文件、102 处本机路径）。

### B.2 结构性观察 S1–S6：现在做不做

| 编号 | 问题 | 现状（0cf4a88a） | 现在值不值得做 | 建议形式 |
|---|---|---|---|---|
| S1 | 编辑记录四端独立实现，没有共享 golden fixture | 在飞 PR 只新建了**调整传输**场景向量；编辑记录本身没有 | **值得，下一轮第一批做**。S3 和 R3 都要在它上面改，先有基线才不会把同一条语义再写第五遍。本轮 Windows 重置的实际状态与复审结论不一致，也说明靠人工对照四端不可靠 | 一个 Shared PR 建 `edit-records-v1.json` 和规则文档，四端各一个 conformance PR（可以并行） |
| S2 | 热点文件即最大文件（`EditorViewModel.kt` 2004 行、`sony2fuji_c.cpp` 3106 行、ContentView 110 个 @State） | 数字与复审相同（`wc -l`、`grep -c` 实测） | **不单独排期**。大重构风险高、收益难衡量；改为“碰到就顺手拆一块”，比如修 A3、A-N9 时把 Look 导入状态机拆出 VM | 附带在功能 PR 里，PR 描述写明拆出的职责 |
| S3 | 热路径整文件读和哈希（X2） | 四端都没动；#240、#267 又新增了身份校验和抽样逻辑 | **值得，排在 S1 之后**，按 Mac 缩略图链 → iOS 保存路径 → Android 启动恢复的顺序。A1 是高严重度，可以先单独用 stat 指纹解决 | 每端 1 个 PR，必须带调用次数探针（撤修复后计数回升） |
| S4 | ABI fixture 不含枚举、只支持 64 位、本地不跑 | 没有变化（`generate_abi_layout.cpp:8-9`） | **值得，成本极低**（半天） | 1 个 Core 小 PR |
| S5 | 取消已是跨层契约，文档和响应性没跟上 | C-N4 和 C-N5 没变；A-N3 的语义没定 | **文档部分现在就做**；编码检查点放下一轮；迟到取消的语义要先决定（Q12） | 文档并入 `lutools/docs/color-contract.md`，或新建 processing-cancellation.md |
| S6 | 更新器状态机靠打补丁演化 | Windows 没变（W-N1、W-N2、W-N6）；Mac 由 #268 又补了三处 | **值得，下一轮 Windows 的首要工作**。先写矩阵测试再收口，Mac 复用同一张矩阵 | Windows 1 个 PR（矩阵＋W-N1/N2/N4/N6）；Mac 之后跟一个“只加矩阵测试”的 PR |

## C. 四端一致性专项（主 §14.8 × 复审 × 0cf4a88a）

✅ 一致或已修；❌ 仍有问题；⏳ 在飞；— 不适用。

| 规则 | Mac（参考端） | iOS | Android | Windows | 结论 |
|---|---|---|---|---|---|
| 普通图片粘到 RAW：曝光基准占位 | ✅ #250 `MacAdjustmentTransfer.swift:159` | ✅ #250 `IOSAdjustmentTransfer.swift:136` | ❌ `AdjustmentTransfer.kt:131-134` | ✅ #255 `AdjustmentTransfer.cs:116` | **Android 偏离**（A18） |
| 同上：白平衡占位（none/null 当成相机白平衡） | ⏳ `MacAdjustmentTransferWB.swift:140` | ⏳ `IOSAdjustmentTransferWB.swift:125` | ❌ `AdjustmentTransferWB.kt:26` | ✅ #255 `AdjustmentTransferWB.cs:68` | Mac/iOS 在飞；Android 还没开始 |
| 同上：“全部”范围时镜头五项被关掉 | ⏳ `MacAdjustmentTransferValues.swift:102-107` | ⏳ `IOSAdjustmentTransferValues.swift:74-79` | ❌ `AdjustmentTransferValues.kt:95-98,132-137` | ❌ `AdjustmentTransferValues.cs:78-80,110-118` | **四端都还不一致**；只有 Mac/iOS 在飞 |
| 同上：默认范围时 RAW 降噪被清零 | ⏳ `:93,116-121` | ⏳ `:63-64,85-88` | —（两个键恒为 0） | —（两个键恒为 0） | 在飞 PR 修完即对齐 |
| RAW 降噪的交换字段（`raw_level` 还是 `post_rgb`） | 写 raw_level，拒收非 0 的 post_rgb（`:93-94,113-114`） | 反过来（`:63-64,84-86`） | 两个都写 0，非 0 拒收（`:82,105`） | 同 Android（`:72,87`） | **语义分叉，要先决定（Q3）**，在飞 PR 不解决这个 |
| 带配方的普通照片粘到 HDR 时按强度换算 | ✅ #250 `Shared/HDRAdjustmentTransfer.swift:107` | ✅（共用 Shared） | ❌ `AdjustmentTransfer.kt:220-243` | ✅ #255 `HDRAdjustmentTransfer.cs:80` | **Android 偏离**（A17） |
| 普通模式“重置全部”保留未启用的 HDR | ✅ 参考行为 | ✅ #256 | ✅ #253 | ✅ #255（经 `Defaults(edit)`；`HDRChecks.cs:134-158`） | **已对齐**；Windows 的 `Adjustments.ResetAll()` 是死路径，见 L2 |
| HDR 显示映射和相机显影的重置入口 | 有渲染重置（`Shared/Native/HDRMonitoring.swift:56`，#256） | ✅ #256、#262 | #253 补了 HDR 区块的重置按钮（只看了 diff 规模，没细读） | ✅ #255（`MainWindow.HDR.cs:308,401`） | 基本对齐；主 §14.6.1d 的“分组重置不清 FBDD”等细项没复核 |
| 粘贴时比较处理版本 | ❌ `Shared/AdjustmentTransfer.swift:422` 只校验范围 | ❌ 同上 | ❌ | ❌ | **四端一致地缺这条规则**，要先决定（Q4） |
| 预设库、外观库逐条容错 | ❌ `Shared/AdjustmentPresetStore.swift:170-180`（M9 只是把它纳入更新门禁） | ❌ 同上 | ❌ `AdjustmentPresetStore.kt:108-130` | ✅ #251 | 以 Windows 为参照移植 |
| 重置入口七种范围 | ✅ | ✅ #262 | 没核对 | 没核对 | 覆盖缺口（E.2） |
| 相机：坏文件卡住、张数上限 | — | ✅ #258（联机上限见 I-N6） | ✅ #257 | — | 已对齐 |
| 相机：重连后认上次进度 | — | ✅ #267（三段抽样） | ❌ A12 | — | **Android 偏离**；建议照搬 iOS 方案（Q7） |

**整改顺序**

1. **在飞 PR 合入**：Mac/iOS 的白平衡、镜头、旧版降噪占位，加上 `adjustment-transfer-scenarios-v1.json` 和契约文档。这是后面所有移植的“规则源”。
2. **Android 一个 PR**：A18（曝光基准）、白平衡、镜头占位、A17（HDR 配方强度），全部用共享场景向量驱动。Android 的 80 条硬编码计数（主 §14.7.1c）一并改成读文件长度。
3. **Windows 一个小 PR**：只改镜头占位，跑场景向量。
4. **产品决策 Q3、Q4 之后**：`raw_level`/`post_rgb` 语义和处理版本比较写进场景向量，再四端各改一次。
5. **预设库、外观库逐条容错**：Mac/iOS 一个 Shared PR，Android 一个 PR，都以 Windows 的 `ListUnreadable` 为参照。

## D. 后续分配计划

### 阶段 1：本轮收尾（2 个 PR）

| PR | 内容 | 为什么必须现在做 | 验证 |
|---|---|---|---|
| 1 | 在飞：M10＋14.8 行1–3（Mac/iOS）＋场景向量＋契约文档 | 已在进行；它产出的向量是阶段 2 Android、Windows 移植的唯一规则源。不先合入，三端会各写一遍规则 | 本机 `bash RawLabMac/build.sh`、`RawLabMac/tests/adjustment-transfer.sh`、`RawLab/tests/adjustment-transfer.sh`；CI 跑 macOS 和 iOS 的模型套件 |
| 2 | 在飞：Windows `RuntimeSaveFailureRecovery` 改成确定性注入 | flaky 会让 Windows updateSdk 门禁失去信用，也会挡住阶段 2 的 S6 矩阵测试 | 本机或 Windows runner 循环跑 50 次；CI 手动触发 windows/native |

- 可并行 worker：2（两个 PR 不共享文件）。
- 阻塞点：PR 1 的规则文档要先确认“来源不是 RAW 时不产出只对 RAW 有意义的字段”与 Mac 现有测试 `AdjustmentTransferTests.swift:568-570` 怎么改（主 §14.6.1a 已给出建议）。

### 阶段 2：下一轮（按平台分组，每个 PR 只解决列出的编号）

| 组 | PR 边界（编号） | 规模 | 验证 |
|---|---|---|---|
| CI | ① R16/R-N2＋L5（verify 适配 fork、显式自托管字段）＋R-N3 ② L1（`RAWLAB_REQUIRE_AX`）＋R5/R-N5（concurrency 带上 inputs）③ R6（Windows 允许名单对账） | 小、小、小 | `python3 scripts/ci/test_workflow.py`、`test_affected_platforms.py`；CI 的 Contracts job |
| Mac | ① M1 ② M2/M-N1＋M-N2（S3 第一段，带计数探针）③ M4/M-N6＋M11（取消）④ M-N7＋M-N3＋L3 小清理 ⑤ S6 矩阵测试复用（只加测试） | 小、中、中、小、中 | `bash RawLabMac/build.sh` 和相关 `RawLabMac/tests/*.sh`；涉及 UI 的先在本机跑 UI 测试（AGENTS 要求） |
| iOS | ① I5 ② I-N1 死代码 ③ I-N4/I-N5/I-N6 相机 ④ I3/I-N2＋I-N3（S3 第二段）⑤ I1 残留（等 Q6） | 小、小、中、中、中 | `RawLab/tests/*.sh` 模型套件；相机部分要真机抽测，记在 PR 里 |
| Android | ① A3 ② A-N1＋A-N10 ③ 14.8 移植：A17＋A18＋白平衡＋镜头（依赖阶段 1）④ A12（等 Q7）⑤ A1（stat 指纹）⑥ 预设库逐条容错 ⑦ A-N9、A-N4、A-N5 小清理 | 小、小、中、中、中、小、小 | `./gradlew testDebugUnitTest`；A12、A1 要真机或模拟器验证相机和冷启动 |
| Windows | ① S6：矩阵测试＋W-N1＋W-N2＋W-N4＋W-N6 ② 14.8 镜头占位 ③ W-N3 预览降级＋L2 死路径 | 中、小、小 | `RawLabWindows/` 现有测试工程；没有硬件 GPU 时不声称 GPU 已验证 |
| 核心 | ① C-N4/C-N5 文档＋编码检查点（S5）② G-N2＋G-N6＋C-N9 ③ S4 枚举进 fixture ④ C2/C6/C7 分块降噪 ⑤ G-N1 Force 错误码统一（先查四端调用方）⑥ C29＋C26 | 中、小、小、中、小、中 | `ctest --test-dir lutools/build-macos --output-on-failure`；④⑥ 需要 Windows 硬件 GPU 和 Android 真机；改共享 C ABI 时检查四端调用方 |
| Shared | S1 编辑记录 golden fixture（规则文档＋fixture），四端 conformance 拆成 4 个小 PR | 中＋4 个小 | 四端快速模型测试 |

- 可并行 worker：**6**（CI、Mac、iOS、Android、Windows、核心各 1 个）。Shared 的 S1 由 Mac worker 兼任，在 Mac ② 之前完成。
- 共享文件 owner：`Shared/*.swift` 归 Apple worker；`Shared/fixtures/` 归 S1 owner；`lutools/include/sony2fuji/ffi/*.h` 归 Core（按 `docs/process/integration-workflow.md` 登记）。
- 验证分层：小 PR 走本机构建加 CI 模型；④ 类 GPU 改动走手动 native 触发和真机；相机类走真机抽测。CI 不跑 UI 测试，UI 测试结果写在 PR 描述里。
- 阻塞点：Android ③ 依赖阶段 1 的 PR 1；Mac ②、iOS ④、Android ⑤ 建议在 S1 之后；Android ④、iOS ⑤ 等 Q6、Q7。

### 阶段 3：先做产品决策（决策人：用户）

| 编号 | 决策问题 | 影响的行 | 建议选项 |
|---|---|---|---|
| Q1 | 超过 128MP 的原生尺寸导出要不要支持？ | C-N1/G-N8、C-N2 | 建议支持到 2.1G 像素的溢出上限，NATIVE 在解码前预检；或者明确不支持，返回尺寸类错误码 |
| Q2 | 仓库接不接受外部 fork PR？ | R16/R-N2、R-N3 | 不接受：在 `docs/process/ci.md` 写明，并让 fork 走“skipped 可接受”；接受：Windows 托管机照常跑 |
| Q3 | `raw_level` 和 `post_rgb` 各自的含义；移动端精度较粗是不是有意的？ | R17、R7 | 字段目录统一定义；不支持该功能的端收到非 0 值时“忽略并提示”还是“拒收” |
| Q4 | 粘贴时来源和目标的处理版本不同怎么办？ | 14.8 处理版本 | 沿用目标版本并提示，或者拒绝 |
| Q5 | HDR 显示映射要不要纳入分组和单项重置？ | 14.6.1d | 纳入“HDR 渲染”分组 |
| Q6 | iOS 和 Android 什么算“可以删”：批量 DNG、相机原件、联机记录 | I1、A2 | 给出保留天数或条数；iOS 是否开 UIFileSharingEnabled |
| Q7 | Android 重连续传要不要照搬 iOS 的三段抽样？ | A12（还有 L4 的风险说明） | 照搬，跨端行为一致 |
| Q8 | Mac 整幅中性参考帧要不要保留？ | M3 | 限制长边，并计入预算 |
| Q9 | 桌面配方生成函数是功能还是测试工具？ | R18 | 测试工具，README 同步改 |
| Q10 | I17 先在真机复现，再决定修法 | I17 | — |
| Q12 | 提交点之后迟到的取消，要不要删掉已完成的文件？ | A-N3、S5 | 保留文件并提示“已完成” |
| Q13 | 更新状态文件的回滚兼容策略 | W-N6 | 旧版读不懂新枚举时降级为 Idle，而不是锁住编辑区 |

- 可并行：决策之间互不依赖，可以一次性评审。决策落地后的实现回到阶段 2 的对应组。
- 阻塞点：没有决策时，对应的实现不开工；只做“把现状写进契约”的文档。

## E. 覆盖缺口与不确定项

### E.1 沿用复审 §7 的缺口

- 两份文档和本计划都只做了静态读码，没有构建、测试或运行应用。“推断”和“沿用主评审”标注的行没有在本次重新验证。
- 界面层（SwiftUI、Compose、WPF 重组）没有量化；着色器与 CPU 公式没有逐行对照；`x3f-bridge` 的 dp1s 细节和 `AbiLayoutChecks.cs` 内部没读。
- GitHub 仓库设置（是否公开、fork 是否需审批、CI result 是否是分支保护必需项）无法离线核实，它决定 R16 的严重度。W1 的线上发布文件名同理。

### E.2 本次核实发现、两份文档都没覆盖的

1. **L1：AX 静默跳过**。`HDRRenditionUITests.swift:79-81` 在没有授权时 `return`，而 `hdr-rendition-ui.sh` 在 CI 模型套件里（`scripts/ci/apple-models.sh:12`）。注释说“CI 自托管 runner 有授权”，这一点无法离线确认；授权一旦丢失，CI 会绿着空跑。另外，`hdr-rendition-ui.sh` 和 `ios-reset-entry-ui.sh`（`:24`）都是 UI 类测试却在 CI 里跑，与根目录 AGENTS 的“CI 不重复执行 UI 测试”字面上冲突，需要协作规范给个说法。
2. **L2：Windows `Adjustments.ResetAll()`** 仍然清空 HDR，只有测试在调（`Adjustments.cs:370`）。测试验证的语义与生产路径不同，复审正是被它误导，才得出“Windows 漏半条”的结论。
3. **L3：#268 新增的门禁闭包**每次求值都整读预设库和外观库（推断有每秒轮询，没有测量）。
4. **L4：#267 的三段抽样**每一项都在锁内遍历全部历史任务；“3×64KiB 加元数据一致就复用原件”的误判风险没有写进文档。
5. **#266 的 `TempCleanupTests`** 在 `RawLabWindows/tests/usage/` 工程里，是否进 CI 没有找到证据（`scripts/` 和 `.github/` 里搜不到 `tests/usage`）。
6. **Android 和 Windows 的重置入口**（主 §14.8 行10）至今两份文档都没核对。
7. **#264（Android 手动清理系统相册副本）是新功能**，两份文档都没评审：删除前是否核对编辑记录引用，没有细读（只看到 `SystemPhotoStore.kt:113-142` 的 inspect、clear、list）。
8. **#260（Android 联机）在复审基线之后才合入**，复审没有覆盖；本次只核对了提交说明和测试规模（`CameraTetherLivenessTest.kt` 778 行），没有逐行审。

### E.3 文档与代码不符（以 0cf4a88a 为准）

| 文档说法 | 实际 | 证据 |
|---|---|---|
| 台账：#267 覆盖 I14/A12 | #267 只改了 iOS 文件，A12 未修 | `git diff --stat d05c8d7d 0cf4a88a` 里 #267 涉及的全部是 `RawLab/` 下的文件；`CameraIncrementalImport.kt` 191d8aba 之后没有相关提交 |
| 主 §14.9：#250 对应 A17、A18 | #250 没改 Android 文件 | `git diff --stat 6b5e7783^1 6b5e7783`（5 个文件，都是 Mac、iOS、Shared） |
| 复 §4.2：Windows ResetAll 仍丢休眠 HDR | 生产路径已保留 | `EditorAdjustmentRules.cs:100,106` 与 #255 的 `Defaults` diff；`tests/editing/HDRChecks.cs:134-158` |
| 复 C-N3：fdopen 会清掉 O_CLOEXEC | macOS 上不会 | `/tmp/lead-plan/cloexec.c`：fdopen 前后 FD_CLOEXEC 都是 1 |
| 复 I-N9：#258 的 harness 可能不进 CI | 已经进了 | `RawLab/tests/camera-originals.sh:13`，加上 `scripts/ci/apple-models.sh:23` |
| 复 R-N4：基线查询只接受 run_attempt==1 | 代码里没有这个过滤 | `git grep attempt` 在 d05c8d7d 和 0cf4a88a 上都是 0 命中 |
| 复 A-N1 路径 `editor/EditorEditStore.kt` | 实际在 `editor/storage/EditorEditStore.kt` | `git grep 'class EditorEditStore' 0cf4a88a` |
| 复 C-N7 路径 `tools/abi-layout/…` | 实际在 `lutools/tools/abi-layout/…` | `git ls-tree` |
| 复 §4.1 W1 路径 `UpdateRelease.cs`（放在 Updates 目录下引用） | 实际在 `RawLabWindows/UpdateRelease.cs` | `git ls-tree` |
| 主 R13：109 处本机路径 | 现在是 26 个文件、102 处 | `git grep -c /Users/xupeng 0cf4a88a` |

### E.4 不确定项

- C-N3 在 Linux 和 Android 上没有实测，“不会清标志”是按 libc 语义推断的。
- R16 在合入 #265 之后“macOS 也会变红”是按 `verify()` 代码推演的，没有用 fork 事件实际触发。
- 状态为“未修”且依据写“沿用主评审”的行（多为 P3 性能项），本次只确认了相关文件之后没有对应 PR，没有逐行重读。

## 整体方案（2026-11-13 架构决策，覆盖本表排序）

来源：`docs/architecture/architecture-review-2026-11-13.md`（AR-1…AR-7）+ 本台账，经架构决策后重排。**本节的阶段划分优先于 B 表的序号顺序**；B 表仍是逐条状态的事实来源。

### 路线

**先建编辑语义的规格层，其余按主题批次双轨推进**：语义层冻结单端修补，所有跨端语义修复只能以「接入 conformance」的形式落地；语义层之外约 80 行按主题批次并行，不逐行修、也不等地基。

关键事实（决策时新核实）：共享向量机制**已经存在**（Mac/iOS/Android/Windows 都读 `Shared/fixtures/adjustment-transfer-v1.json`），AR-1 缺的是**闭环**——向量不覆盖依赖目标状态的规则、Android 写死 `assertEquals(73, all.size)`、没有字段全集可对账。因此地基不是「新建一套机制」，而是补齐闭环。

### 十条验收不变量（判定技术债是否还清的判据）

1. 每个字段 ID 的类型/范围/默认值/步长/精度/传输分组/重置分组/适用目标类型只在 `Shared/specs` 定义一次，四端与核心 CLI 逐项对账。
2. 粘贴/重置/占位/版本比较规则用场景向量表达，每端按 id 集合消费全部向量，禁止写死计数；平台差异只能进 `divergences` 登记表，条数只减不增（棘轮）。
3. 每端每个历史记录版本都有 golden 样本，投影到字段 ID 空间后与共享期望一致；「未来版本」判定只读版本登记表。
4. 同一批渲染请求向量在 GPU 后端与 CPU 参考之间差异在容差内；Auto 能回退，Force 不伪装成功。
5. C ABI 的结构布局、函数签名、枚举值全部进 fixture；`DllImport` 与 `external fun` 与之对账；JNI 包装面有契约测试。
6. 并发与取消有一页成文契约，每条有测试锚点。
7. 每个测试源文件要么被构建系统发现并在门禁执行，要么列在 manual 清单并写明理由；**CI 里出现 SKIP 一律算失败**（L1 推广）。
8. 文件身份判定只有一条规则（stat 指纹优先、内容哈希兜底），三条热路径的整文件读/哈希次数有上限。
9. 产品版本号只有一处来源；核心源码只编译一次、依赖列表只有一份；仓库无本机路径与误跟踪产物。
10. 跨端语义问题不能用单端 PR 关闭；每个「已修」都要有撤修复变红的锚点。

### 地基层（`Shared/specs/`）

- `adjustment-fields-v1.json`：每字段 `id/type/unit/min/max/identity/step/decimals/targets/raw_only/transfer_group/reset_group/reset_all/since/aliases/deprecated`。
- `versions-v1.json`：processing / hdr_processing / payload / scope / 各端 record、journal、recipe 的 `min_readable` 与 `current`。
- `divergences-v1.json`：`{scenario_or_field, platforms, ledger_id, decision, owner}`；#270 的 `platforms`/`platform_expect` 后续迁入。
- **不做代码生成**（重新评估触发条件：连续两轮新增字段因 parity 返工）；`field-catalog.md` 删掉数值、改为引用 JSON。

### 前提核查结论（2026-11-13，基线 d5d62af7；逐条文件:行证据见 kanban t_e1394964）

1. **字段表口径**：83 个对齐字段中 **59 个存在四端分叉（71%）**——步长/量化 53、范围/可表示值 11、默认/单位 10、缺失 4；暗角/颗粒 8 项在 iOS 被 `rounded()` 强截断且传输入口拒收小数。`adjustment-fields-v1.json` 必须显式分离「传输/持久化精确值」与「UI 步长」两列；P1-② 字段表按此口径划范围，不是从零发明规格。
2. **像素对拍定位**：普通 PR CI 不编译 `lutools`，Windows D3D11 后端按颜色契约硬排 WARP，Android CI 无 GLES 环境 → 渲染像素对拍（含 v0）是**发布前/改动渲染核心时的手动门禁**，不进普通 PR 门禁；普通 CI 只锁「规格契约 + request 结构体数值一致」。
3. **传输测试入口**：Android/Windows 传输单测已直调生产入口（`AdjustmentTransfer.prepare/Prepare`、`AdjustmentPayload.decode/Parse`）→ P1-① 接入不需要测试入口重构，各端 <0.5 人日，直接挂共享黄金 fixture。

### 评审门禁（2026-11-13，用户纪律）

- **合入前必须通过独立 review（agy reviewer，carbon 模型）**；评审结论记入 PR 描述与台账变更记录。纯文档性质修改豁免。review 发现 blocking 时修复后复审，再合入。

### 阶段（以迭代轮次计）

| 阶段 | 内容 | 并行 | 可演示产出 |
|---|---|---|---|
| **P0**（半轮） | 合入 #270–#273 与 3 个 worker 的 PR；一次定完 Q1–Q13 与「UI 测试能否进 CI」口径；前置件：AR-4 并发契约页、S4 fixture 扩枚举与函数签名 | 4 | CI 不再空跑/flaky、fork 结果一致；决策清单关闭 |
| **P1**（1 轮） | 语义地基第 1–3 步：①传输场景接入（Android/Windows + 删写死计数 + divergences）②字段表 + 四端 parity ③重置场景向量（锁定现状）；旁路：C24、JNI 契约骨架、P/Invoke 对账、不变量 7 对账、渲染对拍 v0（Metal 对 CPU，手动门禁——前提核查结论 2） | 6–7 | **四端在同一份场景向量上全绿，divergences 从 k 递减** |
| **P2**（1 轮） | 编辑记录 golden + 版本表（S1/M-N7）；A′ 决策落地使 divergences 归零；HDR 引用式契约；S6 更新器矩阵；存储身份与 IO 批次；A12、I1/A2 | 6 | **divergences = 0；旧记录四端可读** |
| **P3**（1 轮） | 渲染对拍扩到 D3D11（硬件）与 GLES（真机）作为发布门禁；GPU 批次（C2/C6/C7、C29、C26、C5）；AR-4 代码项 | 4 | **同一 edit-JSON 四路一致** |
| **P4**（滚动） | 长尾：核心 CPU 性能批、端内清理、Windows 目录分组、R10/R11/R13 | 多路（可用轻量模型） | 只剩「延期决策」与「明确不修 + 理由」 |

- **最小可行路线**：P0 + P1 + P2 的 S1/版本表，约 2.5 轮。
- **理想路线**：P0–P4，约 4.5–5 轮。
- **止损点**：P1 结束若 Android/Windows 接入仍未绿 → 停止扩规格只保留向量；代码生成永不主动启动；渲染对拍若 CI 跑不了 WARP/GLES → 只留发布门禁。

### 双轨期间的插队准入（四条同时满足）

1. 不改变跨端用户可观察的编辑语义（涉及则必须在同一 PR 补规格行或向量）；
2. 严重度中到高、关乎 CI 可信度、可能丢数据或有安全问题、或已在飞；
3. 只动单端或单层，且带撤修复变红的锚点；
4. 不碰地基锁定的文件（`Shared/specs|fixtures`、四端 `*Transfer*`/`*Reset*`/`EditorAdjustmentRules*`、正在扩 fixture 的 ABI 头）。

### 最可能失败的三件事

1. **规格层变成第二份真相**：parity 出现 skip/白名单、divergences 不降反升、散文里又出现数值。对策：parity 进快速通道、棘轮 + owner + 到期轮次、规格设 CODEOWNERS。
2. **向量测到适配层而非真实行为**（L2 是先例）：对策强制走生产入口、加「仅测试调用」检查、每个接入 PR 撤回一条规则证明变红。
3. **巨型重构拖垮迭代**：单 PR 除夹具超过约 800 行、schema 重写超过一次、整轮没关掉任何行。对策：按例子写向量、每 PR 必须关掉台账行或带来可演示绿灯。

## 产品决策登记（2026-11-13，用户裁定）

编号说明：Q 编号由本清单合成时引入（两份评审原文没有这个体系）；**Q11 是合成时的跳号，实际共 12 项**，无遗漏。

| 编号 | 决策 | 落地位置 | 关掉的行 |
|---|---|---|---|
| Q1 | **支持 >128MP**：NATIVE 在**解码前**预检，上限取 2.1G 像素的溢出保护；JPEG 65535 单边限制上移到请求验证层 | 核心 `sony2fuji_c.cpp` 校验层 | C-N1、G-N8、C-N2、C14 残留 |
| Q2 | **接受外部 fork PR**：fork 不选自托管平台、Windows 走托管机；`docs/process/ci.md` 写明流程 | #273 已实现；#281 @ 508f8f49 已补托管路由放行与外部 PR 流程文档 | R16、R-N2、R-N3 |
| Q3 | **保留双键**：`raw_level` = 解马赛克前 Bayer FBDD（0/1/2 整数）；`post_rgb` = 渲染后 RGB 降噪（0–1 浮点，同时是 HDR v6+ 现役键）。不支持该键的端收到非 0 值 → **忽略并提示**；精度以字段规格表为准，移动端按 spec 收窄 | `Shared/specs` + 四端 | R17、R7、D-02、D-05 |
| Q4 | **沿用目标处理版本并明确提示**（不拒绝） | `Shared/specs` + 四端粘贴 | 14.8 处理版本行、D-03 |
| Q5 | **HDR 显示映射纳入「HDR 渲染」分组**，支持分组与单项重置 | Mac 重置范围 + 四端；实现 #280 已合入（`83381e8e`，carbon 复审 approve） | 14.6.1d（D-04 归 Q8，勿混引） |
| Q6 | **批量产物保留 30 天 / 100 条；相机原件不自动删、只提供手动清理入口；联机记录保留 90 天** | iOS/Android 存储层 | I1、A2 残留 |
| Q7 | **Android 照搬 iOS 三段抽样**，但先在契约里写明「抽样是跳过下载的依据，不是完整性校验的替代」 | Android A12 + 契约 | A12、L4 |
| Q8 | **限制长边并计入预算** | Mac 参考帧渲染 | M3、D-04 |
| Q9 | **`AgentRecipe` 定位为测试工具**：移进 tests，README 同步改 | Mac/Windows | R18 |
| Q10 | **需要真机验**：I17 先在真实设备上复现，再决定修法 | iOS 真机 | I17 |
| Q12 | **保留文件并提示「已完成」**：提交点之后的迟到取消不删已渲染文件 | Android 导出 + 核心 | A-N3、S5 部分 |
| Q13 | **回滚兼容**：旧版读不懂新枚举时降级为 Idle，不锁编辑区 | Windows `UpdateStore` | W-N6 |
| Q14 | **UI 测试不进 CI 门禁**：改为「不依赖 AX 的表示层断言进模型套件」+ 本地/发布前手工跑 UI 测试；CI 出现 SKIP 仍按不变量 7 记为失败 | Mac/iOS 测试 + `docs/process/ci.md` | L1、E.2#1 |

> 编号说明：Q11 为历史空号，本登记共 **13 项**（Q1–Q10、Q12–Q14）。

## 变更记录

- 2026-11-13 · PR #270（待合入）· M10 / 14.8 行1–3（Mac、iOS）· 实现完成：两端跳过非 RAW 占位值（白平衡三项、旧版降噪、镜头五项全默认时），新增 `Shared/fixtures/adjustment-transfer-scenarios-v1.json`（18 条带目标初始状态的场景）与 `scripts/ci/test_transfer_scenarios.py`（契约测试）。验证锚点：`bash RawLabMac/tests/adjustment-transfer.sh`、`bash RawLab/tests/adjustment-transfer.sh`；逐项撤回时各自 exit 133 并命中 `Scenario <id>: value <field>` 断言；`python3 -m unittest scripts.ci.test_transfer_scenarios`。Windows 与 Android 仍为部分修复（缺口行见 P1-11、P1-12）。
- 2026-11-13 · PR #271（待合入）· L1 · 实现完成：CI 的 macOS 模型套件 `export RAWLAB_REQUIRE_AX=1`，未授权时 `HDRRenditionUITests` 以 exit 1 失败而不是静默跳过。验证锚点：`RAWLAB_REQUIRE_AX=1 bash RawLabMac/tests/hdr-rendition-ui.sh` 应 exit 1；不设变量时应 SKIP 且 exit 0。
- 2026-11-13 · 台账建立 · 基线 `0cf4a88a`（PR #269）· 178 行；已修 43、部分修复 10、进行中 2、需产品决策 7、未修 113、已复核不再成立 3。
- 2026-11-13 · PR #272（待合入）· T-W1（Windows `updateSdk` flaky）· 实现完成：根因是**控制台测试进程没有 `SynchronizationContext`**，`Progress<int>` 回调被投递到 ThreadPool，与内存 store 的微秒级保存竞争后把 `Downloading` 覆盖回内存阶段，导致按阶段注入的 `moveFault` 漏注入。修复为测试内单线程串行上下文 + 按待落盘目标状态注入。验证锚点：`pwsh ./scripts/ci/windows-models.ps1`；撤掉串行上下文可复现原竞态。
- 2026-11-13 · PR #273（待合入）· R16 ＝ R-N2 · 实现完成：fork PR 的选择结果不再包含只有自托管 runner 的 macOS/iOS，Windows 保留在托管机执行。验证锚点：`python3 scripts/ci/test_affected_platforms.py`；撤掉剔除逻辑时 `test_fork_pull_request_leaves_a_consistent_verify_result` 报 `macos finished as skipped, expected success`（即 CI 恒红的真实症状），`test_fork_pull_requests_never_select_a_self_hosted_platform` 同时变红。
- 2026-11-13 · PR #271（待合入，已修订）· L1 · 状态改为**部分修复**：CI 实测发现自托管 macOS runner **没有辅助功能授权**，`hdr-rendition-ui.sh` 在 CI 上一直空跑。改为打印 `::warning::` 注解（CI 可见）并保留 `RAWLAB_REQUIRE_AX`；真正的覆盖要改成不依赖 AX 的表示层断言（新增后续任务）。验证锚点：`RAWLAB_REQUIRE_AX=1 bash RawLabMac/tests/hdr-rendition-ui.sh` 应 exit 1；不设变量时应打印 `::warning::` 并 exit 0。
- 2026-11-13 · 整体方案落地 · 本节优先于 B 表序号：先建 `Shared/specs` 闭环保障（不新建机制），语义层冻结单端修补；其余约 80 行按主题批次双轨推进。P0–P4 见「整体方案」。最小可行路线约 2.5 轮，理想路线 4.5–5 轮。
- 2026-11-13 · 产品决策全部裁定（12 项，Q11 为合成时跳号）· Q1=A、Q2=接受、Q3=保留双键、Q4=A、Q5=A、Q6=按建议、Q7=按建议、Q8=A、Q9=A、Q10=真机验、Q12=A、Q13=A、Q14=B。对应行由「需产品决策」转入可实施。

- 2026-11-13 · #270 合入（`7c883991`）· P0-01（M10 + 14.8 行1–3，macOS/iOS）→ **已修**；Windows/Android 的镜头与白平衡占位仍为未修（P1-11、P1-12）。锚点：`RawLabMac/tests/adjustment-transfer.sh`、`RawLab/tests/adjustment-transfer.sh`、`python3 -m unittest scripts.ci.test_transfer_scenarios`。
- 2026-11-13 · #271 合入（`6e12fd66`）· L1 → **部分修复**：CI 实测自托管 macOS runner 无辅助功能授权，改为 `::warning::` 可见；根治由 Q14 的表示层断言完成。
- 2026-11-13 · #272 合入（`5e5400cc`）· P0-02（Windows flaky）→ **已修**。锚点：`pwsh ./scripts/ci/windows-models.ps1`；根因是测试进程缺 `SynchronizationContext`。
- 2026-11-13 · #273 合入（`992be9d5`）· P1-01（R16/R-N2）→ **已修**。锚点：`python3 scripts/ci/test_affected_platforms.py`；撤掉剔除逻辑时 `macos finished as skipped, expected success`。
- 2026-11-13 · #274 合入（`d5d62af7`）· P1-04（A3）→ **已修**。锚点：`HDRLookImportTest`（5 条）+ 全量 `:app:testDebugUnitTest` 640 条；撤掉修复时 3 条失败。
- 2026-11-13 · #275 合入（`77297393`）· P1-05（I5）、P1-18（I-N1）→ **已修**。锚点：`bash RawLab/tests/hdr-resource-notice.sh`（撤掉每帧赋值时 exit 133，`Fatal error: HDR preview delivery routes missing-resource warnings through the change-only notice`）。
- 2026-11-13 · #276 合入（`57dbea99`）· P1-03（M1）→ **已修**。锚点：`bash RawLabMac/tests/hdr-history.sh`（撤掉修复时 exit 133，`Fatal error: an accepted gain-map preview was reported as changed before target sampling`）。
- 2026-11-13 · #277 合入 · 两份评审、复审、路线图与本台账入库（文档基线）。
- 2026-11-13 · #278 合入（`593b10d2`）· P1-13（C-N4+C-N5）→ **已修**：并发/取消契约页 + 编码期检查点。锚点：`processing_cancellation_tests`；31MP 编码中取消 JPEG 0.94–1.03 ms、PNG 7.72–10.66 ms。
- 2026-11-13 · #279 合入（`de64c3f0`）· P1-22（S4）→ **已修**：ABI fixture v2（functions 95 + enums 23/103 值），ctest 用例 `abi_layout_fixture`。
- 2026-11-13 · PR #280（待评审合入）· P1-02 根治（Q14）+ Q5 落地 · Mac HDR 显示映射「HDR 渲染」分组与单项重置（零新增文案）；CI 模型套件以 `hdr-rendition-reset.sh` 替换 AX 套件；`docs/process/ci.md` 记录 UI 门禁与 SKIP 口径。锚点：撤 `resettingHDR` 分组/工具处理 → `hdr-model.sh` exit 133；identifier 改错/按钮移除 → `hdr-rendition-reset.sh` FAIL。rebase 后 `apple-models.sh macos|ios` 全绿、本地化 22 项全绿。
- 2026-11-13 · PR #281（待评审合入）· P1-01 补查 · fork PR 的 Windows 作业源门禁只放行托管 `windows-2022` 路由（此前 fork 恒 skip 导致恒红）；`docs/process/ci.md` 新增 External Fork Pull Requests 章节（Q2 口径）。锚点：撤托管逃逸条款 → `test_workflow` 的 `windows_runner` 断言红；`python3 -m unittest discover -s scripts/ci -p 'test_*.py'` 99 项绿。
- 2026-11-13 · Q1（D-01）实施完成 · 2.1G 像素上限 + NATIVE 解码前头部预检 + JPEG 65535 上移请求验证；待 carbon 评审通过后开 PR（评审门禁纪律）。
- 2026-11-13 · 前提核查落地 · 三条结论见「整体方案 → 前提核查结论」：字段表区分传输精度与 UI 步长（59/83 分叉）；渲染对拍改手动门禁；P1-① 传输接入免测试入口重构。
- 2026-11-13 · 复审补充入库 · `docs/architecture/architecture-review-addendum-2026-11-13.md`（Android 批量导出恢复可能删除已发布成片、iOS 三段抽样需完整身份确认、存储读取成本与发布对账、对既有结论的修正表；代码基线 `57dbea99`）。
- 2026-11-13 · 流程纪律 · **评审门禁**生效：PR 合入前必须通过独立 review（carbon），纯文档豁免；见「整体方案 → 评审门禁」。
- 2026-11-13 · 执行期补查入库 · carbon brain 汇总（agy-brain）写入 addendum §4：fork 源门禁两事实、前提核查三结论、Q5 前提过时入修正表、D-01 三个残余风险；决策登记补 Q11 空号说明（共 13 项）。
- 2026-11-13 · PR #281 评审结论 · carbon review **approve**（无 blocking）；两条 should-fix 已修：平台作业门禁改整式 `assertEqual` + android 自托管守卫，ci.md 补验章节拆分「被跳过平台」与「重型检查组」两类并补 android 选项。
- 2026-11-13 · #281 合入（`508f8f49`）· P1-01 补查（fork Windows 恒红缺口）→ **已修**；#282 文档基线随之更新。
- 2026-11-13 · PR #280 合入（`83381e8e`）· P1-02（Q14 根治）+ Q5 → **已修**；carbon 复审 approve（0 blocking / 0 should-fix / 4 note），4 条红/绿锚点在独立临时目录逐字复现。遗留 note（后续顺手）：`navigateAdjustment` 延迟闭包末尾补 `normalizeAdjustmentNavigation()`；`requireResetButton` 可加 title 断言。
- 2026-11-13 · PR #283 评审结论 · P1 第①步（Android/Windows 消费共享场景夹具，去写死计数 80/73）carbon **approve**（0 blocking / 2 should-fix / 4 note）；should-fix 已收口（`8c2d08ea`）：例外键细化为 `status:applied`+`changed:<field>`/`status:rejected:<reason>`、Windows `Capture(All)` 实际输出对账、Android `resolveSharedPath` 统一解析。实测分歧棘轮登记：Android 9 条（P1-11）、Windows 6 条（P1-12）。
- 2026-11-13 · PR #284 复审结论 · Q1（D-01）修复版（三态探测/stb size_t/PNG 分片）carbon **approve**（0 blocking / 3 should-fix / 3 note）；收口中：DNG Classic TIFF 715.82M 确定性上限前置为 `INVALID_ARGUMENT`、打开失败不写探测缓存（冷跳过锚点改 `header-50000x50000.png`+absentLut）、800MP mmap 改 `PROT_NONE`+`mprotect`。
- 2026-11-13 · PR #283 合入（`55c4b75c`）· P1 第①步 → **完成**（Android/Windows 传输单测消费 `adjustment-transfer-scenarios-v1.json`、去写死计数、分歧棘轮登记）。P1-11（And，9 条）/P1-12（Win，6 条）生产行为仍「未修」，修复 PR 中棘轮须清空例外条目。
