# ITER-09 多点曲线接入计划

> **For agentic workers:** 使用 `superpowers:executing-plans`，由协调者实现；独立代理只读复核。

**Goal:** 四端提供全局 RGB 多点平滑曲线，贯通记录、选择性调整、预设、历史、Agent 和批量快照。

**Architecture:** 独立 additive config 保存模式和归一化控制点；CPU 计算 PCHIP 的归一化
Hermite 系数供三种 GPU 使用。旧 request v2 和 S 曲线公式不变。

**Tech Stack:** C++17、Metal/D3D11/GLES、Swift、Kotlin、C#/WPF，复用现有输入事务和持久化。

**Spec:** [需求 §11](../../design/editing-iteration/requirements.md#11-多点平滑曲线iter-09)、
[技术方案 §2、§8.4](../../design/editing-iteration/technical-design.md)。本轮实现已获授权；
用户解锁后已执行本轮实际界面验证；六语大字号及跨功能联合门槛另行收口。

## 基线和兼容

- `feature/editing-tone-curve` 依赖 ITER-08 本地检查点 `cfff3308`，开始前已刷新并核验
  `origin/development@751f21c5` 为祖先。没有远端交付或发布授权。
- custom 曲线 2～33 点，固定 `(0,0)/(1,1)`，x 严格递增、y 非递减，坐标有限且在 `[0,1]`。
- legacy 与 custom 渲染互斥；切换 custom 明确确认从 identity 开始。原 scalar 可保留为
  inactive legacy 值，native/Agent adapter 在 custom 模式只传 scalar 0，不能隐含叠加。
- 逻辑 payload 的 `light.curve` 包含模式和点列；`light.s_curve` 保持原数值类型。两项各自
  选择，未选项不变；仅复制旧 scalar 不切换目标曲线模式。common 包含两项，摘要明确模式。
- custom 不随旧 recipe strength 缩放。UI 选点/画布坐标不持久化；历史只提交模式及控制点。
- binary64 控制点避免存储时丢掉相邻点；GPU 在严格的精度准入下处理，其他合法曲线
  Auto 完整回 CPU、Force 报 unsupported。identity 精确旁路。

## T1：数值合同与共享核心

- [x] 先加入失败回归：严格合法性、固定端点、2/33 点、平台精度极端、PCHIP 参考、单调、
  有界、C1、identity、旧 scalar 原像素；然后实现版本化 CPU 参考及固定向量。
- [x] additive C ABI、session 复用清零、pre-HSL probe、v5 schema/parser/serializer/capabilities
  接通；旧 v1～v4 行为不变，冲突输入/非法 setter 保留状态。
- [x] Metal/D3D11/GLES 共用区间系数；覆盖组合处理、实际后端、float 与 RGB8 对照及回退。

## T2：四端数据和编辑器

- [x] 扩展原生 optional/nullable 模型、严格 codec、逻辑 payload 和所有 native 调用路径。
- [x] 曲线面板支持增删/移动中间点、精确坐标、identity 线与重置；端点固定且不能跨点。
- [x] 模式确认、手势取消、精确输入提交复用既有事务；修改标记、组 reset、保存/预设/
  历史/批量与摘要完整消费新字段。
- [x] 六语资源由共享目录生成，更新真实构建源清单并扩展有行为意义的模型/native/UI 测试。

## T3：验证和检查点

- [x] 运行核心、CLI/MCP、四端模型、native 和构建检查；记录 source/artifact hash 和日志。
- [x] 独立只读复核实际调用链，修复有证据的问题；清理不再需要的临时产物，保留待验包。
- [ ] 保存本地依赖检查点并继续 ITER-10/11；不把编译 UI 测试写成执行通过。
- [ ] 解锁后统一执行实际 UI 与组合验收，再关闭 IT-11/15。

## 本地验证记录（2026-10-24）

- 数值合同和固定向量见 `lutools/docs/tone-curve-v1.md`；C ABI 为 544 bytes，request v2
  保持 184 bytes。CPU 参考、Metal/D3D11/GLES 浮点边界与 RGB8 对照已执行；Android
  GLES 来自独立 emulator 的 SwiftShader，不能作为物理 GPU 性能证明。
- 核心 98 项所选 CTest 通过，配置启用 DNG SDK、GPU、chroma、wavelet，关闭 Lensfun、
  AI denoise、OpenMP。排除已知基线失败 `geometry_raw` / `wavelet_exposure_cache`，没有
  把它们表述为通过。macOS 原生应用另以 Lensfun 开启配置构建；Windows 新核心的
  `tone_curve`、`tone_curve_api`、`tone_curve_recipe`、`gpu_photo` 四项通过。
- MCP 真实 CLI 的 43 项通过；四端共用 payload fixture 扩至 73 项。Android JVM 324 项
  通过，lint 无 error、74 个 warning；双 ABI 原生/App/test APK 构建完成。Windows
  模型与 WPF 构建通过，无编译 warning/error。iOS device arm64、simulator arm64/x86_64
  三 slice 原生框架校验通过，完整 simulator App/test build 通过。
- macOS 新曲线 native/Agent 检查覆盖 identity、inactive scalar、native sampler、
  pre-HSL probe、session 清零、交互后 FINAL 和 16-bit Agent 导出像素相等。
  iOS processor 的 132 个 raster/buffer 断言通过，RAW fixture 分支明确 SKIP；Android
  新增 3 个 native/Compose 测试通过；Windows native/Agent 11 项通过。
- macOS 在独立资料目录用真实 RAW/CUA 验证精确 Double 输入、增点/固定端点、拖动与
  一步 Undo、连续方向键与独立 Undo、模式确认及 inactive S=65 恢复。真实资料文件
  hash/mtime 未变。iOS 真实 ContentView/XCTest 验证模式、增删点、普通/精细两次触摸的
  精确位移及 Undo/Redo。Windows 交互桌面原生指针、保存/Undo/Redo、取消、精确输入、
  确认框和六语曲线面板大字号共 21 项通过；该检查不等同于整应用六语/读屏验收。
- 实测修复并保留 RED/GREEN：macOS 切换曲线工具前取消历史事务；Apple 模式切换时
  坐标闭包不再索引旧空数组；macOS 数值预检后恢复画布键盘焦点；iOS 保存原始落指点，
  避免 UIKit pan recognition 重置 translation 丢失首段位移。独立只读复核无新增已证实问题。
- 窗口/模拟器/AVD/临时 Windows 任务均按本轮身份关闭；构建包、完整日志、source 与
  artifact SHA256 保留在本轮本地验收目录。未 push、创建 PR、合并或发布。

IT-11/15 仍留有同一集成源的六语大字号、读屏、物理设备和跨功能组合检查，不能仅凭
本轮编译和局部实际 UI 通过关闭。Android 旧宽范围 RAW fixture 阻塞仍按 ITER-08 记录，
本轮没有重写其历史结果。下一步继续 ITER-10/11 的本地实现与验证。
