# RUM 四端接入实施计划

Goal: 在已有大陆电信连通性证据上增加隐私优先的四端统计基础与业务打点。

Architecture: 客户端强类型事件 + 默认关闭的同意控制 + 可注入 RUM 适配器；不修改渲染核心。

Spec: [RUM 统计设计](../specs/2026-10-16-rum-analytics.md)

Global Constraints: 保留已有改动；不提交/推送/发布；不泄露 `.env`；不修改限额和权限；未知许可的 SDK 只允许显式本地验证，不进入正式包；无法安全停止的 SDK 不启用；测试输出使用临时目录并清理。

Review Focus: 默认关闭、撤回同意、发布成功边界、批量重试增量、SDK 缺失不影响构建、许可与实际验证范围。

## 任务

1. 核实 SDK API、启停/隐私能力、许可证和云平台配置 schema，更新小样验证记录。许可或退出 API 不明时采用明确不可用的关闭适配器，继续独立工作。
2. 先增加 Swift/Kotlin/C# 同意控制和固定事件契约的失败测试，再实现；使用假传输证明不联网的行为。Swift 放 `Shared/UsageAnalytics.swift`，其他平台放各自源码目录；测试遵循现有独立 harness。
3. macOS：`RawLabMacApp.swift`、`AboutView.swift`、`EditorModel.swift`、`FilmDock.swift`、`BatchExportModel.swift` 接入启动、用户选择、成功导入/导出和批量终态。官方 PC SDK 适配器与打包按许可门槛启用，不影响默认构建和现有模型测试。
4. Android：复用 AboutDialog 的原生 Switch，接 `MainActivity`、`EditorViewModel`、`EditorScreen`、批量完成回调；遵守 stringResource。只增加必要依赖，不增加自动插桩插件。
5. Windows：复用 AboutWindow CheckBox，接主窗口生命周期、成功导入/导出、用户外观选择和批量终态。独立 portable 测试验证契约/持久化。
6. iOS：共享 Swift 契约，原生隐私设置 sheet，维护 Xcode source 注册；业务入口与其他端一致。不猜 SDK 未公开的关闭 API。
7. 执行可用的平台检查及独立整体评审，修复明确问题。记录已通过、未验证、受阻门槛和下一步；清理本次临时产物，不碰用户文件。

## 执行决定

- 在现有 `feat/multilingual-support` 工作区继续，避免在用户离线时切换分支或复制其未提交工作；按平台明确文件所有权。
- 方案和最终验证由主代理负责；相互独立的平台实现可限定目录委派，所有代理不得撤销他人改动。
- 2026-10-16：此前 API `quotas={}` 不作为无限额证据；记录用户后来确认的 `1 OCU/天`，不再使用无上限豁免启动正式客户端。
- 评审统一 `film_selected` 口径为用户点击且选择改变；导入后自动选中不计入，未增加外观导入事件。

## 第一阶段状态（历史）

任务 2–6 的业务层、默认关闭控制和 UI 已落实；任务 1 的许可/核心源码/平台 API schema 核验发现发布门槛，真实四端 SDK 适配器和另外三端云应用尚未启用。任务 7 已执行本机可用验证及独立评审，设备运行测试与 SDK/云端四端验证仍未完成。完整证据与后续问题见 [验证记录](../../verification-rum-analytics-2026-10-16.md)，不能将本计划整体标为四端上报完成。

## 本地真实 SDK 阶段

用户新授权覆盖先前的许可阻塞，但不授权发布或变更限额。沿用当前脏工作区，避免丢失四端基础统计改动。

1. 核验官方 SDK 的精确启停、模块关闭、缓存和平台配置；只读核验现有上海应用，按已核实 schema 创建必要的独立验证应用，不改已有产品权限或限额。
2. 用测试先证明配置白名单、撤回时排队事件丢弃、SDK 生命周期串行且不阻塞界面。PC 共用已核实 C ABI；移动端使用官方 API，不手写上报协议。
3. 真实 SDK 由显式本地开关启用，默认与发布构建拒绝携带；Android 使用独立本地包名，不覆盖设备现有版本。验证模式不改日常持久化同意。
4. 分别编译并运行 macOS、iOS Simulator、Android 实机和可用 Windows 验证宿主；每端只发送有界合成事件，关闭后清理缓存。仅云端按随机标记回读成功才记为大陆上报通过。
5. 独立复核改动、执行相关回归、记录每个平台实际到达的验证层级，清理一次性产物。

