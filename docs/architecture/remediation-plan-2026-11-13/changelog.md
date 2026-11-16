> 返回索引：[RawLab 综合整改任务清单](../remediation-plan-2026-11-13.md)

# 变更记录

- 2026-11-13 · PR #270（待合入）· M10 / 14.8 行1–3（Mac、iOS）· 实现完成：两端跳过非 RAW 占位值（白平衡三项、旧版降噪、镜头五项全默认时），新增 `Shared/fixtures/adjustment-transfer-scenarios-v1.json`（18 条带目标初始状态的场景）与 `scripts/ci/test_transfer_scenarios.py`（契约测试）。验证锚点：`bash RawLabMac/tests/adjustment-transfer.sh`、`bash RawLab/tests/adjustment-transfer.sh`；逐项撤回时各自 exit 133 并命中 `Scenario <id>: value <field>` 断言；`python3 -m unittest scripts.ci.test_transfer_scenarios`。Windows 与 Android 仍为部分修复（缺口行见 P1-11、P1-12）。
- 2026-11-13 · PR #271（待合入）· L1 · 实现完成：CI 的 macOS 模型套件 `export RAWLAB_REQUIRE_AX=1`，未授权时 `HDRRenditionUITests` 以 exit 1 失败而不是静默跳过。验证锚点：`RAWLAB_REQUIRE_AX=1 bash RawLabMac/tests/hdr-rendition-ui.sh` 应 exit 1；不设变量时应 SKIP 且 exit 0。
- 2026-11-13 · 台账建立 · 基线 `0cf4a88a`（PR #269）· 178 行；已修 43、部分修复 10、进行中 2、需产品决策 7、未修 113、已复核不再成立 3。
- 2026-11-13 · PR #272（待合入）· T-W1（Windows `updateSdk` flaky）· 实现完成：根因是**控制台测试进程没有 `SynchronizationContext`**，`Progress<int>` 回调被投递到 ThreadPool，与内存 store 的微秒级保存竞争后把 `Downloading` 覆盖回内存阶段，导致按阶段注入的 `moveFault` 漏注入。修复为测试内单线程串行上下文 + 按待落盘目标状态注入。验证锚点：`pwsh ./scripts/ci/windows-models.ps1`；撤掉串行上下文可复现原竞态。
- 2026-11-13 · PR #273（待合入）· R16 ＝ R-N2 · 实现完成：fork PR 的选择结果不再包含只有自托管 runner 的 macOS/iOS，Windows 保留在托管机执行。验证锚点：`python3 scripts/ci/test_affected_platforms.py`；撤掉剔除逻辑时 `test_fork_pull_request_leaves_a_consistent_verify_result` 报 `macos finished as skipped, expected success`（即 CI 恒红的真实症状），`test_fork_pull_requests_never_select_a_self_hosted_platform` 同时变红。
- 2026-11-13 · PR #271（待合入，已修订）· L1 · 状态改为**部分修复**：CI 实测发现自托管 macOS runner **没有辅助功能授权**，`hdr-rendition-ui.sh` 在 CI 上一直空跑。改为打印 `::warning::` 注解（CI 可见）并保留 `RAWLAB_REQUIRE_AX`；真正的覆盖要改成不依赖 AX 的表示层断言（新增后续任务）。验证锚点：`RAWLAB_REQUIRE_AX=1 bash RawLabMac/tests/hdr-rendition-ui.sh` 应 exit 1；不设变量时应打印 `::warning::` 并 exit 0。
- 2026-11-13 · 整体方案落地 · 本节优先于 B 表序号：先建 `Shared/specs` 闭环保障（不新建机制），语义层冻结单端修补；其余约 80 行按主题批次双轨推进。P0–P4 见「整体方案」。最小可行路线约 2.5 轮，理想路线 4.5–5 轮。
- 2026-11-13 · 产品决策全部裁定（12 项，Q11 为合成时跳号）· Q1=A、Q2=接受、Q3=保留双键、Q4=A、Q5=A、Q6=按建议、Q7=按建议、Q8=A、Q9=A、Q10=真机验、Q12=A、Q13=A、Q14=B。对应行由「需产品决策」转入可实施。

