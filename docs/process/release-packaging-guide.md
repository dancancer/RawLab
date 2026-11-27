# RawLab 统一发版与四端打包规范（Release Packaging Guide）

> 本文档是 RawLab **全平台正式发布打包、签名、验证与 GitHub Release 上架的唯一权威执行入口**。后续任何智能体或发布人员执行正式发版时，只需先向用户取得**发布与签名授权**，即可直接依据本手册与本机私有环境配置自动完成全流程，**不得再次向用户重复索要证书路径、Sparkle 公私钥位置、AI 模型缓存或远端构建主机连接方式**。

---

## 一、本机私有配置约定（不入库）

发布主机本机的私有路径、证书指纹、AI/工具链缓存位置以及远端构建/验证主机清单统一维护在用户主目录受保护文件中（权限 `600`，严禁提交进 Git）：

1. **环境变量配置**：`"$HOME/.config/rawlab/release-env.sh"`
   - 发布启动时直接执行 `source "$HOME/.config/rawlab/release-env.sh"` 加载（仅导出路径与公开身份/SHA-256 指纹，不含私钥或口令明文）。
   - 涵盖标准变量：`RAWLAB_CODESIGN_IDENTITY`、`RAWLAB_CODESIGN_KEYCHAIN`、`RAWLAB_CODESIGN_KEYCHAIN_PW_FILE`、`RAWLAB_UPDATE_CERTIFICATE_SHA256`、`RAWLAB_SPARKLE_PUBLIC_KEY`、`RAWLAB_SPARKLE_CACHE`、`SPARKLE_BIN`、`SPARKLE_PRIVATE_KEY_FILE`、`RAWLAB_ONNXRUNTIME_ROOT`、`RAWLAB_RELEASE_KEYSTORE`、`RAWLAB_RELEASE_PASSWORD_FILE`、`RAWLAB_RELEASE_KEY_ALIAS`、`RAWLAB_ANDROID_CERT_SHA256`、`WINDOWS_TRUST_JSON`、`WINDOWS_PRIVATE_PEM`（若仍导出 `RAWLAB_DUALDN_MODEL_DIR` / `RAWLAB_DUALDN_MANIFEST_SHA256`，正式发布构建不再要求模型输入，仅在提供 `RAWLAB_DUALDN_MODEL_DIR` 时做构建期校验且不打包进正式产物；Windows GPU 冒烟脚本继续从包外传入外部模型目录）。
2. **远端主机与设备指南**：`"$HOME/.config/rawlab/release-hosts.md"`
   - 记录 Windows 打包/签名机（`Paul-dev`）、Windows 物理独显测试机（`DESKTOP-216`）、macOS 二机验签机（`Mac-mini.lan`）、完整 Xcode `DEVELOPER_DIR`、Android AVD/物理设备与局域网缓存绕行细节。

**安全红线**：
- **严禁读取、打印或复制**任何密码文件与私钥文件（`keychain-password.txt`、`p12-password.txt`、`codesign-key.pem`、`ed25519-private-key.txt`、`update-p256-private.pem`、`store-password.txt` 等）的明文内容。
- 仅通过文件路径参数传递，或在 `set +x` 静默模式下通过 `"$(cat "$RAWLAB_CODESIGN_KEYCHAIN_PW_FILE")"` 解锁钥匙串；Windows 私钥仅可在签名瞬间临时传输并在 `try { ... } finally { Remove-Item ... -Force }` 中销毁，且必须校验 `Test-Path` 为 `False`。
- GitHub CLI 操作统一使用授权发布账号令牌：`GH_TOKEN="$(gh auth token --user dancancer)"`。

---

## 二、标准产物清单（13 个文件，不多不少）

每个全平台稳定版本 `<version>`（如 `0.12.0`）对应的 GitHub Release 必须严格包含以下 **13 个资产**：

