# M3 照片空间与外观检索实施计划

> **For agentic workers:** 主控使用 `superpowers:executing-plans` 按平台实施；只读子代理做有边界的定位与一次最终复核。按用户要求合并验证，不重复已经通过且源码未变的检查。

**Goal:** 默认字号的小窗口保留可判断调整的照片空间；四端可以按分类、名称和最近使用查找外观，导入入口始终可达。

**Architecture:** 保留现有灰黄原生界面、外观包装图、调整提交和历史。布局偏好和最近外观属于本机 UI 偏好，不进入照片记录；分类/搜索只改变可见列表，不改变已应用外观。Apple 共用纯过滤/最近模型，Android/Windows 使用本端等价实现。

**Tech Stack:** SwiftUI/AppKit、SwiftUI/UIKit、Kotlin/Compose、C#/WPF；现有六语生成器。

**Spec:** [交互合同](interaction-contract.md)第4/5节、[总体规划](README.md)、[紧凑控件](../../design/editor-workspace/compact-controls.md)、[设计体系](../../../DESIGN.md)。

## 全局约束

- 从 `origin/development@a3d6bded14f963cd8f5f44c11109c747bb978adc` 独立开发；UX-02 的 PR #158 按授权合入后，已更新至 `ef21231f5b47da92ee756d318be5122dc51c2e35`，共同入口与共享文案取两阶段并集，组合流程在此源继续验证。
- 用户明确排除大字号；只验默认字号、长译文、窄窗、正常 DPI、键盘/读屏语义和系统返回。
- 不改渲染算法、C ABI、照片/外观/预设格式，保留原始照片、编辑历史、草稿、保存失败处理。
- Mac 950×620 单值编辑画布至少500×300 pt；文件树在宽度<1100且无目录、用户未手动切换时自动收起。用户手动布局选择优先。
- 单值面板自动220 pt；复杂面板保留现有容量和滚动；拖动之后工具切换不覆盖用户高度，提供恢复自动高度。
- Mac 画布宽<760或高<400时直方图使用紧凑入口和原生 popover；不改用户展开偏好。Windows 按实测的1024×720可用空间适配。
- 保留 Fuji/Kodak/Other，增加全部、用户外观、最近使用；名称搜索忽略大小写和重音；空结果可清除搜索。
- 最近最多12个，稳定ID去重，只在外观应用保存成功后更新；删掉或缺失外观从可见最近中淘汰。过滤隐藏当前项时仍保留当前参数，不自动选择首项。
- 所有新增文案在 Shared/strings 来源维护并生成。原生检查通过后才提交；push/PR/合并按阶段授权。

## Review Focus

- 路径随安装目录变化：内置外观最近项使用 builtin 文件身份，用户外观使用现有 managed ID，不能保存绝对 bundle 路径或名称作为身份。
- 保存失败、切图、迟到保存回调不能把尚未保存/不再对应当前操作的外观写入最近；导入后自动选择也必须走成功保存边界。
- 搜索结果为空或当前项被过滤时，不改变 selection、配方和照片；重命名保留稳定身份，删除项不能指向其他外观。
- 自动布局只适用于未手动选择的状态；窄宽来回切换、工具切换、草稿进出和面板折叠不能覆盖手动高度/文件树选择。
- 新的搜索/分类行不能挤掉手机横屏、窄竖屏或桌面底部的完整值、主动作与照片；触摸命中保持44pt/48dp。

## Task 1: Mac 照片空间

**Files:** `RawLabMac/Sources/Editor/View/AdjustmentPanelLayout.swift`、`EditorView.swift`、`AdjustmentDock.swift`；`RawLabMac/tests/PresentationTests.swift`及实际原生界面检查。

**Interfaces:** 调整栏以当前工具的自动高度和可选手动高度计算；纯布局状态负责文件树默认规则及直方图紧凑条件。现有模型、画布缩放、几何草稿和库持久化接口不变。

- [x] 扩展现有 presentation 模型回归：220pt自动单值、复杂内容高度、拖动后切工具不变、恢复自动；文件树空库/有目录/手动偏好；先观察旧行为失败。
- [x] 接入按实际画布尺寸的直方图紧凑入口，完整图放原生 popover；保持 clipping、HDR统计和用户展开偏好。
- [x] 原生950×620和默认窗口检查曝光、曲线/HSL、几何、文件树、拖动/恢复及德/法长文案；记录实际画布尺寸，不用公式代替运行测量。

