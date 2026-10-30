# UX-02 批量流程实施计划

> **For agentic workers:** 使用 `superpowers:executing-plans` 由主控逐项实现；只读子代理负责必要探索和最终独立复核。每端先补 RED 回归，再实现并完成原生检查。

**Goal:** 多目标应用进入确认页后自动预检；逐张导出配置完成后，一次“开始导出 N 张”贯通检查、冻结和启动，取消与失败仍可恢复。

**Architecture:** 保留各端现有调整会话、CAS/current guard、逐张快照、journal 和 runner。页面请求 generation 只控制未冻结的检查；freeze 成功后由既有持久任务接管，重试始终绑定同一 job。不新增通用跨端事务框架。

**Tech Stack:** SwiftUI/AppKit、SwiftUI/UIKit、Kotlin/Compose、C#/WPF；共享六语来源。

**Spec:** [交互合同](interaction-contract.md)第2/3节、[总体规划](README.md)、[编辑迭代需求](../../design/editing-iteration/requirements.md)。

## 全局约束

- 实施基线为已授权合入PR #156的 `development@a3d6bded14f963cd8f5f44c11109c747bb978adc`；本功能使用独立 `feature/ui-ux-batch-flow` 工作区。
- 不改C ABI、照片/预设/clipboard/job格式、渲染算法和HDR/AI能力。普通GPU Auto回退与AI仅硬件GPU规则不变。
- 只验证默认字号；保留窄窗、正常设备DPI、六语长文案、键盘、读屏语义与系统返回检查。
- 自动prepare只读。草稿Apply/Discard/Continue Editing必须由用户决定；真正应用才保存与生成历史。
- payload为独立冻结值；取消旧页面请求不能使持久clipboard/preset失效。宿主切图使当前请求失效，不要求原始预设来源照片永远存在。
- partial retry复用同一operation及成功回执；不得重新prepare后重复应用成功目标。skip只影响当前操作，不改变集合选择。
- freeze前取消不得创建journal/job/output；freeze后错误不得遗失job ID或再次冻结。恢复、失败重试和输出不确定态沿用现有发布语义。
- Shared/strings由主控统一维护并生成；不手改原生生成资源。原生检查先于提交，按阶段授权push/PR/合并。

## Review Focus

- 非当前目标的旧prepared payload在宿主切图后仍可能通过target current guard：页面与model均须拒绝旧请求。
- Android prepare/freeze在callback之后才清busy：串联必须在释放本次busy后交付callback，旧finally不能覆盖新任务状态。
- freeze已持久化但后续释放raster/接纳启动失败：必须保留唯一任务并能立即恢复，不能只在重启后找回。
- iOS queued→active和后台窗口、Windows未启动窗口关闭：旧completion不能后台启动，关闭不能删掉新冻结的collection任务。
- 自动流程容易把草稿决定、部分成功重试和原uniform batch合并：保持每条原有保存、取消和放弃边界。

> 阶段状态：Task 1–4 已实现并通过目标级原生检查；Task 5 的源码复核、共享文案与索引已完成，提交、PR、集成等待阶段授权。Android 覆盖320/412dp，未单独重复360dp；Windows有原生WPF与外部UIA证据，未将其扩展为全DPI矩阵。

## Task 1: Mac 自动预检与一次启动

**Files:** `RawLabMac/Sources/Editor/View/AdjustmentTransferView.swift`、`Editor/Model/EditorModel+AdjustmentTransfer.swift`、`EditorModel+BatchSelection.swift`、`EditorModel.swift`、`Export/BatchSelection.swift`、`BatchSelectionView.swift`、`BatchExportModel.swift`；`Shared/strings`。

**Interfaces:** 消费现有 `session.prepare/apply`、`prepareCollectionExport`、`freezeCollectionExport` 与 `attachBatch`。`BatchExportModel.start(_:)`提供明确接纳结果，旧按钮调用可忽略返回值。collection启动入口负责检查请求身份和freeze→attached batch.start；冻结后唯一owner仍为`EditorModel.batch`。

- [ ] 在`BatchSelectionModelTests`补宿主切图后旧多目标prepared不得保存；运行`bash RawLabMac/tests/batch-selection-model.sh`确认RED。
- [ ] 进入/替换目标自动prepare，关闭与sourceRevision变化使旧结果失效；保留错误恢复入口和显式最终应用，检查Preset/Paste/Synchronize action。
- [ ] 补一次启动、checking取消、晚结果、freeze后接纳失败保留同ID的回归。使用现有真实PNG模型fixture验证输出，不用缺ImageIO元数据的微型DNG证明导出成功。
- [ ] 将逐张导出主动作合为一次开始；后台prepare只读取主线程固化的输入，提交前再校验选择/source/edit/look。freeze成功即接管到batch，错误显示在同一任务。
- [ ] 为必要新增操作补共享六语并生成；`python3 scripts/localization/generate.py --check`通过。
- [ ] 运行transfer-session、batch-selection-model、batch-export对应检查和Mac构建；真实默认窗口/950pt操作自动预检、取消、一次启动、失败恢复和逐张不同输出，记录准确source与未覆盖项。

