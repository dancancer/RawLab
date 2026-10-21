# RawLab MCP

本地 stdio 服务，把五个 MCP 工具映射到已有的 `sony2fuji` Agent CLI。它不实现像素算法，不打开网络端口，也不会修改 MCP 客户端的全局配置。

## 安装和启动

需要 Python 3.11+、`uv` 和支持 Agent recipe v4 / result protocol v1 的 RawLab CLI。官方 Python MCP SDK 固定为 `2.2.0`，间接依赖由 `uv.lock` 锁定。CLI 可以使用项目构建或已校验的发布包；普通桌面应用路径不能代替 CLI 可执行文件。

从仓库根目录安装：

```sh
uv sync --project tools/mcp --frozen
```

客户端以 stdio 子进程运行：

```sh
/absolute/repo/tools/mcp/.venv/bin/python -m rawlab_mcp \
  --cli '/absolute/RawLab CLI/bin/sony2fuji' \
  --read-root /absolute/photos \
  --read-root /absolute/looks \
  --write-root /absolute/exports \
  --timeout 120
```

`--cli` 和所有根目录必须是绝对路径；根目录必须已存在。`--read-root` 与 `--write-root` 可重复。CLI 必须是自己信任的本地程序。默认每次 CLI 调用超时 120 秒，`--timeout` 接受有限正数。

配置格式示例见 [macOS](examples/macos.json) 和 [Windows](examples/windows.json)，请替换占位路径后手动加入支持 `mcpServers` 的客户端。其他客户端按其配置格式填写相同 command/args。Windows 的 Python 位于 `.venv\Scripts\python.exe`，CLI 通常为 `sony2fuji.exe`。

## 工具

| MCP 工具 | 参数 | CLI 映射 |
| --- | --- | --- |
| `capabilities` | 无 | `--capabilities --json`，启动时协商并缓存 |
| `validate_recipe` | `recipe_path` | `--recipe PATH --print-recipe --json` |
| `image_info` | `image_path` | `--info PATH --json` |
| `render_preview` | `recipe_path`、`output_path`、可选 `long_edge`（默认 1280） | `--recipe PATH --preview PATH --long-edge N --json` |
| `export_photo` | `recipe_path` | `--recipe PATH --json` |

工具参数中的路径必须为绝对路径。recipe 内的 input/look/output 相对路径以传入 recipe 路径的目录为准，包括 recipe 本身为符号链接的情况。所有路径解析后检查允许根；引用路径不能借软链接逃逸。`long_edge` 必须为正 uint32，多余参数会被拒绝。

`validate_recipe` 只读取 recipe，保留 CLI 标准化结果中的相对路径；不要求引用的源图、外观或输出目录已存在。引用路径仍须位于配置的允许根内。校验原 JSON 的重复键、未知字段、范围、版本和类型由原 CLI 完成，不能通过 Python 重写绕过原 parser。

preview/export 要求源图和外观文件存在，输出父目录存在。每次请求在输出目录创建私有暂存目录；CLI 成功且实际文件匹配后，以同文件系统 hard link 无覆盖发布。已有目标或目标软链接会拒绝，禁止覆盖 recipe、输入和外观。文件系统不支持 hard link 时返回失败，不降级为覆盖写入。取消或超时终止该请求的 CLI 并清理自己的暂存文件；服务正常关闭也会回收仍在运行的 CLI。强制杀死服务或断电不提供自动恢复，应检查遗留 `.rawlab-mcp-*` 目录后再清理。

工具返回 JSON text 和同内容的 `structuredContent`，保持 CLI 的 `protocol_version/command/ok/result/error` envelope，失败标记 `isError=true`。MCP 的 `image_info/render_preview/export_photo` 对应 envelope command `info/preview/export`。CLI 错误保留 code/status；MCP 路径/参数限制使用 `invalid_argument`，超时或协议错误使用 `processing_error`。日志和诊断只使用 stderr。

服务目前只宣告 recipe v1～v4；CLI 未来增加 v5 不会让此适配层提前宣告支持。路径限制用于本地工具的授权范围，不是对恶意本地程序或并发文件系统攻击的操作系统隔离。

## 验证

```sh
uv run --project tools/mcp --frozen python -m unittest discover -s tools/mcp/tests -v
```

默认运行 fake CLI / 真实 SDK stdio 协议测试。要运行真实 CLI 对照，请显式提供可执行文件：

```sh
RAWLAB_MCP_CLI='/absolute/RawLab CLI/bin/sony2fuji' \
  uv run --project tools/mcp --frozen python -m unittest discover -s tools/mcp/tests -v
```

该测试使用仓库已有的微型 DNG fixture，在系统临时目录验证五工具、直接 CLI 的标准化结果与 preview/export PNG 字节、源文件不变、未知字段/重复键拒绝，并在结束时清理。它验证指定 CLI 的兼容性，不代替当前 C++ 源码的构建测试。

macOS 已覆盖真实 stdio、取消、并发目标保护和 v0.8.1 发布 CLI 对照。Windows 配置样例尚未在 Windows 执行；其进程终止、NTFS hard link、Unicode 路径和真实 CLI 对照仍是平台验收项。当前受信任 CLI 不应启动外部子进程；POSIX 回收进程组，Windows 当前只回收直接 CLI 子进程。
