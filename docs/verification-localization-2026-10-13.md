# 多语言验证记录

日期：2026-10-13。交付分支：`feature/multilingual-support`。
基线：`origin/development` 的 `12d6cc17b2b92233657d3eb548ee146dbdcb8530`。
本记录描述迁移到该基线后的代码和验证，不沿用原分支上的构建结果。

以下早期章节保留初次交付和 Apple 补充验收的历史结果。后续正常合入了
`development` 的 `2c46edc5f0d8a26933f853afbb068e5def06e2bf`，包含已合并的
JPEG XL、渲染型 DNG、镜头矫正及视口预览功能。最新集成范围、重新执行的检查和
仍未覆盖的事项以文末“Development 集成验收”为准，不把早期结果当作最新核心的完整验收。

## 交付范围

macOS、iOS、Android、Windows 支持简体中文、英语、德语、法语、日语和西班牙语。
默认跟随系统，未支持的语言回退英语；提供持久化的手动语言选择。
菜单、控件、辅助功能标签、应用提示和应用控制的错误文案已资源化。

已补齐 development 新增的大师配方描述、HSL、曝光和照片效果界面。
配方及胶片专有名称、用户外观名称、照片路径、枚举 raw value、配方 ID 和保存格式保持不变。
本次没有修改显影算法、共享 C ABI、RAW 或配方 JSON。
无关的 AI 仿色、JPEG XL、视口预览和降噪缓存改动未带入本交付分支；
原工作区及其已有改动保留。

## 已通过

| 范围 | 检查与结果 |
| --- | --- |
| 资源回归 | `python3 -m unittest discover -s tests -p test_localization.py`：5/5，通过六语言 key、占位符、源调用覆盖、14 个配方描述及 HSL 覆盖检查 |
| macOS 构建 | `bash RawLabMac/build.sh`：当前核心/UI 构建、六语言资源打包、依赖及签名检查通过 |
| macOS 模型 | `localization.sh` 12 项、`master-recipe.sh` 1624 项、`horizontal-picker.sh` 13 项、`presentation.sh` 83 项、`update-check.sh` 2 项，以及 `edit-model.sh`、`edit-memory.sh`、`batch-export.sh` 均通过 |
| 核心 | `ctest --test-dir lutools/build-macos --output-on-failure`：15/15，通过现有 RAW、CPU/Metal、降噪、HSL/照片效果相关回归 |
| iOS 构建 | `bash lutools/platform/ios/build-framework.sh`：当前核心三架构 XCFramework 构建通过；最新模拟器应用和 UI 测试构建通过 |
| iOS 模型 | `presentation.sh` 211 项、`edit-memory.sh` 20 项、`batch-export.sh` 51 项、`photo-information.sh` 9 项通过 |
| iOS UI | iPhone 17e / iOS 26.4，`testLanguageSelectionPersists`：1/1，通过德语、法语实时切换、重启持久化及恢复系统语言 |
| Android 构建 | `assembleDebug assembleDebugAndroidTest testDebugUnitTest lintDebug` 通过；61 项单元测试，失败/错误/跳过均为 0 |
| Android 设备 | 独立 API 35 ARM64 模拟器：5/5，六语言资源、空态编辑器、RAW 导入/旋转/失败恢复/切换语言保留编辑、关于页及降噪控件通过 |
| Windows 可移植检查 | 本地化 29 项、编辑工作流 2 项、降噪 22 项、更新 2 项通过；macOS 上应用/WPF 测试交叉编译通过 |
| Windows 原生 WPF | 隔离目录内直接 `dotnet build`：应用、WPF 测试和本地化 UI 回归均为 0 warning / 0 error；`LocalizationUiChecks` 75/75 通过 |
| diff | `git diff --check` 通过 |

### macOS 原生界面

