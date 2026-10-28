# 手机 HDR 照片分阶段实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: 使用 `superpowers:executing-plans` 逐任务执行；
> 独立代理可只读探索/复核。2026-10-28 用户已授权实施，从 HDR-00 推进；未完成项仍保持待办，
> 不把实施授权视为 push、PR、合入或发布授权。

**Goal:** 首批在 Mac/iOS 导入 iPhone/Android HDR 照片，完成基础编辑、HDR/SDR 预览和兼容 JPEG 保存。

**Architecture:** Apple 系统负责协议解码与显示适配，C++ 核心维护 HDR/SDR 双呈现和确定性编辑。
新增 versioned HDR C ABI，旧 request v2、SDR/RAW 渲染及客户端保持兼容。

**Tech Stack:** C++17、ImageIO/Core Image/Metal、SwiftUI/AppKit/UIKit；Ultra HDR 使用固定版本 libultrahdr 2.0.2，依赖与开关见 `lutools/cmake/hdr-codec-dependencies.json`。

**Spec:** [手机 HDR 技术方案](../../design/hdr-photos/technical-design.md)，设计版本 1；
范围来自 2026-10-28 用户确认，源码核对基线 `a4de533e94cf0dd42355e6b95c6023b4836fb4cc`。

## Global Constraints

