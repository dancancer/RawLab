# Code Review: CPU Build Checker Follow-up

## Must-fix

无。最终复查范围内未发现未处理的 P1/P2。

## Should-fix

无。原 P2/P3 及本轮独立复查发现的两个路径/数量边界均已修复并验证。
这不是对整个历史 Android WIP 或所有编译器输入作无缺陷保证。

## Review Scope

- 模式：self，本地未提交改动复查；分支 `feature/android-v08-editor`。
- Base / HEAD：`5a9774b75eeefbcd091698c12e8ac22a3409dff0`，未新增提交。
- 范围：`RawLabAndroid/tests/check-cpu-build.py`、`test_check_cpu_build.py`、
  `RawLabAndroid/README.md`、`cpu-denoise-performance-verification.md`、
  `reviews/self-android-cpu-denoise-20261015-2156.md` 五文件；本报告另行新增。
- 维度：浮点选项漏报、完整输出对象统计、负例是否由目标错误触发、验证证据归属。
- 强度：Solo，一个独立只读审查者覆盖全部五文件。用户暂停后原审查者继续；
  两个新增候选由主线程复现并修复，随后由同一独立审查者增量复查。
- 自动评审和 hosted CI：不适用；没有访问或写入远端。
- 原有 batch/GPU/JNI/UI WIP 保留，不计入本轮修改或该 commit 的独立验证。

## Reconciliation

1. 原 P2 已闭合：`check-cpu-build.py` 检查有限数、NaN/Inf、signed-zero、近似运算及
   重结合等选项；浮点模式使用明确安全值集合，未展开的响应文件和编译器参数转发失败关闭。
   两个实际 ABI 各三个单点负例均证明旧 commit 检查器误通过、最终检查器拒绝。
   这证明门禁修复，不代表实际构建曾使用这些危险选项。
2. 原 P3 已闭合：比较键包含规范化的完整源路径和输出对象路径，不再按源文件去重。
   arm64 的同一个 `dummy.cpp` 对应两个对象，均被保留。重排、删除和重复源的对象变更
   分别保持 CPU 策略有效，并断言唯一的比较错误，避免由其他失败掩盖漏检。
3. 独立复查发现同后缀路径可冒充 required source。已先复现六项替换，再将路径约束
   固定到当前检出和 ABI 构建目录下的默认 CMake 依赖布局；相对路径的正例仍通过。
4. 独立复查发现数值测试新增对象没有精确源路径和数量限制。现只接受当前检出的
   `lutools/tests/wavelet_denoise_tests.cpp`、正确 target，且最多新增一个对象。
   其他目录同名源和第二个对象的单点负例均被拒绝。
5. 最终独立增量复查确认以上修复闭合，未发现新的可执行缺陷。主线程最终实证核对
   也确认完整对象报告与保存的 JSON 一致，临时变异仅存在于内存。

## Local Verification

证据目录：`/tmp/rawlab-android-v08-56c3/cpu-performance/`。

- `python3 -B -m unittest discover -s RawLabAndroid/tests -p 'test_*.py'`：24 个方法通过。
- 初始 RED/GREEN、最后路径/数量 RED 及最终 GREEN 日志均保留；最终为
  `p2-p3-review-boundaries-green.log`。期间遗漏 `directory` 的测试 fixture 错误
  保存在 `p2-p3-review-fixture-error.log`，已补全 fixture，不改弱断言。
- 两 ABI 最终数据库策略检查和对象比较均 exit 0；优化前数据库仍分别产生预期的
  169/215 项未优化错误。最终内存探针见 `p2-p3-final-recheck.log`。

| ABI | 编译记录 Before / After | 唯一源文件 Before / After | 变化对象 | 新增 / 删除 |
| --- | --- | --- | ---: | --- |
| arm64-v8a | 783 / 784 | 782 / 783 | 169 | 1 / 0 |
| x86_64 | 782 / 783 | 782 / 783 | 215 | 1 / 0 |

变化仍仅为预期三个依赖的命令增加一个 `-O3`，其他 token 顺序不变。
旧 `compile-command-delta.json` 保留为历史材料，不再作为完整对象计数依据。

## Preservation and Limits

- 本轮没有修改 CMake、渲染算法、画质参数、GPU 路径或 Kotlin 测试。
  导出等待仍为 `BatchWorkflowInstrumentedTest.kt:136` 和
  `BatchGpuModeInstrumentedTest.kt:226` 的 `240_000`；预览仍为 `90_000`。
- 历史 212 项源清单有且只有两个检查器/测试文件因本轮修复不再匹配，其余 210 项未变。
  APK、native 测试程序和四对 float 输出的保存哈希再次匹配；没有重写历史清单。
- 排除本轮五文件后的 tracked WIP diff SHA-256 仍为
  `ba5302f1953296799e2fd8266c4b85380dd1d26f67916dbbb98a266500e16e46`；暂存区为空。
- 历史真机/像素/性能结果属于完整 WIP；本轮仅验证检查器和元数据，不是 `5a9774b`
  干净检出或这些未提交修复的新 APK、真机、Release 或 x86 runtime 测试。
- 检查器支持当前项目默认 CMake 布局，检查数据库所声明的路径和选项，不鉴定数据库
  的真实性，不检查历史源文件是否仍存在，也不代替源码/产物哈希或实际编译执行验证。
- `git diff --check` 通过。样片、构建产物、临时错误接线和计时未加入本轮源文件改动。

## Recommendation

本轮已确认问题处理完毕，可保留为待用户后续决定提交的本地修改。
没有 commit、push、PR，也没有发布远端评论、评审或批准。