在当前 worktree 的 `build/RawLab Mac.app` 中完成六语言实时切换及直方图标签检查。
使用仓库合成 `linear-uncompressed.dng`，检查德语/法语配方描述与 HSL 标签。
已选配方、Yellow 通道、色相/饱和度数值、曝光及其他调整在语言切换后保持。
法语选择退出重启后保留。原生截图检查未见文字重叠。
结束后恢复跟随系统、测试调整和当前 development 的 Standard 曝光基准，并关闭本线应用。

### Windows 原生 WPF

提交的 `RawLabWindows/tests/localization-ui` 使用真实 App 启动后的 MainWindow。
测试对该窗口实际的 settings 应用配方、曝光 1.25、HSL 和八项照片效果，
点击真实 Vignette 工具，再逐一切换六语言。对象引用和完整 Capture JSON 均保持；
DynamicResource、工具/HSL/重置按钮辅助功能文案实时更新，六次 Changed 事件及偏好写入正确。
测试前后语言偏好文件均不存在，测试写入已清理。
此结论覆盖托管 WPF 运行，不代表原生显影 DLL、硬件 GPU 或桌面视觉验收通过。

### 设备与样片隔离

Android 在本线新建 AVD `rawlab-i18n-api35` 的 `emulator-5584` 上，
通过显式 `adb -s emulator-5584 install` 和 `am instrument` 执行，
没有使用会枚举全部设备的 Gradle connected 任务。
这是最终通过结果的设备边界。早期验证曾使用 `emulator-5582` 和 connected 任务，
在明确并发设备归属后已停止；不将早期共享设备结果作为最终通过证据。
后续未再操作该设备或其他任务的 Android 真机；本次 Apple 补充验收也未运行 Android 任务。
设备回归使用仓库合成 DNG，不修改样片，也不构成真机 GPU 证明；结束后关闭本线模拟器。

## 评审与失败处理

两位独立评审分别检查 Apple/Shared 与 Windows/Android 调用链，并回查已确认问题：
大师配方在批量摘要中误显示为中性、iOS 批量中性名称被翻译后持久化、
Windows 动态标签及工具辅助功能名称未刷新、iOS 降噪错误及 Mac 16-bit 标签漏翻译，均已修复。

Android API 33+ 的测试曾与系统自动 locale 重建重复调用 recreate；
实际复现 ActivityScenario DESTROYED 错误后，测试与生产代码对齐，仅旧 API 手动重建，
等待新 locale 生效后重新绑定模型。上述最终设备回归通过。
早期共享 AVD/端口冲突不作为通过证据；最终结果来自新建的独立 AVD。

Windows 完整 `build.ps1 -Test` 被当前主机脚本执行策略拒绝；
未绕过或修改策略。必要的本地化验证改为直接运行托管项目。
新增 WPF 回归曾因测试 harness 给 StartupUri 赋 null 失败；
改为等待真实应用正常启动后，最终 75 项检查通过。

## Apple 补充验收

### iOS 原生控件修正

在 `5081f26` 上实际复现两项失败：切换到中文后，曝光 Picker 的外部标签已更新，
选中标题及原生菜单仍是英语，测试找不到“标准显影”；德语降噪标题同一行放置开关、
预设和重置时，“Detailpriorität”被压到约 14 pt 宽、234 pt 高。
这两次 RED 来自当时的原生 UI 运行；早期 `/tmp` 日志在主机重连后已丢失，
不把它们列为目前可读取的证据文件。

修正仅给语言、曝光、白平衡、降噪和导出尺寸 Picker 加 locale identity，
不重建编辑器或模型；降噪预设与其标题分行，开关和重置保持原有 Binding。

补充测试只使用本线 iPhone 17e / iOS 26.4 模拟器
`52D76F0A-FAE5-4409-9C2C-5C33C2E37AE6`。
两次组合遍历在原生降噪点击处失败，未作为通过结果：截图中预设已正确翻译且高度约 34 pt，
但面板滚动与恢复任务横幅共存时，测试点击落入数值输入框。
最终回归先完成批量任务，再将编辑面板回到顶部并使用控件相对坐标，避免复用过期页面坐标。

