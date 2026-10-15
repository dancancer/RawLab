# iOS 0.8 本地 PR 准备

拟用标题：**feat(ios): add native adjustment controls and iPad editor**

完整正文：[ios-v08-pr-body.md](ios-v08-pr-body.md)，可直接用作 `--body-file`。目标 `development`，源分支 `codex/ios-editor-v4`。产品/测试审查快照为 `1393423385f40d29bb4f025511ccf3eefae57fa9`；本报告所在的收尾提交仅补 PR 材料与证据归属勘误，不改变该产品/测试源码。

截至 2026-10-15（Asia/Shanghai），本地准备无实质阻塞，尚未执行 push、创建远端 PR、合并或发布。原有推送/草稿 PR 确认待答，本报告不是该批准。

## 目标与合并条件

只读 `git ls-remote origin refs/heads/development` 和 GitHub branch API 两路均返回 `440b9788ff4cfd8a3f5dfa781b16a33997ccd801`，与本地 `origin/development` 一致。查询时 GitHub `protected=false`，不据此绕过授权或把 CI 门禁视为已通过。

`git merge-base --is-ancestor <target> 1393423` 返回 0，`git rev-list --left-right --count <target>...1393423` 为 `0 10`。因此当前目标没有额外提交，图上可直接 fast-forward、没有需要解决的三方文本冲突；没有实际执行 merge 或改动 refs。PR 尚未创建，未获得 GitHub PR mergeability/托管 CI 结果。

只读查询同源同目标的全部 PR 状态返回空列表；远端也没有 `refs/heads/codex/ios-editor-v4`。后续执行获批动作前仍需检查是否已有 PR，避免这份快照之后重复创建。

只读核对命令：

```sh
git ls-remote origin refs/heads/development refs/heads/codex/ios-editor-v4
gh api repos/dancancer/RawLab/branches/development
gh pr list --repo dancancer/RawLab --state all --head codex/ios-editor-v4 --base development
git merge-base --is-ancestor 440b9788ff4cfd8a3f5dfa781b16a33997ccd801 1393423385f40d29bb4f025511ccf3eefae57fa9
git diff --check 440b9788ff4cfd8a3f5dfa781b16a33997ccd801...1393423385f40d29bb4f025511ccf3eefae57fa9
```

## 完整范围与历史内容检查

产品快照相对目标为 10 提交、55 文件、`+6182/-575`：

| 范围 | 文件数 | 行变更 |
|---|---:|---:|
| iOS 产品、工程和六语言资源 | 27 | +2489/-553 |
| iOS 测试与脚本 | 14 | +2691/-6 |
| iOS 设计扩展、验证/复核记录 | 14 | +1002/-16 |

独立只读核对覆盖全部 10 提交和净 diff，不只是最终工作树：

- 历史新增 blob 共 92 个、1,301,865 字节，均为文本；最大对象是历史 PBX，58,412 字节。全部历史路径恰好为这 55 个，没有中途加进又删除的其他路径。
- 没有 RAW、照片、录屏、截图、构建包、生成大文件意外进历史。针对全部 92 个 blob 的私钥、常见服务 token 和明显凭据赋值模式扫描无命中。
- 完整历史未改 Shared、lutools、macOS/Android/Windows 或 CI 源码。iOS Core 的改动仅属于已授权的导入锁/请求身份及回调发布保护；没有处理算法或持久化格式改动。
- `DESIGN.md` 的新增部分是明确标记的 iOS/iPadOS 段落和 iOS frontmatter；去掉新增部分后 macOS 原文逐字一致，仅末尾多空行。`.impeccable/design.json` 与 surface 也限定 iOS/iPadOS。
- PBX 新增的 13 个 Swift 引用均已跟踪且存在。32 条跨目录资源/源码引用与 base 完全相同，分别为 Shared 8、RawLabMac 12、lutools 12；没有新增跨平台耦合。
- 原生截图保留在忽略目录，未跟踪。README 的相对 PNG 链接仅能在持有本地证据的环境查看，不能称远端 PR 附件。

本次收尾另增加本报告与 PR 正文两份文本，并勘正既有报告中两项旧 UI 的来源。该 docs-only 增量不改变以上产品/测试范围，不为它重跑 native/RAW 全套；最终分支共 11 提交、57 个净变更文件。

