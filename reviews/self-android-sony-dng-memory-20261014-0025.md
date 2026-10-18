# Code Review: Android Sony DNG Memory

## Must-fix

（无）

## Should-fix

（无）

未发现本轮改动仍需处理的可执行缺陷。此前指出的测试和不变量缺口已关闭。
GPU 低于 6GB 的设备不在用户要求范围内；本轮实际 GPU 验证设备约 12GB，
并未测试恰好 6GB 的设备。Windows/iOS 客户端没有在此次 Sony 修复后重新构建。

## Review Scope

- Mode: self；独立 worktree 的 `feature/android-sony-dng-memory`。
- Base、merge-base、HEAD 均为 `3f252a1006d349c2a3655129a9cf665385dccaca`；
  无新提交或暂存差异，审阅对象为 5 个修改文件和 4 个新增源代码/测试文件。
- 最终九文件 SHA 清单的 SHA256：
  `60f5442e5ccd47525d567a0125fd0e8731b1ef2607c562fce79c5229e4027ecf`。
  最后复核时逐项与源文件匹配，未混用不同状态的生产代码。
- 维度：RAW 重载生命周期、降噪缓存/分析复用、Auto/Force 失败语义、
  原尺寸导出颜色/精度、测试可复现性、真机应用数据隔离。
- Intensity: Dual；两个独立只读评审，主代理复核实际调用链和已完成的运行证据。
  修改后只复核发生变化的部分；未重复旧四平台全量审计。
- 自动远程评审/CI：本地 WIP 没有对应远程提交，N/A；本地验证见下文。
- 二进制/生成物通过构建日志、哈希、结构/像素解析及真实运行验证，
  不将不能阅读的 APK、照片或日志内容当作代码指令。

## Change Overview

三个生产修改只缩短整图缓冲区的重叠生命周期：独立系数生成后释放可从 RAW
重建的工作 RGB，restore 的 GaussianBlur 原地执行，CPU film blend 后释放 base。
公共 C ABI、降噪参数、滤波几何、缓存 key、输出尺寸与编码未改变。

共享处理核心存在跨客户端影响，因此不能把 Android 成功等同所有平台已发布。
新的可选重载只用于非 viewport/非 fast-wavelet 的完整 RAW 路径；窗口尺寸变化
相关代码未修改。Android 增加专用 Sony 真实文件测试及隔离构建/执行入口。

## Reconciliation

- 校准、滤波只读取独立 `transformed`、模型和样本，清空旧 RGB 后无悬空访问；
  restore 前重载并重新绑定 Mat。定位：`wavelet_denoise.cpp:474-500`。
- 不可变源像素数量校验确实存在新增不变量缺口，先以畸形源测试复现，
  再补齐 `wavelet_denoise.cpp:432-447` 的校验；原始输入不被修改。
- 直接 core 重试不足以证明 C API Auto 分支。新增
  `wavelet_fallback_tests.cpp:13-68` 用测试链接符号确定性触发 GPU 失败，
  调用真实 `sony2fuji_process`，比对独立 CPU 输出、缓存计数和 Force 硬失败。
  移除 empty-image reload 时 RED，恢复后 GREEN，关闭该缺口。
- 禁用构建不再只有静态推断：新 core-disabled 构建实际完成整个
  `sony2fuji_core`，wavelet/chroma/GPU 均关闭。
- `sony-dng-memory.sh:7-9` 正式默认是三格式、原尺寸、reference=true。
  子集/缩小尺寸/false 仅用于明确的诊断对照，不当作完整门禁。
- 100ms native heap 采样不能证明瞬时 RSS 峰值；测试最终读内核 VmHWM，
  RSS 门槛单独记录和断言，实际无 LMK 完成仍是独立证据。
- Runner 现在记录 native/RSS 门槛和 APK SHA，安装前检查实际应用 ID。
  非隔离 APK 实测在任何设备操作前被拒绝，未覆盖用户的正常应用。
- C API fallback 仅使用既有、明确要求 applied NR 的外部 fixture 参数，
  避免任意静态 RAW 提前返回导致测试错误失败。

## Verification

- 2.5GB CPU 的基线 LMK 位于 wavelet filter，尚未到 writer；同条件修复后的
  capped 对照通过。最终冷启动、无探针原尺寸三格式加独立 FINAL 通过，
  sampled heap 从约 2.085GB 降至 1.692GB，kernel VmHWM 1,649,688 KiB。
- 约 12GB 真机 CPU 和 Force GLES 原尺寸 JPEG/PNG/DNG 全通过；每个 backend
  三个完整文件在修复前后逐字节一致，viewport-history 与 fresh 文件也一致。
- GPU 的第一处理器会话峰值前后约 2.460GB，未出现工作集回归；不宣称此次
  修复优化了 GPU 峰值。CPU/GLES 像素比较仍在既有容差内，最大 RGB8 差 1。
- 核心 CPU 23/23；最终无探针 focused wavelet 1/1；核心 Metal 4/4；
  确定性 C API fallback 最终 1/1；禁用核心完整构建通过。
- Android arm64 app/test 构建通过，68 单测通过；最终 lint 0 errors/17 warnings。

完整参数、文件 SHA、进程死亡证据、旧 wrapper 错误的区分和重现命令见
`https://github.com/dancancer/RawLab/blob/a38ac6065f747cc43ddbee1c8df232c049b288d2/docs/verification-android-sony-dng-memory-2026-10-14.md`。

## Recommendation

本地修复及指定矩阵验证完成，可供后续整合评估。改动仍在独立 worktree；
不将此结论作为其他平台已推广或候选版本已吸收修复的证明。
没有发布远程评论、评审或批准，没有修改 PR30，也没有合并、推送或发布。