- 2026-11-13 · #270 合入（`7c883991`）· P0-01（M10 + 14.8 行1–3，macOS/iOS）→ **已修**；Windows/Android 的镜头与白平衡占位仍为未修（P1-11、P1-12）。锚点：`RawLabMac/tests/adjustment-transfer.sh`、`RawLab/tests/adjustment-transfer.sh`、`python3 -m unittest scripts.ci.test_transfer_scenarios`。
- 2026-11-13 · #271 合入（`6e12fd66`）· L1 → **部分修复**：CI 实测自托管 macOS runner 无辅助功能授权，改为 `::warning::` 可见；根治由 Q14 的表示层断言完成。
- 2026-11-13 · #272 合入（`5e5400cc`）· P0-02（Windows flaky）→ **已修**。锚点：`pwsh ./scripts/ci/windows-models.ps1`；根因是测试进程缺 `SynchronizationContext`。
- 2026-11-13 · #273 合入（`992be9d5`）· P1-01（R16/R-N2）→ **已修**。锚点：`python3 scripts/ci/test_affected_platforms.py`；撤掉剔除逻辑时 `macos finished as skipped, expected success`。
- 2026-11-13 · #274 合入（`d5d62af7`）· P1-04（A3）→ **已修**。锚点：`HDRLookImportTest`（5 条）+ 全量 `:app:testDebugUnitTest` 640 条；撤掉修复时 3 条失败。
- 2026-11-13 · #275 合入（`77297393`）· P1-05（I5）、P1-18（I-N1）→ **已修**。锚点：`bash RawLab/tests/hdr-resource-notice.sh`（撤掉每帧赋值时 exit 133，`Fatal error: HDR preview delivery routes missing-resource warnings through the change-only notice`）。
- 2026-11-13 · #276 合入（`57dbea99`）· P1-03（M1）→ **已修**。锚点：`bash RawLabMac/tests/hdr-history.sh`（撤掉修复时 exit 133，`Fatal error: an accepted gain-map preview was reported as changed before target sampling`）。
- 2026-11-13 · #277 合入 · 两份评审、复审、路线图与本台账入库（文档基线）。
- 2026-11-13 · #278 合入（`593b10d2`）· P1-13（C-N4+C-N5）→ **已修**：并发/取消契约页 + 编码期检查点。锚点：`processing_cancellation_tests`；31MP 编码中取消 JPEG 0.94–1.03 ms、PNG 7.72–10.66 ms。
- 2026-11-13 · #279 合入（`de64c3f0`）· P1-22（S4）→ **已修**：ABI fixture v2（functions 95 + enums 23/103 值），ctest 用例 `abi_layout_fixture`。
- 2026-11-13 · PR #280（待评审合入）· P1-02 根治（Q14）+ Q5 落地 · Mac HDR 显示映射「HDR 渲染」分组与单项重置（零新增文案）；CI 模型套件以 `hdr-rendition-reset.sh` 替换 AX 套件；`docs/process/ci.md` 记录 UI 门禁与 SKIP 口径。锚点：撤 `resettingHDR` 分组/工具处理 → `hdr-model.sh` exit 133；identifier 改错/按钮移除 → `hdr-rendition-reset.sh` FAIL。rebase 后 `apple-models.sh macos|ios` 全绿、本地化 22 项全绿。
- 2026-11-13 · PR #281（待评审合入）· P1-01 补查 · fork PR 的 Windows 作业源门禁只放行托管 `windows-2022` 路由（此前 fork 恒 skip 导致恒红）；`docs/process/ci.md` 新增 External Fork Pull Requests 章节（Q2 口径）。锚点：撤托管逃逸条款 → `test_workflow` 的 `windows_runner` 断言红；`python3 -m unittest discover -s scripts/ci -p 'test_*.py'` 99 项绿。
- 2026-11-13 · Q1（D-01）实施完成 · 2.1G 像素上限 + NATIVE 解码前头部预检 + JPEG 65535 上移请求验证；待 carbon 评审通过后开 PR（评审门禁纪律）。
- 2026-11-13 · 前提核查落地 · 三条结论见「整体方案 → 前提核查结论」：字段表区分传输精度与 UI 步长（59/83 分叉）；渲染对拍改手动门禁；P1-① 传输接入免测试入口重构。
- 2026-11-13 · 复审补充入库 · `docs/architecture/architecture-review-addendum-2026-11-13.md`（Android 批量导出恢复可能删除已发布成片、iOS 三段抽样需完整身份确认、存储读取成本与发布对账、对既有结论的修正表；代码基线 `57dbea99`）。
- 2026-11-13 · 流程纪律 · **评审门禁**生效：PR 合入前必须通过独立 review（carbon），纯文档豁免；见「整体方案 → 评审门禁」。
- 2026-11-13 · 执行期补查入库 · carbon brain 汇总（agy-brain）写入 addendum §4：fork 源门禁两事实、前提核查三结论、Q5 前提过时入修正表、D-01 三个残余风险；决策登记补 Q11 空号说明（共 13 项）。
- 2026-11-13 · PR #281 评审结论 · carbon review **approve**（无 blocking）；两条 should-fix 已修：平台作业门禁改整式 `assertEqual` + android 自托管守卫，ci.md 补验章节拆分「被跳过平台」与「重型检查组」两类并补 android 选项。
- 2026-11-13 · #281 合入（`508f8f49`）· P1-01 补查（fork Windows 恒红缺口）→ **已修**；#282 文档基线随之更新。
- 2026-11-13 · PR #280 合入（`83381e8e`）· P1-02（Q14 根治）+ Q5 → **已修**；carbon 复审 approve（0 blocking / 0 should-fix / 4 note），4 条红/绿锚点在独立临时目录逐字复现。遗留 note（后续顺手）：`navigateAdjustment` 延迟闭包末尾补 `normalizeAdjustmentNavigation()`；`requireResetButton` 可加 title 断言。
- 2026-11-13 · PR #283 评审结论 · P1 第①步（Android/Windows 消费共享场景夹具，去写死计数 80/73）carbon **approve**（0 blocking / 2 should-fix / 4 note）；should-fix 已收口（`8c2d08ea`）：例外键细化为 `status:applied`+`changed:<field>`/`status:rejected:<reason>`、Windows `Capture(All)` 实际输出对账、Android `resolveSharedPath` 统一解析。实测分歧棘轮登记：Android 9 条（P1-11）、Windows 6 条（P1-12）。
- 2026-11-13 · PR #284 复审结论 · Q1（D-01）修复版（三态探测/stb size_t/PNG 分片）carbon **approve**（0 blocking / 3 should-fix / 3 note）；收口中：DNG Classic TIFF 715.82M 确定性上限前置为 `INVALID_ARGUMENT`、打开失败不写探测缓存（冷跳过锚点改 `header-50000x50000.png`+absentLut）、800MP mmap 改 `PROT_NONE`+`mprotect`。
- 2026-11-13 · PR #283 合入（`55c4b75c`）· P1 第①步 → **完成**（Android/Windows 传输单测消费 `adjustment-transfer-scenarios-v1.json`、去写死计数、分歧棘轮登记）。P1-11（And，9 条）/P1-12（Win，6 条）生产行为仍「未修」，修复 PR 中棘轮须清空例外条目。 **✅ 复核通过**：限共享测试接入，分歧实跑见上。
- 2026-11-13 · PR #284 合入（`1513eef0`）· Q1/D-01（C-N1/G-N8/C-N2）→ **已修**：2.1G 像素上限 + 三态解码前预检（JXL DNG/normal X3F 延后复核）+ stb size_t + DNG TIFF 容量前置 + 探测缓存防污染；复审 approve（3 should-fix 已在 `21cddd82` 收口，红锚点逐条复现），CI 7 项全绿。残余风险维持 addendum §4 记录（>715MP 内存表现、真机未验）。
- 2026-11-13 · 独立复核（`36ccbcf9`）· B 表 58 条中 39 条通过，14 条部分成立、2 条未通过、3 条待验证；#283 的测试接入另计。完成-01 的安全关闭结论撤销，完成-06 复现静默复用旧原件，其他证据见各行。
- 2026-11-13 · PR #285 合入（`823e4e13`）· P1-11（Android 曝光基准/白平衡/镜头占位）+ P1-12（Windows 镜头占位）→ **已修**（carbon approve，0 blocking/0 should-fix/2 note）：非 RAW→RAW 粘贴跳过载荷占位，与 #270 四端同语义；#283 的 15 条棘轮例外全清。note（留待后续顺手）：①端到端 capture→prepare 未建本端独立回归；②Windows `ApplyObjects` 每次镜头粘贴构造全量 73 字段默认快照（可只比 5 项）。
- 2026-11-13 · 独立复核增量（`588c9b3e`）· #285 的 P1-11、P1-12 红绿均实跑，新增 2 条通过；本轮合计 60 条中 41 条通过。P1-10 仍未修。
- 2026-11-13 · PR #286 开（`6c1181a9`，未合）· P1 第②步地基：`Shared/specs/adjustment-fields-v1.json`（83 字段）+ 三层 Python 静态 parity（协议/模型/UI，全 python 解析四端生产源）。109 单测绿、协议与 UI 各一条真文件红锚点复现；对审计前提报告登记 11 项源码勘误、divergent=64/identical=19。评审中。
- 2026-11-13 · 纯文档 · 台账拆分为「索引 + 细分项」：本 changelog 及各专项移入 `remediation-plan-2026-11-13/` 目录，索引只留摘要/导航/维护纪律；内容零删改（B 表 178 行核对无缺失）。roadmap 文档 §2/§5/§6 确认为早期滞后快照，以 f-overall-plan.md、g-product-decisions.md 为准，待后续合并。
- 2026-11-13 · /agy-brain carbon 裁决（`staffer-mwf1om9u`）· 独立复核 25 条处置固化 → 新增 [h-review-workpackages.md](remediation-plan-2026-11-13/h-review-workpackages.md)：确认为主、2 处定性修正（完成-06 条件接受、完成-22/37 拆分）、3 条件接受、3 待验证；needs-fix 打成 WP-01–11。第 0 波已启动：WP-02（`fix/ci-no-fake-green`）、WP-03（`fix/core-cancel-latch`）、WP-04（`fix/abi-callback-prototype`）worker 在途，WP-01 待策略开关+派发器方案。
- 2026-11-13 · PR #286 评审 request-changes（carbon，3B/4S）· Layer2/3 自证+spec 两处非法默认值（light.curve points、hdr.look strength）→ 原 worker continuation 返工中（`implement-mwf29ykl`），identical=19 预计修正为 66/17 口径。
- 2026-11-13 · WP-04 交付 → PR #287（`b7d4b92a`，fixture_version 3 + callbacks 原型，锚点齐、ctest 119/119）；carbon 独立评审在途（`review-mwf2zh5s`），重点=Windows fixture_version 断言兼容。WP-09 转原生 subagent 在途（用户新规：简单任务不派 flash implementer）。`.agy-staff/state.json` 存储治理派专项 subagent（迁 SQLite/WAL），已完成作业 events/log 357 件归档至 jobs/archive。
- 2026-11-13 · 第 0/1 波六包交付 → PR #288(WP-08)/#289(WP-05)/#290(WP-07)/#291(WP-06)/#292(WP-02)/#293(WP-03)，六路 carbon 独立评审全部在途；重点=WP-03 的 agent_preview/agent_commands 基线预红断言改动正当性、Windows 两包 compile-only 靠模型 CI 判绿。
- 2026-11-13 · #287 评审 request-changes（carbon）：实现面全过（Windows 兼容/原型准确/锚点确定/范围纪律），Blocking=worker ctest 证据跑在旧构建（真实 143 项矩阵+基线既有 CLI 失败被遮蔽）→ 原生 subagent 返工中。#286 返工 worker 撞 60 分钟硬顶（attention，3.55M tokens，仅 spec 默认值改动未提交）→ 原生 subagent 续做 B1-B3/S1-S4。WP-09 交付 → PR #294（原生 subagent 首例，锚点全绿 139 PASS）待 carbon 评审（agy CLI 正被 sqlite 迁移改造，评审排队等恢复）。
- 2026-11-13 · 评审波次①结果：#290 request-changes（Must=未来版本保护三端不一致/隔离移动失败与非损坏 I/O 误判，Should=Android/Windows 隔离可见性）→ fix-290-journal 返工；#288 request-changes（Blocking=本地化词条未注册 CI 红，P1=retired_ids 撞名/坏预设条目定位撞名）→ fix-288-win 返工。面板不可见根因=导出快照 215KB 超面板读取上限 → staff-state-sqlite 追加瘦身（running+最新 32，≤64KB）。
- 2026-11-13 · 评审波次②收口，七评审全 request-changes、必修清单均已派出返工（原生 subagent 8 路满编，#291/#294 排队）：#293=process 前序循环取消覆盖不全（断言改动获正名=补 #242 遗漏）；#292=SKIP 判定误报面；#289=暂存改动击穿覆盖保护打挂 raster-render.sh；#291=重置时机×2+假绿测试；#294=UI 断言漏翻转（L157-173）。
- 2026-11-13 · 面板「任务记录不可见」根因定位并修复：非字节溢出，是宿主 workspaceFiles.read maxLines=5000 行分页——旧镜像 5441 行 > 5000 → truncated → client L2853 保留空态。导出层改为「全部未结束作业 + 最新 done 补足 32 条」，活体再生成新镜像 2063 行/77KB（truncated 消除，面板恢复）。agy-staff 存储层 SQLite(WAL) 迁移完成（state.sqlite 全量 + state.json 分页快照 + .migrated 备份，261/261 测试绿），repo feature/state-sqlite 3 提交待授权 push。
- 2026-11-13 · #287 返工完成（原生 subagent，`aa06147e`）：真实 ctest 矩阵 143 项/2 失败经与 development 同配方对照确认 pre-existing（agent_preview/agent_commands，源自 #242），零新增失败；S1 指针深度契约+QualType 解包、S2 内联函数指针门禁各配红锚点；复审在途（review-mwf61aat）。
- 2026-11-14 · 决定：agy-staff 暂不推上游（feature/state-sqlite 3 提交留本地，安装副本已装载生效；期间勿重装 agy-staff 包，重装会覆盖 node_modules 移植——重装前需重新装载）。
- 2026-11-14 · #292 返工完成（`07216451`）：SKIP 门禁收行首锚点+双面锚点亲测（评审上轮 3 类误红全转绿，实测修正了评审建议正则的单括号瑕疵）；ai-denoise 去静默兜底+空模型 77 占位；ci.md 补 77 与门禁区分。复审在途（review-mwf6jxyr）。
- 2026-11-14 · **WP-04 合入**：#287 复审 approve（矩阵复跑 143/2 pre-existing 复核成立、S1/S2 锚点复核过）→ dancancer merge（CI 7/7），本波首个落地。面板状态显示 bug：迁移过渡期 6 条 DB 僵尸 running 行（旧 worker 完成不写 DB、面板无 sidecar 纠正）→ 手工对账 + state-db 读侧对账根治派给 staff-state-sqlite。
- 2026-11-14 · **WP-02 合入**：#292 返工复审双 approve（Must+Should 全落实，7/7 绿）→ dancancer merge。至此本波先行合入 2/8；面板僵尸行对账的读侧根治由 staff-state-sqlite 续做中。
- 2026-11-14 · #294 返工完成（`04447468`）：P2 采纳评审方案一（失败记录落盘失败→保守锁定同锁），P1 的 L157-173 UI 断言前提天然恢复免翻转；141 PASS+新 head CI 全绿；usage/system-open 本机 134 已 stash 对照归因既有环境性。复审在途（review-mwf7dc48）。
- 2026-11-14 · #289 返工完成（`3b349bf8`）：覆盖保护按核心别名语义（同路径+device:inode，TOCTOU 双校验），raster-render 红→绿复现；缺样片改显式 FAIL；权限/符号链接对齐核心。#288 返工完成（`4b3629af`）：词条正规登记（30 catalogs 一致）、两 P1 锚点先红后绿、附带修掉本 PR 自带 CS0123 编译断裂，CI 7/7。两路复审在途（review-mwf7hbon / mwf7g…）。
- 2026-11-14 · #293 返工完成（4 commits → `e28a27c4`）：取消锁存上移 ProcessingCancellationScope（单 atomic 全链共享+嵌套继承），C ABI 测试覆盖 1..N 全轮询点（revert 锚点三项全红）；probe 改 4MiB 字节预算+可证伪断言；edit-json.md 补齐 #242 文档遗漏；ctest 167/0/24。复审在途。另发现并适配 hdr_stream 测试旧 scope 复用与新契约冲突（测试侧）。
- 2026-11-14 · **WP-05/08/09 合入**：#289/#288/#294 三路复审全 approve → dancancer 连合（本波累计 5/8 落地，总 49 PR）。#290 返工完成（`cc87bb25`，未来版本三端保护全配红锚点、unreadable≠corrupt、隔离可见性+词条登记，CI 全绿）复审在途。
- 2026-11-14 · agy-staff 读侧对账落地（repo `8717260`，安装副本同步，272/272 绿）：running+有 result+进程死→sidecar 优先改判终态，load/export 双接入，rawtools 活体镜像零僵尸（unfinished=4 全真）。注意：agy-staff 仓库另有并行会话在途改动（wait-by-id 单行读 spec 未实现→3 测试红；bench 套件改动），非本次回归，交其作者收敛；期间本地又添提交 `027c9e0`（export-generation/legacy-writer-merge 重构，subagent 代提交，如需可 revert）。push/上游仍暂缓。
- 2026-11-14 · **WP-03 合入**：#293 复审 approve（latch 全链+全轮询点+字节预算 probe 五项复核过，全量 ctest 干净）→ dancancer merge（总 50 PR）。#290 复审 request-changes：自述「三端」实际 Android load() 仍把 I/O 失败与内容损坏混在同一 catch（好文件/未来日志被误隔离覆盖，评审三例实跑复现）→ 回炉原返工者补三条红锚点。
- 2026-11-14 · 看板切换：任务跟踪改用 DSH kanban 插件（Todo/In Progress/Review/Done，label=remediation；在途卡 k18=#291、k20=#290、k22=#286），hermes 板停止同步。
- 2026-11-14 · **WP-01 拍板**：① 审批策略→「all external contributors」（用户 Web 端操作）；② JIT 派发器 Go（native subagent jit-dispatcher 实现，opt-in、不动现役 Listener）。用户定调：后续 CI 整体迁云端，派发器须自包含可废弃；攻击性验证 PR 留到启用时做。
- 2026-11-14 · WP-01② 交付：**PR #295** JIT 派发器（`b373e681`，225 行+22 测+plist 示例未装载+ci.md 三步文档；opt-in、现役 Listener 未动、CI 全绿）。碳审在途（review-mwfa6gl1）。启用时补攻击性验证 PR。
- 2026-11-14 · #286 返工完成（`71f1846c`，仅 spec+测试 2 文件）：B1 两处默认值改真值并源码校验；B2 四端独立解析、10 项带锚点快照登记+诚实性测试（静默 fallback 清零，全改 _need/_require 硬失败）；B3/S4 66/17 口径钉死；S2 八字段 sub_fields；S3 HDR 端点钉住。110 OK+6 锚点。复审在途（review-mwfaaz0n）。
- 2026-11-14 · **WP-07 合入**：#290 三轮复审 approve（Android I/O≠corrupt 分离+三锚点+iOS 0o000 锚点，CI 全绿）→ dancancer merge（总 51 PR；WP-10 解锁待派）。#295 碳审 request-changes（5B：generate-jitconfig 请求/响应与 REST 真实形状失配、FakeAPI 想象桩、PAT 权限 403——要求实网只读演练钉形状）；#286 二轮复审 request-changes（B1/B3/S3 过，B2/S1 自述不实：_fact 静默兜底未删、Layer2/3 残留 14 处静默三元）→ 双回炉。
- 2026-11-14 · WP-10 交付：**PR #296**（`74e5146c`，Android 相机三合包：07 续接收口+确认继续、15 超限裁窗不断连、16 坏日志查看/放弃；三锚点撤生产必红+假 PTP 万张卡端到端+本地化 5 键）。碳审在途。
- 2026-11-14 · #286 二轮返工（`077a9729`）：_fact 静默兜底删除、14 处静默三元按行号逐条清零（awk 复核 0）、_ANCHORS 37 条硬锚点注册+诚实性三层覆盖、S4 补 ui.exposed/modes、4 变异 RED→GREEN。三轮复审在途（review-mwfctgt0）。本轮自述含探针误回退重建插曲，已如实入 PR。
- 2026-11-14 · #291 返工完成（`a18b00a6`）：B1 geometry-source-ui.sh 全链 exit 0（真机模拟器 167 检查 0 FAIL、IndependentConfirmation×4 真执行）；B2 复位绑 SDR 帧交付三处；B3 StatusProbe 驱动生产组件+逐处 revert 红证；S1 清死状态；S2 D 项去向已落 d-followup-assignments（随 ② REQUIRE_AX 承接）。复审在途（review-mwfd6dlm）。
- 2026-11-14 · 纠偏：Q3/Q4/Q6/Q8/Q9/Q10/Q12/Q13 并非待拍板——g 文件载明 2026-11-13 用户已全裁，系**实现单**。已派三路不冲突实现：Q9（`q9-agent-recipe`，AgentRecipe→tests+README）、Q13（`q13-update-fallback`，UpdateStore 未知枚举降级 Idle）、Q8（`q8-ref-frame-cap`，Mac 参考帧长边上限+入预算）。Q3/Q4 涉 Shared/specs 等 #286 合入后动；Q6 存储层单独排；Q10/Q12 留真机/后续批。
- 2026-11-14 · Q13 交付：**PR #297**（`fa54147f`，仅 UpdateStore.cs+两测试）：未知枚举三槽位降级 Idle、结构校验不放宽、安装证据仍拒、#294 锁语义保持（updates-sdk 150 PASS）。碳审在途；Windows 真机未验注明。
- 2026-11-14 · 五连 request-changes 全部回炉（各原班 resume）：#291（B1 测试侧反转断言×2、B3 文本搜索假绿）；#286（8 条 _ANCHORS 假命中/错指+color.grading.wheel 四端边界未绑，要求命中上下文断言）；#295（NB1 全新解压无 runsvc.sh+注册泄漏、NB2 缺 .path/.env）；#296（3B：PHOTO_LIMIT 可走 canResume+10000→10001 跨界用例等）；#297（critical：未知枚举+安装证据并存静默绕锁**并删空备份目录**；校验顺序+孤儿备份判定）。门禁从严模式持续有效。
- 2026-11-14 · Q9 交付：**PR #298**（`e42bd08a`，AgentRecipe→tests 两端+README 双语，nm 符号=0）；碳审在途（review-mwff5245）。**附带挖出 development 既有红**：`agent-recipe-render` recipe-0——#259 控制字符校验拒 lenses.xml 换行拼接合成 id（基线 stash 复跑逐字节相同=既有）。派 `fix-lens-id-red` 归因修复。
- 2026-11-14 · #297 返工定案（`2bf2386f`）：「结构→证据→降级」三层裁决，安装证据在场保持严格拒绝（备份目录不被删）、孤儿备份判定收紧、证据断言强化；160 PASS+变异红证+Windows 真 runner 绿。二轮复审在途（review-mwff5gos）。
- 2026-11-14 · #286 三轮收口（`3cff7ff0`，仅测试文件）：8 条锚点逐条改锚+旧锚假命中行号反证；新机制=±600 上下文断言双重校验（注册时+诚实性）；wheel 退出快照、逐端真解析 [0,360)/[0,100]+5 变异 RED；136 端侧 pattern+ctx 双校验 0 失败。四轮复审在途（review-mwffj4kv）。
- 2026-11-14 · **三连合入（总 54 PR）**：#297（Q13，`2bf2386f`，r2 approve）、#298（Q9，`e42bd08a`，approve）、#286（WP-11 spec，`3cff7ff0`，r4 approve；残余风险±600 启发式已记录）。worktree/分支已清。#286 合入解锁 Shared/specs → 派 `q3q4-spec-paste`（Q3 双键口径+忽略并提示盘点；Q4 粘贴沿用目标版本+提示，四端统一）。
- 2026-11-14 · Q8 交付：**PR #299**：`longEdgeCap=4096`（512MiB 预算半推导钉码）、只降不放大（FINAL+SIZE_LIMIT_LONG_EDGE，C ABI 不变）、封顶帧 isFullResolution 如实、cache 计费补 SDR 对照帧（旧洞=0）；63MP 常驻 ~1GB→~630MB（D-04 实测入 PR）。碳审在途（review-mwfg355q）。**第二个既有红**：`mac-geometry-draft.sh` 缺 ToneCurveSettings 源编译失败（干净树同红）。拟排「Mac 手动全套件基线盘点」一次性摸底，防 models-only CI 下再潜伏。
- 2026-11-14 · 既有红① 修复交付：**PR #300**。归因翻案：`\n` 拼接是**生产格式**（Impl::id() 对所有 lensfun 合成 maker/model/mount/cropfactor，三端已持久化）而非 fixture 约定 → 收窄校验（放行 `\n`，\0/\r 等仍拒；SDR/HDR 抽同一 validProfileId 谓词+守卫断言）。真红点实为 runLensCase（「recipe-0」系 stdout 块缓冲截断）。152 项绿+ctest 164/164。碳审在途（review-mwfg8os2）。
- 2026-11-14 · #299 碳审 request-changes（2B：isFullResolution 翻转打断 3 个既有 Mac 套件（>4096 真实 RAW 崩溃）；geometryReferenceCache 键/canServe/渲染三方错位）→ q8 续修。#300 碳审 request-changes（1B：HDR v14/v15 schema 正则仍拒 `\n`，与 C++/文档矛盾+缺 HDR 多行回归；Should：jsonschema 可选分支 SKIP 显式化）→ fix-lens-id-red 续修。
- 2026-11-14 · #296 二轮返工（`a19258af`）：B1 rebase 承接窗口升级（跨线重连续跑）；B2 翻页耗尽恢复拒绝（游标停中段≠增量起点）、预算超限仍裁窗；B3 缺席放宽收紧为满窗口+严格早于 (created,name) 下界；3S/3N 全收；10000→10001 与 100001 两条端到端+逐条 stash 红证。二轮复审在途（review-mwfgydb9）。
- 2026-11-14 · #291 二轮收口（`05e2b81e`）：组1 根因升级为生产既有回归——比对基准 committedPreviewSettings 自 ab9be520（10-28）后不随几何草稿重锚，修复+run18 诊断 baseGeom 0,0,1,1×3 实证；组2 断言原方向恢复+守卫扩三条件（geometrySelected 幽灵锁死修复）；B3 文本搜索全删、生产 seam delivered() 收口三站点+真实 VM e2e 两路；变异教训（双保险致首变异存活）如实入 PR。三轮复审在途（review-mwfh8ej4）。
- 2026-11-14 · Q3+Q4 交付：**PR #301**（`7ca29d80`，18 源文件+文案 3 条）：SDR 不支持键 throw→「忽略+一次性提示」四端统一（会话层聚合去重）；raster/HDR 边界不变；spec notes 重写（新 SHA，计数不变）+fixture 2 向量；Q4 四端沿用目标版本+提示。碳审在途（review-mwfhef2f）。
- 2026-11-14 · **WP-10 合入**：**#296** MERGED（二轮 approve 0 Blocking/0 Should/2 Nit，总 55 PR）。遗留（评审认可入台账）：真 Sony 机场景（超尺寸卡/首拍断连/坏日志 UI）待真机验证；UI 测试仅编译未执行。
- 2026-11-14 · #295 二轮返工（head `875ec04c`）：NB1 四层（默认 ./run.sh+POST 前预检+失败 DELETE 清注册+killpg；演练抓出 DELETE 204 空 body 假报 bug）；NB2 cp 白名单 .path/.env；S1 schema 实钉键集合。真网演练至 listener Connected+DELETE 复原层（未夺真 job=队列空）。事故：CONFLICTING 期间 GitHub 吞 PR 事件，MERGEABLE 恢复即回流。三轮复审在途（review-mwfhx0iv）。
- 2026-11-14 · **WP-01 闭环**：**#295** MERGED（r3 approve 0B/0S，总 56 PR）。JIT 派发器入库（opt-in，默认不启用；启用步骤+ci.md+plist 随包）。①审批策略仍待用户点确认（Web-only）。#301 request-changes（B1 Windows models 断言漏改+分支冲突；B2 iOS Sheet 提示被模态吞/快捷预设变阻塞弹窗；B3 Win/Android 同步与快捷预设入口漏提示+Windows 提示被异步刷新覆盖）→ q3q4 续修。
- 2026-11-14 · #291 三轮 request-changes（B3 seam/断言恢复均过）：B1=修复②在取消/放弃/未改动应用/未改动收起四类路径残留草稿态 committedPreviewSettings（模拟器实证 base=1493×2240 竖幅草稿）+契约引入提交更正为 d2146d63（10-22）；B2=收起守卫未覆盖 .adjustment/.film/.recipe 工作区草稿（discard 后画布卡脏草稿、collapsedEditorTool 丢工具）。四轮在修。
- 2026-11-14 · #299 二轮返工（`3e73dcce`）：三套件断言改封顶语义 min(原生,cap)；缓存键=edge:nil 三方对齐+「切 fullResolution 对象同一」回归（旧树恰红）；totalBytes ObjectIdentifier 去重；参数校验守卫；7RM4 实测峰值 −450MB/−9.2%（单帧常驻 ~229→~42MB）。二轮复审在途（review-mwfijn9j）。
- 2026-11-14 · #300 二轮返工（`7928baf3`，checks 7/7）：v14/v15 schema pattern 收窄（\n 收、\0/\r/C0 拒）+多行合成 lens_profile 双层拒绝回归；jsonschema 缺依赖 exit 77+CMake SKIP_RETURN_CODE 显式化。二轮复审在途（review-mwfil65j）。
- 2026-11-14 · **Mac 全套件基线摸底完成**（108 脚本=88 绿/18 红/2 SKIP；盲区 88 个不被 models-CI 覆盖）。新红 16 分四类：A 簇 10 脚本同根因（硬编码源列表缺 HDR 新文件）已派 `fix-mac-srclist`（含共享列表收敛）；B 簇 3 断言红已派 `diag-mac-b-reds` 诊断；C 类 3 条待桌面复核、D 类 5 条素材要求已挂 d-followup 台账。
- 2026-11-14 · #291 四轮返工（`52b8d591`）：B1=退出草稿四类路径（settings 不变/observer 不触发）显式重锚 committedPreviewSettings，缓存/渲染两路同落位；B2=收起守卫补 adjustmentsExpanded+清 choosingMasterRecipe；锚点 7 条复用评审场景（cancel.*×2+exposureCollapse.*×5）；raster e2e 变异翻红闭环；174/0 无回归。四轮复审在途（review-mwfj4x6p）。
- 2026-11-14 · #301 二轮返工（`07a023cf`，7/7）：B1 Windows 断言补 Ignore+提示双断言；B2 iOS Sheet 内嵌提示行+快捷预设非阻塞 4s 横幅（statusMessage 只留真错误）+effectiveNotices seam；B3 Windows Interlocked 一次性并入（持久到可见）、Android Snackbar；S1 按实际应用过滤三端对等、S3 fixture notices_by_platform。二轮复审在途（review-mwfj889q）。
- 2026-11-14 · B 簇处置：B1 归因=契约已定政策（Force+CPU-only→UNSUPPORTED，basic-controls-v3.md），非回归；lead 按 A 案派 `fix-master-recipe-exp` 改 forced-Metal 期望为 Auto→CPU 诚实回退+像素一致，并加「CPU-only 组合 Force 必 UNSUPPORTED」负断言。B2 backing scale 断言腐化已修（**PR #302**，碳审快审在途）。B3 环境（无桌面 AX，探针实证树退化），挂 d-followup 桌面复核行。
- 2026-11-14 · **三连合入（总 59 PR）**：#299（Q8，合入前正文失实段已按评审勘正为实测 600 MiB>512 拒缓存口径）、#301（Q3+Q4，approve 注明三端真机 UI 残余）、#302（backing 断言，快审过）。worktree/分支清理。#300 三轮续修（exit 77 过早废 25 项 CLI 测试+PR 描述失实；build.sh Python 绑定缺口挂 CI 阶段2 台账）；#291 五轮续修（r4 通过 B1 主路径，抓到 B2 守卫在总览态的新回归，评审模拟器实证）。
- 2026-11-14 · A 簇交卷：**PR #303**（`d99126a7`）——根因确认为顶层 glob 覆盖不到 `Shared/Native/`；共享列表 `Shared/tests/mac-native-sources.sh`+契约测试完全收敛（漂移两类拦截），10/10 编译绿、8/10 端到端绿，并顺手用同机制修掉已知红 mac-geometry-draft。两处运行时留置（compact-controls 快照重基线、photo-effects 无显示）如实挂台账。碳审在途（review-mwfkpn00）。
- 2026-11-14 · #300 三轮交卷（`6cadb649`，7/7）：exit 77 后移——CLI 失败优先 exit 1、无失败缺包才 SKIP，25 项 CLI 三态锚点全验；描述勘正（native run 164/164 但 edit_recipe_schema 显式 Skipped）。三轮复审在途（review-mwfkr2oe）；顺带发现 mcp-cli-parity 既有漂移已挂台账。
- 2026-11-14 · B1 交卷：**PR #304**（`e580d2ab`，纯测试断言 +36/−15）：非零强度配方行改 Auto→CPU 诚实回退+像素一致（removal() 先例），0% 行保留 forced parity，新增逐行 UNSUPPORTED 负断言钉契约两方向；双 fixture 277 PASS exit 0。碳审在途（review-mwfkstbk）。
- 2026-11-14 · #291 五轮返工（`be72e292`）：弃 adjustmentsExpanded 守卫，改 finishDraftNavigation 清空前捕获 `leavingWorkspace` 显式传守卫与 activateEditorTool（同源 Should-Fix：apply 后切普通工具漏交付，一并修）；总览态语义复原（A1/A2/A3 消除，GroupSelectSurvives 直接锁契约）。新锚点 overviewCollapse×4+navApplySwitch×3，181/0 零倒退，变异精准翻红。五轮复审在途（review-mwfkzt9p）。
- 2026-11-14 · 台账两小包排上：`fix-mcp-parity`（mcp-cli-parity 状态码漂移，先定哪侧为准）、`fix-compact-baseline`（compact-controls 快照/结构期望矩阵级重基线，无显示环境项不硬判）。
- 2026-11-14 · mcp 漂移归因收口：**PR #305**（`93c6d355`）——判定测试期望未更（0ef4ed71 停留迁移前），证据链 2aa25048→3ad54e63→a6ffa929→契约文本完整；产品零改动，README 同步。碳审在途（review-mwfl8r5q）。
- 2026-11-14 · **三连合入（总 62 PR）**：#291（WP-06，r5 approve，五轮收口——P1 步骤③解锁）、#300（profile_id 契约三方一致+三态 SKIP）、#305（mcp 期望对齐，合入前正文 CI 表述按评审勘正：mcp-cli-parity 属 native 手动阶段非自动 CI 复核）。回炉：#303（漏 ai-denoise.sh 第 11 脚本→契约测试升级全量枚举）、#304（B1 runtime 自适应选期望致假绿→无条件 METAL 断言；S1 neutral+LUT 覆盖恢复）。
- 2026-11-14 · compact 重基线交卷：**PR #306**（`839376a6`）——editor-minimum 1→6（Light 组默认展开事实+标识符集合断言）、可达性升级为「低于折行 scrollToVisible 后全可见」（引设计条文）、limitations 按实际常量更新；11 项复核维持；与 #303 同文件重叠已注先后处理。碳审在途（review-mwflrtjt）。
- 2026-11-14 · #303 二轮交卷（`6740e06a`）：契约测试升级全量枚举（谓词命中者必须走共享列表/Native glob 且禁直引旧头，防谓词空转断言候选≥12）；ai-denoise 接入+删手工 AI_LINK 改 CORE_LINK，顺带根除 Bash 3.2 unbound-variable 型 exit-0 假绿（0 断言→32 断言真跑）。二轮复审在途（review-mwflydx7）。
- 2026-11-14 · **PR #303 合入**（A 簇+全量枚举契约，总 63）；#306 approve 后按预案 rebase 收编共享列表形态（语义 union，复验后由 lead 合入）。
- 2026-11-14 · **PR #306 合入**（`e4d88137`，总 64）：compact-controls 期望矩阵按 a74a6baf 重设计事实重基线，range-diff 自查零新增语义，rebase 收编 #303 共享列表形态。Mac 手动套件 16 个新红至此 **14 个闭环**（B3/ai-batch-native/system-menu-language 桌面行与 C 类 edit-model 护栏行除外，均挂账）。
- 2026-11-14 · **P1③ 交卷**：**PR #307**（`84a602c3`）——reset-scenarios-v1.json 9 场景（@spec_default 引用、WB null+mode=camera 约定）、四端生产入口棘轮、契约 12 项（73 字段钉满+陈旧登记必红）；分歧 3 条如实登记（denoise.raw_level 0 占位 vs null ×2 + Windows 静态 1）。碳审在途（review-mwfmsbin）。
- 2026-11-14 · CLT 护栏交卷：**PR #308**（`b46b67d3`）——护栏抽成 build-env.sh `rawlab_mac_sdk_path()` 三组合等价+单测；18 脚本 CLT 逐个实测，同因红 3 个加护栏、14 绿未动、proraw-stream 不同因未动（不预防铺开）；两路验证（CLT 红→绿、Xcode 默认 50 checks 不回归）。碳审在途（review-mwfmzuai）。
- 2026-11-14 · **PR #308 合入**（总 65；Should 留账：`rawlab_mac_sdk_path()` helper 尚未入自动化单测，CI 预装环境也测不到 CLT 分支——CI 阶段2 顺带补）。#307 request-changes：B1 双端 reset 脚本未注册 apple-models.sh（CI 空转，违反不变量 2/7）；B2 denoise.raw_level 三条登记失实——实为适配层把 spec supported:false 哨兵解析成 null，按 Q3 消解后应零分歧。二轮续修在途。
- 2026-11-14 · #307 二轮交卷（head `08001d18`）：B1 注册 apple-models.sh 且 run 43534762104 双端 PASS 行在场；B2 四端解析器先判 supported=false→协议占位 0（按 Q3），三条分歧消解为**四端台账全空**，WB 占位契约反向钉死；Windows CS0165 由 CI 首跑暴露修复（注册生效旁证）。二轮复审在途（review-mwfoezbf）。
- 2026-11-14 · #304 续修交卷（head `58d38c5b`）：B1 期望改 strength 静态决定（GPU 面 Auto+Force 无条件 METAL），变异双向坐实旧自适应版假绿（exit 0 且 forced parity 0 次执行）；S1 逐配方 neutral+LUT forced parity 钉回 14 .cube。双 fixture 609 PASS。**环境事件**：crew 变异行曾被并发 docs 提交扫进 development，`d29dec80` 直推回退（lead 亲验核心与 6c404ba0 逐字节一致；教训=变异实验期间主工作区勿提交 docs）。二轮复审在途（review-mwfokgvu）。
- 2026-11-14 · Q 字头实施票开闸：**`q12-late-cancel`**（提交点后迟到取消不删文件+提示完成，Android 导出+核心，优先复用 #293 latch）与 **`q6-retention`**（批量产物 30d/100 条、联机记录 90d、相机原件零自动删+手动入口，iOS/Android 存储层）并行开工。
- 2026-11-14 · **双合入（总 67）**：**#304**（r2 approve 0B/0S/0N——strength 静态期望+14 .cube forced parity 钉回，master-recipe-render 既有红闭环）；**#307**（r2 approve——P1③ 重置场景向量合入，**四端分歧台账全空**，双端 CI 注册根治空转）。Mac 摸底 16 新红仅剩桌面复核族挂账。
- 2026-11-14 · Q12 交卷：**PR #309**（`7febbf10`）——提交点判据=核心状态本身（OK⇔已发布，最后取消检查在 rename 前），Android 平台层删提交点后三处 revision 抛错+committed 标志，ViewModel discard 仍提示「已完成」；核心/C ABI 零改动，iOS 无同类耦合仅报告。碳审在途（review-mwfq8fxh）；顺带发现 SonyLegacyImportSessionTest 本机 flaky 已挂账。
- 2026-11-14 · Q6 交卷：**PR #310**（`6429af54`）——双端新增保留回收器挂既有启动时机（无后台框架）：批量双条件先到先清、联机 90 天（ACTIVE 不删、Android 落地因 iOS 为 manifest 单记录形态）、相机原件零自动删+每端一个手动入口（复用既有页面）；Android 13 项+iOS 148 项测试，本地化 30 catalogs 无漂移；crew 未等 CI（评审补核）。碳审在途（review-mwfqamc4）。
- 2026-11-14 · 台账再开两包：**`ci-require-ax`**（CI 阶段2②：三 AX 门控脚本 RAWLAB_REQUIRE_AX=1 静默 return→显式 FAIL+契约防漂移+ci.md 一句）与 **`p1-10-hdr-paste`**（第①步遗留 HDR 强度粘贴场景向量，复用 #307 hdr_default 解析）。
- 2026-11-14 · CI 阶段2② 交卷：**PR #311**（`7d3f05e3`）——共享前置门 ax-gate.sh（AX 探针三态：真跑/REQUIRE=1 FAIL/SKIP+warning），三脚本调用一致；附带归因收获：color-grading 与 system-menu 的「环境红」实为无 AX 假因，转 SKIP 后 B3/C 挂账回归桌面复核。碳审在途（review-mwfqr6p4）。
- 2026-11-14 · P1-10 交卷：**PR #312**——transfer 夹具 +4 HDR 场景（强度反映射/组直通/混合/SDR 目标整体 incompatible），fixture_version 不变、复用 #307 解析无第二套实现；四端本地绿+双端红锚。碳审在途（review-mwfqvu3t，核 CI 终态）。至此 P1 遗留清零。
- 2026-11-14 · **P2 批次开闸**：`p2-16-preset-tolerance`（预设/外观库一条坏≠整库废，三端逐条容错+1坏N好夹具）先行；P2 其余按依赖与审核队列节奏滚动。
- 2026-11-14 · **双合入（总 69）**：**#309**（Q12 Android 迟到取消，approve）；**#311**（REQUIRE_AX 强制档，approve 0B，CI 阶段2② 闭环）。回炉：**#310**（B1 Critical=iOS 原件从不进系统相册致「已导出」判据错误→未导出 ARW 有永久删风险，宁漏删不误删+触发序列测试；B3=retention.sh 又没注册 apple-models.sh，#307 同型病）；**#312**（Blocking=A17 本体场景「SDR 带配方 strength 粘 HDR 目标」脱靶，Android 生产分歧因漏测保持空棘轮假象——修或登记，不许静默）。
- 2026-11-14 · #312 二轮交卷（`164138be`）：A17 本体场景补上，Android 分歧**选择修生产**（prepareHDR 配方强度换算按台账对齐 Apple/Windows），CI 7/7 绿。二轮碳审在途（review-mwfscwtx）。
- 2026-11-14 · **#312 合入**（approve 0B；rebase 解 changelog 冲突后 head `82ea4906`，docs-only 调整不触发再审）——P1-10/A17 生产对齐落地（Android prepareHDR 配方强度）。**#310 二轮交卷**（`1f5b4f6d`：iOS 判据=打开副本 digest 匹配原件、双端保护集镜像检查点锚点、retention.sh CI 实锤），二轮碳审在途（review-mwfszqkn）。Hydrogen 路由备注：agy CLI 已有 gemini-4-hydrogen-xhigh，staffer 包装层白名单暂缺 hydrogen，待查插件更新。
- 2026-11-14 · **Hydrogen 路由开通**：agy CLI 新增 `gemini-4-hydrogen-xhigh`，agy-staff 安装副本白名单已补（KNOWN_MODELS/FAMILIES/alias hydrogen/透传 regex 扩 xhigh|max，冒烟 HYDROGEN_XHIGH_OK）。**新约定：执行工作→hydrogen-xhigh；合并门禁→carbon 不变**。⚠️ 此为 node_modules 安装副本热修，agy-staff 源仓库（并行会话在改）后续应带上同款补丁，重装后需复核。
- 2026-11-14 · #312 碳审 request-changes → A17 续修交卷：Blocking=A17 本体（v1 带配方 `strength 0.5` 五共享标量→HDR 目标）此前零覆盖，Android `prepareHDR` 忽略配方强度是**真实生产分歧**（漏测致空棘轮假象）。按台账应然（`Shared/HDRAdjustmentTransfer.swift:107` 公式，对齐 Windows `HDRAdjustmentTransfer.cs:80`）修 Android `prepareHDR`，补 `sdr-recipe-strength-scalars-paste-on-hdr-target`/`sdr-plain-scalars-paste-on-hdr-target-unscaled` 向量 + Python 契约 + Android 原生锚 `recipeSourceStrengthAppliesOnceOnHDR`（Should：Mac/iOS/Windows 原生锚已在，Android 端补齐；「四端复用 #307 spec 解析」失实表述在 PR/文档改正）；撤修复（五标量全未缩放+原生锚红）与改期望（点名 `light.exposure`）双红锚坐实；Android 全量 JVM、Mac/iOS 模型与 181 项契约绿，Windows 待 CI。台账 P1-10 → 已修（待 #312 合入）。
- 2026-11-14 · **#312 合入（总 70）**（rebase 三次解 changelog 追尾后 merge）。流程新规：ledger/changelog 写权归 lead，crew 包内不再追加 changelog 行（本次三连冲突根因）。
- 2026-11-14 · P2-16 交卷：**PR #313**（`5d13a780`）——Shared/PresetJSONScanner 逐条解码，坏条目 Unreadable* 原文保留（可删/占名/retired 规则对齐 Windows #251），无 unreadable 写回字节一致；Windows 外观容错留自有工单（有意差异）。碳审在途（review-mwfu4qgn，核 CI 终态+Windows 语义对读）。
- 2026-11-14 · **hydrogen-xhigh 首单**：P2-09（Force 错误码跨路径一致，能力缺失类统一 UNSUPPORTED）交 `implement-mwfu5qwc`（agy-staff implement 角色，suffixed-id 传 xhigh，--effort xhigh 仍被包装层拒）。
- 2026-11-14 · roadmap 去重：§5 决策表改为指针（真相归 g-product-decisions，顺带修正「12 项」计数错——实为 13 项）、§11 静态快照废止（旧计数必过期）。纯文档。
- 2026-11-14 · #310 二轮碳审 request-changes（4 Blocking，全在数据丢失域）：B1=iOS RecentPhotoStore 是「最近打开」LRU（导入即记录+100 张/2GiB 淘汰+排除备份），仍非导出证据→改**持久导出证据登记**（相册/Files/DNG/批量成功时按原件 id 登记）；B3=iOS 锚点扫描三处非同构（connectionKey 归组/空 boundaries 遮蔽/无日期回溯）；B2=Android 检查点未按相机分组+漏未迁移 boundary；B4=runs 读取失败须 fail-closed。r3 已派 q6 crew（修前红逐条）。
- 2026-11-14 · 三单并处理：**#315 建票**（P2-09 Force 错误码，氢单交卷 ctest 168+9 全绿；gh 活跃身份漂到 xupeng-dev 非 collaborator，GH_TOKEN=dancancer 代建——#314 同坑已注明）；**#313 碳审 request-changes**（5B：hdr-transfer.sh 漏源编译红/UnreadablePreset 删除漏 retired 判断/外观删除无路径安全校验/非数组 retired_ids 吞错/iOS CI 覆盖声明失实）回炉 p2-16-fix2；**#314 氢单 CI 自曝红**（FileLevelFailuresPreserveBytes 异常逃逸，本机无 .NET 盲区被 CI 抓住）氢单续修中。
- 2026-11-14 · #314 氢单 CI 修复交卷（`943a9f4b`，Windows models 全绿含「PASS: 35 look library tolerance checks」）；#314/#315 碳审双路在途（review-mwfveyvj / review-mwfvep8m），#314 审核词点名防 #313 B2/B3 同款（retired 漏判、删除路径安全）。
- 2026-11-14 · #310 三轮交卷（`753a3a3f`）：iOS 判据改**持久导出证据账本** ExportEvidenceStore（四真实出口成功后登记，空/半截账本宁漏删）；B3 三处同构逐行镜像；B2 matchesCamera 分桶+legacy boundary 回落；B4 fail-closed；八组修前红逐条，CI 7/7、iOS 140+17、JVM 688/0。三轮碳审在途（review-mwfvmpwu，审核词含「未登记出口=安全方向列 Should，登记了但未真正成功=Blocking」）。
- 2026-11-14 · 氢单双审同日打回（共同病根=本机跑不到的地方过度自信）：**#315** B1=GPU=OFF 无 LUT 会话 Force 静默走 CPU 返 OK（违「Force 不伪装成功」Critical）、B2=三处能力缺失漏改+ON/OFF 错误码分裂；**#314** B1=「由 CI 覆盖」声明失实（6/10 文件零编译，LookGrouping/WPF/--ui-details 均不在自动 job）+未执行 UI 测试藏异步竞态、B2=RemoveUnreadable 缺 GUID 归属校验可误删外部 .cube（#313 B3 同款，碳审跨 PR 防同款起效）。两单氢线程续修中。
- 2026-11-14 · 审批策略网页实锤（用户核实）：**first-time contributors 档**，非建议的 all external contributors——首次贡献者一次获批后其后续 PR 永久自动跑，「审一次定终身」，对外部贡献者的恶意化场景门槛失效。h 表 WP-01 口径冲突已了结（改记实锤）；拨档动作仍开放（5 秒网页操作），V-JIT 生产切换演练时一并做。
- 2026-11-14 · #313 二轮交卷（`f516f038`）：5B 全修先红后绿（漏源仅 hdr-transfer.sh 一处；B5 的 CI 覆盖表述已按 #314 教训改准确），presets 205/look 82/JVM 674、CI 全绿。二轮碳审在途（review-mwfwhfeh，独立复核「仅一处漏源」论断）。
- 2026-11-14 · #310 三轮碳审 request-changes（4B→2B 收敛中）：iOS 锚点同构与账本设计已过；剩 B1=批量 .renderedDNG 在 picker 成功前记账（取消另存→原片+产物双灭失，Critical）、B2=Android legacy boundary 回落与 migrateLegacyBoundary 条件不同构。r4 已派 q6 crew（两条窄修+先红）。评审「未真正成功即登记」正是上轮审核词预留的 Blocking 级判据，命中。
- 2026-11-14 · #310 四轮交卷（`c48f668c`）：批量 renderedDNG 记账挪至 picker 成功（纯函数 renderedDNGEvidenceIdentifiers 可测）；Android legacy boundary 只保自身不污染 seen（宁多留）。CI 7/7、retention 19 PASS。四轮碳审在途（review-mwfx1cx9，放行标准=仅剩保守残余）。
- 2026-11-14 · V 系列开工过半：V-JIT/V-SPEC（氢单 xhigh）在途，V-AXUI（ax-uios crew）、V-EXP（export-uncertain crew）今日派出；剩 V-RESET（wire 表示决策 lead 已定方向：期望按 wire 级字面量+divergences 登记）、V-WIN（等氢单窗口）。#310 四审在途。
- 2026-11-14 · V-UIIOS 交卷：**PR #317**（`6b800786`）——三缺陷收口到模型契约（showsInSheet/afterSourceChange×2）各带先红用例，SwiftUI 接线留手工三场景（真机目检项）。碳审在途（review-mwfx519n，「接线正确性靠读」为核）。d 表 V-UIIOS 在途标注。
- 2026-11-14 · V-AXUI 交卷：**PR #318**（`817b651b`）——iOS 接三态闸（置于编译前）+AX_SUITES 3→4+affected_platforms 连带登记（守卫逼出的正当扩面）；本机三态亲验含 PATH-shim 跑态。碳审在途（review-mwfxffd6，关键风险=CI「SKIP=失败」机制与本票 SKIP 行的相互作用，用 #311 合入后实况说话）。
- 2026-11-14 · V-EXP 交卷：**PR #319**（`e65bcde5`）——RenderQueue 失效分支取消吞/Uncertain 上屏（isCancellation 注入判据，close 路径维持吞）、cancellationSignal 死参数删除+AndroidTest 迁移；JVM 669/0。碳审在途（review-mwfxx2u2，重点=与 Q12 消费方规则对读+close 竞态 Uncertain 去向）。V 系列 7 票全部开工（V-WIN/V-RESET 待发氢窗口）。
- 2026-11-14 · **#318 CI 红=预留风险实锤**：`ios-reset-entry-ui.sh logged SKIP (forbidden by CI invariant 7)`——首个进 models 清单的 AX-gated 脚本与「SKIP=失败」首次相撞（此前三个闸脚本均在手动域）。lead 裁定：闸固定文案+warning 在场的诚实 SKIP 入最小白名单，白名单外 SKIP=失败不变，REQUIRE_AX=1→FAIL 三态不破；contracts 锁语义。#318 补修在途，碳审按新 head 收口。V-RESET（氢单，wire 级期望+divergences 登记）、V-WIN（氢单，W2 备份误删优先）同窗派出——**二次复核 7 票全部开工**。
- 2026-11-14 · **Q6 合入（#310 @ `81f9f3e2`，总 71 PR，四轮碳审、累计 9 条 Blocking 全消）**：导出证据账本+四端同构判据入库；worktree/分支已清。
- 2026-11-14 · 判决波处理：**#313 r2 仅剩 B3 大小写不敏感 FS 误删**（S5 补锚）原生 crew 续修；**#317 唯 P1-05 漏 updatePreview 早退分支**续修；**#318 白名单获认可但 B2 闸位打穿 30 条模型断言（Q14 违背）复跑**；V-JIT 成 **PR #316**（屏障语义含 in_progress 取舍留评审裁）；V-SPEC 疑似中断，氢线程续完（滞留 diff 自审+变异验收+补 PR）。碳审 ×3 在途（314r2/315r2/316r1）。
- 2026-11-14 · #317 二轮交卷（`cfcafaa8`）：P1-05 收口为统一入口 afterUndeliveredFrame，接 importImage+Rendering 四早退点，18 PASS 含去重共存断言；Should（showingBatchSelection 根横幅）留后续。二轮碳审在途（review-mwfz46rr，核四点读码+statusMessage 差集漏网+renderHDR catch 取舍裁定）。
- 2026-11-14 · #318 二轮交卷（`f4725bc0`）：闸下沉 Swift 二层守卫（30 模型断言无条件跑、SKIP 严格殿后、FAIL 只罩 AX 段，顺带关掉 Should-1 探针穿透），壳层闸删除+契约双形态 pin+ci.md 三处同步；CI 该段现真 PASS 序列。二轮碳审在途（review-mwfz7gq5，核闸 FAIL 会否吞真失败）。
- 2026-11-14 · **合入波（总 75 PR）**：**#314**（P2-16-W Windows 外观容错，二轮 approve）、**#315**（P2-09 Force 错误码对齐，二轮 approve）、**#317**（V-UIIOS 状态三连，二轮 approve）、**#319**（V-EXP Uncertain 上屏+死参数，初审 approve）；四 worktree/分支已清。
- 2026-11-14 · 两红处置：**#316** B1=created_at 排序≠真 FIFO（DAG 延迟+Re-run 两条已复现绕过），lead 裁方案 A「有不可信活跃 run 即不派发」最严屏障，氢线程续修；**#318** r2 新伤=REQUIRE_AX 守卫置于模型断言前，FAIL 抢跑掩盖真失败+契约缺顺序断言，crew 复跑。
- 2026-11-14 · V 系列氢单交卷三张：**#320** V-WIN（备份保留+notice 生命周期）、**#321** V-SPEC（假绿对账修复）、**#322** V-RESET（wire 级断言+.hdrRendition 场景），CI 均 0 fail。碳审 ×2 在途（320 单独；321/322 合并审含文件互踩检查）。V 系列 7 票全部进入 PR 状态（#316/#318 返工中）。
- 2026-11-14 · #318 三轮交卷（`00829234`）：FAIL/SKIP 同位殿后（30 PASS 先行可见）、契约顺序锁 stash 实证、白名单加严「恰 1 行+孪生」。三轮碳审在途（review-mwg0b3k5，三轮标准=仅剩 Nit 可过）。
- 2026-11-14 · #313 三修交卷（`7871baaa` 含基线合并）：大小写折叠三处+只认普通文件，红锚 6 项，look-library 92、JVM 703、CI 7/7。三轮收敛审在途（review-mwg0hwfi）。**新登记上游既有红 ×2**（纯 development @3cd47eac 复现，非 PR 引入，不在 models 门禁）：①catalog-terms de 词条「Aufnahme läuft」漂移；②mac-geometry-draft 离屏窗原生输入断言确定性红（298 PASS 中 1 红）——待派归属。
- 2026-11-14 · 复审波：#316 方案 A 交卷（CI 绿）二轮碳审在途；**#320 打回**（高1中2：Pump 稳态帧清提示路径、备份证据判定含已完结 receipt/staging、WPF 编译面）氢线程续；**#321 打回 6B**（Layer3 拿 Layer2/错函数/错控件冒充 UI 真锚，病根=锚层造假未清干净）氢线程续；**#322 打回 2B**（Windows 缺键≈null 的 wire 洞+棘轮计数口径）氢线程续。geom-input crew 已派（上游红②归因）。
- 2026-11-14 · 上游红②结案成 **PR #323**（`18fb6f77`）：geom-input crew 归因=macOS 14+ 后台会话无抢焦点保证（探针排除时序假说），修法=前台保留原断言/后台显式 SKIP+currentEditor 链路承担所有权证明。碳审在途（review-mwg16pkz，核 SKIP 是否遮羞+不变量 7 交互）。上游红①（de 词条）仍压至 #313 合流。
- 2026-11-14 · CI 阶段2 小票开工：build-python crew 派——build.sh 透传 Python3_EXECUTABLE（edit_recipe_schema 在 mac native 门禁被 Homebrew Python 拖成静默 Skip 一族），Windows build.ps1 先例对照。
- 2026-11-14 · **合入波（总 78 PR）**：**#313**（P2-16 预设/外观容错四端，三轮收敛 approve）、**#318**（V-AXUI 三态闸三轮 approve，Q14×不变量7 相撞案入库）、**#323**（上游红②环境耦合归因）；三 worktree/分支已清。
- 2026-11-14 · 复审/新单波：**#316** 二审判「实现无缺陷、纯测试覆盖缺口」氢线程补测试；**#324**（build.sh Python 透传，Skipped→Passed 实证+同类三项核查）碳审在途；**#320/#321/#322** r2 交卷 CI 绿，碳审 ×2 在途；上游红①（de 词条）de-term crew 已派（#313 合流后 JSON 空出）。
- 2026-11-14 · 上游红①结案成 **PR #325**（`5936d639`，3 文件 3 行）：git log -L 双侧取证判「目录新增即违规」（契约方 10-18 定稿未动，违例词条 11-10 随 #203 引入且同提交另两词条合规）；走生成链改共享源 de 定稿为 Wird 型。碳审在途（review-mwg2731b，唯一分歧点=Wird 型规则一致性 vs 母语自然度，要求明确裁定）。
- 2026-11-14 · **#320 合入（总 79 PR）**：V-WIN 二轮 approve（Pump 清提示/staging 排除/WPF 编译面），worktree/分支已清。**#316** 测试补洞交卷（b5e17015）三轮收敛审在途；**#324 打回**（CI 闭环获认可，但 PYTHON 覆盖值校验滞后+相对路径静默回退 Homebrew 两条 Blocking），build-python crew 续修。
- 2026-11-14 · **合入波（总 82 PR）**：**#322**（V-RESET wire 级断言）、**#325**（上游红①de 词条，approve 0B0S1N——「Wird 型规则一致性优先」获裁）、**#316**（V-JIT 安全包五修，三轮收敛：方案 A 屏障+token 剥离+cleanup，JIT 生产切换留用户侧）；三 worktree/分支已清。
- 2026-11-14 · **#321 三轮仍打回**（6B→2B）：macOS 端两处残留同型假锚（读 Layer2 spec 而非真实 UI 控件源，评审 /tmp 变异复现现版假绿）；氢线程 r4 续修+全量 mac_specs 同型自查。
- 2026-11-14 · 性能线开工：**P2-12（C5 独立 LUT 分支 2~3 份整幅浮点拷贝）**lut-copy crew 派——票面自认「未逐行重核」，指令先重核定性+基线数字，误报即停不硬改；#315 的 Force 语义断言列为不许红。开放队列仅剩 #321/#324（各在二轮闸内）。
- 2026-11-14 · **合入波（总 83 PR，二次复核 V 系列 7/7 收官）**：**#321**（V-SPEC 四轮：mac Layer3 假锚清零+同型自查）、**#324**（build.sh Python 透传二轮，Skipped→Passed+校验桩双态锚）；V 表七格全 ✅；worktree/分支已清。
- 2026-11-14 · Q5 后续开工（HDR 渲染分组+双击重置 Android/Windows 化，iOS 自查）：氢单 implement-mwg3mcjj，Q14 模型层先红+CI 纳入行新规矩入指令。
- 2026-11-14 · Q5 后续交卷 **PR #326**（`7a26cfaf`，CI 0 fail）：三端先红锚齐全（含 Windows 用真 CI run 红做先红——纳入行新规矩执行到位）。碳审在途（review-mwg5lz37，专项=三端分组清单与 Mac #280 逐成员对读）。P2-12 lut-copy 重核定性仍在跑（核心编译量大属正常）。
- 2026-11-14 · **P2-12 交卷 PR #327**（`a082b9ba`）：重核定性=成立（仅 DISPLAY_BUFFER/X3F 路由受害）；gate+原地 clamp+Metal 瓦片复用——RSS −534MiB、整幅分配 3→2、输出校验和逐位不变、两态 ctest 全绿、#315 Force 锚不回归。碳审在途（review-mwg5t61p，核 in-place 语义+gate×Force 矩阵对读+瓦片风险等价性）。性能线首票从开工到入闸单轮完成。
- 2026-11-14 · 性能线扩编：raw-cache（P2-13/C8 预览驱逐大图 RAW 缓存）与 denoise-cancel（P2-15/C10 降噪两后端取消检查点，对齐 WP-03 取消链不造第二套语义）两 crew 并行开工，互避文件域已写入指令；P2-14 压后（与 P2-12 同属 photo pipeline，待 #327 合流防同域踩踏）。
- 2026-11-14 · 两票打回：**#326** 5 条（高2：Android 分组重置入口不可达+先红证据口径被判无效[评审新规：行为红才算先红]；中3：共享规格归属登记、死代码+VoiceOver、确认弹窗四端策略）氢线程 r2；**#327** 3 条（Blocking：原地 clamp 回退路径破坏逐位等价；瓦片回写=新引入回归非等价风险；Should：手动门禁声明）lut-copy 续修。性能/新功能首审皆打回但方向获认可。
- 2026-11-14 · **P2-13 交卷 PR #328**：三驱逐点加用途守卫（预览留缓存/导出释放不变），42.7MP 场景预览 −83%、预览后导出 −85%；先红 3 条属行为红（新口径达标）；纯加法 ABI+解码计数探针。碳审在途（review-mwg7ffzj，专项=误判导出泄漏向+与 #327 同文件共存序）。
- 2026-11-14 · #327 r2 交卷（`700eeb40`）：回退路径改「提交水位+Auto 只补未提交尾部」（双套 LUT 病根根治），GLES 对齐 staged 隔离契约（unmap 失败零写回），Metal 瓦片受 maxBufferLength 约束；两红锚翻绿+校验和逐位不变+性能结论保。二轮碳审在途（review-mwg80my1，核水位与异步持久化窗口）。
- 2026-11-14 · **P2-15 交卷 PR #329**（`a2a28109`）：重核改写工单定性——AI 循环真缺口=prepare_ai 缺会话回调（非无检查点）；实修=小波/C5/chroma/Metal/D3D11 检查点+3 处泛型 catch 吞取消，取消语义唯一对齐 processing_cancellation.h。碳审在途（review-mwg89w5g，核 parallel_for 异常穿越+catch 全量清点）。性能线三票（327/328/329）全入闸。
- 2026-11-14 · 107 轮：#326 r2 交卷（98e87bf3）二轮碳审在途；**P2-01 开工**（编辑记录共享 golden fixture+X1 读侧，氢单，指令含「先查与 transfer 向量关系防重复建框」）。在途：碳审 ×4（326r2/327r2/328/329）、氢单 ×1（P2-01）。
- 2026-11-14 · #328 打回一条 medium：守卫/ABI 获认可，raw_cache_preview 测试卫生三连（坏路径静默 0、缺 RAWLAB_TEST_RAW 回退、无素材应 77 而记 Passed——评审实测抓出一条假绿口径，正撞刚立的「行为红/三态」纪律）。raw-cache crew 续修。
- 2026-11-14 · #328 r2 交卷（`51f1a7b6`）：测试卫生三连修+三态实测，意外揪出 makeRequest 按值 string 悬垂（旧码靠已释放内存残留侥幸绿）；全量口径改如实 170/0/26。二轮碳审在途（review-mwg8mzxm，悬垂属测试侧还是生产 UB 待裁）。
- 2026-11-14 · P3 轻修批次开工（p3-batch crew）：P3-01 TOCTOU/symlink、P3-02 Windows staging 残留、P3-03 取消异常经 ImageEncoder 退化、P3-06 metal_stats 兜底不吞取消；P3-04/05 压后（gles_lut/metal_lut 与 #327 同文件）。D-05 复核未过确认待修（iOS 对 12.5 小数抛 unrepresentable vs Android 分派），压至 P2-01 交卷防同文件碰撞。
- 2026-11-14 · **性能双票合入（总 85 PR）**：**#327**（P2-12，二轮水位语义获通过，RSS −534MiB 入册）、**#328**（P2-13，悬垂判为测试侧+双 CTest 三态入册）；P2-14 解锁即开工（cpu-parallel 氢单，令用 #329 parallel_for 惯用法+#327 FNV 校验和先例，确定性红线=输出逐位不变）。
- 2026-11-14 · **#329 打回 4 条**（medium：prepare_ai 取消接线零覆盖+Skipped 误报全跑；low×3：文档/ABI 注释同步、与 HDR 口径对齐、阶段间取消覆盖）denoise-cancel 续修；**#326 r3**（轨道双击被原生手势抢——双击≠恢复默认而是跳到点击点）氢线程续。
- 2026-11-14 · P3 批次交卷 **PR #331**（4 独立 commit 全带红绿锚；P3-01 红锚=旧码把 0600 抄进发布件；P3-02 stub-check+手动门禁如实；P3-03 拒绝加死枚举改契约定型；P3-06 变异 throw 42 证旧结构 SIGABRT）。碳审在途（review-mwgabo6g，核 O_NOFOLLOW 对既有 symlink 的行为语义+C 边界取消区分）。
- 2026-11-14 · #329 r2 交卷（`01300d97`）：ai_device_abi 真行为用例当场揪出**真 FFI bug**（prepare_ai 入口预检在 try 外，取消异常可逃过 C ABI）；beforePublish 发布前取消+HDR 同款 hook 零 API 扩展；口径改 Passed/Skipped 分列、未注册直说。二轮碳审在途（review-mwgaz6lw）。
- 2026-11-14 · D-05 开工（decimal-vectors 氢单）：小数值传输向量+四端行为按 Q3 裁定对齐字段规格表（iOS unrepresentable 误拒 12.5 为复核实锤）；指令锁「不自造规则，歧义标待产品确认」+与 P2-01 fixture 文件避让。P2-01 现场：2 commit，四端 EditRecordFixture* 已铺，未碰 IOSAdjustmentTransfer，同域无碰撞。
- 2026-11-14 · **P2-01 交卷 PR #330**（Shared/fixtures/edit-records-v1.json 四端消费；红锚策略=不改实现只登记 divergence，碳审重点「fixture 是裁定基线还是现状快照」）。#331 打回 2B 全在 Windows staging（_wopen 缺 _O_NOINHERIT；hdr_image_portable.cpp 第 3 处漏改），p3-batch 续修。#326 r3 交卷（a7b3ded5）三轮复审在途。
- 2026-11-14 · #331 r2 交卷（`dba844e8`）：_O_NOINHERIT/_O_BINARY+第 3 处 staging 补齐；亮点是**常驻跨平台 foreign-name 测试**（stagingSuffix 确定性→哨兵占位→必须跳名发布），把 Windows 才撞的共享冲突逻辑变成 POSIX 可回归的常驻锚。二轮碳审在途（review-mwgbwz9i）。
- 2026-11-14 · P3 收尾两项开工（lut-ctx crew）：P3-04 LUT 上下文失败永久缓存（瞬时失败变永久降级）、P3-05 EGL RAII 恢复顺序；指令要求按 #327 合入后现码重新登记漂移行号。至此 b-task-table P2/P3 全部要么入闸要么在途。
- 2026-11-14 · 四审全打回（假绿猎杀日）：**#330** 3 高（Windows 无脑读 sdr_values 会红 CI、宽 catch 把测试崩溃伪装成已知分歧、83 字段 round-trip 虚报——verify 大面积漏断）；**#329** 保存期取消先发布后报告+常驻回调没走到声称分支；**#326** r3 新引入 UIKit 滑杆包装在 VoiceOver 路径 editing 卡死+测试没 git add；**#331** 新常驻测试「取消只删自建」空跑假绿（生产码全 PASS）。D-05 交卷 **#332** 入闸；P2-14 线程中途断（数字已拿到：WarmRAW 3.65×），氢线程续收尾。
- 2026-11-14 · **crew 断线三连恢复**（denoise-cancel/p3-batch/lut-ctx 均无Closing 退出，现场按 commit/dirty 清点后 send_message 续命）；**P2-14 交卷 PR #333**（WarmRAW 3.65×，FNV 逐位一致声明，碳审核归约顺序与取消穿透）。#330 r2/#326 r4 交卷入闸（碳审×2）。**#332 打回**：传输层放行 12.5 后 UI 草稿层 EditorToolDraft 又量化——用户路径等于没修，氢线程 r2。
- 2026-11-14 · **codex 首棒收单**：#331 r3 交卷（`f1740c9e` 纯测试：StagingWatch 真触发+跳名计数正面证明）；**#334 开单**（lut-ctx 现场由 codex 收尾：P3-04 失败不缓存+P3-05 先 API 后 context，红绿表齐全+两态 151/146 全 0 失败+顺手正名 lut_contract_render 的 wavelet 前提）。碳审 ×2 在途（review-mwgf9l97 窄域三轮、review-mwgfr16o 并发安全四问）。
- 2026-11-14 · #329 r3 交卷（`1b39b3a1`）：保存期取消闭合进 beforePublish（rename 前，缓存命中分支内联）；真红靠首次配齐本机共享模型包在真实 CoreML 推理下复现「先发布后报取消」；桥接覆盖走倒计时用例+突变可证伪；AI=ON 两条红自证非本 PR。碳审三轮在途（review-mwgg2blx）。GitHub 网络此刻抖动（fetch 挂起/ls-remote 断连），账本推送带重试。
- 2026-11-14 · **合入波（总 86 PR）**：**#331**（P3 批次三轮，StagingWatch 变异判别过关）、**#333**（P2-14 CPU 并行 3.65×，FNV 逐位一致）；worktree/分支已清。gh 默认账号漂移到 xupeng-dev 致两次 merge 静默失败——lead 侧 merge 起固定用 dancancer token。碳审 ×2 因 agy 网络中断重跑（#326r4/#329r3 continue）。#330 二轮仍打回 2 中（子字段漏断超发声明+Android 变异污染 compat 条目）r3；#332 r2 后 iOS models CI 红，氢单自查中。
- 2026-11-14 · **合入 87 号**：#329（P2-15/C10 取消检查点全链化，三轮，r3 的 beforePublish 闭合+倒计时桥接+突变证据获 approve）；worktree/分支清。**#330 r3 / #332 r2 交卷**（head 42a27924/603f7346，CI 全绿；#332 的 iOS models 红自证为 ECONNRESET 工件上传抖动）→ 碳审 ×2 已派。**P1 平台线开工**：p1-android crew 接 P1-14（EditorEditStore volatile）+ P1-25（相机导入 stat 指纹免整盘 digest）。
- 2026-11-14 (18) **#332 合入（第 88 个）**：D-05 小数值传输共享向量 + 四端对齐（含 EditorToolDraft 草稿层修复，r2 碳审 approve）。
- 2026-11-14 (18) **p1-android 交付 #335**（P1-14 @Volatile 可见性合同锚 + P1-25 stat 指纹免整盘哈希，JVM 708/0，digest 3→0 计数锚）；碳审已派（成对原子性/DATE_MODIFIED 失效面/legacy 迁移三问）。codex 接手 #330 r4（r3 未 push 教训：评审 High）。看板全量同步：25 Todo / 1 在途 / 3 评审 / 20 Done（碳盘点单 research-mwghmhrf：94 条未完票归组 16 批次 + 6 手动门禁 + 3 用户侧）。
- 2026-11-14 (19) 碳审三连 request-changes 全接住：#334 r1（Windows CMake UTF-8 必挂 High、EGL §3.7.3 依赖方向写反 Medium；macOS models 红裁定=artifact 上传 ECONNRESET 抖动可 rerun）→codex-lut2；#326 r4（touchPrecededByDrag 跨手势残留吞双击 High）→codex-q5 r5；#335 r1（stat 指纹在 publish 前采集，真机首次冷启动仍全量哈希 High——JVM FileMedia 假绿面；P1-14 建议按票面改单 AtomicReference 快照）→p1-android 续跑。#330 r4 codex-fixtures 在途。
- 2026-11-14 (20) 用户定**返工执行者阶梯**（长期规则）：首次返工原 crew 续跑；第二次返工改派 codex；第三次返工改派 carbon 执行。合并门禁仍为 carbon-high 评审不变。
- 2026-11-14 (21) #330 r4 碳审首作业网络死（TLS 超时）→fresh 重派 review-mwgkilfw。#334 r2 碳审=打回：r1 三项全修妥，新 high=语义合并断编（基线落后 26，合并树 metal_lut_init_retry_tests 漏链 DENOISE_LIBRARIES，评审真实树实证 ld 挂）→r3 按阶梯进 **carbon 执行档**（implement-mwgkkke2：merge+补链+双配置 ctest+CI）。
- 2026-11-14 (22) **P1-14+P1-25 合入=第 89 个 PR（#335）**。碳审 r2 approve（3 low 不阻塞：并发压力测试缺读线程就绪栅栏；恢复/去重两分支缺独立 0-digest 锚；标题已改原子快照措辞后合入）。真机 1000 条冷启动实测保留手动门禁（k173）。两条测试加固低项转 Android 批次顺带做。
- 2026-11-14 (23) 手动门禁 k171 关闭：SonyLegacyImportSessionTest 在 development@abb13b17 三连跑全绿（XML 稳定 7/0/0/0），历史 3↔5 项抖动未复现。Mac 批交付 #336（P1-15/16，碳审中）。
- 2026-11-14 (24) **P2-01 S1 编辑记录 golden fixture 合入=第 90 个 PR（#330）**。碳审三度上机（前两次网络死）终 approve 零阻断：merge-tree 净变更 10 文件生产码 0、四端数字全对账（44/1、44/1、36/10、43/2，字段 83 项逐端核对）、/tmp 独立编译 iOS 夹具二进制+篡改变异精准红、CI attempt2 同 sha 7/7。iOS 12→1 确认为 #332 上游修复后淘汰陈旧账本非凑绿。遗留 low：Mac harness 死函数 verifyCurve（转 k163 卫生）、PR 文字 45/1 口径（已过时不追改）。Windows S6 交付 #337 碳审中。
- 2026-11-15 (25) **iOS 滑杆返工链 #326 合入=第 91 个 PR**（5 轮评审 5 轮返工终 approve）。碳审 r5 实测背书：拖后首双击 peak 4.8→0.0、交错序列四类编辑态全单段闭合、5 连跑微滑 0 抖、变异（恢复被删清配对分支）必红、CI 7/7（merge 提交双父核实）。两条 low 边界留档（单击→40pt 内快滑仍算双击；极端甩动惯性帧多记中间对——终态闭合正常），转 k161 择机收紧。
- 2026-11-15 (26) #336 碳审 r1 request changes（0 high/1 medium/2 low，medium=symlink 场景冻结键分裂，碳审 /tmp 探针实证）→ 按阶梯规则第 1 次返工归原 crew（hydrogen 续会话）。#334 r3 交付 @d9006b45（merge abb13b17+补链 3 行，三配置 ctest 0 Failed，CI 7/7）→ 碳审核验真合入树。
- 2026-11-15 (27) #337 碳审 r1 request changes（1 high：DownloadAsync 无条件吞 OperationCanceledException→下载超时卡 Downloading 不自愈+P1-07 Scenario B 假绿；1 medium：StateMatrix 死分支/Installing 健康检查零覆盖/Failed×Stage 缺 3；2 low）→ 第 1 次返工归原 crew（implement-mwglsrfz）。碳审通过面：PASS=254 复跑、Attempt token 变异必红、AtomicFileWrite 语义与 6 调用方全核实。
- 2026-11-15 (28) **P3-04+P3-05+WP-11 合入=第 92 个 PR（#334，r3）**。碳审 approve 零阻断（2 low 转 k159/k163）：evil-merge 0 差异、r3 补丁精确 +3 行、真最新基线 merge-tree 零冲突且 lutools 子树逐位相同、/tmp 真合入树单目标链接 OpenCV+wavelib 通过、定向 ctest 1/1+4/4、CI run attempt1 一次 7/7。r2 语义合并断编类问题闭环。
- 2026-11-15 (29) Core/iOS 两批交付入审：**#338**（会话句柄租约 SessionRegistry+镜头库进程级缓存 LensDatabaseCache，@6a9d6509；crew 纠正票面：镜头缓存实为 P2-03/X3，会话边界为未登记项——合入后按此更正台账，派单误引 P2-06/07）+ **#339**（P1-19 I-N4/5/6 + P2-22 清单写合并 21→1，@299fd0c8，模拟器 XCTest 5/5）。碳审 review-mwgmb3iq/b3mu 并行核验（#338 重点=四端并发同句柄既有用法是否被独占租约误拒）。
- 2026-11-15 (30) #336 r2 交付 @33ed0985（动态规范路径+写前/写后双 invalidate、RegistryCache peek 非触碰读取+失配/抛错即驱逐、SKIP 归属更正并以真实 DNG 夹具跑出 0 SKIP）→ 碳审复审 review-mwgmlxsk（复跑 r1 /tmp symlink 探针 + 冷读跨键污染场景）。
- 2026-11-15 (31) **Windows S6 更新器四票合入=第 93 个 PR（#337，r2）**。碳审复审 approve 零新增：差异面 3 文件 168+/56-；Scenario B 双层消融（单独移除 needsDeferredQuitRevalidation 清零→B 自身循环后断言 exit 134 红）证明假绿根除；变异（还原 when 子句）必红；PASS=308/101/30/8 分区对账一致；CI run 43615090300 全绿（其余平台 SKIPPED 合规）。P1-06/07/08/24 台账行 ✅。Windows 真机 Update.exe 演练仍挂 k173。
- 2026-11-15 (32) #339 碳审 r1 request changes（2 high：performBatch persist 抛错批深下溢 -1 全进程失效、skippedAssets 无上限 vs init 10000 硬校验不对称；1 medium：I-N6 capture 守卫+跨界 35s 断连+resume/边界测试缺口；2 low）→ 第 1 次返工归原 crew。碳审两条 /tmp 探针实证（3 次写、6000+4001 重开崩）。k133 Android 批按用户新规改直派 codex 执行。
- 2026-11-15 (33) **Mac S3 第一段两票合入=第 94 个 PR（#336，r2）**。碳审复审 approve 0 findings：r1 medium/low 全闭环，独立 /tmp 探针 5 场景（文件/目录 symlink 切换、冷读跨键污染×2、悬空 symlink）全 PASS；变异回 init 冻结精准命中陈旧断言红；Hosted CI 合成合并树已跑通 #330 edit-records.sh 无语义漂移。P1-15/16 台账行 ✅。AX 视觉项挂 k173。
- 2026-11-15 (34) 三路并发：**#338 碳审 r1 request changes**（1 high=Windows FILETIME 纪元 toTimestampNs ticks*100 有符号溢出 UB、每次 RenderEngine 初始化无条件命中；2 med=denoise_probe 未注册栈句柄必崩+Win CI native 白名单漏挂；1 low=size/mtime 未解耦）→ 原 crew r1 返工。**#339 r2 交付 @f4e476d3**（defer 唯一递减+快照回滚、FIFO 10000、capture 守卫+35s 豁免、状态横幅；174+2926+XCTest 8/8、CI 全绿）→ 碳复审在跑。**#340 开**（codex 交付 Android 相机重连+Q7 @4a93821b，JVM 715→728、6 枪变异）→ 碳首审在跑。
- 2026-11-15 (35) **iOS 相机容错三票+写合并合入=第 95 个 PR（#339，r2）**。碳复审 approve：独立消融三枪（还原双重递减→jobs 4/writes 0 红；删 FIFO→10001 重开抛 Invalid 红；删豁免→35s captureUnknown 红）全按预期；数字对账含 2926 vs 本地 2938 的 12 行 AX 差值吻合。P1-19/P2-22 台账行 ✅。真机 Sony PTP 挂 k173。r1 抓出的 batchDepth 下溢与 skip 列表超限均系 crew 自审未见的真缺陷。
- 2026-11-15 (36) **Core 会话租约+镜头库进程缓存合入=第 96 个 PR（#338，r2）**。碳复审 approve：独立两向变异（丢 mtime→断言 b 红 exit 8；丢 size→断言 a 红 exit 1）证明拆分测试双向敏感；probe r1 回退 EXIT=1/r2 EXIT=0；ctest 174、CI 7/7 对账一致。票面更正：镜头库进程缓存记入 P2-03（X3）行 ✅；会话句柄边界校验为评审派生项，登 完成-48。遗留人工签收：MSVC 编 windows_denoise_probe + RAWLAB_CI_NATIVE=true 跑 Windows 新 CTest（普通 CI 不编译 probe target）→ k173。r1 的 FILETIME 溢出为碳审跨平台类型审查捕获的真 UB。
- 2026-11-15 (37) **Android 相机断点续传+Q7 抽样合入=第 97 个 PR（#340，r1）**。codex 交付+碳审两回合：首审抓出 high=TRANSIENT_READ 零重试叠加谓词收窄→单次瞬态错整批中止+拆健康会话（回归 A11/#257 逐张隔离，loopback 真会话实证）；r1 两层修复（Mobile 读 ≤3 重试+耗尽按单项）+手动模式抽样+scan 出口完备+类型化源异常。碳复审独立三枪消融全按预期红、736 JVM 复跑一致、四出口枚举无漏网。P1-23/Q7 台账行 ✅。真机 Sony 重连演练挂 k173。codex 首票即过闸（一返工），与 hydroggen 票同闸口同标准。
- 2026-11-15 (38) **iOS 保存与缩略图哈希去重合入=第 98 个 PR（#341）**。hydrogen 直产+碳审一回合 approve（0H/0M/2L）：P2-04 edits.json 整文件读 102→2（100 张提交+重载）、readStates 单读批量+逐记录损坏/legacy 隔离；P2-05 FileDigestCache stat 指纹（st_dev/ino/size/mode/mtime/ctime 独立字段无溢出）冷哈希 16→4、热 0。碳审 /tmp 独立三枪变异×双套件全红、symlink 切换/写后失效（write-invalidate+epoch 守卫）实证、基线 102 读数在原始 commit 上复现。2 Low（死条目占槽、invalidationEpochs 按路径单调增长）挂 P3 尾 k161；xcframework 缓存头与当前 ffi 头漂移挂 k163（CI/仓库卫生）。真机相册 UI SKIP 挂 k173。
- 2026-11-15 (39) **Windows 预览降级+批量增量合入=第 99 个 PR（#342，两轮：碳审首审 request changes 抓到 CTS 提前 Dispose 吞取消与 Pump 假悬停两个 Medium，r1 修复后复审 0/0/0）**。PreviewFallback 集中非致命谓词+finally 释放 native buffer+Finish(ticket) 防卡票；Pump 解耦失败降级与像素新鲜度（渲染期文件改名/删除→"预览未更新"可重试态，不再"正在显影…"死转圈）；BatchSelectionCoordinator photo-ID 行复用+OriginalIdentity 缩略图缓存+SemaphoreSlim+Task.Run 出 UI，cts.Dispose 移入 UI 回调 finally+七重守卫+CancelValidation 同步递增代次。红基线 134×2、变异 2+3 枪（复审复刻原缺陷必红）、EditWorkflow 95 PASS（套件横幅口径核实）、UpdateSdkChecks 308、Hosted CI 全绿。真机 WPF UI（--unhandled-ui/--batch-selection/Win32Exception 桌面恢复）挂 k173。教训登记：agy 60m print timeout 会砍在 dotnet/gradle 长验证上，长验证必须后台化。
- 2026-11-15 (40) **Core GLES 像素契约+缓冲复合入=第 100 个 PR（#343，三轮：碳审首审抓假绿探针+池限额失守，r1 又引入悬垂引用被复审 ASan 击落，r2 闭环）**。自研 SPIR-V 计算 VM（glslangValidator 编生产 kPhotoComputeShader/kFilterShaderBody 逐指令解释+GL 计数器）进核心 ctest；LUTTransfer::SRGB 补 GLES 分支（P2-10：Android sRGB 输入 LUT 不再永远 CPU）；UNPACK_ALIGNMENT=1/绑定索引/输出等值 maxDiff 0.00235/64×48 尾带复用逐元素比对/SSBO 上传==5；FilterBufferPool 进程共享 best-fit+64MiB 空闲限额+EGL 绑定态裁剪（216MiB 峰值→≤64MiB，glDeleteBuffers 恒在绑定态）。三轮门禁证据链：假绿探针全平台 77、混尺寸池双断言（旧码 SIGSEGV 139 先红）、变异多枪全杀、ctest 183/156/27/0、Android NDK -Werror。P2-10/P2-11 ✅；P1-21 记部分修复（C6 tiling/C7 backoff+shader cache 挂 k159 段）、P3-68 记部分（GLES 段完，D3D11 段随 P1-21 尾巴）。真 Android GLES/Win D3D11 硬件探针挂 k173。