最初的完整六语言原生菜单/批量遍历 1/1 通过（355.576 秒）。独立评审随后指出曝光值
可能为 nil 而绕过保留断言，已改为非空守卫，并增加曝光、白平衡、两种降噪预设及尺寸选择后
的实际状态断言。补强测试又复现德语“Rauschunterdrückung priorisieren”选中标题高约 74 pt
的 RED，证据保留在 `ios-picker-batch-verified.log` / `.xcresult`。
预设标题与菜单进一步分行，给长选项完整宽度；不放宽原有 60 pt 高度断言。

最终 `ios-picker-batch-green`：2/2，0 failures，runner exit 0。
语言持久化回归与六语言完整遍历均通过；后者运行 446.340 秒。
覆盖曝光三种原生选项、白平衡两种 segment、降噪 detail/clean 选择值与高度，
单图及批量导出尺寸原生选项、曝光编辑保留、同一批量任务来源/所选数/2048 尺寸保留。
西班牙语执行 1 张导出并等待完成；另以只读 Photos 数据库记录和实际 JPEG 文件核验
本轮 15:35:54 新增的 2048 × 2048 资产，而非只依赖完成摘要。
测试恢复系统语言，Done 清理本次任务但保留测试照片。
新增 source、测试和文档经过两位独立评审，已补强的测试缺口回查后无未关闭 must/should。

### macOS 批量界面

使用隔离的 `RawLab I18n Walkthrough.app` 和单独的 Edits/Batch/Looks 目录，
编译同一提交的生产视图和模型，仅测试入口更换数据目录，避免影响其他应用会话。
同一任务窗口中完成六语言实时切换，调整来源、配方“滨田英明”100%、曝光 +0.40 EV、
所选 1 张和输出目录均保持。

合成 DNG 的导出因缺少元数据而失败（`RawLabMac.ExportMetadata.Failure`），
没有把该次运行算作成功或改动显影逻辑。随后用仓库真实 DJI DNG 作为目标，
西班牙语界面显示成功 1、失败 0；实际 JPEG 存在，尺寸 3072 × 3072。
原始 RAW 未修改。完成后恢复隔离应用的系统语言并关闭本线应用。

西班牙语完成页截图复现导出尺寸标签逐字换行、打开文件夹按钮文字与图标重叠的 RED。
经确认后，仅将导出尺寸标题与 segmented 控件分行，将打开文件夹改为 folder 图标，
保留翻译 tooltip、辅助功能名称和原动作。新 UI 编译/签名与 `RawLabMac/build.sh` 均通过。
在同一完成任务上重新切换六语言、检查六张原生截图，标题及图标不再挤压，任务状态保持。
额外检查德/法/西三种语言的单张保存面板：完整长边控件在 360 × 110 accessory 中可见，
2048 数值保持；均取消面板，未写入单张导出文件。

## 未验证与剩余限制

- Windows 完整 C++/CTest、原生 DLL/RAW/GPU、手动桌面/RDP 视觉验收：`NOT REACHED`。
- Android API 26-32 运行时语言切换：没有设备实测；有版本守卫、解析测试及 lint。
- Apple 补充验收覆盖曝光、白平衡、降噪、单张/批量尺寸控件与批量页面，
  不涵盖全部 Dynamic Type 尺寸、VoiceOver 流程、iPad 或物理 iPhone。
- Android 批量来源为自定义导入外观时，原有 snapshot 不保存用户显示名，
  查不到内置胶片/配方后仍回退原始 ID；未在本次多语言工作中迁移该持久化结构。
- 六语言尚未完成母语校对；历史任务日志、已有错误详情、用户数据和底层诊断不重新翻译。
- 本报告的检查是本地或专用构建主机验证，不等同于 GitHub exact-head CI 结果。

## 产物与证据

构建产物保持忽略，不提交：

