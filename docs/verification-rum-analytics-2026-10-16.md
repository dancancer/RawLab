# RUM 使用统计接入记录

## 结论

四端已接入显式本地 SDK 构建，均由真实 SDK 发送五类合成事件并经 SLS API 回读各一条。macOS、Windows、iOS 日志明确返回中国、电信；Android 当前网络无 VPN/代理且五类事件入库，但云端地区字段为空，不能当作独立的云端地区证明。验证仅覆盖本次宿主、线路和时点，不外推其他运营商；iOS 使用 Simulator，未验证物理 iPhone。

默认构建仍使用不可用适配器、不链接厂商 SDK，统计默认关闭；已有同意也不能绕过不可用适配器。本地构建不等于已上线。账号所有者确认已设置 `1 OCU/天`，本轮没有独立验证其作用域，也没有修改限额或 RAM 权限。阿里云配置和日志均通过 API，不再操作浏览器。

源码契约见 [设计](superpowers/specs/2026-10-16-rum-analytics.md)，执行范围见 [计划](superpowers/plans/2026-10-16-rum-analytics.md)。没有提交、推送、发布或改变项目许可证。

| 平台 | 真实 SDK / 宿主 | 最终标记 | API 回读 |
| --- | --- | --- | --- |
| macOS | PC 0.4.4 / 本机 arm64 | `658872BB-FE0F-4B5B-A5A7-FC6BA9EB5165` | 5/5；10:07:32 CST；中国/电信 |
| Windows | PC 0.4.4 / Windows 11 x64 VM | `ea467963-44e0-4cf0-be98-f10e76b46a9b` | 5/5；09:52:41 CST；中国/电信 |
| Android | 2.3.2 / USB 连接的 TB320FC 实机 | `428B5992-96C6-48EF-BE4B-E30F88DC7D61` | 5/5；10:04:48 CST；地区字段为空 |
| iOS | 2.4.2 / arm64 iPhone Simulator | `C36E873E-821C-487F-B04F-D9E10D84FC30` | 5/5；10:32:24 CST；中国/电信 |

以上均为 2026-10-16，`group=usage`、`schema_version=1`、对应平台/AppID、`env=local`、业务字段白名单及有界计数均通过。启动是进程启动次数，不把每次生成的测试设备标识当作真实活跃用户或留存统计。

## 第一阶段：统计基础（历史记录）

本节保留真实 SDK 接入前的验证范围；其中“尚未执行”“无 SDK”仅描述当时阶段。当前本地 SDK 结果见后文，不将历史未执行项改写为通过。

### 已落实

- Swift（macOS/iOS 共用）、Kotlin、C# 的固定五事件，固定 `usage` 分组、`schema_version=1`、平台字段，以及 `0...100000` 的有界计数。
- 默认关闭，不存储关闭期间的事件；明确同意后才允许启动。进程内开启/关闭/再次开启不重复计算 `app_started`。撤回即阻止新事件；持久化失败也不在当前进程恢复采集，界面提示重启前检查存储权限。
- macOS/Android/Windows 复用关于窗口，iOS 增加原生隐私设置 sheet。明确披露阿里云、中国大陆存储和 SDK 设备/系统/IP/地区/会话数据，不使用“完全匿名”等承诺。
- 成功得到预览才记录导入；外观选项点击且变化才计数，导入后的自动选中/恢复编辑不计数；文件/Photos 实际发布成功才记录导出；批量一次运行终态记录一次，成功、失败按本轮实际尝试计算，重试不累计过去成功项。
- 不在事件接口接收照片、预览、路径、文件名、EXIF、外观名称、AI 内容/地址/Key 或错误文本。未修改 C++ 渲染核心。

### 验证