- 首批完整能力：macOS 15+（Apple Silicon、Intel），iOS/iPadOS 18+；macOS14 保持现有 SDR 能力。
- 首批输入：iPhone 旧式 Apple/ISO 增益图 HEIC/JPEG、Android Ultra HDR JPEG；Windows/Android 客户端后续接入。
- HDR 工作图：显示参考、D65 扩展线性 sRGB float32，`1.0` 为相对 SDR 参考白，不叠加 RAW 基准或 sigmoid。
- 首批基础参数和禁用工具以[方案 §5.1](../../design/hdr-photos/technical-design.md#51-工具能力)为准，不承诺现有 LUT/DCP 已 HDR 兼容。
- request v2、旧 enum/布局与 v1～v5 Edit JSON 不重解释；HDR processing version 独立于 RAW processing version。
- 原图只读；不静默丢增益图、不继承屏幕能力、不复用过期增益图、不将部分应用报告为成功。
- 已获代码实施授权；使用从最新 `origin/development` 创建的 `feature/*` 隔离 worktree，按项目授权规则提交/交付。
- 依赖与共享素材用主工作区 `.cache/shared/`；一次性证据放任务临时目录，不提交照片、截图、构建或单 PR 测量记录。
- 本地 UI 执行、物理 HDR 设备、原生数值、编译及 CI 分别记录；普通 PR 自动 CI 仍按现有 contracts/models 政策运行。

## Review Focus

1. 双元数据或 RGB 增益图：两个 decoder 读取同一内容，不因开启 XMP 改错通道参数；测试归 HDR-00/04。
2. 相册/iCloud/limited access/取消：取得原容器，失败不以 SDR 转码副本冒充 HDR；测试归 HDR-03。
3. 换屏、headroom=1、应用恢复：仅显示改变，未编辑图、历史与导出保持；测试归 HDR-03/05。
4. HDR/SDR/RAW 混合批量与旧记录：不继承上一张的模式/WB/源缓存，不覆盖未知版本；测试归 HDR-02/04。
5. 大图、辅助图越界、内存/磁盘失败：错误可恢复，原图和已存在输出不变，FINAL 不用预览；测试归 HDR-00/01/04/05。

## 阶段、依赖与 owner

当前工作树已包含 00～04 的草稿实现，仍在执行集成验证；复选框只能在该步骤的完整范围均有
对应 source 和实际结果后勾选，部分通过不能关闭整步。阶段可分多个小 PR，
只有前置接口合入并刷新基线后才接入依赖方，不以文本合并或代理自报完成关闭阶段。

| 阶段 | 交付物 | 前置 | owner 职责 | 当前阶段验证的合同部分 |
| --- | --- | --- | --- | --- |
| HDR-00 | 格式/codec 与构建可行性，固定样本和依赖决策 | 无 | decoder/依赖 owner | A01、A09、A10、A14 的可行性门槛 |
| HDR-01 | HDR 数值合同、typed ABI、CPU 双呈现编辑 | 00 | 共享核心/ABI owner | A02～A04、A10、A13 |
| HDR-02 | 原生记录、传递、预设、批量、Agent v6 | 01 | 共享语义 owner，Mac/iOS adapter owner | A05 状态、A11 缓存身份、A13 参数映射、A14 旧调用方 |
| HDR-03 | Mac/iOS 导入、画布与监看 | 01；状态接入依赖 02 | Apple 平台 owner | A01、A04、A06、A07、A12 |
| HDR-04 | HDR JPEG、元数据、相册/文件/批量保存 | 00～03 | encoder owner，Apple 保存 owner | A08～A10、A13 |
| HDR-05 | 同一集成源的首批联合验收 | 00～04 | 协调者/平台验收 owner | A01～A14 全部首批范围 |
| HDR-06 | 高级算子、外观、RAW/格式/其他平台扩展 | 首批稳定后另定 | 对应模块 owner | 不属于首批完成条件 |

`CMakeLists.txt`、公开头、Swift link/framework 与依赖许可入口各阶段保持单一写入 owner。
平台并行只围绕已固定接口进行；此表不要求每阶段启动多个代理，也不改变用户授权边界。
00～04 只关闭各自表列的合同部分，不提前标记整项 Axx 最终通过；阶段关闭依据是本节之后明确的
交付物与步骤结果，完整设备/端到端条件统一在 05 关闭。02 的模型/缓存预检不依赖 03 的 UI 或 04 的 encoder。

## 文件与职责地图

下表路径已按草稿实现更新；其余为接入点，不要求无关重构。具体内部拆分可调整，
但公开名称、参数意义和相邻任务消费的接口保持一致。

| 范围 | 计划新增 | 既有接入点 |
| --- | --- | --- |
| 公共 HDR ABI | `lutools/include/sony2fuji/ffi/sony2fuji_hdr.h` | `sony2fuji_c.h` 保持旧声明；Mac/iOS bridge 显式 include 新头 |
| HDR 核心 | `lutools/src/core/hdr_rendering.h/.cpp`、`lutools/src/ffi/sony2fuji_hdr.cpp` | 复用 geometry 与颜色转换；`lutools/CMakeLists.txt` 注册构建/测试 |
| 手机文件解码/编码 | `lutools/src/platform/hdr_image_apple.mm`、`lutools/src/core/hdr_jpeg.h/.cpp` | 旧 `display_image.cpp` 继续 SDR；codec 依赖由统一构建入口接入 |
| Apple 共享状态/显示 | `Shared/HDRSettings.swift`、`Shared/HDRDisplay.swift`、`Shared/Native/HDRImage.swift`、`HDRPresentation.swift`、`HDRCanvas.swift`、`HDRMonitoring.swift` | `Shared/AdjustmentTransfer.swift`、`AdjustmentPresetStore.swift`、共享六语 catalog |
| Mac | HDR native adapter 与 `RawLabMac/tests/hdr-*.sh` / `HDR*Tests.swift` | `Engine.swift`、`Adjustments.swift`、`EditorModel+Rendering.swift`、`PhotoCanvas.swift`、Export/Batch 文件 |
| iOS | HDR processor adapter 与 `RawLab/tests/hdr-*.sh` / `HDR*Tests.swift`、`RawLabUITests/HDRPhotoUITests.swift` | `PhotoImportTypes.swift`、`Sony2FujiProcessor*`、`RawSettings`、ViewModel/EditorState、Editor/Export 与 batch |
| Agent | `lutools/docs/edit-json-v6.schema.json` | `edit_recipe.h/.cpp`、`agent_commands.cpp`、Mac `AgentRecipe.swift`、MCP 能力/参数转发；Windows 保持旧类型正确 |
| 合同与测试 | HDR 数值/ABI/codec/recipe 测试、固定小型合成向量 | `display_render_tests.cpp`、`display_image_tests.cpp`、`edit_recipe*`、既有 SDR/RAW 回归 |

## HDR-00：样本、协议与 codec 选型

**Interfaces**

- Consumes：技术方案 §1、§4、§7、A01/A09/A10/A14。
- Produces：旧式 Apple、ISO、Ultra HDR 的识别/还原映射；固定 codec 版本、参数、校验值和许可决定；
  可复用的 `HDRFixtureManifest`（协议、像素尺寸、方向、颜色描述、已知 headroom、SHA-256、来源许可）。
  私人素材只记录外部 fixture 身份，不入库；可再分发小型合成素材才加入正式测试目录。
  同一清单锁定[方案 §8.1/8.2](../../design/hdr-photos/technical-design.md#81-数值比较与查看器-oracle)的
  reference decoder、测试区域、实际设备/内存/OS build、查看器版本；这些资源没落实不能关闭本阶段。

- [ ] **Step 1：建立样本矩阵。** 包含三类首批输入、ISO/XMP 双描述、RGB map、不同分辨率 map、
  EXIF 1～8、P3/饱和灯光、无 map SDR、损坏 map、未知辅助图及超过尺寸/溢出输入；写明每类的预期结果。
- [ ] **Step 2：先写协议检查回归。** 名称 `hdr_codec_legacy/iso/ultrahdr/dual_metadata/rgb_map/bad_aux`，
  断言成功得到两份不同亮度范围的图、颜色/方向一致；坏引用不得仅解底图成功。先确认缺实现时失败。
- [ ] **Step 3：比较系统与候选 codec。** 在 macOS15+ 两架构、iOS18+ framework slices 上分别
  解出 HDR/SDR，独立比较像素及元数据；决定系统覆盖和补充 `libultrahdr` 的具体范围。
- [ ] **Step 4：验证依赖闭包。** 固定源码/哈希/许可、JPEG-only 设置、单边尺寸及 ISO/XMP/RGB map
  开关；确认不隐式增加 libheif/AVIF、不静默降级为 SDR，实际链接各 Apple 产物。
- [ ] **Step 5：验收选型。** 运行 `lutools/tests/hdr_codec/run.py --target <target> --cache-root <shared> --build-root <task> --run-tests`，
  具体 target、fixture 与 simulator 参数见该目录 README；codec 测试独立于产品 `lutools/build-macos`。
  另执行 iOS codec native harness。缺少设备的门槛保留；按用户授权继续本机/模拟器上的后续软件接入，不以此关闭选型的完整设备范围。

输出决策进入长期 HDR 合同；单 PR 的比较数据和失败日志只写 PR。此阶段不得凭 SDK 文档标记设备支持。

## HDR-01：浮点 ABI 与 CPU 双呈现编辑

**Files**

- Create：地图中的公开 HDR 头、核心/FFI 实现、`lutools/tests/hdr_render_tests.cpp`、`hdr_api_tests.cpp`。
- Modify：`lutools/CMakeLists.txt`、必要的颜色/几何复用入口；旧代码仅改必要调用点。
- Contract：方案 §3、§5.1、§6.1；`lutools/docs/hdr-color-contract.md` 已保存固定算子合同/参考向量。

**Interfaces**

- Consumes：00 的 decoder/fixture 规则及不可变原图；所有数据已解释为显示参考。
- Produces：`sony2fuji_hdr_probe/decode/render/export_jpeg/release_pair` 中的 probe/decode/render/release；
  source info、image pair、request v1 和错误/所有权定义按方案 §6.1；同名 diagnostic 参数接线一致。
  `export_jpeg/export_sdr` 函数到 04 才可宣告可用。
- Core 内部入口：`renderHDRPair(const HDRImagePair&, const HDRRenderOptions&) -> HDRImagePair`；
  `HDRRenderOptions` 对应公开 request v1；HDR/SDR 源不可变，结果为独立拥有的线性 RGB32F。

- [ ] **Step 1：先写 ABI 和 identity 回归。** `hdr_identity` 检查 `0/0.18/1/2/4/8/16` 及有效负分量，
  按 A02 断言；`hdr_api_validation` 覆盖布局/对齐、大小尾部、诊断、stride/溢出/NaN/Inf/alias/release twice、
  NULL/串行 session、Force 拒绝、P3 底图不经 sRGB8、source/edited headroom，失败不改输入。
- [ ] **Step 2：固定基础算子合同。** 给曝光、相对 WB、对比度、高光、阴影、饱和度的默认/正负/极值
  建独立参考向量，写清顺序、亮度坐标、保护条件和 `hdr_processing_version=1`；必须满足 §5.1 的连续性
  与无高光平台要求。先看到当前 SDR 算子/缺失 HDR 实现使回归失败，再实现 HDR 公式，不修改旧 SDR 数学。
- [ ] **Step 3：实现 typed ABI。** 新头的类型使用 version/struct_size，buffer 有 stride/颜色/headroom/
  quality；输入借用、输出核心拥有、错误清空输出，保留 request v2 及旧 enum。Apple bridge 和 framework 导出新头。
- [ ] **Step 4：实现 CPU 参考与几何。** 同一逻辑快照分别生成两份呈现；复用方向归一化和现有几何，
  添加 `hdr_geometry` 的配准/FINAL 不用代理回归；不继承 session 残留外观或高级效果。
- [ ] **Step 5：验证新旧边界。** 运行 `ctest --test-dir lutools/build-macos -R '^hdr_(render|api)' --output-on-failure`，
  再运行既有 `display_render/display_image/edit_recipe_raster/rendered_dng/processing_version` 相关选择；
  必须实际有匹配测试，0 tests 或 fixture SKIP 不能写通过。

CPU 参考通过才允许后续 GPU 优化；Auto/Force 行为按方案，不把 Metal presentation 当计算后端。

## HDR-02：记录、参数传递、批量和 Agent

**Files**

- Create：`Shared/HDRSettings.swift`、v6 schema、HDR record/recipe/payload 回归。
- Modify：Mac `Adjustments.swift`、`PhotoEditState`、iOS `RawSettings` 与持久化、两端 batch snapshots；
  `Shared/AdjustmentTransfer.swift`、预设、`edit_recipe.h/.cpp`、`agent_commands.cpp`、Mac AgentRecipe 与能力查询。

**Interfaces**

- Consumes：01 的 `sony2fuji_hdr_request_v1`、处理版本 1、基础参数合法性。
- Produces：`HDRSettings`（record v1、处理版本、编辑模式与基础参数）；`makeHDRRequest(settings:intent:longEdge:)`
  两端 adapter，返回同一公开 request 类型；payload v2/scope v2 和 Edit JSON v6 的严格映射。
- 模式、字段名和缺省行为以方案 §5.2/§6.2 为准；preview mode/headroom 不属于可持久化调整。

- [ ] **Step 1：先写兼容回归。** `hdr_record_legacy` 缺字段仍 SDR；`hdr_record_roundtrip` 保留模式/相对 WB；
  `hdr_unknown_version` 不覆盖；`hdr_session_isolation` 在 HDR/SDR/RAW 切换不泄漏状态；
  `hdr_mode_conversion` 逐项核对首次复制、WB 中性值、冲突拒绝、恢复原快照及单次 undo/redo。
- [ ] **Step 2：实现两端记录和历史。** 打通设置、重置、撤销/重做、保存/重启及源身份/cache key；
  旧记录不自动升级，显示切换不制造调整历史，HDR reset 保持 HDR。
- [ ] **Step 3：实现传递和逐目标快照。** HDR 相对 WB 使用独立字段；默认复制不切模式；
  `hdr_mixed_batch` 验证 RAW/SDR/HDR 逐目标 prepare、取消和失败隔离，不支持项禁止静默部分提交。
- [ ] **Step 4：接通 v6 与能力。** schema/parser/serializer/CLI/Mac Agent 同步，非法高级调整按字段拒绝；
  `hdr_recipe_roundtrip` 与 `hdr_recipe_native_parity` 验证同 request 输出。更新 MCP 的 schema 透传与能力检查，
  Windows parser/旧版本回归保持；不新增移动 Agent。
- [ ] **Step 5：验证。** 运行 `ctest --test-dir lutools/build-macos -R '^hdr_recipe_' --output-on-failure`，
  `bash RawLabMac/tests/hdr-model.sh` 与 `bash RawLab/tests/hdr-model.sh`，以及下表中的 history/batch/Agent runner；补跑既有 edit-memory/batch 模型和 payload fixture。
  CTest 只注册 C++ 用例，Swift 用例由各 model runner 执行，不把未接线测试名算作完成。

## HDR-03：Apple 导入、画布与监看

**Files**

- Create：`Shared/Native/HDRImage.swift`、`Shared/HDRDisplay.swift`、Mac/iOS HDR adapter、原生/UI harness。
- Modify：Mac Engine/PhotoCanvas/EditorModel；iOS `PhotoImportTypes.swift`、processor/ViewModel/EditorState/Editor；
  共享六语资源、构建源列表和 framework/Swift link 入口。

**Interfaces**

- Consumes：01 的不可变 image pair、02 的 `HDRSettings/makeHDRRequest`。
- Produces：`HDRImage` 持有核心 pair；`HDRDisplayState` 只存运行时 display headroom、预览方式和假色；
  `HDRDisplay` 负责工作色域到 Apple 扩展线性显示色域、headroom 映射及 RGBA16F 打包。
- 统计入口 `analyzeHDRImage(const HDRImagePair&) -> HDRStatistics` 使用浮点 HDR 图，输出参考白以上各 EV 分区、
  有效内容 headroom 与假色掩码；不调用旧 RGB8 histogram 后推算。

- [ ] **Step 1：先写来源和状态回归。** `hdr_import_original_container`、`hdr_import_cancel`、
  `hdr_import_cloud_failure`、`hdr_import_limited_access` 保证不丢 map、不发布半导入、不改旧照片。
- [ ] **Step 2：实现导入/编辑路由。** 新 HDR 图默认 HDR；旧记录仍按其模式恢复；macOS14 能力明确受限。
  所有未支持工具禁用并保留引用；显式模式转换冲突预检，取消全量无变化；
  `hdr_macos14_reject` 断言明确系统错误、保留旧画布/空画布、不开放该照片保存且不覆盖 HDR 记录。
- [ ] **Step 3：实现显示和监看。** HDR/SDR 切换、假色、直方图、容量线接通；`hdr_display_isolation`
  模拟 headroom 1/2/4/8、换屏、后台恢复，断言工作图/记录 hash 不变；FP16 打包有限且不发生静默溢出。
- [ ] **Step 4：验证实际交互。** Mac 在隔离用户目录运行应用并操作原生界面；iOS 使用 `RawLab/tests/hdr-ui.sh` 执行真实
  文件/相册导入、参数正负方向、撤销/恢复、对比、裁剪、缩放、显示失败与 SDR 回退；验证六语和无障碍。
- [ ] **Step 5：检查物理 HDR。** 在 HDR Mac、iPhone、iPad 与 SDR 屏检查 A06/A07；记录系统、架构、
  设备和亮度条件。iOS 模拟器可跑交互，不能替代 HDR 亮度验收。UI 通过后才进入对应提交步骤。

Mac 构建用 `bash RawLabMac/build.sh`；iOS 复用 `build-framework.sh`/`verify-framework.sh` 及
`RawLab/AGENTS.md` 的 App/UI harness。新 runner 必须写清设备/fixture 参数，不能借用或重置日用设备。

## HDR-04：增益图 JPEG 与全部保存入口

**Files**

- Create：`hdr_jpeg.h/.cpp`、`lutools/tests/hdr_image_tests.mm`、`lutools/tests/hdr_codec/numeric_acceptance.h`、Apple HDR 保存/重新导入测试。
- Modify：Mac/iOS 单张与 batch 输出格式、相册/文件发布；`Shared/ExportMetadata.swift` 仅在需要时分离 SDR/HDR 规则，
  不改变旧 SDR 输出默认值；依赖和许可由原 owner 接入。

**Interfaces**

- Consumes：01 FINAL image pair、02 冻结快照、00 codec 决策；输出模式独立于预览模式。
- Produces：`sony2fuji_hdr_export_jpeg`、`sony2fuji_hdr_export_config_v1`，以及 `hdr_jpeg` 单张/批量/Agent 格式；
  `sony2fuji_hdr_export_sdr`/`sony2fuji_hdr_sdr_export_config_v1` 保存 pair.sdr 到各端既有 SDR 格式。
  两端发布层只消费已校验临时文件，使用现有取消/原子发布语义。

- [ ] **Step 1：先写输出回归。** `hdr_jpeg_roundtrip`、`hdr_jpeg_dual_metadata`、`hdr_jpeg_rgb_map`，
  断言新 map、ICC、方向/尺寸与 FINAL 对应，按方案 §8.1 固定 oracle/区域/亮度公式验证 A08；
  `hdr_export_sdr` 验证普通 SDR 文件无 HDR/map 标签、匹配 pair.sdr，DNG 仍是 SDR；
  `hdr_export_reject_preview` 验证两种 exporter 都拒绝来源代理/非 FINAL，而允许全质量处理后的长边缩小。
- [ ] **Step 2：实现编码。** HDR 文件使用编辑后两份图、quality 默认 95、sRGB/P3 明确标签；
  普通 SDR 输出只使用已编辑 SDR buffer、既有 sRGB writer，不切模式；屏幕 headroom 不入参。
  测试发现双元数据通道失真时解决 codec，不把合并参数或仅写 ISO 当作已满足合同。
- [ ] **Step 3：实现元数据与事务。** 安全复制拍摄字段、更新尺寸/方向、去掉过期 map/色彩标签；
  `hdr_export_existing_target`、`hdr_export_disk_failure`、`hdr_export_cancel` 验证原文件/旧输出不变、无半成品。
- [ ] **Step 4：接通保存入口。** 单张、批量、恢复重试、iOS 相册和文件、Mac Agent 使用同一 encoder。
  `hdr_export_preview_independent` 验证查看 SDR/假色、不同屏幕时保存内容不变；`hdr_export_native_size` 不使用代理。
- [ ] **Step 5：验收。** 运行 `ctest --test-dir lutools/build-macos -R '^hdr_(image_decode|recipe_cli)$' --output-on-failure`、
  Mac `hdr-bridge.sh`/`hdr-agent.sh`/`hdr-batch.sh` 和 iOS `hdr-processing.sh`/`hdr-batch.sh`；实际在 Apple Photos、Preview 及受测
  Android Google Photos 打开，并用 SDR 查看器读底图。查看器/系统 build 使用 00 冻结的清单；
  普通 SDR 另存与 HDR JPEG 的 SDR 底图分别检查。外部 Android 查看器验收不代表 Android 客户端已接入。

## HDR-05：首批联合验收与交接

**Interfaces**

- Consumes：00～04 合入后同一集成 source、固定构建参数、依赖与 fixture manifest。
- Produces：A01～A14 逐项可定位的 PR/设备结果；可交付范围与未覆盖项。整轮完成前不宣告全部 HDR 支持。

- [ ] **Step 1：刷新集成基线与接口。** 核对 source/base、C 头与 Swift 桥、包内依赖/许可、codec 参数、
  capability；逐个阶段复核语义冲突，不把独立分支的旧通过结果当作当前集成通过。
- [ ] **Step 2：运行最小充分数值回归。** 配置了 Mac core 后运行 HDR 测试组及受影响的 SDR/RAW/Agent/geometry；
  核心接口变化对 Windows/Android 跑旧调用方编译、相关模型/native smoke，不要求首批 HDR UI。
- [ ] **Step 3：完成平台矩阵。** Mac arm64/x86_64 构建和必要 runtime；iOS device、simulator framework slices；
  macOS14 SDR/未来记录保护回归。按方案 §8.2 执行物理 Intel/Apple Silicon HDR、iPhone、HDR iPad、SDR 屏；
  缺任一必须资源明确阻塞，不从交叉编译推定通过。
- [ ] **Step 4：完成真实 UI/显示/外部文件验收。** 同一 source 执行 A06～A09/A12，包括 iPhone/iPad、
  大字号、六语、SDR 屏、48 MP、低内存/失败恢复、混合批量/切图/中断重试；原始素材 hash/mtime 不变。
  A11 按 §8.2 的 12 MP 必须成功、Mac24/48 MP 成功、移动端大图准入、128 MiB 缓存和临时释放条件判定；
  只有时间/内存测量表不能关闭 A11。
- [ ] **Step 5：请求适当 CI 并记录边界。** 普通 PR 自动 contracts/models；必要时按现有 SOP 明确手动
  `macos/ios + native` 或 `build`，共享 ABI 的兼容检查按影响范围选择；不新增每次 push 全量 gate，
  不把 build-for-testing 当 UI 执行。PR 记录实际 source/命令/配置/结果/未覆盖，仓库只维护长期合同及跨 PR 索引。
- [ ] **Step 6：关闭首批范围。** A01～A14 的首批条件全部满足、独立只读复核无未处理阻塞，才记首批完成；
  仍须按用户授权分别处理提交、push、PR、合入及发布，不由此计划自动授权。

## HDR-06：后续扩展入口

本阶段不执行，按独立需求和质量门槛拆分：先 HDR 高级调色算子和外观适配，再评估 RAW 到 HDR；
HEIF/PQ/HLG/AVIF/JXL 与 Windows/Android 显示各自有 codec/系统/GPU 验收，不能仅开放扩展名。
新增任何一项时补技术方案的输入/工具矩阵、参数版本、数值合同和相应平台实际验收。

## 实施状态与证据边界

HDR-00～04 的本机/模拟器软件路径已实现：共享双呈现 CPU 编辑、追加式 C ABI、记录与传递、
Mac/iOS 原图导入与浮点画布、显示监看、单张/逐目标批量、HDR JPEG 与显式 SDR 输出、Agent v6。
libultrahdr 的 arm64 P3 数值回归要求关闭其 intrinsics；产品与独立 codec harness 共用此固定策略，
不通过放宽 A08 阈值解决颜色误差。

当前可复现入口如下；具体通过记录属于源版本对应的 PR/任务证据，本表不代替运行结果。

| 验收范围 | 已接线入口 |
| --- | --- |
| A02～04、A10、A13 核心与协议 | 产品 CTest `hdr_render_*`、`hdr_api_validation`、`hdr_image_decode`、`hdr_recipe_*`；C11 头布局检查随构建执行 |
| A01、A08、A09 格式与数值 | `lutools/tests/hdr_codec/run.py`；`hdr_image_decode` 内的 `numeric_acceptance.h` 检查 sRGB/P3 × ISO/XMP/双描述六条路径；`public_fixtures.py` 检查公开 Android 原片与只读身份 |
| A05、A13 记录和传递 | `Shared/tests/hdr-settings.sh`、`hdr-transfer.sh`、`hdr-native-request.sh`；两端 `tests/hdr-model.sh`、`hdr-history.sh`；既有 history/edit-memory/transfer 回归 |
| A04、A06、A11 桥与显示 | `Shared/tests/hdr-display.sh`、Mac `tests/hdr-bridge.sh`、iOS `tests/hdr-processing.sh`；源缓存为每进程共享 128 MiB 上限，当前画布所有者另计总任务内存 |
| A05、A09、A10 保存和批量 | 两端 `tests/hdr-batch.sh`、Mac `tests/hdr-agent.sh`；原生逐目标冻结、失败隔离、HDR/SDR 输出与重新探测 |
| A12 交互 | iOS `tests/hdr-ui.sh <Build/Products> <task-output>`，需 `IOS_SIMULATOR_UDID` 指向专用模拟器；Mac 在隔离目录执行真实原生界面操作并保存任务截图；无 Mac `hdr-ui.sh` |
| A13、A14 Agent/旧协议 | CTest `hdr_recipe_*`、`edit_recipe_*`、`agent_*`；`tools/mcp/tests` 使用锁定测试依赖并连接本次 CLI；`scripts/ci/apple-models.sh` 包含快速 HDR 模型检查 |

上文未勾选的步骤均含尚未完成的完整范围，不表示其软件实现缺失，也不能凭部分通过关闭。
尚需补齐：真实 ISO/HDR 主底图手机样本、最低 OS 运行、物理 Intel HDR Mac/HDR iPad、
最终源版本的 iPhone 编辑器与实际 EDR 亮度、Apple/Android 外部查看器互操作、完整 24/48 MP 内存与失败矩阵，
以及六语、大字号、辅助功能、iCloud/limited access 等设备/权限组合。模拟器和高版本系统不能替代这些门槛。
先前 iPhone 核心 harness 的结果只覆盖其对应源码，不转记为后续 ABI/codec 改动后的真机通过。

实际 source、命令、结果和资源阻塞写所属 PR；提交、push、PR、合入和发布分别遵循项目授权规则，
本计划不替代 CI 或首批联合验收结论。
