# 第六批 S3：查看、对比与照片状态

> **For agentic workers:** 沿用既有四端 owner、独立 worktree 和独立复评。先补能证明行为的回归，再实现；重型构建由协调者排期，只重验受影响增量。

**Goal:** 完成四端查看/对比、移动端纯预览及相应原生验证，保留 S1/S2 的编辑、草稿、保存和 processing identity。

**Architecture:** 查看状态归本端工作区；一份照片坐标视口投影到各 pane。中性参考沿用已有处理器、缓存和调度队列，补齐身份、构图及尺寸；不新增 C ABI 或处理算法。

**Spec:** [REQ-07～11、AC-13～15](../../design/editor-workspace/requirements.md)、[技术方案第 7、8 节](../../design/editor-workspace/technical-design.md)。AC-16 仅本批非 RGB 部分；另覆盖受影响的 AC-11/12/17/18。

## 基线与范围

- 开发基线 `origin/development@8f40dbcc688b87d7b05ee30092de3183aa4678c6` 已包含第五批 #124～#128；[联合 CI 39774419810](https://github.com/dancancer/RawLab/actions/runs/39774419810) 的 9 项检查成功。此证据属于既有基线，不是 S3 验证。
- 本轮进行中 `development` 合入 #129，推进到 `4dfa8b3eb6e3de5d08f2afdbdfbbf15800a9e9ca`。收尾同步该基线：共享核心由 `bfab4b90` 变为 `97f2a079`，并更新 iOS buffer 所有权及 Android raster 适配层。保留未变化的 UI 交互证据，新核心及适配层另做受影响增量验证，不能将旧 native artifact 标记为新源通过。
- 五个分支为 `feature/editing-view-compare-coordination`、`feature/editing-mac-view-compare`、`feature/editing-ios-view-compare`、`feature/editing-android-view-compare`、`feature/editing-windows-view-compare`。复用已核实干净的隔离 worktree，保留旧分支和主工作区改动。
- 用户已授权本批实现、独立复评和原生验证。push、PR、合入及发布按各自明确授权执行。
- 不重做 S2b 全量输入矩阵，不进入 S4 的 iOS RGB 桥接、Android JNI 或新统计算法，不改参数格式、Agent v4、共享核心、复制/配方/导出快照。
- 设计资产的整体批准与完成状态不因本批接入而修改；旧实现快照不覆盖本批明确的目标合同。

## 共同语义

1. `enabled` 与 `preferredMode` 分开；首次为并排、split 为 0.5。toggle 只切 enabled；选择方式更新偏好并开启；关闭保留偏好。切照片结束临时状态并清旧参考，保留会话偏好；可关闭当前对比，下一次打开仍恢复偏好。
2. 并排只改变照片区内部，按实际宽高选择左右/上下。每个工作区持有一份相对 fit 倍率和归一化照片焦点，每 pane 分别计算 fit 与 pan；不得共用屏幕像素 offset。
3. Wipe 使用同一实际照片矩形，split 是其中的 0～1 比例。线、命中和“调整前/调整后”标识均位于照片内；支持拖动、方向键、Home 回中点与可访问调整。
4. 中性参考采用现有默认 RAW 曝光基准、相机 WB、无外观和默认调色；raster 沿现有 sensor/none 路径。保留 processing identity 及当前已提交 geometry/lens，不能跟随用户调色、借用嵌入 JPEG/旧代理/其他照片，或修改原缓存。
5. 参考 key 至少包含完整 source identity、input kind、processing、geometry/lens、需求尺寸；沿用已有缓存及队列。草稿内禁用对比/hold/纯预览；参考不展示草稿构图。切方式可能通过已有 viewport-demand 发必要 resize，但不得变成编辑或保存。
6. 无常驻对比和草稿时按住临时查看调整前，释放恢复。pan/zoom、多指、cancel、失焦、后台、导入/切图、进入草稿清除临时状态。桌面反斜杠 down/up 相同；文本、菜单、弹窗活动时 `I` 与反斜杠无效。
7. 移动手势优先级：草稿/控件、缩放平移、按住、单击。使用系统阈值和失败依赖；单击等待双击/长按失败，长按释放不得再触发单击。纯预览隐藏常规叠层，保留组、工具、值、滚动、fine 和视口；Back 先退出。提供可访问的进入/退出、查看调整前/返回调整后动作。
8. 左上信息入口、工具栏/更多共用 hidden/file/capture 状态；文字不阻断画布交互。“缩放与显示”中的留白默认开，关闭只减查看边距、仍 fit 完整照片。Windows 查看菜单同源。新增查看偏好仅会话内保存，不新增照片存储字段。
9. 照片顶部约 2 逻辑单位细线投影真实最新请求及 resize 收敛，Reduce Motion 静态说明；不编造百分比、改变布局或高频播报。旧任务不能清新 busy。失败保留最后有效帧、明确未更新并可重试，不冒充 exact；保存错误单独保留，canExport/draft Apply 门控不变。
10. 普通与常驻对比显示 after 统计；hold 仅使用同一已接受 neutral 帧的真实统计，没有则隐藏绘图并保留叠层布局。交互/新帧尚无统计时不能继续显示另一帧数据。RGB 扩展仍归 S4。