| 范围 | 实际结果 |
| --- | --- |
| `bash Shared/tests/usage-analytics.sh` | 通过：默认关闭、一次启动、撤回、不可用服务、启动/存储失败、固定字段、持久化损坏 |
| `bash experiments/rum-pilot/test.sh` | 通过：小样预算门槛、代理拒绝、HTTPS/地域校验、固定载荷；本轮未重发 |
| macOS 完整 `RawLabMac/build.sh`，目标 macOS 15，临时 core/app 目录 | 编译、依赖打包和签名检查通过；没有 RUM 动态库 |
| `bash RawLabMac/tests/usage-model.sh <共享 ARW>` | 通过：用户选择与恢复隔离、失败导入不计数、真实 RAW 导入一次、编辑不重复、批量发布部分成功、取消和重试增量 |
| `bash RawLabMac/tests/usage-privacy-presentation.sh` | 通过：原生设置视图布局 `440x534`，默认不可用；仅测试 fixture，不代表真实 SDK 运行 |
| iOS `xcodebuild test`，iPhone 18 Pro Simulator / iOS 27 | 2 个测试通过：`testUsagePrivacyDefaultsOff`、`testEmptyEditorAndPanelVisibility`；含横竖屏隐私截图与开关状态 |
| Android `:app:testDebugUnitTest :app:lintDebug :app:assembleDebug :app:compileDebugAndroidTestKotlin` | 通过；既有 SDK XML/ShowChart 警告，不声称零警告 |
| Windows portable `tests/usage` | 通过：默认关闭、撤回、失败存储、固定字段、启动失败不重试与一次启动 |
| Windows WPF 应用及 `tests/RawLabWindows.Tests.csproj` 交叉编译 | 通过，0 warning / 0 error；没有在 Windows 执行 WPF 测试程序 |

测试先观察到缺失实现/行为失败，再完成实现；后续补充了 opt-out 写入失败、Windows 启动后同意、批量取消/重试等回归。

Android instrumentation 没有完成执行：连接设备已有 `versionCode=10`，当前分支是 `8`，安装被拒绝为 `INSTALL_FAILED_VERSION_DOWNGRADE`，实际 `0 tests`。没有卸载或降级已有应用。本轮没有做移动端实网发送、其他运营商验证或 Windows 运行时上报。

一次性编译、日志、截图和结果包放 `.cache/tmp/usage-analytics/` / 系统临时目录，验证后清理。可复用下载留在忽略的 `.cache/shared/`；不清除用户原照片、既有缓存或其他任务产物。

### 当时的 SDK 分发与采集门槛

项目原文 [licensing.md](licensing.md) 是 `GPL-3.0-only`。以下是版本产物证据和工程门槛，不是法律结论，也不意味着 MIT 与 GPL 本身不兼容。

