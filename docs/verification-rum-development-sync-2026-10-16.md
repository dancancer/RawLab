# RUM development 同步与本地包检查

## 范围与源码

- 用户要求从最新 development 建新分支，迁入当前统计与许可证修改，补齐 Windows/iOS 本地构建和许可证打包检查；不发布。
- 拉取基线：`47642f57293bc7b648b883b0f5517c83c8a171b3`，分支 `feature/rum-local-validation`。构建验证时改动尚未提交；最终源码由包含本报告的功能提交标识，不能把基线 SHA 当作全部修改的提交 SHA。
- 工作区：`/Users/xupeng/.codex/worktrees/rum-local-development/rawtools`，由 native worktree 工具创建并附加。
- 旧主目录 `/Users/xupeng/mycode/rawtools` 的原分支和源码保持不动。未迁入旧分支已有的 AI 实现、用户删除的旧发布分卷、其他评审资料或路线图草稿；只迁入本任务增量。
- 使用 `git apply --3way` 移植增量，不把旧文件整体覆盖新版；保留 development 的多语言、Lens/geometry、DNG、保存和批量恢复功能。源码下载缓存复用主目录 `.cache/shared/`，配置相关编译结果隔离。
- 未读 `.env`、未调用云 API、未启动 RUM、未发送事件，未提交、推送、签名或发布。

## 迁移验证

| 检查 | 结果 |
| --- | --- |
| Shared `usage-analytics.sh` / `usage-transport.sh` | 通过；默认关闭、撤回、固定字段、串行生命周期及 close 失败 |
| Windows portable `UsageAnalytics.Tests.csproj` | 通过，使用本机已安装的隔离 dotnet 工具；不替代 Windows 原生包验证 |
| Windows `remote_build_test.py` | 通过，GPL/例外文件进入当前源码归档 |
| Android JVM 单测、Debug Kotlin 和 instrumentation Kotlin 编译 | 通过；未生成 APK、未做设备或 SDK 验证 |
| Android 增量回归 | 通过 RED/GREEN；MissingLook 后首次可用预览仅计一次导入、Master Recipe 切回 neutral 计作用户选择 |
| Mac RUM 配置、隐私面板及 Swift parse | 通过；未重新构建完整 Mac app，原模型测试缺少当前 worktree 的 Mac native 依赖 |
| iOS RUM 配置、默认不可用与线程 harness | 全部通过；只使用测试替身，不启动 SDK |
| iOS 许可检查 fixture | 通过 RED/GREEN，拒绝缺失/错版 GPL、例外和许可说明 |

Windows film 选择保留 `ClearMasterRecipe` 与本地化状态；导出事件仅在最终 `File.Move` 成功后上报，原始文件锁和 `previewResize` 退出收尾保留。iOS 单张 DNG 在文件提供方明确完成后记录导出事件，不把生成临时文件视为已另存。iOS film 选择同时考虑 active Master Recipe。

## Windows 实际构建

宿主为现有 Windows 11 VM，SSH 使用既有严格 host key 与 identity 配置。只在 `C:/RawLabValidation/rum-dev-d5ea7337` 写源码、依赖、构建和结果；不覆盖共享 workspace，仅只读复用通用 Python/ExifTool 下载缓存。

真实构建全部通过，进程退出码为 0：

| 配置/检查 | 结果 |
| --- | --- |
| `RawLabWindows/build.ps1 -SelfContained` | 完整 Release x64 WPF/native 包通过，包含当前 LibRaw、Lensfun、DNG/JXL、OpenCV 依赖；未使用 `-Test`，不读取照片 |
| Debug `RawLabRumLocal=true` / Windows SDK 0.4.4 | self-contained 本地包通过，DLL SHA-256 与固定官方版本一致 |
| Release `RawLabRumLocal=true` | 按预期失败：`RawLabRumLocal=true is restricted to non-Release builds.` |
| 实际默认包/local 包许可检查 | 两者通过，构建后又独立执行一次；GPL、链接例外和许可说明与当前源码逐字一致 |
| 许可回归 fixture | 通过；拒绝缺失/过期许可、默认包混入 SDK、local SDK 字节错误 |

