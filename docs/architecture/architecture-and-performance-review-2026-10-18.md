# RawLab 架构评审、定向复现与性能记录

日期：2026-10-18，时区：Asia/Shanghai。

本文合并本轮架构初筛、深入复核、Android 真机定向复现和性能分析，记录结论如何收敛、证据范围及后续验证要求。它不是已批准的重构方案，也不表示缺陷已经修复。

## 1. 基线与阅读方式

| 项目 | 记录 |
| --- | --- |
| 审查和复现基线 | `e493bb20f19a44452fc23a0f4fc41276e0c6df41` |
| 文档整理起点 | `origin/development`，`4a2c1d3ff7e0973a4257958b1d6ae73c1d9f4ca9` |
| 评审范围 | Android 批量状态及输入寿命、跨端参数语义、Mac 预览接受规则、渲染配置与 C ABI、相关性能热点 |
| 实际执行 | Android 真机 7 项状态/生命周期复现与对照、1 项 journal 基准；真机及 Mac 独立 CPU 几何基准 |
| 本轮实现 | 未修改项目代码、配置或正式测试；只使用仓库外临时夹具完成复现 |

**以下缺陷和数字都属于审查基线，不是对最新 `development` 的重新验收。** 文档整理前已经刷新远端引用；后续代码包含 Android 包与文件拆分等变化。所有源码证据链接固定到审查提交，避免旧路径或行号被误解为当前实现。

