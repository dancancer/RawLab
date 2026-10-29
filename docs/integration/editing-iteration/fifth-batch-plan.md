# 第五批 S2b：参数行、精确输入与刻度窗口

本批的固定面板高度与普通字号单行参数约定，iOS / Android 后续由[紧凑控件规则](../../design/editor-workspace/compact-controls.md)覆盖：底栏按内容有界收紧，所有窗口宽度下标尺独占一行，复杂工具允许内部滚动。本批记录不作为该后续布局的验收标准。

> **For agentic workers:** 按既有四端 owner 分工实施；使用 `superpowers:subagent-driven-development` 的任务/独立评审流程。四端独立 worktree 和不重叠的 owned 路径允许并行，重型构建由协调者错峰。

**Goal:** 完成四端 S2b 参数输入与展示，保留 S2a 导航、重置、保存与 processing identity。

**Architecture:** 控件继续消费本端 spec、有效默认与既有 setter；精确输入持有独立原值和作用域，验证通过才提交。移动端 fine 归面板会话，iOS 只改变刻度可视窗口。无新的跨平台运行时模型。

**Tech Stack:** SwiftUI/AppKit、SwiftUI/UIKit、Kotlin/Compose、C#/WPF；沿用现有 C++ 核心。

**Spec:** [REQ-03/04/05/11、AC-08/09/10/20](../../design/editor-workspace/requirements.md)，[技术方案第 5、6 节](../../design/editor-workspace/technical-design.md)。

## 基线、范围与依赖

- 基线为 `origin/development@fcf90f0f2159c08caea55d86652bb82e6c8c46c7`。S2a 的 #119 → #120 → #121 → #122 → #123 已合入，同源[联合 CI 39736091998](https://github.com/dancancer/RawLab/actions/runs/39736091998) 最终 9 项成功；Android 首轮 runner shutdown 后定向重跑通过。
- S2b 包含参数行、精确值、默认起点填充、单值重置、移动端单面板 fine、HSL 色块/轨道/输入隔离和 iOS 刻度端点。S3 查看/对比、S4 RGB、其他 ITER 项不混入。
- 不重做已完成的六组、范围重置或草稿事务；只补新控件影响的接线与定向回归。设计文件中的旧实现快照不覆盖本批明确需求，不改 manifest 的整体批准/完成状态。
- 协调者独占本计划、总账、共享六语来源/生成输出及必要 CI 接线；Mac/iOS/Android/Windows 原 owner 各自负责本端。平台分支不手改 Shared 或生成资源。
- 复用五个干净隔离 worktree，新分支分别为 `feature/editing-parameter-inputs-coordination`、`feature/editing-mac-parameter-inputs`、`feature/editing-ios-parameter-inputs`、`feature/editing-android-parameter-inputs`、`feature/editing-windows-parameter-inputs`；旧分支保留。

## Global Constraints