- macOS：`build/RawLab Mac.app`
- Android：`RawLabAndroid/app/build/outputs/apk/debug/app-debug.apk`
- iOS：`/tmp/rawlab-localized-development-ios/Build/Products/Debug-iphonesimulator/RawLab.app`
- Windows 托管程序集：`RawLabWindows/bin/Release/net8.0-windows/RawLab.dll`，
  不是包含 native DLL 的完整 Windows 发布包。

初次交付的主要验证日志当时保留在临时目录：
`rawlab-i18n-mac-final-build.log`、`rawlab-development-ctest.log`、
`rawlab-i18n-ios-final-test.log`、`rawlab-i18n-final-language.xcresult`、
`rawlab-i18n-android-build-final.log`、`rawlab-i18n-android-instrumentation.log`、
`rawlab-i18n-native-wpf-ui-build.log` 和 `rawlab-i18n-native-wpf-ui-run.log`。
主机重连后这些临时文件已丢失，以上表格记录当时命令结果，不代表补充验收重新运行所有平台。

补充验收证据位于 worktree 的忽略目录 `build/localization-ui-20261013/`：
`ios-picker-batch.xcresult` 和 `ios-picker-batch-final.xcresult` 保存未通过的组合运行；
`ios-picker-batch-stable.log` / `.xcresult` 保存调整后测试；
`ios-picker-batch-verified.log` / `.xcresult` 保存增加选择断言后复现的德语长预设失败；
`ios-picker-batch-green.log` / `.xcresult` 保存最终回归；
`mac-batch-{en,de,fr,ja,zh-Hans,es}.txt` 保存六语言原生任务状态，
`mac-batch-completed-es.txt` / `.png` 保存实际完成状态。
`mac-batch-fixed-{en,de,fr,ja,zh-Hans,es}.txt` / `.png` 保存布局修正后的同一完成任务；
`mac-save-accessory-fixed-{de,fr,es}.txt` / `.png` 保存单图保存面板布局。
`ios-green-shots/` 保存最终测试截图；`ios-photos-output-assets.json` 和
`ios-photos-output-file.txt` 保存输出照片的独立核验。
截图及导出照片仅作本地证据，不提交到仓库。
PR 的提交 SHA、远端同步及 CI 状态在交付时单独核对。

## Development 集成验收

集成目标：`2c46edc5f0d8a26933f853afbb068e5def06e2bf`。
通过普通 merge 保留目标功能，不覆盖客户端文件、不 force-push。
新接入的 DNG 格式、文件导出、镜头模式/搜索/能力/状态/批量摘要及预览等待提示均已本地化。
原有 JPEG/PNG/DNG C ABI 值 `0/1/4`、输出 I/O 状态 `6`、`dng` 持久化值、
原生镜头 ProfileID、手动选择 sentinel、RAW/外观/目标身份和全套调整保持不变。
iOS 界面仍仅提供 JPEG/DNG，不新增 PNG 入口。核心算法及目标分支的回调/缓存语义未作额外修改。

### 当前可读取的检查

- 资源静态回归：5/5。新增资源 seed 检查覆盖四端各六个 catalog 的 49 个集成 key，
  原有 key/value 未改变；随后必要的 Apple 视口错误、Android 自动模式和 Windows 扩展名提示另有补齐。
- Apple typed Lens 状态与完整设置持久化：102 项，包含 10 种状态、应用能力组合、
  JSON/reopen 及原生 ProfileID/名称保持。测试显式断言计数 102；不是 102 次真实 UI 操作。
- iOS 批量模型：81 条 PASS，覆盖 DNG 持久化输出、恢复、存储失败及 frozen Lens/settings。
  macOS Lens settings 和批量模型检查通过。
- iOS 当前三架构 XCFramework 构建通过；最终 `ios-lens-dng-v7` UI 2/2、0 failures、exit 0。
  六语言 Lens 原生 mode/profile/switches 和同一批量目标/DNG/128 px/目的地保持，
  语言持久化回归也通过。西班牙语实际调用系统 Files Save，完成摘要匹配独立译文断言。
  21:58 输出文件为 128×128、32-bit float RGB DNG、198918 bytes；应用生成文件和
  File Provider Storage 中的实际副本 SHA-256 均为
  `1814249e724f6102b6a68e7cfbb2b1997f904743b27da462518630a096943989`。
  德语 Lens 和西班牙语批量截图未见布局重叠。完成后恢复系统语言并清理本次任务，保留 RAW/导出文件。
