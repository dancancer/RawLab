# UX-01 当前照片预设实施计划

> **For agentic workers:** 使用 `superpowers:executing-plans`。主控实现代码；只读子代理负责有边界的定位与复核。先完成 Mac 的正常、取消和冲突路径，再顺序接入其他平台。

**Goal:** 用户在照片持续可见的参数区选择预设，一次操作自动检查并应用到当前照片；成功保存后可撤销，异常保留具体原因和重试。

**前置：** M1 范围摘要完成原生验收，并按授权集成到 `development`。前置已由 [PR #155](https://github.com/dancancer/RawLab/pull/155) 集成，实施基线为 `a6626f483cda246e9688a0b049b6ec10f3e1325a`。

**范围调整：** 按用户 2026-10-30 的明确要求，后续仅使用默认字号，不再适配或检查大字号；既有大字号结果仅为历史记录。

**状态：** UX-01 四端代码、独立复核和受影响原生验证已完成，等待阶段交付授权。UX-02 另行细化，不将其记为本项已完成。

**Spec:** [交互合同](interaction-contract.md)第 2 节；[总体规划](README.md)的范围、平台矩阵、授权和验证要求继续适用。

## 1. 不变项与设计决定

- 复用现有 preset payload、prepare、CAS、history 和 source validator，不增加照片或预设存储字段。
- 外观工具行的“我的预设”切换当前参数区内容。列表与照片同屏，使用已有面板的滚动和高度预算；新增、改名、删除仍在原生管理页完成。
- 列表头提供“管理预设”和“保存当前调整为预设”。空库提供同一个保存入口；库读取失败显示原因和重新载入。
- 每行显示名称、M1 分组摘要和“应用到当前照片”。详细数值在按需展开的 M1 摘要中查看；列表可以滚动，不让大库撑高整个编辑器。
- “应用到多张照片”作为独立菜单动作进入既有目标页。此项在 UX-02 统一完成自动预检；UX-01 不同时重写多目标流程。
- HDR 仍可使用预设。外观组因此允许打开预设子面板；胶片、配方及不支持的算子继续按原能力禁用，不因预设入口而开放 HDR 不支持的编辑。
- 预设面板是否打开是临时 UI 状态，不写入照片。切换其他工具/组关闭该面板并使正在检查的请求失效；关闭管理页后重新读取库。
- 使用稳定 preset ID 和捕获的 payload；操作期间重命名/删除预设不改变已经发起的请求。

## 2. 单次操作的状态与保存边界

| 状态 | 可见信息与动作 | 写入边界 |
| --- | --- | --- |
| 浏览 | 预设列表；管理、保存、应用 | 无照片写入 |
| 检查中 | 正在检查所选预设；取消；禁止第二次提交 | 只读 prepare，不创建历史 |
| 已保存 | 预设名、已保存、撤销 | 只提交当前照片的一次事务 |
| 未变化 | 预设名、未变化 | 不创建空历史，不清空有效 redo |
| 待处理 | 缺外观、模式不兼容、草稿、版本或保存失败的具体原因；重试/取消 | 未提交时保持原照片；已写入但当前视图恢复失败沿用现有明确提示 |
| 已撤销 | 预设名、已撤销 | 撤销绑定本次 transaction ID，并走已有 history guard |

请求在正式 prepare 前解析合法精确输入、保存普通调整，并通过已有草稿“应用/放弃/继续编辑”分支。
不能为了进入预设列表就提交草稿；只有用户发起应用/保存时进入该前置。

取消的无写入边界从上述前置完成后开始：用户已确认保存的普通编辑或应用的草稿可以产生自身历史，
取消不能保存预设 candidate、创建本次预设历史或更改这次请求的撤销状态。回归先记录前置后的
receipt/history，再发起可控的异步 prepare 并取消；另测纯浏览/直接关闭库完全不写照片。

每个请求持有 preset ID/name/payload、当前照片身份、source/open revision、edit revision 和 generation。
prepare 完成时，先检查 generation、当前身份与版本；有效才调用已有 apply。取消、切图、切模式、
关闭面板或后续编辑均使旧请求失效。已失效的完成回调不能恢复结果提示、落盘或记历史。
需要终止的是提交资格，不要求为了取消而中断共享 native 预检线程。

四端分别提供明确的 `applyPresetToCurrentPhoto` 模型/VM 入口（按语言命名习惯调整大小写），
内部负责单目标准备、generation、回调校验、apply outcome 和 transaction ID。
每次 prepare **显式传入 Preset action**（Swift `.preset`、Kotlin `PRESET`、C# `Preset`）；
这些现有 API 的默认值是 Paste，不能依赖默认参数。新增回归必须断言 history action 为预设。

成功状态必须来自 apply outcome 和已保存 receipt；不能把 prepare 成功作为“已保存”。
撤销按钮只操作本次 transaction；当它不再是有效 history head 时，使用已有冲突/失效结果，
不能改成撤销当前最新的无关编辑。重试重新 prepare，不沿用过期结果。

## 3. Task 1：共享文案与可测状态边界

Owner：主控。精确范围为 `Shared/strings` 来源、生成资源，以及必要的平台状态定义。

- [x] 复用准确的已有文案；仅为“管理预设”“应用到当前照片”“应用到多张照片”和检查/结果状态补缺失六语映射。
- [x] 统一使用 `preset.quick.*` 辅助标识，行标识包含稳定 preset ID；取消、重试、撤销有独立标识。
- [x] 每端使用小型 UI/VM 请求状态；不新建跨平台通用事务框架。
- [x] 在平台现有测试入口先补一次 apply、no-change、取消晚到结果、切图/版本变化、重复提交及按 transaction ID 撤销的回归。
- [x] 生成并核对 30 个资源目录，确认所有新可见文案来自映射。

## 4. Task 2：Mac 首先跑通

Owner：主控。主要文件：`RawLabMac/Sources/Editor/View/AdjustmentDock.swift`、新增同目录紧凑预设视图、
`EditorModel+AdjustmentPresets.swift`、`EditorModel+AdjustmentTransfer.swift`、必要的 `EditorModel.swift` 状态、`AdjustmentPresetView.swift` 入口与本端测试。

- [x] 在 looks 工具行切换预设子面板；保持照片与既有布局、键盘焦点。HDR 打开 looks 时默认进入可用的预设子面板。
- [x] 通过 `preparePresetAction` 复用输入/保存/几何草稿前置；纯浏览不调用它。
- [x] 通过 `adjustmentTransferTargets` 和 `AdjustmentTransferSession.prepare(action: .preset)` 准备单个当前目标；完成回调在主线程验证请求后调用 `applyAdjustmentPaste`。
- [x] 当前照片应用替换原 `applying -> AdjustmentTransferView` 路径；只有明确的多张应用动作继续进入目标页。Mac 的 Film/Recipe/Strength 禁用不再连带禁用预设子面板。
- [x] 从 session 的本次 operation/transaction 和结果生成状态；撤销使用 `changeAdjustmentTransaction(id, undo: true)`。
- [x] 在工具变化、关闭面板、切图/切模式和编辑版本变化时取消当前请求的提交资格。
- [x] 扩展既有 history/preset 测试入口并接入 `QuickPresetModelChecks.swift`；不改 prepare/CAS/history 的数据协议。
- [x] 在实际隔离 Mac 应用检查普通应用、取消、缺外观、脏草稿、撤销、HDR、950pt 窄窗与德语；截图必须包含仍可见的照片。

## 5. Task 3：iOS 接入

Owner：主控。主要文件：`ContentView+Panels.swift`、`ContentView+AdjustmentTransfer.swift`、`ContentView.swift`、
新增 `IOSQuickPresetView.swift`、相关 ViewModel 小型入口与 `RawLab/tests/PresetEditorUITests.swift`。

- [x] 在既有 toolStrip/adjustmentPanel 内切换列表，遵守 iPhone 横竖屏与 iPad 侧栏布局，不把列表变成第二个全屏库。
- [x] 调整 looks 组及参数区的 HDR 父级门控，让预设入口可达；Film/Recipe/Strength 等算子仍不可用。补“预设可达、其他算子仍禁用”的实际 UI 断言。
- [x] 复用 `requestAdjustmentAction` 和 draft exit 前置；当前照片 apply 不再打开手动检查目标 sheet。
- [x] 复用 `prepareAdjustmentPaste(action: .preset)` 的 source/generation/current guard；回调有效后 apply，并将 saved settings 反馈给 ContentView 的绑定。当前照片动作不再设置 `.presetApply` 来打开旧手动目标 sheet。
- [x] 复用 `cancelAdjustmentPreparation`；sourceRevision、工具/面板变化使旧请求失效。不得破坏已有库 sheet 的返回规则。
- [x] 使用本次事务的 history request 撤销；异常及未变化状态都有可见的返回路径。
- [x] 在专属 iPhone/iPad 运行一次应用、取消、保存失败、切图、HDR 与默认字号下的长译文；检查列表/按钮至少 44pt，照片持续可见。

## 6. Task 4：Android 接入

Owner：主控。主要文件：`AdjustmentDock.kt`、`EditorScreen.kt`、`MainActivity.kt`、必要的 `EditorViewModel.kt` 小型请求包装、新增紧凑预设内容及对应测试。

- [x] 用 looks 参数区列表承载预设，管理页保留 `AdjustmentPresetSheet`；入口与草稿处理仍由 EditorScreen/MainActivity 负责。
- [x] 发起应用时冻结 payload、当前 photo 和 generation；复用 `prepareAdjustmentPaste(action = PRESET)` 与 `applyAdjustmentPaste`，替换 MainActivity 当前照片动作设置 `AdjustmentSheet.PASTE` 的分支。
- [x] 调整 HDR 下 looks 组和父参数区门控，仅让预设子面板可达；胶片/配方算子继续禁用并有明确状态。补同一页面的可达/禁用断言。
- [x] 消费 prepared state 时核对它属于本次快捷请求；关闭面板/切图调用既有关闭 operation 路径，不接收其他操作遗留的 prepared state。
- [x] 通过 applied outcome/transaction 显示结果和撤销，保留异步提交忙状态与完整错误。
- [x] 扩展 `AdjustmentPresetUITest`、`AdjustmentPresetLayoutTest` 与必要的 history instrumentation；验证 320/360/412dp、默认字号、长译文、Back、HDR 和重新启动。

## 7. Task 5：Windows 接入

Owner：主控。主要文件：`MainWindow.xaml`、`MainWindow/Tools.cs`、`MainWindow/AdjustmentPresets.cs`、
必要的 `MainWindow/AdjustmentCommands.cs`、新增紧凑列表控件及 WPF/UIA 测试。

- [x] 在底部 AdjustmentPanel 内切换预设列表，保持照片可见；不要继续用独占模态库作为快捷应用入口。
- [x] HDR 下预设入口独立于被禁用的 FilmCategory，能够直接打开预设子面板；Film/recipe 能力规则保持原义。
- [x] 复用 `PrepareAdjustmentCommand`、`PrepareAdjustmentTargets(action: Preset)` 与 session apply；新增快捷请求取消入口使 `transferGeneration` 失效。当前照片动作替换 `ShowAdjustmentPreflight` 模态路径，仅明确的多张应用保留目标页。
- [x] 只对本次当前照片 operation 自动提交；保留 openRevision/editRevision/file/CAS guard 及 `AdoptSavedEdit` 的保存后恢复校验。
- [x] `AdjustmentPresetUiChecks` 验证单张状态/冲突；外部 `ui-automation/PresetFlows.cs` 使用真实 UIA 执行取消、一次应用和撤销。
- [x] 在交互桌面检查 1024×720、长译文、默认字号、Tab/Enter/Escape、HDR/SDR；截图与 receipt 绑定当前源，不以 RenderTargetBitmap 代替外部 UIA。

## 8. 退出与交付

- [x] 四端最短正常路径只需点击一次应用；没有手动“检查目标”步骤，照片持续可见。
- [x] 所有平台证明取消/旧回调/版本变化不会提交，成功只写一条 history，未变化不写 history，重试重新 prepare。
- [x] 四端 HDR 下能直接进入预设列表；Film/Recipe 等不支持的算子仍禁用；history action 均为 Preset。
- [x] M1 摘要与正式 payload 一致；本阶段未改变渲染、持久化、批量事务或 GPU 规则。
- [x] 独立复核使用实际最终 diff 和运行证据；修正后仅重验受影响流程。
- [ ] 按授权提交、push、创建目标为 `development` 的 PR，核对源提交和 CI；未经授权不合并。
- [ ] UX-02 在本阶段接口稳定后细化并接入；继续复用多目标准备与冻结批量事务。
