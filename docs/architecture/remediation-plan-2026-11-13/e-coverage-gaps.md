> 返回索引：[RawLab 综合整改任务清单](../remediation-plan-2026-11-13.md)

# E. 覆盖缺口与不确定项

### E.1 沿用复审 §7 的缺口

- 两份文档和本计划都只做了静态读码，没有构建、测试或运行应用。“推断”和“沿用主评审”标注的行没有在本次重新验证。
- 界面层（SwiftUI、Compose、WPF 重组）没有量化；着色器与 CPU 公式没有逐行对照；`x3f-bridge` 的 dp1s 细节和 `AbiLayoutChecks.cs` 内部没读。
- GitHub 仓库设置（是否公开、fork 是否需审批、CI result 是否是分支保护必需项）无法离线核实，它决定 R16 的严重度。W1 的线上发布文件名同理。

### E.2 本次核实发现、两份文档都没覆盖的

1. **L1：AX 静默跳过**。`HDRRenditionUITests.swift:79-81` 在没有授权时 `return`，而 `hdr-rendition-ui.sh` 在 CI 模型套件里（`scripts/ci/apple-models.sh:12`）。注释说“CI 自托管 runner 有授权”，这一点无法离线确认；授权一旦丢失，CI 会绿着空跑。另外，`hdr-rendition-ui.sh` 和 `ios-reset-entry-ui.sh`（`:24`）都是 UI 类测试却在 CI 里跑，与根目录 AGENTS 的“CI 不重复执行 UI 测试”字面上冲突，需要协作规范给个说法。
2. **L2：Windows `Adjustments.ResetAll()`** 仍然清空 HDR，只有测试在调（`Adjustments.cs:370`）。测试验证的语义与生产路径不同，复审正是被它误导，才得出“Windows 漏半条”的结论。
3. **L3：#268 新增的门禁闭包**每次求值都整读预设库和外观库（推断有每秒轮询，没有测量）。
4. **L4：#267 的三段抽样**每一项都在锁内遍历全部历史任务；“3×64KiB 加元数据一致就复用原件”的误判风险没有写进文档。
5. **#266 的 `TempCleanupTests`** 在 `RawLabWindows/tests/usage/` 工程里，是否进 CI 没有找到证据（`scripts/` 和 `.github/` 里搜不到 `tests/usage`）。
6. **Android 和 Windows 的重置入口**（主 §14.8 行10）至今两份文档都没核对。
7. **#264（Android 手动清理系统相册副本）是新功能**，两份文档都没评审：删除前是否核对编辑记录引用，没有细读（只看到 `SystemPhotoStore.kt:113-142` 的 inspect、clear、list）。
8. **#260（Android 联机）在复审基线之后才合入**，复审没有覆盖；本次只核对了提交说明和测试规模（`CameraTetherLivenessTest.kt` 778 行），没有逐行审。

### E.3 文档与代码不符（以 0cf4a88a 为准）

| 文档说法 | 实际 | 证据 |
|---|---|---|
| 台账：#267 覆盖 I14/A12 | #267 只改了 iOS 文件，A12 未修 | `git diff --stat d05c8d7d 0cf4a88a` 里 #267 涉及的全部是 `RawLab/` 下的文件；`CameraIncrementalImport.kt` 191d8aba 之后没有相关提交 |
| 主 §14.9：#250 对应 A17、A18 | #250 没改 Android 文件 | `git diff --stat 6b5e7783^1 6b5e7783`（5 个文件，都是 Mac、iOS、Shared） |
| 复 §4.2：Windows ResetAll 仍丢休眠 HDR | 生产路径已保留 | `EditorAdjustmentRules.cs:100,106` 与 #255 的 `Defaults` diff；`tests/editing/HDRChecks.cs:134-158` |
| 复 C-N3：fdopen 会清掉 O_CLOEXEC | macOS 上不会 | `/tmp/lead-plan/cloexec.c`：fdopen 前后 FD_CLOEXEC 都是 1 |
| 复 I-N9：#258 的 harness 可能不进 CI | 已经进了 | `RawLab/tests/camera-originals.sh:13`，加上 `scripts/ci/apple-models.sh:23` |
| 复 R-N4：基线查询只接受 run_attempt==1 | 代码里没有这个过滤 | `git grep attempt` 在 d05c8d7d 和 0cf4a88a 上都是 0 命中 |
| 复 A-N1 路径 `editor/EditorEditStore.kt` | 实际在 `editor/storage/EditorEditStore.kt` | `git grep 'class EditorEditStore' 0cf4a88a` |
| 复 C-N7 路径 `tools/abi-layout/…` | 实际在 `lutools/tools/abi-layout/…` | `git ls-tree` |
| 复 §4.1 W1 路径 `UpdateRelease.cs`（放在 Updates 目录下引用） | 实际在 `RawLabWindows/UpdateRelease.cs` | `git ls-tree` |
| 主 R13：109 处本机路径 | 现在是 26 个文件、102 处 | `git grep -c /Users/xupeng 0cf4a88a` |

### E.4 不确定项

- C-N3 在 Linux 和 Android 上没有实测，“不会清标志”是按 libc 语义推断的。
- R16 在合入 #265 之后“macOS 也会变红”是按 `verify()` 代码推演的，没有用 fork 事件实际触发。
- 状态为“未修”且依据写“沿用主评审”的行（多为 P3 性能项），本次只确认了相关文件之后没有对应 PR，没有逐行重读。
