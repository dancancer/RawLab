# RawLab Windows
镜头校正与共享核心一致，支持畸变、横向色差、自动/手动匹配及自动裁边，配置接入逐照片记忆和批量任务。离线数据库、依赖和功能边界见[跨平台说明](../docs/lens-correction-platforms.md)。`build-remote.py --workspace C:/RawLabBuild/<feature>` 可隔离远程构建目录。


原生 WPF / .NET 8 Windows x64 客户端，复用 Mac 版的 C++ / LibRaw 显影管线。
支持 Windows 10/11 x64，默认使用 Direct3D 11 硬件加速，失败自动回退 CPU。

0.8 编辑器与 Agent 已合入集成源码。统一参数行、原生菜单、几何/镜头草稿及各轮验证边界见 [Windows 0.8 验证记录](VERIFICATION-v08.md)。实际发布状态、包版本和校验和以 GitHub Release 及随包 provenance 为准。

Agent v08 接入了共享 v4 JSON/CLI、普通 JPEG/PNG/经典 TIFF 和默认单张预览。
普通图像只接受单帧、不透明的 8-bit SDR RGB，最多 64M 像素；方向与 ICC 转 sRGB 各处理一次，
不套用 RAW 曝光基线、相机白平衡、FBDD 或镜头校准。HEIF、BigTIFF、透明、高位深、浮点/HDR、CMYK、多帧以及不支持的色彩描述会明确拒绝，不能据此宣称支持所有 ICC。
新窗口、重新打开及历史恢复默认关闭对比；同图手动选择的并排/滑动会保留到切图。
Windows 各轮实测源码快照、限制及物理项目见 [Agent v08 验证记录](VERIFICATION-agent-v08.md)；历史源码验证不替代最终候选包验收。

v0.5.0 新增逐照片本机调整记忆和独立批量导出窗口。任务固定当前参数、降噪设置和外观，多选 RAW 后输出 JPEG/16-bit PNG；当前版本还支持渲染型 DNG，支持效果检查、逐项结果、取消、失败重试与启动恢复；不改写 RAW 或目标编辑记录。验证范围见[验收记录](../docs/archive/verification/verification-edit-memory-batch-export-2026-10-10.md)。

## 下载 v0.8.0 Windows 包

