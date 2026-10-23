# ITER-03：Android 接入与 Windows 准入

在已完成 Mac/iOS 接入的 `feature/editing-selective-transactions` 继续实现 Android；
Android 原生验证后再接 Windows。基线已同步 `development@751f21c5`，Mac/iOS 接入起点 `cfedd2dd`。

沿用 [逻辑字段合同](../../design/editing-iteration/selective-payload.md) 与
[事务语义](../../design/editing-iteration/technical-design.md#5-iter-03选择性应用与会话历史)。
Android 使用本端 `EditSettings`、`PhotoIdentity` 与 NativeProcessor；不套用 Swift
原生快照，不将来源 as-shot 校准或最后渲染结果当作固定参数复制。

## 实施与验证

- [x] 用真实临时目录先复现多 store 实例丢记录，再增加逐记录 revision、条件保存、删除
  tombstone 和严格新鲜读取；保留旧格式读取及非事务 UI 最后可读值。
- [x] Kotlin payload/adapter 消费共享合法/非法向量；按真实 JNI 单位处理配方、白平衡、
  HSL、降噪和几何；不可无损表示的请求 blocked，不静默舍弃字段。
- [x] 会话记录单张/整批 before-after、实际保存回执及历史 head；重试不重放成功项，
  交错 undo/redo、无变化及 own/external ABA 用独立回归验证。
- [x] 普通编辑、手势结束、reset、look、配方和几何 Apply 接同一成功提交边界。
  保留原生渲染队列的 source/request guard；取消手势恢复前态，恢复与导航不建历史。
- [x] 原生复制/粘贴/历史入口，单字段/HSL 选择、多目标获取、草稿决定、预检、逐目标
  结果和部分重试；临时操作状态与剪贴板/历史分开，资源保留到仍需读取的会话结束。
- [x] 运行相关 Gradle 单元测试、当前 app/instrumentation 构建及专用设备上的 Compose/
  原生 processor 验证；记录实际执行、软件/硬件后端与未覆盖边界。
- [x] 独立只读复核并处理有证据的问题；提交并更新现有 draft PR #134，随后推进 Windows。

原始 URI 的替换与授权变化必须在保存/历史前重新核验，私有 working copy 不能独自
证明来源身份。被取消或替代的预检释放未提交副本，成功历史保留必要资源。界面接受
新回执前再次确认当前记录；缓存成功项不覆盖后续 undo/edit。

- [ ] Windows adapter、桌面事务/原生 UI 接入及四端联合验收。

主代理负责实现与最终验证，子代理仅做明确范围的只读定位和复核。日志、测试副本、
构建输出及截图放本任务临时/交付目录，验证过程记录写入 PR。
