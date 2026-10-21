# 第三批：三端重置提交与草稿保存事务

> 执行方式：沿已授权的协调者 + 平台 worker 实现 + 默认代理独立核验。执行者使用 `superpowers:subagent-driven-development`；各任务先记录行为 RED，再实现与验证。

**目标：** 将第二批的 iOS、Android、Windows 纯重置候选接入本端提交边界，保证草稿只有保存成功后才提升为 committed、清除并离开。

**架构：** 保留每端当前状态 owner、现有同步保存和预览调度器。普通参数重置仍一次走原编辑入口；草稿应用使用现有存储返回成功/失败后提交。无需为了设计文档中的“异步结果”措辞新增协程或异步 writer；未来异步化仍须保持相同源/版本及提交顺序约束。

**Spec：** `docs/design/editor-workspace/technical-design.md` 3.1、4.1、4.2、6；总账 `docs/integration/editing-iteration/README.md`。本批只交付提交边界和现有草稿入口的必要修复；六组布局、HSL 展示、对比/直方图属于后续 UI 批次。

**基线：** `development@bff2b8602b913a08676e04ab7f1109a148f68834`。#110–#114 均已通过最新源提交的独立评审和 CI，并按顺序合入；五个源提交的远端 ancestry 已验证。合入后的联合 CI 39604481132 已通过四端及汇总门禁，不将其外推为未执行的设备/GPU 或第三批事务验证。

## 当前交付状态

三端源码与对应本地验证、独立评审均已完成，尚未 push 或创建第三批 PR。此处的本地结果不代表 hosted CI 或整体 ITER-02 已验收。

| 分支 | 本地提交 | 当前证据与缺口 |
| --- | --- | --- |
| `feature/editing-ios-reset-transactions` | `5e422ea6` | 真实 simulator ContentView、VM 及模型回归通过；真机与 hosted CI 待验证 |
| `feature/editing-android-reset-transactions` | `b8d8e00b` | JVM、lint、ARM64 app/test 编译及约定 RAW 的实际 instrumentation 通过；物理设备、强制 GLES 与 hosted CI 待验证 |
| `feature/editing-windows-reset-transactions` | `f46a4f37` | managed 运行及完整 WPF 交叉编译通过；真实 Windows WPF/native 运行由已接入的 CI 门禁验收 |

## 公共约束与评审重点

- 普通重置一次状态替换、一次原编辑入口；重置候选 unchanged/blocked/stale 或取消确认均零保存与零渲染。该条件不取消退出几何草稿时恢复 committed crop/比较布局所需的预览。不得把普通 autosave 全改成 persist-first。
- prepared token 固定源身份/源版本、编辑版本、完整 committed 快照及适用的 draft/epoch/context。提交重新核对；同 revision 的 WB 元数据或外观身份变化也必须拒绝。不能只以 render revision 代表 edit revision。
- geometry 组重置只改当前草稿的 geometry+lens pair，不立即写任何 committed 字段。其他 scope 在未解决草稿时阻挡；全量重置等草稿解决后重新 prepare。
- 草稿保存失败保留 committed、draft、旧持久化记录并显示可重试错误；成功后一次提交、清 draft、精确预览，待办导航只执行一次。未改变草稿不可创建保存请求。
- 同步 UI 保存沿现有串行顺序；取消未开始的旧 autosave，成功候选不能随后被旧 committed 保存覆盖。保留实际源路径/identity 的当前检查。
- iOS 保留 `PhotoEditState` 的显式 nil filmID；prepared candidate 保留 timestamp，成功持久化沿既有语义刷新 timestamp。不能为了保存 metadata 再造第二份权威 RawSettings。
- 不改 Shared/C ABI、像素公式、持久化 schema、旧 decoder、配方选择、批量复制及撤销架构。Windows 目录复制 await 旧快照问题登记到 I2/ITER-08，不混入本批。
- 新 UI 仅限现有草稿的应用结果、错误/重试和导航守卫。不把旧直接重置控件提前接成新六组界面。
- 独立 worktree、每端单 owner；公共 CI 只由协调者修改。测试依赖复用主工作区 `.cache/shared/`，任务日志在 `.cache/tmp/editing-native-transactions/`。iOS 创建本任务专属 simulator 并记录 UDID；Android 使用本任务专属 AVD、独立 ADB server 端口与明确 serial，记录 PID，仅关闭自己启动的资源。

## Task 0：协调与验收入口

Owner：协调者。独占本批计划/总账、必要的 `technical-design.md` 同步保存实现说明及 `.github/workflows/ci.yml` / `scripts/ci/test_workflow.py`。

