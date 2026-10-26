# 发布前修复计划

状态：R0～R6 实现及可执行的本地回归已完成，等待合入 `development`；R7 的正式配置、硬件、真实升级和远端 CI 门槛仍未关闭。基线为 `origin/development@a21cc27a`。依据为 2026-10-25 对 `development@a21cc27a`
（相对 `v0.8.2`，#105～#136）的整体审查。本计划只覆盖审查发现与用户决策，
不加入新功能；版本号、签名、上传和发布 Release 仍需各自授权。

## 用户决策（2026-10-25）

1. 审查发现的问题全部修复，包括此前判定为"本版触发不到"的更新器与 AI 问题。
2. AI 降噪随本版启用：Mac 与 Windows 发布包打包模型和运行库。
3. 桌面更新器随本版启用。
4. #129 改变旧 HSL 编辑渲染结果：不按处理版本区分，写入发布说明。
5. 收起调整栏后 HSL 目标模式继续生效。以 Mac 为准四端一致：iOS、Android
   改为不随收起退出；四端在面板收起时都要有可见的目标模式状态和退出入口。
6. 发布说明补充：不支持降级；Windows 单实例运行锁的行为。
7. 零预算签名与发布源（2026-10-26）。RawLab 是开源免费应用，本版不购买证书：
   - Mac 用固定的自签名代码签名证书，加 Sparkle EdDSA 签名；不使用 Developer ID，不做公证。
   - Windows 只靠签名发布描述（P-256）及其绑定的包 SHA-256 和大小；不要求 Authenticode。
   - 两端都以 GitHub Release 作为发布源。
   - 现有的 Developer ID、公证、Authenticode 校验保留为配置可选的严格模式。
     以后有赞助购买证书时，只改配置和签名流程，不改代码结构。
8. 2026-10-26 用户再次明确要求打包 DualDn 模型并启用 AI 降噪，确认本项目为非商业使用。
   模型分发确认前置已满足；随包保留上游 CC BY-NC 4.0、作者/来源及转换说明。

## 最新 AI 后端决定（2026-10-26）

用户要求 AI 降噪仅支持 GPU，不支持或继续验证 CPU 模式。此决定覆盖本文及旧接入计划
中的 AI Auto→CPU 回退、Intel CPU 回退、CPU 后端测试要求；普通非 AI 渲染的 CPU
路径保持原合同。Mac 使用 Core ML GPU 计算配置，Windows 使用硬件 DirectML；
GPU 不可用、模型缺失或运行失败时明确报错，不能改用 CPU 网络产生 AI 结果。
旧 ABI 的 CPU 枚举值保留但启用请求返回不支持。准备、预览、导出与批量固定相同 GPU
后端；旧 CPU AI 缓存不得当作 GPU 结果复用。Core ML 的系统调度及辅助 ISP/数据处理
须如实报告，不能把选择 GPU 配置表述为每个算子均在 GPU 执行。
模型转换分阶段运行并记录内存峰值，不再运行 CPU 后端产品验收。

## 启用前置

以下条件全部可以免费准备。私钥只放发布机本地并离线备份，不入库，不放 CI secrets。
缺任何一项，对应工作只能做到"配置接线完成、功能保持不可用"，不能宣称已启用。

