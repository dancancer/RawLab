# Agent v0.8 分阶段验证

## 起点与边界

- 本任务独立 worktree：`/Users/xupeng/.codex/worktrees/bb72/rawtools`。
- 2026-10-15 刷新 `origin/development`，起点为 `acfc4ae99b09b16949914cc22f91603007e4d258`。
- 分支 `feature/agent-complete-edits`；只做本地开发、测试和提交，不 push、PR、merge 或发布。
- 不改移动端 Agent、不做 MCP；macOS 收口后才进入 Windows。

## 默认单张预览

本地提交 `c872d9b`。`EditorView` 默认关闭比较，每次照片 URL 变化重置；只保留用户按钮
在同一照片内切换，参数更新及异步渲染不写此状态。编辑持久化不含比较偏好。

- `python3 RawLabMac/tests/test_single_preview.py`：RED 后 GREEN，3 项源码契约通过。
- `bash RawLabMac/tests/edit-model.sh`：历史恢复、未编辑默认、reset、失败保存保护通过。
- 2026-10-15 原生按钮验收已通过，详见下节；源码/模型测试仍单独列出，不代替交互证据。

### 原生交互验收

生产源码为普通图像提交 `bd29910`；用 `bash RawLabMac/tests/single-preview-interaction.sh`
构建单独的 `ComparisonInteraction.app`。复用未修改的生产 `EditorView`/`EditorModel`，
bundle ID 为 `dev.rawlab.agent.single-preview-interaction`，looks/edits/batch 均在
`build/single-preview-interaction/`；没有读写用户的 RawLab 偏好或编辑目录，没有添加生产 test hook。
测试 harness 不读写 compare，既不通过模型调用模拟按钮，也不通过代码自动打开照片。

使用 CUA 实际点击 toolbar Open、NSOpenPanel 的文件行和 Open 按钮、Comparison 按钮，
通过原生 Exposure 数字框及 Tab 提交编辑。实际 AX 状态和截图均在本次任务工具记录中：

- 新空编辑器：Comparison `Closed`。
- 打开真实 DJI RAW：一张 PROVIA 结果图，Comparison `Closed`。
- 点击 Comparison：出现 `Neutral Development` 与 `PROVIA` 两个 pane，状态 `Already turned on`；
  再点击关闭，只剩一张结果图。
- 手动开启后修改 RAW Exposure 至 +0.60、+1.10，直方图和异步结果更新，完整 AX 树仍为
  `Already turned on` 且存在两个 pane。JPEG +0.80 的同样流程也通过。
- 保持开启后依次切换 RAW -> JPEG -> 未编辑 PNG，每次均重置为 `Closed`；新 PNG Exposure 为 0。
- 再打开已有 JPEG/RAW，显示 `Previous Adjustments Restored` 并恢复 +0.80/+0.60，
  Comparison 仍为 `Closed`，历史记录不会替用户开启对比。

辅助只读模型状态日志已保留到 `/tmp/rawlab-single-preview-interaction-model-events.log`，记录实际打开文件、
busy/完成、结果尺寸和恢复值，不将该日志单独当作按钮证据。截图与日志是生成证据，不入 Git。
后续 harness 默认生成到系统临时目录，不把唯一证据依赖于 build 目录。
验收后从应用菜单退出测试 app，并以进程查询确认退出；未启动或终止用户的 RawLab 应用。

## macOS 完整 RAW 配方

JSON v4 保存最终生效的核心参数。曝光/WB/look/几何之外，补齐对比度、饱和度、高光、阴影、
现有单滑杆 S 曲线、锐化、24 个 HSL 控件、暗角/颗粒全部子参数、小波/显示色度/FBDD 降噪、
镜头畸变/TCA/自动裁边/手动 profile。没有改变 request v2 布局或现有 enum 值。

`RenderEngine.agentRecipe` 返回 Data，不写图片；复用 `Adjustments.apply(to:)`、
`renderHSLSettings` 和当前照片白平衡解析，固化大师配方强度及分项结果，不再次乘整体强度。
保留旧配方 HSL 版本及降噪优先级。v1/v2/v3 严格字段边界与默认结果不变。

`--lens-database` 是本地离线数据库配置，不是图像编辑参数。能力查询返回构建实际支持的
optional features；缺少可选算法时启用请求明确失败，不假装成功。

look 输出覆盖 guard 来自核心 owner 的 `4f95bceb3b3473104869854c3f6389ce82c93c5f`，
本任务只移入该小段保护，并扩展 input/recipe/look 的 direct、normalized、symlink、hardlink
回归。未 cherry-pick 该 owner 整个提交，也未改其工作树；其他核心回归仍待协调集成。

### 实际运行

