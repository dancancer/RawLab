# RawLab 开发流程

本文件适用于整个仓库。后续开发采用 Gitflow；原有 `codex/*` 分支是历史工作，
不为统一命名而重写、删除或迁移其他人的分支。

## 长期分支

- `main`：已发布、可交付版本。普通功能不得直接提交或合入此分支。
- `development`：下一版本的集成分支，也是普通功能 PR 的默认目标。
- 新工作开始前刷新相关远端引用，以远端目标分支为基准，不假定本地分支已更新。

## 功能开发

1. 从最新 `origin/development` 创建 `feature/<short-name>`。
2. 使用独立 worktree；优先使用宿主提供的 worktree 工具，保留已有工作目录和未提交改动。
3. 先确认相关代码、目录级约定和共享接口，再实现有针对性的回归测试及最小充分改动。
4. 提交前运行影响范围对应的验证，选择性暂存本次拥有的文件；不提交 RAW 样片、凭据、
   本地截图、构建目录或其他生成产物。
5. 经用户授权后 push 分支并创建目标为 `development` 的 PR。创建前检查是否已有同源 PR，
   不重复创建。PR 说明改动、验证结果、风险和未验证平台。
6. 合入前核实 PR 的源提交、目标分支、冲突状态及 CI；不得把本地通过称作 CI 通过，
   不绕过保护规则。目标分支变化影响本次代码时，更新分支并重验受影响流程。
7. 仅在用户明确授权合入后执行合并。完成后核实远端目标包含提交；清理 worktree 或分支
   前确认不含未保存工作和必要产物。

尚未发布的个人功能分支可在更新基线时 rebase。已共享的分支不要自行重写历史；
push 被拒绝时先核对远端变化，不默认 force-push。

## 版本发布

1. 从已验证的 `origin/development` 创建 `release/<version>`，例如 `release/0.5.1`。
2. 发布分支只做版本号、打包、发布文档和必要的发布修复，不混入新功能。
3. 完成目标平台构建、测试和发布验收；未覆盖的设备或平台必须明确记录。
4. 经用户明确授权后通过 PR 合入 `main`，为发布提交创建 `v<version>` 标签，并将发布修复
   回合到 `development`。不得用新发布覆盖已有标签。
5. 上传安装包、创建 Release、签名或部署均需要相应授权；采用 Gitflow 本身不代表授权发布。

## 紧急修复

1. 从最新 `origin/main` 创建 `hotfix/<short-name>` 或 `hotfix/<version>`。
2. 仅修复已发布版本的紧急问题，补充可证明问题的测试和必要版本更新。
3. 经授权通过 PR 合入 `main` 并创建新版本标签，同时把修复回合到 `development`。
4. 若有进行中的 `release/*` 也受影响，将必要修复同步到该发布分支并验证。

## 项目验证

- 共享 C++ 核心遵守 [lutools/AGENTS.md](lutools/AGENTS.md) 和
  [颜色与渲染契约](lutools/docs/color-contract.md)。Mac 已配置构建可运行
  `ctest --test-dir lutools/build-macos --output-on-failure`。
- iOS 遵守 [RawLab/AGENTS.md](RawLab/AGENTS.md)，使用其现有构建与平台测试。
- Mac 使用 `bash RawLabMac/build.sh` 及受影响的 `RawLabMac/tests/` 检查。
- Android 使用 `RawLabAndroid/` 的 Gradle 测试、构建及相关设备/GLES 验证。
- Windows 使用 `RawLabWindows/` 的现有构建和测试；没有硬件 GPU 时不声称已完成硬件验证。
- 纯流程文档修改只检查内容、链接和 diff，不机械执行全平台构建。

公共参数、持久化格式和渲染效果跨平台一致。修改共享 C ABI 时检查各客户端调用方；
GPU Auto 保留 CPU 回退，Force 不伪装 GPU 成功。保留原始 RAW 和无关改动。
