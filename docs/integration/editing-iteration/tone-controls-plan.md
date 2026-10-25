# ITER-05 黑白场与鲜艳度接入计划

本项承接 [总需求 §7](../../design/editing-iteration/requirements.md#7-黑场白场鲜艳度iter-05)
和[技术方案 §2.1、§8](../../design/editing-iteration/technical-design.md)，由协调者执行。
分支 `feature/editing-tone-controls` 依赖 ITER-04 本地检查点 `1a1dfef9`，该检查点
承接 draft #134；远端基线仍为 `origin/development@751f21c5`. 此处短 SHA 仅描述基线，
实际来源以分支 ancestry 为准。用户于 2026-10-24 要求继续后续迭代，桌面解锁后
统一验证；尚缺的 UI 验收不标通过，不代表获得 push、PR 或发布授权。

## 接口与取舍

- request v2 的大小、顺序、enum 不变。新增独立 `tone_controls_config` v1，三个
  float 参数均为 [-1,1]，默认 0，setter 失败保留旧状态；每次客户端处理显式设置。
- UI、选择性 payload 的三个值均为 [-100,100]，仅在 native/Agent 边界除以 100。
  稳定字段 ID 为 `tone.black_point`、`tone.white_point`、`color.vibrance`；通用范围
  默认包含，旧 payload 未包含时不改目标。这些值独立于现有大师配方强度。
- Agent v5 已有 processing 身份，本次保留该必填对象并添加可选 tone/color 字段；
  v1–v4 继续拒绝新字段。复制/预设 payload v1 不因 Android 持久化 `v2:` 而改版。
- Apple 使用可选 tone 对象，Windows 使用 nullable 扩展对象，固定 Values 不变；
  Android 新编辑记录和 batch settings 各自使用明确的 `v2:` JSON，保留全部旧长度读取。
- CPU 数值合同先于 GPU/客户端开放。黑白场在 legacy tone 前，鲜艳度在 legacy
  saturation 后、HSL 前，均为 display-encoded sRGB。候选常量未完成质量集前不冻结。

## 任务及验证

- [x] T1：版本化数值合同、CPU reference、固定合成向量及真实样本质量集。
  先加入 v5 新字段解析的失败回归和 CPU 数值测试；覆盖精确 identity、灰阶、方向、
  81×10001 单调网格、肤色/高饱和保护、负向衰减、近灰色/色相连续性和有限边界。
- [x] T2：additive C ABI、session、CPU 链、v5 parser/schema/CLI/MCP 端到端。
  核验旧请求布局、非法 setter 状态保留、复用清零、旧配方字节、raster/RAW 与 FINAL。
- [x] T3：数值准入后接 Metal/GLES/D3D11；核验真实 backend 和 float/RGB8 parity。
  未接后端必须 Auto 回 CPU、Force 明确失败；不把 shader 编译称作硬件验证。
- [x] T4 实现：四端模型、保存恢复、UI、reset/modified、transfer/preset/history、Agent
  与 batch 冻结链；六语资源单一 owner 接入。新增测试先证明字段缺失/丢失，再实现。
- [x] T5a：独立只读复核及本地证据归档；受影响核心、CLI/MCP、四端模型与构建验证
  已执行，具体范围如下。复核发现的 Android/Windows 问题均已修复并复评。
- [ ] T5b：解锁后执行实际 UI 检查并保留各自源码、配置与证据。
  本地依赖检查点保留后补验收所需的源与应用，不作为整项验收完成。

T1→T2 共享三个参数及阶段顺序；T2→T3 共享同一数值版本和参数配置；T2/T3→T4
共享 additive setter，T4 各端共享字段 ID/单位和旧记录缺失语义。已核对无冲突，
Android `v2:` 与 transfer v1 属于不同协议。数值、平台及联合验收分开记账；
本计划不会把 T1 自动指标通过解释为整项 IT-06/15 已通过。

数值决定：鲜艳度的有界保证针对 SDR 输入；legacy contrast/saturation 已产生的越界
工作值不得提前截断。组合回归证明预先截断会在鲜艳度跨过零时改变后续 HSL。正向
在既有越界时保持像素，负向沿原色度连续收敛；后续输出编码继续负责最终 SDR 限幅。

## 本地验证边界

- 共享核心：当前配置的 88 项通过，明确排除两个在干净依赖基线同样失败的
  `geometry_raw`、`wavelet_exposure_cache`。前者涉及缩小重解码后的 native canvas，
  后者的超大 RAW 超过缓存预算，不能把这两项写成通过。tone 的真实 RAW、raster、
  C ABI、schema、CLI，以及全部 43 项 MCP 检查通过。
- Metal 实际 backend 浮点及 RGB8 对照通过；D3D11 在 Microsoft Basic Display Adapter、
  GLES 在 SwiftShader/ANGLE 执行相应 backend 并通过对照。这两项是软件后端验证，
  不是 Windows/Android 硬件 GPU 验收。
- Apple 的受影响 model/transfer/preset/history/batch 检查通过；Mac RAW 渲染与
  native/Agent FINAL 对照通过。Mac App、iOS 三 slice framework、App/tests 和
  新 tone native harness 编译通过；iOS 新 harness 尚未执行。
- Android 300 项 JVM 测试、app/test APK 与 lint 通过；新增 JNI tone instrumentation
  已编译，尚未执行。结构化记录的未知字段、旧 `v2:` film ID、严格布尔与 Double
  越界处理经失败回归后修复，未修改记录保持原始表示。
- Windows managed 模型、WPF App/tests 编译和 30 项无界面的 native/Agent 渲染检查
  通过；回归暴露的 preview key 遗漏 tone 已修复，neutral reference 与 session 清零
  同时验证。独立复评发现的跨 raster session 重置丢参也已通过失败/成功回归；
  退出几何/镜头草稿清理工具选择的修复已接入四项 WPF 回归并编译，实际执行待解锁。
  新工具尚未执行实际 WPF 输入和布局验收。
- 六语资源生成/校验及 27 项本地化工具回归通过。上述均是本地结果，无 Hosted CI
  通过声明，也不代表当前分支已合入 `development`。

## 解锁后补验

四端各自验证三个工具的真实输入/拖动/精细调整、单项与组重置、modified 标记、
保存重开、复制/预设/撤销/重做和导出；同时覆盖六语、短窗/窄窗及大字号的新增项。
iOS 执行已编译的 tone native harness，Android 执行 JNI instrumentation；桌面使用
本批实际构建的包，必要时从同一源码重建并重新绑定哈希。ITER-04 的 Mac 大字号
待验项仍独立保留，不能用本批构建或数值质量集代替。

后续 ITER-06 可以消费本批新配置和完整数据链；IT-06/15 的实际 UI 与联合验收仍保持未完成。

## 解锁后的增量补验（2026-10-24）

Mac 实际数值输入与撤销/重做、Android JNI 预览/导出清零回归、iOS native tone 回归均已执行通过；本轮 iOS processor 共 122 项断言通过，范围与 RAW 跳过项分列。

本轮证据分别绑定 `cfff3308` 基线与具体修复/测试覆盖层，见外部验收索引 `iteration-08-batch-selection` 中的 `mac-ui`、`ios-ui`、`android-ui`、`windows-ui`；不得合称同一二进制的全量通过。Mac/Windows 默认用户目录未变化。Android 扩展到旧 RAW 套件时，样片不满足镜头匹配前提，后续 instrumentation 退出 255；该扩展运行未通过。后续功能的六语大字号联合验收和实体设备覆盖仍未完成。
