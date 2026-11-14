# 独立复核处置（/agy-brain carbon 裁决，2026-11-13）

> 返回索引：[RawLab 综合整改任务清单](../remediation-plan-2026-11-13.md)

- **口径**：对独立复核的 19 条标记项（2 未通过、14 部分成立、3 待验证）+ 证据段 6 项额外发现，共 25 条，交由 /agy-brain（carbon-high，job `staffer-mwf1om9u-a2f7ac29`，全文 `.agy-staff/jobs/staffer-mwf1om9u-a2f7ac29.result.md`）逐条源码级确认。前提已核验：`dancancer/RawLab` 为个人公开仓库（`owner_type=User, visibility=public`）。
- **裁决结果**：绝大多数确认成立；两处定性修正——完成-06 转**条件接受**（协议无远端哈希，全量重下违背增量导入初衷；须在契约文档与 `CameraOriginalStore` 注释写明「3×64KiB 抽样+元数据仅用于跳过重复无线下载，不替代归档完整性哈希」）；完成-22/37、P1-22 拆分判定（代码缺陷进工作包、桌面/硬件实跑进待验证清单）。完成-38 维持 accept-residual（S1/X2 由 P2-01/P2-02 承接，不得取消）。
- **待验证 3 项（不计债，发布前手动门禁签收）**：P1-04（真页返回键退忙）、完成-22①（Windows 桌面只读 ARW 实跑）、完成-35（D3D11/GLES 硬件对拍留档）。

## needs-fix 工作包（波次=brain 排序；状态随 PR 更新；kanban：WP-01 `t_50163342`、WP-02 `t_3a622944`、WP-03 `t_f78e9387`、WP-04 `t_a96fe1fc`、WP-05 `t_afc943b3`、WP-06 `t_520d7b95`、WP-07 `t_cf708448`、WP-08 `t_fa0ae922`、WP-09 `t_194210b9`、WP-10 `t_bb6bce5d`、WP-11 `t_a03c936f`）

