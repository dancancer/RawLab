# iOS / iPadOS v4 原生实现与验证

范围：独立 `codex/ios-editor-v4` 本地工作树；以 development `440b9788ff4cfd8a3f5dfa781b16a33997ccd801` 为基线。仅 iOS UI、对应测试与设计文档。最终实现提交 `146fabf`，其前四个本地提交为 `43b03f7`、`c52f59b`、`e190c65`、`b296b00`；文档与复核证据另有本地提交。未推送、创建 PR、合并或发布。

已按用户录屏观察固定中心游标、左右移动刻度、附近刻线短暂抬高后衰减，以及周边工具的淡出和恢复。v4 的具体时间和曲线是 RawLab 设计取值，不是 Apple 内部参数测量。用户视频仅用于本地分析，没有复制进交付附件。

## 实现

- 大师配方保留层叠 SF Symbol；曝光、颜色、HSL、配方、效果、几何与镜头均基于现有能力。
- 44 pt 触控目标、48 pt 常规工具圈；完整参数标题和数值；单标量选中圈内数值、最多 270° 的正负环弧。
- 真正的单列 `UIPickerView` 调整完整数值。iPhone 使用原生 sheet，iPad 使用 popover；短宽弹层将上下文与滚轮并排。草稿与提交值分离，取消不改变参数；应用才提交，变更草稿阻止直接关闭。
- 自绘刻度使用固定游标、13/22 pt 基础高度、最高 28 pt、24 pt 邻域、180 ms 衰减；精调、离散步长、默认点与边界反馈。Reduce Motion 有对应路径；触觉有用户开关与事件门控。
- iPad 普通横屏照片在左、320 pt 参数区在右，竖屏参数区在下；AX 大字体重新堆叠并为照片预留空间。原生数值弹层随窗口和旋转适配。
- 几何、镜头使用 Apply / Cancel 草稿；退出确认提供 Apply / Discard / Continue Editing。活动草稿期间阻止导出，包括未修改和恢复原值的草稿。
- 加载提示绑定真实渲染/尺寸更新状态，没有宣称性能已优化。单张栅格照片支持 JPEG 与 rendered DNG，批量入口维持 RAW 限制。

## 证据与检查

专用设备：iPhone 18 Pro（`6BAF1C5B-C060-46FC-99C5-BEB18F1F7CE1`）、iPad Pro 11 M5（`A9E7D8B6-8145-4E53-A0E7-8791A5EFA14B`），iOS 27 Simulator / Xcode 27。测试使用公共图片，不含用户私有 RAW 或录屏画面。

最新 `build-for-testing` 构建通过，日志 `/tmp/rawlab-ios-v4-finish-compact-build.log`。使用项目 `RawLab/RawLab.xcodeproj`、scheme `RawLab`、独立 derived data `/tmp/rawlab-ios-v4-derived`，`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO`。工作树的忽略目录保留已构建的 `lutools/build-ios/sony2fuji.xcframework` 作为现有 #51 桥接依赖；未改 Shared/lutools 源码或项目架构设置。

以下为多次定向运行的通过记录，不能解释为一次完整套件全部通过：

| 行为 | 已通过的记录 |
|---|---|
| 原生 wheel 正负值、取消、应用、默认值 | iPhone `phone-wheel-final`，iPad `ipad-r3` |
| 刻度标准/精调、合法曝光步长、上下界 | iPhone `phone-controls-r6`，iPad `ipad-r3` |
| 几何取消/应用、退出确认与提交值保留 | iPhone / iPad `layout-r5` |
| 裁剪宽度解锁比例、拖角、旋转保留草稿 | iPhone `phone-r4`，iPad `ipad-r3` |
| 14 个大师配方名称及入口 | iPhone `phone-r4`，iPad `ipad-r3` |
| 暗角高光可用状态、HSL 通道独立值 | iPhone `phone-r4`，iPad `ipad-layout-r5` |
| JPEG 确认页、提交值、草稿禁导出 | iPhone `phone-r4`，iPad `ipad-r3`；活动草稿保护收尾验证另列 |
| iPad 弹层旋转、草稿保留、外部点击保护 | `ipad-controls-r6`；弹层上下文收尾验证另列 |
| 最大 AX 字号、横竖屏可点 wheel、照片可见 | iPhone `phone-ax-r8`，iPad `ipad-controls-r6`；弹层上下文收尾验证另列 |

日志与 `.xcresult` 位于 `/tmp/rawlab-ios-v4-<记录名>.*`。`AdjustmentScaleTests` 54 项通过；既有 presentation 验证通过。没有运行完整旧 UI 套件；旧用例仍有旧滑条/键盘假设。

收尾定向验证：`ipad-finish` 的最大 AX 字号与 popover 旋转 2/2 通过；`phone-finish-sheet` 的 JPEG 确认、应用后的提交值以及未修改/恢复原值的几何草稿导出保护通过。该次运行的 AX wheel 默认值可见性失败，修正系统短宽 sheet 的布局阈值后，`phone-finish-compact` 单项复测通过（86.466 s），保留原生 wheel 可点、上下文元素可达且位于窗口、照片空间和 Cancel/Apply 断言。iPhone 最大 AX 字号横屏的标题、草稿和默认值直接可见，范围通过左侧上下文滚动完整可达；元素可点不等于所有行同时完整显示。Lens 工具在公共 raster fixture 上按原有能力禁用，活动镜头草稿的导出保护已核对源码，但没有以该 fixture 测试 RAW 镜头草稿。

原生截图共 14 张，均来自 XCUIScreen / Simulator，PNG 按目录规则保留在本地，避免二进制截图进入源码历史。这是过程证据集；三张收尾 wheel 截图已更新，普通 iPhone wheel 竖屏保留收尾前版本，最终上下文布局以收尾截图和源码为准。代表截图：

- [iPhone 编辑器](iphone-editor-portrait.png)、[原生数值滚轮（收尾前竖屏）](iphone-wheel-portrait.png)
- [大师配方](iphone-master-recipe.png)、[HSL](iphone-hsl.png)、[几何裁剪](iphone-crop-landscape.png)、[JPEG 确认页](iphone-export.png)
- [iPad 竖屏](ipad-editor-portrait.png)、[iPad 横屏](ipad-editor-landscape.png)、[iPad 数值弹层](ipad-wheel-landscape.png)
- [iPhone AX 竖屏](iphone-ax-editor-portrait.png)、[iPhone AX 横屏](iphone-ax-editor-landscape.png)、[iPhone AX 数值滚轮](iphone-ax-wheel-landscape.png)
- [iPad AX 横屏](ipad-ax-editor-landscape.png)、[iPad AX 数值滚轮](ipad-ax-wheel-landscape.png)

## 独立复核

使用完整 Impeccable 4.5.2 / 官方 engine 0.1.14，以原生 Operate 扩展执行。独立首轮复核逐张读取 14 张原生截图、代码与测试，见 [finish-before.md](finish-before.md)。本轮只修复其两项实质发现：wheel 上下文被裁切、未修改活动草稿仍可导出。唯一一次收尾确认见 [finish-after.md](finish-after.md)；不运行仅适用于 HTML/CSS 的 detector。

## 证据边界

Simulator 不能证明物理震动品质、实际设备帧率或输入延迟。未验证硬件 VoiceOver/Switch Control、完整 RAW 输出正确性、JPEG 保存到系统相册的最终文件。JPEG 测试覆盖确认和取消流程；未把旧 #51 的真实 RAW 测试冒充本界面的新验证。没有交付新的性能优化承诺。