## Task 2: iOS 自动预检与一次性交接

**Files:** `RawLab/RawLab/UI/Editor/IOSAdjustmentTransferView.swift`、`ContentView.swift`、`ContentView+BatchSelection.swift`、`UI/Export/IOSBatchSelectionView.swift`、`Core/ViewModel/RawEditorViewModel+BatchSelection.swift`、`Core/Batch/Execution/BatchExport.swift`及相关测试。

**Interfaces:** 使用现有`resultDelivery`/adjustmentQueue与prepare/freeze；`BatchExportModel.start()`明确报告接纳。created→queued→active先设置onUsage/onDiscard，随后只对本次新job启动一次；查看已有任务不自动启动。

- [ ] 使用现有resultDelivery延迟completion，补取消后不freeze和source变化后旧prepared失效的RED。
- [ ] 确认页自动prepare；单次最终动作串联prepare/freeze并保留草稿处理。checking可取消，freeze后的任务不因sheet消失丢弃。
- [ ] 补queued后台、重复dismiss/promotion、接纳失败回归；断言job ID、pending数量和start次数，不能用model重复start测试替代owner生命周期证明。
- [ ] 改`BatchWorkflow.testCollectionMicroEditAndFrozenConfirmation`为一次开始即可进入runner/结果；保留微调和历史，追加真实iPhone/iPad默认字号横竖屏、文件/Photos目标、取消/恢复证据。
- [ ] 运行受影响模型、build-for-testing及真实UI测试；不把编译测试目标写为执行通过。

## Task 3: Android callback顺序与持久任务接管

**Files:** `editor/EditorCollections.kt`、`EditorViewModel.kt`、`EditorBatches.kt`、`editor/ui/AdjustmentTransferSheet.kt`、`batch/ui/CollectionExportSheet.kt`及现有单测/instrumentation。

**Interfaces:** prepare/freeze callback必须在本次busy清除后交付；freeze桥接必须把已持久job传递/保留到launch owner。`EditorBatches.resume(job,gpuMode)`仅创建model，自动路径还须调用`continueUnfinished()`。

- [ ] 在`AdjustmentHistoryInstrumentedTest.collectionSyncMicroEditDraftSkipAndFrozenNativePreview`的prepare/freeze callback内断言busy=false，确认当前RED。
- [ ] 调整busy释放与completion顺序，补异常路径和直接串联freeze回归，不用等待固定延迟解决顺序问题。
- [ ] payload/target请求身份驱动一次自动prepare，dispose/换目标取消旧generation；保持同operation部分重试。
- [ ] 补freeze journal成功后release raster失败的RED：失败当下pending可找回同ID，继续不重复freeze/复制；再串联单次开始。
- [ ] 私有ADB设备运行对应JVM、instrumentation和实际UI：默认320/360/412dp、Back、后台/恢复、两份真实不同输出；不重启共享ADB。

## Task 4: Windows启动入口与冻结任务关闭语义

**Files:** `RawLabWindows/BatchSelectionWindow.cs`、`MainWindow/BatchSelection.cs`、`BatchExportWindow.xaml.cs`、`MainWindow/AdjustmentCommands.cs`及现有editing/UI checks。

**Interfaces:** 复用已有自动preflight，只修实际状态缺口。提取明确的batch Start API，按钮和collection新任务共用，不能模拟按钮事件。新collection job保留策略不得扩散到普通未启动uniform draft。

- [ ] 用internal构造器已有createEngine factory注入初始化失败，确认collection job关闭后仍可load同ID的断言在当前RED；保持PhotoFeatureChecks原uniform discard断言。
- [ ] 一个最终动作执行Prepare→Freeze→ShowBatch→一次接纳Start；保留输入、冲突和恢复入口，禁止双击和Loaded重复启动。
- [ ] 在`BatchSelectionUiChecks`与外部UIA验证自动预检、一次启动、初始化失败关闭/恢复，及普通uniform draft原放弃行为。
- [ ] 运行受影响Windows模型、默认产品构建和1024×720默认字号键盘/UIA检查，记录正常DPI与实际限制。

## Task 5: 跨端回归与交付

- [ ] 对照本计划Review Focus与交互合同，自查四端显式action、scope、skip、草稿、取消、保存失败、same-job恢复及真实输出；修复有证据的问题。
- [ ] 执行共享文案/契约、受影响快速模型和最终源码对应原生检查；保留RAW/SDR/HDR能力边界，不声称模拟器/VM证明物理HDR或硬件GPU。
- [ ] 由独立reviewer只读核验最终diff与准确source/base，主控复核发现并针对性修正，不做无关重构。
- [ ] 更新总体索引的阶段状态；单PR日志/截图/测量留在临时证据目录及PR说明。
- [ ] 准备可评审结果后按阶段授权提交、push、创建目标development的PR；合入仍须明确授权，不把本地通过当作CI通过。
