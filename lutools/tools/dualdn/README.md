# DualDn 原生实验构建

此工具把固定的 DualDn Big 权重转换为 RAW、官方 ISP、RGB 三个 ONNX 图。
Python 只用于转换和核验。Mac 应用用原生 Core ML 执行可选的 RAW/RGB float32 网络，
官方 ISP 和 CPU 回退通过 ONNX Runtime C++ API 执行。
设计和颜色边界见 [原照片内降噪契约](../../../docs/architecture/dualdn-inline-denoise.md)。

## 准备模型

使用上游 [DualDn](https://github.com/OpenImagingLab/DualDn) 源码的
`7ec5f6a21c04321beb0d3297d6e9ac5f50635555` revision，以及 SHA-256 为
`9bd36c18afd6148d3b5d50c215d77cc17a745851ed2735f1b655013e71c38e1d`
的 Big checkpoint。文件放在本机依赖缓存中，不加入 Git。
导出器会检查四个来源文件的摘要、420 个权重张量和 53,048,212 个参数，拒绝其他权重。

验证过的转换环境是 Python 3.11、PyTorch 2.10.0、ONNX 1.19.1、
ONNX Runtime 1.23.2、einops 0.8.1、kornia 0.6.12；另需 NumPy 和 ml-dtypes。
使用独立虚拟环境或项目共享依赖缓存安装，不把 Python 依赖放进应用包。

```bash
python3 lutools/tools/dualdn/export.py \
  --source "$DUALDN_SOURCE" --weights "$DUALDN_WEIGHTS" \
  --output "$DUALDN_PACKAGE" --tile-size 640
```

输出目录必须不存在。`manifest.json` 记录模型身份、图文件摘要、尺寸和 PyTorch/CPU
比较结果。`.f32` 文件只用于数值回放；应用仅复制模型、manifest 和上游许可。
64 像素图可用于快速回归，但产品入口只接受 640 像素协议。

在 Apple Silicon Mac 上安装 `coremltools==9.0`，从同一份权重生成原生加速包：

```bash
python3 lutools/tools/dualdn/export_coreml.py \
  --source "$DUALDN_SOURCE" --weights "$DUALDN_WEIGHTS" \
  --package "$DUALDN_PACKAGE" --output "$DUALDN_NATIVE_PACKAGE"
```

该目录包含 CPU 图及 `raw.mlmodelc`、`rgb.mlmodelc`，构建时将
`RAWLAB_DUALDN_MODEL_DIR` 指向它。转换固定为 macOS 14 MLProgram、float32、CPU/GPU，
不启用 float16 或 ANE。当前已核验 PyTorch 2.10.0 的导出结果；coremltools 9.0
会提示该 PyTorch 版本超出其已测试范围，因此转换仍必须通过内置数值检查。
原生文件逐个记录大小和 SHA-256；应用加载时校验，不在用户设备上转换模型。

## 构建 Mac 实验版

准备匹配目标架构的官方 ONNX Runtime 1.23.2 C/C++ 分发包，然后在仓库根目录运行：

```bash
RAWLAB_DUALDN=1 \
RAWLAB_ONNXRUNTIME_ROOT="$ONNXRUNTIME_PACKAGE" \
RAWLAB_DUALDN_MODEL_DIR="$DUALDN_NATIVE_PACKAGE" \
bash RawLabMac/build.sh
```

其他构建选项仍遵循 [Mac 构建说明](../../../RawLabMac/README.md)。
如需仅含 CPU 图的实验包，将模型目录改为 `$DUALDN_PACKAGE`；该包的 Auto 会使用 CPU。
`RAWLAB_DUALDN` 默认关闭；普通构建不需要模型或 ONNX Runtime。
实验构建验证模型后，把模型和动态库放入应用资源/Frameworks，并保留上游许可。
Mac 运行验收覆盖 Apple Silicon；Intel 和移动端未验证。Windows 的 DirectML 构建与
硬件要求见 [Windows AI 降噪说明](../../../RawLabWindows/README.md#实验性-ai-降噪)。

在“细节 → 降噪”中打开“AI 降噪（实验）”。首次完整计算后才保存启用状态。
默认使用 Auto：Apple Silicon/macOS 14 及以上优先执行原生 Core ML 网络，
官方 AHD/ISP 保持 CPU；缺少原生模型或后端执行失败时完整重跑该阶段的 CPU 路径。
Core ML 的 CPU/GPU 调度不代表每个算子都在 GPU 上运行。首次耗时取决于设备和后端，
CPU 回退可能需要数十分钟；取消在分块边界生效。
曝光、外观和裁剪复用结果，改变白平衡只重做 RGB 阶段。准备期间不能导出或复制设置。
重新打开已启用的照片会读缓存，缺失/损坏时重建；失败或取消后可以重试或关闭 AI。
批量导出只消费已经准备好的结果，缺失结果按照片报告失败，不偷偷启动整批 AI 推理。

缓存位于当前用户的 `Caches/RawLab/DualDn`，保存未白平衡 Bayer 和相机空间 RGB 修正。
文件包含 SHA-256 校验和实际生成后端，按文件身份、模型/运行库、处理版本和有效白平衡区分。
原生后端身份包括系统版本；更新系统或模型会重新准备结果。
缓存可重建；清理采用 8 GiB 的尽力限制，并保留当前正在准备的结果。

## 标定边界

当前实验配置 ID 是 `sony-ilce-7cm2-20261022-bce08d93bc36`，只接受
Sony `ILCE-7CM2`、14-bit、LibRaw Sony RAW type 4、7008×4672 有效尺寸、
四相位黑位 512、白位 16383、ISO 100–12800。

| 实测 ISO | k | b（方差截距） | 标定快门范围（秒） |
| --- | --- | --- | --- |
| 100 | 1.4017175356283488e-5 | 4.012456627349693e-9 | 0.166667–2.5 |
| 800 | 1.1384917115434277e-4 | 2.2385292275415084e-8 | 0.02–0.333333 |
| 3200 | 4.553081677833925e-4 | 3.6243917036353184e-7 | 0.005–0.0769231 |
| 12800 | 1.8241977770013236e-3 | 5.150549402363373e-6 | 0.00125–0.02 |

中间 ISO 在归一化的 `k/b` 上作实验性 log-log 插值；范围外不外推。
这是单次拍摄标定，没有独立拍摄轮次、温度、任意快门或跨机身的泛化验证。
真实照片的 NR 元数据与标定拍摄可能不同，因此支持该输入格式不等于认证相同读出条件。
RGB 分支沿用原始 noisy RAW 的噪声图，`b` 不能换成标准差。

## 验证入口

```bash
ctest --test-dir "$RAWLAB_BUILD_DIR" --output-on-failure
"$RAWLAB_BUILD_DIR/dualdn_onnx_tests" "$DUALDN_PACKAGE" cpu
bash RawLabMac/tests/control-groups.sh
RAWLAB_BUILD_DIR="$RAWLAB_BUILD_DIR" bash RawLabMac/tests/ai-denoise.sh
```

`dualdn_probe RAW MODEL_DIR NEW_OUTPUT full auto` 生成原生、RAW-only、官方参考、桥接结果
和可由应用读取的缓存；`raw` 模式只跑 RAW 分支。可用 `--raw-result PREVIOUS_OUTPUT`
复用经过文件身份、模型/参数与源像素核验的完整 RAW 分支结果。
验证目录、RAW 和 `.f32` 都应放在一次性测试目录，不能入库。

`ai-denoise.sh MODEL_DIR RAW CACHE_DIR` 还会验证 Auto 原生缓存的真实后端、缓存复用、普通降噪旁路、曝光编辑、
原尺寸预览/PNG 导出一致性以及 WB 失效。它不把视口缩小后的结果声称为原尺寸像素参考。
末尾追加 `cpu` 可检查 CPU 缓存。`dualdn_native_tests MODEL_DIR` 检查两个原生网络的
固定数值门槛、输入校验、ISP CPU 路径、Auto 回退和强制 Core ML 失败语义。
`dualdn_onnx_tests FIXTURE_DIR coreml --diagnostic MODEL_DIR` 可用独立原生包回放已冻结的真实张量。

`check_real_tensors.py` 接受外部 JSON case 列表（`id/path/model/iso/noise_new/parameter_origin/cross_body`），
逐张把相同的 640 像素张量送到 PyTorch 和原生三个图；它检查算子数值，不证明整图视觉质量。
`--diagnostic` 仅收集差异，不能当作验收通过。跨机身/外推样片只属于压力输入。

## 来源与许可

DualDn 的固定上游许可为 CC BY-NC 4.0（Copyright 2024 OpenImagingLab），
ONNX Runtime 为 MIT。原文保留在实验应用的 `Licenses/DualDn`。
本转换保留原始权重，没有训练或微调；变更包括拆图、固定尺寸、分块运行和 RawLab
颜色桥接。上游模型及派生产物保留其许可，不因宿主项目许可而重新授权。