| SDK | 已核实的发布信息 | 尚缺证据 |
| --- | --- | --- |
| macOS / Windows 0.4.4 | [官方 PC 下载/接入](https://help.aliyun.com/zh/cms/cloudmonitor-2-0/access-pc-platform-application)；官方 ZIP 为头文件、示例和动态库，没有 LICENSE/NOTICE 或核心实现源码 | 这些具体二进制的再分发许可、对应源码与 GPL 组合分发条件 |
| iOS 2.4.2 | [官方 podspec](https://github.com/aliyun/alibabacloud-rum-ios-buildpack/blob/2.4.2/AlibabaCloudRUM.podspec) 声明 MIT；公开 Objective-C 包装代码，核心为 vendored XCFramework | 核心二进制对应源码/许可范围，以及最终组合包如何满足现有项目的源码交付义务 |
| Android 2.3.2 | [官方 POM](https://maven.aliyun.com/repository/public/com/aliyun/rum/alibabacloud-android-rum-sdk/2.3.2/alibabacloud-android-rum-sdk-2.3.2.pom) 声明 MIT；[官方 buildpack](https://github.com/aliyun/alibabacloud-rum-android-buildpack/tree/2.3.2) 有 facade 与预构建核心 AAR | 同上；不能用 facade 的 sources.jar 充当完整核心源码 |

此外，Android 采集项只能通过云端配置关闭，不支持本地 `collectors` 参数；仅 `setSelfMonitor(false)` 不会关闭业务网络/交互采集。未确认每端远程配置、停止/清理及重启语义之前，不初始化 SDK。参考 [Android 配置](https://help.aliyun.com/zh/cms/cloudmonitor-2-0/monitor-android-applications-in-cms2-0)、[iOS 配置](https://help.aliyun.com/zh/cms/cloudmonitor-2-0/ios-sdk-configuration-reference)、[隐私说明](https://help.aliyun.com/zh/arms/user-experience-monitoring/support/rum-sdk-privacy-compliance-instructions)。

移动 SDK 2.x 使用 `ServiceId + Workspace + Endpoint`，不能直接把 PC 的 AppID/ConfigAddress 当作移动配置。官方 `CreateService` 只公开 `serviceType=RUM` 和通用字符串 `attributes`，没有完整的平台创建 schema；本轮没有猜测参数创建另外三端应用。

### 给阿里云的待确认问题

1. 请提供 PC 0.4.4 SDK 与其附带 libcurl 的准确许可证、再分发文本和对应实现源码位置；能否在 GPL-3.0-only 桌面应用中分发？
2. Android 2.3.2 / iOS 2.4.2 的 MIT 声明是否涵盖预编译核心及 native 库？完整对应源码如何获取，或是否提供适用于 GPL 应用的明确授权方案？
3. `stop()` / `stopSDK()` / PC `close()` 是否清除待发缓存、是否可能继续传输、重新同意后是否支持同进程重启？如何禁用非必要自动采集，并确保在远程配置失败时也不默认采集网络/交互？
4. CMS2.0 上海 RUM 创建 Windows/Android/iOS 应用的公开 API 参数/平台枚举及 `1 OCU/天` 限额的产品和地域作用域是什么？

未代用户提交工单或接受新条款。拿到可验证答复后，下一步是实现真实传输适配器、纳入必要许可/源码、按平台配置应用，再在明确同意下逐端做有界实网上报与云端回读。当前不通过更改项目许可证、动态加载技巧或复用错误平台应用来绕过门槛。

本轮独立评审未发现 P1。已补齐四端明确的“数据存储在中国大陆”和网络/设备标识披露，统一自动选中不计作点击的口径；Swift 固定分组也有属性与测试断言。Swift/Kotlin 目前由主线程/主 dispatcher 调用，真实适配器接入前还需正式线程约束/并发撤回测试及非阻塞 SDK 启停验证。
复核另发现 Android 文件缺失的自定义外观会被 ViewModel 拒绝、但 UI 仍可能记录选择；现已禁用不可用项，并增加 `UsageFilmSelectionTest`。该 instrumentation 用例仅完成编译，和其余 Android UI 用例一样尚未在设备执行，不把它写为已通过的运行测试。

## 本地 SDK 阶段（四端回读完成）

用户随后明确授权继续四端真实 SDK 的本地接入和大陆验证，许可证留作发布前事项。本节更新此前“尚未启用”的阶段状态；不发布、不提交、不更改限额或 RAM 权限。用户再次要求阿里云操作全部使用 API，不再使用浏览器。

### 云应用与 API

通过 CMS `ListServices` / `CreateService` / `GetService` 创建或复用以下隔离应用，均回读 `Running`。首次创建 Windows 后本地工具因遗漏 `GetServiceRequest` 参数而失败，随后先重新列举确认创建结果，再复用已有应用，没有重复创建。

| 平台 | 应用 | ServiceId | PC AppID / 移动 legacy PID | 回读 siteType |
| --- | --- | --- | --- | --- |
| macOS | rawlab-rum-pilot-macos | chrtja4hrt@5e37cdf11aa7bbd148078 | chrtja4hrt@50261ae2de76a14 | macOS |
| Windows | rawlab-rum-local-windows | chrtja4hrt@fc0e2162eb4fa5124f28b | chrtja4hrt@353d8439b5164b1 | Windows |
| iOS | rawlab-rum-local-ios | chrtja4hrt@fbde0daa498a0e32c909f | chrtja4hrt@36e8041402b0036 | ios |
| Android | rawlab-rum-local-android | chrtja4hrt@fd771ea48015c6f41b4ba | chrtja4hrt@cbf30393cecba6c | android |

创建使用现有应用的 `attributes={language,siteType}` 结构，移动类型名称参考官方 `CreateRumApp`，Android 附带 `packageName=com.rawlab.android.rumlocal`；CMS 通用 API 本身未枚举这些值，因此成功后的属性回读与后续实际 SDK 日志是核验依据，不宣称已取得完整平台 schema。

`GetServiceObservability` 回读同一上海 workspace 的 publicDomain 为 `proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com`。移动 SDK 使用该 HTTPS base endpoint，并使用独立 ServiceId；PC 使用 `/rum/web/v2` 与对应 PID。未打印或传播响应中的 authToken、AccessKey 或设备/IP 信息。

### macOS 当前证据

- 2026-10-16 09:39:13 CST，真实官方 PC 0.4.4 SDK 经应用相同 `AliyunRUMBackend` 和 `SerialUsageTransport` 提交五类合成 UsageEvent；随机标记 `AE946F89-379D-45A3-9C80-1EA648AC2537`。
- SLS HTTPS API 回读五类事件各一条，group=usage、schema_version=1、platform=macos，kind=built_in，batch value=2/succeeded=2/failed=1/outcome=partial，app.id 为上表 macOS PID；全部来源为中国、电信。仅证明该 SDK/宿主/线路/时点，不外推其他端或运营商。
- `bash Shared/tests/usage-analytics.sh`、`bash Shared/tests/usage-transport.sh`、`bash RawLabMac/tests/rum-local.sh` 通过。串行传输测试先失败再实现，覆盖异步启动、立即撤回丢弃排队事件、重新开启、真实就绪才记录一次启动、启动异常清理。
- 带 SDK 本地完整 App 构建及依赖/签名检查通过；使用独立 bundle ID，产物只允许在 `.cache/tmp/`。`CONFIGURATION=Release RAWLAB_RUM_LOCAL=1` 按预期拒绝。普通默认完整构建随后通过，修复了 macOS Bash 3 对空数组和 `set -u` 的兼容问题。
- `RAWLAB_BUILD_DIR=... bash RawLabMac/tests/usage-model.sh` 通过；隐私窗口布局测试通过。第一次模型测试未传已有临时 native build 路径，因缺少默认静态库失败，补正确路径后通过，未把前次失败冒充运行成功。

真实 SDK 仅由显式本地开关编译；普通构建无 SDK。退出/异常情况下仍需区分正常 close 清理与进程被强制杀死；独立探针使用父脚本拥有的临时目录兜底清理。移动端/Windows 运行及云回读结果待续。

### PC 最终回读与移动阶段诊断

- macOS 改为 `ENV_LOCAL` 后以标记 `106F4385-A982-4519-96FA-210E46934FC3` 再验证，2026-10-16 09:51:45 CST 收到五类事件各一条，env=local、中国/电信、字段白名单和批量计数通过。退出增加异步 `terminateLater` 协调，等待后台 close 完成，10 秒异常兜底；独立评审确认没有提前释放 options。默认完整构建及 local 完整构建均通过。
- Windows 标记 `ea467963-44e0-4cf0-be98-f10e76b46a9b`，2026-10-16 09:52:41 CST 五类事件各一条入上海库，env=local、中国/电信，batch=completed/value=1/succeeded=1/failed=0。VM 中实际加载官方 x64 Release DLL（SHA256 `33cec949309f8025be35ff19d7ae7f7bfc0f59a9ff0bef3e05c40460f0bf6e8d`）。验证器确认进程退出成功且 SDK 私有临时目录为空，随后删除整个本次隔离目录，未接触共享构建 workspace。
- Windows 验证器曾因本机域用户名映射失败、脚本执行策略、中文 netsh 输出和 PowerShell 空 ExitCode 停住。未扩大任何持久权限或更改系统代理；改用当前账号 SID 限制本次目录 ACL、仅当前 PowerShell 进程的脚本运行参数、WinHTTP 结构化只读 API、保留 Process Handle 后等待退出。上述准备失败没有当作 SDK 成功；首个真实 SDK 发送已入库但包装脚本误报，第二个标记才用于完整退出/清理验证。
- Android 独立包 `com.rawlab.android.rumlocal` 和测试包安装成功，不覆盖设备原有 `com.rawlab.android.sonymemory`。显式 instrumentation 单测试运行 `OK (1 test)`，标记 `1A41C8B2-0FC7-4145-A8A9-9A85C41E81A2` 于 09:57:20 CST 的五类事件各一条入库，env=local、AppID/字段/计数正确。移动日志的 geo.country 与 isp.name 均为空，不能写成云端已证明中国/电信。设备 global http_proxy=null，默认网关与 Mac 相同；正在补 app UID 的 activeNetwork/VPN 检查，并收尾专用缓存清理与停止后需重启的 UI 状态。
- iOS 第一次标记 `C9B34C0A-698E-4D06-BD91-0476DA4872F4` 入库 0 条，日志证明 SDK 要求主线程 start，而此前后台调用被拒绝。已增加仅将配置/start 切回主线程的回归修复，等待和发送仍在后台。第二次标记 `D5420A4B-9C56-445B-B9CF-BAE14FE0CF87` 仍为 0，正在依据第二次 SDK 日志继续诊断，不把脚本退出 0 或构建成功写成已上报。

移动 SDK 不假定支持同进程 stop/start；本地停止后应明确提示重启。iOS 普通 RUM cache 无公开清理 API，验证脚本只卸载本次专用 bundle 清理整个测试 sandbox，不能据此宣称正式产品撤回清理已解决。`readback.mjs` 将 ingestionPassed 和 mainlandGeoVerified 分开报告，地理字段为空不等于没有入库，也不伪造地理字段使检查变绿。

### 最新回归与安全收尾

- Android 最终探针标记 `428B5992-96C6-48EF-BE4B-E30F88DC7D61`，2026-10-16 10:04:48 CST 五类事件各一条。设备实际执行 `OK (1 test)`，包含当前 app 的 activeNetwork 非 VPN、LinkProperties 无 HTTP proxy、配置确认、停止/清理和预期 `RESTART_REQUIRED` 终态检查。云端 AppID、env、字段白名单和计数通过，地区/运营商仍为空。停止成功后删除专用 root 和 wrapper 创建的 pref；失败不声称已清理。验证后仅卸载本次 `.rumlocal` / `.rumlocal.test`，回读原有 `.sonymemory` 两个包仍在。
- 独立评审发现 macOS close 非零返回时会保留 native 指针但错误允许再次启动。现将后台 stop 错误显式传递并永久阻断当前 transport；也覆盖 close 尚在执行就立即重新开启的竞态，丢弃排队 restart/record，不重复 close。回归测试先实际失败，再修复通过；UI 收到异步失败时刷新不可用状态，即使此时用户已经关闭统计。
- macOS 上述 close 修复后的真实探针标记 `658872BB-FE0F-4B5B-A5A7-FC6BA9EB5165`，2026-10-16 10:07:32 CST 五类事件各一条，env=local、中国/电信；退出及专用 cache 删除断言通过。完整本地 App 重新构建、依赖和签名检查通过。随后补充的队列 retire 检查由针对性并发回归验证。
- 移动配置通过 `GetRumAppInfo` 再次只读核验：两端仅 `customevent=true`，其余 15 项 false、无版本覆盖；采样字段均为 `samplingRate=1000/samplingType=1`，本轮未改采样。关闭自动模块不等于 SDK 没有基础会话/系统元数据；SLS 中仍可见 SDK 自身 session，隐私披露不使用“完全匿名”或“只上传五个业务字段”的承诺。
- SLS 最近一小时全类型有界查询实际 47 条，未截断，按 app.id 聚合仅 macOS/Windows/Android 的 custom/view/session；iOS 无其他类型记录，已排除仅 `event_type:custom` 查询漏掉 iOS 的可能。
- iOS 第三轮标记 `4572D350-0416-4AFA-80B2-B8E20C1B3158` 仍为 0。新增公开 core 状态检查确认 `isStarted=true`、非空 active session；SDK stop 返回成功且 `isStarted=false`。包装层原本丢弃启动/停止 BOOL，不能再用包装函数返回就假定成功。捕获本次专用进程 stdout 后匹配到厂商固定错误模板 `Invalid producer config destination params` / `Invalid producer config authority params`；只记录模板，不输出路径、SDK 配置或 token。它们是否为初始空配置的预期日志仍待确认，不据此擅自给客户端传 AccessKey 或手写上传协议。

### iOS 最终根因与修复

前六轮未入库；其中第四轮 25 秒窗口未等到完整提交/停止状态，脚本按新增门槛失败，第五轮 phase 打印及进程采样确认 start/record/stop 均返回、producer 线程已创建，不能将第四轮判为死锁。验证脚本现在保留 35 秒固定窗口，并检查明确的提交/停止状态；状态通过仍不代替云回读。

主代理亲自复核 arm64 validity 分支，确认 destination/authority 错误日志后仍继续校验并返回有效，推翻了“producer 必定为空”的初步判断；未报告为厂商 bug。`setEndpoint` 内部也会提取 host，不存在双 `https://`。两个移动应用的公开配置完全一致，不能以配置开关差异解释 iOS 失败。

第六轮预先开启专用进程的实时 debug stream，得到五次固定模板 `[Processor] <onEnd>-<sampling> view.id is nil, should skip event`，没有 not-sampled、module-config-nil 或 disabled；自定义事件是在 export 前因缺少页面上下文被 SDK 丢弃，不是大陆网络拒绝。普通 `log show` 未保留这些 debug 事件，不能用“没看到日志”证明没有执行。

使用 core **公开头文件**的 `reportView` 建立固定 `RawLab Usage` 逻辑上下文，method=`manual`、随机 view ID、空 map、type=nil；停止前结束同一上下文。不使用私有类/selector，不修改 SDK，不开启自动 View 或其他采集。模块 mask 在 start 前仍严格等于 `512`（只有 customEvent）；此用法在当前官方配置页未作为手动-only模式承诺，升级 SDK 时必须重新验证，不能只凭头文件推定未来兼容。

第七轮按上表标记通过：SDK start/session 状态有效、五个 custom 各一条、stop 成功且 core 不再 started。API 全类型补查只有 5 custom + 1 session，五条 `view.name` 均为固定 `RawLab Usage`，没有自动 view 类型。地区与运营商返回中国、电信，字段白名单和批量 partial=2/1 通过。Mac 对接入域名三个 DNS 结果的实际路由均为 `en0`，未走 tunnel；没有输出地址。完整本地 iOS App 构建、公共 API typecheck、固定上下文/主线程与默认不可用回归均通过。

### 保留边界

- 未发布、部署或提交任何产物。版权人于 2026-10-16 确认拥有项目原创代码版权并授权增加 [GPLv3 第 7 节链接例外](../LICENSE-ALIYUN-RUM-EXCEPTION)，仅覆盖所列当前四端 RUM SDK；GPL 正文与默认/Release 无 SDK 的保护保持不变。SDK 自身及其他第三方的再分发条件、许可通知仍是发布前事项，不把链接例外当作供应商授权。
- iOS 没有物理机结果，也没有公开 cache-clear API；当前只证明本次专用 sandbox 随卸载清理，不承诺正式产品完整的撤回清理。移动 SDK stop 后同进程重启未放行，UI 明确要求重启。
- Windows 运行的是与 WPF 相同适配器的独立原生探针，不等于完整 WPF 编辑界面已做运行验收；四端业务挂钩与真实 SDK 传输分别验证，没有把真实照片发往云端。
- 非必要采集保持关闭不等于没有 SDK 基础会话、设备、系统、IP 等元数据；隐私披露继续保留。Android 云端地区字段为空的限制不隐藏。

## GPL 链接例外与收尾

版权人明确授权保留 GPL、增加针对阿里云 RUM 的链接例外且先不发布。根目录 `LICENSE-ALIYUN-RUM-EXCEPTION` 为 GPLv3 第 7 节额外许可，仅覆盖所列 PC 0.4.4、Android 2.3.2、iOS 2.4.2 及限定的随包运行组件；未修改 `LICENSE` 正文，未豁免 RawLab 自身、适配器或构建脚本的源码义务，也未代供应商授予再分发权利。四端许可复制规则和 Windows 源码归档清单已加入例外文件，历史发布记录不改写。

| 检查 | 结果 |
| --- | --- |
| `git diff --exit-code HEAD -- LICENSE` | 通过，GPL 原文保持不变 |
| Windows `remote_build_test.py` | 通过；先证明原归档遗漏例外文件，再修复并验证 ZIP 内内容；未重新运行 Windows 发布构建 |
| macOS 默认完整构建与 `tests/bundle.sh` | 通过；例外文件与根文件逐字一致，依赖及签名检查通过，默认产物不链接 RUM |
| Android `:app:prepareAssets` | 通过；GPL、例外和许可说明三份资源分别与根源文件 `cmp` 一致；未重新生成 APK |
| iOS framework 构建/校验脚本及 Mac 脚本 `bash -n` | 通过；本次未重建 XCFramework 或 IPA |
| 默认 iOS Debug 完整构建 | 通过；主执行文件及 debug dylib 均无 RUM 依赖，此结果属于此前接入收尾，不代表新例外已进入旧 framework 缓存 |
| `git diff --check` | 通过 |

本轮没有启动 SDK、发送新事件、修改云配置或发布。macOS/iOS 临时构建、私有 SDK 日志和一次性 API 解包目录已删除；Android `:app:clean` 通过。复用的 `.cache/shared/` SDK/API 下载缓存保留，未删除用户源码、照片或既有发布产物。
