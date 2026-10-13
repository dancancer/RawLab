# JPEG XL DNG 解码验证 2026-10-12

初始验证分支：`fix/dng-jpeg-xl-decoding`，基线 `f9a5387`。本记录对应修复验证阶段；不发布客户端，也不修改原始 RAW。

## 原因与修改

用户提供的 Samsung Galaxy Z Fold6 样片为 DNG 1.7、Compression 52546、三通道
16-bit LinearRaw。原有 LibRaw 0.22.2 构建没有 Adobe DNG SDK，选中了 JPEG XL
占位解码器，不能解压像素；上层又将该错误误报为文件路径或权限问题。

- 四端接入同一固定版本的 Adobe DNG SDK 1.7.1 build 2724，使用其随附的 JPEG XL、Brotli、Highway 和 skcms 源码；完整许可证随客户端打包。
- 每个处理器管理自己的 SDK host，并保证 host 晚于 LibRaw 释放。仅 JPEG XL DNG 使用该 host，其他 RAW 保留原解码路径。
- 启用必需的 Stage2/Stage3 opcode 处理；统一 SDK、LibRaw 和调用方的平台与线程安全宏，保持 SDK 类布局一致。
- JPEG XL 的 SDK 解码失败立即中止，不回落到占位器或使用半解码数据。区分不支持、路径不可读、内存不足和解码失败，公共 C ABI 不变。
- SDK build 2724 的两处 JXL XMP 元数据代码缺少条件保护，构建时生成带保护的副本；不改变像素解码代码，不编译 XMP 编辑工具链或 validator。
- Xcode 对仅引用 OBJECT targets 的 JXL 静态目标未生成归档；为该目标添加随附的空编译单元，由 CMake 正常生成和更新归档，不使用手工拼接或陈旧的缓存库。

依赖下载与 SHA-256 固定在 [dng-sdk.cmake](../lutools/cmake/dng-sdk.cmake)，处理顺序记录在[色彩约定](../lutools/docs/color-contract.md)。

## 回归依据

四个仓库 fixture 均为合成像素，不是个人照片。基础对照使用相同的 32x24 RGB ramp，
一份无损 JPEG XL、一份未压缩，方向均为 6。另一组让 JXL 文件的必需 Stage2
GainMap 将三通道乘以 2，与独立生成的双倍整数像素比较。

`dng_jxl_tests` 验证解压后的线性像素、方向、白平衡/曝光重载、同一处理器切换
解码器、GainMap、损坏 JXL 错误分类，以及 C ABI 的 CPU/Auto 输出。四次线性
最大误差均为 0。临时移除 Stage2/Stage3 开关时 GainMap 对照误差为 0.372199，
测试退出 1；恢复开关后通过，未降低阈值。损坏文件测试先失败，修复后返回
`PROCESSING_ERROR` 且不产生输出。

fixture 来源与再生成方式见 [fixtures/README.md](../lutools/tests/fixtures/README.md)。
Windows 源码传输只对白名单中的四个合成 DNG 放行，其他个人 RAW 仍被排除；
对应的源码打包单元测试通过。

## 平台结果

| 平台 | 本轮实际验证 | 结果与边界 |
| --- | --- | --- |
| macOS arm64 | 最终依赖、应用构建与打包；CTest；合成 fixture 和用户 DNG；应用中性/PROVIA JPEG、16-bit PNG 导出 | 构建与动态依赖闭包/签名检查通过，CTest 14/14 通过，JPEG XL 回归通过 |
| Android | arm64-v8a/x86_64 APK 构建、单元测试、Lint；API 35 arm64 本机模拟器运行合成 fixture 和用户 DNG | Gradle 通过，原生回归退出 0；未安装应用或触碰物理设备，不代表真机性能/内存验收 |
| iOS | 设备 arm64、模拟器 arm64/x86_64 XCFramework；应用模拟器 Debug 和未签名设备 Release；模拟器运行合成 fixture 和用户 DNG | 构建、许可/依赖检查及原生回归通过；未在物理 iPhone/iPad 运行 |
| Windows x64 | 现有专用 Windows 11 虚拟机原生编译共享核心、LibRaw 和 WPF 自包含包；CPU CTest；合成 fixture 和用户 DNG | 构建/打包、4/4 CPU CTest、JPEG XL 回归和 `raw_smoke` 通过；未运行完整 WPF/GPU 套件 |