| 序号 | 文件名 | 说明 |
| :---: | :--- | :--- |
| 1 | `RawLab-Mac-<version>-arm64.zip` | Apple Silicon macOS 应用包（启用 DualDn Core ML 运行时 + RUM + Sparkle，不含内置 AI 模型，首次使用按需下载） |
| 2 | `RawLab-Mac-<version>-x86_64.zip` | Intel macOS 应用包（禁用 AI + 含 RUM + Sparkle） |
| 3 | `RawLab.Desktop-stable-Setup.exe` | Windows x64 当前用户安装器（含 DirectML 运行时与自动更新，不含内置 AI 模型，首次使用按需下载） |
| 4 | `RawLab.Desktop-<version>-stable-full.nupkg` | Velopack 更新包（供 `windows-stable.json` 校验与增量拉取） |
| 5 | `RawLab-Windows-<version>-x64.zip` | Windows x64 免安装手动压缩包（含 DirectML 运行时，不含内置 AI 模型） |
| 6 | `RawLab-Android-<version>.apk` | Android 正式签名 APK（`arm64-v8a` + `x86_64`，16 KiB 对齐，含 RUM） |
| 7 | `RawLab-iOS-<version>-unsigned.ipa` | iOS 未签名正式包（内含 `sony2fuji.framework` 与 RUM SDK） |
| 8 | `RawLab-<version>-source.tar.gz` | 对应正式 Tag 提交的纯净源码归档（`git archive`） |
| 9 | `appcast-arm64.xml` | 已签名 macOS Apple Silicon Sparkle 更新源 |
| 10 | `appcast-x86_64.xml` | 已签名 macOS Intel Sparkle 更新源 |
| 11 | `windows-stable.json` | 已 P-256 签名 Windows 更新描述文件 |
| 12 | `BUILD-PROVENANCE.json` | 完整构建来源、SHA-256、CI 记录与验证边界证明 |
| 13 | `SHA256SUMS.txt` | 涵盖上述 1–12 共 12 个文件的 `shasum -a 256` 清单（不含自身） |

