# iOS 0.8：系统选片后的获取取消验证

基线 `3fa6ed5b9228cc71bf50241bcde3f441a478b3d0`，独立工作树 `/Users/xupeng/mycode/rawtools/.worktrees/ios-editor-v4`，分支 `codex/ios-editor-v4`。本轮只修改一行 iOS 取消逻辑及新增测试/报告，不改 Shared、lutools、macOS、版本总清单或编辑/导出算法。本地提交，未推送、创建 PR、合并或发布。

## 实测缺陷及最小修复

原始代码取消获取时未清空 `selectedPhotoItem`。系统选片 B 已返回、应用仍在等待时，编辑器离开触发 `cancelPhotoImport()`；返回后重选 B，选择值仍等于 B，`ContentView.onChange(of: selectedPhotoItem)` 没有新变化，因而不启动新获取。

原始定向运行失败：`/tmp/rawlab-ios-v08-picker-baseline/picker-cancel-ui.log`，用例 `testReplacementCancellationPreservesEditedPhotoAndDraftThenSamePhotoCanImport`，92.432 秒。日志第 295 行显示 `source=A`、`selectedPhoto=B`、`acquisitionCount=2`，等待同一 B 导入 40 秒超时。此前同一用例的实际选片、曝光 +0.50、脏草稿禁导入、未改草稿保留、取消解锁和迟到文件释放均已通过。没有观察到旧图覆盖新图。

修复仅在 `ContentView+Helpers.swift` 的 `cancelPhotoImport()` 中增加 `selectedPhotoItem = nil`。先撤销请求并取消 task，再清选择；nil 变化经既有 guard 返回，不启动导入。重选同一项重新产生选择变化。

## 真正可达的取消入口

产品在获取期间显示进度并锁定编辑，没有选片后的取消按钮。当前唯一产品取消出口是 `ContentView.onDisappear`；退到后台的 `scenePhase` 处理保存设置，不取消获取。

本轮使用独立 test-only app `com.rawlab.tests.picker-cancel`，实际编译本树 ContentView、UI、Core 和 Shared 源码。通过原生 XCTest 真实点击系统 PhotosPicker，选择三个本地生成的 PNG，以实际 asset identifier 核对选择，而不是调用导入 helper 代替选片。

系统 `PhotoImportFile.load(from:)` 已取得 retained 文件后，测试 continuation 将其扣在生产 `loadSource` 最终取消检查之前。UIKit 容器 push/pop 保留同一个 UIHostingController，触发真实 `onDisappear → cancelPhotoImport`，没有直接调用取消 helper。故覆盖的是**真实系统选片/文件取得 + 应用返回等待 + 生命周期取消**；等待门和承载生命周期的导航容器均为测试设施，不是产品的用户取消按钮，也不是 provider 内部传输等待。

测试专用源副本只有三处插入：onAppear 注册只读状态 getter、onDisappear 取消后记录计数、获取调用包装为等待门。每个替换点要求恰好一次；原始产品文件不注入测试按钮或延时。各输出的 `harness/source-instrumentation.diff` 和 `source-manifest.json` 记录差异、基线及副本内容摘要；修复运行记录基线 HEAD 加这一行本地修改，最终提交的实现/测试与冻结复核副本一致。

## 最小矩阵与断言

| 路径 | 核验 |
|---|---|
| 空态 → 真实选 B → 等待 → 生命周期取消 → 迟到成功 | 请求/task/选择清空、空态保持、无错误、生产取消检查释放真实 retained 文件；之后 C 能正常导入 |
| 旧图 A、曝光 +0.50、活动但未修改的几何草稿 → B 等待 → 取消 → 迟到成功 | A 的来源/revision、预览图像摘要、直方图、完整设置、草稿、工具选择保持；工具/开关在获取期禁用，返回后启用 |
| 取消后重选同一 B | 真正再启动一次系统获取，获取计数 +1，B 正常导入 |
| 取消 B → C 已正常导入 → B 迟到成功 | C 的来源、预览、直方图、设置、状态不回写，B 的 retained 文件由生产取消检查释放 |
| 取消 B → C 已正常导入 → B 迟到注入失败 | C 保持、无旧错误弹窗、不改导入状态；错误处理经过生产请求身份 guard |

脏草稿已通过真实开关操作验证会阻止导入；还原为未改草稿后才能开始上述系统获取。未伪造脏草稿进入不可达路径。