macOS 原尺寸输出为 3000x4000，LibRaw 参考 WB 平均误差为 `8.29457e-09`；
曝光线性、8/16-bit 安全及原始文件保护检查通过。实际导出图像已检查，内容和方向正常。
该参考比较不能代替独立的厂商色彩标定或机内 JPEG 风格认证。

Android 最终证据：[Gradle](../build/android-dng-final-gradle.log)、[可复现 harness](../build/android-dng-final-harness.log)。
iOS 最终证据：[三架构/XCFramework](../lutools/build-ios/dng-jxl-xcode-final.log)、[DNG 回归](../lutools/build-ios/dng-jxl-BC99A8BD-B3DF-4410-BB43-ABF08E9C3A91/dng-jxl.log)、[模拟器应用](../build/ios-dng-jxl-app-simulator.log)、[未签名设备应用](../build/ios-dng-jxl-app-device.log)。
Windows 最终证据：[原生/WPF 构建](../build/windows-remote/20261012-173543/build.log)、[CPU 和 DNG 回归](../build/windows-remote/20261012-173543/dng-jxl-runtime.log)、[自包含客户端](../build/windows-remote/20261012-173543/RawLab-Windows.zip)。设备仅有普通虚拟显示适配器，未将 CPU/Auto 回退当作真实 Direct3D 11 通过。用于回归的个人 DNG 副本在结束时已删除，不进入源码或客户端压缩包。
忽略目录中的日志/产物仅在本机保留，不随 Git 发布。

## 复现

```bash
bash RawLabMac/build.sh
bash RawLabMac/tests/smoke.sh "$RAWLAB_TEST_JXL_DNG"
export PKG_CONFIG_PATH="$PWD/build/macos15-deps/$(uname -m)/install/lib/pkgconfig"
bash lutools/test.sh lutools/build-jxl-verify
lutools/build-jxl-verify/dng_jxl_tests "$RAWLAB_TEST_JXL_DNG"
python3 RawLabWindows/tests/remote_build_test.py
```

移动端的独立 harness 及构建前置条件见 [Android README](../RawLabAndroid/README.md)
和 [iOS README](../lutools/platform/ios/README.md)。Auto 模式允许回退 CPU，不能仅凭
CPU/Auto 输出相同宣称实际 GPU 后端已运行。物理移动设备与 Windows 真显卡验证不在当前通过范围内。

## development 集成复验

提交交付时发现初始分支还包含两个未合入 `development` 的 AI 调色提交。
因此保留原工作区，将 DNG 修复单独移植到 `origin/development` 的 `12d6cc1`，
使用 Gitflow 分支 `feature/dng-jpeg-xl-decoding`。PR 不包含 AI 调色功能、公开
C ABI 修改、版本升级或其他客户端功能改动。两个构建配置冲突保留了目标分支的
主配方资源、chroma denoising 和 OpenCV contrib。

集成分支重新执行了以下检查，不将初始分支的结果直接当作新基线通过：

| 检查 | 结果 |
| --- | --- |
| 未修改的 `development` 核心基线 | CTest 11/11 通过 |
| 移植后独立核心构建 | CTest 12/12 通过，包含新增 JPEG XL 回归 |
| macOS 最终应用构建与打包 | 构建、动态依赖闭包、许可证和签名检查通过 |
| macOS 最终应用配置 | CTest 16/16；合成 JXL、外部 DNG、DJI 及原尺寸导出通过 |
| Android | arm64-v8a/x86_64 构建通过；58 项 JVM 测试全部通过；Lint 无 error（38 warnings、1 information）；API 35 arm64 模拟器 JPEG XL 回归通过 |
| iOS | 三架构 XCFramework、模拟器 Debug 和未签名设备 Release 构建通过；模拟器合成 JXL 和外部 DNG 回归通过 |
| Windows x64 | 原生/WPF 自包含包构建通过；4/4 CPU CTest、合成 JXL、外部 DNG 和 `raw_smoke` 通过；六个 SDK notice 齐全 |
| Windows 源码打包 | 单元测试通过，个人 RAW 排除规则不变 |

Android 首次下载 SDK 因网络中断失败；最终使用同版本的本机 SDK 源码缓存重跑
全部构建和检查并通过，没有修改 tracked source 或取消验证。用于移动模拟器及
Windows 回归的个人文件副本已清理，仅停止本轮自行启动的模拟器。物理移动设备、
Windows 硬件 GPU 和完整 WPF 交互仍未验证。本节均为本地/专用构建机检查，不是 CI。

