disposition: ship

本次是唯一一次确认。此 ship 仅覆盖首轮两项实质发现的修复，不代表重新审查整个原生界面。按本次要求保留五节格式；未扩展扫描，未构建、启动模拟器或运行测试。

## persistence

Pass。重读了原路径 `ipad-wheel-landscape.png`、`ipad-ax-wheel-landscape.png`、`iphone-ax-wheel-landscape.png`；三张均为有效原生设备捕获，状态和视觉方向正确，无需 recapture。

`DESIGN.md` 本轮 diff 仅增加原生分区及命名空间明确的 iOS tokens，未删除 macOS 正文。iOS surface brief 与 sidecar 记录了当前 sheet/popover、短宽窗口布局、活动草稿导出保护和 RAW-only 镜头边界。README 已明确 14 图是过程证据集、三张 wheel 为收尾更新、普通 iPhone 竖屏 wheel 保留收尾前版本，没有把全部截图标为最终版本。

## fidelity

| 首轮发现／本次核对 | 评分 | 修复证据 |
|---|---|---|
| 1. wheel 标题／metadata 被自动居中裁切 | resolved | 普通 iPad 截图完整显示 Exposure、草稿、范围和 Default；iPad AX 同样完整。iPhone AX 横屏完整显示标题、草稿及默认值，范围位于左侧独立滚动上下文，完整内容按顺序可达。源码取消自动居中，保留完整内容及固定 Cancel/Apply；该滚动适配符合首轮允许的“完整标题，其他信息按明确顺序滚动可达”。 |
| 2. 未修改活动草稿仍可导出 | resolved | `isEditorDraftActive` 覆盖 geometry/lens 选择态，不依赖数值是否改变。所有导出菜单及 JPEG、DNG、batch 函数使用同一保护。收尾 JPEG 用例验证未修改及恢复为提交值的几何草稿仍禁用导出，取消草稿后恢复导出。RAW 镜头草稿为源码证据，raster fixture 的 Lens 按原有能力禁用；没有伪称其运行验证。 |
| TYPE | match（修复批次） | 三图保留 SF Dynamic Type、完整标题及带单位草稿值，未缩字硬塞；短高度使用上下文滚动。 |
| MATERIAL | match（修复批次） | 单列 UIPickerView、系统 sheet/popover 与原生动作保留，没有自定义键盘或模拟物理材质。 |
| GROUND | match（修复批次） | 三图保留中性深灰和功能性黄色，修复没有改变界面底色。 |
| 文档及测试助手的证据表述 | pass | 新助手保留 `isHittable` 和窗口包含条件，并增加上下文核对；原有 12 次滚动、可点和中心可见标准未放宽。README 准确说明元素可点不代表每行同时完整显示，iPhone AX 范围需上下文滚动读全，没有将窗口 frame 检查当成内部滚动区无裁切的证明。 |

`new_regression: none identified` within this fix batch。iPhone AX 范围在初始滚动区边缘继续，并非信息被删除；它属于初轮明确允许的滚动适配，不需再改变列宽或字号。

## ceiling

Reached for the two scored fixes。标题身份、草稿和默认值可读，紧凑高度用独立滚动保留范围；活动草稿的导出状态与事务语义一致。

已读取的真实定向日志确认：`ipad-finish` 2/2 通过；`phone-finish-sheet` JPEG 用例通过（78.958 s），该次 AX 用例失败；后续 `phone-finish-compact` AX 单项复测 1/1 通过（86.466 s）。这些是多次定向运行证据，不是一次完整套件全部通过。

Remaining evidence limits：Simulator 未证明物理触觉品质、真机 VoiceOver/Switch Control、实际帧率或输入延迟；未运行 RAW 镜头草稿交互验证，未验证 RAW 输出正确性或最终 JPEG 保存文件。上述限制不被本次两项修复的 ship 判定消除。

## material_fixes

None remaining for the two scored fixes。两项均 resolved；未识别该修复批次引入的新实质回归。

## keep

保留完整动态标题、合法单列原生 wheel、固定 Cancel/Apply、短高度的有序上下文滚动、统一活动草稿导出保护，以及真实可点／可见断言和分次运行的准确证据边界。