工具为现有 .NET SDK `9.0.318`、MSVC `14.44.35207` 与 Visual Studio 自带 CMake；WPF 目标仍是 `net8.0-windows`。只为本次 PowerShell 进程允许执行检查脚本，未修改系统 ExecutionPolicy。原生编译存在类型转换和编译选项覆盖等 warning，不表述为零警告。

远端源码归档 SHA-256 为 `2909af3c7404dd10b87204b05a2d4ffc52aac41887018cd5c768acc5edab55c8`，与本机传输源相同。另核对远端实际解压的 `MainWindow.xaml.cs`、`RawLabWindows.csproj`、GPL、例外、许可说明与新 worktree 的哈希一致。没有使用旧工作区的编译结果。

最终产物检查时的 SHA-256：

| 文件 | SHA-256 |
| --- | --- |
| 默认 `RawLab.exe` | `678659b553c6b4c725f5426465b6e0491719abe1075c36426969fe35b65e3a14` |
| local `RawLab.exe` | `04a400daa62c54e7eaba8b1b614b944521e7e64b9988f179445d01a2f37de192` |
| local `alibabacloud_rum.dll` | `33cec949309f8025be35ff19d7ae7f7bfc0f59a9ff0bef3e05c40460f0bf6e8d` |

`dotnet publish` 在这里只生成本地目录，不上传服务或创建 Release。没有启动 WPF app 或 SDK。

可复用检查：`experiments/rum-local/windows/verify-licenses.ps1`。它核对包内 GPL、链接例外、许可说明和原生运行文件，并分别检查默认无 SDK、local SDK DLL 的精确 SHA-256。

## iOS 实际构建

使用完整 Xcode/iOS 27 SDK，最低 iOS 18.0；重新构建当前源码的 arm64 device、arm64 simulator、x86_64 simulator 依赖，不能沿用旧分支 core 二进制。

三种架构的 native 编译均退出 0；合成双切片 `sony2fuji.xcframework` 后，`verify-framework.sh` 通过 LibRaw patch marker、架构、Lensfun/资源/许可及动态依赖检查。

| 配置/检查 | 结果 |
| --- | --- |
| 默认 Debug / generic iOS Simulator / arm64 | `BUILD SUCCEEDED`，动态依赖与嵌入目录无 RUM SDK |
| 默认 Release / generic iOS device / arm64 | `BUILD SUCCEEDED`，动态依赖与嵌入目录无 RUM SDK |
| local Debug / Simulator / arm64 / SDK 2.4.2 | `BUILD SUCCEEDED`，RUM core 链接及手工嵌入检查通过 |
| local Debug / device / arm64 / SDK 2.4.2 | `BUILD SUCCEEDED`，RUM core 链接及手工嵌入检查通过 |
| Release 加 `RAWLAB_RUM_LOCAL`，不定义 `DEBUG` | 按预期退出 65：`RUM local validation cannot be built for Release` |
| XCFramework 和以上四个实际 app 许可检查 | 全部通过；GPL、链接例外和许可说明与当前源码逐字一致 |

四个 app 均设置 `CODE_SIGNING_ALLOWED=NO`。local 使用独立 bundle `com.example.RawLab.rumlocal`，显式定义 `DEBUG RAWLAB_RUM_LOCAL`，通过 `FRAMEWORK_SEARCH_PATHS` 与 `OTHER_LDFLAGS` 链接 SDK；构建后只复制 core framework，不执行签名或启动。设备 app 只是未签名的编译/包布局检查，不是可安装的 IPA。

实际 app 内的 `AlibabaCloudRUMSDK.framework` 二进制与固定 2.4.2 归档直接解包的字节一致，而非仅依赖缓存标记：

| 切片 | SHA-256 |
| --- | --- |
| Simulator core | `9ea1292e32b685d2a92f36714b817bf9771772062077714eec2a97948ebfa417` |
| Device core | `ce06a4c9fe88f4cb3efad6274110f4cb2b9dba9067f58459c3faeef786990ca9` |

