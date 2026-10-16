# 阿里云 RUM 中国区接入小样

本目录只验证原生 SDK 和采集链路，不改变 RawLab 的四端应用，也不接入照片处理核心。
目前只支持在 macOS 运行。云端查到测试事件后，才可以评价该次网络的上报结果。

## 当前状态

| 检查项 | 结果 |
| --- | --- |
| 配置校验与固定事件载荷测试 | 已通过 `bash experiments/rum-pilot/test.sh` |
| 官方 macOS 0.4.4 SDK 编译链接 | 已通过 `run.sh --help` 和合成配置 `--check` |
| 云监控 2.0 与 ARMS RUM 开通 | 已由账号所有者分别完成 |
| 专用应用、地域、AppID、ConfigAddress | 已创建 `rawlab-rum-pilot-macos`，华东2（上海）`cn-shanghai`；配置已在控制台取得，不写入源码 |
| 云端每日限额 | 2026-10-16 账号所有者确认已设置 `1 OCU/天`；未通过 API 回读验证作用域与停止动作 |
| 测试网络 | 用户确认本机为中国大陆电信直连；发送前仍须检查代理状态 |
| 大陆网络实际发送与后台查数 | 已通过一次中国电信直连测试，SLS 精确匹配 1 条合成事件；不代表全运营商长期可用 |
| 四端正式接入与 SDK 再分发许可 | 已完成业务入口与默认关闭控制；真实 SDK 未放行，分发许可/源码条件仍需确认，尚未上线四端 |

## 云端准备

1. 账号所有者在控制台阅读协议并分别开通云监控 2.0 和 ARMS 用户体验监控。
   不能把免费额度理解成不会收费。
2. 创建专用测试工作空间和 macOS 应用，建议命名 `rawlab-rum-pilot`，选择中国大陆地域。
   不采集现有应用，不修改其他项目的采集配置，不创建 AccessKey。
3. 查看该版本控制台的用量/限额设置，先核实作用域是否包含同产品同地域的其他应用。
   尝试设置 `1 OCU/天` 并选择超限停止、不自动恢复；以页面实际允许的值为准。
   若最小值更大或设置会影响已有应用，先报告差异，不擅自提高预算或修改共享限额。
4. 重新读取页面确认已保存限额和停止动作，再复制该应用的 AppID、ConfigAddress 和地域。
   文档没有给出严格零超额保证，限额不等同于精确的人民币费用封顶。
5. 如果服务要求先上报才能配置限额，不绕过小样的保护开关；先确认新的费用控制办法。

2026-10-15 已完成应用创建。旧 ARMS RUM 的国内地域列表只有杭州，不能用其杭州限额推定保护
CMS2.0 上海应用。2026-10-16 通过 `GetServiceObservability` 只读查询确认上海 RUM 状态为
`Running`、`feeType=session`、`quotas={}`；这不证明账号级没有其他限额。
当前应用位于上海默认工作空间，并非新建专用工作空间；限额作用域仍待核实。
用户随后明确允许暂不设置限额，先执行一次小样；本次没有修改任何云端限额或采集配置。
小样完成后，账号所有者确认已设置 `1 OCU/天`。后续不再使用无上限豁免进行验证；
人工确认与先前的 API `quotas={}` 回应分开记录，不将空对象解释为不存在限额。