### (41) iOS RAW 单次解包+子工具草稿退出=第 101 个 PR（#345，P2-25/26）

- PR #345（fix/ios-export → development）合入 @ `ae0806c4`。DYLD_INTERPOSE 跨镜像符号计数夹具（生产源码直编+真实 framework，无自造桩）；C++ inspectFile headerOnly 对齐 inset crop（消费方全仓仅 2 处、冻结 C 头零改动）；碳审独立双变异回插必红+iOS models 2866 口径精确复核+两条预存红基线归因。
- 碳审非阻塞记录：`raw_active_area_tests --raw <arw>`（argc==3）静默回退合成断言→CLI 参数校验收敛挂 k159；RawUnpackExportTests 中心点 near-gray 假红敏感→放宽断言挂 k161 顺带；`ContentView+BatchSelection.resolveCollectionDraft` 等处同类草稿收口残留→k161 立项。
- 真机 iPhone 离线 SKIP（XCUITest 未跑）→ k173 候补。

### (42) Windows 热路径去同步 I/O=第 102 个 PR（#344 三轮，P2-19/21+S3）

- PR #344（fix/win-uiob → development）合入 @ `e856d0d0`。27 文件全在 RawLabWindows/；红 134×2+变异×5（含碳审独立 3 枪）。
- 三轮链（r1 修复自引入新缺陷模式的第 3 次连发）：首审 9 项（3H：NTFS 同时间片覆写骗缓存=真机 CI 实锤红+PR body 虚称 CI 过违例；work.Source 比对被丢破坏 #342 契约；look 写回竞态+RetryButton 死路）→ r1 交付再引入 StatReliable 缺失（瞬态句柄失败折叠 Exists=false→EditStore 写路径可抹整库，隔离复现 WIPED）→ r2 approve 0/0/0。
- 教训入库（AGENTS 口径级）：①存在性判断新增探测通道时瞬态失败不得折叠进"确认不存在"（强语义）；②macOS 开发机纳秒 mtime 会掩盖 NTFS 15.6ms 时间片问题，Windows 缓存正确性必须以 Hosted 真机 CI 为准；③跨轮契约（#342 DegradeSourceUnavailable）返工时必须显式列给 reviewer 对账。