- HSL 三轴均 `[-100,100]`；保存仍 axis-major：hue 0…7、saturation 8…15、lightness 16…23。HSL 不显示角度或百分比单位，不改变数值/强度转换。移动端新交互步进 1，Mac/Windows 新交互步进 0.1。
- 参数范围、原有离散步进、温度 reciprocal、有效默认和 RAW/raster 禁用规则由原本端 spec 拥有；不改变 decoder、快照、C ABI、渲染算法、processing identity 或原始照片。
- 原值例外适用于所有合法非网格旧值，不只 HSL：显示和输入初值能还原原值；无实际变化的 Apply/Enter/关闭不调用 setter、保存或预览。新输入必须 finite、范围内且在合法网格上；不得静默 clamp/snap。
- 文本解析保持本端现有 locale 能力；使用数值相等判断原值例外，不因用户只改格式而量化。拖动/滚轮/选择新候选继续按原网格，不全局改变内部 normalize/clamp。
- 桌面保留正常失焦提交合法且有变化输入的既有习惯。Enter 同样提交，Escape 取消；非法文本及错误保留。切工具/色域/照片、隐藏控件或关闭窗口先显式取消未提交文本，取消先于失焦回调；原提交的保存守卫不变。
- 输入会话绑定原 source、工具、axis/channel 和原值；作用域失效后关闭/取消旧输入，不能通过重组后的回调写入新照片或新色域。source 相同数值也必须失效。
- 普通字号采用名称—轨道—数字—外置单位一行；大字号名称/数值一行、轨道另起一行。无单位保留对齐槽。完整文字与数字不靠缩小字体硬塞。
- 数值默认中性色，modified 黄色并有非颜色状态；默认/范围/步进通过精确输入、帮助/AX 可得，不常驻每行 reset/default/range。
- 轨道填充使用同一 `p(value)` 的默认/当前位置区间；色温用 reciprocal。HSL 轨道只作邻色、灰→彩色、暗→亮方向提示，不是像素预测或新算法。
- 单值 reset 复用同一有效默认动作；名称/轨道双击及语义菜单可用，数字输入内部双击保留系统选字。VoiceOver/TalkBack 下不注册冲突的原始双击手势。
- iOS/Android 每个参数面板只有一个 fine 开关，拖动位移灵敏度为 `0.25`，不改变数值、范围、步进、wheel/精确输入。实际切工具/组后恢复 false；不写照片。桌面现有 Shift+wheel 不改成 mobile fine。
- iOS 刻度窗口按实际宽度计算 span，`start=clamp(u-span/2,lower,upper-span)`，indicator=`(u-start)/span`；温度在原 reciprocal 坐标计算。只变可视窗口，不叠加拖动位移，不制造布局引发的值/触觉事件。
- 固定外框仅取决于窗口、字号、安全区/键盘和既有桌面高度；不得依当前 tool、busy、输入错误或 draft actions 改变。标准手机普通字号 HSL 三轴同时可操作；短窗/大字允许内部滚动，固定操作始终可达。
- iOS 最小触点 44×44 pt，Android 48×48 dp；八色单行不足时滚动。保留 Reduce Motion、原触觉边界与原生 focus 恢复。
- 本批实现、评审、验证先本地完成。用户已于 2026-10-22 单独授权 push、建立目标为 `development` 的五个 PR、先合入共享基础，再同步并合入独立复评及各自 CI 通过的消费者，最后核实联合 CI；该授权不包含版本发布。

## Review Focus

1. 同工具、同数值切换到另一照片，旧文本不得落到新 source；由每端输入会话回归覆盖。
2. HSL 旧值 0.5（移动）或 0.05（桌面）只打开/确认、格式变化或切域后不得量化/写盘；由精确输入和真实 UI 回归覆盖。
3. 非零相机默认、reciprocal 温度、正负两侧填充不得反转或重置成固定相机值；由本端 spec/控件回归覆盖。
4. 六语长标题、标准窄竖屏、大字/短横窗须完整显示值、单位、触点及末项；统一预算不能随工具变化。由每端矩形与截图验证覆盖。
5. 单值 reset/精细模式不得绕过几何输入有效性或保存/精确预览门控；由既有 draft suite 的受影响子集覆盖。

## 资源合同

共享资源先冻结，四端消费同一提交。动态参数传本端已经本地化的完整数字（帮助中的单位可附于参数），不把翻译字符串作为状态 ID。

| Shared source | Swift key | Android resource | 参数 |
| --- | --- | --- | --- |
| `请使用 {0} 的步进。` | `请使用 %@ 的步进。` | `editor_numeric_step_error` | step |
| `默认值：{0}；范围：{1} 至 {2}；步进：{3}。` | `默认值：%@；范围：%@ 至 %@；步进：%@。` | `editor_numeric_help` | default/min/max/step |
| `{0} · {1}` | `%@ · %@` | `editor_parameter_pair` | channel/axis 等已有名称 |
| `双击名称或轨道恢复默认值。` | 同 source | `editor_numeric_reset_hint` | 无；普通指针帮助，不作为读屏激活指令 |
| `拖动灵敏度为普通模式的四分之一。` | 同 source | `editor_fine_hint` | 无；移动端 |
| `色相：向相邻颜色偏移。` | 同 source | `editor_hsl_hue_direction` | 无 |
| `饱和度：从灰色到彩色。` | 同 source | `editor_hsl_saturation_direction` | 无 |
| `明度：从暗到亮。` | 同 source | `editor_hsl_lightness_direction` | 无 |

