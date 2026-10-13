# Code Review: review/viewport-denoise-cache

本轮在隔离 worktree 上审查。本次优化与原评审开始时的补丁完全一致，未带入
Lensfun 镜头校正代码；评审结束时源码和新增文件指纹仍一致，快照有效。

## Must-fix

（无已确认的 macOS 发布阻断缺陷）

## Should-fix

### [P2][缓存失效] 共享 C API 混合 FBDD 配置仍有曝光锚点身份风险

实际 Kelvin RAW 输入在 PREVIEW 曝光模式下还依赖 `preview_camera_ev`，但
wavelet 源身份只取 `raw_key` 和尺寸。旧的逐次 RAW reload 清空已被取消，因此
中途改变相机预览曝光锚点后，保留的输出或分析可能与重新解码的输入不一致。

需要保护的最小序列：启用 wavelet，以 PREVIEW 曝光、Kelvin、FBDD=2 渲染；
改 FBDD=1，仍 Kelvin，渲染；再以相机 WB、FBDD=1 渲染，重算相机曝光锚点；
返回 Kelvin/FBDD=1。最后的 `raw_key` 与第二步一致，但实际增益可能已改变。
两个 preview 槽可保留第二步结果。若第三步暂时关闭 wavelet、第四步再启用，
中间请求不写降噪缓存，exact 槽也可保留按旧锚点生成的第二步结果；如果第三步
仍开启 wavelet，单个 exact 槽会被相机 WB 结果替换，不会命中旧 Kelvin 槽。

- Evidence: `lutools/src/ffi/sony2fuji_c.cpp:1200-1214`。
- Trace: `:729-737` 生成 RAW key，`:763` 使用锚点作为 RAW 处理曝光，
  `:785-787` 在相机 WB 后重写锚点；`raw_processor.cpp:159-174` 从处理后的
  采样估算曝光 EV，而 FBDD 在 `:90` 改变处理参数。
- Confidence: 中。可达 C API 状态和遗漏输入已确认；没有真实 fixture 证明
  此序列产生非零 EV 差，数值错误为未复现，不是已确认像素回归。
- Important narrowing: 单纯同一 FBDD 档位的相机/温度 WB 往返未发现可变输入，
  不应报成必然错误。当前 Mac `Engine.swift:89-96` 在 wavelet 非 nil 时强制
  FBDD=0，`Adjustments.swift:206-223` 也清除 legacy FBDD，不能触发此混合路径。
- Remedy: 补充混合 FBDD + WB 往返与 fresh session 的回归；把实际曝光锚点
  纳入源身份，或在锚点改变时失效受影响的输出与分析缓存。
- Gate: 此点不单独阻断当前 Mac 试用，但共享 C API 组合正确性在推广前需补证据。

### [P2][测试覆盖] 缺少启用降噪后的视口到原尺寸文件导出组合

`ViewportPreviewTests.swift:68-80` 的 JPEG/PNG 导出使用无 wavelet/chroma 的
`detail` 配置，且限制输出长边为 1200。wavelet 视口后的精确 buffer 和既有
wavelet 原尺寸 PNG 分别有测试，但没有覆盖同一会话新 viewport -> 完整文件
导出，并与独立 exact 会话比较像素和原尺寸。

- Evidence: `RawLabMac/tests/ViewportPreviewTests.swift:68-80`。
- Partial coverage: `lutools/tests/wavelet_cache_tests.cpp:58-59` 检查 FINAL buffer；
  `RawLabMac/tests/WaveletRenderTests.swift:47-67` 检查 native PNG，但没有启用
  新 viewport 模式。`photo_effects_tests.cpp:205-217` 检查文件忽略 flag，未启用 wavelet。
- Confidence: 高，这是具体组合缺测，不是已经发生导出质量回归。
- Remedy: 用真实 RAW、启用 wavelet，经过尺寸变化与强度/WB 调整后原尺寸
  导出 JPEG/PNG；与 fresh exact session 比较尺寸和像素，断言 PNG 为 16-bit。

## Review Scope

