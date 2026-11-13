# RawLab 架构评审（2026-11-13）

从架构层面（模块边界、依赖方向、共享策略、契约形态、测试拓扑）对全项目的一次独立审视。
与另两份文档的分工：[评审 2026-11-12](codebase-review-2026-11-12.md) 管"全仓问题地图"，
[跟进核对 2026-11-13](codebase-review-followup-2026-11-13.md) 管"整改后的真实状态"，
本文管**结构本身**。三处编号互相独立（本文用 AR 前缀），可互引。

## 1. 基线与方法

- **基线**：`development` @ `d05c8d7d`（2026-11-13，`origin/development`）。只读，未运行构建或测试。
- **方法**：在两份评审与 51 条跟进发现之上做结构归纳，并对本文引用的每个度量重新取证：
  C ABI 导出面计数、四端绑定层规模、参数规格文件分布、HDR 子系统文件清点、
  CMake 目标与链接块对照、近 300 提交触达频率。计数命令可复现，标注 ✓ 的均已亲自核对。
- **读者预设**：熟悉根 `AGENTS.md` 与 [color-contract.md](../../lutools/docs/color-contract.md)。

## 2. 架构形状与做对的地方

```
四端原生 UI（SwiftUI×2 / Compose / WPF）+ 桌面 Agent/MCP（CLI）
        │  各自的应用架构：actor / ObservableObject / 协程 / Dispatcher / code-behind
调整编辑语义层  ← 目前四端各一份 + 核心 recipe 校验一份（见 AR-1）
        │
共享 C ABI（95 个导出函数；struct 带版本+大小前缀；不透明会话句柄）   ← 唯一刻意设计的缝隙
        │
lutools C++17 核心（core / gpu / ai / platform / ffi）+ LibRaw + x3f-bridge(Rust)
```

这个拓扑对"本地编辑、跨端渲染一致、原生交互"的产品定位是正确解，且执行纪律高于平均水准：

- **ABI 卫生**：结构体逐一校验版本与大小；布局 fixture 每次 CI 从 C 头重生成、clang AST 双重
  校验（拒绝 `long` 类非便携类型与 padding 新增字段）；Windows 托管侧有同 fixture 的镜像检查；
  Rust 桥整体 `catch_unwind`；Android JNI 用不透明编号而非裸指针回调。（✓）
- **版本化迁移架构**：processing_version + 迁移回执 + 全源校验 + tombstone，"老编辑记录永远可读"
  是有测试的合同。这套纪律在独立摄影软件里少见。
- **`Shared/strings` 规格驱动共享已经跑通**：单一 JSON 源 → 生成 → 逐字节比对进 CI。
  它是本文最重要建议（AR-1）的既成先例：这个仓库知道怎么做规格化共享。
- **存储语义方向一致**：原子写、损坏隔离、journal、孤儿清理四端同构（质量差异见跟进文档 §4）。

以下问题按"结构性影响 × 修复杠杆"排序。

## 3. 结构问题

### AR-1（高）调整编辑语义层没有单一来源

**现状**：C ABI 之下共享干净，**之上有一整个语义层四端各写一遍，核心还掺了第五份**：

| 知识 | 现有份数 | 位置样本 |
|---|---|---|
| 参数范围/默认值/步长 | 4 + 核心 recipe 校验 | `RawLabWindows/Adjustments.cs` `ParameterSpec`、iOS/Android `EditorAdjustmentRules.{swift,kt}`、Mac 一套、`lutools/src/cli/edit_recipe.cpp` 独立区间校验 |
| 粘贴/传输规则 | 4 | `AdjustmentTransfer*` / `HDRAdjustmentTransfer` 每端各一份（Swift 侧部分入 `Shared/` 但仅两受益端） |
| reset 保留规则 | 4 | 上轮 §4.2：Mac/iOS/Android 对齐后 Windows 仍清休眠 HDR |
| 编辑记录格式 | 4 | 上轮 S1：Swift×2/Kotlin/C# 独立实现，无共享 golden fixture |
| 版本上限登记 | 4+ | 上轮 M-N7：Mac journal 五处硬编码，各端各一份 |

**证据（后果而非理论）**：评审 14.8 跨端表十行不一致全部落在这一层；reset 隔离一个语义拆 4+1 个
PR 后仍漏 Windows 半条；R3（范围无单一来源）/R7（精度两派）自评审起未决。仓库为 LUT 与文案建了
共享规格，唯独产品最核心的编辑语义没有。

**改进**：不必把决策逻辑搬进 C++（保持四端 UI 原生合理）。复制 strings 模式：
`Shared/specs/`（参数规格表、传输/重置规则表、版本登记表）作为单一来源；先做**一致性向量 +
每端 conformance 测试进 CI**（成本低，Windows 半条漏修这类问题当场变红），再评估是否代码生成。
编辑记录 golden fixtures（跟进文档 S1）是同一机制的第一个用例；R3/R7 是顺带的受益者。

### AR-2（中高）唯一缝隙的维护方式跟不上表面积

C ABI 是刻意设计的单缝，但缝两侧都是手抄契约：

