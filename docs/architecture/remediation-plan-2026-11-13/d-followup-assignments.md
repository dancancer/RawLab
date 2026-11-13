> 返回索引：[RawLab 综合整改任务清单](../remediation-plan-2026-11-13.md)

# D. 后续分配计划

### 阶段 1：本轮收尾（2 个 PR）

| PR | 内容 | 为什么必须现在做 | 验证 |
|---|---|---|---|
| 1 | 在飞：M10＋14.8 行1–3（Mac/iOS）＋场景向量＋契约文档 | 已在进行；它产出的向量是阶段 2 Android、Windows 移植的唯一规则源。不先合入，三端会各写一遍规则 | 本机 `bash RawLabMac/build.sh`、`RawLabMac/tests/adjustment-transfer.sh`、`RawLab/tests/adjustment-transfer.sh`；CI 跑 macOS 和 iOS 的模型套件 |
| 2 | 在飞：Windows `RuntimeSaveFailureRecovery` 改成确定性注入 | flaky 会让 Windows updateSdk 门禁失去信用，也会挡住阶段 2 的 S6 矩阵测试 | 本机或 Windows runner 循环跑 50 次；CI 手动触发 windows/native |

- 可并行 worker：2（两个 PR 不共享文件）。
- 阻塞点：PR 1 的规则文档要先确认“来源不是 RAW 时不产出只对 RAW 有意义的字段”与 Mac 现有测试 `AdjustmentTransferTests.swift:568-570` 怎么改（主 §14.6.1a 已给出建议）。

### 阶段 2：下一轮（按平台分组，每个 PR 只解决列出的编号）

| 组 | PR 边界（编号） | 规模 | 验证 |
|---|---|---|---|
| CI | ① R16/R-N2＋L5（verify 适配 fork、显式自托管字段）＋R-N3 ② L1（`RAWLAB_REQUIRE_AX`）＋R5/R-N5（concurrency 带上 inputs）③ R6（Windows 允许名单对账） | 小、小、小 | `python3 scripts/ci/test_workflow.py`、`test_affected_platforms.py`；CI 的 Contracts job |
| Mac | ① M1 ② M2/M-N1＋M-N2（S3 第一段，带计数探针）③ M4/M-N6＋M11（取消）④ M-N7＋M-N3＋L3 小清理 ⑤ S6 矩阵测试复用（只加测试） | 小、中、中、小、中 | `bash RawLabMac/build.sh` 和相关 `RawLabMac/tests/*.sh`；涉及 UI 的先在本机跑 UI 测试（AGENTS 要求） |
| iOS | ① I5 ② I-N1 死代码 ③ I-N4/I-N5/I-N6 相机 ④ I3/I-N2＋I-N3（S3 第二段）⑤ I1 残留（等 Q6） | 小、小、中、中、中 | `RawLab/tests/*.sh` 模型套件；相机部分要真机抽测，记在 PR 里 |
| Android | ① A3 ② A-N1＋A-N10 ③ 14.8 移植：A17＋A18＋白平衡＋镜头（依赖阶段 1）④ A12（等 Q7）⑤ A1（stat 指纹）⑥ 预设库逐条容错 ⑦ A-N9、A-N4、A-N5 小清理 | 小、小、中、中、中、小、小 | `./gradlew testDebugUnitTest`；A12、A1 要真机或模拟器验证相机和冷启动 |
| Windows | ① S6：矩阵测试＋W-N1＋W-N2＋W-N4＋W-N6 ② 14.8 镜头占位 ③ W-N3 预览降级＋L2 死路径 | 中、小、小 | `RawLabWindows/` 现有测试工程；没有硬件 GPU 时不声称 GPU 已验证 |
| 核心 | ① C-N4/C-N5 文档＋编码检查点（S5）② G-N2＋G-N6＋C-N9 ③ S4 枚举进 fixture ④ C2/C6/C7 分块降噪 ⑤ G-N1 Force 错误码统一（先查四端调用方）⑥ C29＋C26 | 中、小、小、中、小、中 | `ctest --test-dir lutools/build-macos --output-on-failure`；④⑥ 需要 Windows 硬件 GPU 和 Android 真机；改共享 C ABI 时检查四端调用方 |
| Shared | S1 编辑记录 golden fixture（规则文档＋fixture），四端 conformance 拆成 4 个小 PR | 中＋4 个小 | 四端快速模型测试 |

