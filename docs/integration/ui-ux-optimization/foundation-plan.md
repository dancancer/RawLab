# UX-03 范围摘要基础实施计划

> **For agentic workers:** 使用 `superpowers:executing-plans` 由主控逐项实现；只读子代理做定位与独立复核。任务 1 完成接口与资源后，平台任务消费同一来源，独立复核后再进入集成。

**Goal:** 四端范围选择与预设详情显示真实数量、分组、逻辑值和保留规则，为快捷应用提供可复用摘要。

**Architecture:** 摘要只读既有 capture payload；Swift 共享 formatter，Kotlin/C# 使用等价 presenter 并消费同一组 fixture。范围编辑使用纯 capture，正式动作继续调用既有保存/clipboard/prepare。

**Tech Stack:** Swift/Foundation/SwiftUI、Kotlin/Compose、C#/WPF、Shared 六语资源。

**Spec:** [交互合同](interaction-contract.md)第 1 节及[总体规划](README.md)全局约束。

## Global Constraints

- 基线 `d2661fc16d2949abb157dd60934eaceadd586d11`；不改 C ABI、payload v1/v2、照片/预设持久化格式和默认处理结果。
- 数量、分组和值来自实际 capture；摘要不保存、不写剪贴板、不记历史，不读照片原文件做显影。
- 不重解释相机自动项、HDR 相对白平衡或 recipe 逻辑值；空范围和捕获错误区分。
- 六语只改 `Shared/strings` 来源并生成；唯一资源 owner 维护。其他 owner 只提资源请求。
- 移动命中区域至少 44 pt / 48 dp；大字号重排/滚动，不缩小文字。
- 不提交、push、创建 PR 或合并；先完成可检查实现与验证，由主控使用用户已有/后续授权交付。

## Review Focus

- all/modified/custom 的结果及空范围必须与本端 capture 相同，切换范围立即更新。
- 相机 WB null 与普通栅格 null 的含义不同，不能显示固定 Kelvin 或数值零。
- HDR 七项和几何的数量/名称准确，不能将相对色温当作 RAW 相机白平衡。
- recipe v3/v4 的逻辑数值、强度和部分应用说明一致；未知 look 保留身份并提示缺失。
- 长名称、曲线对象、六语和大字号不能隐藏确认/返回或截断唯一数值。

### Task 1: 共享摘要、向量与资源

**Owner:** 共享基础 implementer。独占 `Shared/AdjustmentTransferSummary.swift`、`Shared/tests/AdjustmentTransferSummaryTests.swift`、`Shared/tests/adjustment-summary.sh`、`Shared/fixtures/adjustment-summary-v1.json`、`Shared/strings/**` 及生成输出。可在 `RawLab/RawLab.xcodeproj/project.pbxproj` 增加新 Shared 文件的编译引用，不能改其他平台 UI；Mac build 已 glob Shared。

**Produces:**

```swift
struct AdjustmentTransferSummary {
    struct Group: Identifiable { let id: String; let fields: [AdjustmentTransferField] }
    let payload: AdjustmentTransferPayload
    var groups: [Group] { get }
    var count: Int { get }
    var includesGeometry: Bool { get }
    var recipeNote: String? { get }
    init(payload: AdjustmentTransferPayload, locale: Locale = L10n.locale,
         text: @escaping (String) -> String = { L10n.text($0) })
    func valueText(for field: AdjustmentTransferField,
                   lookName: (String, String) -> String?) -> String
}
```

实例持有 locale 和 text resolver，前者只控制数字，后者控制文案；默认使用应用 L10n，测试从生成资源 bundle 注入，不能修改全局 UserDefaults。组按 `looks/light/color/effects/detail/geometry`，字段按 enum 定义顺序；仅包含实际 payload 字段。不新增另一份 scope 选择算法。
`lookName(kind,id)` 返回 nil 时显示类型、稳定身份及缺失提示；neutral 无需 resolver。
数值/对象的显示规则遵循合同，最多两位小数（展示舍入、不回写），单位与标点统一。
`valueText` 使用 `L10n`，formatter 不包含平台 UI 类型；平台标题继续使用既有 field displayTitle。