- parser RED：`Unsupported schema_version: 4`；范围补测 RED：`edits.detail.sharpening is out of range`。
- `edit_recipe_tests`：626 checks 通过；新字段非默认 sentinel 也验证失败时目标保持不变。
- `ctest --test-dir lutools/build-macos --output-on-failure`：33/33 通过，65.78 秒。
- `python3 lutools/tests/test_agent_commands.py --cli lutools/build-macos/sony2fuji --raw lutools/examples/DJI_20250602164503_0444_D.DNG`：14 tests 通过，含 optional features 和输入覆盖保护。
- `bash RawLabMac/build.sh`：完整 app 构建、JXL、bundle 动态依赖与 ad-hoc 签名检查通过。
- `bash RawLabMac/tests/agent-recipe-render.sh lutools/examples/DJI_20250602164503_0444_D.DNG lutools/build-macos/sony2fuji`：通过。

三入口测试使用只读真实 DJI RAW、同一 CPU 后端、相同尺寸与 PNG16：GUI Engine FINAL、
Agent CLI、直接 FINAL 的解码像素 exact；混合非默认 tone/S 曲线/锐化/HSL/暗角/颗粒/小波/
旋转/裁切/透视、旧色度降噪、大师配方 0/50/100/200% 均通过。exact preview 为 248x257，
与同尺寸 FINAL exact。持久化恢复和批量 journal 冻结 settings/look/尺寸后 FINAL exact。

镜头用公开合成 `linear-lens.dng`/`lenses.xml`：实际应用畸变；GUI FINAL RGBA8 与 Agent
PNG16 独立量化后最大差 0。该合成 DNG 的 ImageIO metadata 不可读，不能用于 Swift
`ExportMetadata.preserve` 文件输出，故此例明确采用 FINAL buffer；真实 RAW 文件输出使用上面的 DJI。
没有增加 CPU/GPU 容差；Auto 和 Metal 的原有数值回归由本次 CTest 覆盖。

本轮初次借用旧 worktree 依赖时，该目录被外部清理导致 dyld 失败，未计为通过。
随后复制生成依赖到本 worktree 并重定位，重新完成上述构建和验证；共享素材及原始 RAW 未改写。
原始日志保留在系统临时目录：`/tmp/rawlab-agent-three-entry-final.log`、
`/tmp/rawlab-agent-core-ctest.log`、`/tmp/rawlab-agent-macos-build.log`、`/tmp/rawlab-agent-commands.log`。

## macOS 普通图像

新增 JPEG/PNG/TIFF/HEIF 输入，覆盖打开面板、目录列表、缩略图、拖放入口、信息读取、
编辑保存与恢复、FINAL/preview、Agent info/export、混合 RAW/普通图片批量导出。
独立只读复核后修正了批量空选提示仍限定 RAW 的遗漏，并增加回归断言。

支持矩阵明确限制为单帧、不透明、8-bit SDR RGB，最多 64M 像素。ImageIO 处理方向一次；
带 ICC 的图片转换到 sRGB，无 profile 的 RGB 显式按 sRGB 解读。未标记的灰度/索引色、
透明像素、16-bit/float、CMYK、多页/多帧和识别到的 HDR/gain-map 拒绝，不静默降级。
本轮实际 HEIF 样例为 `.heic`/`public.heic`，不代表所有 HEIF 编码变体。真实 HDR gain-map
fixture 尚未覆盖。导出 PNG16 不表示支持 16-bit 输入，rendered DNG 也不是 RAW/HDR 输出。

新增 `SONY2FUJI_INPUT_DISPLAY_BUFFER = 2`，旧 RAW=0、BUFFER=1 与 request v2 布局不变。
显示图像走现有线性编辑算法与显示输出转换，不套 RAW 场景 sigmoid 或 DNG/RAW 曝光基线。
WB/FBDD/镜头校正属于 RAW 语义，普通图像 UI 不提供其效果，v4 配方明确拒绝这些请求。
Auto 明确回退 CPU，Force GPU 明确失败；未增加第二套处理算法或放宽数值容差。
共享解码函数仅 macOS 启用，其他平台返回 unsupported；Windows 尚未适配。

### 实际运行

- `ctest --test-dir lutools/build-macos --output-on-failure`：36/36，67.49 秒。
- `bash lutools/test.sh`：独立 Debug/shared-library build，36/36，76.81 秒；本地缺少
  `DSC06251.ARW`，可选 `sony_highlights` 未执行，未计入通过项。
- 最后平台 guard 与 CLI 修改后重新构建，相关 display/parser/schema/Agent 五项 CTest
  5/5，6.26 秒。
- `bash RawLabMac/tests/raster-render.sh lutools/examples/DJI_20250602164503_0444_D.DNG lutools/build-macos/sony2fuji`：
  JPEG/PNG/TIFF/HEIF fixture 全部通过，没有格式跳过；GUI FINAL、Agent CLI、直接 CPU、
  Auto CPU 的 PNG16 解码像素 exact，同尺寸 48x33 preview exact。新增 Agent info 断言验证
  raster/sRGB8 与 camera/lens/capture/as-shot WB 为 null。还覆盖 gamma identity、metadata、
  thumbnail、alpha/16-bit/corrupt 拒绝、hardlink 原图保护、持久化恢复、混合 batch 冻结与源 identity。
- `bash RawLabMac/tests/edit-model.sh`：真实异步 EditorModel 打开带方向 JPEG/PNG、编辑像素变化、
  保存/新模型恢复、未见照片默认值、失败输入不残留上一张图片均通过；不是原生按钮交互。
