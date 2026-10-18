# 多功能迭代协作规范

本规范由 [开发流程](../agent.md#迭代协作与集成) 引用，用于提前暴露依赖和重叠修改、
减少共享入口的重复改写，并验证合并后的语义。分支、PR、发布授权和保护规则遵循开发流程。

## 1. 开轮先确定依赖与合入顺序

- 在本轮验收索引中记录目标版本、功能 PR、原实现 owner、依赖图、合入顺序和验收终点。
  依赖图至少标出共享接口、构建依赖、资源和功能组合；并行工作围绕明确的接口开展。
  索引只汇总跨 PR 的状态并链接各 PR 的证据；相关工作结束后移入 `docs/archive/`。
- 从最新 `origin/development` 创建功能分支，一功能一个 worktree，继续由原实现 owner
  负责交付与修复。记录创建时的 base SHA，保留其他工作目录和未提交改动。
- 共享色彩、decoder、C ABI、构建和资源接口优先拆成小 PR 合入 `development`，
  再由各功能接入。多语言基础设施也应提前落地：功能 owner 随新增界面同步新增 keys、
  占位符和无障碍调用，最后集中收翻译与布局。本轮已有交付顺序不倒改。
- 尽早开 draft PR，写明将修改的共享文件和前置 PR。尚未实现的依赖明确标为待接入，
  不把分支上的独立通过结果写成最终联合通过。

## 2. 共享文件指定单一 owner

开轮时按下表从原功能或平台角色中指定具体 owner，并记录到本轮任务清单。
同一共享文件在同一阶段只有一个写入 owner；其他功能通过明确的接入请求交给该 owner。
需要转交时记录交接的 source SHA 和未完成项，再开始修改。

| 共享范围 | 指定角色 | 接入责任 |
| --- | --- | --- |
| 色彩、decoder、C ABI 与核心 CMake 接口 | 共享核心/decoder owner | 先确认语义、旧 ABI 布局和 enum 值，交付公共接口及受影响回归 |
| 公共依赖、Swift native link、平台 build 与许可证入口 | 构建/依赖集成 owner | 统一 SDK/JXL/TIFF/Lensfun 等依赖和 Swift 链接入口；平台 owner 提供接入需要与验证结果 |
| 六语资源结构、动态状态和无障碍资源入口 | 多语言基础设施 owner | 维护资源契约；各功能 owner 随界面改动提供新增 keys 和调用，翻译/布局统一收口 |
| iOS processor、Mac engine、Android editor、Windows window/render bridge 等共享客户端文件 | 对应平台接口 owner | 按依赖顺序接入功能，保留现有状态、缓存、保存与导出语义 |

公共依赖和 Swift link 入口由一个 owner 统一维护，避免各功能分别补同一组脚本。
是否抽取共用代码或链接助手另开实现任务，本规范不要求生产代码重构。

## 3. 前置落地后立即做阶段集成

1. 前置 PR 合入后，协调者记录新的 `development` SHA，通知受影响 owner；
   各依赖分支及时 merge 该基线，避免在旧分支上持续积累重叠改动。
2. owner 解决文本冲突后，列出实际冲突文件、保留的接口和语义风险，执行最小定向回归。
   构建链接变动检查实际 link/runtime；decoder、缓存和导出变动检查对应组合路径。
3. 在原 PR 描述中记录新 head/base、完成结果及平台限制，验收索引更新摘要和 PR 链接。
   共享目标移动且影响本次代码时，原独立 reviewer 将结论绑定新 head/base，复核受影响增量。
4. 阶段验证和复评完成后按已授权顺序合入。下一个依赖功能接新 target，
   不等所有功能结束才做一次大合并。

已完成且 source/configuration 未受影响的原实验保留其范围，不重复全量执行。
纯文档同步检查内容、链接和 diff；不为 docs-only 提交重跑 native 构建或设备实验。
每个新增结果在所属 PR 描述中记录 source SHA、配置、实际执行及限制，区分本地验证与 hosted CI。

## 4. 联合验收后冻结发布源

最终矩阵在同一 source 上检查依赖链接闭包、decoder 复用、缓存隔离、单张/批量 FINAL
导出、六语状态和包资源。机械解决冲突只能证明文本已合并；状态重置、缓存 key、
原尺寸导出和跨功能组合必须由对应语义回归验证。

按本轮实际风险选最小充分矩阵，补受影响组合，避免每个阶段反复重跑全部平台实验。
联合验收后冻结 source，按 Gitflow 创建 release 分支；冻结后只接发布阻塞修复及必要
版本、包和文档工作，新功能进入下一轮。发布修复仍需定向回归和相应 source 复评。

## 5. 隔离验证资源

- Android 使用每任务私有 ADB server 端口和明确的 device serial；记录任务拥有的
  server/emulator PID，仅清理自己启动的进程，不重启共享 ADB 或终止其他任务的设备进程。
- iOS 使用专属 simulator，记录 UDID 和构建输出目录；不重置或关闭其他任务的模拟器。
- Windows VM 中使用每任务独立源码、构建和结果目录，明确 VM/会话及拥有的进程；
  不覆盖共享输出，不终止其他任务的构建或测试。

## 本轮依据：v0.7.0，2026-10-13 快照

- #24 接入 `caf5180` 时有 6 处文本冲突；#26 接入该基线时有 7 处；
  #26 再接入包含 #24 的 `802354aa` 时有 27 处，集中在 Swift test link、CMake、
  iOS 资源/许可、Mac build/许可及 Android/Windows 测试入口。
- GitHub 文件清单中，#24/#26 重叠 62 路径、#24/#25 重叠 56、#25/#26 重叠 51；
  14 路径由至少四条功能线修改。例子包括 `lutools/CMakeLists.txt`、`RawLabMac/build.sh`、
  iOS `Sony2FujiProcessor.swift`、Android `EditorViewModel.kt`、Mac `Engine.swift`、
  Windows `MainWindow.xaml.cs` 和 `RenderEngine.cs`。文件重叠数不是实际冲突数，
  这些数据仅描述本轮快照。
- #24 的 `undefined dng_host` 是实际链接失败，需要补齐 21 个 Swift SDK 链接入口。
  #26 的 LibRaw `recycle` Stage3 warning 泄漏是语义回归，已由实际 SDK
  `WarpRectilinear` → 无 Stage3 JXL/plain 路径完成四端 RED/GREEN。
  这两例分别说明共享构建入口应统一维护，以及合并后必须验证实际状态与功能组合。

本轮进展和最终联合门禁见 [v0.7.0 验收索引](archive/integration/v0.7/acceptance-index.md)；单个 PR 的证据
在对应 PR 描述中保留各自 source 和平台范围。
