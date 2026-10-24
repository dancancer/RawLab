# ITER-06 三分区颜色分级接入计划

> **For agentic workers:** 使用 `superpowers:executing-plans`，由协调者实现；独立代理只读复核。

**Goal:** 在四端颜色组提供阴影、中间调和高光色轮，完整接通保存、复制、预设、历史、Agent 和导出。

**Architecture:** display-linear sRGB 的固定三分区权重混合零亮度色度向量，在 HSL 后执行。
独立 additive C ABI 保留 request v2；四端消费同一个版本化算法和完整三分区对象。

**Tech Stack:** C++17、Metal/D3D11/GLES、Swift、Kotlin、C#/WPF，复用既有 UI 和事务入口，无新增颜色库。

**Spec:** [总需求 §8](../../design/editing-iteration/requirements.md#8-三分区颜色分级iter-06)、
[技术方案 §2、§8.3](../../design/editing-iteration/technical-design.md)。用户已批准本轮实现，
并要求先继续迭代、解锁后统一验证实际界面。

## 基线与共同约束

- 分支 `feature/editing-color-grading` 依赖 ITER-05 本地检查点 `38cfebad`；开始前刷新
  `origin/development` 仍为 `751f21c5`。依赖 ancestry 由 Git 保存，本批没有远端交付授权。
- request v2、tone controls v1 和现有 HSL/effects 布局不改。新增 config v1：
  `version/struct_size` 加三个区的 hue/saturation，共 32 bytes；无效 setter 保持旧状态。
- core、Agent、持久化与 payload 色相使用 `[0,360)`，UI 可输入 360 并归一成 0；
  saturation 使用 `[0,100]`。所有 saturation 为 0 时逐字节 bypass，但非零待用 hue 仍保存。
- 三个交换字段为 `color.grading.shadows/midtones/highlights`，每项是完整 `{hue,saturation}`
  对象，归 color，common 默认包含。缺字段表示未选择，不能清空目标；不跟随旧 recipe strength。
- Apple optional、Windows nullable 扩展，Android 延续已有 `v2:` JSON；未知版本/字段拒绝有损覆盖。
- 先 CPU 参考和固定质量集，再冻结常量、接 GPU/四端。保留用户已要求后补的 UI 验收。

## 复核重点

- saturation=0 的待用 hue 必须经过保存、部分复制、预设和历史，不被 render identity 删除：T4。
- 三分区权重交界、hue 359.999→0 和极小 saturation 不得产生跳变：T1/T2。
- 旧 HSL/contrast 越界工作值不能因启用极小 grading 被提前硬裁切：T1/T2。
- 同一 session 切换 RAW/raster 或清零时必须重新配置，preview key 包含完整 grading：T2/T4。
- 色轮切区/取消手势/切源沿已有输入事务；单区 reset 不改另两区，整工具 reset 清六值：T4。

## T1：CPU 数值参考

**Files:** 新增 `lutools/src/core/photo_color_grading.{h,cpp}`、
`lutools/docs/color-grading-v1.md`、`lutools/tests/color_grading_tests.cpp` 和
`lutools/tests/fixtures/color-grading-v1-reference.json`。

**Interfaces:** `ColorGradingWheel{hue,saturation}`；`ColorGradingOptions{wheels[3]}` 的
`valid()/active()`；`colorGradingCoefficients(options)`；`colorGradingWeights(linearY)`；
`applyColorGrading(RGB,options)` 和 `applyColorGrading(ImageData&,options)`。

- [x] 补失败回归：全零精确 identity、待用 hue、严格范围、三个区的独立作用、黑白端点、
  10001 点权重/梯度、色相环回、SDR 21³ 网格的有界/线性亮度保持、越界工作值连续性。
- [x] 按候选合同实现；用独立 binary64 参考生成固定向量，CPU 逐通道误差 ≤5e-6。
- [x] 运行独立 CPU 回归，查明所有失败；记录数值测试，质量冻结仍等 T2。

## T2：native、CLI 与固定质量集

**Files:** `lutools/include/sony2fuji/{ffi/sony2fuji_c.h,edit_recipe.h}`、
`src/ffi/sony2fuji_c.cpp`、`src/cli/{edit_recipe.cpp,agent_commands.cpp}`、CMake、
v5 schema/docs、对应 API/recipe/CLI/MCP 测试及 `fixtures/color-grading-v1-quality.json`。

**Interfaces:** `sony2fuji_color_grading_config`、`sony2fuji_session_set_color_grading`；
v5 `edits.color_grading` 下的完整 `shadows/midtones/highlights`；capabilities 只在实际接通后声明。

- [x] 先验证旧版本拒绝、v5 严格解析/序列化、非法 setter 不污染、复用清零、RAW/raster、
  FINAL 和 CLI/MCP 对照的失败回归，再接 CPU HSL 后的 grading。
- [x] GPU 未接期间 Auto 一致回 CPU、Force 明确失败，不把新阶段重复追加到 GPU 成片。
- [x] 复用已核验许可/hash 的五张真实照片，固定 identity、三种单区极值、三色组合和
  温和互补组合，产出 FINAL 与 100% 区域；检查肤色、天空、渐变、饱和结构和暗部噪声。
- [x] 数值阈值与视觉质量通过后冻结 v1；不以单一 PSNR 或单张图代替质量判断。

## T3：GPU 对照

**Files:** `lutools/src/gpu/photo_color_grading_shader.h` 和三个现有 photo backend，
`lutools/tests/{gpu_photo_tests.cpp,d3d11_shader_tests.cpp,color_grading_api_tests.cpp}`、
`RawLabAndroid/tests/gpu_smoke.cpp`。

**Interfaces:** 三个 host 消费同一 CPU 预计算的三组零亮度色度系数；shader 共享同一
传递函数、权重和色域公式，在 HSL 后、chroma denoise 前应用。

- [x] 先加入参数 packing、实际 backend、float/RGB8 parity 和 tone/HSL/LUT 组合回归。
- [x] 实现三个后端，float 误差 ≤5e-6、RGB8 每通道 ≤2 DN；记录实际 renderer，软件后端
  不称硬件验证，Force 不能伪装回退。

## T4：四端完整数据链与色轮

**Files:** 复用各端 settings/adjustments、transfer、snapshot/Agent、native 处理与 batch
入口；新增 `Shared/ColorGradingSettings.swift`、本端 grading panel/wheel 及对应 model/UI tests。
协调者独占 `Shared/strings/` 六语、生成输出和所有构建源清单。

**Interfaces:** 三个区的数据都属于 committed settings；当前区选择只属 UI。渲染 identity
与存储默认值分开，旧记录缺 grading 为全零；native 每请求显式配置；色轮手势进入既有
begin/update/commit/cancel 输入会话，不建立第二套历史。

- [x] 先补旧缺失/待用 hue/部分复制/零 recipe strength/预设/撤销重做/batch 冻结的失败回归。
- [x] 接入四端模型、Agent、preview key、session reset、reset/modified 和六语资源。
- [x] 接阴影/中间调/高光切换、色轮与精确 hue/saturation 输入；单区与整工具 reset，
  同值和仅切区不产生编辑，取消恢复手势起点。
- [x] 跑受影响模型/native/构建回归，独立只读复核并修复；实际原生 UI、六语/大字号和
  移动 instrumentation 按用户要求留待解锁后统一执行，不能将编译写成执行。

## T5：本地检查点与后续依赖

- [x] 核验源码、构建、配置和日志绑定；数值/平台/整体 IT-07/15 分开记账。
- [x] 清理不再需要的中间产物，保留待验包与旧迭代证据；保存本地依赖检查点。
- [ ] 解锁后执行实际 UI 和跨功能验收，才能关闭对应验收项。push/PR/合入/发布继续按明确授权执行。

## 当前验收边界

数值合同和固定质量集已冻结；三后端对照与四端模型/构建完成。D3D11 使用虚拟机 adapter，
GLES 使用 headless SwiftShader，均验证了实际 backend 调用，但不属于物理 GPU 验证。
共享核心本轮已运行套件排除前一批确认的 `geometry_raw`、`wavelet_exposure_cache` 基线失败，
不能宣称整个配置的全部测试通过。

只读复核发现并修复了拖动中方向键提前提交、Android 降到 Float 后才检查输入边界，以及
Apple 原生色轮取消入口缺失；相关模型/会话回归已运行。四端真实界面、六语/大字号、
iOS native harness 与 Android JNI instrumentation 只完成构建，待用户解锁后统一执行。
IT-07/15 保持未关闭；本地依赖检查点不代表远端交付或实际 UI 验收通过。