- `bash RawLabMac/tests/batch-export.sh`：先因 RAW 专用提示断言失败，修复后通过。
- `bash RawLabMac/tests/presentation.sh`、`bash RawLabMac/tests/localization.sh` 通过。
- 最终 `bash RawLabMac/build.sh` 完整构建与 bundle/signing 检查通过；RAW 三入口脚本
  再次通过，包含禁用小波 canonical 默认值的新增断言。
- lens-only 补测 14 项通过，Agent result 报告实际 applied distortion，GUI buffer/Agent PNG
  量化后最大差 0。禁用小波的 canonical 默认值及 CLI 参数顺序也有回归。

日志：`/tmp/rawlab-raster-final-ctest.log`、`/tmp/rawlab-raster-test-sh.log`、
`/tmp/rawlab-raster-final-guards.log`、`/tmp/rawlab-raster-final-info.log`、
`/tmp/rawlab-edit-model-raster-final.log`、`/tmp/rawlab-raster-batch-copy-green.log`、
`/tmp/rawlab-lens-report-green.log`、`/tmp/rawlab-raster-stable-macos-build.log`、
`/tmp/rawlab-agent-final-canonical.log`。早期 dyld/测试 RED 不计为成功证据。

## 后续里程碑

- macOS 完整 Agent 参数、普通图像独立复核/提交、默认比较原生交互三项门槛已通过。
- Windows：已完成下述接入前只读检查，未改动 Windows 实现，未运行 Windows 原生验证。

## Windows 接入前检查

2026-10-15 三项 macOS 门槛完成后再次 fetch：`origin/development` 为
`6f0dcf09dde2a5fbb9685496d3bb9f4610a2406b`；相对起点只新增 iOS 保存状态修复，
不影响本轮 Mac 验证源。Windows PR #53 仍 open、未 merged，最新 head 为
`5c2af9261f6872036e72996f214c7092a4d4d3d9`，不是最初记录的 `a57dd992`。

`git merge-tree --write-tree HEAD origin/pr-53` 仅做合并分析，exit 0，没有文本冲突，
返回树 `a66df082d368d880ddd822dec72c44e78df17d8a`。没有改变 branch/index/worktree，
没有创建合并提交，不表示 PR 已合入或联合验证通过。当前两条分支修改路径不重叠；
下面是 Windows 接入将触及的真实 owner 边界，不冒称已经发生冲突。

| 文件/入口 | 已确认依赖与接入要求 |
| --- | --- |
| `RawLabWindows/Adjustments.cs` | `Request` 已是 UI 百分比到 core 的实际映射；#53 增加小数精度，不另写一套换算。 |
| `RawLabWindows/RenderEngine.cs` | `PrepareRecipe` 解析目标 RAW 白平衡；GUI -> v4 必须复用它，不能冻结错误照片的 as-shot 值。#53 在 `SetGeometry` 接入透视。 |
| `RawLabWindows/GeometrySettings.cs`、`Native.cs` | #53 提供 `PerspectiveHorizontal/Vertical`、16-byte config 和 setter；不得复制该 owner 实现。 |
| `RawLabWindows/BatchExport.cs` | #53 的候选验证/可选状态需保留；新回归只验证既有冻结语义，不改写批量状态机。 |
| `RawLabWindows/MainWindow.xaml.cs`、`MainWindow.xaml` | #53 仍默认 `compare=true`/并排选中；Windows 默认单张与换图重置尚未适配。 |
| `RawLabWindows/tests/Program.cs`、`TestWindowState.cs`、独立 localization UI 入口 | #53 的 journal admission、私有 stores/偏好和 profile 保持检查是 WPF 测试前置，不运行旧入口冒险恢复用户任务。 |

Agent 的完整 JSON 解析、校验、session setters 和 FINAL 处理已经在共享 C++ CLI 中实现，
Windows 不应再次用 C# 重写 parser，也不应为迎合协议而把 UI 曝光范围扩到协议范围、
添加原本没有的 RAW FBDD 控件。Windows 待接入的是实际 UI 有效状态 -> 同一 v4 配方，
以及 GUI/Agent/Batch 的同条件 FINAL 回归。普通图像在 Windows 尚未适配，capabilities
不会把 macOS 解码能力宣传到 Windows。

本机没有可执行的 `dotnet`、`pwsh` 或 `powershell`，未把 Mac CTest 或既有 PR #53 结果
记为本任务 Windows 通过。现有 Python source archive 安全测试 1 项通过，py_compile 通过，
仅证明源码打包边界，不证明 Windows build/render/UI。Windows 原生验证需要 task-owned
源码/构建/结果目录、明确的 VM/session/process 及隔离 profile；没有使用或清理其他 owner 资源。

依照仓库单一 owner 约定，已就上述 Windows 接口向协调方请求明确接入/写入权安排。
等待期间不复制 #53、不修改 owner 工作树、不 merge/rebase 未合 PR，不声明 Windows 完成。