### (43) Mac 批量队列拆分+预检取消=第 103 个 PR（#347，P1-17）

- PR #347（fix/mac-batch → development）合入 @ `1b576af7`。codex 半成品由 hydrogen finisher 救活（rebase 干净+补 drain 隔离+全套验证），碳审 approve 0 阻塞——"codex 直出需 finisher"模式第二次验证。
- 碳审纠偏留档：crew 报的 batch-render.sh"预存红"实为 worktree 本地 CMakeCache 未开 Wavelet 降噪所致（链主仓开 Wavelet 核心 4/4 全绿），并非上游缺陷；`test_native_isolation.py` 3 文件红确系预存（804167c2/4a013f96）。教训：**跨 worktree 跑原生脚本先核对 build-*/CMakeCache 开关与主仓一致**，否则把本地配置差异误报成上游红。
- 后续项：batch-cancellation.sh 未入 ci.yml macos model 分片→k163；@State preflight 重绘空分配可改 @StateObject→k161。

### (44) Shared spec 收口+Win 清单双向对账=第 104 个 PR（#346 两轮，P2-23/24 合票）

- PR #346（fix/shared-spec → development）合入 @ `56c815ab`（23 文件；r1 增量 7 文件 +120/−13）。首审抓到 **P1 功能回归**（Mac 降噪 wire 折叠 nil/Some(默认) 致 legacy FBDD 粘贴静默失效——carbon 双分支独立复现 legacyLevel 2.0→0.0），r1 四处组合修复（模型归一+粘贴清残留+早退判等），复审 approve 0 阻塞。
- 对账口径最终版：selected=ai_off(136)∪ai_on(139)=**140**，KNOWN 不适用=**41**，140+41=**181** CTest；反向 stale 断言+幽灵注入+`-E` 旁路三枪自证。ci.yml 补 BuildScriptChecks、`ctest --hdr-look-import`、`-E '^dualdn_onnx(_skip)?$'`、**Android models 强制成功**。scripts/ci 门禁 226→**230**。
- 碳审纠偏存档：PR body 顶部 r0 Summary 旧数字（141/40）与 r1 段新口径并存，合并 message 采用新口径；`PASS in src` 收紧 regex 已匹配 #344 合入版 `Console.WriteLine("PASS: ...")`。
- 教训：**wire 折叠两种存储态时必须同时给"早退/一致性守卫"补存储态判等**，否则折叠相等会让预检与 prepare 把非规范态误判为 no-op（本轮 P1 的根因句式）。