成功门回传原始 source，文件释放由生产 `PhotoImportFile.loadSource` 的取消检查完成。失败门模拟迟到 provider 错误，**先由测试门自行释放持有的文件，再抛合成错误**；它只证明生产错误回调不污染当前请求，不作为生产 provider 失败清理的实测证据。两种门均核对恢复 task 的 `Task.isCancelled`，并保留真实 URL 查询文件已不存在，不用清空 URL 假装清理。

## 本轮执行

Xcode 27.0（27A266a）/ iOS 27 Simulator；专用 iPhone `6BAF1C5B-C060-46FC-99C5-BEB18F1F7CE1`、iPad `A9E7D8B6-8145-4E53-A0E7-8791A5EFA14B`。derived data `/tmp/rawlab-ios-v08-picker-cancel-derived`。测试未使用桌面 CUA、鼠标或主动打开 Simulator 窗口，未重置其他设备。

| 新增用例 | iPhone | iPad |
|---|---|---|
| 首次获取取消、空态和真实迟到文件释放 | PASS，28.613 s | PASS，28.622 s |
| 新 C 不受取消 B 的迟到成功/注入失败影响 | PASS，71.467 s | PASS，74.115 s |
| 旧图/活动草稿保留、同图重新获取 | PASS，52.359 s | PASS，53.145 s |

两端各 3 tests、0 failures、0 skips，均为 `TEST EXECUTE SUCCEEDED`。修复构建 `TEST BUILD SUCCEEDED`。新增三用例包含四个时序场景（迟到成功/失败分别执行），不是旧套件的重复计数。

测试结束后通过宿主只读检查两个测试 app 的真实 `tmp/RawLabImports`，均无残留子目录，记录在各输出的 `retained-files-after-tests.json`；没有删除文件来制造通过。

修复构建：`/tmp/rawlab-ios-v08-picker-cancel-fixed-build.log`。修复运行：`/tmp/rawlab-ios-v08-picker-fixed-phone/`、`/tmp/rawlab-ios-v08-picker-fixed-ipad/`，各含 `harness-build.log`、源副本/差异、`picker-cancel-ui.log`、`.xcresult` 和 xctestrun；驱动日志在同前缀的 `*-driver.log`。真实手势和系统选择记录在 XCTest 日志及 `.xcresult`，没有把 helper-only 断言或默认跳过计入系统集成通过。

重跑命令（使用新输出目录；末尾可附单一 XCTest 方法名）：

```sh
xcodebuild -project RawLab/RawLab.xcodeproj -scheme RawLab -configuration Debug \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,id=<dedicated-UDID>' \
  -derivedDataPath <dedicated-derived-data> ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO build-for-testing
bash RawLab/tests/picker-cancel-ui.sh <built-RawLab.app> <dedicated-UDID> \
  <original.xctestrun> <new-output-directory>
```

需要现有 arm64 simulator 桥接 framework；脚本仅在该设备安装测试 app。普通测试未显式启用 `RAWLAB_PICKER_CANCEL_HARNESS=1` 时明确跳过新增类，不依赖该设备预装测试 app。

默认未启用入口实测为 3 skipped、0 failures，日志 `/tmp/rawlab-ios-v08-picker-default.log` 与 `.xcresult`；这三项跳过不计为系统链通过。

## 独立复核和未达路径

[独立 Solo 复核](../reviews/self-ios-picker-cancel-20261015.md)覆盖冻结 6/6 实现/测试文件及取消调用链，无 Must-fix、无 Should-fix。审查报告保存时运行尚未结束，最终运行结果由本报告与原始日志补齐；审查者未运行测试或发布远端 review。

本轮未取得 provider 自身仍在等待时的取消证据；也未覆盖 iCloud、RAW `PHAssetResourceManager.writeData` fallback、真实 provider 迟到失败、实际多窗口关闭/重新建立或进程被系统终止。测试容器的生命周期动作与产品真实窗口使用不同。解码开始后会改变 source revision 并清活动草稿，不能把本轮“获取阶段保留草稿”外推到解码阶段。

本轮 XCTest 日志与两端所采统一日志没有记录到 `Publishing changes` / `Modifying state during` 警告。查询限定本测试进程最近 30 分钟，输出保存在各运行目录的 `swiftui-publication.log`（log 工具有 uid 查询提示，但退出码为 0、无匹配事件）。此前单次 SwiftUI 发布警告仍未定位；此次没有该记录，不能宣称已根治。

此前 167+13 状态/RAW 结果和普通 picker 打开取消证据保持原记录，本轮未重跑或冒充新增通过。真实触觉、实机帧率及硬件辅助功能仍无设备证据。