- 可并行 worker：**6**（CI、Mac、iOS、Android、Windows、核心各 1 个）。Shared 的 S1 由 Mac worker 兼任，在 Mac ② 之前完成。
- 共享文件 owner：`Shared/*.swift` 归 Apple worker；`Shared/fixtures/` 归 S1 owner；`lutools/include/sony2fuji/ffi/*.h` 归 Core（按 `docs/process/integration-workflow.md` 登记）。
- 验证分层：小 PR 走本机构建加 CI 模型；④ 类 GPU 改动走手动 native 触发和真机；相机类走真机抽测。CI 不跑 UI 测试，UI 测试结果写在 PR 描述里。
- 阻塞点：Android ③ 依赖阶段 1 的 PR 1；Mac ②、iOS ④、Android ⑤ 建议在 S1 之后；Android ④、iOS ⑤ 等 Q6、Q7。

### 阶段 3：先做产品决策（决策人：用户）

| 编号 | 决策问题 | 影响的行 | 建议选项 |
|---|---|---|---|
| Q1 | 超过 128MP 的原生尺寸导出要不要支持？ | C-N1/G-N8、C-N2 | 建议支持到 2.1G 像素的溢出上限，NATIVE 在解码前预检；或者明确不支持，返回尺寸类错误码 |
| Q2 | 仓库接不接受外部 fork PR？ | R16/R-N2、R-N3 | 不接受：在 `docs/process/ci.md` 写明，并让 fork 走“skipped 可接受”；接受：Windows 托管机照常跑 |
| Q3 | `raw_level` 和 `post_rgb` 各自的含义；移动端精度较粗是不是有意的？ | R17、R7 | 字段目录统一定义；不支持该功能的端收到非 0 值时“忽略并提示”还是“拒收” |
| Q4 | 粘贴时来源和目标的处理版本不同怎么办？ | 14.8 处理版本 | 沿用目标版本并提示，或者拒绝 |
| Q5 | HDR 显示映射要不要纳入分组和单项重置？ | 14.6.1d | 纳入“HDR 渲染”分组 |
| Q6 | iOS 和 Android 什么算“可以删”：批量 DNG、相机原件、联机记录 | I1、A2 | 给出保留天数或条数；iOS 是否开 UIFileSharingEnabled |
| Q7 | Android 重连续传要不要照搬 iOS 的三段抽样？ | A12（还有 L4 的风险说明） | 照搬，跨端行为一致 |
| Q8 | Mac 整幅中性参考帧要不要保留？ | M3 | 限制长边，并计入预算 |
| Q9 | 桌面配方生成函数是功能还是测试工具？ | R18 | 测试工具，README 同步改 |
| Q10 | I17 先在真机复现，再决定修法 | I17 | — |
| Q12 | 提交点之后迟到的取消，要不要删掉已完成的文件？ | A-N3、S5 | 保留文件并提示“已完成” |
| Q13 | 更新状态文件的回滚兼容策略 | W-N6 | 旧版读不懂新枚举时降级为 Idle，而不是锁住编辑区 |

- 可并行：决策之间互不依赖，可以一次性评审。决策落地后的实现回到阶段 2 的对应组。
- 阻塞点：没有决策时，对应的实现不开工；只做“把现状写进契约”的文档。

- D 项（IOSResetEntryUITests axTrusted 静默跳过无 SKIP，Q14 同源）：PR #291 不含，随 CI 阶段2 ②「RAWLAB_REQUIRE_AX 强制（L1）」承接（2026-11-14 拍板去向）。