决定：主代理负责方案、PC 适配和最终验证；移动 SDK API 与 Windows 宿主核验独立委派只读代理。平台实现若委派则明确文件所有权。合成验证不要求照片权限或真实输入。

阶段记录：
- 本地 SDK 四端源码及五类合成事件 API 回读均通过。macOS/Windows/iOS 返回中国、电信；Android 实机五类事件均入库，activeNetwork 无 VPN/HTTP proxy，停止/清理及需重启终态通过，但云端地区字段为空，入库与地区证明分别记录。iOS 为 Simulator，不外推物理 iPhone。
- 官方 ARMS `GetRumAppInfo` 在上海实测可读取本次 CMS 应用；核对 PID、region、appType 后，仅对新建 Android/iOS 验证应用 `UpdateRumApp` 关闭非必要采集，再读回确认只剩 customevent，无版本覆盖。保留采样率、限额和权限。
- 独立 PC 评审采纳 LOCAL 环境与规范化产物路径修复。保留已存储 consent 在 unavailable 构建中可见且可撤回的行为；“默认关闭”指新安装默认，不意味着隐藏历史同意。已补回归，SDK 不会因 unavailable 状态初始化。
- Windows VM 使用新建私有临时目录，不使用共享构建 workspace。首次探针已到云，但 PowerShell ExitCode 为空造成验证器误报失败；已修正进程句柄等待并以新标记重跑，确认退出成功及私有缓存为空。
- 最终 PC 复核补齐 close 失败后的永久不可用、UI 刷新及 stop 后立即 re-enable 的排队竞态；回归先失败再通过。停止失败时保留 native options，不重复 close 或继续 record。
- Android 专用本地包验证后已卸载，原有正式包和测试包保留；Windows 本次私有目录已删除。SDK/API 下载缓存保留；macOS/iOS 临时构建、私有 SDK 日志和一次性 API 解包目录已清理，Android `:app:clean` 通过。
- iOS 经实时 SDK debug stream 确认 customEvent 缺少 view.id 被丢弃；使用公开 core reportView 建立固定逻辑上下文修复，未启用自动 View，mask仍512。第七轮五类事件及安全字段通过，完整停止/专用 bundle 卸载完成；没有把非致命 producer 配置日志误报为厂商缺陷。完整过程、失败轮次和残余限制见验证记录。
- 版权人后续确认拥有全部项目原创代码版权，并授权保留 GPL、增加当前四端 RUM SDK 的链接例外。已添加根例外文件、更新许可说明及四端打包清单，GPL 正文和本地构建门槛不变；供应商自身许可与再分发条件仍需发布前核实，未发布。

## development 同步与构建补齐

用户要求从最新 development 创建新分支、迁入当前修改并补齐 Windows/iOS 本地构建与许可包检查。新分支 `feature/rum-local-validation` 从 `47642f5` 创建，位于独立 native worktree；旧主目录与分支、其他未提交改动保持原样，不把旧分支的历史实现整体合入。

- [x] 迁移本任务四端统计与许可增量，保留 development 新版编辑、六语资源、保存和批量终态语义。平台 owner 只写对应客户端目录，主代理维护 Shared、iOS core 构建/许可及根文档。
- [x] Windows 在 VM 私有源码/构建/结果目录执行真实 WPF 构建，验证默认无 SDK、本地 SDK 编译及 Release flag 拒绝；最终包内 GPL/例外/许可说明逐字一致。未覆盖共享 workspace、启动 SDK 或发布。
- [x] iOS 按当前源码重新构建设备与两种模拟器架构 XCFramework，并构建默认及 local Debug Simulator/device 应用，另通过默认 Release device 构建；framework 和四个实际 app 包许可证通过。显式 local SDK 仅编译，未启动或发送事件。
- [x] 跑迁移相关定向回归，独立复核冲突语义和包检查，记录实际 source/configuration/宿主与未覆盖项，清理本次临时产物。未提交、推送、发布或更改云配置。

结果与边界见 [development 同步验证记录](../../verification-rum-development-sync-2026-10-16.md)。本阶段补齐编译/包检查，不把此前旧源码的大陆回读当作本轮新版 app 的运行验收。
