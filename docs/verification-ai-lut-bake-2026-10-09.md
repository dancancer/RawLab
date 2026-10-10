# AI 仿色 CUBE 编译前提验证

日期：2026-10-09。分支：`codex/macos-ai-color-match`。

## 结论

已批准设计中的“将现有中性显影完整烘焙为 65/129-grid F-Log2 CUBE，
并以全采样域最大通道误差 0.02 作为硬门槛”未通过前置验证。
即使 AI 配方为恒等操作，Python 预处理器和原生 C++ 路径也均失败。
因此不能在不修改设计的情况下把该路径交付为可用功能。

没有放宽门槛，没有把失败产物导入应用，没有上传任何照片或再次调用付费 API。
本轮没有实现 AI 界面、原生编译器或分享功能；只保留可复现的数值探针。

## 测量结果

数值为绝对显示 sRGB 单通道误差，不是百分比或 Delta E。

| 路径 | 网格 | 最大误差 | 全部通道 p99 / 分组 p99 | 门槛 |
| --- | --- | --- | --- | --- |
| 现有 Python/OCIO 准备器 | 65 | 0.494203299 | 全部 0.012807595 | FAIL |
| 现有 Python/OCIO 准备器 | 129 | 0.433937818 | 全部 0.003085770 | FAIL |
| 原生 C++，完整 Log 域 | 65 | 0.473513335 | 域内 0.009575725 | FAIL |
| 原生 C++，摄影 scene 样本 | 65 | 0.271029711 | scene 0.018688083 | FAIL |
| 原生 C++，完整 Log 域 | 129 | 0.279617608 | 域内 0.001936436 | FAIL |
| 原生 C++，摄影 scene 样本 | 129 | 0.156048149 | scene 0.005221426 | FAIL |

灰阶最大误差为 65-grid 的约 0.002493、129-grid 的约 0.000620，均低于门槛。
这说明仅检查灰阶或平均误差会漏掉此次高饱和颜色问题。
两条路径使用不同的固定随机样本，不能把最大值差异当作 CPU/OCIO 不一致证据。

## 原生证据

探针直接复用当前源码中的 `decodePhotoLog`、`ColorConverter` 和 `neutralDisplay`，
写出 R-fast CUBE，再通过 `LUTParser` 重新读取，以 `LUTApplicator` 三线性插值比较。
没有自行替代原生色彩公式或插值公式，也不依赖可能过期的已构建静态库。

固定种子 20261009，样本为 4096 个随机 Log 点加 17x17x17 网格、513 个灰阶点、
4096 个曝光范围 -10 到 +6 EV 的正线性 sRGB 样本转换得到的 Log 点。

65-grid 的一个实际错误样本：

```text
F-Log2 RGB: [0.816386402, 0.918075979, 0.712974608]
线性 sRGB: [1.09411871, 29.251543, 1.4890188]
直接中性结果: [0.888914406, 0.999028206, 0.925283313]
CUBE 插值结果: [0.415401071, 0.999022901, 0.918899834]
```

该网格单元八个角点在线性 sRGB 的红通道约为 -0.116 至 4.797。
经中性显影后，角点红通道跨越 0 至约 0.986。
F-Log2 网格通过色域矩阵转换后，在单个粗网格单元内跨越了中性曲线的陡峭区和零点截断区，
三线性插值无法复现单元内部的解析结果。这一现象足以解释该反例，不能靠普通文件校验发现。

129-grid 的摄影 scene 反例也来自正线性 sRGB，而非只来自不可实现的负色彩：

```text
线性 sRGB: [0.122559994, 12.3157501, 8.42050838]
直接中性红通道: 0.364165097
CUBE 插值红通道: 0.208116949
误差: 0.156048149
```

## 重现

从仓库根目录运行；探针仅接受新的输出文件，不覆盖已有产物。
返回码 2 表示真实测量超过 0.02，返回码 1 表示调用或文件错误。

```bash
OUT=$(mktemp -d /tmp/rawlab-ai-bake.XXXXXX)
c++ -std=c++17 -O2 -Ilutools/include -Ilutools/src/core \
  experiments/ai-color-match/bake_gate_probe.cpp \
  lutools/src/core/color_converter.cpp lutools/src/core/lut_parser.cpp \
  lutools/src/core/lut_applicator.cpp -o "$OUT/native-bake-probe"
"$OUT/native-bake-probe" 65 "$OUT/native-neutral-65.cube"
"$OUT/native-bake-probe" 129 "$OUT/native-neutral-129.cube"
```

Python 对照使用已有环境，不安装新依赖：

```bash
OUT=$(mktemp -d /tmp/rawlab-ai-python.XXXXXX)
lutools/.venv-lutprep/bin/python -m lutools.lutprep prepare \
  lutools/examples/lut-contracts/identity.cube "$OUT/neutral-65.cube" \
  --contract lutools/examples/lut-contracts/srgb-creative.json --size 65
lutools/.venv-lutprep/bin/python -m lutools.lutprep prepare \
  lutools/examples/lut-contracts/identity.cube "$OUT/neutral-129.cube" \
  --contract lutools/examples/lut-contracts/srgb-creative.json --size 129
```

准备器因为门槛失败不会安装输出；原生诊断探针保留失败 CUBE 以供检查，
这些是临时诊断产物，不是可发布的 AI 外观。

## 建议修订，尚未批准或实现

保持 AI 返回颜色配方和本地生成 CUBE 的产品方案，但将 AI CUBE 改为明确声明的
display-sRGB -> display-sRGB 创意变换。运行时先精确计算既有中性显影，再查 AI CUBE；
不把中性显影自身烘焙进粗 Log 网格。导出和分享使用这一相同 CUBE，避免另造一个有损的 Log 版本。

这需要为新类型增加核心加载、CPU / Metal 执行和明确的输入声明；旧 F-Log/F-Gamut CUBE
保持原路径。其他 GPU 必须在新类型未实现时显式拒绝 Force，并在 Auto 采用正确 CPU 路径，
不能把新 CUBE 当旧类型执行。它改变了已批准的“不新增渲染路径”和导出输入约定，需用户确认。

该修订仅消除了已确认的中性显影烘焙误差来源，不证明所有 AI 配方都能通过误差门槛；
配方生成的显示域 CUBE 仍需原生重读、相同门槛和真实图像验证。