Windows key 使用 Shared source 的 `{n}` 格式。Apple `formats` 依参数顺序为 `%@`，Windows 为 `{0}`…；Android `file=editor_strings.xml`，`formats=%1$s`…，`types` 均为 `s`。fine hint 只映射 iOS/Android；其余七项映射四端，reset hint 只在普通指针/触摸帮助使用，不提示读屏用户用原始双击。六语值只维护在 `Shared/strings/common/catalog.json`，四端 `entries` 是上述 key 映射的可检查交付物，不在计划复制一份译文。已有“精细”“已调整/未调整”“请输入有效数字”“请输入范围内的有效数字”和单值 reset、轴/色域名称继续复用；不重新整理旧翻译，不增加八色×三轴笛卡尔积 keys。

## Task 0: 共享资源、计划与交付编排

**Owner:** 协调者。

**Files:** `Shared/strings/common/catalog.json`、四个 `Shared/strings/platforms/*.json` 与 generator 产生的对应资源；本计划、`README.md`/第四批验收状态；必要时 `.github/workflows/ci.yml`、`scripts/ci/test_workflow.py`，只补未覆盖的真实测试入口。

**Interfaces:** 提供上表六语文案；不提供新的数据模型或控件框架。平台 owner 提交需要的测试入口，协调者核对现有工作流是否已运行后才改 CI。

- [x] 核对 key/placeholder 的六语和平台映射，生成后执行 `python3 scripts/localization/generate.py --check`、`python3 tests/test_localization.py GeneratorFormatTests GeneratorSourceTests`；若改 CI，先证明缺失入口再执行现有 CI policy/actionlint。
- [x] 更新跨批总账，记录 S2a 已集成的实际源/联合 CI；独立复核本批范围、资源与依赖，选择性本地提交后供四端显式 merge。
- [x] 冻结下面的远端编排及本地重型资源时段；平台 worker 不自行启动同主机全量构建、模拟器或 remote CI。

## Task 1: Mac 参数输入

**Owner:** 原 Mac workspace worker；独立 reviewer 不参与实现。

**Files:** `RawLabMac/Sources/Inputs/ParameterValueField.swift`、`ParameterPrecision.swift`；`Editor/View/AdjustmentRow.swift`、`AdjustmentDock.swift`、`EditorView.swift` 的收起入口；`Controls/MacHSLMixer.swift`、受影响 `DenoiseControls`/`PhotoEffectsControls`；`Geometry/GeometryControls.swift`、`MacGeometryWorkspace.swift`；`Editor/Model/EditorModel+Workflow.swift`、`EditorModel+Geometry.swift` 与 `System/MacGeometryWindowGuard.swift` 中输入取消 seam。测试归现有 `RawLabMac/tests/`。

**Interfaces:** 扩展本端输入 validator/formatter 与 scope invalidation，保留 `ParameterPrecision.snapped/stepped` 的拖动/滚轮用途；继续消费当前 spec/有效默认/既有 binding，HSL setter 保留捕获的 targetChannel。文本焦点与本地草稿不切换渲染交互状态；实际改变值的滚轮手势才进入原交互预览与结束回调。几何 Apply 继续提交并校验文本，等候精确预览；tab/cancel/reset 与关闭先取消未提交文本。

- [x] `parameter-value.sh` 先 RED：min/max、越界、空/NaN/Inf、locale 数字、新非网格拒绝、旧 12.34/tint 3.27/桌面 HSL 0.05 原样无变更；Enter/普通 blur 一次提交、Escape/导航取消零提交、同值跨 source 取消。
- [x] 最小实现严格提交、完整 formatter、输入取消、普通/大字行、默认起点填充、HSL 轨道与横滑和语义 reset；不改 Engine/C ABI/存储。
- [x] GREEN：parameter-value、control-groups、edit-model 与几何输入受影响子集；一次真实 App 构建后批量验证六语 950×620/1440×900、普通/大字、Enter/Escape/失焦/双击/AX/切域，采集完整矩形和截图。只重跑后续实际受影响项。
- [x] 交付完整 diff/源码 hash/验证配置，独立需求与代码复评，修复后按增量绑定最终源码。

## Task 2: iOS 参数行与刻度端点

**Owner:** 原 iOS workspace worker；独立 reviewer 不参与实现。

**Files:** `RawLab/RawLab/UI/Adjustments/AdjustmentControl.swift`、`AdjustmentRuler.swift`、`AdjustmentScale.swift`；必要 `NativeValueWheel.swift` 窄修；Editor/ContentView、Panels、EditorState/EditorDrafts 的 fine/session 接线及现有所有参数调用面板。测试归 `RawLab/tests/`、`RawLab/RawLabUITests/EditorV4UITests/` 及 `RawLab/RawLabUITests/EditorUITests/` 的受影响 reset 调用与驱动；不改 processor/codec。