官方参考：[PC 接入](https://help.aliyun.com/zh/cms/cloudmonitor-2-0/access-pc-platform-application)、
[用量和限额](https://help.aliyun.com/zh/arms/user-experience-monitoring/product-overview/billing-and-usage-query)、
[计费](https://help.aliyun.com/zh/arms/user-experience-monitoring/product-overview/billing-description)。

## 本地运行

仅运行不联网的配置/载荷测试：

```bash
bash experiments/rum-pilot/test.sh
```

在运行进程的环境中设置专用应用配置，不写入源码或提交配置文件：

```bash
export RAWLAB_RUM_APP_ID='<pilot AppID>'
export RAWLAB_RUM_CONFIG_ADDRESS='<pilot ConfigAddress>'
export RAWLAB_RUM_REGION='cn-shanghai'
bash experiments/rum-pilot/run.sh --check
```

`--check` 不调用 SDK 初始化或统计 API，但进程会加载厂商动态库；首次运行可能下载官方 SDK。
下载固定校验值的 0.4.4 包，保存在主工作区 `.cache/shared/aliyun-rum/macos/0.4.4/`，
包被厂商更新后会拒绝运行，不会静默升级。每次从已校验归档重新解包到系统临时目录，
不复用解包后的库。父脚本退出时删除本次 SDK 副本、编译产物和运行缓存，清理失败会报错。

通常应在云侧限额已核实、网络确为大陆运营商直接出口且用户同意发送时执行：

```bash
export RAWLAB_RUM_LIMIT_VERIFIED=1
export RAWLAB_RUM_NETWORK='china-telecom' # 或 china-unicom、china-mobile，必须与实际网络一致
bash experiments/rum-pilot/run.sh --send
```

`RAWLAB_RUM_LIMIT_VERIFIED` 是操作者的确认，不会替你设置或查询云端限额。
若账号所有者明确允许先做未设云端限额的小样，可不设置上述变量，改为：

```bash
export RAWLAB_RUM_ALLOW_UNCAPPED_PILOT=1
export RAWLAB_RUM_NETWORK='china-telecom'
bash experiments/rum-pilot/run.sh --send
```

此分支会输出云端限额未验证的警告，不能用作生产发布配置，也不是费用封顶。
程序拒绝代理环境变量，启动脚本检查系统 HTTP/SOCKS/PAC 代理；这不能识别所有 VPN/TUN、
网关代理或出口位置，必须另外确认实际网络。不要为了通过校验只改运营商标签。

小样每次只提交一个 `rum_pilot_probe` 自定义事件，包含随机 `run_id`、运营商标签、
`schema_version` 和固定计数 `1`。不读取照片、文件名、EXIF、AI 提示词或业务错误日志。
SDK 的 Crash、curl、CEF 自动采集均显式关闭；设备 ID 设置为本次随机 ID，缓存使用独立临时目录。
SDK 仍可能上报系统、启动、会话等预置数据，不能把它描述成完全无标识或总上报量恰好一条。
程序停留 15 秒后关闭 SDK，60 秒看门狗限制单次运行；超时会硬退出，不能保证 SDK 完成关闭或投递。
父脚本负责异常退出后的缓存清理；强制杀死父脚本或断电仍可能遗留临时目录。没有常驻进程或自动重复测试。

SDK 下载包没有许可证文本。本小样不提交或随应用分发厂商二进制，不据此推断正式再分发许可。
四端业务层和发布门槛见 [接入验证记录](../../docs/verification-rum-analytics-2026-10-16.md)。

## 验收

在云监控 2.0 的目标 PC 应用详情中打开“自定义事件”，按 `rum_pilot_probe`、
分组 `connectivity` 和本次 `run_id` 查找明细。记录北京时间、地域、运营商、是否直连、
SDK 退出状态、云端事件次数及属性、限额页面状态。SDK 初始化成功、进程退出 0 或 HTTP 200
都不能代替后台实际收数。事件不可见时先排查，不持续循环发送。

先完成一个已确认大陆直连网络的闭环，再覆盖移动、联通、电信的可用测试网络。
一次成功仅证明该次线路与时间可用，不保证所有大陆网络始终可达；持续性需后续监测。
本地探针结束后没有常驻采集器。云端应用保留以便后续接入；如需停用，先确认单应用开关的作用域，
不要猜测 workspace 级字段或删除尚需复核的云端证据。

## 首次实网结果

- 北京时间：2026-10-16 00:11:44。
- 地域：`cn-shanghai`；用户确认本机中国电信直连，发送前系统 HTTP/HTTPS/SOCKS/PAC 代理均关闭。
- 本地：原生 macOS 0.4.4 SDK 成功初始化、提交一次事件并关闭，进程退出 `0`。
- 云端：通过官方 SLS SDK 的只读 `getLogs` 查询上海 RUM Project 的 `logstore-rum`，
  限定事件名称、分组和时间窗口，返回 1 条候选，精确匹配本次 `run_id` 的记录也是 1 条。
- `run_id`：`49F70C54-2CCA-4663-B81A-35B253A826CA`。
- 明细：`event_type=custom`、`custom.name=rum_pilot_probe`、`custom.group=connectivity`、`custom.value=1`；
  AppID 匹配，`properties` 中的 `run_id`、`network=china-telecom`、`schema_version=1` 均匹配。
- 云端网络归属：`geo.country=中国`、`isp.name=电信`。没有输出公网 IP、设备名称、认证 Token 或 RAM 凭证。
- 已确认 SDK 预置字段仍包含设备、系统、用户/会话、网络和地域信息；正式四端接入前仍需完成隐私披露、
  用户控制和 SDK 再分发许可核实。此结果不等于四端正式接入或全运营商可用性保证。