| 前置 | 用途 | 依据 |
| --- | --- | --- |
| Mac 自签名代码签名证书（长期有效） | 给应用、`Sparkle.framework` 和 AI 运行库签名。身份固定，更新前后系统隐私授权不丢；Sparkle 据此核对新版签名身份 | M-7 |
| Sparkle EdDSA 密钥对 | 公钥写入 `SUPublicEDKey`，签更新包和 appcast。这是 Mac 唯一必须长期保持不变的密钥：以后换成 Developer ID 时，Sparkle 要求 EdDSA 密钥不变才允许更换签名身份 | [桌面更新计划](desktop-updates-plan.md#失败恢复与发行配置) |
| Windows P-256 发布描述签名密钥对 | 公钥写入 `UpdateTrust.json` 的 `PublicKey`，签发布描述。这是 Windows 唯一的信任来源 | `RawLabWindows/Updates/SignedUpdateSource.cs` |
| GitHub Release 发布源 | 仓库已公开，0.8.2 起的各平台包已发布在 Release 上。用固定地址 `https://github.com/dancancer/RawLab/releases/latest/download/<文件名>` | R1-3 |
| Windows 发布形态改为 Velopack 当前用户 Setup | 只有 `RawLab.Desktop`、非 portable、`stable` 渠道的安装形态可自动更新；ZIP 仍只能手动更新 | `RawLabWindows/Updates/VelopackUpdateAdapter.cs:47-52` |
| DualDn 模型分发许可确认 | 已由用户于 2026-10-26 确认本次非商业使用和模型打包；模型保留 CC BY-NC 4.0，随包带署名、来源和转换说明 | [接入文档](../../architecture/dualdn-inline-denoise.md#交付边界) |
| 目标版本号 | 发布说明、Info.plist/csproj 版本、feed 条目 | 根 `AGENTS.md` 版本发布 |

零预算方案的已知代价，写入发布说明，验收时实测：
- 首次安装仍要手动放行：Mac 在"隐私与安全性"里点"仍要打开"，Windows 在 SmartScreen 里点"仍要运行"。
- 每端只有一道签名防线，没有苹果公证扫描和证书吊销。私钥泄露即可推送恶意更新，因此密钥保管是发布流程的一部分。

## 基线、分支与合入顺序

- 各任务从最新 `origin/development` 创建分支（起草时为 `a21cc27a`），一任务一个
  worktree，放在 `../rawtools-worktrees/<short-name>`。开工时记录 base SHA。
- 合入顺序：R2 核心 → R0/R1 共享资源、构建与许可 → R4 Mac → R5 iOS、R3 Android、
  R6 Windows → R7 联合验收 → `release/<version>`。共享语义（更新器 B/C/D、
  HSL 目标收起状态）先在 Mac 定稿，其他端照此移植。
- 前置合入后，依赖分支立即合入新基线并重验受影响组合，不留到最后大合并。

| 任务 | 分支 | owner 与独占路径 |
| --- | --- | --- |
| R0 协调、文档与发布说明 | `feature/release-fixes-coordination` | 协调者：本文、总账、`docs/`、`CHANGELOG.md`、`Shared/strings/` 与生成输出 |
| R1 构建、打包、许可与 CI | 同上，或单独 `feature/release-packaging` | 构建/依赖 owner：`RawLabMac/build.sh`、`Info.plist`、`RawLabWindows/build.ps1`、csproj、`UpdateTrust.json`、`ThirdPartyNotices`、`.github/`、`scripts/ci/` |
| R2 核心 | `feature/release-fixes-core` | 核心 owner：`lutools/src/ai/`、`lutools/src/ffi/`、核心测试 |
| R3 Android | `feature/release-fixes-android` | Android owner：`RawLabAndroid/` |
| R4 Mac | `feature/release-fixes-mac` | Mac owner：`RawLabMac/Sources/`、`RawLabMac/tests/`、`Shared/*.swift` 中的 Mac 消费部分 |
| R5 iOS | `feature/release-fixes-ios` | iOS owner：`RawLab/` |
| R6 Windows | `feature/release-fixes-windows` | Windows owner：`RawLabWindows/`（`build.ps1`、csproj、`UpdateTrust.json` 归 R1） |

平台任务需要的新文案（HSL 目标收起状态、更新锁定原因、AI 连续未就绪的失败提示等）
由平台 owner 向 R0 提交 key 与占位符需求，不在平台分支手改共享资源。

## 共享约束

- 文中行号基于 `a21cc27a`，只是线索。开工前对照最新代码重新确认触发条件；
  不成立的项写明证据后关闭，不为凑数修改。
- 每项先补能失败的回归测试，再做最小修复。不改变 C ABI 布局、持久化格式、
  处理版本语义或渲染公式；确需改动时先交协调者确认，并检查四端调用方。
- 普通显影的 GPU Auto 保留 CPU 回退，Force 不伪装成功；AI 按最新决定仅支持 GPU，不能回退 CPU；原始 RAW 只读。
- 涉及界面的改动先在本地跑受影响的 UI 测试，通过后再提交；PR 记录源码版本、命令、
  结果和未覆盖项。CI 编译 UI 测试目标不等于 UI 测试通过。
- 私钥、证书、公证凭据和本机路径不入库，只提交公钥与公开配置。
- 一次性产物放系统临时目录或主工作区 `.cache/tmp/<task>/`，用后清理；
  模型包与运行库按版本和校验值放 `.cache/shared/`，不在各 worktree 重复下载。
- 标"核实项"的条目：先用测试、复现或测量确认；成立则修复并补回归，
  不成立则在 PR 中记录证据后关闭。

## R0 协调、文档与发布说明

**R0-1 发布说明。** 在 `development` 的 `CHANGELOG.md` 增加未发布条目；正式版本号与
`docs/releases/v<版本>.md` 在 release 分支完成。内容：

- HSL 渲染变化（#129）：HSL 生效且对比度/饱和度把像素推出 0～1 范围时，越界部分
  不再被压回，高饱和颜色更准确。旧编辑在新版本中可能明显不同（审查样例 8 位输出
  最大差 136），不提供恢复旧行为的选项。
- 不支持降级：v0.8.2 的 Android 无法读取新版编辑库；Mac、iOS、Windows 回退后
  再保存任意照片，会丢掉本版新增的调整字段与处理版本标记。
- Windows 单实例：程序运行时再用"打开方式"或拖放打开文件，会提示退出其他实例
  后结束。文案以实现为准，由 R6 提供实际行为。
- AI 降噪：仅 Mac、Windows；系统和硬件要求、首次计算耗时、安装包体积增长；
  模型为 CC BY-NC 4.0 非商业许可，不随 RawLab 改为 GPL。
- 自动更新：
  - 本版是首个带自动更新的版本，从 0.8.2 升级需手动安装一次。
  - Windows 只有 Setup 安装版支持自动更新，ZIP 版仍需手动下载。
  - Mac 需放在当前用户可写的位置（如"应用程序"）才能自动安装。
  - 更新包从 GitHub Release 下载。
- 安装与签名说明：
  - RawLab 使用自签名证书，没有经过苹果公证，也没有 Windows 发行商签名。
  - 首次安装需手动放行：Mac 在"系统设置 → 隐私与安全性"里点"仍要打开"，
    Windows 在 SmartScreen 里点"更多信息 → 仍要运行"。
  - 从 0.8.2 换到本版时签名身份变了，系统可能要求重新确认一次文件夹访问等权限；
    之后的自动更新不应再出现。是否成立以 R7 实测为准。

**R0-2 文档纠正。**

- `docs/design/editing-iteration/selective-payload.md` 编码表补 `color.grading.*`、
  `light.curve`、`effects.clarity`、`effects.dehaze`，与四端实现和
  `Shared/fixtures/adjustment-transfer-v1.json` 对齐。
- `docs/design/editing-iteration/field-catalog.md:165`、`:227` 的"四端数据/UI 待接入"
  改为实际状态。
- `docs/design/editor-workspace/requirements.md:49` 写"效果→暗角"，四端代码中
  清晰度/去朦胧排在暗角前，默认工具为清晰度。按现状改文档；如要保留暗角为默认，
  改为四端代码任务并在开工前告知协调者。
- `docs/architecture/dualdn-inline-denoise.md` 交付边界、`desktop-updates-plan.md`
  的 U6 与"发行条件未齐备"表述，按启用决策与前置确认结果更新。
- 零预算签名决策写进设计：
  - `technical-design.md:265` 及第 10 节：Developer ID 与公证改为可选的严格模式；
    默认模式为自签名证书加 EdDSA（Mac）、签名发布描述（Windows）。
  - `requirements.md:169`：签名前置的表述同步修改。
  - `desktop-updates-plan.md`：信任边界改为 GitHub Release 发布源。
  - 记录切换到付费方案的步骤：
    - Mac：EdDSA 密钥保持不变，新版本改用 Developer ID 签名并打开严格模式配置。
    - Windows：新版本填入 `PublisherKeySha256` 并做 Authenticode 签名。

**R0-3 总账。** 更新 [总账](README.md) 中 #134/#136 等已合入项的状态，登记本计划和
各修复 PR；本轮发布完成后将总账与批次计划移入 `docs/archive/`。

**R0-4 共享六语。** 接收 R3～R6 的新 key，统一生成并通过
`python3 scripts/localization/generate.py --check`。

## R1 构建、打包、许可与 CI

**R1-1 AI 随发布包打包。**

- Mac：发布构建使用 `RAWLAB_DUALDN=1`，ONNX Runtime 1.23.2，模型目录为含
  `raw.mlmodelc`、`rgb.mlmodelc` 的原生包（见 `lutools/tools/dualdn/README.md`）。
- Windows：`build.ps1 -DualDnModel`，ONNX Runtime DirectML 1.23.0，沿用现有运行库校验。
- 给两端发布构建加显式的发布开关，缺 AI 输入时直接失败，避免误出不含 AI 的发布包；
  日常开发构建保持现状。
- 模型包与运行库按版本和 SHA-256 存放在 `.cache/shared/`，发布文档记录校验值；
  构建时用 `dualdn_probe --validate` 校验包内资源。

**R1-2 签名与安装形态（零预算）。**

- Mac：
  - `build.sh` 发布模式改用固定的自签名证书签名（现在是 `codesign --sign -` 的 ad-hoc
    签名，见 `RawLabMac/build.sh:191`、`:207`）。由内向外逐个签：AI 运行库、
    `Sparkle.framework` 内的 Autoupdate、Updater.app 等，最后签主程序；不用 `--deep` 代替。
  - 不开启带库校验的 hardened runtime：自签名证书没有 Team ID，开启库校验会导致
    Sparkle 和 ONNX Runtime 无法加载。
  - 发布 ZIP 用 `ditto -c -k --keepParent` 等保留符号链接的方式打包。
  - 打包后校验 `codesign --verify --strict`，并确认签名要求固定到该证书；不跑 `spctl`。
  - 开发构建继续使用 ad-hoc 签名。
- Windows：
  - 用 `vpk` 打包 `RawLab.Desktop`、`stable` 渠道的当前用户 Setup，保留 ZIP 供手动下载。
  - 不做 Authenticode 签名。

**R1-3 发布源与更新配置（GitHub Release）。**

- Mac 每个架构一个 appcast：`appcast-arm64.xml`、`appcast-x86_64.xml`。
  - 两个架构的构建各自写入 `SUFeedURL=https://github.com/dancancer/RawLab/releases/latest/download/appcast-<架构>.xml`。
  - Info.plist 同时写入 `SUPublicEDKey`、`RawLabUpdateArchitecture`，以及 M-7 定义的
    自签名证书指纹；保留 `SUVerifyUpdateBeforeExtraction`、`SURequireSignedFeed`、
    `SUSignedFeedFailureExpirationInterval=0`。
  - enclosure 指向同一 Release 的下载地址，带 `rawlab:architecture`、`rawlab:sha256`。
  - 现有校验只要求下载地址与发布源同为 github.com（`SparkleUpdateAdapter.swift:101`），
    跳转到 GitHub 下载服务器由 Sparkle 跟随。R7 实测。
- Windows `RawLabWindows/Updates/UpdateTrust.json`：
  - `FeedUrl=https://github.com/dancancer/RawLab/releases/latest/download/<发布描述文件名>`；
  - 填入 `PublicKey`，`PublisherKeySha256` 留空，表示只靠签名发布描述的模式（见 W-8）。
- 发布脚本：
  - 生成并签名两端更新文件：Sparkle 的 `sign_update`/`generate_appcast` 签包和 appcast；
    RawLab 自己的工具签发布描述。私钥只从发布机本地读取。
  - 发布顺序：先建草稿 Release 并上传全部附件（各平台包、Setup、nupkg、appcast、
    发布描述），全部上传完再发布。草稿不会成为 `latest`，用户不会看到有更新却下载不到包。
  - 正式发布前，用两端公钥离线校验全部签名。
- 确认开发构建（ad-hoc、未打包 Setup）仍显示"不可用"，而不是报错。

**R1-4 许可证。**

- Windows：`ThirdPartyNotices.md` 和 `Licenses/` 补 Velopack（MIT）。还原后用
  `obj/project.assets.json` 核对间接依赖，有则一并补齐。
- Mac：`Resources/ThirdPartyNotices.md` 表格补 Sparkle 2.10.0（许可文件已随包复制）。
- DualDn、Restormer、ONNX Runtime、DirectML 的声明从"可选实验"改为正式随包组件；
  `docs/reference/licensing.md` 说明模型保留上游 CC BY-NC 4.0，不随 RawLab 改为 GPL。

**R1-5 CI。**

- 着色器离线编译：新增 HLSL 只在有硬件适配器时才调用 `D3DCompile`
  （`lutools/src/gpu/d3d11_photo.cpp:75-86`），GLSL 也从未离线编译。由 R2 提供测试，
  R1 接入 CI：Windows 测试直接调用 `D3DCompile` 编译着色器源码（编译不需要 GPU）；
  GLES 着色器用 `glslangValidator` 检查。
- AI 构建：full 检查组在 Mac 和 Windows runner 上以 AI 开启的配置构建，并运行
  DualDn 相关测试；共享模型包放在 runner 的共享缓存目录，两台 Mac 布局保持一致。

## R2 核心

**C-1 Windows 每次渲染都全量哈希模型和原片。**

- 位置：`lutools/src/ai/dualdn_cache.cpp:41-56`；`lutools/src/ai/ai_session.cpp:30-40`、
  `:58-61`、`:74-81`；`lutools/src/ffi/sony2fuji_c.cpp:870`、`:878`、`:944`。
- 现象：Windows 上 `sourceIdentity` 每次对整个文件做 SHA-256；`ensurePackage` 每次
  先算 `packageStamp()`，对 7 个模型文件逐个算身份。缓存命中时每次渲染也要哈希
  约 333 MB 模型加两遍 RAW，估算每次多 1.5～3.5 秒。
- 要求：
  - 模型内容只在 `loadModelPackage` 校验一次，之后的身份只看元数据。
  - RAW 内容摘要按文件索引、大小、时间在进程内复用。
  - `loadRawImage` 把同一次算出的身份传给 `renderKey`。
  - 保留"同尺寸、保留时间的原地覆盖不复用旧结果"这一保证。
- 回归：计数式测试证明缓存命中路径不再读取模型和原片内容；原地覆盖仍会失效。

**C-2 关闭 AI 后渲染会话仍占着 AI 结果。**

- 位置：`lutools/src/ai/ai_session.cpp:19-28`、`ai_session.h:44`、
  `sony2fuji_c.cpp:1331-1343`。
- 现象：`configure()` 只在目录或后端变化时清空 `loaded_`；客户端关 AI 只把 `enabled`
  置 0，61MP 照片约 1 GB 结果一直驻留。
- 要求：`enabled` 变为 0 时清空 `loaded_` 和 `loadedKey_`。

**C-3 Windows 运行时身份不刷新，导致准备与渲染的键对不上。**

- 位置：`ai_session.cpp:58-66`、`directml_device.cpp:48-67`。
- 现象：缓存键里的 `runtimeDigest_` 含 DirectML 适配器和驱动版本；渲染会话只在模型
  变化时重算，准备任务每次新建会话重算。驱动更新、适配器变化或首次查询偶发失败后，
  两边键不一致。
- 要求：渲染端查找已完成结果时不依赖可变的适配器/驱动身份，或在未命中时重算一次
  再查。客户端次数上限见 W-4。

**C-4 着色器离线编译测试。** 配合 R1-5，覆盖 `d3d11_photo_shader.h`、
`gles_photo_shader.h` 及共享的 `photo_tone_shader.h`、`photo_color_grading_shader.h`、
`photo_tone_curve_shader.h`。

**C-5 核实项。**

- macOS 原片身份含 `st_ctime`：权限、扩展属性、标签变化会让 AI 缓存全部失效。
  确认后改为不受元数据变化影响、但能识别内容覆盖的身份。
- Windows 缓存原子替换：渲染会话正以 `ifstream` 读同一键时，`MoveFileExW` 可能失败。
  需验证共享模式，必要时用允许删除共享的方式打开或加重试。
- Legacy 小波改用 `transformOpponent` 替代 v0.8.2 的 `cv::transform`，需与 v0.8.2 逐像素
  对比。处理版本 1 的输出必须与旧版一致，有差异就恢复旧运算顺序。

## R3 Android

**A-1【阻塞】粘贴、预设、同步写出负零，设备上回执和撤销报冲突。**

- 位置：`adjustments/AdjustmentTransferValues.kt:33`（`highlights = -value.toFloat()`）；
  `AdjustmentTransfer.kt:85`、`:111`（`assignEffective`）；
  `AdjustmentTransferSession.kt:56`、`:148`；`editor/EditorAdjustmentHistory.kt:36`；
  `settings/EditPersistence.kt:72-80`；`settings/StructuredSettingsCodec.kt:14`。
- 触发：来源照片未用大师配方，用默认范围（除几何外全部字段）粘贴、保存预设或同步到
  高光为 0 的照片。
- 原因：`assignEffective` 反算出逻辑值 0 后，取负得到 -0f。Kotlin 数据类按
  `Float.compare` 比较，-0f 与 0f 不等。设备 org.json 把 Float -0f 写成 `0`，读回为 +0f；
  JVM 测试用的 org.json 会保留负零，所以测试没发现。
- 后果：
  - 内容相同的粘贴也被算作修改。
  - 当前照片回执比对失败，界面报保存失败、要求重新载入，但数据已写入。
  - 撤销/重做一直报冲突。
- 要求：
  - 不变量一：`EditSettings` 中任何浮点字段都不出现负零。在 `setLogical`、`logical`
    的取负处归零，并覆盖 `editor/controls/AdjustmentInteraction.kt:29-38` 等手动
    输入"-0"的路径。
  - 不变量二：`EditStore.commit` 返回的记录与磁盘读回结果逐字段相等，例如返回按磁盘
    编码再解码的记录。
- 回归：
  - JVM：默认范围粘贴到相同内容的照片应判为未变化；结果中不出现负零。
  - 编码往返测试：按设备行为把 -0 写成 0，回执仍与磁盘相等。
  - 模拟器：默认范围粘贴到当前照片后撤销、重做均成功，回执不报冲突。

**A-2 编辑过的照片，工作副本在会话内不再删除（相对 v0.8.2 退化）。**

- 位置：`editor/EditorViewModel.kt:674-677`（`releasePreviousPhoto`）；
  `adjustments/AdjustmentTransferSession.kt:35-38`、`:180-181`；
  `editor/EditorAdjustmentHistory.kt:31`；`photo/PhotoStorage.kt:55`、`:222`。
- 现象：保存过一次的照片被登记进 `knownRecords`，切走时不删副本；重新打开又复制一份，
  旧副本失去引用，直到 `onCleared` 才清理；进程被杀后目录一直遗留。
- 要求：
  - 历史的来源校验改为依赖原始 URI 校验，不为它保留整份副本；或在 `refreshSource`
    换掉副本后立即删除旧文件。
  - 启动时清理不属于当前进程的过期 `rawlab-*` 目录。删除前确认批量任务和 journal
    恢复不引用这些副本。
- 回归：在两张已编辑照片间来回切换，缓存目录文件数恒定；撤销跨照片仍能校验来源。

**A-3 集合同步的应用与撤销在主线程逐张整文件 SHA-256。**

- 位置：`editor/EditorCollections.kt:66-67`；`editor/EditorViewModel.kt:820`、`:825-829`、
  `:926`；`editor/ui/AdjustmentTransferSheet.kt:127`、`:208-210`；
  `adjustments/AdjustmentTransferSession.kt:77`、`:146`、`:165`。
- 要求：应用、撤销、重做和 `editCollectionPhoto` 的提交放到与预检相同的串行后台队列，
  主线程只接收结果；保持版本比较写入与回执语义。整文件哈希只在预检/冻结阶段做，
  提交阶段用 stat 级校验。
- 回归：主线程不做文件读取（StrictMode 或计时断言）；大集合同步不触发应用无响应。

**A-4 API 26 每次保存在主线程读取并哈希整张原图。**

- 位置：`photo/OriginalPhotoSource.kt:28-37`，经 `EditorAdjustmentHistory.kt:81` 调用。
- 要求：API 26 及非普通文件 fd 的情况改用大小、inode、秒级修改时间，或在后台预算
  摘要并缓存；不得在主线程整文件读取。

**A-5 配方白平衡探测没清掉新增处理阶段。**

- 位置：`app/src/main/cpp/rawlab_jni.cpp:149-171`（`prepareRecipeWb`）；
  `engine/NativeProcessor.kt:97-101`、`:166-170`。
- 现象：使用大师配方且清晰度或去朦胧不为 0 时，32px 探测退化为全分辨率 CPU 管线，
  预览延迟约翻倍，并每帧冲掉 `dehaze_analysis` 缓存。
- 要求：清晰度/去朦胧、曲线、颜色分级、黑白场/鲜艳度改为随 `nativeProcess` 传入，
  在 `prepareRecipeWb` 之后设置；或探测时设为恒等值、探测后恢复。
- 回归：探测请求的配置为恒等值（JNI 测试）；开启去朦胧时预览只跑一次去朦胧分析。

**A-6 收起调整面板后 HSL 目标模式继续生效。**

- 位置：`editor/ui/EditorScreen.kt:247`（`targetMode` 要求 `expanded`）。
- 要求：按 R4 的 M-5 定稿行为移植：收起后目标模式不退出；画布上显示当前轴和退出入口；
  Back 退出（`:251` 已有）；对比、按住查看的禁用规则沿用展开时。

**A-7 核实项。**

- `settings/EditPersistence.kt:83` 每次 `versionedState`/`compareAndSave` 都重读并严格
  解析整份 `edits.properties`，每个手势在主线程 2～3 次，记录不清理。实测数百到上千条
  记录时的耗时，超过一帧则加缓存或移出主线程。
- `EditorCollections.prepare`/`freeze` 在 IO 线程调用 `validateCollectionActive` →
  `validateCommitted`，`EditorAdjustmentHistory` 不是线程安全的。改为主线程封闭或加锁。
- 大图内存峰值：编辑器会话持有解码 Bitmap（128MP 约 512 MB），同时从编辑器发起批量或
  集合导出时会再解码一份。真机测峰值；有内存不足风险则导出前释放编辑器缓存或串行化。

## R4 Mac

**M-1 方向键微调 HSL 目标时丢失取样点。**

- 位置：`Editor/Model/EditorModel+HSLTarget.swift:13-19`、`:57`、`:60-64`；
  `Presentation/MacCanvasInput.swift:62-68`。
- 现象：`beginHSLTarget` 先 `cancelHSLTarget()` 清空取样点，再因重新显影中 `busy` 返回。
- 要求：检查失败时保留原取样点；显影期间按键累积后合并为一次调整。iOS 的处理
  （`RawLab/RawLab/UI/Editor/ContentView+HSLTarget.swift:17-21`）可作参考。
- 回归：连按与按住方向键，取样点保留，最终值等于累积步进，历史只增加对应条数。

**M-2 拖动中按 ⌘Z/⇧⌘Z 拆散事务。**

- 位置：`Editor/Model/EditorModel+AdjustmentHistory.swift:16-20`、`:76`；
  `Shared/ToneCurveInteraction.swift:62`。
- 要求：曲线、色轮、HSL 目标拖动进行中禁用撤销/重做；或先取消正在进行的输入会话，
  再执行撤销。一次拖动始终只形成一条历史。
- 回归：三种拖动中触发撤销，历史条数与最终值正确，后续鼠标移动不再写历史。

**M-3 AI 与批量导出、Agent 配方。**

- 位置：`Editor/Model/EditorModel+Workflow.swift:307`、`Export/BatchExportModel.swift:84-90`、
  `Rendering/Engine.swift:377`、`Editor/Model/EditorModel+BatchSelection.swift:164`、
  `Rendering/AgentRecipe.swift`。
- 现象：统一批量预检用 `job.settings.neutralSettings`，AI 在里面是关的；导出时 RAW 目标
  返回 `AI_NOT_READY`，普通图片目标抛"AI 降噪仅支持 RAW 照片"，都要到运行时才失败。
- 要求：
  - 先核对 Windows 行为：`BatchExportWindow.xaml.cs:152` 用真实设置加固定 AI 后端预检，
    失败项一开始就取消勾选。Mac 对齐：预检用每个目标的真实设置；普通图片目标在预检时
    排除并说明原因；RAW 目标在预检或导出前完成 AI 准备，不静默退回普通降噪。
  - `agentRecipe` 遇到开启 AI 的照片时拒绝，与 Windows 一致。
- 回归：开启 AI 的来源照片建统一批量任务，预检结果与实际导出一致。

**M-4 更新器语义修复（Mac 先定稿，R6 照此移植）。**

- B 备份与恢复目录从不清理：
  - 位置：`System/Updates/UpdateStore.swift:72-80`；
    `DesktopUpdateController.swift:223`、`:225`、`:227`；`UpdateState.swift:47`。
  - 现象：每次安装尝试都复制一份完整数据，作废的尝试留下孤儿副本；只要成功更新过一次，
    "重建更新设置"就永久失效，Looks 也会反复被复制。
  - 要求：首启健康检查记为完成后删除不再引用的备份；作废的尝试清理自己的副本；
    "重建"只把当前状态引用或进行中的备份视为阻碍。
- C 选了"退出时安装"后退出被静默拒绝：
  - 位置：`DesktopUpdateController.swift:199-201`、`:216-217`；
    `System/MacGeometryWindowGuard.swift:96`；`Editor/Model/EditorModel+Updates.swift:11-14`。
  - 要求：退出时安装准入失败（未提交输入、几何草稿、正在渲染等）就回到普通退出流程：
    照常弹草稿确认，本次不安装，保留安装选择。不得出现按 ⌘Q 无反应。
- D 首启信任检查一次失败即永久失败：
  - 位置：`DesktopUpdateController.swift:110-113`、`MacUpdateTrust.swift:47-58`、
    `MacUpdateRuntime.swift:36`。
  - 要求：区分暂时失败（严格模式下 `spctl` 超时、离线等）与明确失败；暂时失败允许重试，
    不写成永久失败。
  - 现在每次启动都要等信任检查结束才创建编辑器（`MacUpdateRuntime.swift:36`）；
    非升级后的首启不应阻塞编辑器创建。实测自签名模式下的启动耗时。
- 回归：模型测试覆盖孤儿备份清理、重建条件、退出准入失败回退、暂时失败重试；
  真实签名包的启动耗时记录在 PR。

**M-5 收起调整栏后 HSL 目标模式继续生效（四端基准）。**

- 位置：`Editor/Model/EditorModel+HSLTarget.swift:4-7`、`Editor/View/EditorView.swift:528`。
- 要求：
  - 保持现有"收起不退出"的语义。
  - 面板收起时，在画布上显示目标模式的当前轴和退出入口；Esc 退出。
  - 平移被目标手势占用的情况要能从提示看出。
  - 文案交 R0。
- 回归：收起后提示可见、可退出，拖动按目标调整写一条历史，展开后面板状态一致。

**M-6 核实项。**

- `originalCache` 跨线程读写：`Editor/Model/EditorModel+Workflow.swift:336` 在主线程读，
  `Editor/Model/EditorModel+Rendering.swift:105-110` 在渲染队列写。用 Thread Sanitizer
  加反复打开同一照片验证；有竞争则加同步。
- 打开新照片时，`EditorModel+Workflow.swift:342` 与 `EditorView.swift:110/128/133` 只取消
  颜色分级的进行中交互，曲线拖到一半会被提交。统一为都取消或都提交。
- 普通图片套用大师配方后，白平衡"已调整"标记：`Adjustments/Adjustments.swift` 的
  `isModified(.tool(.whiteBalance))` 不区分 RAW 与普通图片，色调偏移对普通图片无效却显示
  已调整。iOS 工具级已按 `isRaw` 区分，两端颜色组级都没有区分；四端对齐。
- 撤销/重做不检查 AI 是否运行中（Windows 会拦截）：确认是否会产生错误状态，
  有则与 Windows 对齐。

**M-7 更新信任改为自签名证书模式，Developer ID 保留为严格模式。**

- 位置：`System/Updates/MacUpdateTrust.swift:10-58` 与 `makeMacUpdateAdapter`。
- 按 Info.plist 选择模式：
  - 写了自签名证书指纹（新增配置键，名称由实现定）：自签名模式。
  - 写了 `RawLabUpdateTeamID`：现有 Developer ID 加公证的严格模式，代码保留不动。
  - 两者都没写或同时写了：判为不可用。
- 自签名模式：
  - 用签名要求固定叶证书指纹，对主程序和嵌套代码做严格校验。
  - 不调用 `spctl`。
  - 保留现有检查：bundle ID、HTTPS feed、EdDSA 公钥、架构、签名 feed 三项设置、所在目录可写。
  - ad-hoc 签名判为不可用。
- 不改变 Sparkle 自身的 EdDSA 校验与签名 feed 要求。指纹值由 R1 写入 Info.plist。
- 回归：两种模式、缺配置、配置冲突、ad-hoc、证书不匹配、嵌套代码被改动，分别得到预期的
  可用/不可用结果；正式自签名包判为可用。

## R5 iOS

**I-1 收起调整面板后 HSL 目标模式继续生效。**

- 位置：`RawLab/RawLab/UI/Editor/ContentView+HSLTarget.swift:5`（要求
  `adjustmentsExpanded`）。
- 要求：按 M-5 移植：收起不退出，画布显示当前轴与退出入口。

**I-2 核实项。** 普通图片的白平衡组级"已调整"判断，与 M-6 同步对齐。

## R6 Windows

**W-1 首次准备 AI 期间预览冻结。**

- 位置：`MainWindow/Rendering.cs:124`。
- 要求：改为 `settings.AIDenoiseEnabled && (aiJob.State.IsRunning || !AIResultReady)` 才阻止
  预览，导出仍由 `AIBlocksOutput` 拦截，与 Mac `EditorModel+Rendering.swift:55` 一致。

**W-2 草稿中"重置全部"等不到精确预览时锁住编辑区。**

- 位置：`MainWindow.Commands.cs:85-106`、`MainWindow/Tools.cs:440`。
- 要求：离开草稿后立即执行重置，只把"回到原工具"延后到空闲；显影失败、AI 失败时
  清除 `pendingAllReset`。
- 回归：重置后预览持续失败，调整栏和 AI 重试仍可用。

**W-3 HSL 目标保存失败后手势状态残留。**

- 位置：`MainWindow/HslTarget.cs:81-85`、`EditWorkflow.cs:58`、
  `MainWindow/EditHistory.cs:31`、`:40`、`:81`。
- 要求：`EndHslTarget` 结束后无论保存成败都清 `editGesture`；失败时保留 `editDirty` 和
  重试提示，下一次手势不回滚未保存的修改。

**W-4 AI 连续"结果未就绪"时无限重复准备。**

- 位置：`MainWindow.xaml.cs:86-89`、`MainWindow/AIDenoise.cs:87-96`。
- 要求：同一身份连续未就绪设上限，超过后转为失败并提示（文案交 R0），配合 C-3。

**W-5 更新器。**

- A 批量编辑窗口不受安装锁约束：`MainWindow/SoftwareUpdates.cs:61-62` 锁定时只禁用了
  主窗口和 `batchWindow`。`collectionWindow` 也要禁用；新建的批量窗口按当前锁状态初始化；
  或把锁状态并入 `CollectionBusy`（`MainWindow/BatchSelection.cs:11`）。与 Mac
  `RawLabMacApp.swift:125` 对齐。
- B、C、D 按 M-4 定稿移植：`Updates/UpdateStore.cs:82-88`；
  `Updates/DesktopUpdateController.cs:106`、`:203-204`、`:214`、`:219-221`；
  `MainWindow/SoftwareUpdates.cs:96`。
- E 锁定时整个主窗口禁用，更新窗口关掉后看不到原因：保留可见的锁定原因和打开软件更新
  的入口。
- F 单实例锁：行为不改，把实际提示与退出行为提供给 R0 写入发布说明。

**W-6 收起调整栏的 HSL 目标提示。** 现有"收起不退出"保持不变，按 M-5 补画布提示与退出入口。

**W-7 核实项。** AI 恰好在拖动中完成、随后取消手势时，"已启用 AI"会被一起回滚，
`ReconcileAI` 还会重置已完成结果（`MainWindow/AIDenoise.cs:79`、`EditHistory.cs:40`）。
复现成立则让 AI 启用状态不进入手势的回滚范围，并核对 Mac 是否同样存在。

**W-8 更新信任改为只靠签名发布描述，Authenticode 保留为严格模式。**

- 位置：
  - `Updates/UpdateTrust.cs:28-29`：现在要求 `PublisherKeySha256` 必须是 64 位十六进制。
  - `Updates/VelopackUpdateAdapter.cs:55-57`（创建）、`:76`（校验）、`:83-84`（安装派发前）。
  - `Updates/UpdatePackageVerifier.cs:41`：包内文件逐个做 Authenticode。
- `PublisherKeySha256` 为空时进入描述模式：
  - 不调用 `AuthenticodeTrust`。
  - 保留签名描述验证，以及它绑定的包大小、SHA-256、版本、架构、渠道、有效期，禁止降级。
  - `UpdatePackageVerifier` 只跳过 Authenticode，其他检查不变。
- 填了 `PublisherKeySha256` 时，现有严格模式不变。`FeedUrl`、`PublicKey` 缺失仍判为不可用。
- 回归：
  - 两种模式下，篡改包、篡改描述、描述过期、版本降级都被拒绝。
  - 描述模式下，未做 Authenticode 签名的正式 Setup 能完成检查、下载、校验和安装派发。

**W-9 支持从 GitHub Release 下载。**

- 位置：`Updates/SignedUpdateSource.cs:21`（`AllowAutoRedirect = false`）、`:28`、`:45`；
  `Updates/UpdateTrust.cs:70-72`（包地址必须与发布源同主机）。
- 现象：`releases/latest/download/...` 和 `releases/download/...` 都会 302 跳转到 GitHub 的
  下载服务器（如 `release-assets.githubusercontent.com`）。现在禁止跳转，必然失败。
- 要求：
  - 手动跟随跳转并限制次数；每一跳都必须是 HTTPS，目标主机在白名单内
    （`github.com` 与 GitHub Release 下载域名）。
  - 首个地址仍须与发布源同主机。
  - 包的可信度仍由签名描述里的大小和 SHA-256 保证；超时、大小上限、取消逻辑不变。
- 回归：本地模拟跳转链，覆盖白名单内成功、跳到白名单外、降为 HTTP、跳转次数超限；
  R7 用真实 GitHub 预发布附件实测。

## R7 联合验收与发布门槛

全部修复合入后，在同一 `development` 源上执行，结果绑定源码与二进制，通过后再创建
`release/<版本>`：

- release PR 的自动 full 检查组全部通过，含 R1-5 新增的着色器编译与 AI 构建检查。
- 四端受影响 UI 测试与六语、大字号回归，覆盖：
  - HSL 目标收起行为；
  - 粘贴、预设、同步与撤销；
  - 集合导出；
  - 更新设置、锁定与恢复画面。
- 真实硬件：
  - Windows 硬件 GPU 跑 D3D11 预览与导出，DirectML 下 AI 的 Auto/Force；
  - Mac Apple Silicon 跑 Core ML；Intel 验证 AI 不支持的提示，不运行 CPU AI；
  - Android 真机或模拟器验证 A-1 至 A-5，含内存峰值。
- AI：首次计算、缓存复用、关闭后内存释放、批量导出，以及缺模型或校验失败时的提示。
- 更新（IT-13/14）：
  - 从 0.8.2 手动安装本版（种子版），确认数据保留，并记录首次放行和权限确认的实际提示。
  - 测试用独立的测试密钥，以及指向 GitHub 预发布附件的测试发布源；预发布不会成为
    `latest`，正式用户收不到。用测试种子版升级到"种子版+1"测试包，验证：
    - 检查、下载（含 GitHub 跳转）、校验拒绝、安装、重启；
    - 首启健康检查和失败恢复。
    - Mac arm64/x86_64 与 Windows x64 分别记录。
  - Mac 自签名模式另需实测：
    - 自动更新后是否触发 Gatekeeper 或"App 管理"权限提示；
    - 文件夹访问等隐私授权更新后是否保留；
    - EdDSA 正确但证书不同的更新包是否被拒绝。
    - 结果写入发布说明。
  - 正式包和更新文件发布前，用正式公钥离线校验全部签名。
- IT-15/16 联合门槛与总账 IF 项关闭；未覆盖的设备或平台在发布文档中明确记录。
