# ITER-11 桌面更新接入计划

依据[需求 §13](../../design/editing-iteration/requirements.md#13-桌面自动更新iter-11)
与[技术方案 §10](../../design/editing-iteration/technical-design.md#10-iter-11两端更新链与发行前置)。
ITER-11 已集成到 development。2026-10-26 决定本版启用桌面更新器，采用免费签名方案和
GitHub Release 发布源，具体接线见[桌面发布流程](../../process/desktop-release.md)。
正式密钥、公钥、版本和实际升级验收仍是发布门槛；本地测试不代表已授权签名、上传、
替换日常应用或发布 feed，也不能记为 IT-13/14 真实升级验收。

## 接入与信任边界

- macOS 固定 Sparkle 2.10.0，使用官方 framework/helper 与 `SPUUserDriver`。
  保留包和 feed 的 EdDSA 校验，开启 `SUVerifyUpdateBeforeExtraction`、
  `SURequireSignedFeed`，并禁止签名失败因超时而降级。只有 SDK 的准备完成回调
  才能进入 `package_ready`，下载字节完成不表示校验通过。
- Windows 固定 Velopack / vpk 1.2.161，启动最早阶段禁用默认自动应用。
  仅 `RawLab.Desktop` x64 当前用户 Setup 形态可申请安装。自定义 `IUpdateSource`
  先验证固定公钥签名的发布描述，再绑定包 SHA-256、大小、版本/架构/渠道；
  默认不要求 Authenticode，信任来自 P-256 签名描述。配置发行公钥指纹时额外启用
  Authenticode 严格模式；feed 自带 hash 不能单独建立信任。
- 正式构建必须嵌入真实固定来源、公钥与发行身份；配置缺失、开发签名、portable、
  旧 ZIP 或不受支持架构都保持自动安装不可用。安装支持说明只读，不改变资格。
- 当前开发包保留既有发布页手动下载。携带 updater 的首个可信种子版仍需人工迁移；
  不宣称现有 0.8.2 可以无修改自举。

## 实现顺序

- [x] U1：两端持久状态、attempt token、阶段约束、取消/失败/重启后的迟到回调失效；
  自动检查默认开、自动安装默认关、跳过版本、稍后提醒与渠道。
- [x] U2：安装准入聚合所有编辑/任务状态；只在明确安装意图下保存已提交编辑，
  草稿必须由用户处理；任务与 journal 未安全结束时阻止安装。
- [x] U3 本地接入：真实 Sparkle / Velopack adapter、信任检查、受限安装形态与启动锁；
  备份/首次启动健康记录及失败恢复入口。
- [x] U4：独立软件更新设置、内嵌说明、进度、取消/重试、跳过/稍后、
  立即重启/任务结束后/下次退出选择；六语与可访问名称。
- [x] U5 本地验证：模型/故障注入、真实 SDK 离线包与校验拒绝、两端构建、实际 UI 和源码绑定。
- [ ] U6（已确定启用方案，待正式配置与真实升级验收）：0.8.2 手动安装种子版→签名新版、实际替换/重启/恢复，
  macOS arm64/x86_64 与 Windows x64 支持矩阵、真实用户数据保留。

失败记录独立于窗口生命周期。恢复进程不能沿用旧 attempt 或未经重验的包资格。
关闭自动安装撤销自动排队；普通关闭设置不提交/清除照片草稿。Sparkle 的准备完成
回复 `dismiss` 可能仍会在退出时安装，必须显式取消未获安装选择的准备任务，并在
正常退出前重新检查许可与任务状态。

## 失败恢复与发行配置

安装前备份仅包含 `Edits`、`Looks`、`Presets`、`Batch`，按文件记录 SHA-256；
原始照片不在备份或替换范围。安装派发后的状态是 `pending_restart`，首次启动
必须先核对当前版本/build、应用信任、备份及数据读取健康，再记录 `complete`
和开放编辑。损坏的备份或状态保留错误并进入恢复画面。

安装前的损坏状态可显式“重建更新设置”：先把原始字节持久保存到
`Updates/StateRecoveries/<id>/state.json`，再原子写入关闭自动更新的新设置。
保存的 receipt 绑定归档校验值；本进程仍关闭编辑入口，重开并通过数据健康检查后
才清除 receipt。未来格式、安装阶段/旧版本标记、未知备份或恢复目录/日志均阻止重建；完整可解码的非安装状态允许清理已验证的孤儿备份，
保留全部文件并提示人工处理，不能用重置掩盖安装状态不明。

恢复只在安装/首次启动失败且本进程尚未开放编辑时提供。用户先手动安装更新前
同一版本/build 的可信种子应用，再点击“恢复更新前的数据”。新程序已经成功
开放编辑后不自动降级。恢复先验证并准备备份文件，将当前目录移入
`Updates/Recoveries/<id>/original` 保留新格式记录，再恢复旧目录。移动前落盘的
`recovery-in-progress.json` 阻止中断后开放编辑；明确重试先回滚未完成的移动。
成功记录 receipt 后清除日志，当前进程仍要求退出重开，避免复用缓存的模型；
失败版本被跳过，自动安装关闭。不能用开发签名应用执行这一恢复动作。

正式配置不含私钥：Mac 使用每架构独立的 GitHub `appcast-<arch>.xml`、
`SUPublicEDKey`、`RawLabUpdateArchitecture`，以及固定自签名证书的
`RawLabUpdateCertificateSHA256`。自签名模式不做公证，不调用 `spctl`；
写入 `RawLabUpdateTeamID` 则选择 Developer ID 与公证的严格模式，两个身份配置互斥。
appcast enclosure 需 `rawlab:architecture`、`rawlab:sha256`；包与 feed 都由 Sparkle EdDSA 校验。

Windows 的嵌入资源 `Updates/UpdateTrust.json` 固定 GitHub Release `FeedUrl` 和 P-256 SPKI
公钥 `PublicKey`，默认 `PublisherKeySha256` 为空。描述绑定包大小、SHA-256、版本、
架构、渠道和有效期，拒绝降级。GitHub 下载跳转逐跳限制 HTTPS、443 端口、白名单和次数。

将来改用付费签名时，Mac 保持原 EdDSA 密钥不变，改用 Developer ID 并设置 Team ID；
Windows 对发行可执行文件签名并填入 `PublisherKeySha256`。不更换更新协议。
正式发布先创建草稿 Release，上传全部包、Setup、nupkg、appcast 与签名描述，
离线用正式公钥校验后再发布；草稿不进入 `latest`，避免用户看到未上传完整的更新。

普通启动不等待完整信任检查；更新后的首次健康检查遇到暂时失败可重试，保留备份。
健康状态落盘后清理不再引用的备份。退出时安装准入失败会继续普通退出确认并保留安装选择。
固定密钥、公钥和目标版本未提供时，发布入口直接失败，开发包继续显示自动更新不可用。

## 本地验证边界

两端原生更新画面使用真实编辑器、输入框、照片记录和会话历史，验证更新导航、
检查/下载/取消不提交数值输入或裁切草稿；下载状态由测试 adapter 驱动。
恢复画面在独立测试目录执行实际数据恢复。另行执行真实 Sparkle 对未签名 feed
的拒绝，以及真实 Velopack 读取/下载 vpk x64 包、签名描述、缓存篡改和取消检查。
没有把 fake adapter 的安装选择记成真实安装，也没有运行离线 fixture 的 Setup。

备份测试包含子进程在目录移动之间退出、重开后的回滚和恢复、新格式文件保留。
更新模型检查已接入两端普通模型门槛；界面及离线打包仍属于本地检查。
Mac 本轮运行于 arm64，Windows 为 x64 交互桌面；六语大字号布局和可访问名称
不等同于读屏验收。Mac Intel、真实签名升级与可选严格模式、安装权限/重启矩阵、物理设备
及整轮 IT-15/16 联合验收仍未关闭。本地结果不代表 Hosted CI。

## 官方接口依据

- [Sparkle 2.10.0 包版本与校验值](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.10.0/Package.swift)
- [Sparkle 自定义 UI](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUserDriver.html)
- [Sparkle 安装委托](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)
- [Sparkle 安全配置](https://sparkle-project.org/documentation/customization/)
- [Velopack 1.2.161](https://www.nuget.org/packages/Velopack/1.2.161)
- [Velopack 更新来源接口](https://docs.velopack.io/reference/cs/Velopack.Sources/IUpdateSource)
- [Velopack 离线测试](https://docs.velopack.io/integrating/testing)
- [Windows WinVerifyTrust](https://learn.microsoft.com/en-us/windows/win32/api/wintrust/nf-wintrust-winverifytrust)