**Shared vectors:** fixture 顶层为 `cases`，每项 `id/payload/expected`，expected 含 `groups`（id/fields）、`count`、`includes_geometry` 及 `values_zh`（field -> 中文展示字符串）。使用固定 `zh-Hans` locale 与文字 resolver 核对中文；另测 en/de 的文字及数字。覆盖曝光 +0.70 EV、geometry crop/turn、camera WB、raster WB、HDR 七项、recipe v3/v4、curve/grading/wavelet，包括 null 和其他端显式降噪对象两种实际形态；额外检查任意合法字段不会得到 JSON 或 object 占位文本。

- [x] 先写向量与测试，运行 `bash Shared/tests/adjustment-summary.sh`，确认缺少接口/能力的失败原因。
- [x] 实现只读分组与 formatter。existing payload 在构造时已 validate，不放宽 validate。
- [x] 新增必要六语来源与四端 entries；Android 新 key 统一 `adjustment_summary_*`，把对应关系写入报告。复用既有准确词条，避免同义重复。
- [x] 运行摘要测试、`bash Shared/tests/adjustment-presets.sh`、`python3 scripts/localization/generate.py --check`、`git diff --check`。
- [x] 报告 source/base、RED/GREEN、准确接口、资源 key 映射、变更文件与未覆盖；不提交。

### Task 2: Mac / iOS 摘要接入

**Owners:** 本端 owner；禁止修改 Shared 资源。依赖 Task 1 接口与资源。

- Mac 修改 `AdjustmentScopeEditor.swift`、`AdjustmentPresetView.swift`、`AdjustmentTransferView.swift`、`BatchSelectionView.swift` 及相关 `EditorModel+AdjustmentPresets.swift` 的只读预览入口。
- iOS 修改 `IOSAdjustmentScopeEditor.swift`、`IOSAdjustmentPresetView.swift`、`IOSAdjustmentTransferView.swift`、`IOSBatchSelectionView.swift` 及 ViewModel 只读预览入口。
- 新建本端小型 summary view（必要时添加 Xcode 引用），在范围 editor 三模式、预设 list/detail 和 transfer payload 明细中复用。
- `previewAdjustmentPayload(scope:) throws -> AdjustmentTransferPayload`（iOS 另接 `settings: RawSettings`）直接调用本端纯 capture；提交快照和 current/live 一致性按交互合同第 1 节，不调用会保存或改变 reload 状态的 capturePresetAdjustments/copyAdjustments。
- [x] 先补模型/呈现回归证明 modified、empty、capture error 和 HDR 范围，然后实现摘要与确认按钮 gate。
- [x] 跑本端 transfer/preset 定向模型与新增呈现回归。
- [x] 执行实际 Mac UI/iPhone+iPad simulator 检查范围切换、长值与保存，记录精确源和未覆盖。Mac 最终构建的 RAW/HDR、德语窄窗、空选择及取消/复制检查已补齐；iPhone/iPad 检查已通过。
- [x] 交主控核对与独立 task review，不提交。代码复核问题已修正；阶段交付按授权推进。

### Task 3: Android / Windows 摘要接入

**Owners:** 本端 owner；禁止修改 Shared 资源。依赖 Task 1 fixtures 与资源。

- Android 新增 `adjustments/AdjustmentSummary.kt` 并修改 `editor/ui/AdjustmentTransferSheet.kt`、`AdjustmentPresetSheet.kt`、`batch/ui/BatchSelectionScreen.kt`；只读预览来自 `AdjustmentTransfer.capture`，绝不调用 copy 的 VM 方法。
- Windows 新增 `AdjustmentSummary.cs` 并修改 `AdjustmentScopeEditor.cs`、`AdjustmentPresetDialogs.cs`、`AdjustmentTransferPresentation.cs`、`MainWindow/AdjustmentCommands.cs`、`BatchSelectionWindow.cs`；只读预览来自 `AdjustmentTransfer.Capture`。
- Windows 保留 Standard 默认范围；按实际 `SelectedScope` capture 后显示摘要，覆盖 Standard/all/modified/custom 四种模式。
- [x] 先在现有模型测试框架消费同一 fixture；固定中文 locale 验证 expected groups/count/value texts。
- [x] 实现本端 presenter、scope 即时摘要和错误/空范围处理，保留现有字段选择与 commit 行为。
- [x] 跑定向模型、instrumentation/WPF 原生 UI，覆盖默认/大字号与 HDR/SDR。
- [x] 报告真实运行环境、source/base、结果及 `NOT RUN`；主控独立复核，不提交。

Task 2/3 的具体命令和设备由主控分派时固定到任务 brief；本计划不把未运行矩阵视为通过。