## 共享资源

协调者唯一写入 `Shared/strings` 及其 30 个生成输出。各平台消费同一基础提交，不手改资源；缺词交给协调者补齐。Swift/Windows 新 key 等于下表 Shared source，均无参数；Android 使用列出的资源名。

| Shared source | Android resource | 平台 |
| --- | --- | --- |
| 开启对比 | `editor_compare_enable` | 四端 |
| 关闭对比 | `editor_compare_disable` | 四端；提升既有 Windows unique，保留译文 |
| 对比方式 | `editor_compare_mode` | 四端 |
| 并排 | `editor_compare_side_by_side` | 四端 |
| 分割线 | `editor_compare_wipe` | 四端 |
| 调整前 | `editor_compare_before` | 四端 |
| 分割位置 | `editor_compare_split` | 四端 |
| 重置分割线 | `editor_compare_reset_split` | 四端 |
| 查看调整前 | `editor_compare_hold_before` | 四端 |
| 返回调整后 | `editor_compare_show_after` | 四端 |
| 进入纯预览 | `editor_preview_enter` | iOS/Android |
| 退出纯预览 | `editor_preview_exit` | iOS/Android |
| 缩放与显示 | `editor_zoom_display` | 四端 |
| 照片四周留白 | `editor_photo_margin` | 四端 |
| 预览未更新 | `editor_preview_outdated` | 四端 |
| 预览已更新 | `editor_preview_updated` | 四端 |

复用“对比 / 调整后 / 正在显影… / 重试 / 照片信息”；Android 分别为 `compare / result / rendering / retry / editor_photo_info`，其中最后一项新增映射。现有 `neutral` 不全局改名。文案只描述状态与动作；不以“预览已更新”代替保存成功。

## Owner 与执行任务

| 任务 | 唯一 owner | 可写范围与关键交付 |
| --- | --- | --- |
| T0 共享基础 | 协调者 | 本计划、总账、六语来源/生成输出、必要的既有 CI 入口接线。资源检查和独立复核后本地提交，消费者显式合入 |
| T1 Mac | 原 Mac owner | `PhotoCanvas`、`EditorView`、`PhotoViewport`、模型中性缓存/渲染/来源失效与相邻纯查看 helper；补 lens-only reference 和失败保帧。保留 Engine/core/调度算法/几何事务 |
| T2 iOS | 原 iOS owner | `UI/Preview`、`ContentView` 相关 extension、`EditorLayout/EditorDrafts`、VM reference/resize/retry 接线及相应 Xcode 注册；原生 gesture failure 关系、稳定画布身份、导入沿既有草稿待办守卫 |
| T3 Android | 原 Android owner | `PhotoCanvas/PhotoZoom`、`EditorScreen/EditorPanels` 与必要 Dock 接线、`EditorWork/EditorRenderer` 身份缓存窄修；VM/state 默认冻结，必要新增 seam 先交协调者核对，不改 MainActivity/JNI/core |
| T4 Windows | 原 Windows owner | `PhotoCanvas`、`MainWindow` 查看/Rendering/Tools/Transform 取消 seam、`EditorIcon`、`RenderEngine` 中性 key/lens 窄修与相关 tests；不改 Library/JSON/core |

每端同时负责对应正式回归源码。其他代理也在工作，不回退其他 owner 的改动。新 helper 只承载本端查看职责，不建立跨平台通用状态框架。

## 增量验证与独立复评