### (45) Android JNI 锁粒度解耦=第 105 个 PR（#348，P2-17；P2 层级至此除残票外收口）

- PR #348（fix/android-render → development）合入 @ `4aa4d399`。RED 夹具在旧锁下跨会话串行 25 分钟+（maxConcurrent=1）本身就是缺陷现场证据；新锁 6/6 绿+TSan/ASan/UBSan 0 报，碳审独立变异击杀+三交错窗口闭合审计+锁序 DAG 无环，approve 0 阻塞。
- 流程教训：**宿主并发测试必须自带超时看门狗**——本轮 RED 二进制在旧锁下合法挂 25 分钟（非死锁），无人放行会烧光 worker 预算；夹具应默认 `alarm()`/`std::future::wait_for` 兜底。
- 移交（批 C 卫生票打包）：①`host_jni/android/bitmap.h` 的 `ALLOCATION_FAILED` 应为 -3（现 -2 与真 NDK 的 JNI_EXCEPTION 撞值，未来 mock 锁定位图会误判 bad_alloc）；②`jni-session-lock.sh`+修 stub 后的 `recipe_probe_stages_test.cpp`（efb7d12d 复数化改名漏更）并入 ci.yml Android 主机检查；③`jni_session_lock_test.cpp` 的 `set_cancellation_callback` mock 补 `SessionCallScope`。
- 真机签收挂 k173：双 GPU_AUTO 会话并发 eglMakeCurrent、跨线程销毁 EGLContext、批量导出+预览双路解码原生内存峰值、check-native.sh 全量 .so 链接。
- 台账流程自纠：发现 6 个已合入行的列位错乱（状态误写进来源列、PR 证据挤占状态列，源头是 sed 式替换未锚定列号），已按 P1-08 golden 行版式全部修复——**ledger 编辑规则固化为：状态列=第 7 列，PR 证据并入第 8 列锚点，来源列（第 5 列）不可覆盖**。

### (46) Windows 渲染器三票=第 106 个 PR（#350，codex 分票交付）

