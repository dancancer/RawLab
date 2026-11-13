> 返回索引：[RawLab 综合整改任务清单](../remediation-plan-2026-11-13.md)

# 整体方案（2026-11-13 架构决策，覆盖本表排序）

来源：`docs/architecture/architecture-review-2026-11-13.md`（AR-1…AR-7）+ 本台账，经架构决策后重排。**本节的阶段划分优先于 B 表的序号顺序**；B 表仍是逐条状态的事实来源。

### 路线

**先建编辑语义的规格层，其余按主题批次双轨推进**：语义层冻结单端修补，所有跨端语义修复只能以「接入 conformance」的形式落地；语义层之外约 80 行按主题批次并行，不逐行修、也不等地基。

关键事实（决策时新核实）：共享向量机制**已经存在**（Mac/iOS/Android/Windows 都读 `Shared/fixtures/adjustment-transfer-v1.json`），AR-1 缺的是**闭环**——向量不覆盖依赖目标状态的规则、Android 写死 `assertEquals(73, all.size)`、没有字段全集可对账。因此地基不是「新建一套机制」，而是补齐闭环。

### 十条验收不变量（判定技术债是否还清的判据）

1. 每个字段 ID 的类型/范围/默认值/步长/精度/传输分组/重置分组/适用目标类型只在 `Shared/specs` 定义一次，四端与核心 CLI 逐项对账。
2. 粘贴/重置/占位/版本比较规则用场景向量表达，每端按 id 集合消费全部向量，禁止写死计数；平台差异只能进 `divergences` 登记表，条数只减不增（棘轮）。
3. 每端每个历史记录版本都有 golden 样本，投影到字段 ID 空间后与共享期望一致；「未来版本」判定只读版本登记表。
4. 同一批渲染请求向量在 GPU 后端与 CPU 参考之间差异在容差内；Auto 能回退，Force 不伪装成功。
5. C ABI 的结构布局、函数签名、枚举值全部进 fixture；`DllImport` 与 `external fun` 与之对账；JNI 包装面有契约测试。
6. 并发与取消有一页成文契约，每条有测试锚点。
7. 每个测试源文件要么被构建系统发现并在门禁执行，要么列在 manual 清单并写明理由；**CI 里出现 SKIP 一律算失败**（L1 推广）。
8. 文件身份判定只有一条规则（stat 指纹优先、内容哈希兜底），三条热路径的整文件读/哈希次数有上限。
9. 产品版本号只有一处来源；核心源码只编译一次、依赖列表只有一份；仓库无本机路径与误跟踪产物。
10. 跨端语义问题不能用单端 PR 关闭；每个「已修」都要有撤修复变红的锚点。

### 地基层（`Shared/specs/`）

- `adjustment-fields-v1.json`：每字段 `id/type/unit/min/max/identity/step/decimals/targets/raw_only/transfer_group/reset_group/reset_all/since/aliases/deprecated`。
- `versions-v1.json`：processing / hdr_processing / payload / scope / 各端 record、journal、recipe 的 `min_readable` 与 `current`。
- `divergences-v1.json`：`{scenario_or_field, platforms, ledger_id, decision, owner}`；#270 的 `platforms`/`platform_expect` 后续迁入。
- **不做代码生成**（重新评估触发条件：连续两轮新增字段因 parity 返工）；`field-catalog.md` 删掉数值、改为引用 JSON。

### 前提核查结论（2026-11-13，基线 d5d62af7；逐条文件:行证据见 kanban t_e1394964）

1. **字段表口径**：83 个对齐字段中 **59 个存在四端分叉（71%）**——步长/量化 53、范围/可表示值 11、默认/单位 10、缺失 4；暗角/颗粒 8 项在 iOS 被 `rounded()` 强截断且传输入口拒收小数。`adjustment-fields-v1.json` 必须显式分离「传输/持久化精确值」与「UI 步长」两列；P1-② 字段表按此口径划范围，不是从零发明规格。
2. **像素对拍定位**：普通 PR CI 不编译 `lutools`，Windows D3D11 后端按颜色契约硬排 WARP，Android CI 无 GLES 环境 → 渲染像素对拍（含 v0）是**发布前/改动渲染核心时的手动门禁**，不进普通 PR 门禁；普通 CI 只锁「规格契约 + request 结构体数值一致」。
3. **传输测试入口**：Android/Windows 传输单测已直调生产入口（`AdjustmentTransfer.prepare/Prepare`、`AdjustmentPayload.decode/Parse`）→ P1-① 接入不需要测试入口重构，各端 <0.5 人日，直接挂共享黄金 fixture。

