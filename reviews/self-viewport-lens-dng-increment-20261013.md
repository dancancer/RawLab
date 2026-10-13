# 视口 / 降噪 / Lens / DNG 合并增量复审

## Must-fix

（无）

## Should-fix

（无未解决项）

两位原评审者发现的 iOS DNG 导出期间 resize 丢失问题已关闭。生产路径
`RawEditorViewModel+IO.swift:437,444` 在成功和失败回调中，清除 busy 并完成导出
回调后，均回放最新 `requestedPreviewLongEdge` 和 `currentPreviewSettings`，与
既有 JPEG 行为一致。DNG 文件仍使用冻结设置和 FINAL 路径。

修复前，真实 tiny raster DNG 成功、缺失源失败两种路径均复现状态断言失败；
修复仅增加两条回放调用，同一测试两分支及既有状态检查均通过。忙碌期间
`1216 -> 896` 和 exposure `0.5` 在完成后正确提交。测试不是手动模拟完成回调，
也未把编译或 Lens 资源缺失当作有效 RED。

## 评审范围

- 模式：self，原两位独立评审者的增量复评，无降级。
- 分支：`feature/viewport-denoise-preview`。
- 原 head：`90809a718b71786308fac750497959cd6e83630c`。
- 合入目标：`d810fe6e47fbc70be79786a8ebaee2d1e9e9fe0e`，正常 merge，不改写历史。
- 代码快照：staged merge，60 个非 Markdown 功能路径。
- 最终源清单 SHA-256：
  `be656f12197be66d1f7eb41b29023511859d724938cffd860b92a4ab7d0b1faf`。
- 色彩契约 SHA-256：
  `9c6d649459bb08062a3d148b9ed6214062d5a266a01e3ab8573d7b7581eba71c`。
- 维度：缓存/状态失效、视口/窗口变化、原尺寸 JPEG/16PNG/DNG、调用及打包边界。
- 两位均覆盖 packet 的 22 个交集/新增路径和相邻调用；旧缓存/内存算法等未变
  路径复用既有评审，未重新开展旧 58-path、2.5 GiB 冷热或 SDK Stage3 全套审计。
- 首轮一致发现一个 Should；主代理沿真实调用核实、测试先行并修复；两位随后只
  复核 IO、状态测试和测试脚本三个路径，结论一致且绑定更新后的源清单。
- 原始用户需求及本轮明确合入范围是规格依据。仓库与平台材料只作为证据。
- 自动评审及 hosted CI：self staged 快照无相应远端结果，不宣称 CI 通过。

## 调用与验证

已追踪 C ABI RAW/Lens/曝光锚点到 wavelet key、视口缩源和 FINAL/FILE 排除条件；
Mac Engine/EditorModel、iOS processor/ViewModel、Android VM/JNI、Windows
MainWindow/RenderEngine 以及各自导出、busy 和过期结果保护。

新增单一真实组合测试硬性要求 Lens 和降噪均实际应用，并覆盖 A/B/A、配置与
数据库 revision 失效、独立视口/完整结果、曝光锚点/报告、原尺寸三格式，以及
PNG/DNG 解码像素和 Force Metal 独立滤波。未用 no-op 降噪冒充组合覆盖。

客户端定向验证、匹配 SDK/Lens/TIFF 的新构建、Mac RPATH RED/GREEN 与实际包内
加载、iOS 测试 app 资源结构和 DNG busy-resize RED/GREEN 已由主代理执行或核对。
评审者均只读，未自行重跑测试。完整结果与 fixture/产物身份见
[组合验证报告](../docs/verification-viewport-lens-dng-integration-2026-10-13.md)。

## 剩余边界

- Android Sony 的 Clean 配方资格失败仍保留；其余三项通过不改记为四项。
  同一原尺寸降噪 JPEG/16PNG 断言在原已证 Panasonic 样本上通过。
- 新 Android 组合客户端运行在 6 GiB 专属 AVD，不代替历史 2.5 GiB 内存门禁。
- Windows 原生 SaveFileDialog/Explorer 流程明确 `NOT REACHED`。
- iOS 当前选定出口没有 16PNG；物理移动设备及 x86 运行未验证。
- 最终多语言联合 source 与发布候选仍由协调者在后续实际合入后验收。

## 建议

可更新已有 PR #27。没有剩余已确认的 Must/Should；不把有限样本/定向门禁扩展
为所有设备、RAW 或发布条件均通过。提交后只需核对源清单与实际 head 的绑定，
无需因提交元数据重新运行已完成门禁。

未发布远端评论、review 或 approval。