## Task 2: Apple 外观检索与最近

**Files:** 新增纯模型 `Shared/LookBrowser.swift` 及共享模型测试；Mac `Looks/Film.swift`、`FilmDock.swift`、`EditorModel.swift`、`EditorModel+AdjustmentHistory.swift`；iOS `UI/Panels/LookPanels.swift`、`Core/ViewModel/RawEditorViewModel.swift`、`RawEditorViewModel+LUT.swift`、`IO/RawEditorViewModel+PersistenceAndExport.swift` 和 Xcode 文件引用。

**Interfaces:** 过滤输入为稳定ID、显示名、FilmGroup、是否用户外观；输出保持原对象和原顺序，最近按记录顺序。最近模型接受成功ID与有效ID集合，去重、裁剪12项；持久化独立偏好键。Mac 的稳定ID由 managedID 或 builtin 文件名产生，iOS 沿用 lutID。

- [x] 用纯模型回归固定分类、大小写/重音搜索、空结果、最多12项/重复使用/删项/重命名/重启。
- [x] 固定分类与搜索行，保留横向包装图列表和固定导入；空结果显示清除动作，搜索不触发外观应用。
- [x] 在既有成功提交回执后记录外观变化，失败不更新；加载/切图不当作一次新应用。补成功、失败、恢复后的行为回归。
- [x] 运行共享/本端受影响模型和Apple构建；Mac、iPhone与iPad默认字号检查分类、名称搜索、最近、导入及横竖屏，复用既有隔离原生宿主。

## Task 3: Android 与 Windows 接入

**Files:** Android `looks/FilmGrouping.kt`、`editor/EditorViewModel.kt`、`editor/EditorState.kt`、`editor/ui/AdjustmentDock.kt`、现有 LookLibraryScreenTest/FilmGroupingTest；Windows `FilmGrouping.cs`、`MainWindow/Tools.cs`、`MainWindow/Library.cs`、`MainWindow.xaml`、`EditWorkflow.cs`、必要布局入口及 `tests/looks`/原生UI checks。

**Interfaces:** Android以 `LookChoice.id` 和既有 persist 成功回执记录；Windows以 `CurrentLookIdentity()` 和 `SaveEdits()`成功分支记录。Windows仅淘汰不再有效的ID，不顺手添加新的外观删除功能。

- [x] 同组纯模型回归验证稳定ID、分类/搜索、最近12项与删项行为；分别接入原生列表和保存成功边界。
- [x] Android保留现有参数预算与侧栏；固定导入、分类和搜索不随外观横向滚走。
- [x] Windows先实测1024×720；若照片空间受默认344DIP面板和直方图挤压，按与Mac相同的自动/手动规则提供紧凑面板和直方图入口，保持现有草稿和控件滚动。
- [x] 合并一次受影响JVM/Windows模型与原生检查，实际320/412dp、手机横屏、1024×720、键盘与长文案；不重跑已通过的无关完整测试。

## Task 4: 状态与可达性收尾（UX-06）

复核确认的缺口随本阶段接入，主控继续唯一写入。四端配方卡增加勾选；禁用的 HDR/WB/镜头工具用已有原生 tooltip 或读屏 hint 说明具体原因；iOS/Android/Windows 镜头开关与 Mac 相同，在缺少校准时禁止新开启，但保留关闭已启用值的能力。Windows 批量页重名说明改为可换行的两行，修复默认英文碰撞。没有复现的辅助页问题不扩大修改。

验证集中到现有配方、镜头与工作区宿主，默认字号。与 UX-02 合并后的源码检查共同入口与旧批量目标测试；M4 用同一集成源完成组合验收，源码未影响的硬件证据不重复。

## Task 5: 联合验证与交付

- [x] 共享文案生成和受影响静态契约通过；四端逐项核对搜索不改照片、保存失败不入最近、删除/重命名/重启与布局偏好。
- [x] 独立reviewer只读复核最终diff；主控验证可证明缺陷，集中修正并只重验受影响路径。
- [x] 交付前刷新development；若UX-02已集成，接入其最终源并验证共同入口。更新跨PR索引，单PR日志/截图/测量只留临时证据和PR正文。
- [ ] 默认产品构建和本地受影响原生UI通过后准备可评审PR描述，再按阶段授权提交、push、PR；明确未覆盖硬件GPU/物理HDR边界。
