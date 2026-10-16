# iOS 0.8 development 整合验证

本轮在独立工作树 `.worktrees/ios-editor-v4`、分支 `codex/ios-editor-v4` 继续现有 [PR #52](https://github.com/dancancer/RawLab/pull/52)。以正常 merge 接入 `development`，不 rebase、不 force、不修改主工作树。合入由协调任务执行。

## 源码与产物归属

| 项目 | 精确来源 |
|---|---|
| 整合前 PR 源 | `6c249b483acb4987df95b1c25ee8a5e9e27a4cda` |
| 本轮已合入目标 | `435feda1d6e44cc5a53a4a0c73208ce96fc6ee0b` |
| 语义整合提交 | `4fec9111869e65f5927757390feed3bdcc038828` |
| app / XCTest build-for-testing 源 | `f2857bef02ff49ffaacfdd8b7fe41cae235e9e29` |
| 产品目录 `RawLab/RawLab` tree | `6c48c015fc6d8e5f53670ed9d6e512738243e5ea`，自整合提交未变 |
| 新 framework 的 `lutools` tree | `f454bab64993119d45795d5996702a824daadea5` |
| framework 二进制 SHA256 | `67bd918c1ebce865f1c4c1665b2bb233c86d5ccda85dc734184e90deffc6e293` |
| framework UUID | `792F4F66-8D21-32BB-BC4C-A778644FB9ED` |
| 公共头文件 SHA256 | `02b79b3edf48d9b1bf478811684aeacaa9585e6bea3777d02b0c7353cc1c6de9` |

本轮证据根目录是 `/tmp/rawlab-ios-v08-integration-20261016`，下文相对路径均指该目录。`app-provenance.json` 记录 app 源、产品树、测试脚本提交和实际内嵌库摘要；`framework/framework-provenance.json`、`framework/built-CMakeCache.txt`、构建脚本和日志记录 core、编译配置与依赖来源。

framework 使用 Xcode 27.0 (`27A266a`) / iPhoneSimulator 27.0，Release、arm64 Simulator、最低 iOS 18；GPU、Lensfun、DNG、降噪开启，OpenMP 关闭。共享下载只读复用，绑定源码/配置的编译结果单独构建。旧生成库保存在任务目录，没有复用为本轮验证库，也没有覆盖未知源码改动。当前仅构建 arm64 simulator 切片，不是完整通用发布包。

## 两处冲突的语义处理

`ContentView+Helpers.swift` 保留导入期间编辑锁、请求身份、取消任务、迟到结果释放与恢复回调 guard。接入 RUM 的 `onImported` 回调，由 ViewModel 在接纳当前导入成功后调用；取消或迟到导入不计成功。保留取消后清空 `selectedPhotoItem` 的同图重选修复。函数已在 MainActor，不增加重复调度。

`ContentView+Panels.swift` 将隐私按钮和原生导入按钮放在同一工具栏组，保留导入禁用条件和刻度聚焦行为。保存反馈位于固定高度的标题栏，保留窄宽度下标签缩为图标、失败重试、44pt 操作区和无障碍描述。没有恢复旧版第二行保存提示或重复工具条；原生工具条仍由 `EditorLayout` 布局。

自动合并内容也做语义检查：`ContentView.swift` 保留几何来源变化后的未裁切预览修复、文件导出成功回调和隐私 sheet；胶片选择事件迁移至 `Panels/LookPanels.swift` 的 `filmButton`，只在胶片值改变时记录。RUM 五份源码各有一个 Sources 引用；新建/恢复批量任务的终态回调、照片写入成功事件、默认关闭和未配置状态均保留。没有新增 App scenePhase 生命周期绑定；传输边界由已有串行 transport 处理。

## 构建与定向结果

| 检查 | 来源与结果 | 证据 |
|---|---|---|
| framework | 新核心树构建通过；29 个公共 C API 导出、当前头文件实际链接、LibRaw 标记、56 个 Lensfun XML、许可证和系统动态依赖检查通过 | `framework/build-simulator.log`、`framework/verify-simulator.log`、`framework/framework-provenance.json` |
| app + XCTest | 精确 f2857bef，`build-for-testing` exit 0；app 内嵌库 SHA256 与新 framework 一致 | `app-build.log`、`app-provenance.json` |
| RAW 几何 | f2857bef 产品 / 新 framework，60 项 PASS、0 FAIL / SKIP；独立 C 参考、JPEG/DNG 尺寸、冻结批量设置、冷 WB 透视 preview/FINAL、复用会话双轴复位及 Auto/CPU 比对通过 | `models/geometry-processing.log`、`models/geometry-result.json`、`models/geometry-artifacts/` |
| 批量状态 | 私有 profile 下 89 项断言通过；90 条 PASS 日志包括一条汇总，不计为90项 | `models/batch-export.log`、`models/batch-export-result.json` |
| RUM 纯逻辑 | 整合源 4fec911，配置、local transport、线程、Shared analytics、Shared transport 五脚本 exit 0 | `rum/results.json` 与五份同名日志 |
| 几何来源切换 UI | 9ec42c6脚本/不变产品，35/35，XCTest1/1，0失败；使用既有链接产物接续 | `geometry-source-r3/geometry-result.json`、`geometry-source-r3/geometry-source-ui.log`、`geometry-source-r3/geometry-source.xcresult` |
| 隐私入口 UI | 恢复后r2为1/1、0失败、13.225s、exit0；原运行中断exit -15另存 | `rum/privacy-phone-r2.log`、`rum/privacy-phone-r2.xcresult`、`rum/RUM-verification.md` |
| 保存反馈 UI | iPhone竖/横屏、AX M、XS四项，加13寸iPad竖屏一项，共5/5、0失败/跳过；完整frame最大变化0pt，重置目标≥44pt且可触达 | `save-feedback/phone.log`、`save-feedback/ipad-portrait.log`、两份xcresult及 `save-feedback/README.md` |
| 导入状态模型 | 既有链接二进制首次runtime，167项断言通过 | `models/import-state-runtime.log` |
| RAW导入/历史/迟到结果 | 15项通过；同一真实RAW以A/B两身份及设置，accepted B回调1次、迟到A为0；重开历史与独立新Processor像素一致 | `models/raw-import-history.log`、`models/model-results.json` |
| 视口状态 | 三组通过：busy resize/取消/降噪切换、DNG成功、DNG失败的尺寸与最新设置重放 | `models/viewport-state.log` |
| 处理器导出 | 56项通过、0失败/跳过，实际Sony RAW/lens、DJI降噪、JPEG/DNG/FINAL、HSL、CPU/Force Metal比对 | `models/processor-export.log`、`models/model-results.json` |
| 批量发布模型 | 14项通过；15条PASS含一条汇总，Photos拒绝/手动确认及DNG已发布文件重核对通过 | `models/batch-publication.log`、`models/model-results.json` |
| RAW系统选片/原生滚轮/恢复/批量入口 | 明确启用后1/1、0失败/跳过、91.531s；系统选片后RAW专用lens可用；曝光+0.35、水平透视12保存并重启恢复；活动草稿禁止导出，批量选择保留原DNG名并就绪 | `raw-native-ui/raw-native.log`、`raw-native-ui/summary.json`、`raw-native-ui/raw-native.xcresult` |

构建命令：

```sh
xcodebuild -project RawLab/RawLab.xcodeproj -scheme RawLab -configuration Debug \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=5E68FBD4-B519-4B74-8AE5-FF8F9E9C5DA5' \
  -derivedDataPath /tmp/rawlab-ios-v08-integration-20261016/derived \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build-for-testing
```

最终定向UI合计8/8、0失败、0跳过，实际xcresult汇总见 `ui-final-summary.json`；模型401条断言另加视口三组，详见 [模型验证报告](ios-v08-model-integration-2026-10-16.md)。首次编译/链接失败和隐私中断没有计作通过。RAW系统用例只执行到批量就绪，未冒充该用例完成实际批量文件发布。

本轮三个新建模拟器分别承担 iPhone UI（`5E68FBD4-B519-4B74-8AE5-FF8F9E9C5DA5`）、13寸 iPad 几何（`1A11DBF8-83FC-4F1E-95EF-AE9E35BCC7D6`）和模型/RAW（`47310A81-02AA-45A1-807A-431181E4D338`）。没有重置其他设备、操作桌面鼠标或修改真实用户 profile。

## 实际失败与最小测试修复

- host 批量测试首次尝试真实 Documents/Exports，被运行沙箱拒绝；未扩大权限重试该路径。测试入口改用私有 `CFFIXED_USER_HOME` 和 `RAWLAB_TEST_PROFILE`，在首次写入前核对 export root 属于该 profile；未改 `HOME`。修复后89项通过。
- 几何容器首次编译被嵌套沙箱阻止 SwiftUI 宏启动，未进入模型/UI 执行。保留 `geometry-source-run.log`，使用同源码、同专用设备的受限提权调用重试。
- 接入 RUM 后，七份递归收集 Shared 源码的测试脚本把新 `Shared/tests` 两个 `@main` 文件也传给编译器，几何和 import-state 实际报重复 `main`。仅增加排除 tests 目录的 glob，实测只剔除该两文件、保留49个产品 Swift；显式传入的 harness 测试不受影响。首次链接失败日志保留，未计通过。
- 三份既有 native 脚本补私有 Swift module-cache 路径，避免使用未知 host 缓存；不改变测试/产品语义。
- 模型设备首个原生路径探针停在 SimLaunchHost，尚未执行测试；只重启本任务新设备一次，未 erase。重启后探针确认 HOME/cache/Documents/tmp 均属于该设备，几何原生测试随后通过。
- 隐私UI点击后，日志到t73报告应用idle通知未收到，此后无断言结果；限定该设备的container查询、限定app进程3秒采样也迟滞/超时，未取得定位调用栈。原xcodebuild及taskPHONE的app进程被精确核对后中断，exit -15。仅一次自有iPhone恢复的 `simctl shutdown 5E68FBD4-B519-4B74-8AE5-FF8F9E9C5DA5` 超过45秒，该阶段最终状态不确定；当时未继续boot/erase或第二次测试，后续仅在协调补充授权后恢复（见下文），不重置共享服务或其他设备。完整命令、timeout和目标见 `rum/RUM-verification.md`，不能据此归因为产品缺陷或算通过。

测试增量提交：`dbef63b`（四个保存用例适配真实原生刻度及新增明确启用的 RAW UI）、`f2857be`（RAW 历史/迟到结果测试、批量私有 profile）、`8b0264f`（三脚本私有模块缓存）、`9ec42c6`（七脚本排除 Shared 独立测试）。这些提交没有修改产品或共享 core。

## 独立复核与边界

整合提交4fec911由任务内 reviewer 和协调侧独立只读 review 分别检查，均无 Must-fix / Should-fix；确认原生 UI、请求/source guard、固定标题保存反馈和 RUM 成功/批量终态/隐私入口共存。dbef63b、f2857be 及两次脚本增量均另行只读复核，无 Must-fix / Should-fix。静态 review 没有计作动态测试通过。

历史 UI、取消和 e63 RAW 结果保留原始源码归属，见原有验证文档；本轮没有机械重跑无关整套。新 RAW A/B 模型使用同一份真实 DJI RAW 的不同身份/设置，不代表多相机覆盖。几何来源 UI 容器仍通过真实 ViewModel/ContentView 恢复链进入，但不是系统 PhotosPicker 获取测试。

真实 iCloud/provider 内部等待、fallback、真实迟到失败、多窗口重建/系统终止、签名设备安装、物理震动、实机帧率/延迟、硬件 VoiceOver/Switch Control 保留待验。RUM 默认构建未配置 provider，本轮不会称实际 SDK/网络采集通过；纯逻辑测试使用 fake transport。历史 e63 `RawExports.log:363` 的一次 SwiftUI 发布警告仍未定位，后续日志无记录也不能据此关闭。

协调补充授权后，逐个核对launchd_sim的SIMULATOR_UDID：26253=iPad、26395=iPhone、40583=Models；仅结束这三个任务进程，旧设备94569/94778未动。确认三个进程已退出后，一次有时限的simctl查询立即exit0，三个任务设备均为Shutdown。没有重置共享服务。协调侧同时确认内存可用41%、磁盘321Gi，未将迟滞归因内存/磁盘耗尽。相关证据在 `simulator-diagnostics/`。

恢复期间exec-server连接更换，两个已暂停的外层wrapper消失；核对进程、日志和产物，几何/import-state二进制已链接，但尚未执行XCTest/模型。继续使用这些既有二进制，从签名/执行步骤接续，不重复编译或测试。

恢复后按iPhone→iPad→Models顺序只启动一个任务设备，表中全部定向检查完成。RAW UI准备时只读确认任务Photos库自带六张图片（5 JPG、1 HEIC），并非空库；未删除这些素材，只新增一张私有DJI DNG。用例实际通过RAW-only lens及批量原名检查，不能把预览或默认图片当作RAW。初次“空库”前提检查在addmedia前即停止，非产品/XCTest失败；最终库为六张默认图加一张RAW，见 `raw-native-ui/seed-result.json`。

最终fetch仍为435feda，产品、工程、UITest、Shared与native输入相对构建源f285未变（仅测试脚本与文档增量）。本轮已达到转Ready的本地验证条件；PR最终状态与推送head由远端记录确认，合入仍由协调执行。#53尚未合入，不把其未提供的新core当成本轮产物来源；后续准确target移动时，按实际core/header/link变化做增量判断。

## 清理与保留证据

已清理失败/成功harness、重复framework副本、bridge对象、Swift模块缓存、索引、一次性helper以及不再需要的DerivedData中间目录；模型仅清除本任务19个随机cached源。RAW UI完成后再核对私有DJI的SHA256为0ecdc8…，随后删除磁盘副本；共享Sony与共享DJI原始素材未变。MODELS的测试App/profile已卸载，三个任务设备均正常shutdown，未erase设备、未触及旧设备。见 `cleanup-final.json`、`models/simulator-model-cleanup.json` 与 `simulator-diagnostics/final-device-cleanup.json`。

保留必要日志/xcresult、输出/源码快照、135KB生成PNG，以及匹配f285的App/XCTest产品供复核。当前f454新framework、来源配置和按版本配置区分的依赖构建暂保留，供协调#53的实际增量决定使用；旧未知来源生成库备份未擅删。没有构建产物/RAW/截图加入Git，也没有清理主树未知改动。
