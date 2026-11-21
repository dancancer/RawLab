# Sony 相机传图实验工具

将 Sony 存储卡中已有的静态照片复制到独立持久目录，再通过系统文件打开入口交给 RawLab Mac。
Go 工具用于桌面协议验证，尚未加入产品内的连接、选图界面；其他品牌和 FTP 不在实现范围。
另有独立的 [Android 手机传图实验](android-connect/README.md)，已在 Pixel XL / Android 10 上完成
蓝牙配对、自动请求相机热点、卡内列表和 ARW 原文件保存。
正式产品已接入「从相机导入」，使用与实验程序共用的协议源码，见 [RawLab Android](../../RawLabAndroid/README.md)。

已在 `ILCE-7CM2 / 固件 2.00 / PC Remote / Wi-Fi / Access Authentication` 上完成
SSH 连接、既有照片列表、ARW 下载、重复内容去重、取消及 macOS 打开编辑闭环。
这不是其他型号、固件或连接模式的兼容声明。HEIF 已能列出，下载和编辑能力需另行确认。

## 构建与运行

需要 Go 1.26 或更新版本。模块支持 macOS、Linux；自动打开 RawLab 仅实现 macOS。
在此目录运行以下命令，二进制放系统临时目录：

```bash
go build -o /tmp/rawlab-camera ./cmd/rawlab-camera
/tmp/rawlab-camera help
```

仓库 worktree 开发时，将 `GOMODCACHE` 指向主工作区 `.cache/shared/sony-transfer-go`，
`GOCACHE` 指向主工作区 `.cache/tmp/<task>/go-build`，避免重复依赖与源码目录中的构建产物。

相机先开启 PC 遥控并保持唤醒，电脑和相机处于可互通的局域网。
使用相机“访问认证信息”显示的用户名、密码和 SHA-256 指纹。
将以下结构保存为本机私有 JSON，使用真实值替换占位符，再执行 `chmod 600`；
不把凭据加入 Git，也不要将密码放到命令行参数中。

```json
{
  "user": "CAMERA_USER",
  "password": "CAMERA_PASSWORD",
  "fingerprint": "SHA256:CAMERA_DISPLAYED_FINGERPRINT"
}
```

下文 `192.168.1.100`、凭据路径和文件名是示例。首次先读取精确型号和固件：

```bash
/tmp/rawlab-camera probe --experimental \
  --host 192.168.1.100 --transport ssh --credentials /private/path/camera.json

/tmp/rawlab-camera list --experimental \
  --host 192.168.1.100 --transport ssh --credentials /private/path/camera.json \
  --profile sony-pc-contents --model ILCE-7CM2 --firmware 2.00 --storage 1

/tmp/rawlab-camera download --experimental \
  --host 192.168.1.100 --transport ssh --credentials /private/path/camera.json \
  --profile sony-pc-contents --model ILCE-7CM2 --firmware 2.00 --storage 1 \
  --file-name DSC00001.ARW --expect-size 46280704
```

`--expect-size` 是列表返回的字节数，可省略。下载会重新枚举当前会话，要求文件名在选定存储中唯一，
并在完成后复核对象元数据。不会保存旧句柄后跨会话直接重试。
JSON 结果写 stdout，进度和错误写 stderr；退出码 `0` 为成功、`2` 为参数错误、`130` 为取消。
`Ctrl-C` 会关闭传输并删除本次部分文件；之后重新执行下载即可，不提供跨会话字节续传。

## 保存后打开

下载返回 `source_id`、绝对路径、SHA-256、字节数及 `duplicate`。
重复的相同字节和格式会复用原 source ID 和路径；同名不同内容会保存到不同目录，保留已有原件。

```bash
/tmp/rawlab-camera records
/tmp/rawlab-camera open --source SOURCE_ID --app '/Applications/RawLab Mac.app'
```

`open_requested` 只表示系统接受了文件打开请求，实际解码或编辑失败由 RawLab 显示；原文件仍保留。
相机断开后，`records`、`open` 和文件选择器打开均可离线使用。

macOS 默认存储为 `~/Library/Application Support/RawLab/CameraImports`，
Linux 为用户配置目录下的 `RawLab/CameraImports`。所有命令可用 `--store /absolute/path` 指定同一个存储：

- `manifest.json`：客户端 GUID、完整源文件、来源及最近的传输尝试。
- `files/<source_id>/<camera_filename>`：持久原件，不由编辑缓存清理。
- `.partial/`：未完成传输；进程中断后下次启动处理已登记任务。
- `.lock`：跨进程写锁，避免多个工具同时发布文件。

请保留整个存储目录，或先备份原件再自行清理。移动完整文件会改变桌面编辑身份。
不明来源的孤立完整文件不会被自动删除；可通过 RawLab 文件选择器手动恢复。
不再使用的认证 JSON 应从本机删除。

## 协议与边界

| Profile | 使用范围 | 状态 |
| --- | --- | --- |
| `sony-pc-contents` | SSH 上的 PTP/IP；Sony 会话握手和 `0x923B/0x923C/0x923D` 卡内内容命令 | 上述 α7C II 条件下已实测 |
| `sony-standard-ptp` | 标准 PTP storage/object 枚举与下载；可显式选择 `--transport plain` | 仅合成协议测试通过，旧机型及配对仍需真机确认 |

`0x9201` 是有状态的会话建立，不是持久设置写入。工具不发送 `0x9212` 内容模式切换，
不提供拍摄、删除、格式化、属性设置或自动关闭认证的功能。SSH 先核对指纹，再发送密码，
转发目的地固定为相机的 `localhost:15740`，不回退到明文。

只接受显式指定的私网、链路本地或回环 IP，不扫描网络。所有网络命令必须传 `--experimental`；
list/download 还要求精确型号和固件匹配。默认单文件上限 1 GiB、清单上限 10000 个对象，
可用 `--max-bytes`、`--max-assets` 调整。`--timeout` 控制等待数据包和 SSH 转发建立的时间。

文件保存必须满足协议成功、transaction ID、完整数据阶段、长度及格式头检查。
格式头检查不是完整 RAW 解码。来源显示为 `camera-file-unverified`，不将缩略图/JPEG 宣称为 ARW。
如需要和独立读卡器副本比较，可选用：

```bash
/tmp/rawlab-camera verify --source SOURCE_ID --reference '/Volumes/CARD/DCIM/100MSDCF/DSC00001.ARW'
```

相机文件列表不是冻结快照。传输期间避免换卡、删除或修改文件；元数据复核不能证明
相机上发生了“相同元数据、不同字节”的替换。工具不锁住相机 UI。

## 开发检查

```bash
go test -race ./...
go vet ./...
```

测试使用本机 TCP/SSH responder 和临时磁盘目录，覆盖协议分包、错误终态、超时/取消、
对象变化、身份校验、文件事务、重复下载及发布恢复，不需要连接相机。
当前仓库 Hosted CI 尚未执行本模块的 Go 检查，本地通过不能当作 CI 通过。

长期设计见 [Sony Wi-Fi 传图设计](../../docs/design/camera-transfer/sony-wifi-design.md)。
协议参考和依赖声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