- [x] 核实并记录 #110–#114 合入 SHA；优先复用本任务已合入且干净的各端独立 worktree，从最新 `origin/development` 新建 `feature/*` 分支。若原 worktree 有未保存内容则保留并另建，不能覆盖。
- [x] 将 Windows 现有 `transform-ui` 加入该平台 CI 的 `run-v08.ps1 -Only`，复用现有真实 DNG、WPF 和隔离账号入口；不把仅 managed 测试当 WPF 事务证据。
- [x] 按实际变动补充 CI policy 回归；新改动通过对应 policy 与 actionlint。
- [x] 默认代理逐端完整评审，主线程复核关键调用链与实际结果；源码调整后只复核相关增量。

## Task 1：iOS 提交适配与草稿保存

Owner：iOS worker。

修改范围：`RawLab/RawLab/Core/ViewModel/RawEditorViewModel.swift`、`Core/ViewModel/IO/RawEditorViewModel+PersistenceAndExport.swift`、`Core/ViewModel/IO/RawEditorViewModel+IO.swift`；`UI/EditorState/EditorDrafts.swift`、`UI/Editor/ContentView.swift` 与必要的 `ContentView+Helpers.swift` / `ContentView+Panels.swift` 现有保存重试回调。除首个完整路径外，以上均相对 `RawLab/RawLab/`。允许新增本端 `EditorResetTransaction.swift` 值类型/窄适配文件，并更新 Xcode source list。测试在既有 `RawLab/tests/` / app test target；不得重构整套 ContentView 或 processor。

接口职责：保留 ContentView `settings/settingsRevision` 为当前参数 owner，VM 持有 source revision/identity 和持久化。VM/窄适配提供 prepared reset 与当前 source、revision、完整状态的核对，普通重置交回 ContentView 一次替换；草稿提供可返回 Bool/Result 的候选保存入口，只有成功才替换 UI committed 和激活目标工具。完整原记录 metadata 在 import publication 时随正确 source 留存；保存时以当前 settings 加 metadata 形成唯一完整快照，显式 look 改变需正确同步身份。

- [x] 失败回归：显式 nil filmID + 非 nil lutID 的非外观重置保持 nil；候选 timestamp 不变；旧 source/revision/同版本 WB/context/draft 变化拒绝；普通 reset 无变化零调用、有变化只一次编辑。
- [x] 失败回归：保存位置不可写时 Apply 保持原 settings/draft/记录且不执行待办导航；修复后 retry 成功；已排队旧 autosave 不覆盖成功 candidate；原地 apply/应用并离开各只精确预览一次。
- [x] 在现有 save/pending 链实现这些边界。已保存候选回写 SwiftUI settings 后，observer 不得再次排队保存或重复预览；成功标记绑定源与精确候选，只消费一次，不能吞掉随后普通编辑。保留正常 Photos/Files import 的同步 save gate；当前该路径未证明可达跨源旧保存，不以虚构竞态解释修改。
- [x] 草稿 geometry+lens pair 的 changed/project/应用/取消都同时覆盖两个对象；保留现有裁切 uncropped 投影、exact/resize/import 门控。
- [x] 扩展 `RawLab/tests/RawImportHistoryTests.swift`：复用 `raw-import-history.sh "$APP" "$DEVICE" "$RAW" "$BASE"` 运行真实 VM/queued save/source 测试。扩展现有 `GeometrySourceHarness.swift`，通过 `geometry-source-ui.sh "$APP" "$DEVICE" "$XCTESTRUN" "$OUT"` 在真实 ContentView 验证失败 Apply 与导航。该 test-only harness 已支持 persistence 注入，不新增 production UI 测试开关；删除测试中 Apply 后手动 save 才掩盖提交顺序的依赖。
- [x] 运行 `edit-memory.sh`、`presentation.sh` 及上述实际受影响 simulator/VM 测试。需要本 worktree 的 arm64 simulator app/native framework 和 build-for-testing `.xctestrun`，使用专属大 iPad simulator；纯 macOS Swift harness 不代表 iOS VM 已验证。记录 app/test 编译和实际运行的区别。

## Task 2：Android 提交适配与草稿保存

Owner：Android worker。

修改范围：`editor/EditorViewModel.kt`、`EditorState.kt`、`AdjustmentDraft.kt`，必要的 `EditorResetTransaction.kt` / `EditorEditStore.kt` 注入 seam；`editor/ui/EditorScreen.kt`、`EditorPanels.kt`、`AdjustmentDock.kt`、`MainActivity.kt` 的草稿回调。测试使用 `src/test/.../editor/` 与已有 `GeometryDraftInstrumentedTest`、`EditorViewModelRaceInstrumentedTest`、`EditorV08Test`。不改 JNI、RenderQueue、codec、旧工具 ID。

接口职责：`applyDraft(): Boolean` 仅在 candidate 保存成功并提交后返回 true；UI 的 Apply 和 pendingLeave 依该结果行动。`prepareReset`/`commitReset` 捕获当前 photo identity、独立 edit/source token、完整 edits 和 draft/context；普通 committed reset 只调用现有 `edit` 一次。当前同步 `EditorEditStore.save()` 保留；如需测试失败仅加窄注入，不引入异步 writer。

