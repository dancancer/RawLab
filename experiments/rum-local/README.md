# RUM 本地接入与验证

2026-10-17 起四端正式构建默认带 RUM SDK、以 `env=PROD` 上报，统计默认开启（见[设计](../../docs/superpowers/specs/2026-10-16-rum-analytics.md)）。本目录保留两类验证：正式配置的实网验证，以及显式本地验证构建（`env=LOCAL`、独立应用标识和同意存储）。五类合成事件不会读取照片，也不会改动日常统计的同意状态或安装标识。

## 云端只读检查

使用 Node.js 22+ 和官方 SDK。RAM 凭证只放根目录忽略的 `.env`，使用 `ALIBABA_CLOUD_ACCESS_KEY_ID` / `ALIBABA_CLOUD_ACCESS_KEY_SECRET`，不要传入客户端或命令行参数。

```bash
npm install --save-exact --prefix .cache/shared/aliyun-arms-api/10.1.0 @alicloud/arms20190808@10.1.0
npm install --save-exact --prefix .cache/shared/aliyun-sls-api/1.2.6 @alicloud/log@1.2.6
env -u DEBUG -u NODE_DEBUG node experiments/rum-local/mobile-config-check.mjs
env -u DEBUG -u NODE_DEBUG node experiments/rum-local/readback.mjs <UUID> <macos|windows|ios|android>
```

两个脚本均不修改配置、限额或权限，不使用浏览器。配置检查要求移动应用仅开启 `customevent`；回读最多查询最近一小时的 100 条 Usage 日志，只输出白名单字段，不输出 IP、设备名、authToken 或原始响应。查询达到上限时失败，不把截断结果视为完整结果。

回读：`node experiments/rum-local/readback.mjs <UUID> <macos|windows|ios|android> [local|prod]` 核对一次探针；`node experiments/rum-local/readback.mjs --launches <平台> <分钟>` 列出正式环境最近的真实启动（设备标识只输出短哈希）。脚本经 git 找到主工作区的 `.env` 与接口库，worktree 里也能用。

`ingestionPassed` 验证五类事件各一条、对应 AppID、期望环境、固定字段与有界计数；`mainlandGeoVerified` 单独表示云端地区字段是否为中国。移动日志地区为空时，不能把入库成功当作云端地区证明。网络、线路、地域和运行时证据见[验证记录](../../docs/verification-rum-analytics-2026-10-16.md)。

## 正式配置实网验证

- macOS：`RAWLAB_RUM_TARGET=production RAWLAB_RUM_VALIDATION_RUN=<UUID> RAWLAB_RUM_LIMIT_VERIFIED=1 RAWLAB_RUM_NETWORK=china-telecom bash experiments/rum-pilot/local-adapter.sh`。正式包本身：用隔离的 `CFFIXED_USER_HOME` 启动 `build.sh` 产物，再用 `--launches macos` 回读。
- iOS：`bash scripts/rum/prepare-ios.sh` 后以 Release 配置编模拟器包；启动时传 `SIMCTL_CHILD_RAWLAB_RUM_VALIDATE=1 SIMCTL_CHILD_RAWLAB_RUM_VALIDATION_RUN=<UUID>` 只跑探针，不带这两个变量即正常上报。
- Windows：`bash experiments/rum-local/windows/run.sh --publish` 打出不依赖 .NET 的探针包，复制到 Windows 后运行包内 `validate.ps1 -ValidationRun <UUID>`。
- Android：ANDROID_PROBE_PLACEHOLDER

## 本地构建

- macOS：`RAWLAB_RUM_LOCAL=1 RAWLAB_BUILD_DIR="$PWD/.cache/tmp/rum-local/macos-build" RAWLAB_APP_PATH="$PWD/.cache/tmp/rum-local/RawLab Local.app" bash RawLabMac/build.sh`。运行时提供 `RAWLAB_RUM_APP_ID` 与 `RAWLAB_RUM_CONFIG_ADDRESS`；独立五事件探针是 `experiments/rum-pilot/local-adapter.sh`。
- Windows：Debug 构建添加 `-p:RawLabRumLocal=true`（SDK 取共享缓存或 `-p:RawLabRumSdkZip=`）；本地验证模式不能是 Release。Windows 主机上的探针与退出/缓存检查使用 `windows/validate.ps1`，不要在 macOS 上将交叉编译当作原生运行验证。
- Android：`ANDROID_HOME="$HOME/Library/Android/sdk" ./gradlew -PrawlabRumLocal=true :app:assembleDebug :app:assembleDebugAndroidTest`（工作目录 `RawLabAndroid`）。独立包名 `com.rawlab.android.rumlocal`，不覆盖正式包；停止后重新开启需重启进程。
- iOS：见 [iOS 本地验证](ios/README.md)。仅 Simulator Debug、本次专用 bundle；停止后重新开启需重启进程（正式包同样如此）。

发送探针前需操作者确认用量上限、当前大陆电信直连且无代理/VPN。移动探针另需先成功运行配置检查，再显式传入 `RAWLAB_RUM_CONFIG_VERIFIED=1`（Android instrumentation 对应 `rumConfigVerified=true`）。这些标记是运行前确认，不等于工具独立验证了限额作用域。

SDK/官方 API 依赖缓存留在主工作区 `.cache/shared/`，SDK 由 `scripts/rum/` 下的脚本按固定版本与 SHA-256 准备。临时构建、SDK 日志和测试 sandbox 验证后清理，不保留真实照片或 SDK 缓存。项目保留 GPLv3，并有版权人授权的[当前四端 SDK 链接例外](../../LICENSE-ALIYUN-RUM-EXCEPTION)；例外不授予供应商权利，供应商 SDK 的再分发条件由版权人负责确认。