## 已落地依赖与构建前提

| 依赖 | 当前状态 |
|---|---|
| #50：RAW 编辑缓存 | 已合入 development，merge `dd634415377607582c59ff35d483551041883d79`；是当前 target 的祖先 |
| #51：透视参数接入 | 已合入 development，merge 即 `440b9788ff4cfd8a3f5dfa781b16a33997ccd801`；本分支直接基于它 |
| Shared Swift、film/master-recipe artwork 和 LUT 资源 | 原有 PBX 引用与目标完全相同，全部存在；本分支不改这些来源 |
| `sony2fuji.xcframework` | 既有忽略构建依赖，未进 Git；本地测试使用已知 #51 来源的 arm64 device 和 arm64 simulator 两片 |

现有通用构建入口是 `bash lutools/build.sh ios`，验证入口为 `bash lutools/platform/ios/verify-framework.sh`。标准验证要求 arm64 device 与 arm64/x86_64 通用 simulator、许可证、资源与系统动态依赖。本轮现有测试 framework 不是该完整通用包，不能宣称发布打包已验收。没有为本次文档准备重建共享依赖，也不修改共享 build owner 的脚本。

无额外未合入的共享接口、其他平台设计或功能 PR 前置依赖。后续目标移动若触及 iOS 入口或资源，按实际冲突/语义影响补定向组合验证。

## 准确验证矩阵

| 源码 | 已有结果 | 可复核证据 |
|---|---|---|
| UI 实现阶段，最终 `146fabf17ff8f8ba1de3284c727de9a4891d1925`，文档 `3f87abb5d2188e36c3bbdfafe4ed070f71cffda6` | wheel、刻度/精调、草稿/配方/HSL、iPad/旋转/AX 的分次定向通过；部分首轮失败后定向修复 | `.impeccable/review/ios-editor-v4/README.md` 和 finish-before/after；其中 phone-finish-sheet 整次失败，只计其中 JPEG 单项及后续 AX 修复复测，不称整个旧套件通过 |
| `e63a30f52ac4b6c6be2c81eb18a19d56004cd9b2` | 作者 167 状态、4 项原生触控、3 组尺寸回归 | `docs/ios-v4-import-lock-verification-2026-10-14.md`、`/tmp/rawlab-ios-v4-import-state-complete.log`、`/tmp/rawlab-ios-v4-crop-lock-r2/crop-lock-ui.log`、`/tmp/rawlab-ios-v4-import-viewport-r2.log` |
| 精确 e63 独立复验 | 167 状态＋13 RAW 迟到断言＋3 组尺寸；4 触控＋5 完整应用 RAW，共 UI 9/9，零失败/跳过；实际 JPEG RGBA 与 FINAL 一致、DNG 全文件一致 | 独立报告提交 `1ad455605479723f9140797671307a01213f5b31`；本地完整报告 `/Users/xupeng/mycode/rawtools/build/ios-v4-raw-validation/docs/verification-ios-v4-import-lock-2026-10-14.md`，同树 `build/import-lock-validation/verification-summary.json` 及原始日志 |
| 较早 UI 构建 | 既有裁剪/几何两用例确实 2/2，但 `/tmp/rawlab-ios-v4-derived` 早于最终 r2；不计为精确 e63 的最终重跑 | `/tmp/rawlab-ios-v4-import-existing.log`；独立报告已明确来源勘误 |
| `3fa6ed5b9228cc71bf50241bcde3f441a478b3d0` | 空态两端共 4/4；24 普通语言/方向组合、4 最大字号组合、28 次打开/取消 | `/tmp/rawlab-ios-v4-empty-copy-confirm-{phone,ipad}.log/.xcresult`，README 空态章节 |
| `1393423385f40d29bb4f025511ccf3eefae57fa9` 的产品/测试内容 | 两端各 3/3 获取取消用例、实际 retained 目录为空；原始 3fa 同图重选失败后修复 | `docs/ios-v08-picker-acquisition-cancel-2026-10-15.md`、`/tmp/rawlab-ios-v08-picker-fixed-{phone,ipad}/` 的日志、manifest、实际目录清点；manifest 记录构建时 3fa 基线加一行修复，内容摘要与 139 完全一致 |
| 精确 139 | 本次补存 54 项刻度数学/轮值/意图/事件/动效断言，通过 | `bash RawLab/tests/adjustment-scale.sh`；`/tmp/rawlab-ios-v08-pr-adjustment-scale.log` |

