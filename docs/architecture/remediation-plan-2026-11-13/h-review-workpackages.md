# 独立复核处置（/agy-brain carbon 裁决，2026-11-13）

> 返回索引：[RawLab 综合整改任务清单](../remediation-plan-2026-11-13.md)

- **口径**：对独立复核的 19 条标记项（2 未通过、14 部分成立、3 待验证）+ 证据段 6 项额外发现，共 25 条，交由 /agy-brain（carbon-high，job `staffer-mwf1om9u-a2f7ac29`，全文 `.agy-staff/jobs/staffer-mwf1om9u-a2f7ac29.result.md`）逐条源码级确认。前提已核验：`dancancer/RawLab` 为个人公开仓库（`owner_type=User, visibility=public`）。
- **裁决结果**：绝大多数确认成立；两处定性修正——完成-06 转**条件接受**（协议无远端哈希，全量重下违背增量导入初衷；须在契约文档与 `CameraOriginalStore` 注释写明「3×64KiB 抽样+元数据仅用于跳过重复无线下载，不替代归档完整性哈希」）；完成-22/37、P1-22 拆分判定（代码缺陷进工作包、桌面/硬件实跑进待验证清单）。完成-38 维持 accept-residual（S1/X2 由 P2-01/P2-02 承接，不得取消）。
- **待验证 3 项（不计债，发布前手动门禁签收）**：P1-04（真页返回键退忙）、完成-22①（Windows 桌面只读 ARW 实跑）、完成-35（D3D11/GLES 硬件对拍留档）。

## needs-fix 工作包（波次=brain 排序；状态随 PR 更新；kanban：WP-01 `t_50163342`、WP-02 `t_3a622944`、WP-03 `t_f78e9387`、WP-04 `t_a96fe1fc`、WP-05 `t_afc943b3`、WP-06 `t_520d7b95`、WP-07 `t_cf708448`、WP-08 `t_fa0ae922`、WP-09 `t_194210b9`、WP-10 `t_bb6bce5d`、WP-11 `t_a03c936f`）

| 包 | 内容（条目） | 波次 | 状态 |
|---|---|---|---|
| WP-01 | CI 自托管执行硬隔离（完成-01）：①审批策略改「all external contributors」（Web 端手动，API 不可达则用户操作）；②JIT 派发器方案（常驻 Runner.Listener 改服务端元数据硬校验 + ephemeral 派发，~80 行）；攻击性验证 PR 待做 | 0 | 卡片就绪 |
| WP-02 | CI 防空跑（A/B/C/18-②）：apple-models.sh SKIP 判失败、hdr_stream 补 LUT fixture、ai-denoise 缺模型显式 SKIP 用例 | 0 | **PR #292 评审中** |
| WP-03 | 核心取消锁存 + D-01 残留（P1-13、D-01①②③）：编码器粘性取消锁存、float→精确缩放（65535 误拒）、JPEG 4096 标记与 TIFF IFD 链边界 | 0 | **PR #293 评审中**（agent 测试断言改动系评审重点） |
| WP-04 | ABI 回调原型入夹具（P1-22①）；64 位限制=条件接受（四端纯 64 位；引入 32 位 ABI 前必须先拆夹具） | 0 | **PR #287 评审中**（`b7d4b92a`，fixture_version 3，碳审重点=Windows 消费方兼容） |
| WP-05 | Mac 单张导出「编码+元数据」整链暂存（完成-36） | 1 | **PR #289 评审中** |
| WP-06 | iOS HDR 提示缓存重置 + 死状态清理（P1-05、P1-18、D 项）——须在 P1-③ 切 iOS 分支**前**合入 | 1 | **PR #291 评审中** |
| WP-07 | 三端批量日志逐任务损坏隔离（完成-37 iOS/Android/Win） | 1 | **PR #290 评审中**（Windows 面靠 CI 验证） |
| WP-08 | Windows 启动清扫防崩、内嵌预览兜底、坏预设展示（完成-05、完成-23、E） | 1 | **PR #288 评审中**（Windows 面靠 CI 验证） |
| WP-09 | Windows 更新器启动失败回退（完成-27，并入 S6 更新器矩阵） | 2 | **在途**（分支 `fix/win-update-launch`，原生 subagent） |
| WP-10 | Android 相机三合包（完成-07/15/16）；与 P1-23/P1-25 共用 `CameraImportStore.kt`，按集成规范排 owner | 2 | todo |
| WP-11 | 核心 GLES 先绑后建与跨 API 恢复（F/P3-05，并入 P3 GPU 批次） | 3 | todo |

- **完成-06 契约注记落盘**：随 P1-23(A12/Q7)/P3-47(L4) 一并写入（条件接受的前置）。
- **完成-37 Mac 单文件预读**：条件接受（100 条/30 天 Q6 上限 + P3-12 兜底）。
- 与 P1 主线的冲突约束：第 0/1 波均避开 `Shared/specs|fixtures` 与四端 `*Transfer*/*Reset*` 锁定文件；#286 评审中的 Layer2/3 返工与本表互不重叠。
