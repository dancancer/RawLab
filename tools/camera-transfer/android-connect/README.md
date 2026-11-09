# Android Sony 手机传图实验

独立的 Android 10+ 验证程序，用于测试 Sony α7C II（ILCE-7CM2、固件 2.00）的
蓝牙发现、配对、Wi-Fi 自动连接和原文件下载。它使用自己的 application ID，不替换 RawLab Android。
已在 Pixel XL / Android 10 上完成该机型的前台列表与 ARW 下载；不代表其他机型、系统或后台场景已验证。

## 验证范围

1. 只显示 Sony 广播中名称包含 `ILCE-7CM2` 的设备，由用户选择。
2. Android 系统完成 Bluetooth bond，用户核对手机与相机上的数字。
3. 协商 BLE MTU 158，执行 Sony `EE01` 配对初始化，再向 `CC08` 写入 `01`。
4. 从 `CC06`、`CC07` 读取并校验 Wi-Fi 名称和密码。相机尚未准备好时，
   对实际观察到的 `ATT 0x9D` 做有上限的等待；其他错误停止。
5. 先取得包含目标 SSID 的新扫描结果，再用精确 SSID/BSSID 建立 `WifiNetworkSpecifier` 请求，
   由 Android 显示系统连接确认。旧扫描结果会导致系统报找不到匹配热点，不能当作密码错误。
6. 使用返回 `Network` 的 socket factory 连接相机 AP 网关的 TCP `15740`，建立
   PTP/IP command/event 双通道，响应 event probe，并通过 `GetDeviceInfo` 校验型号和固件。
7. `OpenSession (0x1002)` 后使用 `0x923C` 分页列出卡槽 1 的 RAW/JPEG，
   使用 `0x923D` 按 3 MiB 分块复制选定 RAW 原文件。每段检查事务、终态和长度，
   下载后重新枚举元数据，拒绝文件在传输期间变化。
8. 原文件以 MediaStore pending 项写入手机 `Download/RawLab Camera Imports/<UUID>/`，
   完成后发布并记录大小和 SHA-256。可预期的失败清理本次 pending 项，不覆盖同名原件。

手机直连模式与桌面 PC Remote 使用不同的连接 profile：当前机型的手机模式开放 TCP 15740，
无需桌面路径的 SSH 22 或 `0x9201/0x9202` 初始化。PTP/IP 本身不另加 SSH/TLS，
无线链路使用相机的 WPA2 热点；程序没有修改相机的 Access Authentication 设置。
不提供拍摄、删除、格式化或时钟/GPS 写入。

此实验限定相机充当 AP，不能把共同路由器的网关当作相机；最多列出 10000 个文件，
单文件上限 1 GiB，当前界面提供单张 RAW 下载。JPEG 下载、HEIF、后台传输、进程重启恢复、
精确发布瞬间的取消、批量传输和 RawLab 编辑器交接尚未完成设备验收。
传输中不要换卡或修改相机文件；元数据复核不能发现“元数据相同但内容被替换”的情况。

Wi-Fi 密码只保留在内存中，不写入日志或仓库。系统配对关系由 Android 管理；
点击“结束并释放连接”会释放 BLE 和临时网络请求，不删除已有配对或已保存照片。
设备上的 `connection-events.txt` 记录阶段、错误、文件名、大小、哈希及保存位置，不含密码。

## 构建与安装

需要 JDK 17、Android SDK platform 35 与 build-tools 35.0.0；不需要 Gradle、NDK 或生产版 RawLab 构建。
构建使用本机 SDK，APK 和测试输出放在指定临时目录；复用本机 Android 调试签名。

```bash
export CAMERA_BUILD_DIR="$(mktemp -d /tmp/rawlab-camera-android.XXXXXX)"
bash tools/camera-transfer/android-connect/build.sh

adb devices -l
adb -s DEVICE_SERIAL install --no-incremental -r "$CAMERA_BUILD_DIR/CameraConnect.apk"
adb -s DEVICE_SERIAL shell am start -n app.rawlab.cameraconnect/.CameraConnectActivity
```

`ANDROID_SDK_ROOT` 和 `CAMERA_JAVA_HOME` 可覆盖默认 SDK/JDK 位置。
`CAMERA_KEYSTORE` 可指定调试签名，默认复用 `~/.android/debug.keystore`，不存在时创建。
保持签名一致即可覆盖安装；旧版使用过不同临时签名时，先导出日志再卸载旧实验包。

Android 10 首次使用需要位置权限、系统位置服务和蓝牙。保持 App 在前台，
相机进入 `网络 → 连接/电脑遥控 → 智能手机连接`。点发现的相机后完成系统提示，
不需要手动输入 SSID/密码，也不需要去手机 Wi-Fi 设置选网络。

连接后点“读取照片列表”，再点“下载一张 RAW 原文件”。默认选择列表中的第一张 RAW；
实验时可通过启动参数 `--es file-name CAMERA_FILENAME.ARW` 指定待核验文件，文件必须在当前会话中唯一。
未完成传输的照片不会发布到 Downloads；停止任务不影响已完整保存的照片。

日志读取：

```bash
adb -s DEVICE_SERIAL shell run-as app.rawlab.cameraconnect cat files/connection-events.txt
```

构建脚本运行 Wi-Fi 参数解析和本地 TCP responder 测试，覆盖双通道握手、设备身份、
事务不匹配、内容列表解析、截断和长度边界，并校验 APK 签名。
真机结果仍须单独记录；编译和合成测试通过不是设备验证。
一次性 APK、日志与截图在使用后清理，不加入 Git；保留本机可复用调试签名。

## 协议来源

流程依据 Apache-2.0 的 CameraSync 公开源码和文档，固定在
[`c25814716a15afca997e0abf0a661974c5021669`](https://github.com/rock3r/CameraSync/tree/c25814716a15afca997e0abf0a661974c5021669)：

- `docs/sony/DOWNLOAD_PICS.md`：CC08 启动与 CC06/CC07 的 Wi-Fi 参数布局。
- `SonyProtocol.createPairingInit`：EE01 的七字节初始化数据；没有采用文档中少一个字节的示例。
- `SonyConnectionDelegate`：MTU 158。
- `docs/sony/DOWNLOAD_PICS.md`：手机模式 PTP/IP 双通道与 `0x923C/0x923D` 命令。

PTP/IP 收包与内容解析从本仓库已验证的 Go 实验实现移植，沿用有界接收、事务检查与元数据复核；
其 alpha2go 协议参考声明见上级 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。

本程序使用 Android 原生 API 独立实现，不依赖 CameraSync 的运行时。
SonyCameraKit 仅作为研究线索，未复制其未声明许可的源码。