**Interfaces:** 现有 native wheel 的 original/default 候选和 no-op 行为保留；单面板 fine 向各 ruler 注入，原量化/触觉/Reduce Motion 不变。刻度窗口是本端纯布局计算，不成为新参数数据。

- [x] `adjustment-scale.sh` 先 RED：strength/sharpen 0、HSL ±100、EV ±4、2000/50000K 的端点/中点/变宽窗口；原值 HSL 0.5 的完整显示/候选保留、fine 位移 0.25、布局零 setter/触觉。
- [x] 最小实现统一参数行、面板 fine、HSL 轨道/原 axis-channel 绑定、端点窗口；所有现有 `AdjustmentControl` 调用不得保留隐藏的行级 fine。
- [x] 无 core 的真实控件 harness 优先 RED/GREEN；完整 app 验证前核对 framework source/arch/config/hash 及标准打包所需资源（含 Lensfun 数据库与许可证目录），缺失才构建 simulator slice。专属 iPhone/iPad 模拟器验证取消/no-op/切域/切源、单面板 fine/切组复位、三轴、端点、德语 XXXL 短横窗与焦点/44pt 触点。
- [x] 只复跑本批影响的真实 UI 与草稿输入子集，按实际编译/执行/截图/硬件未验分别交付，再独立评审。

## Task 3: Android 参数行与输入会话

**Owner:** 原 Android workspace worker；独立 reviewer 不参与实现。

**Files:** 下列生产路径均以 `RawLabAndroid/app/src/main/java/com/rawlab/android/editor/` 为前缀：`controls/AdjustmentControls.kt`、`controls/AdjustmentInteraction.kt`、`controls/HslControls.kt`；`ui/AdjustmentDock.kt`、`ui/EditorScreen.kt`、`ui/EditorTools.kt`；`controls/DenoiseControls.kt`、`panels/PhotoEffectsControls.kt`、`geometry/GeometryControls.kt`。测试在 `RawLabAndroid/app/src/test/java/com/rawlab/android/editor/` 与 `RawLabAndroid/app/src/androidTest/java/com/rawlab/android/editor/`。不拥有 VM 保存/预览、settings/codec/JNI/core。

**Interfaces:** `AdjustmentScale.parse` 严格输入并允许合法 original 例外；`drag/position` 继续处理原网格/reciprocal。NumericControl 本地 draft 以 source/tool/axis/channel 为会话身份，无变化不调用现有 VM setter。

- [x] JVM/Compose 先 RED：旧 HSL 0.5 显示/初值/no-op，空/非finite/越界/新非网格错误，合法新值一次 callback；切 source/channel/tool 取消旧输入；fine 0.25，实际切 tool/group 后恢复 false、未发生导航的 Stay 不复位，两者均零保存/预览；默认两侧/reciprocal 填充。
- [x] 最小实现普通/大字行、单面板 fine、HSL 轨道/语义动作/焦点。统一 `editorDockLayout` 的预算，使标准竖屏普通字号有完整三轴空间；短窗/大字统一压缩导航并内部滚动，不按 tool 调预算，不挤掉照片和固定 draft actions。
- [x] JVM/lint/app/test APK 通过后，专属 ADB/AVD 批量执行 320/360/390/412、普通/1.6、短横窗/侧栏及六语关键布局：标准竖屏普通字号三条 HSL 轴须同时完整可操作，照片区保持可见、固定 draft actions 不被遮挡；短窗/大字末项可滚达且所有工具外框相同。真实 ARW 验 legacy/current 下无变更输入零保存/零预览、合法单轴及 processing identity 保留。
- [x] 同一最终 APK 采集触点/视口/外框与截图，独立评审；真实 TalkBack/GPU 无条件则明确未验。

## Task 4: Windows 严格输入与原生参数行

**Owner:** 原 Windows workspace worker；协调者安排实际 Windows 验证，独立 reviewer 不参与实现。

**Files:** `RawLabWindows/ParameterRow.cs`、`ParameterInteraction.cs`、`ParameterSlider.cs`、`Controls.xaml` 的对应模板；`HslPanel.cs`；MainWindow Tools/Rendering/InteractionExport 及各 panel 的取消/scope seam；必要 `ParameterSpec` UI parser 窄修；现有 editing/editor-shell/tool-groups/transform-ui/ui-details/localization-ui 测试。不改模型 decoder clamp、JSON、Library 或 RenderEngine。