### 评审门禁（2026-11-13，用户纪律）

- **合入前必须通过独立 review（agy reviewer，carbon 模型）**；评审结论记入 PR 描述与台账变更记录。纯文档性质修改豁免。review 发现 blocking 时修复后复审，再合入。

### 阶段（以迭代轮次计）

| 阶段 | 内容 | 并行 | 可演示产出 |
|---|---|---|---|
| **P0**（半轮） | 合入 #270–#273 与 3 个 worker 的 PR；一次定完 Q1–Q13 与「UI 测试能否进 CI」口径；前置件：AR-4 并发契约页、S4 fixture 扩枚举与函数签名 | 4 | CI 不再空跑/flaky、fork 结果一致；决策清单关闭 |
| **P1**（1 轮） | 语义地基第 1–3 步：①传输场景接入（Android/Windows + 删写死计数 + divergences）②字段表 + 四端 parity ③重置场景向量（锁定现状）；旁路：C24、JNI 契约骨架、P/Invoke 对账、不变量 7 对账、渲染对拍 v0（Metal 对 CPU，手动门禁——前提核查结论 2） | 6–7 | **四端在同一份场景向量上全绿，divergences 从 k 递减** |
| **P2**（1 轮） | 编辑记录 golden + 版本表（S1/M-N7）；A′ 决策落地使 divergences 归零；HDR 引用式契约；S6 更新器矩阵；存储身份与 IO 批次；A12、I1/A2 | 6 | **divergences = 0；旧记录四端可读** |
| **P3**（1 轮） | 渲染对拍扩到 D3D11（硬件）与 GLES（真机）作为发布门禁；GPU 批次（C2/C6/C7、C29、C26、C5）；AR-4 代码项 | 4 | **同一 edit-JSON 四路一致** |
| **P4**（滚动） | 长尾：核心 CPU 性能批、端内清理、Windows 目录分组、R10/R11/R13 | 多路（可用轻量模型） | 只剩「延期决策」与「明确不修 + 理由」 |

- **最小可行路线**：P0 + P1 + P2 的 S1/版本表，约 2.5 轮。
- **理想路线**：P0–P4，约 4.5–5 轮。
- **止损点**：P1 结束若 Android/Windows 接入仍未绿 → 停止扩规格只保留向量；代码生成永不主动启动；渲染对拍若 CI 跑不了 WARP/GLES → 只留发布门禁。

### 双轨期间的插队准入（四条同时满足）

1. 不改变跨端用户可观察的编辑语义（涉及则必须在同一 PR 补规格行或向量）；
2. 严重度中到高、关乎 CI 可信度、可能丢数据或有安全问题、或已在飞；
3. 只动单端或单层，且带撤修复变红的锚点；
4. 不碰地基锁定的文件（`Shared/specs|fixtures`、四端 `*Transfer*`/`*Reset*`/`EditorAdjustmentRules*`、正在扩 fixture 的 ABI 头）。

### 最可能失败的三件事

1. **规格层变成第二份真相**：parity 出现 skip/白名单、divergences 不降反升、散文里又出现数值。对策：parity 进快速通道、棘轮 + owner + 到期轮次、规格设 CODEOWNERS。
2. **向量测到适配层而非真实行为**（L2 是先例）：对策强制走生产入口、加「仅测试调用」检查、每个接入 PR 撤回一条规则证明变红。
3. **巨型重构拖垮迭代**：单 PR 除夹具超过约 800 行、schema 重写超过一次、整轮没关掉任何行。对策：按例子写向量、每 PR 必须关掉台账行或带来可演示绿灯。