- macOS 当前生产应用构建/打包/签名检查通过。使用全新的核心 build 目录和本线依赖前缀，
  保留原 SDK OOM 断言并实际通过；不复用其他工作区的 native 二进制。
- macOS 真实 DJI DNG：CPU 与强制 Metal，各输出 128 px PNG/DNG；非零调整下
  单张/批量 DNG 字节完全一致，原始文件不变。
- macOS 当前生产视图/模型的隔离测试入口：六语言 live Lens 状态、手动 ProfileID、畸变/TCA/裁边和
  曝光 +0.75 EV 保持；全套 edits JSON 前后 SHA-256 相同。
  同一 frozen batch 的来源、1 个目标、DNG、128 px 和目录保持，job JSON 前后 SHA-256 相同。
  德/法/西截图确认尺寸标题和 folder 图标布局；西班牙语实际 DNG 批量成功 1/失败 0，
  文件 198918 bytes/128×128；单张 JPEG 实际输出 128×128。真实照片仅作本地证据。
- Android 当前生产 APK 的双 ABI native 构建、app/test APK assemble 及 lint 通过。
  本次 full build 的 unit task 为 UP-TO-DATE，不声明这次重跑了全部单元测试。
  Sony fixture 下有 5 个单测试成功记录，包括六语言资源、Lens 控件、真实 Activity 重建时
  全套编辑/DNG batch/source/destination 保持，以及 JPEG/16-bit PNG final cap。
  该组合运行没有成功 aggregate，不能表述为整组 GREEN。
- Android 同一 production APK/native ELF 下，仅更换 AndroidTest fixture 为 DJI DNG
  （3072×3072、19545856 bytes），独立 CPU/强制 GLES DNG 回归 `OK (1 test)`，216.539 秒。
  CPU 75845 ms，GLES 138571 ms；实际 DNG/PNG 存在。不是物理设备 GPU 验收。
- Windows 当前源码的托管应用 fresh build、可移植本地化 29 项、真实 WPF 六语言窗口回归通过：
  `RESULT: PASS failures=0 changed=6`，包含完整设置、手动 Lens、DNG、批量目标和目录保持。
  未作 RDP 视觉验收。
- Windows 未修改的生产 native CMake 构建通过：GPU/Lensfun/Wavelet/Chroma 与依赖开关全部 ON，
  使用本线 Python 3.11.9 build-host runtime 和 fresh native 目录，源码 CMake hash 与 worktree 一致。
  新 DLL 的同一 session/GPU_OFF 实际导出 JPEG 14582 bytes、16-bit PNG 63439 bytes、
  DNG 132870 bytes，均为 128×85；ABI 0/1/4 均 status 0，缺失目录 DNG status 6，harness exit 0。
  不是关闭 Lens/GPU/降噪的早期替代配置，也不声明执行了 Windows hardware GPU 或全量 CTest。

### 失败与实际边界

macOS 最初两次 SDK OOM probe 失败。CMake cache/link.txt/otool 证明旧 build 目录引用了
原工作区依赖；本线依赖重建后，旧 cache 仍使用原路径。新 build 目录绑定本线依赖后通过，
没有修改 native 源码或放宽断言。

