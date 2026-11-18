<!--
活台账（索引）：由主评审 + 整改后复审 + 实际合并台账合成，随任务推进持续更新。
本文件已拆为「索引 + 细分项」：细分项在 remediation-plan-2026-11-13/ 目录，本索引只放摘要、导航与维护纪律。
更新纪律（每次合入后必做）：
  1. 任务状态只改 b-task-table.md 的「状态」与「依据」两列；依据写成 `PR #NNN @ <commit>`，合入前写 `PR #NNN（待合入）`。
  2. 任何状态从「未修/部分修复」变成「已修（已合入）」时必须同时写清验证锚点：
     脚本/命令 + 断言名 + 撤掉修复后应红的位置。
  3. changelog.md 追加一行：日期 · PR · 涉及编号 · 状态变化。
  4. 产品决策的最新登记在 g-product-decisions.md；阶段表的最新维护在 f-overall-plan.md。
     ../archive/architecture/remediation-roadmap-2026-11-13.md 是同内容的早期快照（§2/§5/§6 已滞后并已归档，参见 adr-2026-11-19-owner-transformation.md），以本目录两文件为准，后续合并。
复核说明：独立复核请直接按「依据」列的命令与断言复跑，并撤掉对应修复确认变红——
本表的「已修」只以代码核实和红/绿证据为准，不以 PR 标题为准。
文档来源：codebase-review-2026-11-12.md、codebase-review-followup-2026-11-13.md、
architecture-review-2026-11-13.md。
-->

# RawLab 综合整改任务清单（两份评审 + 实际合并台账，2026-11-13）

- **代码基线**：`origin/development` @ `0cf4a88a`（PR #269）。本机工作区 HEAD 停在 `d05c8d7d`，所以全部代码核实都用 `git show 0cf4a88a:<path>` 和对当前 `development` 的实时检查完成。
- **输入**：主评审 `docs/architecture/codebase-review-2026-11-12.md`（下称“主”）；复审 `docs/architecture/codebase-review-followup-2026-11-13.md`（下称“复”）；架构评审 `docs/architecture/architecture-review-2026-11-13.md`。
- **行号**：表里写的行号都按 `0cf4a88a` 实测。不在改动清单里的文件，复审行号仍然有效；这类引用标“文件未改，沿用复审”。
- **负责人图例**：Core 核心、Mac、iOS、And(roid)、Win(dows)、CI、Apple（Mac 和 iOS 同一个 PR）、Shared；“主”指与协调者同一模型，“轻”指机械改动，可用轻量模型。

> **独立复核（2026-11-15 第三轮复核，`development` @ `6d6a7acf` / 源码树 `766ebcca`；遵循第一性原理把关，覆盖 `#310`、`#313`–`#359` 共 48 个新合入 PR）**：已复核 B 表 **117 条**（全表共 **179 行**，含 `#338` 派生 `完成-48`；其余 62 行为未修或历史未动项）——**103 条 ✅ 复核通过**（本轮升级 6 条：`P1-05、P1-09、P1-18、D-05、D-07、完成-06`；新增通过 43 条：`P1-06..08、P1-14..17、P1-19、P1-23..25、P2-01..07、P2-11..15、P2-17..25、P3-01..06、P3-61、P3-66、P3-68、P3-69、完成-48`）、**9 条 复核：部分成立**（`P1-21、D-02、P2-09、P2-16、P2-26、P3-60、完成-07/37/38`）、**1 条 复核：未通过**（`完成-01` 自托管生产未切换且同 UID plist 明文暴露 Token）、**4 条 复核：待验证**（`P1-04、P2-10、完成-22/35`）；B 表外跟进票与工程包中，`V-SPEC #321`、`V-RESET #322`、`V-AXUI #318`、`V-UIIOS #317`、`V-WIN #320`、`V-EXP #319`、`Q5 #326` 及 `#323/#324/#325/#354/#357` 全部 **✅ 复核通过**，`V-JIT #316` **复核：部分成立**。详见 [B 综合任务清单](remediation-plan-2026-11-13/b-task-table.md)、[工作包处置](remediation-plan-2026-11-13/h-review-workpackages.md)及[独立复核证据](remediation-plan-2026-11-13/review-evidence.md)。

## A. 执行摘要

