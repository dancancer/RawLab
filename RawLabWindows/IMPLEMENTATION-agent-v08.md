# Windows Agent And Display Input Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement the approved handoff task-by-task. Keep a single Windows write owner.

**Goal:** 接入完整 Agent v4、普通图像与默认单张预览，保留 PR #53 的编辑器恢复和测试隔离契约。

**Architecture:** 选择性消费本地冻结的共享 C++ parser/schema/FINAL/display-buffer 实现；Windows serializer 复用实际渲染参数映射。WPF 与 CLI 使用同一 Windows 原生解码器，批量复用现有冻结状态机，不创建第二套显影算法。

**Tech Stack:** C++17 / C ABI / MSVC / WIC / .NET 8 WPF / System.Text.Json。

**Spec:** 用户本轮交接指令，以及冻结源 `82946eb4d3c99b0e6edffdc868c3c393539fc2e2` 的 `docs/verification-agent-v08.md`、`lutools/docs/edit-json.md` 与 `lutools/docs/color-contract.md`。

## Global Constraints

- 起点 `3199c915d20b77f38c00a6b7c1edbc9a286807ea`；沿用 `feature/windows-v08-editor`，不另建分支或 PR。
- 仅本地开发、验证和必要提交；不 push、不更新/合并 PR、不发布或部署。
- 保留已有 P2 修复、六份未跟踪 review 报告、旧验证证据与其他任务资源。用户另行授权清理旧缓存/历史构建产物；只回收已审计的可生成目录，保留源码/样片/日志。
- 共用协议和色彩语义不变；新的共用路径改动先说明文件及原因。不改冻结 Mac UI。
- 不新增 FBDD UI；raw_level=0。目标 RAW 白平衡逐图解析，不冻结源 AsShot，不重复大师配方强度。
- 普通图像：单帧、不透明、8-bit SDR RGB、最多 64M 像素；ICC/sRGB 和方向各处理一次。不静默降级透明、高位深、HDR、CMYK或多帧。
- Windows 必须真实重建并执行当前共享核心/CLI；Mac 结果、旧 DLL、交叉编译不替代本次验证。
- 保留 common journal admission、私有 stores/profile 保护。物理输入/GPU 不可达时明确 NOT REACHED。

## Review Focus

- 目标照片不同 WB、配方 0/50/100/200%：GUI/Agent/冻结 Batch 的同尺寸 FINAL 像素一致。
- v1-v3 不获得 v4 字段；v4 省略/边界/完整字段与 capabilities/schema 一致，覆盖 input/recipe/look alias 保护。
- RAW/raster 混合批量不继承 RAW 相机 WB、曝光基线或镜头，源文件不被覆盖。
- 方向、ICC、非法输入和重开缓存不能重复变换、保留旧图或静默丢精度。
- 新窗口/切图/历史恢复默认单张，同图手动对比在调参和异步结果发布中保持选择。

## Milestone 1: Complete Agent

**Files:** 冻结 `lutools/**` 必要改动；`RawLabWindows/native/CMakeLists.txt`、`build.ps1`、`RenderEngine.cs`、新 `AgentRecipe.cs`、平台测试与本文/验证记录。

**Interfaces:** `RenderEngine.AgentRecipe(path, settings, look, output, longEdge)` 返回 v4 JSON；内部复用 `PrepareRecipe`、`Adjustments.Request`、`RenderHsl` 和已有配置值。CLI 保持唯一解析和校验入口。

- [x] 消费冻结共享闭包并记录每个源文件及来源 SHA；开启实际 Windows CLI 构建/打包。
- [x] 针对缺少 Windows serializer 添加 RED；核对冻结共享 parser/schema 原有负向控制，不把已有 Mac PASS 视为 Windows PASS。
- [x] 实现完整有效状态序列化与同图目标保护，不扩 UI 参数范围。
- [x] 新私有 Windows build 执行 CTest、CLI v1-v4/schema/capabilities/alias、GUI/Agent/Batch FINAL 与 preview 几何回归。
- [x] 定向独立复核、补独立目标 WB oracle 并复验，证据记录于 VERIFICATION-agent-v08.md；本地提交不改变 PR 远端。

## Milestone 2: Ordinary Images

**Files:** Windows 专属原生解码器、平台条件构建；必要 CLI 平台 guard；`RenderEngine.cs`、`Native.cs`、文件树/打开/拖放/info/恢复/批量边界与相应测试/资源。

**Interfaces:** 复用 `sony2fuji_load_display_image` 与 `SONY2FUJI_INPUT_DISPLAY_BUFFER=2`；不复制 C++ 调色阶段。只在实际支持且验证后声明 JPEG/PNG/TIFF/HEIF 能力。

- [ ] 添加 JPEG/PNG 解码、方向、ICC、精度/alpha/HDR/multiframe/损坏拒绝 RED。
- [ ] 实现 WIC 边界及共享 GUI/CLI 入口；保持单次方向/颜色变换，明确 RAW-only 请求禁用/拒绝。
- [ ] 贯通打开、文件树/Drop、info/缩略图、预览、保存恢复、Agent、单张与混合 Batch。
- [ ] 重新构建 Windows native，验证 identity 色彩、三入口 FINAL、源身份/alias 保护和 RAW 回归；实际探测 TIFF/HEIF codec。
- [ ] 定向独立复核、修复、复验，记录支持/不支持项并本地提交。

## Milestone 3: Single Preview Default

**Files:** `MainWindow.xaml(.cs)`、现有 comparison/canvas/cache 接线与测试；不将会话选择写入历史编辑。

- [ ] 添加新窗口、新图、历史恢复的默认关闭 RED；保留同图手动侧并排/滑动及异步状态断言。
- [ ] 同步菜单、button、canvas、cache 的默认/切图状态，不只改字段初值。
- [ ] 执行真实 Windows 原生打开/切图/对比/调参操作验收；若桌面输入不可达则准确记录限制，不把 routed event 当物理操作。
- [ ] 重跑受影响编辑器/批量/隔离验证，完成独立复核与本地提交。核实远端 PR 未改变。