e63→139 的产品差异仅为 `ContentView+Panels.swift` 空态展示、`ContentView+Helpers.swift` 取消时清选择；Core、Shared、lutools 无后续差异。保留 RAW 验证范围，同时明确没有在 139 重新执行真实 RAW 全链。

所有 UI 与原生容器结果均为本地 Xcode 27 / iOS 27 arm64 Simulator，未当作 CI 或真机通过。默认未启用容器的 4 项 crop / 3 项 picker 跳过不计为通过。独立 RAW 报告、原始日志、截图和输出仍由协调任务在本地保留，没有复制私有 RAW、照片或大包进本分支。

## 后续验收与发布门禁

当前无证据支持阻止源码进入审查。以下边界必须保留，而不是用未跑的测试阻塞本地准备或抹去已通过结果：

- **后续 provider 验收**：真实系统文件取得已经走过；门后返回等待与 UIKit 生命周期是测试设施，不覆盖 provider 自身等待、iCloud、RAW resource fallback、真实 provider 晚失败、多窗口重建或进程终止。合成失败清理由测试门负责，不能冒充生产失败清理。
- **后续设备验收**：签名真机安装、触觉品质、实机帧率/延迟、硬件 VoiceOver/Switch Control。模拟器可支持代码审查，不能替代这些结论。
- **保留跟踪的警告**：e63 `RawExports.log:363` 在关闭 JPEG 成功提示后有一次 SwiftUI 发布警告，尚未定位；实际两种导出和后续 Reset 通过。139 取消流程所采日志无该记录，不能据此关闭问题。
- **PR/合入门禁**：获批发布分支后，核对实际 PR 源/目标 SHA、是否已有同源 PR、托管检查和目标变化带来的受影响组合。当前祖先关系仅证明图上无文本冲突，没有远端 approval 或 CI 结果。
- **发布包验收**：签名、依赖/许可证闭包和实际设备结果应绑定最终发布源；本地 arm64 测试 framework 不等同通用 release 包。本任务不创建 release 分支、标签、IPA 或对外发布。

## 提交列表（产品快照完整 10 提交）

按实现顺序，从 development 到 139：

| SHA | 主题 |
|---|---|
| `43b03f72c8447e66867d6154ec57fad254f19d7f` | Add native iOS adjustment ruler, value wheel, and iPad editor |
| `c52f59bc6b27e66af0e9c37b01668068c90e1f03` | Fix native iOS ruler intent and accessible parameter interactions |
| `e190c65b30d5b49292f3dbe85bb8029cfcd2cc56` | Preserve accessible editor space and explicit draft exit actions |
| `b296b0094dc3d58c07718ba15bffb1f56c2e06de` | Keep native value wheels visible through rotation and preserve active ruler input |
| `146fabf17ff8f8ba1de3284c727de9a4891d1925` | Preserve native wheel context and block export from active editor drafts |
| `3f87abb5d2188e36c3bbdfafe4ed070f71cffda6` | Document scoped iOS design and native verification evidence |
| `92afb1b3d78a4fb82834daba8943898376e22dbe` | Prevent crop edits and stale results during photo import |
| `e63a30f52ac4b6c6be2c81eb18a19d56004cd9b2` | Record import lock regression and independent review evidence |
| `3fa6ed5b9228cc71bf50241bcde3f441a478b3d0` | Simplify iOS empty editor copy and import label |
| `1393423385f40d29bb4f025511ccf3eefae57fa9` | Reset photo selection after acquisition cancellation |

第 11 个提交即本报告/PR 正文与证据勘误的 docs-only 收尾提交。最终接收 SHA 由本地提交输出交接，产品/测试内容仍精确对应 139；可用 `git log --reverse --format='%H %s' 440b9788ff4cfd8a3f5dfa781b16a33997ccd801..HEAD` 取得包含该文档提交的完整列表。