1. **完成度**（`0cf4a88a` 建账基线：B 表原 178 行，`#338` 新增 `完成-48` 后现共 **179 行**；实时状态与复核结论以 [B 综合任务清单](remediation-plan-2026-11-13/b-task-table.md) 为准）：建账时已修 43、部分修复 10、进行中 2、需产品决策 7、未修 113、已复核不再成立 3；截至 `6d6a7acf` 已合入并经独立复核 **117 行**。
2. 主评审第一批 14 个编号（§2.1 加上 §12 的 C2、C4、I5、R10、R11、R13 另算）：W1、C1、R1、W3、R2、A4、C3、X4、X5、X13、L1、R14、A3、I5 的落地状态见 B 表对应行。
3. 补充评审的 40 条主要发现：已修 25，进行中 1（M10），未修 14。复审新增的 61 条：只有 R-N1 由 #265 修复；C-N3、I-N9、R-N4 经复核不再成立。
4. **安全项**：高严重度的 R1/R15/R-N1 已由 #265 关闭（`ci.yml:130-134`）。剩下的 fork 问题是 R16/R-N2“fork 首跑无基线”，按 P1 处理；独立复核对完成-01 的关闭结论维持未通过（见 review-evidence）。
5. **本轮之后仍是高或中到高的未完成项共 5 行**（建账基线快照；A1、I1、A2 现已由 `#335`/`#310` 收口，C2/C6/C7 仍见 `P1-21`）：A1（Android 启动全量 SHA256）、I1 和 A2 的残留（存储回收）、C2/C6/C7（GPU 一致性）。
6. **最该先做的 8 项**：① 合入在飞的 M10＋场景向量（P0-01）；② 合入 Windows flaky 加固（P0-02）；③ R16＋L1，让 fork 与发布通道可信；④ A1 启动哈希缓存；⑤ I1/A2 存储批次；⑥ GPU 批次（C2/C6/C7）；⑦ 结构性 S1（编辑记录整文件）；⑧ 更新器矩阵（S6）。
7. **与台账不符**：#267 没改任何 Android 文件，A12 仍未修；#250 也没改 Android，A17、A18 仍未修（主 §14.9 的“已修”标注按 B 表状态列为准）。

## 细分文档导航（`remediation-plan-2026-11-13/`）

| 文件 | 内容 | 更新时机 |
|---|---|---|
| [b-task-table.md](remediation-plan-2026-11-13/b-task-table.md) | **B 综合任务清单 179 行（活台账核心）＋ B.1 复审条目状态 ＋ B.2 结构性观察 S1–S6** | 每次合入后改「状态/依据」 |
| [c-four-end-consistency.md](remediation-plan-2026-11-13/c-four-end-consistency.md) | C 四端一致性专项（主 §14.8 对照） | 一致性专项合入后 |
| [d-followup-assignments.md](remediation-plan-2026-11-13/d-followup-assignments.md) | D 后续分配计划（建账时 3 阶段版，历史） | 一般不改 |
| [e-coverage-gaps.md](remediation-plan-2026-11-13/e-coverage-gaps.md) | E 覆盖缺口、文档与代码不符、不确定项 | 核实后 |
| [f-overall-plan.md](remediation-plan-2026-11-13/f-overall-plan.md) | 整体方案：路线、十条验收不变量、地基层、**阶段表（活）**、插队准入、失败预测 | 阶段推进时 |
| [g-product-decisions.md](remediation-plan-2026-11-13/g-product-decisions.md) | **产品决策登记（活，Q1–Q14，Q11 空号）** | 用户裁定时 |
| [review-evidence.md](remediation-plan-2026-11-13/review-evidence.md) | 独立复核证据（口径、安全、覆盖缺口、边界） | 独立复核会话维护 |
| [h-review-workpackages.md](remediation-plan-2026-11-13/h-review-workpackages.md) | **独立复核处置（/agy-brain carbon 裁决）**：25 条判定 + needs-fix 工作包 WP-01–11（含波次/并行/状态）+ 条件接受与待验证清单 | 工作包推进时 |
| [changelog.md](remediation-plan-2026-11-13/changelog.md) | 变更记录（追加式） | 每次合入/评审/决策 |

## 关联文档

- [整改路线图（早期快照，已归档）](../archive/architecture/remediation-roadmap-2026-11-13.md)：§2/§5/§6 与 f-overall-plan.md、g-product-decisions.md 同源，已滞后并由 [Owner 改造 ADR](adr-2026-11-19-owner-transformation.md) 取代。
- [架构评审补充](architecture-review-addendum-2026-11-13.md)：Q1 决策依据、残余风险（§4 执行期补查）。
- 评审门禁与编排纪律（用户裁定）：所有 PR 合入前必须 carbon 评审通过（纯文档豁免）；任务编排与关键决策走 /agy-lead（carbon）。