> **外置 AI 模型说明**：桌面端正式发布包均**不包含** DualDn / Restormer 模型权重，仅随包提供推理运行时（ONNX Runtime / DirectML）与 `ai-model-catalog.json`。首次使用 AI 降噪时需由用户在应用内手动触发一次下载；从早期内置模型版本升级的用户同样需要执行一次应用内下载。Intel macOS 包不含 AI 运行时与模型。
>
> **禁止上传的文件**：Velopack 附带生成的 `RawLab.Desktop-stable-Portable.zip`、`RELEASES-stable`、`releases.stable.json`、`assets.stable.json` 严禁上传至 GitHub Release；仅在确认仅更新部分平台的热修复发布中，按 [桌面端发布 SOP](desktop-release.md#acceptance-and-publication) 完整保留并校验 `appcast-arm64.xml`、`appcast-x86_64.xml` 与 `windows-stable.json`。

---

## 三、发版前准备与独立工作区隔离

1. **前置核查**：
   - 确认目标版本已在 `main` 合入并打好附注标签 `v<version>`（不得修改主工作区本地未跟踪宣发目录如 `release-artifacts/`）。
   - 使用独立工作区检出目标 tag 提交：
     ```bash
     git fetch origin --tags
     COMMIT_SHA="$(git rev-parse "v$VERSION^{commit}")"
     git worktree add --detach ../rawtools-worktrees/v"$VERSION"-pkg "$COMMIT_SHA"
     python3 ../rawtools-worktrees/v"$VERSION"-pkg/scripts/version/generate.py --check
     ```
2. **生成源码归档与发布说明**：
   - 使用 `git archive --format=tar.gz --prefix="RawLab-$VERSION/" "$COMMIT_SHA" -o "$DIST/RawLab-$VERSION-source.tar.gz"`，并用 `tar -tzf` 核对不含私钥或外部 RAW 样片。
   - 准备 UTF-8 格式的发布说明文本（同时传给 `macos_appcast.py --notes`、Windows `update-manifest sign` 与 `scripts/release/upload-draft-release.sh --notes-file`）。
3. **本机快检（切 `release/*` 前与打包 worktree 中各跑一次）**：
   ```bash
   bash scripts/release/preflight.sh            # 版本/文档链接 + RawLabMac 全量类型检查 + macOS/iOS apple-models
   bash scripts/release/preflight.sh --models none   # 只跑前三步，约 1 分钟
   ```
   - 依次执行：`generate.py --check` 与构建号单调/血统门禁（`scripts.ci.test_versioning`）、入库文档相对链接（`scripts.ci.test_doc_links`）、RawLabMac 主工程 `swiftc -typecheck`（与 `RawLabMac/build.sh` 同一组源文件，打开 `RAWLAB_RUM`，拦截只有完整应用编译才暴露的 SwiftUI 编译错误）、`scripts/ci/apple-models.sh macos|ios`。
   - 任一步失败立即停止，并在 stderr 打印失败步骤名与退出码；apple-models 并行失败时会额外汇总每个失败套件及其退出码。
   - SwiftPM 产物缓存在 `<worktree>/.cache/tmp/release-preflight`（可用 `RAWLAB_PREFLIGHT_CACHE` 改位置），与本 worktree 源码绑定；首次约 80 秒，增量约 40 秒；发布结束后随 worktree 一起清理。
4. **CI 手动门禁错峰派发**：`checks=full` 是发布门禁，按设计冷编原生依赖（`cold=true`，只查询不恢复缓存），并在 `macOS full (arm64, all)` 与 `(x86_64, intel)` 成功后保存原生依赖缓存（full 的 Intel 部分只构建一次，在同一作业里依次跑 core、agent、render）；`checks=build` 不是冷构建，会直接恢复同一缓存键。
   - 先派发 `platform=macos checks=full`，等上述两个作业结束（`Save successful native dependencies` 完成，或因缓存键已存在而显示 skipped）后再派发 `platform=macos checks=build`；同时派发时 build 的 arm64 与 x86_64 两个作业会与 full 的四个作业一起冷编，并争用 GitHub 托管 macOS 的并发额度，整体反而更慢。
   - 不同 `(platform, checks)` 组合的派发互不取消；同一组合重复派发会取消前一次，等它结束再重派。

---

## 四、四端分平台打包、签名与验收步骤

### 4.1 macOS（`arm64` + `x86_64`）
详细架构与签名细节见 [桌面端发布 SOP](desktop-release.md#macos) 与 [macOS 文档](../../RawLabMac/README.md)。
1. 在 `set +x` 下加载 `"$HOME/.config/rawlab/release-env.sh"`，解锁 `$RAWLAB_CODESIGN_KEYCHAIN` 并将其加入当前用户钥匙串搜索列表。
2. **构建 `arm64`**（独立 `RAWLAB_BUILD_DIR`）：
   - 设置 `RAWLAB_RELEASE=1 RAWLAB_ARCH=arm64 RAWLAB_DUALDN=1 RAWLAB_ONNXRUNTIME_ROOT=... RAWLAB_RELEASE_ZIP="$DIST/RawLab-Mac-$VERSION-arm64.zip"`，执行 `bash RawLabMac/build.sh`（不再要求 `RAWLAB_DUALDN_MODEL_DIR` / `RAWLAB_DUALDN_MANIFEST_SHA256`；若 `release-env.sh` 仍导出了 `RAWLAB_DUALDN_MODEL_DIR`，仅做构建期 `dualdn_probe --validate` 校验，不向应用包复制任何模型文件，且打包前会硬性校验 `Contents/Resources/AI/DualDn` 不存在、`Contents/Resources/ai-model-catalog.json` 存在）。
   - 运行 `python3 scripts/release/macos_appcast.py` 生成 `$DIST/appcast-arm64.xml`，随后用 `swift scripts/release/verify-sparkle.swift "$RAWLAB_SPARKLE_PUBLIC_KEY" "$DIST/appcast-arm64.xml" feed` 验签。
3. **构建 `x86_64`**（独立 `RAWLAB_BUILD_DIR`，**必须显式清除 AI 环境变量**）：
   - 使用 `env -u RAWLAB_DUALDN_MODEL_DIR -u RAWLAB_DUALDN_MANIFEST_SHA256 -u RAWLAB_ONNXRUNTIME_ROOT RAWLAB_RELEASE=1 RAWLAB_ARCH=x86_64 RAWLAB_DUALDN=0` 执行 `bash RawLabMac/build.sh`。
   - 生成并验签 `$DIST/appcast-x86_64.xml`。
4. **验收**：
   - 本机运行 `RawLabMac/tests/smoke.sh`（双架构）、`RawLabMac/tests/update-trust.sh`、`RawLabMac/tests/sparkle-adapter.sh`。
   - 对 Apple Silicon 正式应用包执行**真实启动冒烟**：启动应用确认不含内置模型，在界面中触发一次应用内模型下载，下载完成后在 Apple Silicon 硬件 GPU（Core ML）上跑通一次 AI 降噪。Intel 正式包不含 AI 功能，只需完成常规启动与更新验收。
   - 传输至 `release-hosts.md` 中的二机验签 Mac mini 执行 `codesign --verify --deep --strict --all-architectures` 及 `DYLD_PRINT_LIBRARIES=1 "<app>/Contents/MacOS/RawLabMac" --smoke missing.raw /tmp/dyld-smoke` 检查动态库闭包（注意：**不要传 `--help`**，GUI 主程序不会退出）。

### 4.2 Windows（`x64`）与 `windows-stable.json`
1. 将 `RawLab-$VERSION-source.tar.gz`、`UpdateTrust.release.json` 与发布说明文本传至 `release-hosts.md` 中的 Windows 发布机（`Paul-dev`），解压到干净目录。
   - **复用 `Paul-dev` 已校验缓存**：源码归档没有 `.git`，`build.ps1` 找不到主工作区，会把 `<源码>\.cache\shared` 当共享缓存，RUM SDK、Velopack 工具等每次重新下载。构建前先建目录联接并导出缓存变量：
     ```powershell
     New-Item -ItemType Directory -Force "$src\.cache" | Out-Null
     New-Item -ItemType Junction -Path "$src\.cache\shared" -Target 'E:\RawLabRelease\.cache\shared' | Out-Null
     $env:NUGET_PACKAGES = 'E:\RawLabRelease\.cache\shared\nuget'
     $env:RAWLAB_SOURCE_ARCHIVE_CACHE = 'E:\RawLabCI\cache\rawlab-deps'
     $env:RAWLAB_LENS_SOURCE_CACHE = 'E:\RawLabCI\cache\lens-sources'
     $env:RAWLAB_HDR_SOURCE_CACHE = 'E:\RawLabRelease\.cache\shared\hdr-codecs'
     ```
     `-OnnxRuntimeRoot` 直接传 `E:\RawLabCI\cache\onnxruntime\windows-directml-1.23.0\installed`。
   - 清理源码树前先用 `cmd /c rmdir "$src\.cache\shared"` 只删除联接本身；**不要**对联接执行 `Remove-Item -Recurse`（Windows PowerShell 5.1 会顺着联接删掉共享缓存内容）。
2. 调用 `RawLabWindows/build.ps1 -ReleasePackage`（传入 `-DotNet`、`-UpdateTrustFile`、`-OnnxRuntimeRoot`、`-ReleaseOutput`；不再需要 `-DualDnModel` 与 `-DualDnManifestSha256`，即使传入 `-DualDnModel` 也仅用于构建期校验，不会进入产物）。
3. 校验 `out\publish\RawLab.exe` 的 `FileVersion` / `ProductVersion` 与 `Shared/version.json` 一致，并确认 `out\publish\AI\DualDn` 不存在且 `out\publish\ai-model-catalog.json` 存在（`build.ps1` 在调用 `vpk.exe` 前也会硬性校验）。
4. 在 Windows 上签名并校验 `windows-stable.json`（因 `UpdatePackageVerifier` 需读取 PE `FileVersionInfo`，必须在 Windows 主机执行）：
   - 仅在签名命令的 `try { ... } finally { Remove-Item ... -Force }` 内临时传入 `$WINDOWS_PRIVATE_PEM`，有效期设 `365` 天、`MinimumVersion` 按兼容基线设置（当前 `0.9.0`）；完成后核实 `Test-Path` 为 `False`，再运行 `update-manifest verify`。
5. 仅将 `Setup.exe`、`*-full.nupkg`、`RawLab-Windows-$VERSION-x64.zip` 与 `windows-stable.json` 传回本机 `$DIST/`，同时取回构建树的 `dualdn_probe.exe` 供下一步使用（不放进 `$DIST/`）。
6. **物理独显冒烟（`DESKTOP-216`）**：用 `scripts/release/smoke-windows-gpu.ps1` 对正式 ZIP 做无损冒烟，脚本头部注释给出完整的上传与调用命令：
   - 必须经原生 Windows OpenSSH 端口 `2222` 连接（`ssh -p 2222` / `scp -P 2222`）；端口 `22` 进入 WSL2，进程带 `PreferSystem32Images` 限制会加载 `System32\onnxruntime.dll`，脚本检测到即拒绝运行；
   - 需通过 `-ModelDir` 从包外传入已校验的模型目录；脚本依次核对：正式 ZIP 内**不含** `AI\DualDn` 且包含 `ai-model-catalog.json` 与 DirectML 运行库、用包内运行库对外部 `-ModelDir` 执行 `dualdn_probe --validate` 与强制 DirectML 的 `pipeline` 探针（`producer` 须含 DirectML 且无回退）、`sony2fuji.exe` CLI 出图、ExifTool 版本、子进程加载 `sony2fuji.dll` 的 `sony2fuji_ai_available=1` 与 `sony2fuji_ai_hardware_available=1`（且运行库来自安装包目录）；
   - 调用时加 `-NonInteractive`，漏传参数直接报错而不是在 ssh 会话里等待输入；前置守卫失败同样会清理；工作目录与 `-StagingDir` 在 `finally` 中删除并核实 `Test-Path` 为 `False`；`%LOCALAPPDATA%\RawLab` 前后指纹不一致即判失败；不启动 GUI。输出的 `SUMMARY:` 行可直接写入 `BUILD-PROVENANCE.json`。
7. **Windows 真实启动与按需下载冒烟**：在带硬件 DirectML 独显的 Windows 主机上启动正式包，确认初始无内置模型，手动触发一次应用内模型下载，随后在硬件 GPU 上完成一次 AI 降噪。

### 4.3 Android（`.apk`）
1. 在打包 worktree 执行 `bash RawLabAndroid/scripts/fetch-rum-sdk.sh` 拉取并校验 RUM AAR。
2. 如当前网络环境存在 Android SDK CMake 3.22.1 访问外网 TLS 拦截（参见 `release-hosts.md`）：
   - 将共享缓存 `.cache/shared/macos-sources/` 与 `.cache/shared/hdr-codecs/` 中已校验归档解压至临时源码目录；
   - 创建临时 `GRADLE_USER_HOME`（软链 `~/.gradle/{caches,wrapper,native,android}`）并通过 `init.d/*.gradle` 向 `android.defaultConfig.externalNativeBuild.cmake.arguments` 注入各 `-DFETCHCONTENT_SOURCE_DIR_*` 与 `-DRAWLAB_*_CACHE`；同时导出 `RAWLAB_ANDROID_SOURCE_CACHE`、`RAWLAB_SOURCE_ARCHIVE_CACHE`、`RAWLAB_HDR_SOURCE_CACHE`、`RAWLAB_LENS_SOURCE_CACHE`。
3. 导出 `JAVA_HOME`、`ANDROID_HOME`、`RAWLAB_RELEASE_KEYSTORE`、`RAWLAB_RELEASE_PASSWORD_FILE` 后运行 `bash RawLabAndroid/scripts/build-release.sh`，确认：
   - Release APK DEX 包含全部 RawLab 与 RUM JNI 类定义；
   - `apksigner` 证书 SHA-256 严格匹配 `$RAWLAB_ANDROID_CERT_SHA256`；
   - 全部 `.so` 通过 16 KiB 对齐检查。
4. 运行正式包模拟器冷启动冒烟（**严禁对真机运行以免卸载用户数据**）：
   ```bash
   ANDROID_HOME="$HOME/Library/Android/sdk" \
     bash RawLabAndroid/scripts/smoke-release-apk.sh "$DIST/RawLab-Android-$VERSION.apk" --avd rawlab-v0111-triage-android15
   ```
   （如使用默认 ADB `5037` 端口，可避免 `emulator` 未注册到自定义 ADB 端口导致等待超时。）

### 4.4 iOS（未签名 `.ipa`）
1. 导出 `DEVELOPER_DIR` 指向完整 Xcode（`iOS 27.1+ SDK`），运行 `bash scripts/ci/check-ios-sdk.sh` 与 `bash scripts/rum/prepare-ios.sh`。
2. 构建并校验三切片 `sony2fuji.xcframework`：`bash lutools/platform/ios/build-framework.sh` + `bash lutools/platform/ios/verify-framework.sh`（需要时可传本地 `-DFETCHCONTENT_SOURCE_DIR_*`）。
   - `build-framework.sh` 默认 `JOBS=6`，按 CI 托管机设定；本机发布时显式传 `JOBS="$(sysctl -n hw.ncpu)"` 缩短三切片串行编译。若同时在跑 Android 或 macOS 构建、出现内存换页，退回默认值。
3. 使用 `xcodebuild -project RawLab/RawLab.xcodeproj -scheme RawLab -configuration Release -sdk iphoneos -jobs "$(sysctl -n hw.ncpu)" CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build` 构建未签名应用。
4. 校验 `RawLab.app` 内 `Info.plist` 版本号、构建号、`MinimumOSVersion`、`arm64` 架构及内嵌 `Frameworks/{sony2fuji,AlibabaCloudRUMSDK}.framework`，放入 `Payload/RawLab.app` 后用 `ditto -c -k --keepParent Payload "$DIST/RawLab-iOS-$VERSION-unsigned.ipa"` 打包，并校验 `unzip -Z1` 顶层目录为 `Payload/RawLab.app/`。

---

## 五、清单生成、Draft 上架与发布后线上验签

1. 生成 `$DIST/BUILD-PROVENANCE.json`（对标历史 Release 结构，如实区分本机/远端已验证项、Hosted CI 结果与未覆盖物理硬件项）。
2. 在 `$DIST/` 下生成并校验 `$DIST/SHA256SUMS.txt`（包含其余 12 个资产的 `shasum -a 256`，不含自身；运行 `shasum -a 256 -c SHA256SUMS.txt` 须 12/12 `OK`）。
3. **先创建空 Draft，再并发上传并核验全部 13 个资产**（Draft 不会影响线上 `releases/latest` 自动更新）：
   ```bash
   GH_TOKEN="$(gh auth token --user dancancer)" bash scripts/release/upload-draft-release.sh \
     --version "$VERSION" --dist "$DIST" --notes-file "$NOTES_FILE" --jobs 4
   ```
   - 先在本地核对 `$DIST/` 恰好是上表 13 个文件、`SHA256SUMS.txt` 12/12 校验通过，任何 GitHub 写操作都在此之后；
   - 空 Draft 建好后 3–4 路并发上传（`--jobs`），单个资产失败按退避重试（`--attempts`，默认 4 次，`--clobber` 覆盖半截资产）；仍失败时在 stderr 列出失败资产，直接重跑同一命令即可续传，Draft 保持未发布；
   - 同 tag 已有 Draft 时复用，已正式发布时拒绝执行；脚本从不转正。
4. 脚本最后通过 GitHub API 核对 Draft 资产数量为 `13`、文件名集合一致，且每个资产 `state=uploaded`、`size` 与 `digest`（`sha256:`）与本地逐字节一致，打印 `remote: 13/13 assets match local size and sha256`；API 未返回 `digest` 时同样判失败。**任何不一致严禁转正**。仅需复核时加 `--verify-only`。
5. 全部核验一致后正式发布：
   ```bash
   GH_TOKEN="$(gh auth token --user dancancer)" gh release edit "v$VERSION" \
     --repo dancancer/RawLab --draft=false --latest
   ```
6. **发布后必须立即执行线上拉取验签**（依据 [桌面端发布 SOP](desktop-release.md#acceptance-and-publication)）：
   - 从 `https://github.com/dancancer/RawLab/releases/latest/download/{appcast-arm64.xml,appcast-x86_64.xml,windows-stable.json}` 真实下载三份更新元数据，分别运行 `verify-sparkle.swift` 与 Windows `update-manifest verify`（校验绑定刚上传的 `.nupkg`）；
   - 使用 `curl -fsSLI` 检查全部版本化包下载链接返回 HTTP `200` 且 `content-length` 与 `BUILD-PROVENANCE.json` 匹配。
7. 全部验收完成后清理本地与远端临时构建树/目录，保留 `"$HOME/.config/rawlab/"` 与主工作区本地素材完整。
