# RAW 格式支持与上游回移植

RawLab 使用 LibRaw 0.22.2-Release 的 ABI 和数据布局，并通过
[`patch-libraw.cmake`](../../lutools/cmake/patch-libraw.cmake) 在四个平台应用相同的解码与相机元数据修正。
普通 JPEG/PNG/TIFF 使用平台图像解码器；启用 LibRaw 的 JPEG 依赖专门用于 RAW 容器里的 JPEG 编码。

## 固定源码来源

发布基线是 [LibRaw 0.22.2-Release](https://github.com/LibRaw/LibRaw/tree/0.22.2-Release)
（`b93f6e45c194f5df9b02a43b1af9a54b4f41f33f`）。增量核对到 master
[`8b376613626c41f83b260e520d43c02f8aff762b`](https://github.com/LibRaw/LibRaw/tree/8b376613626c41f83b260e520d43c02f8aff762b)，
并检查相关未合入 PR。master 已有新的共享库 ABI，不能直接替换发布库后假定现有客户端兼容。
下表记录实际采用的代码来源，不表示所有模式都完成相机色彩标定。

| 支持 | 来源与实现 |
| --- | --- |
| Sony ARW6 / Compressed RAW 2、ILCE-7M5（A7 V） | 已合入 master 的 [PR 824](https://github.com/LibRaw/LibRaw/pull/824)、[A7 V PR 825](https://github.com/LibRaw/LibRaw/pull/825) 及后续 [`e419de0`](https://github.com/LibRaw/LibRaw/commit/e419de08001de28ae6988ecb22df47e52b9c5eaa)；保留完整上游解码器、分块/尾行处理及最终黑白电平修正，另带型号、有效区域和色彩矩阵 |
| Sony ILCE-1M2（A1 II） | 已合入 master 的 [PR 775](https://github.com/LibRaw/LibRaw/pull/775)、[PR 846](https://github.com/LibRaw/LibRaw/pull/846)；型号 ID、全画幅及缩小尺寸的有效区域、色彩矩阵 |
| Canon EOS R50 V | 已合入 master 的 [PR 784](https://github.com/LibRaw/LibRaw/pull/784)；型号 ID、ColorData 识别和矩阵 |
| Canon PowerShot V1 | 未合入的 [PR 856](https://github.com/LibRaw/LibRaw/pull/856)，固定 head `27b4621a7591eae6e2412f656ab78d11dcd4ce0f`；ColorDataSubVer 65 使用现有 v12 布局，并加入矩阵和相机列表 |
| Sigma Merrill / Quattro X3F | 启用发布源码已有的 `USE_X3FTOOLS` / `ENABLE_X3FTOOLS`；同时开放各客户端 `.x3f` 导入入口 |
| 有损 JPEG DNG（Compression 34892） | 各平台启用 LibRaw JPEG 解码，固定 libjpeg-turbo 3.1.3、JPEG8 ABI；不改变 Adobe DNG SDK 的 JPEG XL 路径 |

相机补丁位于 [`libraw-cameras.cmake`](../../lutools/cmake/libraw-cameras.cmake)，
ARW6 还对损坏码流补充系数范围检查、无溢出的符号运算、64 位重建中间值及越界拒绝，
并拒绝不足 16 行、没有低频行的 tile。补丁和第三方源码位于
[`libraw-sony-arw6.cmake`](../../lutools/cmake/libraw-sony-arw6.cmake)、
[`third_party/libraw`](../../lutools/third_party/libraw/README.md)。依赖缓存必须包含这些输入；
改变补丁后不能复用旧 LibRaw 二进制。

已有的 Nikon HE、Hasselblad X2D II、Canon R6 III 和 JPEG XL DNG 支持保留。
Nikon HE 使用项目已有、经过样片校验的实现；HE* 支持边界仍以
[解码器说明](../../lutools/third_party/nikon_he/README.md)为准。

## 尚未采用的实验代码

- [RX1R III PR 847](https://github.com/LibRaw/LibRaw/pull/847)：部分有效区域来自目测估计，缺少对应模式的可靠元数据/样片证据，暂不复制这些裁切参数。
- [X3F PR 829](https://github.com/LibRaw/LibRaw/pull/829)：额外白平衡和 Quattro 重建算法属于独立的画质变化；本项目先启用发布版已有解码器，避免把新的颜色/重建行为等同于格式可读性。
- [Nikon HE PR 826](https://github.com/LibRaw/LibRaw/pull/826)：不覆盖已有本地实现；直接替换会丢失现有重建修正，也不能据此宣称 HE* 已支持。
- [AAHD PR 783](https://github.com/LibRaw/LibRaw/pull/783)：属于去马赛克性能改动，不增加文件格式支持。

## 回归验证入口

默认 CTest 包含可完整显影的 JPEG-compressed DNG。链接 RawLab 补丁版 LibRaw 时
（本树构建，或依赖前缀带 `share/rawlab/libraw-patch.sha256`）还包含合成 ARW6 容器的分派、
修正电平、正常 tile 解码及短 tile、越界系数拒绝测试；未打补丁的系统 LibRaw 跳过这些测试。
`SONY2FUJI_TEST_LIBRAW_SOURCE` 指向补丁后的 LibRaw 源码树时，另加带 UBSan 的
`sony_arw6_bounds` 重建回归。真实照片不入库，通过 CMake 参数选择：

```sh
cmake -S lutools -B lutools/build-macos \
  -DSONY2FUJI_TEST_SONY_ARW6=/path/to/DSC06333.ARW \
  -DSONY2FUJI_TEST_FORMAT_DIRECTORY=/path/to/raw-reference
ctest --test-dir lutools/build-macos --output-on-failure -R 'sony_arw6|raw_format'
```

`raw_format_tests.cpp` 指定共享样片的 SHA-256 文件名；外部目录包含 Sigma DP2 Merrill、
dp2 Quattro、两份有损 DNG、A1 II 的未压缩/无损/有损/缩小模式、R50 V RAW 和 V1 CRAW。
这些公开参考文件来自 [raw.pixls.us](https://raw.pixls.us/)，以 CC0 发布；[参考文件清单](../../lutools/tests/fixtures/raw-references.json)记录来源 URL、许可、大小和校验值。测试检查型号、有效尺寸、相机矩阵、完整解码、
显影和像素细节，不能用内嵌预览替代 RAW 解码。

普通图像的 ICC+EXIF 色彩元数据回归在 Windows 原生 `windows_display_image` 测试中。
用户原始 JPEG 可通过 `RAWLAB_TEST_RASTER` 运行 Apple 图像测试；Android 使用
`rawlabTestSonyArw6` / `rawlabTestRaster` Gradle 属性及 `ExternalPhotoImportInstrumentedTest`。

iOS Simulator 可用 `bash lutools/tests/raw-codecs-ios.sh <framework> <simulator-uuid>`
运行同一套合成解码检查；`RAWLAB_TEST_SONY_ARW6` 和 `RAWLAB_TEST_FORMAT_DIRECTORY`
可接入上述外部样片。Android 的有损 DNG 回归使用入库的合成小文件，默认运行、不跳过。
