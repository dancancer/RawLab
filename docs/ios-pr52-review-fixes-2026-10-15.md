# PR #52：几何源切换预览修复与刻度禁用验证

基线 `683ee98c92d323d6c38f0f09f402357f4649d4e6`，工作树 `.worktrees/ios-editor-v4`，分支 `codex/ios-editor-v4`。本轮只处理两条内部审查候选。只读核对时远端源仍为该提交，目标 `development` 为 `440b9788ff4cfd8a3f5dfa781b16a33997ccd801`。本轮结果先本地提交，未推送或修改远端 PR。

## 已确认的 P2：新照片沿用几何工具时显示已裁切预览

在 13 英寸 iPad 上，A 的几何工具处于未修改状态，导入有裁切持久化记录的 B。导入先按 B 的 committed crop 生成预览；`sourceRevision` 处理只清草稿，几何工具保持选中。恢复 settings 被 `consumeRestoredSettings` 消费，nil 草稿又不触发草稿预览。实际 viewport 已达到 1280，等于导入重设的 preview/requested edge，`updatePreviewSize` 去重返回。裁切框因此叠在已裁切图上，直至另一次编辑触发渲染。

基线动态验证使用专用 iPad Pro 13 M5 / iOS 27：`4FC51998-1D2F-4014-8D97-E2344677D87F`。实际 ContentView 的三轮源切换均命中 1280；35 项断言中 29 通过、6 失败。失败仅为每轮的未裁切预览像素和 comparison geometry。无修改 Apply、Cancel、修改后 Apply 的设置、持久化及 JPEG 对照均通过，当前证据支持这是编辑预览问题，没有观察到裁切设置或输出损坏。

`ContentView.swift` 的产品改动只有 4 行：保留几何工具选择，源完成且 VM 不忙时显式调用 `updatePreview(settings: draftPreviewSettings)`。该设置使用完整画幅供裁切框编辑；实际裁切仍由原来的 settings/nil draft fallback 提供。导入开始的 revision 因 busy 跳过；完成后直接调用 VM，避开 UI `isImporting` 尚在清理时 `previewEditorDraft` 的 busy guard。没有修改 Apply、Cancel、持久化或导出算法。

## 定向回归

`GeometrySourceHarness.swift` 编译本树实际 UI、Core 与 Shared，承载实际 ContentView。测试副本只在 onAppear 启动任务、在原 viewport callback 旁记录边长；没有替换 `.onChange` 或恢复/渲染实现。测试用生成的 2400×1600 PNG 和独立 EditPersistence，经真实 `importImage` 及 settings 恢复回调进入流程；这次起点是 ViewModel 导入，不是 PhotosPicker 获取。

三轮依次验证无修改 Apply、Cancel、修改后 Apply：恢复 B 的设置、几何工具仍选中、裁切框取 B crop、无脏草稿、实际边长 1280、预览等于独立完整画幅参考、comparison 使用完整画幅、最终设置与持久化正确、JPEG 解码后与独立 committed-settings 参考一致。修改轮还核对草稿确实变脏且预览继续保持完整画幅。预览和 JPEG 参考必须非空，避免两侧 nil 相等假通过。

| 运行 | 结果 | 证据 |
| --- | --- | --- |
| 基线产品 + 初版定向 harness | 1 项 XCTest 失败；29/35 检查通过，6 项预览检查失败 | `/tmp/rawlab-pr52-geometry-baseline/geometry-source.json`、`geometry-source-ui.log`、`geometry-source.xcresult` |
| 4 行修复 + 同一初版 harness | 1/1 XCTest，通过 35/35 检查，20.849 s | `/tmp/rawlab-pr52-geometry-fixed/geometry-source-ui.log`、`.xcresult` |
| 最终修复 + 加强非空断言的最终 harness | **1/1 XCTest，通过 35/35 检查，20.978 s，0 failures / 0 skips** | `/tmp/rawlab-pr52-geometry-final/geometry-source.json`、`geometry-source-ui.log`、`geometry-source.xcresult` |
| 最终 Xcode 产品与 XCTest 增量编译 | `TEST BUILD SUCCEEDED` | `/tmp/rawlab-pr52-review-fixed-build.log` |

最终运行目录保存本次转换后的 ContentView/Panel、冻结的 harness 源码、插桩差异、基线 HEAD 和 tracked working diff。基线启动时补正过测试 app 的 scene manifest，最终脚本已包含该配置；没有改产品 manifest。独立只读复核确认最小修复的 busy/恢复顺序、nil draft fallback 和输出参数保持正确；复核者未运行模拟器，运行结果以上述日志为准。

复现命令（输出目录必须新建）：

```sh
xcodebuild -project RawLab/RawLab.xcodeproj -scheme RawLab -configuration Debug \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,id=4FC51998-1D2F-4014-8D97-E2344677D87F' \
  -derivedDataPath /tmp/rawlab-pr52-review-derived ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO build-for-testing
bash RawLab/tests/geometry-source-ui.sh \
  /tmp/rawlab-pr52-review-derived/Build/Products/Debug-iphonesimulator/RawLab.app \
  4FC51998-1D2F-4014-8D97-E2344677D87F \
  /tmp/rawlab-pr52-review-derived/Build/Products/RawLab_iphonesimulator27.0-arm64.xctestrun \
  <new-output-directory>
```

脚本仅安装独立 `com.rawlab.tests.geometry-source` 测试 app，在专用设备执行一个明确启用的 XCTest。默认普通 UI 测试不启用该 harness 时跳过此方法。沿用现有已知 arm64 simulator framework；本轮没有扩展为完整框架发布包验收。

## 候选 2：刻度禁用守卫

[独立动态验证记录](ios-pr52-ruler-disabled-2026-10-15.md)记录实际 SwiftUI hosted production ruler、系统方向键、真实拖动与系统 AX 节点状态。最终 **1/1 XCTest 通过，16.722 s，0 failures / 0 skips**；慢拖动跨越父级禁用后 editing 结束，禁用生效后的数值与写入次数保持，解锁后新拖动可用。禁用后方向键和拖动不写 binding，AX 节点为 Disabled；直接 UIKit AX 方法调用会写，但该直调不等于系统会对禁用节点派发操作。本轮未确认用户可达缺陷，保留 `AdjustmentRuler.swift` 原实现。运行命令与原始日志见该记录。

## 本轮边界

几何动态证据使用本地生成的 raster；本轮不重跑已有 RAW/系统获取取消全套，不将新结果记作新的真实 PhotosPicker 或 RAW 验收。刻度在相同父 `.disabled` 环境验证组件输入契约，完整 app 中各导入/保存/降噪任务的时序和硬件 VoiceOver/Switch Control 没有因此获得新验收。未占用 Mac 真实桌面、未重置其他 Simulator、未改 Shared/lutools/macOS 源码。此前未定位的 SwiftUI 单次发布警告仍保留原结论。
