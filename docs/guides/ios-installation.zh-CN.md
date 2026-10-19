# 将 RawLab 安装到自己的 iPhone

[English](ios-installation.md) | [简体中文](ios-installation.zh-CN.md)

你需要一台电脑、一根能传输数据的 USB 线，以及自己的 Apple Account（原 Apple ID）。**不用越狱，也不必购买付费开发者账号。** RawLab 要求 iOS 18 或更高版本，目前按 iPhone 提供支持。

RawLab 发布的是 **未签名 IPA**，也就是尚未获得安装许可的应用包，不能在手机上点开直接安装。电脑上的工具需要先用你的账号给它签名，再装到你的手机上。当前发布方式不是 App Store 或 TestFlight。见[项目安装说明](installation.md)。

## 选择安装方式

| 你的情况 | 使用方式 |
| --- | --- |
| 有 Windows 或 Mac，想安装发布版 | 按下面的 Sideloadly 步骤操作，不需要编译源码 |
| 有 Mac 和 Xcode，不想使用第三方签名工具，或想安装当前源码 | 使用后面的 Xcode 流程 |
| 只有 iPhone，没有电脑 | 当前发布包没有本文支持的纯手机安装方式，需要借用电脑 |

免费账号签名的应用 **7 天后需要续签**，每台设备最多安装 3 个此类应用。续签就是用同一个账号重新签名、覆盖安装，不必先删除应用。不要频繁更换应用标识，以免耗尽免费账号的 App ID 额度。见 [Apple 免费账号限制](https://developer.apple.com/help/account/basics/about-your-developer-account)。

## 方法一 用 Sideloadly 安装发布版

Sideloadly 是第三方工具，不是 Apple 官方工具。使用它需要在本机工具内登录 Apple Account；不愿这样登录时，改用方法二。密码、验证码和手机锁屏密码都由你自己输入，不要发给 AI agent。

### 1 下载两个文件

1. 打开 [RawLab 最新发布页](https://github.com/dancancer/RawLab/releases/latest)，在 `Assets` 下载名称包含 `iOS` 和 `unsigned.ipa` 的文件。不要下载 Android APK、Mac ZIP 或源码包。
2. 从 [Sideloadly 官网](https://sideloadly.io/) 下载并安装与你电脑系统匹配的版本，不使用来路不明的镜像或“在线签名”网站。

Windows 用户还需按 Sideloadly 官网的安装提示准备 **网页下载版 iTunes 和 iCloud**。官网注明 Microsoft Store 版本不适用于该流程；如果已有这些软件，先检查版本和备份需求，再决定是否替换，不要让 agent 直接卸载。Mac 不要照搬 Windows 的安装要求。见 [Sideloadly 安装要求](https://sideloadly.io/)。

### 2 连接手机

用 USB 线连接 iPhone 和电脑，解锁手机。如果手机询问“要信任此电脑吗”，点“信任”并输入锁屏密码。保持手机连接，在 Sideloadly 的设备列表中选中 **你的 iPhone**，不要误选 Apple Silicon Mac 自身。

如果电脑看不到手机，先检查数据线，并确认 Finder（Mac）或 iTunes（Windows）能看到它。

### 3 签名并安装

1. 打开 Sideloadly，把下载的 `.ipa` 拖进去。
2. 确认所选设备是你的 iPhone，在 `Apple ID` 栏输入自己的 Apple Account。
3. 保持普通 Apple ID 安装模式和默认设置，点 `Start`，自己完成密码及双重认证输入。不要选择只导出 IPA 的模式。
4. 等待工具报告安装成功；出错时保留错误信息，不要连续重试或随意更换账号。

无需修改最低 iOS 版本、注入插件、删除内嵌 Framework 或关闭系统安全保护。以上基本流程见 [Sideloadly 官方说明](https://sideloadly.io/)。

### 4 开启开发者模式

手机打开 **设置 > 隐私与安全性 > 开发者模式**，开启后按提示重新启动。重启后还要点“启用”并输入锁屏密码，才算完成。若安装工具提前要求开启此模式，先完成这一步，再继续安装。

若看不到开关，先按安装工具的提示安装开发签名应用，再查看设置；Mac 用户也可在 Xcode 中开始设备配对。Apple 说明，连接 Xcode 或安装开发签名应用后可以显示此入口。若工具无法继续且开关仍未出现，先停下排查，不下载未知的“解锁”工具。见 [Apple 开发者模式介绍](https://developer.apple.com/videos/play/wwdc2022/110344/)。开发者模式会降低部分安全保护，只为运行自己信任的应用开启。见 [Apple 开启步骤](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)。

### 5 打开 RawLab

在手机主屏幕或 App 资源库打开 RawLab。**只有出现“未受信任的开发者”时**，才到 **设置 > 通用 > VPN 与设备管理**，选择刚才用于签名的账号并按提示信任；这不是每次安装都必须做的步骤。见 [Sideloadly 的信任与排错说明](https://sideloadly.io/faq)。

能打开应用、停留在主界面且不立即退出，说明安装和首次启动成功。需要检查照片处理时，再导入一张自己允许用于测试的 RAW，预览并导出 JPEG。安装成功不等于所有相机、大图处理和真机性能都已验证。

### 6 七天后续签

重新连接电脑，使用 **同一个 Apple Account、同一个应用标识（Bundle ID）**，再安装一次。先导出重要成片，不要先卸载 RawLab；卸载可能删除应用内的数据。

也可以按 [Sideloadly 自动续签说明](https://sideloadly.io/faq)配置自动刷新，但电脑必须运行相关后台程序，并能通过 USB 或已配置的 Wi-Fi 连接到手机。它不是手机离开电脑后仍能永久生效的签名。

## 方法二 用 Xcode 安装源码版

此方法只适用于 Mac，通过 Apple 官方工具构建和安装，**不是把未签名 IPA 拖进 Xcode**。安装的是当前源码；若要与某个发布版一致，应另外取得对应版本源码，不要重置已有工作目录。

1. 从 Mac App Store 或 [Apple 开发者网站](https://developer.apple.com/xcode/)安装完整 Xcode。首次打开，按提示安装 iOS 支持组件。Xcode 必须支持手机当前的 iOS 版本；只有 Command Line Tools 不够。
2. 准备[仓库源码](https://github.com/dancancer/RawLab)和 CMake。已有源码时进入现有仓库根目录；没有源码时，在一个合适的目录运行下面的命令，新建独立源码目录：

```bash
git clone https://github.com/dancancer/RawLab.git RawLab-source
cd RawLab-source
```

然后从仓库根目录运行下面两条命令，先生成并检查图像处理框架。没有 CMake 时，可在已有 Homebrew 的 Mac 上运行 `brew install cmake`。

```bash
bash lutools/build.sh ios
bash lutools/platform/ios/verify-framework.sh
```

3. 运行 `open RawLab/RawLab.xcodeproj`。在 **Xcode > Settings > Apple Accounts**（旧版可能叫 `Accounts`）中登录自己的账号。
4. 选择工程中的 **RawLab target > Signing & Capabilities**，启用 `Automatically manage signing`，把 `Team` 换成自己的团队；免费账号显示为 `Personal Team`。应用标识改为自己使用的唯一值，例如 `com.yourname.rawlab`，其中 `yourname` 换成自己的英文标识。**不要沿用工程里他人的 Team，也不要把示例值当成最终值。** 这些是本机签名设置，不需要提交到仓库。
5. 用 USB 连接 iPhone、完成信任电脑，在 Xcode 顶部选择 **RawLab scheme 和真实 iPhone**，不是模拟器，也不是 `Any iOS Device`。等待设备配对和调试支持准备完成；手机在 **设置 > 隐私与安全性 > 开发者模式**开启、重启并再次确认后，点 Xcode 的运行按钮。
6. 手机能打开 RawLab 后，安装完成。免费账号到期后，再用同一账号和应用标识运行安装一次。

Xcode 会处理应用和内嵌框架的签名，不需要手工重复添加框架。构建前提见[仓库 iOS 构建指南](../../lutools/platform/ios/README.md)，设备运行流程见 [Apple Xcode 真机运行说明](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)。

## 给 AI agent 的执行步骤

本节面向在用户电脑上有操作权限的 agent。用户只让你写文档时，不要实际安装。用户明确要求安装后，按以下顺序执行，遇到需要用户输入的步骤时等待其完成。

### 先确认条件和边界

- 确认电脑是 Windows 还是 Mac、目标是哪个 iPhone、iOS 是否至少为 18，以及安装发布版还是当前源码。已有明确答案时不重复询问。
- 安装发布版按方法一；Mac 上已有仓库和完整 Xcode、用户要源码版或不愿使用第三方签名工具时，按方法二。
- 密码、验证码、锁屏密码、信任电脑、开发者模式的重启及确认由用户本人完成；不要读取、记录或索取这些秘密。
- 不购买开发者会员、不上传 TestFlight、不越狱、不安装企业描述文件，也不关闭 SIP 或 Gatekeeper。不擅自卸载现有应用、驱动或账号证书。
- 保留已有代码改动；不切换或重置分支，不提交个人签名配置、证书、描述文件、设备信息或生成物。

### 发布版的操作顺序

1. 从最新发布页找到实际的 unsigned IPA 和同一版本的 `SHA256SUMS.txt`，下载后核对 **该 IPA** 的 SHA-256；校验失败即停止。Mac 可用 `shasum -a 256 "/path/to/RawLab-iOS-version-unsigned.ipa"`，Windows PowerShell 可用 `Get-FileHash -Algorithm SHA256 "C:\path\RawLab-iOS-version-unsigned.ipa"`。将示例路径换成实际下载文件，不比较其他平台包。
2. 检查并打开 Sideloadly，按方法一操作。它是桌面界面流程，不要编造 `sideloadly install` 之类的命令；有桌面操作工具时按可见界面操作。
3. 在认证前把输入交给用户；恢复操作后核对实际选择的手机、IPA 和安装模式。手机已显示开发者模式开关时先让用户开启；暂未显示时按安装工具提示继续，工具要求开启时暂停等待，不把中断当作安装成功。
4. 工具报成功后，请用户完成开发者模式及必要的信任确认，再验证手机能启动 RawLab。记录工具实际使用的 Bundle ID，后续续签沿用它，不在聊天中公布账号或完整设备标识。
5. 没有桌面操作能力时，完成下载和校验，告知用户准确文件位置以及下一步界面操作；不要把“文件准备完成”说成“已装到手机”。

### 源码版的命令行操作

所有命令从仓库根目录执行。先完成方法二中的 Xcode 初始化、用户账号登录和手机配对。可以让用户在 Xcode 界面选择自己的 Team；若无法确认其 Team ID，就使用 Xcode 界面运行，不猜测、不照抄项目默认值。

先检查环境和可选设备，任一步失败都先处理该项，不继续安装：

```bash
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
cmake --version
xcodebuild -list -project RawLab/RawLab.xcodeproj
xcodebuild -showdestinations -project RawLab/RawLab.xcodeproj -scheme RawLab
xcrun devicectl list devices
```

如果 `xcodebuild` 指向 Command Line Tools，可在当前终端设置 `DEVELOPER_DIR` 为实际 Xcode 的 `Contents/Developer` 路径，例如 `export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"`，不必修改全局工具链。

在当前终端设置以下真实参数后再执行构建。不要把占位符直接传给命令：

| 变量 | 如何取得 |
| --- | --- |
| `TEAM_ID` | 用户确认的开发团队 ID，或用户已在 Xcode 选定 Team 后的 `DEVELOPMENT_TEAM` 设置；仓库原有值不能证明属于当前用户 |
| `BUNDLE_ID` | 首次安装时选定的唯一应用标识；更新或续签用原值 |
| `DEVICE_UDID` | `xcodebuild -showdestinations` 中目标真实 iPhone 的 `id`；不要选模拟器 |
| `DEVICE_ID` | `devicectl list devices` 中同一手机的 Identifier；不假定它与上面的 UDID 相同 |

以下步骤要在同一终端按块执行，**每块退出码为 0 才继续**。命令行覆盖签名设置，不需要修改项目文件：

```bash
: "${TEAM_ID:?Set the confirmed signing team ID}"
: "${BUNDLE_ID:?Set the app bundle ID}"
: "${DEVICE_UDID:?Set the physical iPhone destination ID}"
: "${DEVICE_ID:?Set the same iPhone devicectl identifier}"

bash lutools/build.sh ios
```

```bash
bash lutools/platform/ios/verify-framework.sh
```

框架必须通过验证，不能只因目录存在就复用来源或版本不明的缓存。

```bash
xcodebuild \
  -project RawLab/RawLab.xcodeproj \
  -scheme RawLab \
  -configuration Release \
  -destination "platform=iOS,id=${DEVICE_UDID}" \
  -derivedDataPath build/ios-personal-install \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  PRODUCT_BUNDLE_IDENTIFIER="${BUNDLE_ID}" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGNING_ALLOWED=YES \
  build
```

这一步会通过用户已登录的 Xcode 账号创建或更新签名资料，并按需注册所选设备。不要使用 `CODE_SIGNING_ALLOWED=NO`；那样只能构建，不能得到可安装的签名应用。

```bash
APP_PATH="$PWD/build/ios-personal-install/Build/Products/Release-iphoneos/RawLab.app"
test -d "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
```

确认应用签名校验通过后安装，传入的是 `.app`，不是 unsigned IPA：

```bash
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
```

如果手机还有开发者模式或信任提示，等待用户完成，再继续：

```bash
xcrun devicectl device info apps --device "$DEVICE_ID"
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"
```

在已安装应用列表中核对实际 Bundle ID。启动命令成功仍不代表应用不会立即崩溃；请用户确认手机上能看到并停留在 RawLab 主界面，或使用有权限的设备界面工具核实。

### 如何报告结果

分别报告 **构建或签名、安装、首次启动** 的实际结果。只有安装工具成功且真机主界面确认可用时，才报告“已安装并可打开”；其他情况明确说卡在哪一步、原始错误是什么、下一步需要用户做什么。

最后提醒用户免费签名的 7 天期限和续签方法。只运行了模拟器或未签名设备构建时，不得声称真机安装成功。

## 常见问题

| 问题 | 处理方式 |
| --- | --- |
| 下载后在手机上点 IPA 没反应 | 未签名 IPA 不能直接安装，用电脑按方法一或方法二操作 |
| 找不到手机 | 解锁、信任电脑、换能传输数据的 USB 线；Windows 检查官方要求的 iTunes/iCloud 版本 |
| 找不到开发者模式 | 先尝试安装开发签名应用，或在 Mac 的 Xcode 开始配对，再查看手机设置 |
| 七天后打不开 | 用原账号和原 Bundle ID 续签、覆盖安装，不要先删除应用 |
| 提示免费账号安装数量或 App ID 已达上限 | 免费账号最多注册 10 个 App ID 和 3 台设备，注册后 7 天过期；每台设备最多安装 3 个应用。先核实额度，不反复改 ID；卸载其他应用须由用户决定 |
| Xcode 提示签名团队或 Bundle ID 错误 | 确认使用自己的 Team、唯一 Bundle ID、自动签名及已登录的账号 |
| Xcode 找不到 `sony2fuji.xcframework` | 从仓库根目录运行 iOS 框架构建及验证命令，不手工删除嵌入框架来绕过错误 |
| Xcode 不支持手机当前 iOS | 安装支持该系统的 Xcode 和设备支持组件，不降低 RawLab 的最低系统版本 |
| 想用 TestFlight 安装 | 当前发布包不是 TestFlight 构建，不能导入 TestFlight；需要维护者另行发布并提供邀请链接 |

步骤及外部工具说明核对日期：2026-10-13。RawLab 已发布包的真机安装、峰值内存和温度验证仍未完成；本文提供安装操作流程，不把构建或模拟器检查当作真机验证。见[发布版限制](../releases/v0.5/v0.5.0.md)。