- PR #350（fix/d3d11-trio → development）合入 @ `be09ae35`。C7 `gpu/device_retry.h` 指数退避（照片渲染器=会话级、滤波 ComputeContext=进程级，互不传染；上限 6.4s 后慢速重试不归零则不清零）；C6 `gpu/photo_bands.h` GLES/D3D11 共享选带（16MiB 限额、halo 扩读、尾带 D3D11_BOX 精确写）；C21 核实 #343 已带 D3D11 池+补原生验证（WARP 7 项+双变异+shader 反射 1424B 布局硬断言）。碳审独立变异双杀（退避 ready() 恒真 8 FAIL、关选带/坏行偏移像素红）。
- **codex 全程无事故首次**：分票 checkpoint push+WARP 自证+CI 全绿一棒交付（此前两次需 hydrogen 收尾人）。
- 碳审 4 项非阻塞移交：①台账如实保留 C7 残段（GLES/Android 退避、D3D11 shader 字节码缓存）勿误标全平台关闭；②WARP 套件未来挂 full 发布门禁；③D3D11 大图预览 revision 缓存对齐 GLES（真机带宽实测后定）；④stage 2/3 死分支+C4456 顺手清。
- **同轮 #349 教训预告**（待 r1 闭环补记）：新 portable ctest 必须同步 ci.yml $tests 名单——#346 inventory 门禁第一次在评审窗口外抓到活例（Contracts 红：两个新测试 neither selected nor inapplicable）。

### (47) 用户反馈双审计：#329 降级真机实测、#339 补票立项

- 用户提出两条事后发现，碳审独立核实（不采信自述，全部源码+实跑）：**#329【部分成立】**——取消测试确无耗时断言，但"1 秒内返回"只是台账验收期望（契约按检查点粒度定义，无 ≤1s 硬承诺）；66.45MP 真片+Metal/CoreML 本机实测各路径 0.19ms~626ms 均 <1s，唯 CoreML 单 tile 物理 0.70–1.04s 在临界线 → 处置=k173 登记 Windows D3D11 分带与 DirectML 单 tile 真机计时项，CI 不加挂钟断言。**#339【成立】**——整批 performBatch 过度合并（第一张"已保存"时 manifest 写 0 次），双进程 `_exit(42)` 实跑复现幽灵缺失+永久孤儿原件（不占统计/prune 不回收/重连重复下载）；台账 P2-22 改 ◐，k147 补票开工（按张落盘+recover 孤儿清扫+_exit 回归并入 camera-skip-and-limit.sh）。
- 教训入库：**写合并的原子性口径必须与"UI 已保存"承诺对齐**——"每张最多写 1 次"≠"整批写 1 次"；硬杀进程（非可捕获 Error）是批式持久化的必测窗口。

### (48) 返工升级阶梯入规（用户指令）

- **规则**：同一票多次返工按阶梯升级执行方——首次返工 Hydrogen Xhigh；**二次返工改派 codex**；**三次返工改派 carbon（implement）**。合入门禁复审始终 carbon-high 不变。
- 首例执行：#349 r2（二次返工）由氢派单被撤销、codex 接管（现场：中断 worker 已产出未推送草稿 460f7b88，codex 指令含"不信任草稿逐条核实"）。
- 配套事实（碳审 r2 揭露）：普通 PR 自动门禁只跑 models 快速档，**不执行 C++ ctest**——新增/改动原生测试的分支矩阵（如无硬件 GPU 回退）需本地注入（Mach-O interpose MTLCreateSystemDefaultDevice→nil）或手动 native/full 档闭环，名单绿≠执行绿。

### (49) 第 107/108 合入：#349 三轮链 + #351 卫生票；workflow-scope 合并经验

- **#349（第 107 个，merge 6c147f96）**：P3-60/C12 preview 曝光缓存 + P3-61/C13 HSL 小波缓存。三轮评审链（氢 r1 → codex r2 → 碳 r3 approve）：ci.yml $tests 名单、512 Bayer 合成夹具+入库 DJI、scale_denom≤2（EV |Δ|≤0.07 十二真片 max 0.034）、无硬件 GPU 注入必红修复（fallback 回填 Off+cpuExecuted）、Force 伪装缓存修复（Force probe 恒存 Off）、损坏 JPEG longjmp、LRU/负缓存。codex 二次返工首例全绿交付（interpose 红绿闭环+双变异）；碳 r3 独立注入复验+变异 A/B 击杀。ctest 185/185。
- **#351（第 108 个，merge 83d54f81）**：host-jni-hygiene（bitmap.h 常量对齐真 NDK -3/-1/-2、recipe_probe_stages 子结构 memcmp+stub ABI、jni_session_lock TSan 干净、双脚本接 Android 强制档）。碳审 3 变异全死。
- **GitHub workflow-scope 实操规则**：dancancer OAuth token 无 `workflow` scope——**API 建的分支提交**（update-branch）与部分 `mergePullRequest` 会被 `refusing to allow an OAuth App to create or update workflow` 拒绝；**git push 不受限**。处置：分支本地 rebase 到最新 development + force push（新 head 自动门禁重跑）→ `gh pr merge` 立即成功（#349/#351 双实证）。若再遇拒：先 rebase 重试，最后才网页合并或让用户给 token 加 scope。
- 碳审非阻塞移交：#351 ①jni_session_lock Test2 补锁内 notify_all（省 CI 固定 1.5s 空等）②recipe_probe_stages_test 单数 stub 清理+sizeof==2248 static_assert；#349 ③processing-concurrency.md sony2fuji_session 行号差 1。

### (50) 用户反馈第 3 击：#352 跨版本孤儿删除风险 → re-adopt 分级恢复（合入前拦截）

