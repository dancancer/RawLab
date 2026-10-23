# ITER-03：iOS 接入与后续平台准入

> 执行沿用 `superpowers:executing-plans`。主代理负责设计、代码和最终验证；默认子代理只读定位与复核。

## 目标和边界

在 `feature/editing-selective-transactions` 继续已验证的 Mac 合同，实现 iOS 的选择性复制、
逐目标预检/条件保存、部分重试、会话历史和普通编辑提交。iOS 原生验证完成后才开始
Android，再开始 Windows；不能用前一端结果代替后一端验收。

基线：`development@4076810b`，当前分支 `ade8e786`；已有 draft PR #134。
沿用 [字段合同](../../design/editing-iteration/selective-payload.md) 和
[事务方案](../../design/editing-iteration/technical-design.md#5-iter-03选择性应用与会话历史)。

## 决策

- iOS adapter 直接操作 `RawSettings/PhotoEditState`；不经过 UI 百分比，不复制 Mac native DTO，
  不通过 `applyMasterRecipe()` 合并部分字段。相机校准仅来自目标运行时 context。
- 沿用现有稳定字段、版本和共享向量。补齐已记录的旧版 post-RGB 降噪缺口：
  `detail.denoise.post_rgb` 使用 `[0,1]`，与 `raw_level` 分开；旧 payload 缺字段表示不选。
  Mac 只表达该请求为零，非零必须 blocked；不能映射到 FBDD。格式尚未发布，保留 v1。
- iOS 原生范围/精度更窄的请求明确 blocked，不静默裁切或量化。完整 legacy HSL 配方
  只有能在现有 iOS renderer 中保持所选与未选有效值时才可表示。
- `PhotoIdentity` 仍用 Photos resource ID 或内容 SHA-256；不改已有记录键。为旧 store
  增加 optional revisions，读取不迁移；条件保存比较 identity、完整旧记录和 revision。
  跨实例写入读最新 registry 并原子替换，删除保留 revision tombstone。
- `updatedAt` 不作为参数变化；同值编辑不写盘、不建历史、不清 redo。实际保存后的完整
  回执参与后续 CAS；undo/redo 仍按照片历史 head 检查，防止值回到原点后越过后续编辑。
- 所有实际保存复用 `persistEditCandidate`；几何 Apply 保持保存成功后才清草稿。普通拖动
  begin 冻结前态，end 提交一次，cancel 恢复前态；恢复/metadata/导航不记历史。
- 操作页与剪贴板/历史分开；异步目标读取在取消后不能继续提交。多目标资源保留到会话
  history 不再需要，写入前核对源资源与活动草稿，成功回执不能覆盖后续未保存编辑。
- 不拦截 UIKit 文本控件的原生撤销；照片操作通过明确的编辑菜单/历史入口执行。

## 实施顺序

### 1. Adapter 与字段向量

- [x] 先加纯模型失败回归：core 单位、精确 HSL、source freeze、WB 目标校准、recipe strength、
  legacy HSL、独立 recipe LUT、几何/lens 合并、旧版降噪及不支持值。
- [x] 新增 iOS `AdjustmentTransfer` adapter；与 Mac 消费相同 JSON 合法/非法向量。
- [x] 补齐逻辑 post-RGB 字段、Mac 明确能力校验及共享文档，保持旧 payload 可读。

### 2. 存储与会话

- [x] 先加真实临时目录回归：旧记录、revision 冲突、失败原子性、并发实例、无记录目标、
  metadata 无变化、部分失败重试、单张/整批交错、redo 单张失效和 own/external ABA。
- [x] iOS store 增加 versioned read / compare-and-save；平台 session 沿用 Mac 算法与结果语义。
- [x] 普通 save、geometry Apply、reset、配方/外观选择和手势都走成功提交边界。

### 3. 原生入口

- [x] 独立复制/粘贴/历史菜单与 sheet；scope 可选单字段/HSL，全部明确包含 geometry/lens。
- [x] 多照片 PhotosPicker/file importer 使用独立目标加载，不复用 export-only 的任务提交。
- [x] 原生资源/外观/校准预检、活动草稿决定、逐目标结果/跳过/重试、会话 undo/redo。
- [x] Xcode 显式注册新增 app/测试文件；显式 source-list runner 同步。

### 4. 验证与后续平台

- [x] iOS pure adapter/session + 既有 edit-memory/raw-import-history/geometry/parameter 回归。
- [x] 当前源码 iOS app/test target 构建；专属 simulator 执行原生操作测试，记录真实运行结果。
- [x] 独立只读复核，关闭有证据的问题；报告模拟器/真机、编译/执行及未覆盖边界。
- [x] 提交 iOS 当前阶段并更新 PR 验证。
- [ ] 按同一字段与事务失败向量推进 Android，再推进 Windows；分别完成原生验证。

日志、照片副本、模拟器与构建输出放本任务临时目录；验证记录放交付目录/PR，不入源码。