[Windows x64 独立运行包](https://github.com/dancancer/RawLab/releases/download/v0.8.0/RawLab-Windows-0.8.0-win-x64.zip) · [发布说明](https://github.com/dancancer/RawLab/releases/tag/v0.8.0) · [SHA-256](https://github.com/dancancer/RawLab/releases/download/v0.8.0/SHA256SUMS.txt)

解压后运行 `RawLab.exe`，保留完整目录。版本0.8.0/build12，self-contained .NET8；包含 Visual C++ 运行库、LUT、Lens DB 与 ExifTool，程序未签名。桌面 Agent、几何、JPEG/PNG/TIFF 普通图像和混合批量复用现有处理核心；默认单图预览，按需启用对比。实际候选包、GPU/UI 覆盖和已知限制见[发布验收](../docs/releases/v0.8.0-preparation.md)及随包 BUILD-PROVENANCE。

## 构建

需要 .NET 8 SDK、Visual Studio 2022 Build Tools 的“使用 C++ 的桌面开发”组件
（含 Windows SDK 与 CMake），首次构建需要联网下载校验过的 LibRaw 0.22.2 / zlib 1.3.1 /
libtiff 4.7.1 源码。

```powershell
./RawLabWindows/build.ps1 -Test
# 或显式指定外部样片：
./RawLabWindows/build.ps1 -Test -RawPath 'Z:\Photo\2019\2019-02-02\_DSC0205.ARW'
# 不要求目标机器安装 .NET 的独立发布：
./RawLabWindows/build.ps1 -SelfContained
./build/RawLab-Windows/RawLab.exe
```

构建默认输出 `build/RawLab-Windows`，必须保留整个目录；可将整个目录打包为 ZIP。
默认包需要 .NET 8 Desktop Runtime，`-SelfContained` 包含运行时。
支持 `-DotNet <dotnet.exe>` / `-CMake <cmake.exe>` 指定工具。
脚本也会使用仓库 `build/tools/dotnet` 下的本地 SDK（若存在）。

Release 包默认带阿里云 RUM PC SDK 0.4.4（`alibabacloud_rum.dll`），使用统计默认开启、以
`env=PROD` 上报。SDK 取主工作区 `.cache/shared/aliyun-rum/windows/0.4.4/sdk.zip`，缺失时从供应商
带版本号的地址下载；压缩包和 DLL 的 SHA-256 都固定，不符即停止。`-RumSdkZip <zip>` 指定自备的
压缩包，`-NoRumSdk` 出不带 SDK 的离线包。打包后可用
`experiments/rum-local/windows/verify-licenses.ps1 -Package build/RawLab-Windows` 核对 SDK 与许可文件。
Debug 构建不带 SDK。
未签名，不自动安装、不修改系统文件关联。第三方许可证与说明随程序复制。

### 从 Mac 远程编译

已准备好的 Windows x64 OpenSSH 编译机可直接构建当前工作区，不需要先提交或切换到 Windows 真机：

```bash
python3 RawLabWindows/build-remote.py \
  --host <user>@<windows-host> \
  --identity ~/.ssh/rawlab_vm100 \
  --known-hosts ~/.ssh/rawlab_vm100_known_hosts
```

首次连接前，通过可信控制台核对 SSH 主机公钥并保存到 `known-hosts` 文件。脚本强制校验主机密钥，只使用指定私钥；不要提交私钥或关闭校验。

脚本发送当前已跟踪及未忽略的新源文件，包含尚未提交的改动，排除个人 RAW 样片和忽略的构建产物；仅白名单中的四个合成 DNG 回归 fixture 随源码发送。Windows 工作目录为 `C:/RawLabBuild/workspace`，保留依赖和编译缓存，只清理上次清单中已从本次源码删除的文件。请勿让多个任务同时使用这个工作目录。远程编译自包含 x64 包并取回 `build/windows-remote/<timestamp>/RawLab-Windows.zip`，同目录保留完整 `build.log`。

`--test --raw /path/to/sample.ARW` 会另外上传指定样片并执行原有完整测试。编译不要求 GPU，但完整 GPU 测试要求实际 Direct3D 11 执行；仅有虚拟机编译结果或显示适配器名称，不能据此声明 GPU 通过。未使用 `--test` 时不运行完整测试。

新建专用 Windows 编译机时，管理员可使用 [provision-build-tools.ps1](scripts/provision-build-tools.ps1) 安装校验过的 .NET 8.0.425 SDK 和 VS 2022 Build Tools 17.14.41。脚本需要预先下载的官方安装包，检查固定摘要和 Microsoft Authenticode 签名，安装 C++、Windows SDK、CMake 与托管桌面构建组件；不负责 Windows 授权或 SSH 配置。

```powershell
./RawLabWindows/scripts/provision-build-tools.ps1 -InstallerDirectory 'D:\'
```

平台实测范围见 [RAW 兼容性验证记录](../docs/archive/verification/verification-raw-compatibility-2026-10-09.md)；虚拟机编译结果不替代真机 GPU 和交互性能验收。

## 功能与 Mac 对齐

| 功能 | Windows 实现 |
|---|---|
| 照片打开、拖放、多目录文件树 | RAW、JPEG/PNG/经典 TIFF；原生对话框；文件夹可直接拖入左侧空白处或目录行并记住，重复路径去重，不移动源文件；目录按需展开；拖动右侧边界调整宽度；缩略图自动单/双列，文件名在下方，超长省略、悬停显示全名 |
| 缩略图 | RAW 只提取内嵌预览，不解包/显影；普通图像复用严格 WIC 解码/方向/色彩入口后缩小；最多两个后台读取任务 |
| 胶片 | 独立“胶片”类别，选中后显示胶片列表；同一套十种 LUT 与包装图；支持中性、多选导入兼容 CUBE/RLOOK；导入项使用会话内的外部文件引用 |
| 调整 | 胶片强度 0–200%（默认 100%）、曝光、色温、色调、对比度、高光、阴影、S 曲线、饱和度、锐化 |
| 几何 | 八手柄/移动裁切、比例预设、百分比精调、左右 90° 旋转、翻转、±45° 拉直及水平/垂直透视；独立草稿预览，应用后才保存并可冻结到批量任务 |
| 效果 | 独立暗角和颗粒工具；暗角强度/中点/圆度/羽化/高光保护，颗粒强度/大小/粗糙度；辅助参数可单项或分组重置，强度为零时保留编辑值 |
| 降噪 | 小波亮度/色彩/粗色斑参数与独立显示色彩降噪模式；所有模式按每次显影请求写入 native 会话 |
| 白平衡 | 拍摄时相机增益；校准后的 2000–50000 K / ±150 色调；倒色温滑杆 |
| 曝光基准 | 标准显影、匹配内嵌预览、传感器基准；显示实际基础偏移 |
| 数值输入和重置 | 五列参数行、精细网格、Enter/失焦提交、Esc 恢复当前输入；有效数值框内限速滚轮调整，单项/分组/全部重置 |
| 逐照片编辑 | 本机自动保存并恢复各照片参数和 LUT 身份；失败可重试，不写回 RAW |
| 对比 | 顶部菜单切换并排 / 左右滑动 / 关闭；中性与修改后共享缩放、平移；适合窗口、100% 实际物理像素 |
| 直方图 / 裁切提示 | 最终 sRGB 显示图统计；RGB 线性计数、重叠填色；可折叠 |
| 调整栏 | 底部圆形工具与带正负方向的进度环；拖动边界调高、收起恢复 |
| 交互预览 | 一个进行中请求和一个最新待处理请求；拖动 1000px，松手精确 2000px / 原尺寸 |
| 导出 | 精确预览完成后允许导出；原 RAW 全分辨率 JPEG / 真 16-bit PNG（保留拍摄 EXIF）以及渲染型 DNG；失败不替换目标文件 |
| 加速 | Direct3D 11 计算着色器；GPU 自动 / 仅 CPU / 强制 GPU；显示实际后端 |

`Ctrl+O` 打开，`F` 适合窗口，`1` 实际像素，`+/-` 缩放。
顶部图标悬停显示名称，导出菜单提供 JPEG / 16-bit PNG / 渲染型 DNG。
滑动对比时拖动中央分隔线；画布获得焦点后，左右方向键微调，`Home` 回到中央。
下拉框、右键菜单和滚动条使用统一深色样式；键盘焦点和选中项使用黄色标识。
拖动画布平移、滚轮缩放。双击照片画布在适合窗口与 100% 实际像素之间切换并复位平移；手动缩放后双击回到适合窗口。双击对比分隔线不会改变缩放。文件树右键移除只修改目录列表。
中文 RAW / LUT / 导出路径以 UTF-8 通过 C ABI，原生层转换为 Windows Unicode 路径。

JPEG 和 PNG 导出自动保留可读取的相机、镜头、拍摄时间、快门、光圈、ISO、GPS 等拍摄信息。
方向固定为正常，尺寸与 sRGB 标记按显影结果更新；不复制 RAW 传感器布局、旧缩略图
或不透明的 MakerNotes。JPEG 压缩图像数据保持不变，PNG 使用标准 `eXIf` 块并保留
16-bit 通道。无拍摄 EXIF 的输入仍可导出。元数据写入失败时不会替换已有目标文件。
渲染型 DNG 使用已应用全部调整的输出图像，不写入来源 RAW 的拍摄 EXIF；它的外观已烘焙，
不能从 DNG 恢复为原始 RAW 调整。DNG 不需要 ExifTool。

构建脚本会下载并校验 ExifTool 13.59 的 Windows x64 发行包，完整随附于 `ExifTool/`
目录（含 Perl、源码和许可证）；无需用户另行安装。请保留完整安装包目录。

不支持任意输入色彩空间的 CUBE；需声明兼容的 Fuji F-Log/F-Log2/F-Log2C
输入和 BT.709 显示或受支持的 Log 输出。RLOOK 使用 CPU 回退，不是 Direct3D 原生 DCP 加速；导入时逐文件验证并报告失败、保留成功项，仍引用原路径，没有新增 Mac/Android 的托管库同步。细节与色彩约定见 [处理契约](../lutools/docs/color-contract.md)。
显示 Kelvin 是相机校准估计，不等同于 Lightroom 私有配置值。

## 打开、缩放与性能

选中照片立即复用已有缩略图，并优先读取相机内嵌预览；状态栏标识它尚未应用当前显影设置。
随后显示 1000px RAW 快速预览并补齐精确显影；只有精确结果完成后才允许导出。
双击立即按原图尺寸放大现有画面，再后台补齐原尺寸细节；平移仅更新图层变换，两侧对比共享视口。

当前照片的适合窗口/原尺寸精确图像缓存最多占用 256 MiB 像素数据，参数、对比/裁切提示、GPU 模式或 RAW/LUT 文件变化会失效。
这一上限不含正在显示的图像、原生显影数据和 GPU 纹理；导出始终单独生成全分辨率结果。
LibRaw 去马赛克和 RAW 颜色转换启用多核 CPU，发行目录随附 OpenMP 运行库。
关闭对比时只生成修改后图片；裁切提示关闭时不生成提示蒙版。

本机 Sony ARW 的前后测试中，首次出现画面从 1059 ms 降至 43 ms（相机内嵌预览），重复原尺寸放大从约 410 ms 降至 4 ms，拖动期间合成回调平均间隔从 60.7 ms 降至 31.5 ms。
首次原尺寸细节仍约需 0.4 秒；测试使用本地文件且未清空文件缓存，远程显示为约 32 Hz，不能据此推断网络盘冷读取速度或本地高刷新率表现。
测量方法、输出一致性与验证范围见 [性能记录](performance.md)。

## 硬件加速

RAW 显影的 Direct3D 11 计算与 WPF 画布绘制是独立的加速路径，状态栏的 GPU 后端表示前者。
应用通过 `Switch.System.Windows.Media.EnableHardwareAccelerationInRdp` 为支持的远程桌面会话启用 WPF 硬件绘制，不修改系统注册表。
实际流畅度仍受远程显示刷新率、连接和驱动影响。

需要支持 Direct3D feature level 11.0 的硬件显卡。优先选择独立显存较大的硬件
适配器，不将 WARP 软件渲染器标记为 GPU。矩阵、线性曝光、F-Log2、3D LUT、
强度、明暗/色彩、细节、暗角/颗粒、小波过滤、显示色度引导滤波和双线性缩放在 GPU 执行。
锐化、暗角/颗粒和显示色度均在原像素尺度处理。RAW 解包、白平衡、去马赛克、
高光重建、噪声估计、OpenCV Lab 转换、文件编码及直方图统计保留在 CPU。
每个会话复用 GPU 设备、LUT、线性 RAW 上传及中间缓冲；切换白平衡后更新上传。

“GPU 自动”在设备创建、资源分配或渲染失败后走 CPU，并在状态栏显示回退。
“强制 GPU”遇到错误直接失败，可用于确认 GPU 是否真正生效。全分辨率照片需要
较多显存，显存不足时自动模式仍能导出。诊断环境变量 `RAWLAB_DISABLE_D3D11=1`
用于验证自动回退及强制失败；正常运行不要设置。

跨平台接入的构建与运行范围见 [本轮验证记录](../docs/archive/verification/verification-cross-platform-effects-gpu-denoise-2026-10-10.md)。
Windows 托管层交叉编译通过不代表新的 D3D11 着色器或硬件路径已运行。

## 验证

`build.ps1 -Test` 运行共享核心 CTest 和独立的 Windows 测试程序，测试参数映射、
调度、外部 Sony ARW、中文路径、缩略图、直方图、白平衡、曝光基准、PNG 位深和
全分辨率导出。托管测试覆盖暗角/颗粒默认值、范围、40 字节 versioned ABI、旧记录迁移、
编辑记忆和批量快照。GPU 测试还检查 CPU / Direct3D 11 像素差异、细节边界、LUT 域、
交互/精确/导出隔离，要求测试机器具有上述硬件。输出保存在忽略的 `build/windows-verification`。
可选 DJI / 高光样片未随仓库提供时，不把缺少样片算作已验证。
测试不再依赖仓库内置 RAW。`-Test` 默认从 `Z:\Photo\2019\2019-02-02` 按文件名
选择首张 ARW，也可使用 `-RawPath` 或 `-RawDirectory`。仅复制到忽略的 build 目录
执行测试，不在照片目录写入、重命名或删除文件。核心 CMake 可独立指定
`-DSONY2FUJI_TEST_RAW=/path/to/sample.ARW`；未指定时跳过真实 RAW 相关测试。
测试也生成 WPF 窗口截图供布局检查；人工使用时仍应检查不同显示缩放、多屏与大目录。

空编辑器主窗口的关于回归不需要 RAW 或 native DLL，可在 Windows 上单独运行：

```powershell
dotnet build RawLabWindows/tests/RawLabWindows.Tests.csproj -c Release
dotnet RawLabWindows/tests/bin/Release/net8.0-windows/RawLabWindows.Tests.dll --about
```

该入口覆盖打开、关闭、再次打开关于窗口，以及版本显示和六语刷新；使用临时更新设置，
不写用户语言偏好。测试账户须没有待恢复的批量任务，否则测试会停止以保留原任务。
`build.ps1 -Test` 也包含此回归。

当前 Windows 回归还覆盖内嵌预览尺寸与方向、精确缓存上限及失效、预览不能启用导出、原尺寸几何和不重绘图像的平移。
几何处理复用共享核心，依次执行旋转、翻转、居中内接拉直、归一化裁切，最后调整输出尺寸。
裁切百分比以旋转和拉直后的画布为基准；超出边界的数值收回画布内。中性对比图使用同一套几何参数，原 RAW 保持不变。
托管设置检查覆盖 40 字节几何 ABI、旧记录默认值、快照与批量恢复；Windows 原生定向入口为
`dotnet RawLabWindows/tests/bin/Release/net8.0-windows/RawLabWindows.Tests.dll --geometry <repo> <RAW>`。
macOS 上的 WPF 交叉编译及托管测试不代表 Windows 原生或 D3D11 运行验证。

`run-v08.ps1` 包含 `editor-review` 回归，也可直接运行
`RawLabWindows.Tests.dll --editor-review <repo> <RAW>`。它通过真实主窗口的批量接线，
控制单张导出/外观导入与预检的两种完成顺序，检查编辑、切图、延迟关闭及实际 PNG 发布；
并检查几何/镜头离开对话框在精确预览完成后启用“应用并离开”。还覆盖真实主窗口在
journal 清理失败后的恢复与重试、Running 批量的当前项完成后关闭，以及导入/单张导出与
批量两种完成顺序下的 viewport resize 恢复，包含降噪 debounce 和独立 CPU 视口像素比对。
测试通过 dispatcher 完成回调和批量首项 Running 进度 post 固定时序，仍执行真实 native
工作，不依赖机器速度或物理文件选择器，也不向产品代码增加测试控制入口。
边界裁框旋转的模型回归在 editing 中，水平/垂直翻转的真实控件回归在 transform-ui 中。

主测试程序的共同入口在分派默认或专项套件前检查 `%LOCALAPPDATA%/RawLab/Batch/job.json`，
存在即拒绝运行；默认套件完成 native 检查后、WPF 初始化前再检查一次。使用没有产品任务并发运行的独立测试账号，
不要为运行测试删除或移动已有 journal。默认窗口的 EditStore 仍使用每次运行独立的目录。
`run-v08.ps1` 的 `default-isolation` 回归也可直接运行
`RawLabWindows.Tests.dll --default-isolation <output>`，不需要 RAW 或系统目录重定向。
它对同一共同入口传入任务私有的 journal 路径，覆盖 Running/Publishing、完整与 UI-only
参数、photo-features/interactions 分派、文件锁和损坏 JSON，检查拒绝后 journal、staging、成片的文件列表、字节和修改时间不变，
且不创建输出或 WPF Application。另一个私有对照调用真实恢复清理，证明 fixture 确实能触发风险。

独立 `localization-ui/LocalizationUiChecks.csproj` 也在任何偏好处理或 WPF 启动前执行同一保护。
其 `--default-isolation <output>` 回归使用私有 Running/Publishing、文件锁和损坏 JSON，
确认 journal/staging/源文件/成片的文件列表、字节、修改时间保持，且未进入启动或语言处理。
正常六语测试改用私有语言文件，不再备份、覆盖或恢复真实 `language.txt`。
测试保留真实 App.OnStartup、StartupUri 自动创建窗口和语言订阅；测试侧的 Loaded 类处理器
先于窗口的 Loaded 实例处理器注入私有状态，避免自动更新副作用。这仍不是物理桌面或真实 profile 重启验收。

直接构造 WPF 主窗口的测试在 Show 前通过 `TestWindowState` 使用私有 Edits、Batch、目录库和禁用自动更新的配置；
独立 StartupUri 路径在 Loaded 类处理器中完成同样隔离，先于产品的 Loaded 实例处理器。
防止 Loaded 写入默认 `updates.json` 或发起后台网络请求。窗口构造仍读取默认配置，所以入口保护和独立账号要求继续有效；
这不是跨进程锁或完整用户配置虚拟化。`run-v08.ps1` 会构建两种可执行程序，并包含
`localization-admission`、`profile-isolation`、`localization-ui`、`status-layout` 和 `updates` 检查。
状态栏布局回归覆盖六语言、两种窗口尺寸、普通/放大文字及保存/重试/导出/批量提示显隐，
不替代物理 DPI、辅助功能或 Explorer/OLE 验收。
`ui-details`（`RawLabWindows.Tests.dll --ui-details <output>`）不需要 RAW 或 native DLL，按六语检查发布前的界面细节：
工具栏与工具条图标不重复、几何操作图标形状不相近，中日文不夹英文原词、外观名称按语言显示，
语言下拉框与文件树显示名称而非类型名，相邻位置不重复同一名称或数值，重置按钮不多余且对齐，
色块与文字不被截断，工具说明不在词中间断行，选中状态、下拉菜单位置、启动目录提示与打开失败状态正确。

普通图像和单张预览的功能回归可通过同一入口选择：

```powershell
./RawLabWindows/tests/run-v08.ps1 -RawPath 'C:/samples/photo.ARW' -NativeArtifacts 'build/RawLab-Windows' -Only 'raster,comparison-default'
```

`raster` 比较 GUI renderer、CLI 和冻结 BatchRunner 的 FINAL 像素；`comparison-default`
覆盖主窗口的菜单、历史恢复、文件树/拖放处理器和实际混合批量导出。两者都不是物理输入验收。
独立原生交互入口另行构建无产品程序集引用的 UIA driver，通过真实 Windows 文件选择器和跨进程控件
执行 RAW/PNG/JPEG 打开、对比切换、调参及私有 profile 重启恢复：

```powershell
./RawLabWindows/tests/run-comparison-native.ps1 -RawPath 'C:/samples/photo.ARW' -NativeArtifacts 'build/RawLab-Windows'
```

该入口同样先保护默认 journal，运行前后核对默认 RawLab 配置文件字节及修改时间，并将所有写入放在私有目录。
退出码 `0` 表示实际原生交互通过，`2` 表示桌面不可达的 `NOT REACHED`，其他非零表示失败；
详细结果写入独立输出目录的 `summary.json` 和日志。`run-v08.ps1` 不隐式调用这个入口，不能替代其结果。
该验收默认仅 CPU；测试环境变量 `RAWLAB_COMPARISON_GPU=Cpu|Auto|Force` 可选择两次启动的加速模式，
运行后应恢复原环境变量。Force 会核对 RAW 实际 GPU backend，PNG/JPEG 必须显示 CPU，返回 RAW 后恢复原模式。
原生 UIA 本身仍不代表 Explorer/OLE 拖入、真实鼠标/触控笔、物理 GPU 或多显示器验收。
VM 和 125 真实主机的原生通过结果、独立 PID/LUID 显存采样及未覆盖项目见 [验证记录](VERIFICATION-agent-v08.md#native-desktop-follow-up-2026-10-16)。

`editor-review` 还覆盖空闲批量窗口同步关闭失败时的 pending viewport resize：锁住私有 journal，
分别保留和不保留前台导入，确认无需额外输入即可恢复精确预览，且独立 CPU 像素一致。
`appearance` 对已打开的真实窗口执行浅色、深色、浅色高对比度资源切换，检查输入、弹层、
选中/悬停/按下状态、进度和滑条的成对颜色及画布重绘，还检查已存在的滑动分隔线、裁切网格/控制点和
直方图轮廓。直方图保留 RGB 通道语义，高对比度时额外画清晰的包络线；照片及导出像素不变。
测试不更改系统配色，也不替代物理高对比度验收。

`run-v08.ps1 -Only` 接受逗号分隔的套件名，忽略首尾空格、大小写和重复项。省略或空字符串运行全部套件；
非空但仅含空格/逗号的值、未知名称或未实际运行的选择项都会失败。构建始终执行。
每次执行先清空旧 summary，提前失败也留下本轮非零结果，不会沿用上次 PASS。
可单独验证真实 PowerShell 入口（使用私有外部命令替身，不执行产品渲染）：

```powershell
./RawLabWindows/tests/RunnerSelectionChecks.ps1 -Output 'build/windows-runner-selection'
```

`--denoise` 专项同时使用外部真实 RAW 和受控 noisy RAW。真实照片可能不足共享算法要求的
八个平坦图块，不能假定每张照片在每个视口都一定改变像素；受控输入负责验证实际滤波效果。
先在安装了 NumPy、tifffile 的测试 Python 环境生成 fixture，再运行专项：

```powershell
python lutools/tests/make_denoise_fixture.py build/windows-fixtures/denoise.dng
./RawLabWindows/tests/run-v08.ps1 -RawPath 'C:/samples/photo.ARW' -NativeArtifacts 'build/RawLab-Windows' -Only denoise
# fixture 位于其他位置时，显式传入 -DenoiseRaw 'C:/samples/denoise.dng'
```

直接调用测试程序时，可使用 `--denoise <repo> <RAW> <controlled-DNG>`；省略最后一个参数时，
使用 `<repo>/build/windows-fixtures/denoise.dng`，缺少文件会报错，不会跳过滤波断言。
生成的 DNG 属于忽略的测试产物，不提交，也不会被 `build-remote.py` 自动发送；远程专项前须
单独生成或传送到任务自己的构建目录。`build.ps1` 保持 ASCII，以免 Windows PowerShell 5.1
按系统 ANSI 编码读取时吞掉命令；`tests/BuildScriptChecks.ps1` 检查这一约束及测试构建命令的 AST。

完成 `build.ps1 -Test` 后，可单独运行以下可见窗口测量；它会打开测试窗口并自动缩放、平移，输出首次画面、原尺寸细节和合成回调间隔：

```powershell
dotnet ./RawLabWindows/tests/bin/Release/net8.0-windows/RawLabWindows.Tests.dll --interactions $PWD.Path 'C:/samples/photo.ARW'
```

历史版本验证通过 119 项 Windows 检查；Sony/DJI 共 38 组输出像素哈希与优化前一致。共享核心当时 11 项 CTest 通过；这些结果不替代[本轮跨平台验证](../docs/archive/verification/verification-cross-platform-effects-gpu-denoise-2026-10-10.md)。

本机样片、GPU 像素差异和性能结果见 [验证记录](verification.md)。

### 恢复、入口及资源回归

`--editor-review <repo> <RAW> [part]` 省略 part 时运行所有编辑器场景；子场景名忽略大小写和首尾空格，
未知或显式空值直接失败，不创建样片或窗口。主测试程序也拒绝未知模式、错误参数数量及错误的 `--ui-only`。
下列独立检查同样先保护已有默认 journal/staging，并使用私有窗口配置：

```powershell
dotnet <TargetDir>/RawLabWindows.Tests.dll --entry-selection <repo> <RAW>
dotnet <TargetDir>/RawLabWindows.Tests.dll --resources <repo> <RAW>
```

`--resources` 在一次预热后执行三轮真实 RAW 的 CPU 编辑、原尺寸/适合窗口、重新打开及关闭，
记录每 100ms 的进程私有内存、工作集、托管内存、CPU 时间和空闲时的预览缓存。
它检查窗口可回收、原生 session 释放、已有缓存预算及 RAW 字节保持不变，不用任意 RSS 上限代替泄漏判断。
结果写入任务目录 `build/windows-resource-checks/`；这是短时单 VM 验证，不是长期压力或物理 GPU 验收。
编辑器回归另检查关闭请求后的缩略图队列停止、失败后的文件树恢复、无变化时不重显影，
以及 1000 次格式检查式拖拽悬停；实际 Drop 仍验证路径，不改写源文件。

`editor-review` 的 `close-pending` 子场景覆盖活动渲染与排队预览并存时的关闭顺序，
以及渲染先结束、批量最后结束且 journal 清理失败后的预览恢复。测试锁定私有 journal，
并与独立 CPU 显影像素核对，不依赖 pending resize 来掩盖排队请求。
`usage-lifecycle` 通过真实主窗口、About 和批量窗口验证启动、导入、外观切换、导出、
部分失败重试及等待发送完成后的退出；只使用私有 consent 和假 transport，不发送网络事件。
所有通过 `TestWindowState.Isolate` 创建的窗口同时替换 analytics，避免保留默认同意状态或 SDK transport。