## Mac 手动全套件基线盘点（2026-11-14，mac-suite-inventory，证据 /tmp/rawlab-mac-suite-inv/）
108 脚本：88 绿 / 18 红 / 2 SKIP（source 库）。models-only CI 仅覆盖约 20 个，盲区 88。已知对照 agent-recipe-render（#300 在修）、mac-geometry-draft 计入 18。
- **A 簇（已派 `fix-mac-srclist`）**：10 脚本同根因=硬编码 Swift 源列表缺 `HDRPresentation/HDRDisplay/HDRCameraProfileAssetStore`（ab9be520、6f940269 引入）：compact-controls-presentation、geometry-render、geometry-viewport、mac-perspective-integration、photo-effects-presentation、progressive-render、batch-import-presentation、single-preview-interaction、mac-straighten-preview、update-ui；含共享列表收敛防再犯。
- **B 簇（诊断完毕 11-14）**：B1 master-recipe-render=产品契约已定（basic-controls-v3.md L46-47 Force→unsupported，00aa7e20 漏更测试期望）→ 按 A 案派 `fix-master-recipe-exp` 对齐；B2 mac-lens-draft-presentation=backing scale 测试腐化，已修 **PR #302**；B3 color-grading-input-ui=本 harness 无桌面 AX（AXIsProcessTrusted=false、树自指导致），待桌面复核 wheel 动作，建议并入 CI 阶段2 ② `RAWLAB_REQUIRE_AX`（与 hdr-rendition-ui 绿≠真跑同族）。
- **C 类（台账挂行，待桌面会话复核 3 条）**：edit-model 链跑 mac-viewing-model 缺「CLT 缺 SwiftUIMacros→强制 26.5 SDK」护栏；ai-batch-native 沙箱 `sandbox_extension_issue` EPERM 缓存未隔离；system-menu-language 德语菜单读出为空（需桌面+AX 授权）。
- **D 类（素材要求记档 5 条）**：lens-render/export-metadata 默认 DSC06251.ARW 未入库（.cache/shared 可补）；hdr-sdr-preview/hdr-lut-preview 需 `RAWLAB_TEST_HDR` gain-map；fuji-compatibility 需 RAW+彩色 CUBE（ACROS/identity 走 missingColor 属预期）。
- 另录：hdr-rendition-ui E.2-L1 无 AX 授权静默 return（绿≠真跑，与 Q14 axTrusted/REQUIRE_AX 挂行同族）。
- **CI 阶段2 家族新行（11-14，#300 评审发现）**：`RawLabMac/build.sh` 未传 `-DPython3_EXECUTABLE`，CMake 绑定 Homebrew Python（无 jsonschema）→ macOS native CI 中 `edit_recipe_schema` 实为 Skipped（对照 Windows build.ps1 已透传）。阶段2 统一透传解释器并核查 SKIP 清单。
- **A 簇修后新挂（11-14，PR #303 交卷时发现）**：①`compact-controls-presentation` 快照期望过时需要整体重基线（a74a6baf 重设计未重基线：`editor-minimum expected 1 numeric fields; found 6`，改期望后又败于可达性断言）**PR #306** 矩阵级重基线交卷（逐项依据、标识符集合防凑数、可达性改滚动可达、cacheDisplay 面 headless 全绿；碳审在途），真实鼠标/滚轮/VoiceOver 交互仍留桌面复核；②`photo-effects-presentation` 与本会话锁屏下的 `mac-geometry-draft` 末位激活检查同属「无显示/锁屏会话」环境红，待有显示器会话复核即关。
- **既有红新登记（11-14，#300 native run 顺带发现）**：`tools/mcp` `mcp-cli-parity` 契约漂移——`test_missing_output_parent_is_mcp_policy_vs_native_parity` 期望 `processing_error(4)` 实得 `output_io_error(6)`，双套件一致复现，疑输出策略变更后期望未更。判定=测试期望未更（2aa25048 staged write 迁移+edit-json.md L124-125 明文 status 6），**PR #305** 修期望，碳审在途。
