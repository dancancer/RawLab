# Code Review: 5a9774b CPU Performance

## Must-fix

无 P1 或已确认的生产功能回归。

## Should-fix

### [P2][测试] 不安全浮点选项仍可让编译检查错误通过

位置：`RawLabAndroid/tests/check-cpu-build.py:21-22,59-64`。

`UNSAFE_MATH` 只匹配有限的完整选项。向真实 arm64 编译数据库中的
`wavelet_denoise.cpp` 命令追加 `-ffinite-math-only`、`-fno-honor-nans` 或
`-fno-honor-infinities`，`validate()` 仍返回空错误列表；相同探针对
`-ffast-math` 则正确拒绝。整个负例仅在内存中构造，没有修改源文件、编译数据库或设备。

这不是无影响的别名差异：使用本项目 NDK 编译器，把
`int is_finite(float x) { return __builtin_isfinite(x); }` 的 LLVM IR 输出到标准输出，
普通 `-O3` 保留浮点检查，而 `-O3 -ffinite-math-only` 直接生成 `ret i32 1`。
实际核心 `lutools/src/core/wavelet_denoise.cpp:421` 依赖 `std::isfinite` 拒绝非法参数。
因此这个守卫会漏报能破坏原有浮点语义的构建配置，不能据其成功判定没有此类选项。

当前保存的真实两 ABI 构建没有这些选项；本次仅新增 `-O3`，不能据此宣称已有
画质回归。但这是新增防回归检查的可复现误通过，独立审查者与主代理均复现。

- 置信度：高。
- 最小修复：至少补齐改变 NaN/Inf 等浮点语义的选项检查，并为每项增加参数化负例；
  保持检查失败关闭，不要通过删弱断言消除该问题。

## Nice-to-have

### [P3][验证记录] arm64 编译命令数被唯一源文件数替代

位置：`RawLabAndroid/cpu-denoise-performance-verification.md:70-73`，
以及 `reviews/self-android-cpu-denoise-20261015-2156.md:27-30`。

记录写每个 ABI 原始都有 782 条编译命令。实际保存的 arm64 baseline 数据库有
783 条记录、782 个唯一源文件；`hal/carotene/src/dummy.cpp` 被两个对象分别编译。
最终 arm64 数据库为 784 条记录、783 个唯一源文件。x86_64 则为 782 -> 783 条记录。

主代理本轮按源文件和输出对象组成的完整键重新比较全部记录，确认仍只有预期的
169/215 条命令增加 `-O3`，另新增一个数值测试对象，没有删除或额外选项变化。
所以本次优化范围结论成立，但原来的计数及“全部命令”表述应修正。

- 置信度：高。
- 最小修复：区分编译记录数和唯一源文件数，以对象级记录更新对比统计及文档。

## Review Scope

- 模式：self，本地单 commit，只读检查。
- 分支：`feature/android-v08-editor`。
- Base：`20f63978a75834dd19b253a7fca1253435801094`。
- Head：`5a9774b75eeefbcd091698c12e8ac22a3409dff0`。
- 范围：9 个提交文件，533 行新增；较早未提交 WIP 不归入该 commit。
- 维度：Debug 构建边界、画质/超时约束、测试误通过、验证证据归属。
- 强度：Solo，一个独立只读审查者覆盖全部 9 文件，主代理复核候选和原始证据。
- 自动评审及 hosted CI：本地检查，不适用；没有查询或发布远端评审。
- 只新增本报告；没有修改代码、既有文档、索引或提交，没有 push/PR。

## 已确认的边界

1. `RawLabAndroid/app/src/main/cpp/CMakeLists.txt:44-47` 使用 PRIVATE target 选项和
   `$<$<CONFIG:Debug>:-O3>`，只为 `wavelib`、`opencv_core`、`opencv_imgproc`
   追加 Debug 优化。没有修改全局 C/C++ flags，也没有向 Release 添加该选项。
2. `lutools/CMakeLists.txt:289-293` 新目标只在 Android 且启用 wavelet 时出现，
   `EXCLUDE_FROM_ALL` 不加入默认 CMake all；`-UNDEBUG` 保留测试断言。
   该测试源未改变，APK 中不包含测试可执行文件。
3. 渲染源、参数、GPU 模式传递、Kotlin 批处理测试和数值测试源在本 commit 与父提交间
   没有 diff。精确 commit 中两处导出仍为 `240_000`，预览仍为 `90_000`。
   不把完整 WIP 的文件行号冒充精确 commit 的行号。
4. 四组 before/after float 文件重新校验 SHA 后与原记录一致，每组前后相同。
   这是代表性浮点输出证据，不是所有设备/输入画质的数学保证；也没有旧完整
   32.7MP JPEG 在 240 秒内完成的证据。
5. `cpu-denoise-performance-verification.md:3-4,212-216` 明确写明运行结果属于
   完整 WIP，而非 CPU-only commit 的干净检出；旧复查报告 `:84-87` 同样明确。
   没有发现把这些结果伪称为本 commit 独立验证的表述。
6. 把冻结的 212 项清单直接对照此 commit，189 项相同、17 项内容不同、6 项不存在。
   当前工作区则 212/212 匹配冻结清单。这进一步确认两种验证范围不能混用。

## 本轮执行的核对

- 检查全部提交 diff；混合 batch 文档按 `git show` 读取，确实仅新增 6 行 CPU 链接。
- 六项 `python3 -B` 检查器单测通过；对真实数据库执行基线拒绝和最终通过核对。
- 独立逐对象检查所有原始/最终编译记录，确认优化目标和选项差异。
- 在内存中执行不安全浮点选项负例，并用 NDK 标准输出 IR 证明其语义影响。
- 核对 float 输出哈希、冻结源清单、真实 CPU/GLES/RLOOK 后端及预览失败恢复日志。
- 检查提交 whitespace；复核前后 HEAD、空暂存区及现有 tracked WIP diff 指纹未变。

没有重新构建 APK 或运行真机、Release、x86_64 runtime、低内存设备和全相机测试。
不能给出 exact-head 独立设备验证已通过的结论。

## 结论

生产优化边界、原有画质参数和等待常量未见本次回归；验证记录正确限定为完整 WIP。
建议先修正 P2 检查器误通过，再修正 P3 计数。此前“没有 P1/P2”的历史复查结论
不能覆盖本轮新增的负例发现。没有进行任何远端评论、评审或批准。
