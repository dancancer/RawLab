# 故障诊断日志录制与上传契约

## 目标与隐私边界

四端（macOS、iOS、Android、Windows）提供统一的**手动开启、有界录制、用户主动交付**排障机制，辅助定位导入失败、显影异常、GPU 回退、AI 降噪报错与导出问题：

- **默认关闭**：未开启「记录详细诊断日志」时，热路径仅检查内存原子位，不产生步骤日志或磁盘写入；既有致命错误摘要（`recent-errors.json`）继续按有界环形缓冲保留最近失败码。
- **有界录制租约（防遗忘常驻）**：用户手动开启开关后，生成会话诊断码 `RL-YYYYMMDD-XXXXXXXX`，写入本地租约（有效期 **30 分钟**，且允许跨越 **1 次应用重启** 以覆盖冷启动或恢复类故障）。超时或第二次重启后自动归位为关闭，已录制的最近一次会话保留在本地供导出或上传。
- **严格隐私脱敏**：不采集任何图像像素、缩略图、照片文件名、完整个人目录路径、相册标识符、EXIF GPS/序列号、设备个人命名或 AI 提示词/密钥。异常文本与上下文统一将已知主目录/临时目录/外置存储及带空格子路径整段擦除（替换为 `<user>`、`<temp>`、`<app>`、`<path>` 等），将裸媒体文件名替换为 `<file>.<ext>`，并对未知文件后缀掩码处理。
- **网络与云端边界**：平时录制及导出本地 `.zip` 完全离线运行，零网络请求；仅当用户主动点击「一键云端上传」时，客户端向阿里云上海 SLS WebTracking 端点发送单次 HTTPS 请求。客户端报文自身不读取或写入网络地址，阿里云 SLS 接入网关会按常规 HTTPS 服务自动记录请求源 IP（随 Logstore **14 天**生命周期到期自动清除，开发者拉取工具在回读落盘时自动剥离该服务端字段）。

## 诊断包结构（Schema v1）

无论是通过「保存到设备 / 分享诊断包」导出的 `RawLab-Diag-<诊断码>.zip`，还是通过云端拉取脚本还原的本地目录，均包含相同的核心文件：

| 文件名 | 内容说明 |
| :--- | :--- |
| `manifest.json` | `schemaVersion: 1`、`reportID`、生成时间、应用版本与构建号、系统版本、架构/机型代号、步骤条数与裁剪计数、可选用户简述（≤ 200 字） |
| `breadcrumbs.jsonl` | 开关开启期间按序记录的结构化步骤（`timestamp`、`seq`、`level`、`category`、`stage`、`message`、`context`），总上限 `500` 条 / `450 KB`（超出时保留会话头部与最新尾部） |
| `recent-errors.json` | 最近有界错误记录（最多 64 条），覆盖用户在打开录制开关前已触发的错误码 |
| `README.txt` | 包内文件用途与隐私排除说明 |

## 阿里云 SLS WebTracking 云端配置清单

云端通道使用上海地域 SLS `PutWebtracking` 免 AccessKey 写入接口（默认端点：`https://proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai.cn-shanghai.log.aliyuncs.com/logstores/logstore-diagnostics/track`；本地验证可通过环境变量 `RAWLAB_DIAGNOSTIC_UPLOAD_URL` 指向同规格 `.log.aliyuncs.com` 测试库）：

1. 在上海 SLS Project 下创建 Logstore：`logstore-diagnostics`（建议选择「按写入数据量计费」，享 30 天免费热存储）。
2. 开启 **WebTracking** 开关（允许客户端免签名 `POST /logstores/logstore-diagnostics/track`）。
3. **防刷封顶必配项**：
   - Shard 数量设为 **`1`**，**关闭「自动分裂」**；
   - 数据保存时间设为 **`14 天`**（不超过 30 天）；
   - 开启索引：为 `report_id`、`platform`、`app_version` 配置键值索引（`report_id` 大小写不敏感或精确匹配）；
   - 配置单日写入量监控告警（如单日写入 `> 100 MB` 发送通知）。
4. 若操作者本机 `.env` 中的只读 RAM 用户权限按单库授权，需为该 RAM 用户补充 `logstore-diagnostics` 的只读查询权限（`log:GetLogs`）；客户端不存放任何 AccessKey。

## 开发者拉取诊断日志

当用户提供诊断码（例如 `RL-20261124-8F3A92C1`）时，在主工作区已配置 `.env` 只读凭证与 `.cache/shared/aliyun-sls-api/1.2.6` 的开发机上运行：

```bash
env -u DEBUG -u NODE_DEBUG node scripts/diagnostics/fetch-report.mjs RL-20261124-8F3A92C1
```

脚本验证诊断码格式、自动按日期窗口查询上海 SLS、按 `chunk_index` 重组分片并剥离服务端附加的 IP 元数据，将完整的 `manifest.json`、`breadcrumbs.jsonl` 与 `recent-errors.json` 还原至 `.cache/tmp/diagnostics/<诊断码>/`。