- Mode: self；branch `review/viewport-denoise-cache`。
- Worktree: `/Users/xupeng/.codex/worktrees/viewport-denoise-review/rawtools`。
- Base/head: `b31827cf9c4a3237eaebf3c3d4f8f6fa58422f13`；只审本次 WIP，
  不审此前 JPEG XL 提交。staged 为空，优化未 commit。
- Unstaged fingerprint: `41dc54014d2fd56e104405fa77c261982d2fdcf3216c1fdac2a608e1d42c5c50`，
  与迁移前原优化相同，结束时仍相同。新增测试、缓存头、基准、计划、验证报告
  和指令文件的内容哈希也相同。报告不纳入被审源码指纹。
- Coverage: 全部原优化 diff 和相关新增文件；核心 RAW/filter/output 调用链、
  PhotoCanvas -> EditorModel/RenderScheduler -> RenderEngine，以及单张/批量导出。
- Dimensions: 功能正确性、缓存并发性能、状态机、C ABI 兼容、测试覆盖。
- Intensity: Dual；两位独立审查者在新 worktree 复核已覆盖的相同源码与 prior
  findings，主代理核验迁移一致性、关键调用链及独立构建/测试；无降级。
- Excluded: Lensfun、其他平台接入、指令文件自身与历史 review 报告。
- Automated review / CI: self WIP，无 PR 自动审查或 exact-head CI。

## Fresh Verification

所有新构建/测试产物位于 worktree 的 ignored build 路径或测试临时目录，
未修改源 RAW。依赖读取原目录已构建的 arm64 库，未重建或修改该依赖安装。
Sony 测试 fixture 通过 ignored symlink 只读引用原目录；Panasonic RW2 使用外部路径。

- CMake Release，Metal/chroma/wavelet/DNG SDK 启用，OpenMP 关闭：配置和构建通过。
- `ctest --test-dir lutools/build-macos --output-on-failure`：23/23，0 失败，83.52s。
  包含 Sony/DJI RAW、RAW reuse/WB/FBDD、wavelet cache/analysis、CPU/Metal、
  photo effects、DNG/JXL 和输出契约。
- `RawLabMac/tests/viewport-preview.sh`：在此 worktree 新编译全部相关 Swift
  源码，使用 Panasonic S5II RW2，通过视口 CPU/Metal、half-size WB、返回精确
  buffer、JPEG/PNG detail 导出、PNG 16-bit，以及完整 EditorModel resize 回归。
- Resize 覆盖缩小/放大、快速变更、交互中变化、旧尺寸结果丢弃、降噪稳定窗口、
  旧 timer deadline 后不提前提交、busy/导出门禁、100% 取消等待和 native 质量。
- Test artifacts: `/tmp/rawlab-viewport-preview.EXp6zr`。
- `git diff --check`：通过。
- Not run: 混合 FBDD 曝光差复现、上述启用 wavelet 的 viewport -> native 文件
  组合、GPU 故障注入、Windows/Android/iOS 运行、本 worktree 的应用打包/签名。

## Reconciliation

未发现普通 WB/源文件/质量/尺寸/GPU mode/完整降噪 options 匹配上的已确认回归。
exact 与 viewport 槽隔离、preview 内存预算、源分析跨强度复用符合实现目标。

窗口取消逻辑运行在主队列，旧 DispatchWorkItem 在开始前取消后不执行闭包；
不报告仅凭“cancel 不能终止已开始执行”推导的假竞态。尺寸最终提交及 busy 门禁
通过新 worktree 模型测试；100% 和原图保持完整质量。

Swift 导出每次关闭 interactive/viewport flags（`Engine.swift:65-68`）；核心
只对 PREVIEW + BUFFER 启用 viewport（`sony2fuji_c.cpp:1108-1109`）。门控正确，
但不把分离的测试覆盖升级成完整降噪文件导出组合已经验证。

## Recommendation

macOS 路径未发现已确认回归，稳定快照的既有检查均通过。其他平台推广前先补齐
两个具体边界的回归证据；当前没有作出“所有组合无问题”的放行结论。

原工作区代码未被本任务撤销或修改。本轮只迁入已有优化、准备独立验证环境、
写入本报告，没有修复业务源码、commit、push 或推广其他平台。
没有发布远程评论、review 或 approval。
