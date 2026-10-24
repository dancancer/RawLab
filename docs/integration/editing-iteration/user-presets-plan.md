# ITER-04：独立用户调整预设

> **For agentic workers:** Use `superpowers:executing-plans`; the coordinator owns
> implementation and default agents provide bounded read-only exploration/review.

**Goal:** 四端提供独立、可命名和持久复用的用户预设，保存和应用沿用 ITER-03 的范围、
草稿预检、条件保存与会话历史。

**Architecture:** 单独的版本化 registry 保存稳定 ID、名称、时间和完整逻辑 payload。
保存使用纯 capture，不改剪贴板；应用将冻结 payload 交给现有 prepare/apply，历史来源
增加 preset。平台只实现本地文件访问与原生界面，不增加第二套参数合并或渲染路径。

**Tech Stack:** Apple 共用 Swift/Foundation 存储；Android Kotlin、Windows C# 按同一 JSON
合同及失败向量实现；沿用 SwiftUI、Compose、WPF 和现有本地化生成器。

**Spec:** [需求第 6 节](../../design/editing-iteration/requirements.md#6-用户调整预设iter-04)、
[技术方案第 6 节](../../design/editing-iteration/technical-design.md#6-iter-04用户预设)、
[原生交互约定](../../design/editor-workspace/iteration-design.md)。

## 基线与 owner

- 从 `origin/development@751f21c5` 创建 `feature/editing-user-presets`，本地快进接入
  `acad800b` 的 ITER-03 依赖；前置 [PR #134](https://github.com/dancancer/RawLab/pull/134)
  尚未合入。此处不改变远端 `development` 或前置分支。
- 主代理负责合同、四端实现、共享字符串、测试接线和最终验证；默认代理只读定位和复核。
- 一功能一 worktree；不改原主工作区的文档或其他功能分支。合入、签名、发布仍按已有授权边界。

## Global Constraints

- `registry_version=1`，每项为 `id/name/created_at/updated_at/payload`；时间用 Unix 毫秒。
  registry 版本与时间仅接受 JSON 十进制整数字面量，拒绝小数、指数、布尔和字符串；
  时间范围为 `0...Int64.max`，不能依赖语言解码器的浮点舍入。
  payload 继续使用现有 `payload_version=1` 和 `scope_version=1`，不另存 native snapshot。
- ID 为独立 UUID；碰撞必须重试或失败，不能按名称、列表长度或位置生成。覆盖和重命名
  保留 ID 与创建时间，删除不影响其他预设或已应用照片。可选 `retired_ids` 保留删除身份，
  防止生成器碰撞后让旧确认命中新条目；缺少该字段时按空集合读取。
- 名称去除首尾空白并规范为 Unicode NFC；规范后按区分大小写的完整名称检测重复。
  空白名称拒绝，重名另存需要不同名称；覆盖和删除必须确认具体条目。
  持久化名称必须已经是 NFC 字节序列；trim 集合固定为 U+0009–000D、0020、0085、00A0、
  1680、2000–200B、2028、2029、202F、205F、3000，不包含 U+2060 或 FEFF。
- payload 的 source identifier 保存为 `preset:<id>`，保留解释所需的 RAW/processing/recipe
  上下文；不保留源照片文件依赖。重命名不改变内容、source identifier 或外观 ID。
- 写入在本端排他锁内重新读取、校验，覆盖/重命名/删除比较确认时的完整条目，避免
  迟到确认覆盖后来修改。整个新 registry 成功原子替换后才更新 UI。
- JSON 对象的重复键（包括转义后同名的键）、未知 registry/条目字段、未来版本、
  重复 ID/名称、非法 payload 失败且保留原文件；
  缺外观由现有应用预检报告。旧预设未包含的新字段保持未选语义。
- 管理操作不编辑照片、不写剪贴板、不新增照片历史。应用沿用现有单目标/多目标
  事务和 retry；preset action 只改变历史来源文案。
- UI 同步提供六语、长名称、大字号、无障碍 ID；原生执行与仅编译分别记录。

## Review Focus

1. 删除其他条目后新建与 ID 碰撞，不能使旧按钮命中另一个预设。
2. 对话框打开后 registry 被其他实例修改，旧覆盖/删除确认不得覆盖新内容。
3. 保存失败、损坏和未来版本不会清空库；失败后重试仍使用明确的原操作。
4. 来源文件删除、配方和外观缺失、未选字段，以及预设/剪贴板等价性保持同一合同。
5. 保存/应用取消和下一次打开不得沿用上次 payload、目标、skip 或 pending action；
   原剪贴板与无变化应用后的 redo 保留。

## Task 1：共享格式与 Apple 存储

**Files:** 新建 `Shared/AdjustmentPresetStore.swift`、`Shared/fixtures/adjustment-presets-v1.json`、
`Shared/tests/AdjustmentPresetStoreTests.swift`、`Shared/tests/adjustment-presets.sh`。

**Interfaces:** `AdjustmentPreset` 为值类型；`AdjustmentPresetStore.list()`、
`create(name:payload:)`、`overwrite(_:payload:)`、`rename(_:name:)`、`delete(_:)` 均 throws；
修改已有条目的参数为确认时的完整 `AdjustmentPreset`。重复名称错误带已有条目。

- [x] 先写失败测试：空库、创建/重启、空白/NFC 重名、覆盖/重命名 ID、删除后创建、
  UUID 碰撞、并发实例、过期确认、未来/损坏/未知字段、原子写入失败保留原文件。
- [x] 实现独立 JSON registry、加锁新鲜读取与原子替换；payload 来源改为预设稳定 ID。
- [x] 运行新 Swift runner，验证共享 fixture 的跨端编码、拒绝行为和源独立性。

## Task 2：Mac 原生预设

**Files:** 新建 `EditorModel+AdjustmentPresets.swift`、`AdjustmentPresetView.swift`；修改
`EditorModel.swift`、`EditorModel+AdjustmentTransfer.swift`、`AdjustmentTransferSession.swift`、
`AdjustmentTransferView.swift`、`AdjustmentDock.swift` 和相应 test source lists。

**Interfaces:** 保存调用 `MacAdjustmentTransfer.capture`；应用调用现有
`prepareAdjustmentPaste` / `applyAdjustmentPaste`，prepared operation 增加默认 `.paste`
的 action 参数，预设显式使用 `.preset`。范围控件由复制与保存共同使用。

- [x] 先写模型回归：草稿/保存失败阻挡 capture、剪贴板不变、删除源后应用、同内容
  clipboard/preset 候选一致、未选字段不变、preset history undo/redo、缺外观阻挡。
- [x] 外观组接入“我的预设”，实现列表/空态、保存名称与范围、重名另存/覆盖确认、
  重命名、删除确认、错误与重试；每次打开重置本次操作状态。
- [x] 构建当前 Mac app，执行模型与实际原生 CRUD/重启/应用/历史工作流，核对隔离配置。

## Task 3：iOS 原生接入

**Files:** `RawEditorViewModel+AdjustmentPresets.swift`、`IOSAdjustmentPresetView.swift`；
`LookPanels.swift`、`ContentView+AdjustmentTransfer.swift`、`IOSAdjustmentTransferView.swift`、
`IOSAdjustmentTransferSession.swift`、Xcode source references 与模型/XCTest runner。

- [x] 复用 Task 1 存储，先测试纯 capture、不改剪贴板、已提交设置与来源失效。
- [x] 在外观组加入原生 sheet，复用字段范围及现有草稿动作和 prepare/apply；
  preset action 进入同一历史，关闭恢复管理列表时不保留上次跳过或待办。
- [x] 运行共享/模型检查、app/test 构建与专用模拟器上的 CRUD、确认、失败恢复、
  重启持久化和应用历史流程；补长名称/六语布局检查。

## Task 4：Android 原生接入

**Files:** 新建 `presets/AdjustmentPresetStore.kt`、`editor/ui/AdjustmentPresetSheet.kt`；
修改 `EditorViewModel.kt`、`EditorState.kt`、`AdjustmentDock.kt`、`MainActivity.kt`、
`AdjustmentTransferSheet.kt`、`AdjustmentTransferSession.kt` 及 JVM/instrumentation 测试。

- [x] 同一 JSON fixture 的读写/拒绝、锁与条件修改先失败后通过；使用现有原子文件模式。
- [x] 保存由纯 capture 产生 payload，应用复用冻结 preflight/history，CRUD 与照片记录隔离。
- [x] 原生 sheet 覆盖命名/范围/确认/错误；运行 JVM、双架构构建/lint及专用 emulator 的
  CRUD/来源删除/重启/应用等价和历史测试，不使用其他任务的 ADB 或设备。

## Task 5：Windows 原生接入及验收收口

**Files:** 新建 `AdjustmentPresetStore.cs`、`AdjustmentPresetDialogs.cs`、
`MainWindow/AdjustmentPresets.cs`；修改 `MainWindow/Tools.cs`、`AdjustmentCommands.cs`、
`AdjustmentDialogs.cs`、`AdjustmentTransferSession.cs` 及 managed/WPF/UIA tests。

- [x] 共享 JSON fixture、原子失败、碰撞与过期确认先失败后通过；纯模型纳入 editing 项目。
- [x] 外观组接入列表和原生命名/范围/确认界面；保存纯 capture，应用同一预检和历史。
- [x] 运行 WPF 与独立 UIA 的 CRUD/重启/缺外观/保存失败/Undo/Redo；六语两字号。
  单独修复已定位的旧 Geometry/Popup 夹具和前台任务预览指示器回归，并定向重验。
- [x] 更新 `Shared/strings/` 并生成资源；执行本地化/CI 契约、独立只读复核及受影响
  组合验证。PR 区分前置依赖、当前源码、原生执行、Hosted CI 与未覆盖设备。
- [x] 保存证据后只清理本任务临时构建、照片副本和设备；不修改原始照片和其他工作区。

## 当前验收边界

Apple、Android 与 Windows 共用 55 组 registry 输入向量；三端解析器拒绝重复键、
非整数字面量、未来版本和损坏内容。各端原生执行记录分别绑定实际源码和构建，
增量模型或解析器回归不将较早 UI 记录改称为最终包的完整验收。

Mac 常规字号工作流已执行，大字号原生截图因桌面锁屏尚未到达；iOS 模拟器和
Android 专用模拟器已完成六语大字号检查。Windows 原生交互、独立 UIA 的源删除/重启/Undo/Redo 已完成；本轮还修复并验证
预设管理窗口与其他窗口失活时的精确输入边界。
真实读屏、移动真机、硬件 GPU 及跨功能 IT-15 联合验收仍单独保留。

Windows 临时工作区、计划任务和移动端专用设备已在证据归档后清理；Mac 待验收的
隔离测试 App、输入副本与其运行依赖保留到大字号检查结束。用户于 2026-10-24 明确要求先推进后续迭代，解锁后统一验证；本批保存为本地
依赖检查点，Mac 大字号仍待统一验收。不推送远端、不建立新 PR，也不将本地提交记为
ITER-04 整项已验收。