只编译和读取产物，未安装/启动/重置模拟器或物理设备，未发送合成事件。

可复用检查：`experiments/rum-local/ios/verify-licenses.sh`，fixture 回归入口为 `verify-licenses-test.sh`。

## 收口与清理

- 无未解决合并文件，`git diff --check HEAD` 通过；根 `LICENSE` 正文与 development 相同。
- 原主目录本任务 tracked diff 的 SHA-256 仍为迁移前的 `2322e22425f81414276f5be9710e721467d5bb551166b756370ab987d8c0dcfa`，原分支仍为 `feat/multilingual-support`；未用新分支覆盖它。
- 本轮源码、配置和回归脚本保留在新分支工作区。一次性源码归档、重复依赖输入、构建中间目录、app/Windows 临时包和日志在验证后清理；只保留可复用、带版本/校验值的 `.cache/shared/` 下载缓存。
- 构建验证阶段没有 commit、push、PR、签名、发布或云配置写入。随后用户另行授权提交、push、创建目标为 `development` 的 PR，并在确认无阻塞后合入；该授权不包含 Release、签名、安装包发布或云配置写入。

## 合入前复验

用户授权后重新获取 `origin/development`，仍为本报告基线。再次执行 Shared 同意/生命周期测试、Windows portable 契约与配置测试、Windows 源码打包测试、iOS 配置/默认不可用/线程测试、Mac 配置/隐私面板、iOS 许可 fixture、pilot 离线配置测试，全部通过。Android 再次执行 `:app:testDebugUnitTest :app:compileDebugAndroidTestKotlin`：100 tests、0 failures/errors/skipped，instrumentation Kotlin 编译通过。

合入前发现并修复 macOS 退出回归：geometry draft 确认后，默认构建忽略 `.terminateNow` 返回值，没有回复此前 `.terminateLater` 的退出请求。新增 `UsageTerminationTests.swift` 与 `usage-termination.sh`，编译真实 delegate 文件和轻量模型/NSApplication 替身；先复现 `FAIL: confirmed draft exit replies exactly once`，再为同步完成分支显式回复。默认与 `RAWLAB_RUM_LOCAL` 两种编译均通过，覆盖确认退出、取消、保存失败、SDK 延迟/重复完成。测试使用假 SDK，不启动网络或真实退出应用。

Windows/iOS 已完成实际 native 构建的客户端源码未变化，因此未重复四套 app 构建。Mac 本次修复由上述真实 delegate 编译/行为回归覆盖，完整 Mac native 构建和照片流程仍未重验。新增脚本 `bash -n`、API 脚本 `node --check`、PBX `plutil -lint` 及 staged diff 检查通过；暂存内容没有凭据、SDK 二进制或生成产物。

仓库目前没有 `.github/workflows`；GitHub 的实际 check-runs/status 仍须在 PR 最终 head 上读取，不把本地验证称作 hosted CI。合并前还需确认最终 head/base、无冲突及评审结论，不绕过分支保护。

## 边界

- 本轮不重新证明大陆上报；此前四端回读属于旧源码时点的证据，见 [先前验证记录](verification-rum-analytics-2026-10-16.md)。构建通过不等于上报或设备运行通过。
- 本轮未验收物理 iPhone、完整 WPF 编辑界面、GPU 硬件或真实照片流程。
- GPL 正文不改，链接例外不等于 SDK 供应商的再分发授权；正式发布条件仍未放行。
- 新统计设置文案未完成所有六语翻译：Mac/iOS/Windows 部分文案仍是中文，Android 除英语、简体中文外回退英语。此次不将其列为已完成的多语言 UI 验收。
- `docs/licensing.md` 的相对链接用于源码树；二进制包内应阅读同目录的 `RawLab-GPL-3.0.txt`、`RawLab-Aliyun-RUM-Exception.txt` 和 `RawLab-Licensing.md`，本轮按实际文件内容校验，不把源码相对链接当成包内布局保证。
