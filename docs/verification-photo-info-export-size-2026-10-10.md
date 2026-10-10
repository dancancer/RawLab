# 照片信息、文件树操作与导出尺寸验证

日期：2026-10-10。基线：`origin/development` / `8bd506938827ac074ae042f79b4e80ed3b4657de`。
分支：`codex/photo-info-export-size`。实施和构建在独立 worktree，未改写原工作区的源码。本报告记录提交前的验证结果，不代表发布或商店签名验证。

## 行为

- 四端照片信息叠层采用隐藏、文件信息、拍摄参数三态；桌面支持 `I`，移动端使用信息按钮。参考 [Adobe Loupe Info Overlay](https://helpx.adobe.com/lightroom-classic/desktop/viewing-photos/view-photos.html) 的双信息组切换方式。字段来自原图，缺失字段不伪造，叠层不进入导出像素。
- Mac / Windows 的照片和目录右键菜单可在 Finder / 资源管理器打开，或将当前调整和外观写入目标的本机编辑记录。应用前确认目标数量，目录仅处理直接 RAW 子文件，不打开目标来改变来源，不改写 RAW。
- 单张与批量导出提供原尺寸、2048 / 3000 / 4096、自定义 1...65535 长边上限。共享核心新增 mode 4，保持比例且不放大，导出使用 FINAL 而非预览代理。任务冻结尺寸；旧 journal 缺失字段时使用原尺寸。原有输出格式不变。

## 通过的检查

| 范围 | 检查与结果 |
| --- | --- |
| 共享核心 | `ctest --test-dir lutools/build-macos --output-on-failure` **15/15** 通过，包括实际 ARW / DNG、Metal、限长、比例、不放大和非法尺寸。日志：`build/ctest-final.log`。 |
| Mac 构建与模型 | 应用构建及非系统动态库打包/签名检查通过。照片信息、编辑记忆、实际编辑模型、批量 journal、外观导入、文件树测试通过；新增保存附件回归先失败后通过。RAW 元数据原尺寸修复后再次构建和信息模型测试通过。日志：`build/mac-original-info-size-build.log`、`build/mac-info-original-size-green.log`、`build/mac-size-accessory-final.log`、`build/mac-file-browser-final.log` 等。 |
| Mac 实际文件 | Sony ARW 的单张/批量、原尺寸/2048 上限、JPEG/16-bit PNG 导出通过；成片像素一致，2048 上限实际为 **1365×2048**，EXIF 日期和方向正确，RAW 未变。日志：`build/mac-sized-batch.log`，以及前次 `export-metadata.sh` 实际样片检查。 |
| Mac 原生交互 | 用相同编译二进制的独立测试 bundle 验证信息三态、数值输入的快捷键保护、照片/目录菜单。真实保存对话框选 512，文件解码为 **341×512**。右击第二张后 Finder 选中 `target.ARW`；应用设置确认 1 张，当前照片不变，重新打开目标恢复 1.25 EV；目录确认 2 张，仅处理直接 RAW，排除 JPEG。测试 bundle 只更改忽略目录中的 bundle ID，避免操作正在运行的原工作区应用。 |
| Windows 构建 | 在 VM 100 上从当前 worktree 的源文件重新构建 native DLL、WPF、ExifTool 和 self-contained 包，通过。最新包：`build/windows-remote/20261010-150159/RawLab-Windows.zip`；构建日志同目录 `build.log`，远程构建/测试/下载 exit 0。 |
| Windows 原生回归 | 修复后重新运行实际 Windows **12/12 CTest**、**126 项 native/WPF 检查**通过；本次配置外部 Sony RAW，覆盖实际 Direct3D 11、CPU/GPU 像素一致性、真实 RAW、UTF-8 路径、EXIF、PNG 16-bit、缓存和导出门禁。最新日志 `build/windows-remote/20261010-150159/build.log`。纯编辑/降噪/更新测试此前通过，相关纯模块本轮未修改。部分 Metal-only 子检查在 Windows 上明确 SKIP，不计为 Metal 验证。 |
| Windows 新功能 | 登录桌面 session 1 上最新 **37 项检查**通过：真实 ExifTool 读取、叠层三态与切片防串图、原尺寸/预设/自定义控件、非法值与格式切换、实际批量 512 px/journal、JPEG/16-bit PNG 2048 px、65535 不放大、照片/目录菜单和确认复制、直接子级筛选、RAW 字节不变。资源管理器确认精确单选被右击的 `target.ARW` 持续 500 ms，另一个目录节点也单独打开成功。日志 `build/windows-selection-fixed.log`；结束后任务 Ready、exit 0，见 `build/windows-selection-process-status.log`。 |
| Android 静态检查 | 本轮重新构建 debug / test APK、lint、50 个 JVM 测试通过（0 failures / errors），日志 `build/android-remaining-fix-static.log`。此前 native request 测试、ARM64 / x86_64 16 KB 对齐检查通过；本轮未改 JNI 或 native binary。外部 RAW 仅进入测试 APK，不进入正式应用资源。 |
| Android 新功能真机 | Lenovo TB320FC / Android 15 上 **4/4** 通过：真实 Sony EXIF、缺字段、方向、三态和切片、预设/非法/512 自定义 UI、保存相册后实际像素/EXIF、CPU JPEG/16-bit PNG、不放大、RAW 不变、批量 256 px 冻结/journal/真实失败后恢复重试。日志：`build/android-features-final.log`；有效应用截图：`build/verification/android-info-final.png`、`android-size-final.png`。 |
| Android 旧界面定点回归 | 修正版本硬编码、横向列表选择器、异步相册等待、布局偏好泄漏后，22 个界面用例按组通过。包含 PhotoCanvas 4 项、相册 13 项、About 1 项，以及用带 RAW fixture 的测试 APK 再跑编辑/外观 4 项。日志：`build/android-device-ui-regressions.log`、`build/android-editor-look-final2.log`；前者的两项 `sample.RAW` 缺失由后者补齐，不能把前者单独记为全通过。 |
| Android 剩余问题修复后 | 真机本轮 **44/44** 通过，涵盖全部非 `NativeProcessorTest` 仪器用例，包括照片信息/尺寸 4 项、此前失败的批量工作流 2 项、相册和编辑等界面回归。原尺寸单张和批量成片像素一致、目标编辑记录和 RAW 不变均通过；效果查看 **2133 ms**，仍使用原来的 90 秒测试上限。日志 `build/android-remaining-fix-device.log`。其余 7 个 NativeProcessorTest 已在前次全量运行中通过，本轮未重复这组耗时测试，不能将本次 44 项称为一次完整 51 项运行。 |
| iOS 模型和处理器 | Simulator 构建及照片信息、批量、presentation 测试通过。Sony ARW 的 `processor-export.sh` 通过，验证 RAW/buffer 限长、比例、小图不放大、FINAL/preview 分离、JPEG EXIF/方向/尺寸。日志：`build/verification/full-2026-10-10/ios/processor-export-final.log` 等。 |
| iOS 完整界面与成片 | iOS 26.4 / iPhone 17 Pro 新独立模拟器 `87728BCF-7E00-476A-B173-E3636F1C3A5A` 上最新 **8/8 EditorUITests** 通过，包括真实 DNG 选片、叠层原尺寸 3072×3072 与三态、横竖屏、大字、缩放、编辑记忆、批量和单张尺寸。宿主只读查询新图库记录并用 ImageIO 实际解码：批量 **128×128**、单张 **1024×1024**、原尺寸 **3072×3072**。`RawLab/tests/editor-ui.sh` exit 0；日志、xcresult、截图、尺寸记录：`build/verification/ios-original-info-clean-final/`。原尺寸元数据模型回归 9 项通过，日志 `build/ios-info-original-size-green.log`。 |

## 修复结果与边界

- Android 的批量预览 90 秒失败已修复。诊断复跑记录界面仍为 spinner、线程停在 `NativeProcessor.nativeProcess`，没有原生错误：`build/android-batch-preview-diagnostic.log`。原因是效果查看对整张 RAW 先做精确 CPU 降噪再缩小。现在仅该预览采用已有 interactive 路径先限长，最终导出未改，原测试的 90 秒上限未放宽；本轮 44/44 已通过。前次失败日志保留，作为 RED 证据，不作为当前结果。
- Windows 自动选中文件的缺口已补齐。严格断言首次等待 2 分钟仍为 count 0（`build/windows-selection-red.log`）；独立 STA 原生 probe 观察到 TXT 首次正确、ARW 首次仅 focus 而未 selected，目录加载后再调用可选中（`build/windows-shell-selection-native-probe2.log`），RAW 属性是 Archive 而非 Hidden。现在初次打开后等待实际 Shell view 并明确选择，只有连续单选匹配才完成；桌面 37 项检查中的文件选择断言保持精确路径且持续 500 ms，最新日志 `build/windows-selection-fixed.log` 明确为 count 1 / `target.ARW`，计划任务结束后读回 exit 0。目录节点打开仍独立通过。
- Android 覆盖一台真机；iOS 覆盖模拟器，不等于 iOS 真机验证。未进行商店签名、发布、安装升级兼容或所有设备/系统版本矩阵测试。
- RAW 样片、生成图片、日志和截图均为测试材料，保存在忽略的构建目录、临时目录或专用模拟器中。没有删除原有模拟器图库或原工作区的用户改动。

## 验证发现的修复

- Mac 保存尺寸附件未观察 `EditorModel.exportLongEdge`，选择尺寸后数值控件不刷新。改为 `@ObservedObject` 附件，回归真实 NSSavePanel 的 native NSTextField 变化；实际 UI 选择和 512 px 成片也通过。
- Mac 的 SwiftUI List 把同一行两个照片菜单合并，实际右击第二张却在 Finder 中选中第一张。改用每张缩略图独立的 AppKit 命中与菜单；复测第二张 Finder 选中、复制设置、普通左键导航均正确。
- Windows 批量自定义值未失焦时，导出可能采用旧尺寸，且切换格式会丢掉非法草稿。改为即时校验、保留草稿、导出前提交有效尺寸；真实 512 px 批量文件和 journal 通过。
- iOS 缺少支持方向声明，横屏测试仍保持竖屏。增加 Portrait / LandscapeLeft / LandscapeRight；实际横屏布局和完整 UI 回归通过。缺省 Portrait 的依据见 [Apple UISupportedInterfaceOrientations](https://developer.apple.com/documentation/bundleresources/information-property-list/uisupportedinterfaceorientations)。
- iOS 测试此前以文件名前缀选片，误接受带相同拍摄日期/同名前缀的已导出 JPEG。现在要求信息叠层包含完整 DNG 文件名，并通过稳定的叠层 AX label 检查，不再遍历会变化的 StaticText 索引。图库像素核验移至宿主只读脚本，避免 UI runner 额外图库权限导致假通过或阻塞。
- 截图复核发现 iOS ImageIO 顶层 RAW 尺寸来自内嵌预览：实际 DNG 返回 720×720，但 DNG DefaultCropSize 为 3072×3072；Sony ARW 返回 1616×1080，但 EXIF 为 7008×4672。共享信息模型仅对 UTType RAW 优先使用 DNG crop / EXIF 原尺寸，普通 JPEG 仍使用实际编码尺寸，随后统一应用方向。三项新增模型回归先失败后通过，界面测试增加实际 DNG 的 3072×3072 断言。
- Android 仅批量效果查看启用交互预览，避免 32 MP RAW 的全尺寸 CPU 降噪阻塞查看。批量/单张最终输出继续走 `export` / FINAL；实际像素一致性回归通过。
- Windows 在 RAW 目录首次加载完成后补齐文件选择；使用 [ShellFolderView.SelectItem](https://learn.microsoft.com/en-us/windows/win32/shell/shellfolderview-selectitem) 的 select / deselect others / ensure visible / focus 标志，持续核验精确路径，释放 PIDL 和所有获取的 COM 对象。测试不再以目录存在代替文件选中。
- 在已有测试导出照片的模拟器复跑时，批量按钮等待超时，保存的 journal 目标列表为空；原选片条件只匹配日期，无法区分同日期的原图与导出 JPEG。后续空编辑器用例又受未完成批量任务恢复影响。测试现在复用刚按完整文件名验证过的原图位置；整套空态/批量回归使用新的专用模拟器，不删除旧图库或任务来制造空态。失败诊断日志仍保留在 `build/verification/ios-original-info-size-final/`。

## 环境恢复

- Android ZUI `GET_INSTALLED_APP` 仅为 debug instrumentation 临时设为 allow，最终已设置并读回 **`mode=10`**；正式版本没有新增该权限，也未更改锁屏或全局安全/显示设置。
- Windows 只清理本次测试目录的 Explorer 窗口和两个临时计划任务；用户登录会话保留。测试构建/原始日志保留供复核。
- Mac 的独立测试 bundle、旧 worktree 测试进程和测试 Finder 窗口已关闭，原工作区正在运行的应用保留。
- 本次创建的闲置 iOS 模拟器已关闭而未删除图库；原有模拟器保留。

## 本次复核

独立只读复核确认：四端限长导出均为 FINAL；Windows 目录复制不依赖目录加载缓存；Mac 独立右键目标与观察模型附件无阻塞问题；Windows Shell PIDL 在异步返回后正确释放；RAW 原尺寸元数据优先级不改写 raster / 导出像素，统一方向逻辑保留。提交前 `git diff --check` 通过。