**Interfaces:** ParameterRow 严格验证并保留输入原值/会话；Refresh 不把同 range 的旧 dirty 文本绑定到新 source。Slider UIA 报告完整实际值，SetValue/拖动仍遵守当前范围/步进。

- [x] managed 先 RED：替换旧 `999→100` UI parser 断言为拒绝；覆盖 finite/range/grid/locale、旧非网格/no-op、scope 失效、默认起点与 reciprocal；确认未改变非 UI normalize 用途。
- [x] 最小实现错误保留、明确取消、默认填充、普通/26 DIP 重排、修改标记、名称/轨道双击及 UIA/context-menu reset、数字双击选字；HSL 无单位、方向轨道/完整色域轴值。
- [x] **push 前完成实际 Windows**：在任务独立源码/输出/profile 运行编辑输入、同值换源/切域、Enter/Escape/失焦、invalid geometry Apply guard；批量跑六语×两尺寸×普通/26 DIP 的 24 张 HSL 图及非零默认 WB/曝光/颗粒代表场景。先记录完整 bounds/截图再断言，保留失败现场。
- [x] coordinator 核实 source/hash 与 Windows 构建退出码，独立评审实际截图和代码；crossbuild 不替代 WPF runtime。宽窗若离屏必须明确记录。

## 验证与远端编排：减少重复等待

1. 当前基线已有 exact-source 联合 CI；不为确认同一未改基线重新做全平台冷构建。各端先跑低成本 RED/GREEN，再集中一次 native/UI 矩阵；后续只验证受影响增量。
2. iOS framework、Mac native build、Android native/emulator 不同时争抢本机资源。依赖下载复用主工作区 `.cache/shared`；编译结果只有 source/platform/arch/config 全部匹配才可复用。Windows 使用任务独立目录，不占用或停止 CI runner 工作目录/进程。
3. 有远端授权后先交付真正的共享前置；消费者在前置未合入时保持 draft，已有工作流只跑契约检查。前置合入并同步实际 target 后，再将消费者转为 ready，使正式 CI 的 diff 仅包含本端代码。
4. 消费者各自独立评审与其受影响 CI 通过后按依赖集成；无依赖端不互相充当门槛。目标只增加不重叠平台文件时做增量影响检查，完整 tree 不变的实验不重做。
5. 协调文档与实现一并收口；纯文档无需重跑 native。已有 selector/push 累计未验证变更机制继续使用，不新增跳过失败检查或伪造成功的流程。
6. 阶段 push CI 可以由既有 concurrency 合并到最新目标；最终必须核实同一 source 的联合结果。runner shutdown/服务中断保留日志，工作流结束后只重跑受影响 job；编译停滞先查实时日志，不反复重跑整条流水线。
7. CI 等待期间只记录状态变化与可行动问题，不反复查询已通过的 jobs；服务端整体状态和关键阶段用于判断运行，不把没有新增输出自动判为代码失败。

## 完成门槛

- [x] 八项共享文案和平台映射通过生成/本地化检查，资源合同独立复核；同时补齐 Mac 已有“未调整”来源的遗漏映射。
- [x] 四端各自严格输入/原值保留/session/布局及本平台专属行为完成，本批相关真实 UI 证据与独立评审闭合；范围外检查缺口在总账保留。
- [x] Windows 实际 WPF、iPhone/iPad 模拟器、Android 私有模拟器和 Mac 原生界面在本地交付阶段完成；移动真机、真实读屏和硬件 GPU 未覆盖。
- [x] 当前实现已选择性本地提交；获单独授权后已建立 [#124](https://github.com/dancancer/RawLab/pull/124) 共享基础、[#125](https://github.com/dancancer/RawLab/pull/125) Mac、[#126](https://github.com/dancancer/RawLab/pull/126) iOS、[#127](https://github.com/dancancer/RawLab/pull/127) Android、[#128](https://github.com/dancancer/RawLab/pull/128) Windows。此勾选仅确认交付入口已建立；各自 head/复评/合入与最终同源联合 CI 结果留在 PR 说明，不提前登记成功。

本批完成只关闭 S2b 对应 AC；S3、S4 与整个 ITER-02 的联合验收继续在总账登记。