本机证据目录为 `build/dng-jxl-integration/`：`core-ctest.log`、`macos-build.log`、
`macos-ctest.log`、`macos-dng-smoke.log`、`gradle-rerun.log`、`dng-jxl-arm64.log`、
`ios-framework.log`、`ios-simulator/dng-jxl.log`、`rawlab-sim-build.log` 和
`rawlab-device-build.log`。Windows 日志位于
`build/windows-remote/20261012-220912/` 的 `build.log` 与 `dng-jxl-runtime.log`。

## PR 23 评审修复复验 2026-10-13

本轮在 `feature/dng-jpeg-xl-decoding` 上处理 Stage1、ActiveArea 与 SDK 内存异常，
不修改公共 C ABI、原始 RAW 或其他解码器。三个评审问题均先复现再修复：

| 条件 | 修复前 | 修复后 |
| --- | --- | --- |
| 只有必需 Stage1 MapTable、没有 OpcodeList2/3 | 加载成功，但与独立半值像素对照的最大误差为 `0.186099`，测试退出 1 | 强制 SDK Stage2 路径先执行 Stage1，最大误差为 0 |
| 32x24 存储尺寸、内部 30x22 ActiveArea、必需 GainMap | 返回 `Corrupted data or unexpected EOF`，测试退出 1 | 同步 SDK 输出尺寸及边缘偏移，方向 6 的输出为 22x30，最大误差为 0 |
| SDK 分配器内存不足 | 加载、白平衡重载及 C ABI 都被误分类为普通解码/处理错误，测试退出 1 | SDK `dng_error_memory` 和 `std::bad_alloc` 保留为 LibRaw 内存错误，再返回 `OutOfMemory` / `OUT_OF_MEMORY`，不产生 C ABI 输出 |
| ActiveArea 内还有非零 DefaultCropOrigin | 仅允许尺寸变化后仍有像素偏移，最大误差为 `0.0244148`，测试退出 1 | 将两个 inset crop 项从存储坐标转成 Stage2 坐标，20x28 输出最大误差为 0 |

回归套件现在使用 11 个合成 DNG。Stage1 MapTable 与独立未压缩半值像素比较；
ActiveArea/GainMap 和 DefaultCrop/GainMap 各与独立双倍整数像素比较；未知必需
Stage1 opcode 必须在 core 和 C ABI 中拒绝，不能静默跳过。所有新增用例都在
默认 `dng_jxl_tests` 中运行，不依赖手动选择参数。内存故障通过 SDK 官方的
`DNG_SetSimulateMemoryFull` 注入，覆盖首次加载、白平衡重载和 C ABI。

LibRaw 补丁已分别验证干净源码、旧补丁缓存升级和重复执行；没有修改上游 SDK
像素解码源文件。Windows 传输白名单及 iOS staging 已同步新增 fixture，个人
RAW 排除规则不变。

最终源码复验：

| 平台/检查 | 结果 |
| --- | --- |
| macOS arm64 | 原生核心、客户端和打包通过；CTest 16/16；11 个 fixture 与外部 Samsung DNG 回归通过；实际客户端 Samsung/DJI JPEG、16-bit PNG 导出通过 |
| iOS | 三切片 XCFramework、模拟器 Debug、未签名设备 Release 构建通过；模拟器 11 个 fixture、OOM 及外部 DNG 回归通过，新增 DefaultCrop 误差为 0 |
| Android | 两 ABI 构建通过；API 35 arm64 模拟器 11 个 fixture、OOM 及外部 DNG 回归通过，新增 DefaultCrop 误差为 0；本轮 58 项 JVM 测试和 Lint 已通过，最终仅改 C++ glue 后未重复无关的 JVM/Lint 检查 |
| Windows x64 | 专用构建机原生/WPF 自包含包构建通过；4/4 CPU CTest；11 个 fixture、OOM 及外部 DNG 回归通过，新增 DefaultCrop 误差为 0；`raw_smoke` 和六份 SDK notice 检查通过，临时个人 DNG 已删除 |
| 源码/补丁检查 | Windows 源码打包单元测试、shell 语法及 `git diff --check` 通过；干净源和已打补丁源重复执行 CMake patch 通过 |

