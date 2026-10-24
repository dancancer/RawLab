# ITER-08 批量编辑与逐张导出接入

本项按[总需求 §10](../../design/editing-iteration/requirements.md#10-批量同步与快捷单张微调iter-08)和
[技术方案 §5.2、§7](../../design/editing-iteration/technical-design.md#52-统一草稿预检)实现。
四端集合、同步、单张微调和逐张冻结任务已接入；实际界面按用户要求解锁后统一验证，
IT-09/10/15 仍未关闭。本地分支依赖 ITER-07 检查点 `9a19a49e`，没有本项远端交付或发布授权。

## 数据与职责

- 集合保存有序稳定身份、选择集合、当前照片、返回位置和最近一次实际变更的同步事务。
  文件名不作为身份；删除、权限失效和重新添加按照片报告，不以同名文件替换。
- 同步持有独立冻结的 payload 和来源身份；构建目标、prepare 与写入时排除来源并去重。
  它复用现有 prepare/CAS/commit/history，不写复制剪贴板。普通微调不覆盖集合的同步历史入口。
- 单张编辑复用原 editor、保存入口和草稿门控；返回保留顺序与选择。预设继续只作用当前照片。
- 草稿 Apply/Discard/Skip 属于当前操作。Skip 不改集合选择，也不提交或放弃该照片的草稿。
  保存失败保持 blocked；全部跳过不生成任务或成功事务。
- 逐张导出先预检所有目标及当前活动编辑器，回到最终参数/实际数量确认页，第二次确认时
  重读记录并校验输入、外观及活动会话。任务持有参数、版本、外观校验、身份、顺序和输出设置。
  后续编辑和外观库变化不能改写任务；任务资源由 journal 自己持有并按原生命周期清理。
- 输出格式、尺寸和目的地在确认时统一确定。每张照片拥有自己的调整；这不新增一个任务中混用输出格式的功能。

## 任务格式兼容

| 平台 | 旧统一任务 | 新逐张任务 | 核心持久化入口 |
| --- | --- | --- | --- |
| iOS | 缺版本/模式按 v1 `uniform_frozen` | job v2、item/settings v1 | `BatchExportModels` / `BatchExportStorage` |
| macOS | job v1/v2 `uniform_frozen` | job v3、item/settings v1 | `BatchExport` / `BatchJournal` |
| Android | 保留 journal v1～v3 reader | journal v4、item/settings v1 | `BatchModels` / `JournalCodec` / `BatchJournal` |
| Windows | job v1/v2 `uniform_frozen` | job v3、item/settings v1 | `BatchExport` / `BatchJournal` |

旧统一任务继续使用来源快照，不读取目标的当前编辑记录，也允许把来源加入导出目标。
来源排除是同步写入的规则。新逐张任务缺快照、未知版本或模式降级均失败，不静默恢复为统一模式。
runner 和预览从相应任务模式读取参数；取消保留成功输出，失败重试只调度失败集合，恢复 publishing
继续先核对已发布输出，成功项不重复执行。

## 接入与验证

- [x] 共享/四端集合模型；同名不同身份、重复目标、桌面硬链接和来源已选中的回归。
- [x] 同步 prepare/CAS/source guard、成功回执、部分失败/跳过及事务历史接入。
- [x] 同一 editor 微调、返回位置、当前草稿 Apply/Discard/Skip 和保存失败反馈。
- [x] 逐目标预检、独立确认、记录/输入/外观变化拒绝、任务独立资源与冻结预览。
- [x] 旧任务兼容、版本拒绝、取消/恢复/失败重试与输出发布状态回归。
- [x] 四端入口、最终参数摘要、六语言来源与资源生成；独立只读复核。
- [x] Mac 原生 EditorModel 与实际像素导出、iOS 纯模型、Android JVM/lint、Windows 模型检查。
- [ ] 解锁后执行四端实际集合→同步→微调→返回→逐张导出闭环；核对照片差异和旧统一任务恢复。
- [ ] 执行 iOS 原生 harness/XCTest、Android JNI/ViewModel/Compose 和 Windows WPF 集合工作流。
- [ ] 四端六语、大字号、键盘/触摸、缺失文件/权限、草稿保存失败及读屏联合验收。

构建应用和测试目标只证明编译通过。原生核心在本项没有改变，复用的核心库必须与源码/配置
逐项绑定；后续新参数仍需进入本端 native snapshot、确认摘要与逐张任务回归，不能另建导出参数 DTO。

具体命令、源码/产物哈希与临时文件清理记录保留在本地交付记录，远端 PR/CI 状态另行登记。

## 解锁后的增量补验（2026-10-24）

Mac 实际完成来源排除同步、两张目标单独微调、保留集合、逐张冻结及 2 张 JPEG 导出；iOS/Android 各自完成真实界面的单照片微调/返回/冻结/放弃流程。iOS 54 项 native history/collection 断言与混合 RAW/raster JPEG/DNG 发布恢复通过；Windows 16 项 WPF collection 检查通过。多照片同步的 iOS/Android 证据来自模型及复用的 transfer 工作流，不能算本轮 collection UI 的多照片覆盖。

本轮证据分别绑定 `cfff3308` 基线与具体修复/测试覆盖层，见外部验收索引 `iteration-08-batch-selection` 中的 `mac-ui`、`ios-ui`、`android-ui`、`windows-ui`；不得合称同一二进制的全量通过。Mac/Windows 默认用户目录未变化。Android 扩展到旧 RAW 套件时，样片不满足镜头匹配前提，后续 instrumentation 退出 255；该扩展运行未通过。后续功能的六语大字号联合验收和实体设备覆盖仍未完成。