1. 先用低成本纯模型/控件回归证明：模式偏好、split、同照片焦点投影、来源/后台取消、零编辑/零保存、中性 key/参数。验证 RED 原因，再实现 GREEN。
2. 有 native 依赖的模型/集成回归证明：RAW/raster 的默认 reference、committed geometry/lens、processing 保持，source/resize/latest-only、保帧失败重试、统计配对和保存错误独立。只重跑受影响的草稿/保存守卫。
3. 实际 native 输入验证 pointer/keyboard/touch 序列，不仅调用 handler。移动 iPhone/iPad 与 Android 的代表竖/横布局验证单击/双击/长按/移动/多指/Back/后台和恢复；桌面验证 key-up、文本/菜单/弹窗及 capture/focus 取消。
4. 新增控件验证六语、窄窗/短窗、较大字号、触点、照片内边界、留白完整 fit 和细线不改布局。保持现有画布和 dock 外框预算；不重做 17 工具全矩阵。
5. 执行者报告冻结 diff、源码/构建绑定、实际命令、失败及 NOT REACHED。协调者安排独立需求/代码复评并核对关键调用链；修复后只复评该增量和受影响验证。
6. 原生验证、模拟器、离屏 composition、真实读屏、物理设备和硬件 GPU 分开记录。没有执行的项目不能宣布通过；S3 通过不等于 S4 或整项 ITER 已验收。

## 验证资源

- 已验证的 S2b 基线不再全量重建。iOS simulator arm64 的 `bfab4b90b3915ef32b6b804327b167b4bc1ab52f` native 缓存，只有源码、Xcode/SDK/min target/配置及 artifact hashes 一致时接入；S3 App 与测试必须 fresh build。
- Mac/Android 旧编译产物已清理：如没有完整匹配的其他缓存，只构建一次 core，之后同源增量复用；不能把旧 App 当作 S3 证据。Windows native DLL 同样需 source/config/dependency hashes 一致，复制到任务私有目录；不修改共享 runner 输出。
- Mac/iOS 重型编译错峰；Android 使用任务私有 ADB/AVD、限制编译并发；Windows 使用独立输出和测试时段。启动前检查占用，不影响其他任务或用户设备。
- 一次性日志、截图和构建绑定放主工作区 `.cache/tmp/editing-view-compare/`；依赖/只读素材按版本或 hash 共用 `.cache/shared/`。任务结束审计后清理不再需要的自有产物，保留复用价值明确的 native 缓存。

## 本地收尾状态

- 四端均已正常合入 `5eaff75c`，包含 `development@4dfa8b3e`；实现及后续生产增量均已独立复评。最终提交见[总账交付索引](README.md)。
- 四端本批原生增量与证据绑定已完成。Windows 在共享 VM 空闲后补齐外观、真实输入及 UIA 切图/重开/重启链，并修复 IME 与窗口外松键后的恢复问题；最后生产和测试增量已独立复评。约定的本地交付没有剩余阻塞，远端集成和下列设备边界继续单独登记。
- 旧核心 `bfab4b90` 的 UI 证据保留原归属；当前核心 `97f2a079` 的 source、配置与 artifact hashes 单独核对，并补跑受影响 RAW/raster/所有权路径。没有以旧二进制证明新核心通过。
- S3 随下述阶段汇总 PR 交付；真机、真实读屏、硬件 GPU 和校准镜头样片仍保留明确缺口。S4 RGB 的后续本地交付见[第七批索引](seventh-batch-plan.md#本地交付索引)，不改整体 ITER 的验收状态。

## 汇总 PR 交付

用户于 2026-10-23 确认先将已完成工作合入阶段开发分支，再统一向 `development` 提 PR。本轮复用 `feature/editing-rgb-integration`，已包含四端 S3/S4、共享资源和 MCP 平台补充的最终提交。

仅推送这一汇总分支并创建目标为 `development` 的聚合 PR，使用现有 PR 触发条件及受影响平台矩阵；不另外创建指向阶段分支、但未覆盖现有 CI filter 的子 PR。独立复评和原生验证保留各自源码归属，聚合 PR 的实际 head/base 与 CI 结果在 PR 登记。

本次授权覆盖阶段汇总、push 和创建 PR；聚合 PR 合入 `development` 以及后续发布仍按各自授权和门禁执行。
