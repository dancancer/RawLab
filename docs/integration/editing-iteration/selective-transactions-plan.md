# ITER-03：选择性调整与事务基础

> **For agentic workers:** Use `superpowers:executing-plans`; the coordinator owns
> implementation and default agents provide bounded read-only exploration/review.

**Goal:** 实现可被剪贴板、预设和多目标同步复用的选择性 capture/prepare/commit 与会话历史，
先验证 Mac 原生模型/真实存储，再按同一合同接四端入口。

**Architecture:** 版本化逻辑 payload 与 native snapshot/Agent recipe 分离。纯 adapter
按字段生成完整候选，存储层以身份、版本和完整前态做条件保存，成功后才记录历史。
不增加通用 native DTO，不通过逐个 UI setter 执行粘贴。

**Tech Stack:** Swift/Foundation、现有 Mac Adjustments/EditPersistence 和独立 Swift 测试；
后续 Kotlin/C# adapter 消费同一字段合同。

**Spec:** [ITER-03](../../design/editing-iteration/requirements.md#5-lightroom-式复制粘贴与编辑历史)、
[技术方案](../../design/editing-iteration/technical-design.md#5-iter-03选择性应用与会话历史)。

## 基线、范围和 owner

- 基线 `origin/development@57e4cf7787ac0fdf74dcf40224fc16406d981994`。
- 分支 `feature/editing-selective-transactions`；首批协调/黑白场参考已通过
  [draft PR #133](https://github.com/dancancer/RawLab/pull/133) 提交，尚未合入；本实现无其代码依赖。
- 主代理写本计划、共享 payload、Mac adapter、条件保存与 history、对应测试；默认代理只读核验。
- 紧凑控件 owner 已从 `feature/editor-compact-controls` 交接
  `1071b74c776cab23d74c39aa4b66b42eafe6630f`；本分支通过 merge 保留该提交历史，
  Mac EditorModel/Geometry/Inputs 与六语资源的后续 ITER-03 接线由本任务负责。
- 用户已授权继续 Mac ITER-03、原生验证、提交和更新
  [draft PR #134](https://github.com/dancancer/RawLab/pull/134)；未授权合入或发布。

## Global Constraints

- `payload_version=1`、`scope_version=1`；未知版本/字段/值拒绝，不静默丢弃。
- payload 只包含实际选择字段、逻辑值及解释上下文；来源 as-shot/相机校准、照片内容、EXIF、
  viewport 和临时草稿不进入可应用值。
- all 显式包含 geometry/lens；默认和 modified 排除它们，custom 按显式字段集合。
- modified 按逻辑值和有效默认识别，包括 recipe 注入值；强度 0 不隐藏逻辑修改。
- HSL 24 项、crop 四个坐标、WB mode/Kelvin/tint、lens 各请求及 raw/chroma denoise 分别选择。
  wavelet 按完整算法对象选择；合并后的 crop/WB/recipe 依赖再次校验，不能为了成功覆盖未选项。
  编码与边界见[选择性 payload v1](../../design/editing-iteration/selective-payload.md)。
- exposure/tone/color 使用稳定物理或归一化单位；Mac 百分比和高光符号由 adapter 唯一转换。
- selected look 为 recipe 时，只在完整强度及配方依赖字段都包含时保留源 recipe identity。
  partial capture 可只传固定贡献；target recipe 保留时通过反算和实际 render helper 检查，
  不可表示则 blocked，不静默 clamp、不重跑 applyMasterRecipe。
- 自动项逐目标解释；保存原记录的 processing identity，不将来源 identity 当可复制调整。
- 保存成功且实际变化后才进入 history；条件保存失败保持旧记录；空/重复目标不伪报成功。
- 多目标 history 按照片独立 applied/undone/redo-invalidated；部分失败可重试，新的单张编辑
  只清该照片 redo；相同内容不清 redo。
- 旧 registry v1 和缺少 revision 的记录继续读取；不在读取时迁移。新 optional revision 只在成功保存时写入。

## Review Focus

1. 来源改变/删除不改变 payload，来源校准不被复制。
2. recipe strength 0/.5/2、legacy HSL，以及 target recipe 反算超界不能悄悄改变未选字段。
3. RAW/raster、缺外观和未来版本必须在写入前拒绝。
4. 多实例修改、source replacement、无记录目标与保存失败不会覆盖旧数据。
5. 单张 undo 后整批 undo、部分失败重试、新编辑使单张 redo 失效都按实际成功分量处理。

## Task 1: 逻辑 payload 与 Mac capture/prepare

**Files:** `Shared/AdjustmentTransfer.swift`、`RawLabMac/Sources/Adjustments/MacAdjustmentTransfer.swift`、
`MacAdjustmentTransferValues.swift`、`MacAdjustmentTransferWB.swift`、
`Shared/HSLSettings.swift` 的精确值入口、`Adjustments.swift` 的窄校验/recipe 版本访问入口，
`RawLabMac/tests/AdjustmentTransferTests.swift`、`RawLabMac/tests/adjustment-transfer.sh`。

**Interfaces:** `AdjustmentTransferPayload`（版本/来源上下文/选中值）、`AdjustmentTransferScope`；
`MacAdjustmentTransfer.capture(scope:snapshot:context:) throws -> AdjustmentTransferPayload`；
`prepare(payload:target:context:) throws -> PhotoEditState`。

- [x] 先写测试：默认不含 geometry/lens、all/custom/modified、HSL 单轴单色、源冻结、JSON
  往返/未知字段版本、recipe active/强度 0 与 .5、目标未选值和元数据、RAW/raster、缺外观。
- [x] 实现独立类型与 adapter，所有 selected 字段先验证；不经过 UI 量化或全量 recipe 应用。
- [x] 用实际 `Adjustments.apply`/`renderHSLSettings` 比较目标选中/未选贡献；未选择参数保持
  原始 native 值，确需改变解释上下文时同时验证未选项有效值；不可表示返回明确错误。
- [x] 运行新 runner 及已有 control-groups/master-recipe 受影响检查，记录实际结果。

## Task 2: 条件保存与会话 history

**Files:** `RawLabMac/Sources/Editor/Storage/EditPersistence.swift`，新增
`RawLabMac/Sources/Editor/Storage/AdjustmentTransferSession.swift` 与对应纯存储测试/runner。

**Interfaces:** versioned record read + compare-and-save，保留旧 `state/save`；
session 的 prepare/apply/retry、undoPhoto/undoTransaction/redoPhoto/redoTransaction 返回逐目标状态。

- [x] 添加先失败的临时目录回归：保存成功、无变化、源替换、目标前态/revision 变化、
  只读/非法存储、部分失败/重试、重新打开 registry 后复用已保存值。
- [x] 实现原子条件保存，成功后生成新的 revision 并记录 before/after；所有真实保存仍走原 registry。
- [x] 实现逐照片 history 分量，操作身份固定，skip/failed/unchanged 不进入成功历史；
  undo/redo 再次条件保存，失败不移动对应分量。
- [x] 覆盖单张和整批交错、redo 单张失效、无变化保持 redo、后续独立保存冲突。

## Task 3: 独立复核与原生消费者

- [x] 默认代理对合同、adapter、真实存储/history 做独立复核；主代理核实关键调用链并修复。
- [x] Mac 菜单、复制范围、逐目标预检/结果、会话历史与普通手势接入统一提交入口。
- [x] Mac 接入后的原生 UI 验证及交付记录完成；具体通过范围和未覆盖项见 PR #134。
- [x] iOS/Android/Windows 逐端适配同一字段语义与失败向量，不重新设计另一套 payload。
- [x] 四端共享向量与对应原生工作流核验完成；逐端源码、模拟器/设备边界及现有基线
  套件问题在 PR #134 分别登记，不扩大为全平台硬件或完整发布验收。

## 下一阶段接入边界

- Mac 的 `EditorModel` 已保存完整 versioned record；open/普通保存/geometry Apply/undo/redo
  统一使用该记录和 session。metadata 解析、导航和文本草稿不建立 history；一次拖动只在结束
  时提交一次。显式 native runner 已同步源码，新 history 模型 runner 进入按需 Mac model CI 组。
- `recipe-lut:<id>` 已接入恢复、可重新选择的独立外观、预览及单张/批量导出 resolver。
  它不重新执行完整 recipe，不提供用户导入外观的重命名/删除操作。
- 文件树“应用当前设置”冻结自己的 payload，排除来源且不改写剪贴板；普通粘贴可主动粘回
  来源照片。关闭或重新选择清理操作上下文，保留剪贴板与会话历史。
- 键盘历史失败保留原 transaction/photo/direction 后进入恢复界面；重试不能从单张扩大到
  整批。历史冲突/目标失败独立于当前照片的 autosave error，成功回执不覆盖之后的脏编辑。
- iOS 使用 core multiplier 和独立运行时 WB 校准，不能直接复用 Mac native DTO。它没有
  Mac 的 recipe settings version 或 FBDD 存储字段；旧 HSL 和降噪差异必须由真实 adapter
  映射/明确阻挡。iOS 旧 `noiseReduction` 是 post-RGB request 值，不能冒充 raw FBDD；已补充独立的
  `detail.denoise.post_rgb` 字段与四端模型向量；Mac、Android、Windows 的非零请求明确阻挡。
  iOS 原生接入与实际 Files 多目标工作流已完成对应验证。
- Android/Windows 已接入 native adapter、条件保存与会话历史和原生入口，分别执行本端
  原生测试。Android 校验原始 URI 与临时副本身份；Windows 使用物理文件身份，并在
  实际菜单、文本/照片快捷键、批量部分失败及重启恢复中核验同一事务合同。