- 导出函数已 **95 个**（`sony2fuji_c.h` 69 + `sony2fuji_hdr.h` 26），门面 `sony2fuji_c.cpp`
  3106 行、近 300 提交触达 16 次（✓）。
- Windows：**154 个手写 `DllImport` 签名**分布在 25 个文件（✓）。
- Android 不直接绑 C ABI：`rawlab_jni.cpp`（1556 行）**再发明了一层自有原生 API**，Kotlin 侧
  44 个 `external fun` 依赖的是这个 JNI 包装面的行为（会话生命周期、取消、错误映射）——
  同一核心实际维护着两层面孔，且第二层没有任何类似 ABI fixture 的东西护着。
- 新 ABI fixture 只钉 struct 布局（50 个全覆盖）：**函数签名与 16 个枚举取值不在门禁内**；
  生成器硬断言 64 位；本地 `test.sh`/ctest 不含它，漂移只在 Contracts job 暴露（✓，跟进 G-N7/C-N7）。

**改进**：① fixture 扩"函数符号+签名哈希 + enum 常量"（生成器已有 clang AST，增量小）；
② P/Invoke 声明从 C 头半自动生成或至少在 Windows 镜像测试里对全量符号做一次存在性对账；
③ 给 `rawlab_jni.cpp` 的包装面立一份契约测试（错误码映射、取消语义、会话编号复用），
把"第二层面孔"从口口相传变成测试对象。

### AR-3（中高）HDR 是横切的第二套架构，缺一份对等的集成契约

核心侧 `hdr_*` 文件 23 个（core/platform 两层），每端再有平行子系统
（`Shared/Native` 6 个、Kotlin/C# 各一簇）（✓）。历史轨迹是"影子管线"：三份缩小实现
（现收敛 2/3，`hdr_resample.h` 仍独立）、HDR 专属传输/重置规则（14.8 表占三行）、每端自己的
HDR 画布与状态机、专属的迁移字段（`hdr_processing_version`）。v0.9–v0.10 的功能扩张全部压在
这条第二轨道上，而 **SDR 有引用式的 color-contract.md，HDR 只有叙述式设计文档**——
[technical-design.md](../design/hdr-photos/technical-design.md)、[android-windows.md](../design/hdr-photos/android-windows.md)、
camera-raw、proraw 四篇加 release notes 承载了输入模型、位深与 gain-map 语义、与 SDR 路径的交汇规则
和每端能力矩阵，但没有一个"改行为必须回来改、测试可以指着断言"的单点契约。

**改进**：一份 `docs/design/hdr-photos/contract.md`（或并入现有 technical-design）把 HDR 的
边界规则收拢成引用式契约；HDR 相关的传输/重置/重置保留规则进 AR-1 规格表，避免每个 HDR 新特性
重演一遍四端漂移。中期方向：HDR 渲染原语（缩小/采样/色调映射入口）在核心收敛为单组 API。

### AR-4（中）会话与线程是"注释级契约"

核心的并发模型以逐函数注释散布（如 `sony2fuji_c.h:469`"never on a UI thread implicitly"、
`:540`"caller-owned serial session"、`:790-796` 取消回调条款），没有一处集中回答：
谁能调用、必须序列化到什么粒度、回调可否被并发调用、取消在哪些阶段生效、多会话是否真并行。
两个既有后果：跟进 C-N4（回调实际被 `cv::parallel_for_` 工作线程并发调用，契约未写）；
Android 全局 `sessionsMutex` 把批量导出与编辑器预览完全串行化（跟进 A-N2）——**核心没说清
自己的并发模型，客户端只能各自保守**。

**改进**：一页 `processing-concurrency` 契约（可并入 color-contract 或 platform-integration），
内容就是上面五问 + 状态码语义；取消相关（检查点粒度、迟到取消、编码阶段行为）一并说清
（跟进 S5）。成本一页纸，拦住的是整个"隐式契约 bug 家族"。

### AR-5（中）"共享到什么程度"的界线没画出来

现状两种症状并存：该共享的没共享（AR-1 的语义层、预览调度合并规则——Mac 的 80 行
`RenderScheduling.swift` 被评为最佳实现，但其余三端各自重实现同一产品规则）；
每端本可自由的又被要求手拉手（同一个修复拆四端 PR、四份测试脚本清单）。
建议的划线标准：**用户可观察的行为（合并/失效/保留/失败语义）= 产品合同，进规格与 conformance；
实现手段（actor vs 协程 vs Dispatcher、缓存算法、UI 结构）= 平台自由。**
这条线一旦明确，"要不要建共享库"的答案也随之清晰：先不需要共享**代码**库，需要的是共享**规格**。

### AR-6（中）测试拓扑与契约面不成比例

契约面（四端 × N 语义 × 四渲染后端）在增长，测试组织没跟上：

- 三端靠 standalone console/shell harness + **每脚本手写源码清单**（R14）：改一次签名改一片脚本；
- 新写的 532 行相机回归落在 Xcode scheme 外的独立 harness（I-N9），"写了测试"与"CI 跑测试"脱钩；
- Windows 原生门禁是 23 个测试名的手工白名单（R6），新默认不跑；
- **没有任何东西在"同一份 edit-JSON 在 Metal/GLES/D3D11/CPU 四路渲染一致"层面兜底**——
  这恰是产品最核心的承诺，目前只有核心数值单测间接覆盖。