- **用户主张（成立）**：#352（未合并）`recover()` 无条件删除未索引 `originals/<uuid>/`，与旧版 #339 整批写窗口（前序照片 UI 已"已保存"但清单 0 写）叠加成**跨版本升级**场景：升级首启即物理删除该完整原件唯一副本；相机卡已清+无备份=可能永久丢片。
- **碳独立核实（review-mwha7fq2，不信任任何人）**：`development`(#339 bin) 与 `23ce7659`(#352 bin) 双二进制临时目录实跑证实删除路径——旧版 `savedCount=1 manifestWrites=0` 硬杀 → 升级 `originalsDirs=[] storedBytes=0`；半片只存在于 `partial/`，磁盘原件是 APFS 原子 rename 的完整文件；无 history/统计/prune 任何兜底（均只读 manifest 快照）。正式版 `v0.10.0` 不含相机模块=真实暴露度 0；`development`/TestFlight 含 #339 构建的合入门禁 High（违背 Q6）。
- **碳揪出 2 个实现坑（我原派单未点透）**：① `pruneExportedOriginals` 有 `state.jobs` 空/prunable 空两处早退 + 只清 `prunedSourceIDs`，无 Job 引用的已导出 re-adopt 件**永远删不掉**（"可 prune"落空）；② re-adopt 准入必须过 `init()` 全量不变量（小写 UUID 目录名兼容大小写敏感 APFS、`validName&&photoName`、0<size≤1GiB、4 字节魔数、digest 合法），异常非空目录单条目 catch 跳过（不 throw 炸 `init`、不盲删未知文件）。附 8 条红线（含翻转 3 处旧"删空"断言、Step1→2→3 顺序锁死、幂等 0 写、迁移/幂等/prune 回归用例）。
- **lead 处置获碳认可**：分离"逐张持久化"（保留）与"孤儿无条件删除"（改分级 re-adopt：完整件入索引 UI 恢复可见、垃圾件删、软链/非 UUID 保留），否决 quarantine（重+割裂）与纯回退删除（#339 孤儿仍拿不到）。
- **crew 返工（mwha76tu 同线程，首次返工=Hydrogen Xhigh）**：新 head `ddc1cafa`（rebase 后仅 5 iOS 文件），8 红线全落；变异（re-adopt→无条件删）camera-originals EXIT=133 + skip-limit L1750/L2084 红；四脚本+apple-models ios 24 套件绿。碳复审 r2 `review-mwhaw0xw` 在跑（approve=第 109；打回=二次返工改派 codex）。
- **教训（入规）**：**批式/延迟持久化改动必须审"跨版本升级首启"这一独立窗口**——旧版崩溃遗留的磁盘态由新代码首次 `recover()` 处置，删除类清扫在升级语境下默认危险（未索引≠垃圾）；对"唯一副本"存储的自动删除需与 UI"已保存"承诺 + 导出账本联合判定，缺任一即 re-adopt/保留而非删。

### (51) 派发强度调整（用户指令）

- 后续 Hydrogen 执行票直接按 **medium 强度**派发（原默认 Xhigh 停发；复杂任务仍直接 codex，二次返工 codex、三次返工 carbon 阶梯不变，碳审 high 门禁不变）。

### (52) #353 合入（109th）；#352 二次返工（codex）交付待 r3

- **#353 合入**（merge `c3029f5c`，第 109 个）：#351 碳审观察×2（jni_session_lock_test Test2 锁内 notify_all 消 1.5s 空等；recipe_probe_stages_test 死 stub+`static_assert(2248)`）+ k159 文档尾（processing-concurrency.md 阶段 3 检查点表）。碳审 0 阻塞，独立变异实证修复有效（无 notify 回退 1511-1543ms vs 修复 15ms，TSan 5 连 0 race）。碳新增 2 条 P3 转 k159：阶段 3 行旧标签归类失准 + `parallelPixelRanges` 取消步长现值 4096（16384 仅任务切分粒度）——全文行号/口径统一对齐并入 k159 收尾，勿单改一行自相矛盾。
- **#352 二次返工**（阶梯规则首次实战：1st=Hydrogen、2nd=codex）：codex 收口碳 r2 的 F1-F5（三态清扫/单目录 do/catch/小写 UUID 守卫+去重/排序含 name/合规 .ARW 负向夹具），M1（prune 早退还原）与 M2（validateHeader 强真）均 exit 133 按预期死；新 head `0ccaa77d`。testIN6 首跑 L2227 超时（串行复跑过，flaky 定性待碳 r3）。碳 r3 `review-mwhbuii8` 在跑，approve=第 110 个。

### (53) #352 合入（110th）：跨版本 re-adopt 收口；教训入库

- **#352 合入**（merge `44b053f2`，第 110 个，head `0ccaa77d`）：P2-22 翻 ✅。碳 r3 门禁 APPROVE 0 阻塞：独立最小复现反证（r2 head 对 chmod 000/1GiB+1B/双文件=SIGTRAP 崩或盲删，r3 head 全部保留、权限恢复后次轮 1 写接管）；变异三枪 Mut1(preserve→盲删)/Mut2(去 validateHeader)/Mut3(去小写守卫) 均 133 死；r2 已认可件（逐张持久化/prune/Step 顺序/幂等）零回退；CI 全绿绑定 head；PR 正文升级语义表逐格真实。
- **testIN6 flaky 定性（碳 r3）**：既有紧时序——capture 后台刚性 1.535s 睡眠 + 3s nextCardCheck=4.535s 下界 vs 6s 窗口仅 <1.4s 余量，再叠 101 页全表 filter（1.01×10⁶ 闭包扫描）与并发编译负载；3 连跑绿。修复尾项（timeout 6→10 或 mobilePage 二分游标）转 **k163**。
- **升级阶梯首次完整实战**：#352 = Hydrogen 首轮（approve 后用户反馈触发返工）→ Hydrogen 1st rework（碳 r2 打回 5 缺陷）→ **codex 2nd rework（阶梯规则首次执行）**→ 碳 r3 approve。全过程碳三审+双二进制复现，用户跨版本反馈第 3 击避免了一次"合入后升级删片"生产事故。
- **遗留**：真机大小写敏感 APFS 实测→k173；PR body 基线 SHA 笔误（57213002 应为 4426fa41，纯描述）随归档不追改。

### (54) 卫生波四连合入（111–114th）+ medium 强度批次首航

- **#354 合入**（111th `ee346058`，P3/#345①）：raw_active_area_tests 严格 argv（argc>2/-h→usage exit 2），碳新旧二进制对拍 6 组 exit 全中。
- **#355 合入**（112th `76ee4947`，P3-66/C19）：libjpeg-turbo 全平台 `WITH_SIMD=ON`（REQUIRE_SIMD 保持 OFF：无 NASM 平滑回退 scalar）；encode 2.36x/decode 2.10x、JDCT_ISLOW 下 SIMD/scalar 字节逐位一致（碳上游 MD5 向量+独立探针双重实证）。**碳纠偏**：worktree ctest 157+28 vs 主基线 158+27 的真因=CMake 自动拾取 Homebrew py3.15 缺 `jsonschema` 吞掉 edit_recipe_schema 注册（夹具缺位是另一对 skip、本在基线内）——**今后 worktree 跑 ctest 一律显式 `-DPython3_EXECUTABLE=<含 jsonschema 的 pyenv python3.11>`**。
- **#356 合入**（113th `fc854a1d`，k163 testIN6 flaky）：FakeSonyCameraChannel.mobilePage 惰性有序校验+二分切片（O(log N)/页，didSet 失效+filter 兜底），timeout 6 未放宽；碳对拍夹具新旧逐页一致+off-by-one 变异 13 组红。
- **#357 合入**（114th `17e32f51`，纯文档免门禁）：processing-concurrency.md 全文 154 处 file:line 脚本化零漂移；阶段 3 标签归类别修正+cancelStep=4096 口径。
- **Hydrogen medium 首航**（用户新强度口径）：三票全部一次交付、碳审 0 发现，medium 足以胜任卫生/文档/工具类票；复杂票继续 codex。
- **在途**：#358（C23 死代码：只删 1 个真孤儿 stub、C23 点名五项全数 C ABI/测试豁免留证）碳审 mwhdjf84 在跑；碳清道夫 mwhdc9p0（worktree/分支/.cache/tmp/AGY 产物盘点）在跑。

### (55) #358 合入（115th）C23 收口 + 碳清道夫 + worktree 构建口径入规

- **#358 合入**（115th `34273a82`，P3-69/C23 ✅）：真孤儿仅 `hdr_image_stub.cpp`（17 行）；碳三重复核（全对象 nm 交叉/clang -Wunused 全 TU/构建脚本逐一）判 **lutools/src 内部死代码已清零**；主评审点名五项全数属 C ABI（其中四项锁在 `abi-layout-v1.json` 门禁夹具）或测试/XCFramework 导出引用，豁免成立。C23 就此关闭——"删除"的诚实答案是"几乎没有可删的"。
- **worktree 本地 ctest 口径入规（碳 #358 根因裁定）**：worktree 手跑 lutools 全量必须 ①`source RawLabMac/build-env.sh` + `-DSONY2FUJI_ENABLE_LENSFUN=ON -DSONY2FUJI_ENABLE_DNGSDK=ON`（否则 LensFun 静默 OFF 吞 #85/#140/#141/#170 注册）②显式 `-DPython3_EXECUTABLE=<pyenv 3.11 含 jsonschema>`（否则 Homebrew py3.15 把 #82 降级 skip）。181=154+27 假降由此而来，非回归。今后 crew 报 ctest 口径差先按这两查。
- **碳清道夫报告（用户指令）**：删已合并 worktree 15 个（12 个 ~/.codex 历史 feature worktree + decimal-vectors/read-development/wp-verify-windows）、已合并本地分支 fix/decimal-vectors、`.cache/tmp` 闭环目录 32 个（≈1.65 GB，含 rawlab-mobile-native 1.4 GB 临时 DerivedData）、AGY 终态作业文件 1486 个（64 MB，keep 25 dry-run 后 apply）；脏 worktree（release-0.9.0-gate 等 12 个含未提交改动）与 PR 正文引用的 .cache/tmp 产物全部保守保留。主仓 status 干净、HEAD=origin。
- **在途**：#359（client-tails：#347 @StateObject + #345② nearGray 假红）Hydrogen medium mwhdpb5y 在跑。

### (56) #359 合入（116th）；#360 碳审打回→Hydrogen 一轮返工；P3 双批在审

- **#359 合入**（116th `766ebcca`）：@State→@StateObject（碳实证 CI 不编译该文件后本机全量 build.sh exit 0 补编译盲区；泄漏前提未被实测复现、PR 如实表述）+nearGray 放宽（color-contract §"Spread<1/255"契约一致，三夹具模拟器复现灰 DNG 红→绿）。#347 移交与 #345② 两票销。
- **#360 碳审 request changes**（1 P0+3 P1+1 P2，全有注入实证）：P0=契约红（d3d11_shader_cache 进 ci.yml Windows 名单、gpu_gles_renderer_retry 应进 test_windows_inventory KNOWN_INAPPLICABLE 而非 $tests——glslang 块内 Windows 无 glslangValidator；C# 缺 PASS 横幅）；P1a=GLES 保留上下文后 capacities/cachedLut 失步（glBufferData OOM 先毁旧数据，ES3.1 §6.2）+map/unmap 抛错不排空 glGetError（CONTEXT_LOST 漏判+粘滞污染下帧）；P1b=磁盘缓存 tmp 名拼 this 指针单例同址并发破原子（20/80 破损实测）；P1c=LRU 测试第 4 步淘汰 0 次假覆盖。Hydrogen 一轮返工 mwhfzdz3 同线程在跑。
- **P3 双批交付待审**：#361（Android：A-N4 preparing finally 复位/A-N5 assets @Volatile+快照前置/A-N6 启动清理后台化+protect 竞态/A-N7 BatchExport 下 IO；JVM 740 全绿，基线 SonyLegacyImportSessionTest 5 失败为 k171 已知 flaky）；#362（Mac：M-N3 isRasterInput 单一事实源/M-N7 版本键 CaseIterable fail-closed 穷举/M-N9 代际过期丢弃含 inFlight waiters；4 脚本 exit 0）。碳包 mw 在跑。
- **口径确认**：`gpu_gles_renderer_retry` 类 glslang 门控测试的正解=KNOWN_INAPPLICABLE_WINDOWS_CTESTS 登记（mac native 实执行），与 lesson 46 的 $tests 名单法互补——**$tests 只收"Windows 可构建"的 portable 测试**。

### (57) P3 双批碳审均 request changes（阻断全实锤）；#360 r1 已交

- **#361 打回 4 阻断**（碳有复现程序）：A1 冷启动 `SystemPhotoStore.cleanupTemporary` 在后台线程无条件删在途 `raw-*.input`/`.*.part`，与 `restoreSystemPhotos`/`receivePhotoIntent` 的 retain 并发（128KiB JPEG 并发复现 FileNotFoundException）——启动清理后台化的前提是清理目标不能被"新会话正在写"的东西命中，protect() 只护了 WorkingCopy.directory，没护 system-photo-imports 与 BatchJobs 渲染产物；A2 `reclaimBatchArtifacts`×`refreshPending`、`atProcessStart`×新批处理草稿同类；A3 `discardDraftOrCompleted` 把空操作 completion 缓存进 `discardCompletion` → 同实例后续 `discard()` 永久空转（L402/L411/L417/L422 链），且 `BatchPreviewLifetimeTest` 的 Deferred 没 await；A4 `confirmOutput` 跑在可取消 scope + `startInternal/continueUnfinished` 不持 confirmLock → 确认后立即关面板＝确认丢失或全 SUCCESS 孤儿任务。
- **#362 打回 2 阻断**：B1 `invalidateStaleEntries` 未像 `invalidateDirectory` 那样把 `inFlight` 路径纳入 stale 判定 → 首次解码中文件被原子替换时 `fileGenerations` 不推进，过期 idA 图像既入缓存又非 nil 交付（碳复现 `invalidated=false deliveredNonNil=true cachedStaleIdA=true`）；B2 并发测试 `DecodeGate` 在 `NSImage(contentsOf:)` **之前**阻塞（旧字节根本没读），`freshResult` 也只判非空 → 测试假覆盖。
- **共同教训**：P3 轻票≠低风险——"后台化/异步化"类改动必须连带审"谁可能正在写被清理/被淘汰的对象"，审查口径=**保护集必须覆盖所有并发写方，而不是只覆盖重构时顺手想到的那一个**。
- **#360 r1 交付**（44b5692f/47286390/14997f12）：P0 契约三处修复（d3d11_shader_cache→ci.yml $tests；gpu_gles_renderer_retry→KNOWN_INAPPLICABLE；C# PASS 横幅）；GLES 三注入场景红→绿+两新用例；磁盘缓存 pid+atomic 临时名（80 轮 0 破损）；LRU 第 5 条真淘汰。scripts/ci 231 绿、ctest 187 绿、Contracts 绿；碳 r2 复审 mwhipbyn 在跑。

### (58) 用户第三轮复核受理+核验；六路并行开工；#361/#362 r1 待复审

- **第三轮人工复核（#310–#359 全 48 PR）受理**：103 通过/9 部分成立/1 未通过（完成-01）/4 待验证；新发现派单前 lead 逐条实核（行号命中、grep 0 调用方、本机 launchctl/pgrep 佐证），并把核验交给碳脑（agy-brain carbon-high staffer-mwhj5e7o）独立复核防自证。
- **#360 r2 打回受理**（碳 r2：1 P1 恒真并发测试+2 处 P2 假绿子断言+Windows _WIN32 零 MSVC 编译）：梯子第二轮=codex，gpu-r2 在跑（碳处方照抄：热键预热+diskHits==1 断言、lutA 序列夹具、workflow_dispatch windows native 手动门）。
- **新票四张全部并行派出**：①win-ub-hygiene（Hydrogen：P3-60 尾 Windows file_clock ns 溢出 UB 按 lens_correction static_assert 模式修+shader_vm SKIP 77 C22+5 支 Apple 脚本进 apple-models 门禁+gles_denoise dtor 守卫）；②ios-draft-close（Hydrogen：P2-26 三处草稿收口）；③looks-ui（codex：P2-16 三端外观库坏条目 UI）；④win-force-gpu（Hydrogen：P2-09 尾 Windows「强制 GPU 不可用」文案区分）+⑤jit-hardening（Hydrogen：完成-01 工程半边——token 出 plist 明文/launch_runner 剥 GH_TOKEN/allowlist 锁 head_sha/FIFO 抢占）。生产 JIT 切换本身仍归用户侧 k179。
- **#361 r1（33cb399c，A1 @Synchronized/A2 rootLock+protect 覆盖面/A3 空操作不毒化/A4 NonCancellable 原子段，JVM 744 全绿）与 #362 r1（0be72764，B1 inFlight 代际+B2 读旧图后 gate，双变异真红+build.sh 绿）** 交碳包 review-mwhjhth4 复审（含 #360 r2 联审）。
- D-02（降噪键跨端分叉）排队为下一张 codex；P2-26 实证若发现路径已兜住则按碳脑裁定缩范围。

### (59) #364 合入（117th）；碳脑核验落地；#367/#368 一轮返工在跑

- **#364 合入**（117th `8a1ee180`）：P3-60 尾 Windows `file_clock` ns 溢出 UB 按 raw-ticks 修（逐位十进制格式化不执行 negation，`INT64_MIN` 也安全；mac 侧 `__int128` 纳秒输出逐字符不变）+ C22 `SKIP 77`（4 项 glslang 系测试原名恒注册）+ thumbnail-cache.sh 入 apple-models + gles_denoise dtor 守卫。碳实证 185 全绿口径（168 假降=主仓旧 CTestTestfile 时间戳）。碳脑建议 sony2fuji_c.cpp:3484 microseconds 转换无乘法路径**不改**（第一性原理不捆绑）。
- **碳脑（agy-brain 首用）核验裁定**：P3-60 成立（量级勘误 1.34e19 非 e21）；5 支 Apple 脚本"直塞 apple-models 会炸普通 PR"仅 1 支可入（crew 已按此做，碳裁定文档化=闭环附 1 行措辞修正）；shader_vm 目标名实为 gles_shader 等 4 项+异名即炸对账（已避）；**#367 数据层根因**（LookLibrary.swift:277 `file_name` 键 vs 真实 camelCase `fileName` → 真实坏条目 fileName=nil 删不掉实体文件，模拟器 camelCase 实证 RED）；**#368 残留**（requestCollectionNavigation/openBatchSelection 未收口，探针 RED）；完成-01 本机无 plist（仓模板 scripts/ci/launchd/），GH_TOKEN 剥离与 allowlist head_sha 落点 jit_dispatch.py。
- **#365（jit-hardening）交付待审**：token 出 plist 明文→jit.env 0600+`--env-file`、launch_runner 剥 GH_TOKEN、allowlist 强制 `@<head_sha>`（对照 GitHub run 元数据，crew 纠正了"本地 rev-parse"的票面假设）、FIFO 无抢占窗口注释；scripts/ci 238（+7）全绿+红锚。
- **#367/#368 一轮返工**（梯子第一轮=Hydrogen，双并行在跑）：#367 修 L277 键匹配+删除残留实体文件测试；#368 集合导航两入口收口。
- **D-02**（降噪键跨端分叉）codex 已并行开工（现状矩阵先行，若已被 #321/#346 实际收敛则轻量交付）。
- **用户侧**：自合 #363（update-roadmap）与 AGENTS.md 全局原则条目（第一性原理/主轴把关/诚实声明红线——与本链工作方式一致，已纳入派单口径）。

### (60) #368（118th）/#369（119th）合入；D-02/P2-26 台账闭环；#367 r2 与三张返工在跑

- **#368 合入**（`d7390743`）：iOS 草稿收口全链（resolveCollectionDraft/quickPresets/导出/openBatchSelection/requestCollectionNavigation），模拟器 123 项 RED→GREEN，碳 approve 附 2 条非阻断 UX 简注（批量入口 disabled 未含 previewRendering 极短窗口点击静默——已登记简注）。
- **#369 合入**（`c0f2231e`）：D-02 收口（碳首审 approve：四端矩阵逐格源码核对+Mac/iOS/Windows/Shared 本机实跑+变异实测）。**台账已更新**：D-02→✅（b-task-table/c-four-end/f-overall/g-product-decisions 四处），P2-26→✅（#368 闭环）。codex 交付仅用 ~20 分钟（票内含现状矩阵自查），再次验证"复杂票直接 codex+先证实现状"的高效路径。
- **#367 r2**（codex 在跑）：碳二轮发现 Android 宿主接线死锁（面板打开即 draft=LOOK 而删除按钮 enabled 写死 draft==null → 恒灰；单挂测试假绿）——放行 draft.group==LOOK+穿 EditorViewModel 宿主回归+recipe-lut 保留对齐；r2 需 rebase 含 #369 的 development 并重生成字符串。
- **三张 codex 返工在跑**：#361 r2（A4 死锁/过期快照/单槽 lastConfirm/r1_a4 恒真，碳处方）、#362 r2（M-N9 image(for:) 身份精确判定 2 行+CASE_E_MN9 常驻）、win-native-baseline（Windows native 门基线 2 红：preview_exposure_cache 合成 DNG 覆写+wavelet_noise_model 跨标准库分布断言——#360 放行前置）。
- **#365/#366 碳包在跑**（jit token/head_sha 闭环性+TOCTOU 裁定；#366 ABI 增量+reason 清零时序）。
- **合入计数**：119（#368=d7390743、#369=c0f2231e）。

### (61) 返工波：#361r2/#362r2/#367r2/#371 交付待复审；#365/#366 一轮返工在跑

- **wnb 票→#371**（codex 65 分钟）：Windows native 门两条基线红修复（preview_exposure_cache 合成 DNG Windows 覆写+wavelet_noise_model 跨标准库分布去耦合，JUnit 138 名前后一致不删项），**Windows native 整门首次 100% 绿**（run 43699429908）。合入后 #360 rebase+重跑 native 门即达放行标准。
- **#361 r2**（codex）：A4 死锁/过期快照/单槽覆盖/恒真测试四项重写，749 测全绿+6 变异全红+CI 绿，碳复审在跑。
- **#362 r2**（codex）：M-N9 身份精确判定 2 行+CASE_E_MN9 双入口常驻（旧代码红、Case E 并发绿），四脚本+build.sh+CI 绿，碳复审在跑。
- **#367 r2**（codex）：Android 宿主接线放行 draft.group==LOOK+recipe-lut 保留+穿宿主仪器测试 4/4 真跑（真实宿主/ViewModel/队列/持久化）；并实证纠正 JVM 基线口径（looks-ui 分支=737 非 744）；rebase 含 #369+字符串并集重生成。碳复审在跑。
- **#365/#366 一轮返工**（Hydrogen）：#365 两项（fork PR pull_requests=[] 恒不命中+stub 假绿；同仓 push 信任判定须前置防队列锁死）；#366 一项（RenderHDRAsSDR Native.Check 漏传 session→HDR 容器+强制 GPU 仍弹误导文案）。
- **codex 吞吐观察**：本轮 5 张 codex 票全部 20–65 分钟交付且红绿证据齐全，"碳处方照抄+先证实现状"票面对 codex 高效；碳审仍是唯一放行闸。

### (62) 宿主重启事故恢复零损失；#365 合入（120th）；真机门禁首跑抓到 Android 构建期红

- **事故**：19:01–19:08 宿主 harness 重启，6 个在途任务（4 碳审+1 返工+1 真机门禁）中断，轮询器全灭。**远端零损失**（各分支 r1/r2 head 均已 push 存留：#365=c1877834、#367=f7f677ba 等），仅评审过程重跑（碳包A #361r2/#362r2/#371、碳包B #366r1/#367r2、碳审 #365r1 重新派发）。
- **#365 合入（120th，`59b0de8e`）**：完成-01 工程半边收口（jit.env 0600、GH_TOKEN 剥离、pr#n@sha 同仓限定+外部 fork 指路 run_id@sha、push 信任前置防队列锁死；scripts/ci 240）。iOS models 首跑红=自托管 runner 失联（重启窗口），`gh run rerun --failed` 转绿后合入。k179 剩用户侧生产切换演练。
- **真机首轮（Pixel XL marlin，API 29/Adreno 530）**：`:app:buildCMakeDebug[arm64]` 自 **700eeb408（#334）** 起编译失败——`driver()` 仅在 `#ifdef SONY2FUJI_FAKE_EGL_GLES` 内定义，NDK 真机构建 11 处 undeclared identifier。**Android APK 仪器测试链在真机侧从未跑通**（hosted CI Android models 不构建该 cmake 测试目标=门禁盲区，k163 候选补录）。解锁票 fix/android-device-gate 在跑（1b 段出宏+真机全套 connectedDebugAndroidTest+k173 签收表随 PR）。
- **iOS 模拟器高占用答疑**：为自动化任务临时模拟器的正常负载（碳审/测试起停），harness 重启后 booted 清空、CPU 回落，无孤儿残留。

### (63) 连合五单（121–124）：#367/#371/#361/#362 全 APPROVE；#366 r2 与 #360 rebase 接力

- **#367 合入（121th `dd944aff`）**：碳三枪独立变异（UI 门禁/ViewModel 门禁/recipe-lut 恢复各必红）+737 口径纠偏（dev=736+1 新增）+字符串并集 --check 全绿。
- **#371 合入（122th `8f89f40d`）**：Windows native 整门 138 项保序 1:1 对账（2 红→0 红零删项）；preview_exposure_cache 修法核到 LibRaw `_wfopen` 共享模式根因（优于跳过：切照片释放句柄+负缓存跨照片断言）；wavelet 换 SplitMix64+Box-Muller 阈值一字未松+`/UNDEBUG` 防断言被 Release 吞。**native 门基线自此全绿**。
- **#361 合入（123th `cefbc514`）**：A4 四阻断全闭（锁外 awaitPending/无过期快照/集合化 pending/4 线程夹具）；碳 4 枪运行时变异全红（含锁内 join 死锁还原=超时红）。
- **#362 合入（124th `3bdacd59`）**：M-N9 持锁身份判定+CASE_E_MN9 双路由常驻；碳变异（去 identityMatches）双路由必红；跨 47 夹具联调+隔离 build.sh 绿。
- **#366 r2（codex 在跑）**：碳拦下 RenderedDngChecks 间接取串过滤（原生门 --rendered-dng 必崩，hosted 不跑原生套件故 CI 全绿掩盖）；一行对齐 FormatErrorMessage(2,null,ForceGpu)+对账扩展；native 实跑并入 #360 复跑窗口。
- **#360 rebase+native 复跑票（在跑）**：让位 #364 清单机制保原注册名；预期 139 项（138+新 d3d11_shader_cache）全绿后即 r3 碳终审。
- **节奏已按用户指令调整**：并行 9 路；全量测试收缩到关键节点（碳包实跑+合入波前），小票只跑针对性脚本+hosted CI。k161 移交项拆 3 张小票并行中（滑杆容差/preflight 生命周期/中性灰假红）。

### (64) 真机解锁与三分类清障（125–127）：#374/#366/#372 合入；#360 根因翻案=LUT 缓存缺内容哈希

- **#374 合入（125th `8d01b2ef`）**：`gles_lut_binding_tests.cpp` 1b 故障注入段包 `#ifdef SONY2FUJI_FAKE_EGL_GLES`，Android NDK 真机构建自 700eeb408 起首次编译通过。碳审拦下**签收口径失真**（非代码）：assumeTrue 静默跳过被计入 PASS、#343 真机 GLES 实为 0 触达（跑通项均 CPU 路径）——按处方修正 PR/k173 后放行。教训入派单口径：仪器 PASS 必须与 `-r` 模式 skipped 对账。
- **#366 合入（126th `456be34b`）**：Force-GPU 文案对齐 r2（native `--rendered-dng` 证据并入 #360 native 窗口）。
- **#372 合入（127th `97f66433`）**：hosted「Android models」新增 ndk-compile.sh 轻量 CMake 门禁（~12s），活红锚实证（未修必红 run 43710892455）——Android 测试源 NDK 编译盲区永久关闭。
- **#360 根因翻案（codex）**：Windows native `lut_contract_render` 12 连红非 d3d11 缓存键，而是 **LUT 文件缓存只比路径/大小/mtime**——测试同尺寸同时间戳覆写同路径时 V-Log 错误复用线性 LUT，本机确定性复现同款 12 红；系 development 既有缺陷（非 #360 引入）。修复=lut_parser 按内容 SHA-256 判缓存+同尺寸同 mtime 覆写回归（红锚成立）+两个 `#define` 变体缓存测试。native 前二跑败于 Adobe 下载网络断（码 56/18，未及测试），第三跑 `43716383315` 在途。遗留：LUT 加载新增全文件哈希的性能基准待补（非阻断）。
- **真机三分类（research，双环境对照+素材入 APK）**：12 嫌疑类**全部 A 类真实缺陷**（API29+API35 同红，素材无关）；素材类（RasterFixture/NativeMemory/HDRBatchCancel 等）装样片即转绿=C 类。拆 4 票：**k531** P0 batch cancel 门序崩溃（latch 30s 主线程 AssertionError 崩仪器进程，连带同类 3 法没跑）；**k533** P0 小图 master recipe 预览上变换 19→1600（viewportPreview 绕过原生钳制，C++ 侧）；**k535** P1 Editor v0.8 toolOpen 契约错位（6 UI 套件共因：EditorWorkspaceGroups 15/18、UsageFilm、LookLibrary、AdjustmentPresetUI、CameraMediaUi、X3fEditor）；**k537** P1/P2 尾批（colorState 枚举 5vs6、批量选择读盘竞态、相机续传句柄契约、API29 Compose no-paragraph 崩溃+411dp 裁切）。k531/k533 Hydrogen、k535 codex 并行在跑。
- **滑杆票 #373**：双击容差子类+惯性合并交付（红锚/13+29 全绿/CI 7/7），碳实跑仍拦两阻断（第 2 触快滑零写回假绿、touchesBegan 抹惯性窗致既有回归分裂 4 对编辑态）→ Hydrogen 一轮返工在跑。另两张 k161 小票经 git 证据确认**已随 #359 顺路修复**（b9f00f1f：preflight @StateObject+nearGray 断言），零改动关票。

### (65) 大波合入（128–141）：#373–#386 十四单；#360 收官；真机红尾批 k531–k537 全清

- **#373 合入（128th `5711a6f8`）**：iOS HDR 滑杆 r2（delegate 判定+位移回退，碳两轮后 APPROVE 0 阻断）。**#375（129th `d23475d4`）**：批量状态门序测试搬迁（PROCESSING→PUBLISHING/FAILED），零产品改动；碳用两个独立反证锁定"测试有罪"。**#376（130th `26193be8`）**：PREVIEW+邻域/几何统一 `preview_long_edge=min(pl,native)` 封顶（#533 主修）。
- **CI 三连（131–133）**：#377 ndk-compile 工具链过滤+Python 契约测试入 CI；#378 `raw_active_area` CLI 消费矩阵；#380 `inspect_lut_color` 状态语义（rlook→LEGACY(5)/畸形→UNREADABLE(6)），碳实跑核 strength=2f 不钳 1.0。
- **#381 合入（134th `863f4028`）**：Editor v0.8 toolOpen 契约错位主修（codex，6 UI 套件共因）；契约裁定=桌面分组工具网格、选中工具才开草稿（与 mobile-r2 分组语义对齐，Mac 桌面=不同契约）。6 套件 API35 全绿+碳加跑 Pixel XL API29 抽验绿。
- **#360 合入（135th `9e94034f`）**：GPU 跟随大票（LUT SHA-256 缓存内容失效+d3d11 双 define+`--rendered-dng` 组合），native 手动门禁 139/139 绿。碳 r3 简注：64³/65³ `.cube` 热哈希 +29–31ms/帧 → 派生 perf 票 #387。
- **真机红尾批 k537 四单全清（136–141）**：#382 API29 簇（compose-bom 2025.06 修 `GraphicsLayerV29` no-paragraph 崩溃+AboutDialog 411dp，Pixel 16/16）136th；#383 GLES 设备 EGL 平台分支（**#343 真机触达 0→31 PASS**，AVD+Pixel）137th；#384 小图纯几何封顶 138th；#385 SDR 批量取消代际透传锁 139th；#386 相机续传契约断言对齐 #340（又是测试随实现漂移；双设备 6/6）140th；#379 批量选择读盘竞态——碳包 D 打回**测试注入时序**真根因（controlsEnabled 守卫静默丢 edit），处方 r2 后碳独立 6/6 亲验 141th。
- **Windows native 下载 flake 治理**：DNG SDK/rustup 下载连挂 4 次（schannel/GOAWAY/tls eof，run 43726623136 三连败）；#388 换仓内 `rawlab_download_archive` 3 重试+SHA256 校验（氢实测 `DOWNLOAD_RETRIES` 非 FetchContent 合法关键字）碳 APPROVE，分支 native 端到端实测在跑。**教训**：连挂≥2 次即升碳/codex 接手，氢不再盲重试。
- **在途**：#387 LUT 哈希平台加速（CC_SHA256/CNG；64³ SHA 28.2→2.6ms 达标；碳 r1 拦 Windows `RGB` 宏击穿/provider 析构序/MinGW 链接三阻断，codex r2 已修，碳 r3+Windows native 门禁收口）。
- **登记**：k159 双简注（viewport_preview==0+邻域微差异、geom 封顶已随 #384 落）；k163（DNG 重试已票面化 #388）；k161（commitAdjustments 解锁序/revision 快照下沉；controlsEnabled 静默丢编辑的普通用户路径确认票）；AVD-B（rawlab-api35-b）本轮新增为并行设备泳道，波尾拆除。

---

### (66) 过度防御大扫除波（142–158）：十七单；SHA-256 全仓审计 41 点 + 非哈希重处理 15 组；对抗式评审成为默认

- **起点=两次全仓审计（carbon-high）**：①**SHA-256 审计 41 个运行时调用点**（17 必要-保留 / 19 必要-可降载 / 5 过度防御-可去），最重为"同一张 25–75MB ProRAW 流式导出被全量哈希 7 次""Android 批量单张 RAW 10 次""HDR 滑杆每帧扫整张 20–80MB RAW 但摘要无人消费""AI 降噪 96–720MB 浮点张量背靠背双算"；②**非哈希过度防御 15 组**，最重为批量账本 `O(N²)` 写放大（每张 3–4 次写、每次写前整读回+解码+全量校验，500 张≈3–6GB JSON 吞吐）、HDR 滑杆 4 层逐像素 `isfinite` 扫描栈、主线程同步清扫/冻结、16-bit PNG 为 2KB EXIF 重解码重压缩、可再生缩略图缓存用 `WriteThrough+fsync` 且每写全目录 stat（≈3.3 万次）。
- **合入清单（142–158）**：
  - **#388（142nd）** DNG SDK/rustup 下载改走 `rawlab_download_archive`（3 重试+SHA256）；**#404（158th）** 同法收编 opencv/opencv_contrib（pin 实算），Windows native 的 schannel 抖动不再卡门禁。
  - **#390（143rd）** k161 `controlsEnabled` 静默丢弃七入口结构化日志（零行为变更，观察真实命中率再决定是否上单槽合并队列）；**#392（145th）** k161 `commitAdjustments` 单槽契约注释（碳定性=顺序自洽非竞态）。
  - **#387（144th）** LUT 哈希平台加速（CC_SHA256/CNG，64³ 28.2→2.6ms，三平台字节一致；codex r2 修 Windows 宏击穿/BCrypt 析构序/MinGW 链接）。
  - **#389（146th）** k163 批 B：CMake 优先 `Python3_EXECUTABLE`、Mac 死代码清理、`batch-cancellation.sh` 接入 CI `in_suite model` 分片；**#395（147th）** k163 iOS 三脚本分类（`ios-photo-previews.sh` 20.8s、`raw-unpack-export.sh` 26 checks、`subtool-menu-draft.sh` 123 checks 均实跑，落 native-gate 模拟器路线/手动门）。
  - **#391（148th）** Mac UI harness 隔离（三 harness 注入目录）——碳 r1 打回 B1：`seeded` 哨兵留在持久夹具而 `editDirectory` 改随机临时目录→同 root 二次启动丢编辑仍跳过播种；返工改 `root/rawlab-iso-state` 确定性路径并去掉退出自删，增量复位 APPROVE。
  - **#399（149th）** 安卓批量日志：长连接流 + `recordRow(sync:)` 只在 URI 登记后与终态 fsync（每张 ≤2 次），codex 独立审确认撕裂尾行 replay 容错真实存在、URI checkpoint 不会恢复成假成功项。
  - **#398（150th）** 编辑账本写后原地更新缓存（iOS）+ Android `(lastModified,length)` 短路；Android 因 java.io 面只有两维、`fileKey` 规范允许 null 而修订既有契约用例——原生独立审**裁决修订成立**（`Os.stat` 的 st_ino/st_ctim 可零窗口但代价=秒粒度合成+host JVM 不可用），并登记"同毫秒跨进程 lost-update 窗口"。
  - **#397（151st）** 缩略图缓存去 fsync/WriteThrough + **进程内共享实例**（修 AlbumScreen/EditorViewModel 双实例索引失步）+ **JPEG SOI/EOI 校验**（AOSP `BitmapFactory` 把 `kIncompleteInput` 当成功）；碳两阻断，返工后独立复审确认真闭环（含 130-filler 逐出脑洞的边界核）。
  - **#394（152nd）** 三端批量检查/回退接既有 stat 校验缓存；codex 审出 **Windows P1**：`WindowsFileIdentity` 在 FAT/exFAT 无故 ChangeTime/USN 时仍报 `StatReliable=true` → 脏摘要复用致冻结反复失败；修复=两标记都不可用即走全量哈希（回归含"大文件+标记不可用+同尺寸同 mtime 覆写"，旧判定实跑红）。
  - **#396（153rd）** 启动清扫离首屏——**三轮**：codex 实跑复现 P1（Q6 reclaim 与同 ID 任务恢复的旧快照删除）→ 修复又引入反向 P1（`modificationDate` 比 `creationDate` 使非空导出目录**永不回收**）→ 终版=每 part 记自身快照 mtime 比较、夹具改"建目录后写子文件"真实形态。
  - **#401（154th）** LUT 兼容性向导四端免整片拷贝（引用原路径，content:// 流与安全作用域仍落盘）；碳阻断=androidTest 仍断言旧拷贝契约，返工后仪器化 3/3 实跑绿 + 增量审确认只多 1 行只读 getter。
  - **#400（155th）** Windows 导出尾趟：ExifTool `-stay_open` 常驻管道（整批省 N−1 次 Perl 冷启动）+ `CopySDROnly`（6 处 SDR-only 省整幅 HDR float LOH 克隆，42MP 成片峰值额外分配 ~1.0GB→~0.5GB）。
  - **#402（156th）** AI 摘要簇：T1 cache.load/store 透传张量摘要（96–240MB 不再背靠背双算）+ T4 非 USN 卷退路按 stat 身份复用（有界 LRU 128、canonicalPath、before/after 双读复验）——碳拦并发 TOCTOU 污染与测试假绿（注入点在 `sourceMetadata` 之后测不到 `sequence==null`），返工 + 测试自比假绿再修（filler 逐出制造真实污染窗口）。
  - **#403（157th）** 相机 iOS 落盘去重（`complete()` 零重算/采样复用/`verifiedURL` 接缓存；顺带把 `FileDigestCache` 拆独立编译单元让相机 harness 免拖编辑持久化依赖，pbxproj+16 脚本同步）；codex 判 a/b 红锚**假绿**（钩子只覆盖新包装）→ 计数下沉到真实 `hash()` 入口并撤除 seam，codex 亲自变异 `mutation_exit=133` 实证。
- **方法论沉淀**：
  - **对抗式评审成默认**：`异步化/顺序放宽`类改动单审会漏并发窗口（#396 的 Q6 竞态、#394 的 Windows 脏摘要都是二审才抓到），此类票一律叠二审（carbon 或 codex），并优先用"实跑变异"而非推演。
  - **假绿三形态**：断言未覆盖真实入口（#403）、受污染值自比（#402）、夹具形态失真（#396 空目录 ctime==mtime）——交付必须"撤修复实跑变红"。
  - **返工的反向 bug**：为堵竞态加的"过保守"判据同样致命（#396 回收 100% 失效），修复后要验证"该删的还能删"。
  - **执行方分配纪律**：过度防御/降载类减法票**不派 codex**（风格偏加法）；凡派 codex 前置"最小充分改动+禁止净增防御层"纪律；agy 网关反复 `loadCodeAssist` EOF 时改派原生 subagent，agy 并发上限 **4**。
- **在途**：#405（Mac 缩略图缓存去 fsync+LRU 索引、Android statvfs 风暴）、#406（批量账本写放大 Mac/Win）、#407（相机 Android 半边）、#393 r3（stat 短路→内容寻址零 I/O+摘要键 parse 缓存，等 Windows native 重跑）。

---

### (67) 过度防御大扫除波二（159–171）：审计清单全部落地；冲突规则与"假绿三形态"再次被实证

- **#393（159th `62e463d5`）SHA 降载票①（C++ 核心）**：T1 相机 RAW 解码末尾无人消费摘要（前后已有 `cameraRawStamp` 夹逼）→ 不读盘；T2 ProRAW develop/finish 双算→单算、openPROW 复用准入摘要；T3 portable HDR 边界双验→单验；**T4/T5 三轮返工**——先把 #360 的内容防线退回 stat 短路（碳审：NTFS 粗时钟重开原发故障 + `expectedHash` 失配卡死 + 假绿测试），终版=**内容寻址零 I/O**（`Looks/HDR/<sha256>.cube` 文件名即摘要，直接比名）+ 摘要键 parse 缓存 + 三套样板合一；Windows native 重跑绿（首跑败于 opencv 下载 flake）。
- **#404（158th）/#408（160th）** opencv/opencv_contrib 收编 `rawlab_download_archive`（重试+SHA256 pin，终结 schannel 抖动卡 native 门禁）；changelog (66) 入库。
- **#406（161st）+ #409（164th）批量账本写放大（Mac/Win/iOS）**：`save()` 改为"首写或磁盘指纹≠本进程上次写出"才整读回+校验；探针文件任务级化；**保留 publishing/checkpoint/succeeded 三崩溃锚**（评估后不合并，合并会弱化恢复语义）；IO 账：500 张整文件重读 1500+→1、探针 6000+→1500 stat。**Windows 指纹被碳审打回并 CI 实红**（`(Length,LastWriteTime)` 在 NTFS 15.6ms 粗时钟下等长覆写漏检 → 静默覆盖未来版本 job.json）→ 终版=USN>0 + 六字段全匹配才跳过，否则回退全读；iOS 用 APFS 全纳秒 stat（`dev+ino+size+mtime_ns+ctime_ns`，`.atomic` 换 inode 反而成为检出依据）。
- **#407（162nd）相机 Android 半边**：publish 采信流式摘要、pending 尺寸复核、采样 savedStat 快路径；**d1/d2 打开路径被碳审整段否决并撤回**（MediaStore `(SIZE,DATE_MODIFIED)` 整秒精度非 iOS 纳秒语义，同秒等长覆写会静默错图+编辑串图+账本不自愈），仅保留 a/b/c；仪器化 `CameraMediaLibraryTest` 6/6 实跑。
- **#405（163rd）缩略图缓存三端**：去 fsync/WriteThrough + 共享实例（修 Album/Editor 双实例索引失步）+ **容器完整性校验**（Android JPEG SOI/EOI；Mac/iOS PNG IEND、JPEG EOI——ImageIO 对截断图返回非空残图已被实测钉死），坏条目删除+剔索引自愈；Mac 删掉 `NSImage(data:)` 的 0×0 伪装成功兜底。
- **#411（165th）基线断裂修复**：`BatchPublicationTests` 的 `preview.cgImage`→`preview.image.cgImage`（生产从未有该访问器；回加才是为一条断言净增 API），并把 `hdr-batch.sh` 模拟器不适用登记入 ci.md。
- **#413（166th）Mac 16-bit PNG 导出尾趟**：为 2KB EXIF 整图重解码重压缩 → **`eXIf` chunk 流式注入 + IDAT 原样平移**；61MP 实测 preserve 尾趟 **8.92s→0.45s**、峰值 RSS **+910MB→+9MB**、像素解码/编码 **1+1→0+0**，成片像素 SHA256 与 EXIF 读回逐项一致。
- **#412（167th）HDR 滑杆扫描融合**：4 层整图扫描里可融合的两层并入 edit 写趟（**每帧整图扫描 7→4**），FFI/核心校验因错误契约不同不硬合；碳审 TSan 抓出并行归约对非原子 `fusedMax` 的无锁读（UB）→ 一行修（初值 `-inf`），TSan 前后对比 2 race→0。
- **#414（168th）Android 相机账本**：进程内增量账本 + 行级 WAL + 任务级快照替代每张全量重写（单张：全目录枚举 1→0、重写 2→0、fsync 4→2–3）；碳审两阻断=设备门禁测试直读 json `prepared` 必红（hosted CI 只编不跑=假绿）+ **WAL 缺单调序号**（`Files.move` 与 `wal.delete()` 间崩溃会把旧 WAL 重放到新快照上，复活被清零的 `savedStat` 绕过篡改自愈）→ 加 `seq` 判据与 `recoverJob` 清 `prepared`，仪器 6/6 真绿。
- **#410（169th）Freeze 离主线程（Mac/Win）**：双遍全集重验 + look 拷贝搬后台；碳审三阻断=后台读 WPF `GpuMode.SelectedIndex` **100% 崩**、`checking` 提前清导致**冻结期取消失效仍落盘**、Windows 红锚自写 `Task.Run` 绕过生产入口（且 PR 误称 WPF 已编译）→ 修后手动 Windows `build` 门禁真编 WPF，锚点③变异实证（撤修复两次独立 run 精准红、恢复 3 连绿 32 checks）。
- **#415（170th）Mac 编辑账本缓存**：写后重取指纹原地更新（写+读配对磁盘读 2N→N），补齐 H-03 的 Mac 半边。
- **#416（172nd `548ab84b`）LUT 副本内容寻址去重**：同一 look 在任务目录内 N 份 → 1 份（4 处 per-target 复制点；7.4MB/份）。碳审打回两点——**Mac 的 `BatchJournal.directory` 是跨任务平铺目录**（不像 iOS/Android 有 `<jobID>/`），副本平铺会被上一个任务的 `releaseResources` 误删（`missingLook`）→ 改为任务作用域前缀 `Batch/<jobID>-<sha>.<ext>` 且回收只看本任务前缀；**iOS 集合导出 `IOSBatchSelection` 漏改** → `look-<ordinal>`→`look-<sha>` 补齐。两处红锚均实测 EXIT=133。
- **方法论再确认**：①**冲突/竞态类必须二审**（本轮 5 张票的阻断全是"单审会漏"的时序或平台契约）；②**假绿三形态全部再次出现**（未覆盖真实入口、自比值、夹具失真）；③**"减法票写成加法票"的具体形态**=用元数据短路顶替内容凭证（#393 T4/T5）与"按实例私有缓存"（#397）；④**平台语义不可类推**：MediaStore 整秒 ≠ VFS 纳秒、NTFS 粗时钟/FAT 无 ChangeTime、ImageIO 对截断图返回非空——三处都靠实跑或实测钉死。

---

### (68) 审计清单清零（至 172）：过度防御大扫除收官；剩余项均为用户侧手动门禁

- **累计合入 172**（本波从 #388 起 36 单），`development` 现 `548ab84b`。**两次全仓审计（SHA-256 41 点 / 非哈希重处理 15 组）派生出的全部工单已落地**：SHA 四簇（#393/#394/#402/#403+#407）、批量账本三端（#406/#409）、启动清扫与 Freeze 搬线程（#396/#410）、缩略图缓存三端（#405/#397）、LUT 向导免拷贝（#401）、Win 导出尾趟（#400）、Android 相机账本（#414）、HDR 扫描融合（#412）、Mac PNG eXIf（#413）、Mac 账本缓存（#415）、LUT 副本去重（#416），以及两笔基建（#404 opencv 收编、#411 基线断裂修复）。
- **本轮净收益样例（实跑口径）**：LUT SHA-256 28.2→2.6ms；Mac PNG 导出 preserve 尾趟 8.92s→0.45s、峰值内存 +910MB→+9MB；HDR 拖杆每帧整图扫描 7→4；500 张批量账本整文件重读 1500+→1；缩略图缓存写 256 张 stat 3.3 万→256 且零强制同步；相机导出单张 ProRAW 全量哈希 7 次→0（内容寻址/摘要透传）。
- **收尾验证**：`development` 上 scripts/ci **245 OK(4 skip)**；dev-tip Windows native 门禁已派（run 43778371601）作为跨端最终回归。
- **剩余均为用户侧**：手动门禁 k165（Mac 桌面会话+AX）/k167（有显示器非锁屏）/k169（素材补齐后 5 脚本）/k173（真机与硬件 GPU 签收）/k175（待开工批次前置）、#370（用户侧 PR）、k179（Runner JIT 切生产）、k161 尾注（undo DRAFT 误开历史面板；单槽合并队列待日志证据）、k163 尾注（`--batch-selection` 纳入常规 CI 需 v08 布局）。

---

### (69) 审计残留清零（171–178）：模型包/AI 门禁收口；`分层复用` 成为成文硬原则

- **#417（171th）/#418（173th）** 文档：changelog (67)(68) 入库。
- **#416（172nd `548ab84b`）LUT 副本内容寻址去重**：任务目录内同一 look N 份→1 份（`<jobID>-<sha>.<ext>` 任务作用域前缀）。碳审打回两点：Mac `BatchJournal.directory` 是**跨任务平铺**目录，平铺放副本会被上一任务的 `releaseResources` 误删（`missingLook`）；iOS 集合导出漏改。返工后两处红锚均实测 EXIT=133。
- **#419（174th `5099381d` 前）undo/DRAFT 误开历史面板**（k161 登记项）：判据抽成 `adjustmentHistorySheetFor(userRequested, results)`——主动请求恒开、undo/redo 仅真实 BLOCKED/CONFLICT/FAILED 开、**DRAFT 门控拒收保持当前 sheet** 并走既有 Snackbar 提示；JVM 769/0，撤排除必红。
- **#421（175th）Apple HDR 单次读取+摘要复用（C-08/C-10）**：`export_stream` 内部哈希 **3→1**、`exportHEIF` **2→1**、CLI ProRAW（含前置扫盘）**4→1**。碳审抓出真阻断：原实现"先按路径读 NSData、再按路径 `stat`"（非 `fstat(fd)`），"读后 stat 前"替换会漏检，且 C-10 全零摘要路径可**把 A 的 EXIF 写进 B 的像素**并原子落盘；返工为 `open→fstat(before)→同一 fd 分块读入堆内存→fstat(after) 夹逼`，不跨流式周期持映射（防外部 `O_TRUNC` 触发 SIGBUS），红锚以注入缝模拟"读中途换 inode 替补"必 `SOURCE_CHANGED`。
- **#420（176th）AI 模型包进程级缓存（C-11/T2）**：正式包单次校验 **621.9MB**，此前每个新 session（缩略图/批量/编辑器）都重算。首版用 `(size,mtime)` 指纹被碳审打回（NTFS 15.6ms tick 击穿 `dualdn_package` 测试、且绕过硬 `packageStamp` 契约；canonical 为键却校验未规范化路径 + 锁外指纹 TOCTOU）→ 终版**复用同库 `sourceMetadataKey`**（零内容读、`fileReads==1` 不变）+ canonical 统一 + 指纹与校验同锁内。
- **#370（177th）MPF JPEG 导入校验**（用户 PR）：CI 两处注册遗漏由 lead 补齐——host JNI 测试缺 `-I lutools/src` 且未链接 `jpeg_mpf.cpp`；新 ctest `jpeg_mpf` 未进 `ci.yml` 白名单。
- **#422（178th）`dualdn_api` 预存在红定界 + Mac 真包门禁**：定界=**测试夹具漂移**（`b9e5de06` 把 `legacySonyCrop` 纳入 raw key 契约时，session 默认 `processing_version=Legacy`→true 而手工 fixture 走 false），产品反证=`dualdn_session`/`dualdn_native` 真包全绿。修法改测试不改产品；门禁首版挂错 `full`（`full` 本已跑真包 → 重复重建）且脚本在 GHA `GITHUB_ENV` 环境必崩、`eval "$(...)"` 吞退出码 → 返工改挂 `native && arm64`、显式 env 优先、缺输入硬失败。
- **成文原则（AGENTS.md 更新）**：新增 **「分层复用」** 三级优先级——①优先复用项目内已有基础设施与组件（`lutools`/`Shared/`/现有缓存与原子写原语）；②次选平台原生 SDK 或成熟开源库；③最后才最小必要自研并收敛为单一共享模块。本轮两例即实践：#420 从自造弱指纹改为复用 `sourceMetadataKey`、#422 复用既有 `ai-inputs.py` 而非另写解析。
- **收尾**：`development@97b5182b`，**开放 PR = 0**，scripts/ci 245 OK；剩余项全部为用户侧手动门禁（k165/k167/k169/k173/k175）、k179 Runner 切生产，以及两条条件项（k161 单槽合并队列待日志证据、k163 `--batch-selection` 入 CI 需 v08 布局）。
