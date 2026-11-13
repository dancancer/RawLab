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