当前 `development`（`a883b91`）的静态复核与处置另见[第 12 节](#12-当前代码复核)。

证据分为四类：

- **可控复现**：真实生产调用链在指定调度或故障注入条件下产生了所述结果。
- **已实测**：有明确环境、输入、计时范围和对照的性能数据。
- **静态确认**：调用链或参数语义已经核查，但未完成相应运行验证。
- **延后/撤回**：反证不足以支持原来的缺陷或重构判断，不列入当前缺陷清单。

测试达到预期不等于缺陷消失：本轮复现检查中的部分断言，恰好要求观察到错误状态。

## 2. 结论总览

| 编号 | 初筛编号 | 收敛结论 | 证据级别 | 建议 |
| --- | --- | --- | --- | --- |
| A1 | 原 02 | 取消旧快照可以覆盖终态，阻塞批量页面关闭 | P2，真机可控复现 | 优先保证终态不被旧活动快照覆盖 |
| A2 | 原 01 | 首次 journal 前初始化失败，正常关闭后留下不可发现的副本 | P2，真机故障注入 | 明确首次 checkpoint 与草稿清理责任 |
| A3 | 原 03 | 白平衡中点舍入存在条件性跨端参数差异 | 静态确认，真实 RAW 命中及像素影响未验证 | 先固定语义与共同样例，不合并所有平台模型 |
| A4 | 原 05 | 通用调度与照片/草稿接受规则的分工合理 | 延后，未证明当前发布错误 | 补组合时序测试，暂不抽大型预览模块 |
| A5 | 原 04 | 暂无充分理由统一完整渲染配置或扩大 C ABI | 撤回原建议 | 保留兼容设计及既有端到端契约测试 |
| Perf-Journal | 新增 | 大批次全量 journal 重写有平方级放大 | 真机微基准 | 优化持久化粒度，不能省掉安全检查点 |
| Perf-Geometry | 新增 | active geometry 仍支付完整源尺寸处理成本 | 真机独立 CPU 阶段实测 | 优化内存访问/分块，保留精确输出语义 |
| Perf-Raster | 新增 | iOS 普通图片预览有重复会话和数据库初始化 | 静态确认，收益未实测 | 先统计初始化成本，再评估复用 |

基于该基线，建议顺序是 **A1 -> A2 -> 已测性能热点 -> A3 的边界样例**。A4 不作为当前缺陷重构；A5 不列入整改任务。进入实际实施前，先在目标分支重新定位并核验这些结论。

## 3. A1：取消旧快照覆盖终态

### 3.1 触发与根因

`cancel()` 的单次 StateFlow getter/setter 各自线程安全，但 `read -> copy -> write` 不是原子转换。Main 与 IO worker 都发布同一批次状态，可能出现：

```text
Main: 读取 RUNNING 快照 S，构造 S.copy(stopping=true)，尚未执行 setter
IO:   BatchRunner 结束，发布 COMPLETE / CANCELLED / FAILED 终态 T
Main: 将基于 S 的旧副本写回，覆盖 T
最终: RUNNING + stopping=true，但 worker 已经结束
```

`reportTerminal()` 只发送统计回调，没有再次刷新 batch state；runner 最后的行更新也已经完成，因此不会自然恢复终态。

证据：[取消写回][cancel-write]、[终态发布][terminal-write]、[journal-before-notify][runner-commit]。

### 3.2 真机结果及影响

| worker 实际终态 | 最终页面状态 | 正常关闭 | journal / 输出 |
| --- | --- | --- | --- |
| COMPLETE | RUNNING，stopping=true，worker 非活动 | 拒绝；Compose 返回和取消按钮均禁用 | SUCCESS；已保存 JPEG 可从 MediaStore 重新解码为 64x48 |
| CANCELLED | RUNNING，stopping=true，worker 非活动 | 拒绝 | SUCCESS、CANCELLED；已完成 JPEG 可读取 |
| FAILED | RUNNING，stopping=true，worker 非活动 | 拒绝 | FAILED；没有把失败误记成成功 |

用户看到的是页面停留在“正在停止”，不是 native 任务仍在运行。真实 `EditorViewModel.closeBatch()` 也因为活动 phase 拒绝关闭。

对照检查在终态和 worker 均完成后再调用 cancel，状态保持 COMPLETE，stopping=false。**此问题需要跨线程读改写窗口，不是每次取消都会发生；自然发生概率未测量。**

证据：[关闭限制][close-batch]、[页面返回与进度分支][batch-screen]、[停止按钮][stop-button]。

### 3.3 修复目标与边界

- 在原子状态更新内，基于同一最新快照判断 phase 并构造结果；相关并发读改写点应一致处理。
- 同一次运行的终态不得被旧取消命令或旧活动快照覆盖。合法的重试/重新开始是另一条转换，不能机械禁止所有终态后转换。
- 不能只改 worker 的发布而保留 cancel 的旧式读改写。
- 原子更新可能重试，journal、文件发布、计数等副作用不应放入可重试的更新 lambda。
- 保留行边界取消、不可变 job 快照及 journal-before-notify。当前证据不要求新增全局 actor。

还应覆盖 worker 旧快照覆盖 stopping 提示的反向丢更新。该方向在静态分析中可达，本轮真机重点验证的是更严重的终态回退。

## 4. A2：初始化失败后留下无 journal 的输入副本

### 4.1 精确触发条件

1. 新批次尚无既有 journal；source 和 target 已复制到批次目录。
2. 目标校验使用的第一次 processorFactory 调用成功。
3. start 阶段第二次 factory 调用抛出初始化异常，尚未进入 runner 的首次 commit。
4. model 进入 FAILED，行仍是 PENDING；用户正常关闭而不是显式放弃任务。
5. 关闭只清理 SELECTING 或全部成功任务，因此副本保留；恢复扫描只找 `.properties`，无法发现该任务。

创建 `BatchJournal` 只确保目录存在，不等于保存任务。根因是 FAILED 同时覆盖“未持久化草稿”和“已持久化的可恢复失败任务”，而清理依据只看 phase/行状态。

证据：[初始化顺序][init-order]、[异常处理][init-catch]、[清理条件][discard-condition]、[恢复扫描][pending-scan]。

### 4.2 真机结果与对照

```text
factoryCalls=2
phase=FAILED
closeAccepted=true
journal=false
pending=false
copiesRetainedBytes=418
originalsUnchanged=true
```

真实关闭入口接受了关闭，但冻结 source/target 仍在，重新创建 journal 扫描也找不到任务。本次两个微型 PNG 的遗留量为 418 字节；真实输入会按实际副本大小占空间。丢失的是任务恢复入口，不是删除外部原图。

| 对照 | 观察结果 | 说明 |
| --- | --- | --- |
| 测试先显式保存 journal，再注入同一初始化异常 | 正常关闭后 pending=true，副本保留 | 缺失首次 checkpoint 是关键条件，不是所有 FAILED 都不可恢复 |
| SELECTING 草稿正常关闭 | 副本删除，原始输入不变 | 普通草稿路径有清理，缺口在失败阶段分类 |

该复现不依赖关闭竞态、进程强杀、真实 OOM 或真实存储损坏。异常通过已有 factory 注入；它证明失败处理路径，不能估计设备自然初始化失败的频率。

### 4.3 资源归属与修复目标

| 资源 | 归属及边界 |
| --- | --- |
| 外部原始照片 | 通过 URI 读取并复制，不由批次清理删除 |
| 编辑器 cache | `PhotoStorage` 持有，不能与批次冻结输入混为一谈 |
| 冻结输入和 look | 位于 `filesDir/RawLab/BatchJobs/<id>`，需要明确恢复或清理责任 |
| journal | 决定恢复扫描能否发现任务；仅有输入目录不够 |

优先保证在可能失败的 processor 初始化之前建立可发现 checkpoint。若 journal 自身保存失败，仍需明确草稿清理责任和错误提示，不能声称任务已经可恢复。

保留已持久化失败任务的恢复能力；不要为了清理泄漏直接丢掉所有 FAILED。若要支持进程强杀后的孤儿回收，还需独立约定，不能依赖关闭回调，也不能无差别删除无 `.properties` 的活跃准备目录。

初筛中“已冻结输入可能被编辑器 cache 清理删除”的宽泛担忧已收窄：冻结输入不在编辑器 cache。初始 freeze 与 close 的寿命交错属于另一项尚未定向运行的风险，不应与本次确定复现混写。

## 5. A3：白平衡中点舍入的条件性差异

共享核心返回连续的 camera temperature/tint。Windows 使用默认 `Math.Round`，Apple 使用默认 `rounded()`，Android primer 使用 `std::round`。中点取整策略不同。

例如 getter **精确返回** `tint=12.5`，配方偏移为 `5`、强度为 `1`：

| 平台 | 相机 tint 取整 | 最终 request tint |
| --- | --- | --- |
| Windows 默认中点取偶数 | 12 | 17 |
| Apple / Android 中点远离零 | 13 | 18 |

这不总是只影响显示：配方的目标白平衡 primer 会先渲染中性图，读取取整后的相机 WB，再叠加配方偏移并生成后续 request。

但普通 camera WB、配方偏移为零的当前渲染继续使用核心相机增益，不经过上述回流。**本轮未验证真实 RAW 是否精确命中中点，也未证明最终可见像素差异。** 不应描述为已复现的跨平台画质回归。

证据：[Windows 取整][windows-wb]、[Mac 取整][mac-wb]、[Mac primer][mac-primer]、[Android primer][android-primer]、[核心 WB 估计][core-wb]。

后续先定义明确舍入策略，测试实际 primer/request 路径，并覆盖正负 tint、不同强度和输入类型。不要在测试里另抄转换公式后自证，也不能无声迁移旧 Windows 记录。

以下差异已有兼容理由，不应仅因内部表示不同就要求统一：

- 对比度/饱和度的 UI 百分比与核心乘数表示不同，但新配方最终语义一致。
- 高光方向在不同阶段取反，最终映射一致。
- Mac 旧 HSL 版本保留历史行为，新版本才随配方强度缩放。
- 新照片、缺失字段的旧记录、CLI/C session 有各自兼容的曝光默认值。
- RAW/raster 混合批次应按目标解析相机控制，不能复制来源相机元数据给所有目标。

## 6. 延后与撤回的架构建议

### 6.1 A4：Mac 预览接受规则，延后重构

通用 scheduler 判断队列层面是否有资格返回结果；EditorModel 判断当前照片、草稿、窗口尺寸和外观资源是否仍接受该结果。两层判断不是天然重复。

反证包括：

- 同一时间只有一个 in-flight，pending 只保留最新请求；拖动期间允许较旧 interactive frame 显示是现有契约。
- `draftEpoch` 防止普通预览进入几何草稿后回写，不能简单删除。
- `edge` guard 保护 resize，已有真实 model 集成测试。
- missing look 依赖外部文件可读性，不应塞进通用 scheduler。
- 未找到 `publishedExactID` 导致后续帧被错误阻断的可达路径；busy 也已合并 worker、scheduler 和 resize quiet period。

保留现有分工。优先补“旧 interactive 完成前进入 draft”“外部 look 删除后完成”等受控组合测试；只有实际维护条件继续增长并出现遗漏时，再评估统一事务所有者。

证据：[scheduler][mac-scheduler]、[model 接受规则][mac-acceptance]、[resize 集成测试][mac-resize-test]。

### 6.2 A5：统一完整渲染配置，撤回当前建议

request 与 session 配置分离有明确兼容和资源所有权理由：

- request v2 布局固定，新能力通过 additive setters 扩展。
- session 持有 decoder/cache、GPU、lens DB 等资源，不能简单压成公开参数记录。
- EditRecipe 是独立协议适配器，字符串借用与 fresh-session-per-recipe 已有约定。
- CLI 与各端已经有集中配置阶段；平台 decoder、预览、GPU 和寿命差异不是无意义重复。
- 既有测试覆盖完整 v4 参数组、GUI/CLI FINAL PNG 像素比较、预览、强度、持久化、冻结批次与 lens。

因此不以本轮分析推动扩大公共 C ABI、让原生应用依赖 JSON、统一全部执行入口。新增参数组时扩展现有契约测试即可；未来确有第二个执行入口或配置规则分叉时再评估内部编排。

证据：[C ABI 兼容入口][ffi-contract]、[EditRecipe 约定][edit-recipe]、[完整渲染测试][agent-parity-test]。

## 7. Perf-Journal：全量重写的平方级成本

基线中的成功发布路径对 N 个目标执行 `5N+1` 次 checkpoint：初始状态一次，每行依次记录 processing、publishing、已创建 URI、output-ready、success。每次保存重新序列化全部行，再通过临时文件替换完整 journal。

### 7.1 真机微基准

调用真实 BatchRunner/BatchJournal，渲染和发布回调不做实际图像工作，但仍执行 URI checkpoint。保存后读取 journal 文件长度并累计。10 行预热，25/100/300 行各执行 3 次。

| 目标数 | checkpoint 次数 | 累计序列化写入 | 含 journal 中位耗时 | 3 次范围 | 无 journal 对照中位 |
| --- | --- | --- | --- | --- | --- |
| 25 | 126 | 1.07 MiB | 0.550 s | 0.546-0.551 s | 1.134 ms |
| 100 | 501 | 16.29 MiB | 9.362 s | 9.357-9.386 s | 3.401 ms |
| 300 | 1501 | 149.11 MiB | 77.078 s | 76.941-77.111 s | 11.482 ms |

100 到 300 个目标，累计字节约为原来的 9.15 倍，符合新批次 O(N^2) 的全量重写成本。已完成行在恢复批次中可被跳过，不能把该公式不加限定地用于所有恢复/失败情况。

### 7.2 优化边界

- 优先减少不变任务元数据的重复序列化，并评估行状态的持久化粒度。
- 保留 journal-before-notify、URI checkpoint、发布中断后的恢复顺序。
- 无 journal 只是隔离成本的对照，不是可接受的优化方案。
- 不能为了提速任意 debounce 落盘，或只在整批结束时保存。

上述时间是 Debug instrumentation 中的管理开销，**不含真实 RAW 解码、渲染、相册或目录发布**。累计字节是程序写出的序列化长度，不是 SSD 物理写入量；没有宣称实际 300 张导出总耗时为 77 秒，也没有测量 Release 优化收益。

证据：[runner 检查点][runner-commit]、[全量保存实现][journal-save]。

## 8. Perf-Geometry：完整源尺寸几何阶段

active geometry 关闭 viewport/early-resize，并在最后缩小输出。因此即使画布只需要 1600px，几何阶段仍可能处理完整高分辨率输入。

### 8.1 真机独立 CPU 子阶段

直接编译基线 `photo_geometry.cpp`，NDK arm64、`-O3`，使用合成渐变 float RGB。输入副本准备在计时之外，1 次预热加 5 次采样。

| 源图 | identity 中位 | 90 度旋转中位 | 水平透视 0.2 + 拉直 3 度中位 |
| --- | --- | --- | --- |
| 1600x1067 | 0.001 ms | 10.676 ms | 24.105 ms |
| 7008x4672 | 0.001 ms | 290.525 ms | 486.277 ms |

大图旋转范围为 284.163-295.393 ms，透视范围为 485.244-487.573 ms。7008x4672 的单份 float RGB 像素约 374.7 MiB，这是字节量推导，不是峰值内存实测。

统计只含 `applyGeometry`，不含 RAW 解码、tone/LUT、最终 resize、纹理上传或 UI。**这不是完整帧时、帧率或两个等价实现间的加速比**；小图只是规模对照。

### 8.2 值得优化的范围

先评估 CPU 几何的内存访问、分块和并行处理。交互近似路径若要提前缩小，必须与精确预览、导出明确区分，并重新验证像素与画布契约。

现有契约明确让 active geometry 使用完整源图；GPU Auto 可以由 CPU 完成几何，Force 不能伪装纯 GPU 成功。不能直接提前缩小最终导出，也不能把 GPU 移植当作已经验证的方案。

iOS 在几何变化时可能为比较图与调整图各执行一次处理，可进一步测量该组合链路；两张图语义不同，不能直接当作重复渲染缺陷。

证据：[viewport 资格][geometry-eligibility]、[几何后才缩小][geometry-order]、[CPU 循环][geometry-loop]、[颜色契约][geometry-contract]、[iOS 比较图与结果图][ios-comparison]。

## 9. Perf-Raster：iOS 普通图片初始化与解码

静态调用链确认，`processBuffer` 每次创建/销毁 native session，并加载 Lensfun；display/raster 的有效参数随后又禁用相机专属镜头校正。核心数据库 setter 每次创建数据库并逐一解析 XML，没有全局加载缓存。

可先记录同一输入连续滑杆更新中的 session/database 初始化次数和耗时，再评估跳过明确无用的初始化、复用串行受控的预览会话。不要把 display/raster 的结论直接扩展到 legacy buffer 或 RAW。

普通图片单张 JPEG/DNG 导出还会重新从本地缓存 URL 解码，而编辑器已保留完整 `draftBuffer`。复用前需确认输入快照、方向、并发和内存寿命，不宜直接套用批次目标的资源策略。

本轮没有测量这些 iOS 路径的耗时，不称作已量化瓶颈。Mac 已有持久 session/raster cache，iOS RAW 预览也已有专用复用机制，不能重复建议所有平台统一新增缓存。

证据：[每次创建会话][ios-buffer-session]、[raster 有效设置][ios-raster-settings]、[数据库设置][ios-lens-load]、[核心 XML 加载][lens-database-load]、[导出重新解码][ios-raster-export]、[Mac 已有缓存][mac-raster-cache]。

## 10. 实验环境、覆盖与证据

### 10.1 真机与构建范围

| 项目 | 记录 |
| --- | --- |
| 真机 | LENOVO TB320FC，Android 15 / API 35，arm64-v8a，SM8475 |
| 独立测试包 | `com.rawlab.android.reviewprobe20261018`，未覆盖原安装包 |
| 输入 | 测试包自行生成的两个 64x48 PNG，不读取用户照片 |
| 生产路径 | BatchExportModel、BatchRunner、BatchJournal、EditorViewModel.closeBatch、BatchExportScreen |
| 时序控制 | 测试侧委托 Flow 通过反射包住原 MutableStateFlow，在 setter 入口用门闩暂停；不替换生产状态机 |
| 故障控制 | 已有 processorFactory，目标校验成功后切换为抛 IOException |
| 原生构建 | 基线 shared core 和 JNI 重新编译；NDK 27.2.12479018，arm64，CPU/raster 专用配置 |
| 关闭的能力 | GPU、Lensfun、DNG SDK、wavelet/chroma、OpenMP；测试 factory 不向 NativeProcessor 传镜头数据库 |
| 总结果 | `OK (8 tests)`，270.852 秒；另有独立几何程序 |

专用构建用于隔离状态、文件生命周期和普通图像输出，不是正式全功能 APK/Release 验收。早期模拟器准备曾遇到现有库的 JNI 命名不匹配；最终真机结果不依赖该安装包，而使用重新编译的基线核心及 JNI。

### 10.2 八项检查

| 临时检查 | 基线观察 |
| --- | --- |
| `completeCanBeOverwrittenByCancelAndUiCannotExit` | COMPLETE 回退 RUNNING；真实按钮禁用；关闭被拒绝；JPEG 可读取 |
| `cancelledCanBeOverwrittenByCancel` | CANCELLED 回退 RUNNING；journal 保留正确行状态；已完成 JPEG 可读取 |
| `failedCanBeOverwrittenByCancel` | FAILED 回退 RUNNING；journal 仍记录失败 |
| `cancelAfterTerminalDoesNotRegress` | 终态后再取消不回退 |
| `initFailureThenNormalCloseLeavesUnrecoverableCopies` | 关闭后无 journal、无恢复入口、副本遗留、原始输入不变 |
| `persistedFailureRemainsDiscoverable` | 预先保存 journal 的失败对照可被扫描发现 |
| `normalDraftCloseDeletesCopies` | SELECTING 草稿关闭正常清理 |
| `journalScaling` | 完成 10 行预热和 25/100/300 行各 3 次对照 |

成功输出通过真实 MediaStore URI 重新读取并解码；原始夹具 SHA-256 前后相同。测试收尾在观察产品路径结果之后才显式清理，避免 cleanup 掩盖遗留问题。

### 10.3 关键原始输出

```text
race terminal=COMPLETE stale=RUNNING stopping=true workerActive=false closeRejected=true journalStatuses=[SUCCESS] outputsReadable=1 uiChecked=true
race terminal=CANCELLED stale=RUNNING stopping=true workerActive=false closeRejected=true journalStatuses=[SUCCESS, CANCELLED] outputsReadable=1 uiChecked=false
race terminal=FAILED stale=RUNNING stopping=true workerActive=false closeRejected=true journalStatuses=[FAILED] outputsReadable=0 uiChecked=false
orphan factoryCalls=2 phase=FAILED closeAccepted=true journal=false pending=false copiesRetainedBytes=418 originalsUnchanged=true
control cancel-after-terminal phase=COMPLETE stopping=false
control persisted-before-init phase=FAILED journal=true pending=true copiesRetained=true
control draft-close copiesDeleted=true originalsUnchanged=true
Time: 270.852
OK (8 tests)
```

真机 journal 每组三次原始值：

| 目标数 | 累计字节/次 | checkpoint/次 | 含 journal 耗时 ms，依次列出 | 无 journal 耗时 ms，依次列出 |
| --- | --- | --- | --- | --- |
| 25 | 1121350 | 126 | 549.921094, 545.784010, 550.839999 | 1.621667, 1.133073, 1.134271 |
| 100 | 17083651 | 501 | 9386.236663, 9356.762549, 9362.260101 | 4.846197, 3.400886, 3.395416 |
| 300 | 156352351 | 1501 | 77111.168824, 77078.260543, 76941.331117 | 12.926250, 11.481563, 11.467291 |

辅助 Mac 几何数据来自 Apple M3 Max，同样为 1 次预热加 5 次计时，不替代真机证据：

| 源图 | 90 度旋转中位 | 透视 + 拉直中位 |
| --- | --- | --- |
| 1600x1067 | 5.811 ms | 16.455 ms |
| 7008x4672 | 184.846 ms | 358.816 ms |

### 10.4 复现入口及可复用性

原运行入口如下，**依赖当时仓库外的临时夹具和测试 APK，不是当前仓库中可以直接运行的正式测试命令**：

```sh
adb -s "$ANDROID_SERIAL" shell am instrument -w -r \
  -e class com.rawlab.android.BatchReviewProbe \
  com.rawlab.android.reviewprobe20261018.test/androidx.test.runner.AndroidJUnitRunner
```

后续新增正式回归时，应复用上述真实 model/关闭/扫描路径及门闩时序，而不是复制简化状态机。修复后的断言应改为“终态不回退、结果页可退出”“保留副本可发现或按明确草稿策略清理”，同时保留 journal 与实际成片不变的断言。

构建溯源：

```text
LibRaw 0.22.2 archive SHA-256:
de86b035655accff8d4010f1a221fdf50d353cb7b1422ba26f14a0db92612cfa
Unstripped source-built JNI SHA-256:
6e11e65297b72032d11cae554490da70ca6b3eb502a9795e25793b3742f30531
```

真机及模拟器独立测试包均已卸载；测试 journal 目录为空，MediaStore 无测试包残留图片，独立几何程序目录删除。约 1.1 GiB 临时构建、APK、输入、输出和日志已清理。完整临时夹具曾内嵌于本地 HTML 报告；本文提取稳定结论与关键数据，不依赖操作系统临时路径。

## 11. 未覆盖事项与后续验收

- 未测取消竞态的自然概率、连续点击压力或真实 OOM 下的概率。
- 未用真实 RAW 复验本轮夹具的画质/解码；未验收 GPU、完整 DNG SDK、镜头校正或正式 Release 包。
- 未运行 exact-head CI 或全平台测试；本轮定向检查不能代替这些门槛。
- 未完成首次 journal 保存失败、进程强杀孤儿回收、初始 freeze/close 交错的专项测试。
- 未验证白平衡 exact-half 在真实 RAW 上命中及可见差异。
- 未测 iOS 普通图片初始化、重新解码及几何双处理的占比或优化收益。
- 文档整理没有重跑最新 `development`，也没有把后续包拆分当作修复证据。

实施前先确认目标提交仍存在对应路径，再建立正式回归。先解决 A1/A2 的局部不变量；性能改动要记录同输入、同质量、同构建的前后对照，并保留崩溃恢复和像素契约。A4/A5 不应因曾出现在初筛中就自动成为重构任务。

## 12. 当前代码复核

本节仅对 `development` 的 `a883b91c547e9cc6d5f463d9ece25720dc33e8cd` 做静态代码阅读，**没有重跑设备实验，也没有重新测量性能**；上文实验数字仍只属于 `e493bb2`。处置栏记录本次协调安排，不代表相关工作已合入或完成验收。

| 项目 | 当前代码结论 | 处置 |
| --- | --- | --- |
| A1 | 确认仍在：[IO 状态发布][recheck-worker]与 Main 上的[取消读改写][recheck-cancel]未形成原子转换，旧快照仍可覆盖终态。 | `feature/android-batch-state-integrity` 修复中。 |
| A2 | 确认仍在：新任务的[处理器初始化][recheck-init]先于[首次保存][recheck-runner]；已有未完成行但尚无日志时初始化失败，[正常关闭][recheck-close]仍按[阶段及成功行][recheck-discard]决定清理，副本无法被[恢复扫描][recheck-pending]发现。 | 与 A1 同分支处理，保留已持久化失败任务的恢复能力。 |
| Perf-Journal | 确认仍在：[每次保存全量重写][recheck-journal-save]；另发现[逐行读取内的 `rows.indexOf(row)`][recheck-journal-load]也有 O(N^2) 成本。 | A1/A2 合入后，改为快照加仅追加的行日志，保持旧 v2 日志可读；届时拆出 `startInternal` 的发布逻辑。 |
| Perf-Geometry | 确认仍在：`lutools/src`、`lutools/include` 自旧基线未变；[逐像素双精度变换][recheck-geometry-transform]及[90/270 度旋转按列读取源图][recheck-geometry-source]仍在。 | `feature/core-geometry-cpu-perf` 进行中，限定单线程，要求与旧实现逐位一致；本节未验收该分支。 |
| OpenMP（新增） | 部分确认并修正范围：[macOS][recheck-openmp-mac]、[iOS][recheck-openmp-ios]、[Android][recheck-openmp-android]及[Windows][recheck-openmp-windows]客户端构建均关闭自有核心的 `SONY2FUJI_ENABLE_OPENMP`。前三端核心的 `#pragma omp` 不启用；Windows 自有核心因 MSVC 经典 OpenMP 不支持其余无符号循环，仅对 `raw_processor.cpp` 另加 `/openmp`，其[RAW 输出转换][recheck-openmp-raw]与[JPEG 编码前转换][recheck-openmp-jpeg]两处可并行。LibRaw 等第三方库不在此结论内。 | 先测完整帧耗时，并在完整测试套件下检查线程安全，再决定逐平台启用 OpenMP、采用最小行并行辅助函数，或保持不变。 |
| A3 | 确认基线仍有差异：[Windows][recheck-windows-wb]仍为中点取偶数，[macOS][recheck-mac-wb]为中点远离零；差异仍只在 Windows，真实 RAW 命中与像素影响未验证。 | [PR #79][recheck-windows-pr]已提供对齐 macOS 的修复；记录时仍未合入，不视为此基线已修复。 |
| Perf-Raster | 确认 iOS 静态路径仍在：[普通图片会话及数据库初始化][recheck-ios-session]、单张[JPEG][recheck-ios-jpeg]/[DNG][recheck-ios-dng]导出重新解码，均未量化成本。 | 下一步仅测量，暂不实施缓存或会话复用。 |
| A4 | 处置不变：[调度资格][recheck-mac-scheduler]与[照片、草稿、尺寸接受规则][recheck-mac-acceptance]仍有不同职责，未证明发布错误。 | 继续延后重构，优先补组合时序测试。 |
| A5 | 处置不变：[固定请求布局与增量接口][recheck-ffi]、[独立协议与会话寿命约定][recheck-recipe]仍支持现有分离。 | 维持撤回统一完整配置的建议，不扩大公共 C ABI。 |

对比旧基线，`lutools` 仅有 `cmake/lens-dependencies.cmake`、`tests/dng_jxl_tests.cpp` 改动；不能把包拆分或依赖配置变化当成上述热点已修复的证据。以下本节引用固定到本次复核提交；原审查证据继续保留旧提交。

[recheck-worker]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/RawLabAndroid/app/src/main/java/com/rawlab/android/batch/BatchExportModel.kt#L204-L223
[recheck-cancel]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/RawLabAndroid/app/src/main/java/com/rawlab/android/batch/BatchExportModel.kt#L232-L235
[recheck-init]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/RawLabAndroid/app/src/main/java/com/rawlab/android/batch/BatchExportModel.kt#L165-L205
[recheck-runner]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/RawLabAndroid/app/src/main/java/com/rawlab/android/batch/BatchRunner.kt#L21-L23
[recheck-close]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/RawLabAndroid/app/src/main/java/com/rawlab/android/editor/EditorBatches.kt#L45-L55
[recheck-discard]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/RawLabAndroid/app/src/main/java/com/rawlab/android/batch/BatchExportModel.kt#L343-L369
[recheck-pending]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/RawLabAndroid/app/src/main/java/com/rawlab/android/batch/BatchJournal.kt#L113-L120
[recheck-journal-save]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/RawLabAndroid/app/src/main/java/com/rawlab/android/batch/BatchJournal.kt#L27-L66
[recheck-journal-load]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/RawLabAndroid/app/src/main/java/com/rawlab/android/batch/BatchJournal.kt#L98-L110
[recheck-geometry-transform]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/lutools/src/core/photo_geometry.cpp#L80-L88
[recheck-geometry-source]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/lutools/src/core/photo_geometry.cpp#L49-L131
[recheck-openmp-mac]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/RawLabMac/build.sh#L48
[recheck-openmp-ios]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/lutools/platform/ios/build-framework.sh#L55-L60
[recheck-openmp-android]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/RawLabAndroid/app/src/main/cpp/CMakeLists.txt#L34-L43
[recheck-openmp-windows]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/RawLabWindows/native/CMakeLists.txt#L45-L54
[recheck-openmp-raw]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/lutools/src/core/raw_processor.cpp#L218-L221
[recheck-openmp-jpeg]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/lutools/src/core/raw_processor.cpp#L529-L545
[recheck-windows-wb]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/RawLabWindows/RenderEngine.cs#L130-L137
[recheck-mac-wb]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/RawLabMac/Sources/Rendering/Engine.swift#L307-L312
[recheck-windows-pr]: https://github.com/dancancer/RawLab/pull/79
[recheck-ios-session]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor.swift#L221-L240
[recheck-ios-jpeg]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/RawLab/RawLab/Core/ViewModel/IO/RawEditorViewModel+PersistenceAndExport.swift#L115-L124
[recheck-ios-dng]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/RawLab/RawLab/Core/ViewModel/IO/RawEditorViewModel+PersistenceAndExport.swift#L171-L177
[recheck-mac-scheduler]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/RawLabMac/Sources/Rendering/RenderScheduling.swift#L22-L71
[recheck-mac-acceptance]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/RawLabMac/Sources/Editor/Model/EditorModel+Rendering.swift#L125-L134
[recheck-ffi]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/lutools/include/sony2fuji/ffi/sony2fuji_c.h#L338-L406
[recheck-recipe]: https://github.com/dancancer/RawLab/blob/a883b91c547e9cc6d5f463d9ece25720dc33e8cd/lutools/docs/edit-json.md#L77-L97

## 源码证据

下列链接全部固定到审查基线，不指向当前分支的同名文件。

[cancel-write]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLabAndroid/app/src/main/java/com/rawlab/android/BatchExport.kt#L485
[terminal-write]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLabAndroid/app/src/main/java/com/rawlab/android/BatchExport.kt#L464
[runner-commit]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLabAndroid/app/src/main/java/com/rawlab/android/BatchExport.kt#L125
[close-batch]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLabAndroid/app/src/main/java/com/rawlab/android/EditorViewModel.kt#L561
[batch-screen]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLabAndroid/app/src/main/java/com/rawlab/android/BatchExportScreen.kt#L64
[stop-button]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLabAndroid/app/src/main/java/com/rawlab/android/BatchExportScreen.kt#L239
[init-order]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLabAndroid/app/src/main/java/com/rawlab/android/BatchExport.kt#L423
[init-catch]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLabAndroid/app/src/main/java/com/rawlab/android/BatchExport.kt#L472
[discard-condition]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLabAndroid/app/src/main/java/com/rawlab/android/BatchExport.kt#L596
[pending-scan]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLabAndroid/app/src/main/java/com/rawlab/android/BatchExport.kt#L278
[windows-wb]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLabWindows/RenderEngine.cs#L137
[mac-wb]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLabMac/Sources/Engine.swift#L334
[mac-primer]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLabMac/Sources/Engine.swift#L207
[android-primer]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLabAndroid/app/src/main/cpp/rawlab_jni.cpp#L87
[core-wb]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/lutools/src/core/white_balance.cpp#L97
[mac-scheduler]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLabMac/Sources/RenderScheduling.swift#L51
[mac-acceptance]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLabMac/Sources/EditorModel.swift#L761
[mac-resize-test]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLabMac/tests/ViewportPreviewTests.swift#L170
[ffi-contract]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/lutools/include/sony2fuji/ffi/sony2fuji_c.h#L338
[edit-recipe]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/lutools/docs/edit-json.md#L77
[agent-parity-test]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLabMac/tests/AgentRecipeRenderTests.swift#L202
[journal-save]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLabAndroid/app/src/main/java/com/rawlab/android/BatchExport.kt#L192
[geometry-eligibility]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/lutools/src/ffi/sony2fuji_c.cpp#L1394
[geometry-order]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/lutools/src/ffi/sony2fuji_c.cpp#L980
[geometry-loop]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/lutools/src/core/photo_geometry.cpp#L111
[geometry-contract]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/lutools/docs/color-contract.md#L112
[ios-comparison]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLab/RawLab/Core/ViewModel/RawEditorViewModel+Rendering.swift#L97
[ios-buffer-session]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor.swift#L268
[ios-raster-settings]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor+Helpers.swift#L178
[ios-lens-load]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor+Lens.swift#L71
[lens-database-load]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/lutools/src/core/lens_correction.cpp#L89
[ios-raster-export]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLab/RawLab/Core/ViewModel/RawEditorViewModel+IO.swift#L403
[mac-raster-cache]: https://github.com/dancancer/RawLab/blob/e493bb20f19a44452fc23a0f4fc41276e0c6df41/RawLabMac/Sources/Engine.swift#L96
