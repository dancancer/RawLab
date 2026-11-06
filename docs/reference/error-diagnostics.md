# 错误日志格式

iPhone 和 iPad 用户可以从报错弹窗或「更多 → 导出错误日志」将本机记录存为 JSON。
日志保存在设备上，最多保存最近 64 个事件。iOS 记录应用捕获的错误，由用户手动导出。

## JSON v1

顶层 `schemaVersion` 为整数 `1`，`events` 按发生顺序排列。

- `timestamp` 为 UTC 的 ISO 8601 时间。
- `environment` 包含 `platform`、`appVersion`、`build`、`osVersion` 和 `deviceModel`，均为字符串。`platform` 可取 `ios`、`macos`、`windows`、`android`。
- `operation` 为操作分类，如 `photoImport`、`preview`、`photoExport`、`lookImport`、`batchExport`、`editPersistence`、`adjustment`。
- `stage` 为该操作内的阶段，`attemptID` 为可选 UUID，用于串起同次任务的事件。
- `outcome` 为 `failed` 或 `succeeded`。iOS 仅在一次导入失败后额外保留下一次成功导入。
- `context` 为平台提供的技术字段，键和值均为字符串。导入示例包括 `entryPoint`、`extension`、`declaredType`、`providerType`、`detectedType`、`sourceKind` 和 `bytes`。`detectedType` 表示系统解码器识别到的类型。
- 失败事件的 `error` 包含 `domain`、整数 `code`、`underlying` 原因链，以及可用时的 `native.status`、`native.reason`、`native.field` 整数。成功事件省略 `error`。

读取端应忽略未知字段，并容许可选字段缺失。新增字段沿用版本 1，破坏兼容的更改需提升 `schemaVersion`。
导出格式仅记录排查需要的技术字段，排除原片、预览、文件名、完整路径、账号标识及任意错误正文。
`extension` 仅保留已知照片格式的后缀，其他后缀记为 `unknown`。可能包含后缀信息的动态类型标识也会过滤。
