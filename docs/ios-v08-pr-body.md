参数调整现使用完整值原生滚轮和固定中心刻度，iPhone/iPad 按窗口与动态字体布局。几何和镜头改动先预览，明确应用或取消；活动草稿和未完成预览会阻止导出。此 PR 是 iOS 0.8 的客户端实现与定向验证。

## 改动

- 使用单列 `UIPickerView` 调整完整数值；iPhone 使用系统 sheet，iPad 使用锚定 popover，并适配旋转和最大动态字体。刻度提供固定游标、移动刻线、精调、默认值/边界反馈及 Reduce Motion 路径。
- 保留曝光、颜色/HSL、胶片与大师配方、效果、几何/镜头、预览和导出能力；补齐大师配方图标、草稿退出和导出保护。六种语言空状态保留导入操作，去除冗余标题。
- 统一导入期间编辑锁，按请求/来源身份拒绝迟到图像、错误、直方图和完成回调；修复降噪尺寸任务与 DNG 导出逆序时的尺寸重放。
- 取消获取时清空 PhotosPicker 选择，修复取消后同一照片不重新导入。测试专用生命周期容器与等待门不进入产品。

## 范围与依赖

目标为 `development`；准备时远端为 `440b9788ff4cfd8a3f5dfa781b16a33997ccd801`，已包含 [#50](https://github.com/dancancer/RawLab/pull/50) 的 RAW 缓存修复和 [#51](https://github.com/dancancer/RawLab/pull/51) 的透视参数接入。目标是本分支祖先，当前无目标侧分歧或文本合并冲突。

仅修改 iOS 客户端、六语资源、对应测试及 iOS 设计/证据文档。`Shared`、`lutools` 和其他平台源码未改；`DESIGN.md` 保留 macOS 原文，仅增加明确标记的 iOS/iPadOS 扩展。现有跨目录资源引用没有增加。

## 本地验证

| 源码范围 | 结果 |
|---|---|
| UI 实现阶段，最终 UI 提交 `146fabf` | 原生滚轮、刻度/精调、草稿、配方/HSL、iPad/旋转和最大字号的分次定向运行通过；保留初次失败与修复后结果，未宣称一次完整旧 UI 套件通过 |
| 精确 `e63a30f` 的独立 RAW 复验 | 167 状态断言、13 RAW 迟到发布断言、3 组尺寸回归；4 项原生触控和 5 项完整应用 RAW 用例，UI 合计 9/9、零跳过；实际 JPEG 解码 RGBA 与 FINAL 参考一致，DNG 全文件一致 |
| `3fa6ed5` 空状态 | iPhone/iPad 共 4/4 用例；六语言横竖屏、最大字号和 28 次系统选择器打开/取消 |
| `1393423` 获取取消修复 | iPhone/iPad 各 3/3，零失败零跳过；旧图/活动未改草稿保持、同图重选、新 C 不受旧 B 迟到成功/注入失败影响；两端真实导入临时目录无残留 |
| `1393423` 刻度数学回归 | 54 项通过；本轮补存当前源码 stdout |

e63 到当前产品源码仅改空状态布局与取消时清选择，Core/Shared/lutools 无差异。RAW 结果保留精确 e63 归属，未把它写成 139 的重复实测。较早的两项既有 UI 通过不计入精确 e63 的 9/9。

使用 Xcode 27 / iOS 27 的专用 arm64 模拟器及已知 #51 桥接依赖，`build-for-testing` 通过。干净克隆仍须按现有 `bash lutools/build.sh ios` 和 `verify-framework.sh` 构建/验证 framework；本轮现有测试 framework 只有 arm64 device/simulator 两片，不作为已完成通用发布包验收。当前没有本分支的托管 CI 结果。

## 后续验收边界

以下保留为明确跟踪项，不阻止现在进入代码审查：

- 获取测试包含真实系统选片和本地 transferable 返回，等待门位于返回之后，通过实际 `onDisappear` 取消；未覆盖 provider 内部仍等待、iCloud、RAW resource fallback 或真实 provider 迟到失败。注入失败由测试门先清文件，不作为生产 provider 失败清理证据。
- 实际多窗口关闭/重建、系统终止、签名真机安装、物理触觉、实机帧率/输入延迟、硬件 VoiceOver/Switch Control 仍需设备验收。
- e63 的 JPEG 成功提示关闭后出现过一次 SwiftUI `Publishing changes from within view updates` 警告（`RawExports.log:363`），来源未定位；输出比对和后续 Reset 均通过。当前取消流程所采日志无该记录，不代表已根治。

PR 创建后仍须核对实际源/目标 SHA、托管检查和目标移动后的受影响组合；本地无冲突不代替这些门禁。发布包的签名、依赖/许可和真机验收单独记录。

## 证据

- [完整提交、范围、依赖与验证来源](https://github.com/dancancer/RawLab/blob/codex/ios-editor-v4/docs/ios-v08-pr-readiness-2026-10-15.md)
- [原生 UI 实现和历史定向记录](https://github.com/dancancer/RawLab/blob/codex/ios-editor-v4/.impeccable/review/ios-editor-v4/README.md)
- [导入锁与异步状态记录](https://github.com/dancancer/RawLab/blob/codex/ios-editor-v4/docs/ios-v4-import-lock-verification-2026-10-14.md)
- [系统选片后的获取取消与同图重选](https://github.com/dancancer/RawLab/blob/codex/ios-editor-v4/docs/ios-v08-picker-acquisition-cancel-2026-10-15.md)

上述源码链接在源分支获批推送后可用。原生截图和 `.xcresult` 是本地过程证据，未随源码提交，README 中的本地 PNG 链接不是已交付的远端附件。完整独立 RAW 报告由协调任务保留，准确报告提交及本地证据位置列于准备记录。
