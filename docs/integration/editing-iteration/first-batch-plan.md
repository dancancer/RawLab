# 编辑迭代首批 Implementation Plan

> **For agentic workers:** Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` to implement each owned task. Follow repository authorization, temporary-file and validation rules over generic workflow defaults.

**Goal:** 交付可复用的 I0 字段语义目录、现有 v4 CLI 的本地 MCP 薄层，以及 Mac 六组规则/重置候选，为四端后续接入提供可检验前置。

**Architecture:** MCP 只通过固定 argv 调用既有 CLI；Mac S1 只在现有完整快照上计算修改状态和 reset candidate，不接新 UI 或保存。两条实现线位于独立 worktree，协调分支维护跨 PR 依赖与契约。

**Tech Stack:** Python 3.11+、官方 MCP SDK v2、既有 C++17 CLI；Swift 5、既有 Mac Adjustments/C ABI、现有 Swift 测试 runner。

**Spec:** [总需求](../../design/editing-iteration/requirements.md)、[总技术方案](../../design/editing-iteration/technical-design.md)、[工作区子方案](../../design/editor-workspace/technical-design.md)。

## Global Constraints

- 基线 `development@12cda1c67ddd1c58095831ff12a112fc1356da78`；功能分支独立 worktree；共享文件 owner 见[总账](README.md)。
- MCP 五工具为 `capabilities`、`validate_recipe`、`image_info`、`render_preview`、`export_photo`；只用 stdio，不接受任意命令/shell，不修改全局客户端配置。
- MCP 首批支持 v1～v4，要求 CLI 至少支持 v4 与 `protocol_version=1`，v5 不得提前宣告；输入、外观、输出路径先按原 recipe 目录解析并校验允许根。
- 六组 ID 固定 `looks/light/color/effects/detail/geometry`；保留旧 `AdjustmentGroup`、旧 decoder 和已有 API，导航 ID 不进入存储格式。
- reset 只产生候选，不保存、渲染或修改调用方快照；配方独立化前后非外观 core Float 值及最终 HSL Float 数组必须相等，无法表示则 blocked，不 clamp。
- 精确保持 recipe settings version、旧缺字段默认、HSL 小数、legacy 降噪语义；原始照片只读。
- 不重建设计资产、不写新像素算法、不改 ABI/Agent schema 或本地化；公共 CI 仅由协调者在 #108 接入 MCP 协议与当前 Mac CLI 对照，保留现有门槛；真实平台未运行的检查写未验证。

## Review Focus

- 原 recipe-relative 路径因复制到暂存目录而改变含义；在 MCP 路径测试中固定 Unicode/空格/软链接/越界输入。
- 取消与正常完成竞态导致错误发布或清理别人输出；验证任务隔离、已有目标保护和仅清理未发布私有输出。
- 配方强度 0 隐藏逻辑改动、旧版本 HSL 被再次缩放；Mac 测试同时检查逻辑标记和原 core 有效值。
- 缺失真实 WB 或物化值超范围时猜测/clamp；严格返回 blocked，原快照保持。
- 关闭的降噪/效果保留辅助字段却没有标记、组 reset 串组；完整对象 sentinel 回归证明字段归属。

## Task 0：I0 目录与调度

**Files:** 新增 `docs/design/editing-iteration/field-catalog.md`；维护本目录总账与计划。

**Interfaces:** 消费既有 EditRecipe/C ABI 与四端记录；产出独立 payload/scope 版本边界、稳定字段语义和平台映射。尚未核对字段明确留待冻结，不用默认值推测代替来源。

- [x] 记录字段 ID/类型/单位/范围/默认解析/分组/RAW 条件/配方强度语义及四端来源。
- [x] 区分 native record、payload/scope、Agent、batch journal 版本；列明缺字段、未来版本及未包含字段的处理。
- [x] 核对所有相对链接与需求覆盖；协调者亲自复核关键转换。目录完成不等于跨端 adapter 已实现。

## Task 1：MCP v4 工具

**Ownership:** 协调者分配实施责任，`tools/mcp/` 同时仅一个写入 owner；`mcp_phase1` 负责接入核验。不修改 CLI、core、全局配置。

**Files:** `tools/mcp/pyproject.toml`、锁文件、`src/rawlab_mcp/`、`tests/`、`examples/`、`README.md`。

**Interfaces:**

- 输入启动配置：CLI 绝对路径、一个或多个 read roots、write roots、正任务超时；工具 schema 仅接受其具名数据参数。
- `capabilities` → `--capabilities --json`；`validate_recipe` → `--recipe PATH --print-recipe --json`；`image_info` → `--info PATH --json`；`render_preview` → `--recipe PATH --preview PATH --long-edge N --json`；`export_photo` → `--recipe PATH --json`。
- 校验 CLI envelope 的 command/ok/result/error 与退出码；工具名和 CLI `info/preview/export` 的命名差异显式映射。
- 成功结果返回实际文件、尺寸/quality 等 CLI 事实；诊断只去 stderr，不能伪造能力或像素成功。

- [x] 先新增协商、路径/覆盖保护、envelope 错误、取消/超时和任务隔离的失败测试。
- [x] 实现固定 argv 的异步子进程 adapter、版本交集和真实路径校验；每请求独立句柄，超时/取消等待自己子进程退出。
- [x] 在目标同文件系统的私有暂存位置输出；成功后无覆盖发布，失败/取消不留下最终文件；不以普通 `replace` 偷盖已有目标。
- [x] 接官方 SDK v2 stdio、五工具显式 schema、关闭清理与日志隔离；锁定具体依赖。
- [x] 跑协议/adapter 自动测试与五工具真实 smoke，直接 CLI 对照标准化结果及 preview/export 像素；版本/路径反例必须拒绝。
- [x] 固定负向回归：损坏/未知字段配方、未知协议/缺工具能力、缺失源图/外观、CLI 非零退出/错误 command、无权限/磁盘写出失败；失败时保留已有目标，不能产生成功结果或最终输出。
- [x] 写 Mac/Windows 配置样例、安装/兼容与排错说明；记录实际验证平台和未验证项，提交独立复核。

## Task 2：Mac S1 纯规则与 reset candidate

**Ownership:** 协调者分配实施责任，下列模型/测试同时仅一个写入 owner；`workspace_s1` 负责接入核验。不改 View、EditorModel 或共享资源。

**Files:** `RawLabMac/Sources/Adjustments/AdjustmentTypes.swift`、`Adjustments.swift`、`RawLabMac/tests/ControlGroupTests.swift`，必要时修改 `control-groups.sh` 的测试接线；`Engine.swift` 只把原 raster normalization 改为调用同一模型 helper。

**Interfaces:**

- 新增独立 `EditorAdjustmentGroup` 六值；保留旧八组枚举/API。
- 新增 `EditorResetScope`：组、当前 HSL 色域、全部 HSL、全部调整。
- `EditorAdjustmentContext` 携带本端输入种类/默认曝光模式与中性 film identity；真实 as-shot 使用现有 `Adjustments.asShotWhiteBalance`，不能用固定 6500/0 冒充 RAW 校准。
- 纯 `isModified(scope:snapshot:context:)` 与 `prepareReset(scope:snapshot:context:)` 消费现有 `PhotoEditState`；后者返回 unchanged、完整候选或有类型的 blocked 原因，不保存或调预览。
- recipe 物化 helper 放 `Adjustments` 内部，清身份前读取私有 settings version 与原 render HSL；候选包含 settings、filmID、masterRecipeID 一致的最终状态。

- [x] 先跑现有 control-groups/master-recipe 基线；所用 core 构建须对应当前 core source/config，不借其他分支产物冒充。
- [x] 新增六组归属、完整辅助对象、RAW/raster/legacy 默认、无变化、范围 reset 不串组的失败测试。
- [x] 新增 strength `0/0.5/1/2`、旧 recipe settings version、真实 WB/缺 WB、非有限值/超范围、HSL 小数的物化测试；断言非外观 core Float 与最终 HSL Float 不变。
- [x] 实现纯规则与候选；保留正常配方选择/取消/缩放和旧 decoder；严格验证放在新候选路径，不改变旧输入 parser 的 clamp 契约。
- [x] 执行 `bash RawLabMac/tests/control-groups.sh`、`bash RawLabMac/tests/master-recipe.sh`；发现影响原字段/兼容时补对应现有模型套件。
- [x] 交独立复核；明确这只是 S1 模型前置，未完成 EditorModel 原子提交、UI/设备或整项 ITER-02。

## 首批退出与后续调度

两条实现线分别验证和复核，不把其中一条阻塞传播到另一条。I0 目录复核后，由协调者安排四端 adapter；Mac S1 稳定后，下一任务才接 expected revision、批量赋值、持久化成功判定和 View 路由。MCP 必须完成真实调用后才能验收 IT-01；Windows 未验证时保留平台缺口。

本计划不安排后续功能的自动合并或发布。需要远端操作时，交付可检查的具体分支/提交、验证与风险，再按已有授权推进。