Android 第一次缺少 `sample.RAW`，6 个选中测试中 3 个 FileNotFoundException，未记通过。
随后 Sony `DSC06251.ARW` 输入（7008×4672、45199360 bytes）的两次预览/导出测试
在实际 2.5 GiB/4 CPU AVD 上被 guest `lmkd` 杀死：PID 2971/RSS 471488 kB，
低 swap/thrashing；PID 3993/RSS 416732 kB，低 swap/min watermark。两次均有
Zygote signal 9/进程死亡证据，没有对应 native fatal signal/backtrace。
证据更正：方法虽名为 `nativeDngBakesAllAdjustmentsOnCpuAndForcedGles`，预览及 DNG/PNG
输出请求实际都是 longEdge128；FINAL 仍先执行全分辨率计算再缩输出尺寸。CPU 整轮
`preview+exports` 完成 marker 未出现，旧日志不能定位失败在预览、渲染、编码/writer 或其他阶段，
不能写成原尺寸输出 DNG 失败。原尺寸 DNG 文件输出仍未验证；DJI fixture 通过不能替代
Sony 大 RAW 输入流程的未完成覆盖。

Windows 初次 full-feature configure 因临时路径达到 279 字符触发 MAX_PATH；
仅缩短本线 fresh build 根目录后成功，没有改源码、脚本执行策略、系统长路径设置或其他 VM 配置。
`build.ps1 -Test` 的脚本策略限制仍在；本轮通过的是直接 production CMake/指定 target 和托管命令，
Windows 全量 CTest、hardware GPU 与手动 RDP 视觉验收仍未执行。

iOS 新增 UI 回归早期失败均保留：启动参数固定 `RawLab.language=en` 覆盖手动 preference；
Photos 系统 Add 与应用内 Add 同名；空态 toolbar import 的 hit point 为 (-1,-1)；
Files 的 Cancel 是 AX Other 而不是 Button。修正测试启动/实际 AX 查询，不放宽生产状态断言。
独立 DerivedData 与测试 marker 绑定当前源码。v5 已完成六语言遍历并实际生成
3072×3072、32-bit float RGB DNG，但因 Cancel 类型查询失败，整个 v5 仍记为 FAILED。
v6 的六语言/128 状态断言也通过，但 AX Other Cancel 的 hit point 为 (-1,-1)，实际点到 More 菜单，
随后取消摘要断言失败。11.846 秒的现有文件诊断截图证明系统 Files 没有可见 Cancel，
该 AX 节点与 More 重叠；没有改生产 Files controller。
v7 改验系统可达的正向 Save/实际文件副本/本地化 exported 摘要，不放宽语言或状态保持断言。
Files 取消路径仍未验证，不把 v5/v6 或仅截图的诊断 test 算成最终 UI GREEN；诊断 test 已删除。

原两位评审的翻译 Must/Should 已逐项回查：Mac DNG 菜单、视口错误、12 个 Apple key、
四个 Swift harness 的 Shared/Localization source list、Windows 扩展名提示和 crop F1、
Android 自动模式/typed states/global preference/真实 Activity 保持测试均已关闭。
另两项属于集成目标原有功能的作者观察，未伪装成已修：RAW→raster 后选中的 Lens 可保留为禁用空面板；
iOS DNG UI 入口有 preview/busy gating，但 model exportDNG 没有 JPEG 同等 guard。
本轮不变更该状态/并发设计，交由对应功能 owner 跟进。

最新证据保存在忽略目录 `build/localization-integration-prep/`：
`static-final.log`、`apple-lens-final.log`、`ios-batch-model.log`、`mac-batch-model.log`、
`mac-build-final.log`、`mac-rendered-dng-final.log`、`android-build-final.log`、
`android-focused-instrumentation-fixture.log`、`android-rendered-dng-dng-instrumentation.log`、
两次 Sony 的 instrumentation/logcat、`windows-wpf-ui.log`、
`windows-native-final-config-short.log`、`windows-native-final-build.log` 和 `native-final-gate-validation.log`。
`ios-lens-dng-{v4,v5,v6}.log/.xcresult` 是失败证据，不因文件名而计为通过。
`ios-lens-dng-v7.log/.xcresult` 与 `ios-v7-shots/` 保存最终 UI 2/2 和原生截图，
`ios-files-inspect.log/.xcresult` 只保存短诊断，不作为替代完整 UI 验收。
以上不等同于 GitHub exact-head CI，也没有执行新的全量 Stage3/ColdWarm/内存评审。
