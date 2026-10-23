# ITER-03～11 剩余交付计划

> **For agentic workers:** Use `superpowers:subagent-driven-development` or
> `superpowers:executing-plans` for each bounded implementation batch. Do not treat
> this dependency index as permission to edit another owner's files.

**Goal:** 交付九项剩余功能；分别记录代码、平台接入、质量和真实环境验收。

**Architecture:** 沿用已合入的工作区、保存事务和共享处理核心。复制、预设、同步共用
选择性应用事务；新算法先冻结 CPU 数值合同再接公共接口和各端；更新沿既定
Sparkle/Velopack 路线推进，真实发行链另行准入。

**Tech Stack:** C++17/C ABI、Swift、Kotlin、C#，现有原生测试与四端构建。

**Spec:** [总需求](../../design/editing-iteration/requirements.md)、
[总技术方案](../../design/editing-iteration/technical-design.md)、
[字段目录](../../design/editing-iteration/field-catalog.md)。

## 基线与授权

- 2026-10-23 刷新基线：`origin/development@57e4cf7787ac0fdf74dcf40224fc16406d981994`，
  已包含 [#131](https://github.com/dancancer/RawLab/pull/131)。旧总账中的 S3/S4 未合入描述
  是历史快照，不能继续作为待开发项。
- 用户明确要求本协调任务推进 ITER-03～11；开发、测试和本地集成在本轮范围内。
  push、PR、合入、签名、上传和发布按根 AGENTS 的逐项授权执行。
- 用户已确认发行条件尚未齐备，ITER-11 先做本地开发与验证。可信种子包、签名、公证、
  feed 和真实升级不标通过，也不因这些条件不足而阻塞编辑功能。
- 主工作区和其他任务的未提交内容不动。协调分支为 `feature/editing-remaining-coordination`，
  当前独立 worktree 由本任务持有。
- 活跃的 `feature/macos-adjustment-polish` 负责 Mac 导航高度、滑块和裁切交互；本批不修改其
  Editor/View、Geometry、Inputs 或 `EditorModel+Geometry.swift`。

## Global Constraints

- 原始照片只读；旧照片、旧配方和旧批量任务的像素与恢复语义保持。
- request v2 布局不变；公共配置使用 additive ABI，setter 先完整验证再替换。
- Agent v5 已用于 processing identity。后续新调色字段使用新 schema 版本（拟 v6），
  不扩大现有 v1～v5 接受字段，不提前宣告未接通能力；实施前再次核对版本占用。
- all/modified/custom 与字段存在性分开：缺字段表示不改目标；geometry/lens 默认排除，
  明确 all 或显式选择才复制；自动 WB/曝光/镜头逐目标解析。
- 单目标保存原子化；多目标部分失败逐张保留结果；history 只记成功且实际变化的分量。
- 核心/C ABI/schema、共享本地化、构建/CI 同阶段各有唯一写入 owner。
- GPU Auto 保留一致 CPU 回退，Force 明确 unsupported；不得假报 GPU 成功。
- 新算法的数值回归通过不等于质量冻结；单端/模拟器/本地通过不等于四端/真机/Hosted CI。

## 交付顺序与验收终点

| 工作线 | 顺序与具体交付 | 退出条件 |
| --- | --- | --- |
| 选择性复用 | I2a 字段编码、逐端 capture/prepare 向量 → I2b 单目标 save-first、草稿预检 → I2c 多目标结果和会话 history → I2d 四端入口 | ITER-03：IT-03/04，覆盖源冻结、未选项、RAW/raster、配方、失败重试、冲突和逐照片 redo |
| 用户预设 | I2 完成后，独立 registry、命名/覆盖/重命名/删除与重启；应用复用 I2 | ITER-04：IT-05；删除源照片后仍可应用，损坏/未来版本不覆盖原文件 |
| 批量编辑 | I2 完成后，稳定身份集合、同步、单张复用 editor、返回集合、per-target frozen job | ITER-08：IT-09/10；旧 uniform job 保留，运行后编辑不改变任务 |
| 基础调色 | 黑白场 CPU 参考 → 鲜艳度数值/质量集 → tone 配置/C ABI/new schema → 四端保存/Agent/导出 | ITER-05：IT-06/15；全零旧像素不变，完整参数链和固定质量集通过 |
| 分级与曲线 | 共用已冻结的新参数链；颜色分级独立数值/质量评审；PCHIP 保留 legacy 模式 | ITER-06：IT-07；ITER-09：IT-11；两者分别验收，不互相代替 |
| HSL 目标调整 | 共享 pre-HSL probe 与变换坐标 → 三轴冻结手势 → 四端 UI，提交接 I2 history | ITER-07：IT-08；真实像素、近灰拒绝、过期帧、取消/缩放/crop 与单次 history |
| 空间效果 | Clarity/Dehaze 各自 CPU 参考/固定样本/尺度合同 → bridge/持久化/Agent/导出 | ITER-10：IT-12；天空/人像/夜景/边缘与 preview/FINAL 比较，不以锐化或全局对比替代 |
| 桌面更新 | 本地 descriptor/任务状态/attempt token/持久化/准入 → 框架 adapter → 可信种子版与真实升级 | ITER-11：本地模拟与 IT-13/14 分开；发行条件到位后验证旧版迁移、安装失败和数据恢复 |
| 联合验收 | 每批先集成前置、同步消费者和复核增量；末批固定同一 source | IT-15/16 + 相关 AC，保留设备、GPU、真实读屏及发行限制 |

I2 和基础调色可并行；预设、批量同步不得另写一套合并/历史。算法实现不等待复制 UI，
但新字段交付必须补齐 scope/preset/history/batch 链。未完成项继续留在本轮，不以“下一版”隐藏。

## 当前派发与文件 owner

| owner | 当前独占范围 | 交接点 |
| --- | --- | --- |
| 协调者 | 本计划、总账、字段目录/版本勘误、后续任务拆分与最终验证 | 基线 SHA、接口合同、源/目标变动、测试与独立复核结果 |
| 协调者实施、默认代理只读核验 | 本批 `photo_tone_endpoints.h/.cpp`、对应测试及其 CMake 注册 | CPU 参考、RED/GREEN、数值边界；不改 C ABI/GPU/native/UI |
| 下一批平台 adapter owner | 尚未派发；按端独占模型/存储/操作入口 | 先消费冻结 payload 合同和同一组向量，再接 UI |
| 桌面更新 owner | 尚未派发；本地开发，不启用正式安装 | 状态机和签名/发行准入独立验证 |

## Review Focus

- 配方强度 0 时仍能识别逻辑修改；部分粘贴不改变目标未选字段的实际效果。
- 旧 processing identity 和新字段缺失不能在加载、复制或导出时被偷偷升级。
- 自动 WB/镜头不携带来源校准；同名文件不同身份不能互相覆盖。
- 部分保存失败、单张后来修改和多目标撤销交错，不重复撤销或失效其他照片 redo。
- 更新旧 attempt、保存失败和未落盘 journal 不得穿过安装准入；缺可信发行条件不得安装。

这些跨功能风险分别由 I2、参数链、批量和更新任务补行为测试；下面的首个数值任务只承担
黑白场单调/identity/边界风险，不把未覆盖矩阵算作通过。

## 本次实施任务

### Task 1: 黑白场 CPU 参考与单调性合同

**Files:**
- Create: `lutools/src/core/photo_tone_endpoints.h`
- Create: `lutools/src/core/photo_tone_endpoints.cpp`
- Create: `lutools/tests/photo_tone_endpoints_tests.cpp`
- Modify: `lutools/CMakeLists.txt`（只注册上述源与测试）
- Create: `lutools/docs/tone-endpoints-reference.md`

**Interfaces:**
- Consumes: `RGB` / `ImageData`，`sony2fuji/common.h`，已声明 display-encoded RGB 处理约定。
- Produces: `ToneEndpointOptions { float blackPoint=0, whitePoint=0; bool valid() const; bool active() const; }`；
  `RGB applyToneEndpoints(const RGB&, const ToneEndpointOptions&)` 和
  `void applyToneEndpoints(ImageData&, const ToneEndpointOptions&)`。
- 这是内部 CPU 参考，尚不接 session、CLI、GPU 或 UI；不宣告 ITER-05 已交付。

- [x] **Step 1: 添加失败回归并记录 RED。** 覆盖默认精确旁路（包括超出 SDR 的有限值和
  signed zero）、非法参数 valid()、灰色保持、暗端/亮端正负方向、`.15/.20` 旧反例、亮端
  对称反例、`b,w∈{-1,-.75,-.5,-.25,0,.25,.5,.75,1}` 的 81 组参数和每组至少 10001 个 Y。
  未限幅公式和生产函数的限幅输出都必须非递减；覆盖 `0/.175/.35/.65/.825/1`，完整 image
  与逐像素 API 一致。断言在 Release/NDEBUG 配置仍执行。
- [x] **Step 2: 实现最小 CPU 参考。** 参数有限且在 `[-1,1]`；调用方使用前验证。
  双零直接返回原像素/整图，不执行限幅。非零使用 display-encoded RGB（不是物理亮度）
  的归一化 BT.709 系数加权标量 Y；用 double 中间量，系数和归一化保证灰色 Y 精确不变。
  `S(t)=t*t*(3-2*t)`，先限制 t 到 `[0,1]`；
  `delta=.20*(blackPoint*(1-S(Y/.35))+whitePoint*S((Y-.65)/.35))`；
  每通道加同一 delta，最终 clamp `[0,1]`。不改旧 tone 运算或 RAW sensor metadata。
  单调界 `F'(Y) >= 1/7` 写入合同，明确 active SDR 限幅与零值绕过的区别。
- [x] **Step 3: 运行定向 GREEN。** CMake 注册 `photo_tone_endpoints`；先独立编译新测试
  （无需 native 依赖），再配置现有核心测试构建并运行新 CTest 与受影响核心套件。
  项目完整核心检查按 `lutools/AGENTS.md` 执行；缺依赖或素材记录具体限制，不改旧测试绕过。
- [x] **Step 4: 自查并本地提交 owned files。** 提交前 `git diff --check`，确认没有 C ABI、
  schema、原生 UI 或能力声明改动；保留真实样本质量、鲜艳度和完整链路为未完成。

### Task 2: 协调复核与下一批准入

**Files:** 本计划、`README.md`、总技术方案/字段目录的版本事实勘误。

- [ ] 独立复核 Task 1 的公式、边界、无效配置约定与测试有效性；核对实际验证证据。
- [ ] 记录已交付 CPU 参考的精确提交和本批未覆盖项；ITER-05 整项继续未完成。
- [ ] I2a 下一批先处理四端配方/自动 WB/默认值向量和真实消费接口；不新建没有消费方的
  通用 native DTO，也不把 Agent recipe 直接当剪贴板。
- [ ] 远端交付前整理具体 diff、验证和风险，按项目约定取得本批 push/PR 授权。

## 当前状态

九项均未验收。三条线的只读核查已完成；Task 1 的本地实现为 `1c6fa7f`，
独立 Release/NDEBUG 测试、ASan/UBSan 及本源码的核心 60 项 CTest 通过，待独立复核。
这是黑白场内部参考的验证，不是 ITER-05 的质量冻结、四端接入或 Hosted CI。
ITER-11 发行条件由用户确认尚未齐备，先做本地开发与验证。无 push、PR、合入或发布授权扩展。

I2a 接入核对已定位的具体风险：

- source recipe 的固定贡献要按其版本/强度物化一次；HSL 的 legacy 不缩放分支仍需保留。
- target recipe 保留时，反算所选字段必须在其现有范围内且经实际 render helper 等价验证。
  例如来源 contrast core 为 `1.8`、目标 recipe strength 为 `.5` 时，目标需要 delta `1.6`，
  已超出 native `[-1,1]`；直接填 `.8` 会错误得到 `1.4`。应明确 blocked 或无损独立化，
  不能静默截断，也不能因为一种例子不可表示就一律拒绝所有 recipe 目标。
- 相机 WB 与 recipe tint offset 需分别表达逻辑请求；目标 as-shot 是解析上下文，不能复制
  来源派生 Kelvin/tint。固定绝对 WB、相对 tint 和 raster 不兼容分别验证。
- 外观引用需要 kind/stable identity/resolver；不存在的引用不能替换为 neutral。
- 普通选择性应用保留目标 processing identity。snapshot、revision 和 processing 的变化都应
  使旧 prepared candidate 失效；不要把 processing 当作第七个 UI 分组。

这些是下一批必须覆盖的行为向量，尚不是四端 payload 编码已经冻结或已实现的声明。