| 包 | 内容（条目） | 波次 | 状态 |
|---|---|---|---|
| WP-01 | CI 自托管执行硬隔离（完成-01）：①审批策略改「all external contributors」（Web 端手动，API 不可达则用户操作）；②JIT 派发器方案（常驻 Runner.Listener 改服务端元数据硬校验 + ephemeral 派发，~80 行）；攻击性验证 PR 待做 | 0 | ①审批策略网页实锤（2026-11-14 用户核实）=「Require approval for first-time contributors」，**未拨至建议档「all external contributors」**（首次贡献者一旦获批即永久自动放行，恶意化门槛失效），拨档仍待用户操作，原两行口径冲突就此了结；②PR #295 已合入（`66b039e1`）；**复核：未通过**（2026-11-14）：本机常驻 `Runner.Listener`（PID `82065`）仍在跑、Windows 自托管无隔离，且 `jit_dispatch.py` 存在 `os.environ` 向作业泄漏 `RAWLAB_JIT_TOKEN`（`:141-144,272`）与排队不可信作业 FIFO 抢占临时 runner（`:115-130,214-219`）两处阻断级缺陷 |
| WP-02 | CI 防空跑（A/B/C/18-②）：apple-models.sh SKIP 判失败、hdr_stream 补 LUT fixture、ai-denoise 缺模型显式 SKIP 用例 | 0 | PR #292 **已合入**（`4bebba43`）；**复核：部分成立**（2026-11-14）：`hdr_stream_api_portable`（2/2）与 `dualdn*_skip`（exit 77）**✅ 复核通过**；但 `apple-models.sh` 仍漏拦 `ios-reset-entry-ui.sh` 无日志静默跳过 AX（#311 遗漏 D 项）、`camera-skip-and-limit.sh:27-50` 缺 Simulator SDK 静默跳过，以及 `pre_checks` 中 Python `skipped=N` |
| WP-03 | 核心取消锁存 + D-01 残留（P1-13、D-01①②③）：编码器粘性取消锁存、float→精确缩放（65535 误拒）、JPEG 4096 标记与 TIFF IFD 链边界 | 0 | PR #293 **已合入**（`f96f989e`）；**✅ 复核通过**（2026-11-14）：`ProcessingCancellationScope` 原子锁存、`scaleEdgeHalfUp` `uint64` 精确缩放、JPEG 4 MiB 扫描预算与 64-IFD 防环遍历均实跑 CTest 167/167 全绿，分别撤回锁存与精确缩放均变红 |
| WP-04 | ABI 回调原型入夹具（P1-22①）；64 位限制=条件接受（四端纯 64 位；引入 32 位 ABI 前必须先拆夹具） | 0 | PR #287 **已合入**（`d70544ed`，CI 7/7）；**✅ 复核通过**（2026-11-14）：`fixture_version:3` 展开 4 回调原型与一级指针约束，给 `sony2fuji_cancel_callback` 增参或改二级指针后 CTest 与 Python 单测均变红（Windows `AbiLayoutChecks.cs` 仅验 `structs` 边界记档） |
| WP-05 | Mac 单张导出「编码+元数据」整链暂存（完成-36） | 1 | PR #289 **已合入**（`63105a9b`）；**✅ 复核通过**（2026-11-14）：`Engine.swift:729-782` 同目录 `.rawlab-<UUID>` 暂存+写完元数据后 `Darwin.rename`，本机 `export-metadata.sh` 全绿，撤掉暂存分支即变红 |
| WP-06 | iOS HDR 提示缓存重置 + 死状态清理（P1-05、P1-18、D 项）——须在 P1-③ 切 iOS 分支**前**合入 | 1 | PR #291 **已合入**（`9ae012d7`，D 项拆给 CI 阶段2②）；**复核：部分成立**（2026-11-14）：死状态已清、常规跨图 HDR 提示已恢复，但①SDR 出帧前失败早退时 `hdrResourceNotice` 不重置，②`ContentView.swift:380-405` 换图漏清 `collapsedEditorTool` 致跨图展开面板误入上一张图的子工具（含 HDR 误入禁用的镜头工具） |
| WP-07 | 三端批量日志逐任务损坏隔离（完成-37 iOS/Android/Win） | 1 | PR #290 **已合入**（`91754cce`）；**复核：部分成立**（2026-11-14）：三端 `.corrupt-*` 隔离、未来版本保护与 I/O 区分均通过测试且撤修复变红，但隔离提示仅接通 Windows UI，iOS 与 Android（`lastQuarantinedPaths` 生产 0 读取）对用户静默 |
| WP-08 | Windows 启动清扫防崩、内嵌预览兜底、坏预设展示（完成-05、完成-23、E） | 1 | PR #288 **已合入**（`a3b23e11`，CI 7/7）；**✅ 复核通过**（2026-11-14）：`TempCleanup` 异常全隔离（CI `[usage]` 实跑）、`PumpEmbedded` 非致命异常兜底、`AdjustmentPresetDialogs` 坏/未来预设展示与删除全部闭环 |
| WP-09 | Windows 更新器启动失败回退（完成-27，并入 S6 更新器矩阵） | 2 | PR #294 **已合入**（`4ce99b5f`）；**✅ 复核通过**（2026-11-14）：`!dispatched` 启动失败回退 `ReadyToInstall` 并解锁编辑、清理备份，回退落盘失败时保守保留 `Installing` 门禁 |
| WP-10 | Android 相机三合包（完成-07/15/16）；与 P1-23/P1-25 共用 `CameraImportStore.kt`，按集成规范排 owner | 2 | PR #296 **已合入**（`f72b1e8a`）；**复核：部分成立**（2026-11-14）：完成-15（联机 10k 截窗保持 `READY`）与完成-16（坏日志弹窗与丢弃）**✅ 复核通过**；完成-07 冷启动恢复 `PAUSED` 落 `CameraRoute.HOME` 无 `tether-confirm-continue` 入口且新开联机不关旧 journal |
| WP-11 | 核心 GLES 先绑后建与跨 API 恢复（F/P3-05，并入 P3 GPU 批次） | 3 | todo |

- **完成-06 契约注记落盘**：随 P1-23(A12/Q7)/P3-47(L4) 一并写入（条件接受的前置；截至 `bcdc7c64` 尚未落盘，B 表完成-06 维持未通过）。
- **完成-37 Mac 单文件预读**：条件接受（100 条/30 天 Q6 上限 + P3-12 兜底）。
- 与 P1 主线的冲突约束：第 0/1 波均避开 `Shared/specs|fixtures` 与四端 `*Transfer*/*Reset*` 锁定文件；#286 评审中的 Layer2/3 返工与本表互不重叠。
