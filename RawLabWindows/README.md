# RawLab Windows

原生 WPF / .NET 8 Windows x64 客户端，复用 Mac 版的 C++ / LibRaw 显影管线。
支持 Windows 10/11 x64，默认使用 Direct3D 11 硬件加速，失败自动回退 CPU。

## 下载 v0.2

[下载 Windows x64 独立运行包](https://github.com/dancancer/RawLab/releases/download/v0.2/RawLab-Windows-0.2-win-x64.zip) · [完整发布说明](https://github.com/dancancer/RawLab/releases/tag/v0.2) · [SHA-256 校验](https://github.com/dancancer/RawLab/releases/download/v0.2/SHA256SUMS.txt)

解压后运行 `RawLab.exe`，保留完整目录。发布包已包含 .NET 8、Visual C++ 运行库、LUT 和 ExifTool，无需另行安装 .NET。程序未签名。

v0.2 支持 0–200% 胶片强度（默认及重置为 100%），JPEG / 16-bit PNG 导出保留拍摄 EXIF。
下文的快速预览、缩放缓存和远程桌面画布加速属于当前源码改动，尚未包含在上述 v0.2 下载包中；请按构建说明生成新版。

本次已验证的 Windows x64 独立运行包随仓库提交，供 Mac 端统一发布，见 [发布交接与校验说明](../release-artifacts/windows/2026-10-08/README.md)。

## 构建

需要 .NET 8 SDK、Visual Studio 2022 Build Tools 的“使用 C++ 的桌面开发”组件
（含 Windows SDK 与 CMake），首次构建需要联网下载校验过的 LibRaw 0.21.5 / zlib 1.3.1 源码。

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
未签名，不自动安装、不修改系统文件关联。第三方许可证与说明随程序复制。

## 功能与 Mac 对齐

| 功能 | Windows 实现 |
|---|---|
| RAW 打开、拖放、多目录文件树 | 原生对话框；目录按需展开；拖动右侧边界调整宽度；缩略图自动单/双列，文件名在下方，超长省略、悬停显示全名 |
| 缩略图 | 只提取内嵌预览，不解包/显影 RAW；最多两个后台读取任务 |
| 胶片 | 独立“胶片”类别，选中后显示胶片列表；同一套十种 LUT 与包装图；支持中性、导入兼容 CUBE |
| 调整 | 胶片强度 0–200%（默认 100%）、曝光、色温、色调、对比度、高光、阴影、S 曲线、饱和度、锐化 |
| 白平衡 | 拍摄时相机增益；校准后的 2000–50000 K / ±150 色调；倒色温滑杆 |
| 曝光基准 | 标准显影、匹配内嵌预览、传感器基准；显示实际基础偏移 |
| 数值输入和重置 | 滑杆、数字、单项/分组/全部重置；保留照片与胶片选择 |
| 逐照片编辑 | 本次会话内保留各照片参数和 LUT；不写回 RAW |
| 对比 | 顶部菜单切换并排 / 左右滑动 / 关闭；中性与修改后共享缩放、平移；适合窗口、100% 实际物理像素 |
| 直方图 / 裁切提示 | 最终 sRGB 显示图统计；RGB 线性计数、重叠填色；可折叠 |
| 调整栏 | 底部圆形工具与带正负方向的进度环；拖动边界调高、收起恢复 |
| 交互预览 | 一个进行中请求和一个最新待处理请求；拖动 1000px，松手精确 2000px / 原尺寸 |
| 导出 | 精确预览完成后允许导出；原 RAW 全分辨率 JPEG / 真 16-bit PNG，保留拍摄 EXIF；失败不替换目标文件 |
| 加速 | Direct3D 11 计算着色器；GPU 自动 / 仅 CPU / 强制 GPU；显示实际后端 |

`Ctrl+O` 打开，`F` 适合窗口，`1` 实际像素，`+/-` 缩放。
顶部图标悬停显示名称，导出菜单提供 JPEG / 16-bit PNG。
滑动对比时拖动中央分隔线；画布获得焦点后，左右方向键微调，`Home` 回到中央。
下拉框、右键菜单和滚动条使用统一深色样式；键盘焦点和选中项使用黄色标识。
拖动画布平移、滚轮缩放。双击照片画布在适合窗口与 100% 实际像素之间切换并复位平移；手动缩放后双击回到适合窗口。双击对比分隔线不会改变缩放。文件树右键移除只修改目录列表。
中文 RAW / LUT / 导出路径以 UTF-8 通过 C ABI，原生层转换为 Windows Unicode 路径。

导出自动保留可读取的相机、镜头、拍摄时间、快门、光圈、ISO、GPS 等拍摄信息。
方向固定为正常，尺寸与 sRGB 标记按显影结果更新；不复制 RAW 传感器布局、旧缩略图
或不透明的 MakerNotes。JPEG 压缩图像数据保持不变，PNG 使用标准 `eXIf` 块并保留
16-bit 通道。无拍摄 EXIF 的输入仍可导出。元数据写入失败时不会替换已有目标文件。

构建脚本会下载并校验 ExifTool 13.59 的 Windows x64 发行包，完整随附于 `ExifTool/`
目录（含 Perl、源码和许可证）；无需用户另行安装。请保留完整安装包目录。

不支持任意输入色彩空间的 CUBE；与 Mac 相同，需声明兼容的 F-Gamut / F-Log2
输入及显示输出。细节与色彩约定见 [处理契约](../lutools/docs/color-contract.md)。
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
强度、明暗/色彩、细节和双线性缩放在 GPU 执行。锐化始终在原像素尺度处理。
RAW 解包、白平衡、去马赛克、高光重建、文件编码及直方图统计保留在 CPU。
每个会话复用 GPU 设备、LUT、线性 RAW 上传及中间缓冲；切换白平衡后更新上传。

“GPU 自动”在设备创建、资源分配或渲染失败后走 CPU，并在状态栏显示回退。
“强制 GPU”遇到错误直接失败，可用于确认 GPU 是否真正生效。全分辨率照片需要
较多显存，显存不足时自动模式仍能导出。诊断环境变量 `RAWLAB_DISABLE_D3D11=1`
用于验证自动回退及强制失败；正常运行不要设置。

## 验证

`build.ps1 -Test` 运行共享核心 CTest 和独立的 Windows 测试程序，测试参数映射、
调度、外部 Sony ARW、中文路径、缩略图、直方图、白平衡、曝光基准、PNG 位深和
全分辨率导出。GPU 测试还检查 CPU / Direct3D 11 像素差异、细节边界、LUT 域、
交互/精确/导出隔离，要求测试机器具有上述硬件。输出保存在忽略的 `build/windows-verification`。
可选 DJI / 高光样片未随仓库提供时，不把缺少样片算作已验证。
测试不再依赖仓库内置 RAW。`-Test` 默认从 `Z:\Photo\2019\2019-02-02` 按文件名
选择首张 ARW，也可使用 `-RawPath` 或 `-RawDirectory`。仅复制到忽略的 build 目录
执行测试，不在照片目录写入、重命名或删除文件。核心 CMake 可独立指定
`-DSONY2FUJI_TEST_RAW=/path/to/sample.ARW`；未指定时跳过真实 RAW 相关测试。
测试也生成 WPF 窗口截图供布局检查；人工使用时仍应检查不同显示缩放、多屏与大目录。

当前 Windows 回归还覆盖内嵌预览尺寸与方向、精确缓存上限及失效、预览不能启用导出、原尺寸几何和不重绘图像的平移。
完成 `build.ps1 -Test` 后，可单独运行以下可见窗口测量；它会打开测试窗口并自动缩放、平移，输出首次画面、原尺寸细节和合成回调间隔：

```powershell
dotnet ./RawLabWindows/tests/bin/Release/net8.0-windows/RawLabWindows.Tests.dll --interactions $PWD.Path 'C:/samples/photo.ARW'
```

本次验证通过 119 项 Windows 检查；Sony/DJI 共 38 组输出像素哈希与优化前一致。共享核心此前 11 项 CTest 通过；其他平台尚未复测。

本机样片、GPU 像素差异和性能结果见 [验证记录](verification.md)。