本轮日志位于 `build/dng-jxl-review/`，包括 `macos-ctest-final.log`、
`macos-dng-jxl-final.log`、`macos-app-final.log`、`macos-app-smoke-final.log`、
`android-final-gradle.log`、`android-final-dng-jxl.log`、`ios-final-framework.log`
和 `ios-final-simulator/dng-jxl.log`；Windows 运行证据为
`windows-targeted-tests-final.log` 与 `windows-final-cleanup-check.log`，最终构建记录
位于 `build/windows-remote/20261013-110110/build.log`。这些是本地/专用构建机检查，
不是 hosted CI。
物理移动设备、Android x86_64 运行时、Windows 硬件 GPU 和完整 WPF 交互仍未验证；
CPU/Auto 像素一致不代表硬件 GPU 已执行。

## Stage2 白平衡时序复验 2026-10-13

原独立复审固定在 `40ce6084eb4bfd6f911079d9fa4e8c80b83d9c68`，确认上轮三项
已修复，但指出 Stage2 标志晚于 `open_file` 设置。LibRaw 在识别时已经按各通道
`WhiteLevel - BlackLevel` 校正白平衡，之后 SDK Stage2 又按这些范围线性化；
`recycle()` 保留的 flags 还会让后续白平衡重载或普通 DNG 的识别不同于首次加载。
本轮保留该固定提交和报告，先补可达的失败回归，再修改实现。

新增三个合成 fixture 使用 BlackLevel `(1024,2048,4096)`、WhiteLevel
`(32767,49151,65535)`；独立参考直接将整数样本按
`(sample - black) * 65535 / (white - black)` 归一化并四舍五入，不调用 SDK。

| 回归 | 修复前 | 修复后 |
| --- | --- | --- |
| 首次相机 WB 与独立归一化像素 | 最大误差 `0.249717` | 最大误差 0 |
| 相机 -> 自定义 -> 相机 | 最大误差 `0.249717` | 最大误差 0 |
| 同一处理器 JXL -> 普通 DNG 与新建普通处理器 | 最大误差 `0.370309` | 最大误差 0 |
| 同一 C ABI session 相机 WB 往返 | 最大字节误差 65 | 最大字节误差 0，自定义输出也确认不同于相机输出 |

最小修复为：每次识别前清除本路径管理的 JXL flags 和 host 绑定，先识别 decoder；
仅 JPEG XL 在 Stage2 flags 已设置的情况下重新打开，再绑定 SDK host 和 unpack。
普通 RAW/DNG 仍为原来的单次打开，不改变公共 C ABI、其他解码器或 SDK 源码。
`raw_smoke` 的 LibRaw 参考路径同步修正，避免参考本身重复同一个时序错误。

默认套件现在包含 14 个 fixture，四端均重跑了新旧用例和外部 Samsung DNG：

| 平台/检查 | 结果与边界 |
| --- | --- |
| macOS arm64 | 构建/打包、16/16 CTest、14 fixture、外部 DNG、`raw_smoke` 及实际 Samsung/DJI JPEG/16-bit PNG 导出通过 |
| iOS | 三切片 XCFramework、模拟器 Debug 和未签名设备 Release 通过；专属 `RawLab DNG WB QA` 模拟器运行 14 fixture 和外部 DNG 通过，随后只删除该自建实例 |
| Android | arm64-v8a/x86_64 构建、58/58 JVM 测试、Lint 无 error（38 warnings、1 information）通过；专属 `emulator-5584` 的 API 35 arm64 运行 14 fixture 和外部 DNG 通过；未操作 `emulator-5582`，未执行任何 connected 测试 |
| Windows x64 | 原生/WPF 自包含包、4/4 CPU CTest、14 fixture、外部 DNG、`raw_smoke` 和六份 SDK notice 通过；临时个人 DNG 副本已删除，构建进程已结束 |

Android 初始专属端口 5590 的设备没有注册到 adb，保留失败日志后换到空闲推荐
端口 5584，通过最终 harness；只清理本轮专属实例/AVD，没有重启全局 adb 或
影响其他模拟器。物理移动设备、Android x86_64 运行时、Windows 硬件 GPU 和
完整 WPF 交互仍未验证，不把 CPU/Auto 一致当作真实 GPU 执行。

本轮本机证据目录为 `build/dng-jxl-wb/`，包含 `macos-wb-red.log`、
`macos-wb-green.log`、`macos-ctest.log`、`macos-app-smoke.log`、
`android-gradle.log`、`android-dng-jxl-5584.log`、`ios-framework.log`、
`ios-simulator/dng-jxl.log`、`windows-targeted-tests.log` 和
`windows-cleanup-check.log`；Windows 构建在
`build/windows-remote/20261013-114016/build.log`。这些是本地/专用构建机检查，
不是 hosted CI；日志和个人 RAW 均不进入提交。