- [x] 失败回归：草稿保存失败不提升 edits、不清 draft、不离开；旧记录不变、错误可见、恢复存储后同一 draft 可 Apply/retry。失败提示不再被 `draft != null` 隐藏。
- [x] 失败回归：geometry+lens 成对 reset/project/apply/cancel；原单 kind 滑动仍只改对应字段。unchanged draft 不可 Apply 且零保存；changed 仍需 exact、无 resize/render/错误。现有 canApplyDraft 还控制裁切与比例输入，需拆出不含 changed 的 draft-ready 投影，避免空草稿首次无法操作。
- [x] 失败回归：旧 prepared token、不同源、同版本 context/完整快照变化被拒绝；普通 reset 一次编辑提交/一次预览、unchanged 零请求。当前 accept 会在预览后再次保存；对 reset/draft 已落盘且源/request/完整 resolved settings 全相同的候选跳过重复写，真实新增 WB 元数据仍保存，保留普通编辑原语义并覆盖两种分支。
- [x] 实现 token、pair projection 与 save-first draft 路径，复用现有保存失败状态；重试区分普通 dirty 保存和草稿 Apply 失败，不能把原 committed 的保存成功误当草稿已应用。
- [x] 运行完整 `:app:testDebugUnitTest`、lint/app + androidTest 编译。真实 VM 依赖 Android Context/JNI，不能在当前纯 JVM 依赖中伪装验证；复用 `EditorV08Test` / `GeometryDraftInstrumentedTest`，在任务私有 emulator 上通过 `adb -P "$PORT" -s "$SERIAL" shell am instrument -w -r -e class '<full class>#<method>' com.rawlab.android.test/androidx.test.runner.AndroidJUnitRunner` 执行。构建时用 `-PrawlabTestRaw="$RAW"` 提供只进入测试 APK 的样片；不调用会枚举他人设备的 connectedDebugAndroidTest，不新增 Robolectric 依赖。

## Task 3：Windows 提交适配与草稿保存

Owner：Windows worker。

修改范围：`RawLabWindows/EditWorkflow.cs`、`MainWindow.Transform.cs`，必要的独立纯 `EditorResetTransaction.cs` 与 `TransformDraft.cs`；`tests/editing/Program.cs` / csproj、`tests/TransformUiChecks.cs`、`tests/EditorReview/ResizeUi.cs`。不改 `Commands.cs`/旧 reset UI、JSON schema、Library 目录复制或 D3D11。CI 由协调者修改。

接口职责：准备从完整 SavedEdit 捕获 file/openRevision/editRevision/OriginalIdentity、settings/Look、draft generation/context。普通 accepted reset 一次恢复设置和外观并 `MarkEdited()`/Schedule；未修改 Look 时保留原 lut/UI identity 映射。草稿从 committed + transform 的 geometry/lens 构造 candidate，先用现有 EditStore 保存，成功后才 `transform.Apply()`/EndTransform/一次 Schedule；失败 return false 保持 draft 与 committed。

- [x] managed 失败回归：完整快照/Values 隔离、source/edit revision/identity/context stale 拒绝、pair reset 只改 draft、unchanged 零请求。
- [ ] WPF 失败回归：exact draft 就绪后让 editStore 目录不可写，Apply/导航均失败且 committed/draft/旧记录不变；恢复 store 后 retry Apply 成功。继续保留普通编辑保存失败阻止切照片回归。
- [x] 同步“应用并离开”在 dialog 内先保存应用，成功才关闭并继续原 caller 的目的地；失败保留同一 dialog 与可见错误，允许重试，或明确继续编辑/放弃。回归覆盖同 dialog 失败→修复→成功导航一次；返回后不能再次 Apply，不新增通用导航总线。
- [x] Apply 增加 Dirty 门控时，现有 TransformUiChecks / EditorReview.ResizeUi 对未修改草稿的等待改为实际 preview-ready；有变化时继续断言 Apply 启用，不放宽原 exact/render/error 门槛。
- [x] 实现保存候选而不提前 mutation；取消旧 timer，失败保留重试状态，成功不再排一次旧 committed autosave。现有 RetrySave 若针对 draft 失败应重试 draft Apply；普通保存重试语义不变。
- [ ] 运行 managed build + DLL（本机 .NET 共享缓存）；WPF/native build 和 `transform-ui` 必须用真实 Windows CI 结果验收，不能把 Mac managed 通过外推。

## 集成条件

各任务本地提交前完成 targeted RED/GREEN 和源码自查；交给默认代理独立评审，协调者复核实际测试与平台缺口。任务失败或未运行明确保留状态。第三批 push/新建 PR/合入按已有授权边界另行处理：当前第二批五个 PR 的远端授权不自动扩展到第三批。无版本发布、安装包上传或生产部署。
