disposition: fix

输入边界：本次为已批准的 code-led 原生 Operate 扩展，无新 comp／seed 要求；未提供独立 QUALITY BAR 卡，使用指定 iOS 指引及 craft floor。未运行 HTML/CSS detector、构建、模拟器或测试。

## persistence

Pass：`PRODUCT.md` 存在；HEAD 为 `b296b00`。`PRODUCT.md`、`DESIGN.md` 相对 `440b978` 无差异，桌面正文保留。iOS 文档按交付安排等待本次审查后补充。

14 张指定 PNG 均已逐张 `view_image`，包括最新 iPhone 编辑器和普通 wheel。设备、状态及视觉方向符合文件声明，没有缺图、黑屏或损坏证据，故无需 recapture。

日志支持：iPad r6 2/2、iPhone AX r8 1/1 通过；iPhone r6 为 1/2，r4 为 6/8。补充核对后，[phone-layout-r5.log:762](/tmp/rawlab-ios-v4-phone-layout-r5.log:762) 和 [ipad-layout-r5.log:836](/tmp/rawlab-ios-v4-ipad-layout-r5.log:836) 均确认 `testGeometryDraftCancelApplyAndToolExitPreserveCommittedValue` 通过，补齐 r4 几何退出确认失败后的单用例证据。r5 各自完整运行仍分别为 1/3、2/4 通过；以上是后续针对失败项的通过证据，不是一次完整八项全通过的运行。

## fidelity

| 元素／契约 | 状态 | 证据 |
|---|---|---|
| THESIS／照片优先 | match | 普通 iPhone、iPad 横竖屏保留照片主导层级；控件用于观察和调整。 |
| OWN-WORLD | match | 灰黄语言、连续表面、系统控件和功能性黄色均保留。 |
| STORY | contradicted | 几何／镜头草稿期间的导出保护只覆盖“已修改”，遗漏刚进入或恢复原值的草稿。 |
| FIRST VIEWPORT | match | 正常工具圈、完整参数 header、固定中心游标和照片关系稳定。 |
| FORM／v4 刻度高度 | match（源码） | 13/22→28 pt、24 pt 附近权重、每刻度余量及 180 ms 二次衰减与规范一致；静态截图不能证明实测时长。 |
| TYPE | match | SF 系统文本样式、tabular 数值；主 header 完整，AX 必要时分行，圈内放不下使用 glyph。 |
| MATERIAL | match | 真正单列 `UIPickerView`、SF Symbols、原生 sheet/popover；刻度采用适合测量工具的清晰几何。 |
| GROUND | adaptation | 系统深色表面延续中性灰；符合规范允许的语义颜色映射，没有暖奶油或蓝黑漂移。 |
| scalar 数值／≤270° 环弧 | match | 八个单标量选中态显示数值；弧从顶部按正负方向绘制并限制为 0.75 圈。 |
| 多值工具／大师配方 | match | HSL、配方、镜头、几何保留 glyph；配方使用层叠图标。 |
| wheel 草稿／取消／应用 | match | 数值保留在局部 `@State`，只有应用提交；变更草稿阻止直接关闭，没有自定义键盘。 |
| wheel 标题／metadata | contradicted | 标准 iPad 的 Exposure 标题被裁碎；iPad AX 标题／范围不见、Default 下行裁切；iPhone AX 横屏首次展示只见动作和 wheel。源码强制把 wheel 居中，将同一滚动区内的上下文推离可视区。 |
| iPad 布局／AX | match | 标准横屏左照片、右 320 pt 参数列；竖屏在下方。AX 堆叠并保留完整参数标题及照片，源码预留 96 pt。 |
| 几何／镜头返回 Exposure | match（源码） | Apply、Cancel 均返回 Exposure，动作固定于滚动参数区之外。 |
| busy／触觉真实性 | match（源码） | 预览提示绑定真实 rendering/resize 状态；真实设置 Toggle、原生反馈及 125 ms 事件门控存在。没有硬件触觉证明。 |
| 测试可见／可点标准 | match | 保留 12 次滚动、`isHittable` 和中心可见条件；slow＋hold 使用真实 UIKit 手势。≥200 检查限定标准全尺寸 iPad，AX 照片仍要求 ≥80 且 frame 在窗口内。它们没有核验弹层标题／metadata。 |
| 参考真实性 | match | v4 数值、曲线和时长明确属于 RawLab 设计取值；未把用户视频作为 Apple 精确测量。 |

## ceiling

原生 Operate 所需的系统呈现、文字、图标、照片尺度和局部动效已采用；没有需要新增的装饰或视觉概念。收尾尚卡在弹层信息完整性与草稿导出状态。硬件触觉及实际帧率不在 Simulator 证据覆盖内。

## material_fixes

1. 修正 [NativeValueWheel.swift:54](/Users/xupeng/mycode/rawtools/.worktrees/ios-editor-v4/RawLab/RawLab/UI/Adjustments/NativeValueWheel.swift:54)：打开／旋转时的 `.scrollTo(..., anchor: .center)` 不得裁掉参数身份、范围或默认信息；为普通 iPad、AX iPad、AX iPhone 横屏保留完整标题，其他内容以明确顺序滚动可达，Cancel／Apply 持续可达，并复核这三张原路径截图。
2. 修正 [ContentView+Panels.swift:49](/Users/xupeng/mycode/rawtools/.worktrees/ios-editor-v4/RawLab/RawLab/UI/ContentView+Panels.swift:49)：按几何／镜头草稿是否处于活动状态禁用全部导出入口，包括未修改和恢复原值的草稿；目前 `isEditorDraftChanged` 加 `editorBusy` 无法覆盖这两种状态。

## keep

保留照片优先、灰黄语言、48 pt 圈、完整 SF header、单列原生 wheel、固定游标与局部衰减、AX 分行／照片保留及原有严格可见可点断言；修复后按安排补写原生文档，完整保留桌面正文。