**改进**（按性价比）：① 跨端渲染 conformance：同一批 recipe 向量 × 四端（或至少核心 CPU vs
各 GPU 后端）容差对拍，先做成手动触发的发布门禁，再谈进普通 CI；② 测试清单机制尽量交给
构建系统生成（CMake/gradle/SPM），消灭手写清单漂移；③ Windows 白名单换成 `ctest -N` 对账。

### AR-7（低中）陈旧但明确的结构账

- **C24 原样存在**（✓）：`sony2fuji_core`（STATIC）与 `sony2fuji`（SHARED）把 `${CORE_SOURCES}`
  编译两遍，链接配置是两块近似的 17 行手抄，且已出现漂移样本——Apple 分支 shared 侧重复链 `uhdr`
  并多链一组 framework（`lutools/CMakeLists.txt:245` vs `:310`）。改 OBJECT library 或
  `foreach(target ...)` 共享同一依赖列表即可根治；这属于"每次加依赖都要记得抄两遍"的税。
- **Windows 客户端结构债**：根目录平铺约 150 个 `.cs` + code-behind + console harness，
  与 Mac/iOS 分层目录相比靠惯性生长；它直接解释了为什么 Windows 整改的 diff 最难 review
  （跟进 R6/W-N 系列全部集中于此）。不必重构，值得一次纯移动式的目录分组 + `.csproj` 整理。
- **版本上限散落**（AR-1 的表已含）：journal/记录/配方的"未来版本"识别各端硬编码多处，
  缺版本登记表；登记进规格文件后，M-N7 类"漏枚举把好任务判损坏"的风险随 AR-1 一并消解。
- **能力协商未成一条道**：AI 降噪 GPU-only、HDR HEIF 运行时门控、X3F 按构建开关——核心 CLI 有
  `--capabilities`，但客户端各自探测（`aiEnabled`、系统版本判断、后端存在性）。建议四端统一
  从核心取一个能力快照（含各后端存在性），替代散落的 ad-hoc 判断；错误码语义配合 AR-2③ 的
  映射测试一起收（跟进 G-N1 的 Force 错误码分裂正是能力协商缺失的一种表现）。

## 4. 不建议统一的（避免过度工程）

- **四套原生 UI 栈与其应用架构**（SwiftUI×2/Compose/WPF；actor/协程/Dispatcher/code-behind）：
  这是产品定位的一部分，强行统一收益为负。要统一的是它们消费的行为规格（AR-5），不是实现。
- **C++17 + 异常在 C 边界收敛**的现状：好过引入新错误体系；配合 AR-4 文档化即可。
- **`Shared/` 只服务 Swift 双端**：结构上合理（Mac/iOS 血缘最近），只要不再往里塞"假装四端共享"
  的假设即可（当前 7 处平台特判都在 UI 封装层，可接受）。
- **CLI/Agent 走 C++ 而非 C ABI**：同一核心、不同缝，合理；风险只在语义与 GUI 分叉——由 AR-1
  的规格表与 AR-6① 的对拍顺带看住。

## 5. 优先级建议

| 顺位 | 动作 | 消解 | 量级 |
|---|---|---|---|
| 1 | `Shared/specs` 规格 + 每端 conformance 向量（从编辑记录 golden fixtures 与 reset/传输规则表起步） | AR-1、跟进 S1/R3/R7、M-N7 | 一轮迭代 |
| 2 | 并发/取消一页契约 + ABI fixture 扩枚举与函数签名 | AR-4、跟进 C-N4/S5、G-N7/C-N7 | 各数天 |
| 3 | 跨端渲染 conformance 对拍（先手动门禁后进 CI） | AR-6 | 数天～一轮 |
| 4 | CMake 双 target 合并依赖列表（OBJECT library） | AR-7/C24 | 一天 |
| 5 | JNI 包装面契约测试 + P/Invoke 符号对账 | AR-2②③ | 各数天 |
| 6 | HDR 对等契约文档；HDR 规则入规格表 | AR-3 | 文档一轮 |
| 7 | Windows 目录分组、测试清单生成化、能力快照统一 | AR-7、AR-6② | 见缝插针 |

一句话结论：**下层（核心、ABI、存储、迁移）已经高于水准，上层（UI 原生性）是定位所在，
真正的结构空洞在中间那层——编辑语义没有规格化。** 如果这轮只做一件事，做 AR-1；
它的两个前置件（并发契约页、fixture 扩展）都很便宜。

## 6. 限制

- 只读评审，未运行构建/测试；计数与文件清单基于 `d05c8d7d`，引用行号只对该基线有效。
- AR-1 的"四端各一份"统计到规格文件粒度，未逐字段比对四端取值差异（R3 已给出抽样结论）。
- GitHub 仓库设置（fork 审批、保护规则）影响 AR-6 中"CI 跑测试"的判定，同跟进文档 §7。
