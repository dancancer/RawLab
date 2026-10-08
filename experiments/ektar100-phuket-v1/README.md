# EKTAR 100 Phuket v1

独立的扫描外观参考 LUT，第一版供看图评估。没有修改原始照片。初版制作时未接入应用；后续已按用户要求移除 RawLab 的胶片输出名称白名单。

## 文件与使用

- `EKTAR_100_Phuket_v1_FLog2_FGamut_65.cube`：65 x 65 x 65，共 274625 个 RGB 采样点，标准 R-fast 顺序。
- **输入**：原始 F-Gamut / F-Log2，D65，full range，DOMAIN 0..1。不是 F-Gamut C，也不是 sRGB JPEG 输入。
- **输出**：BT.709/sRGB 原色、sRGB 编码、D65。不是 Gamma 2.4 视频输出。
- 白平衡、曝光在 LUT 前完成；不要先做一次显示色调映射，再应用本 LUT；也不要在本 LUT 后重复做 Log-to-display 转换。
- 这是供数码照片使用的外观变换，不应直接套到已经扫描完成的 EKTAR TIFF 上。
- 更新后的 RawLab PHOTO API 接受 `EKTAR 100 Phuket`，不再要求它属于内置胶片名称白名单；仍要求正确的 F-Log2 / F-Gamut 输入声明和 BT.709 输出色域。本 LUT 保留真实名称，没有伪装成 PROVIA。初版对比图通过通用 C++ LUTApplicator 渲染。

## 查看结果

扫描参考、照片对比和诊断图是本地生成物，不随代码提交；下方图片链接需要先运行文末的重现命令。交付的 CUBE 已移出原目录，仓库保留生成脚本，运行测试前需先生成 CUBE。

各对比图从左到右：**Neutral / PROVIA / Velvia / EKTAR-v1**。曝光和白平衡保持一致，没有为某一风格单独调亮。

- [街景、天空、植被](comparisons/comparison-sheet-1.jpg)
- [人物、深蓝天空、傍晚](comparisons/comparison-sheet-2.jpg)
- [肤色、建筑、山体](comparisons/comparison-sheet-3.jpg)
- [DJI 山谷与高反差](comparisons/comparison-sheet-4.jpg)
- [灰阶曲线与渐变](curves-and-gradients.png)

`comparisons/` 同时保留每个 RAW 的 1400 像素长边单张结果，便于放大比较。它们是完整去马赛克之后在线性空间缩小的审片图，不是全分辨率成片。

## 参考素材与取舍

用户确认 `/Volumes/share/gen8/pics/films/普吉` 的 84 张 TIFF 都为 EKTAR 100 扫描直出。实际读取确认全部为 16-bit RGB、Adobe RGB (1998)。每张先在 16-bit 数值上取样，再用 LittleCMS 浮点 ICC 转换到 sRGB；没有把 Adobe RGB 数值直接当 sRGB。缩略图保留 TIFF 中已有的像素方向，部分原片本身倒置。

全批次的 [元数据与描述性统计](reference/scan-analysis.json) 和四张缩略总览保留在 `reference/`。预览使用相对色度转换，超出 sRGB 的颜色会在显示时裁切；报告记录了转换后的越界比例。个别照片约 30% 的取样像素至少有一通道越界，因此没有把 sRGB 预览的边界颜色当成精确色度目标。

视觉选择覆盖以下内容，而不是由海水、天空的像素数量决定整体映射：

| 内容 | 代表照片 | 第一版取舍 |
| --- | --- | --- |
| 蓝天、青蓝海水 | 1、8、14、18、23、49、81 | 蓝色轻微向青移动，适度加强彩度；不全局加青 |
| 日照和树荫植被 | 3、4、6、16、39、45、69 | 稍浓的绿色与暗部，避免荧光绿；保留阴影层次 |
| 日照和阴影肤色 | 2、7、8、12、19、24、46、77 | 橙黄肤色区不跟随蓝绿同幅增饱和；不把阴影偏色硬编码成全局白平衡 |
| 白墙、沙滩、红黄物体 | 9、25、28、38、47、56、82 | 维持近中性灰白和连续高光，不增加统一暖色滤镜 |
| 室内、傍晚、高反差 | 29、31、33、37、43、50、53 | 不强行匹配每张曝光，不复制局部遮挡、暗角或扫描边缘 |

这一版是**看过扫描后人工设定参数的解析模型**，不是从 84 张照片训练得到的模型，也不是有配对输入的回归拟合。统计仅用于审查参考集，不直接决定参数。

富士 PROVIA、Velvia 的本地 65-grid LUT 用于灰阶曲线与数码 RAW 对照；本文件没有混入或复制其表格采样值。新模型独立完成 F-Log2 解码、F-Gamut 到线性 sRGB 变换、柔和的色域处理、对比曲线、Oklab 分色相调整与显示编码。参数全部可在 `color_lut.py` 的 `PARAMETERS` 中查看。

没有配对数码/胶片照片或色卡，无法区分胶片、扫描器、扫描软件和现场光线各自的影响。不能将这一版本称为 EKTAR 100 的实测物理还原。LUT 也不包含颗粒、光晕、锐化、局部对比或动态白平衡。

## LUT 初版验证结果

- 84 张 TIFF 全部读取及 ICC 转换完成，并查看了全部缩略总览。
- 8 项针对性自动测试通过：F-Log2 数值锚点、超白值、近中性与连续色阶、R-fast/插值、65-grid 误差、不完整 CUBE 拒绝、浮点 ICC 保持低于 8-bit 的色差，以及实际交付 CUBE 的尺寸、范围与生成器一致性。
- 10 个独立 RAW：9 个 Sony ARW、1 个 DJI DNG；不是胶片照片的同场景配对。
- 使用现有 RAWProcessor 的相机白平衡、完整去马赛克和高光处理；Sony scene baseline 为 +0.7 EV，DJI 为 +1.05 EV，用户额外曝光均为 0。
- 三种 LUT 在实际 RAW 上的 C++ 与 Python 插值抽样最大差异为约 `2.38e-7`，输出均为有限数值。新 LUT 的 10 张输出没有通道到达或超出 0/1 端点。
- 12000 个合成摄影颜色的直接解析结果与 65-grid 三线性插值相比，通道绝对误差 p99 为 `0.00865` 以下，最大约 `0.02305`。这是离散采样误差，不是对胶片的色差指标。
- 灰阶检测范围为相对 18% 灰的 -7..+7 EV。最小单通道步进约 `-8.05e-7`，通过 `1e-6` 数值容差；近黑处不是严格数学单调。最大 RGB 通道差约 `0.00239`，小于一个 8-bit 码值。
- 已查看全部 10 个 RAW 的四列对比及灰阶/色相渐变图。未运行应用构建或应用接入测试，因为本轮没有修改应用或核心。

详细数值见 [validation.json](validation.json)。原有照片和工作区中与本任务无关的改动保持不动。

## 重现

以下命令从仓库根目录运行。分析脚本的依赖由 uv 放在独立缓存，不修改项目 Python 环境。ICC 转换使用本机 `/opt/homebrew/lib/liblcms2.dylib`；字体使用 macOS Helvetica。

```bash
uv run --no-project experiments/ektar100-phuket-v1/analyze_scans.py \
  '/Volumes/share/gen8/pics/films/普吉' \
  experiments/ektar100-phuket-v1/reference

lutools/.venv/bin/python experiments/ektar100-phuket-v1/color_lut.py

/usr/bin/c++ -std=c++17 -O3 -DNDEBUG -arch arm64 -mmacosx-version-min=26.0 \
  -Ilutools/include experiments/ektar100-phuket-v1/raw_probe.cpp \
  lutools/build-macos/libsony2fuji_core.a \
  /opt/homebrew/Cellar/libraw/0.21.5/lib/libraw.dylib \
  -lz -framework Metal -framework Foundation -o /tmp/rawtools-ektar-probe

lutools/.venv/bin/python experiments/ektar100-phuket-v1/render_comparisons.py
lutools/.venv/bin/python experiments/ektar100-phuket-v1/make_diagnostics.py

uv run --no-project --python lutools/.venv/bin/python \
  --with numpy==2.4.1 --with pillow==12.1.0 \
  --with tifffile==2026.3.3 --with imagecodecs \
  python -m unittest discover -s experiments/ektar100-phuket-v1 -p 'test_*.py'
```

RAW 浮点中间文件缓存到本目录的 `.cache/`。更换源 RAW、核心二进制或显影设置后，应清除对应的缓存再生成对比。LUT 渲染本身每次重新执行，不复用旧结果。

## 来源

- 本仓库的 [色彩约定](../../lutools/docs/color-contract.md) 和 `color_converter.cpp`：工作空间矩阵及 F-Log2 数值约定。
- [Fujifilm 官方 LUT 页面](https://www.fujifilm-x.com/global/support/download/lut/)：参考 LUT 来源背景；本地文件用于比较，不等同于已确认其开源许可。
- [Bjorn Ottosson 的 Oklab 原始说明](https://bottosson.github.io/posts/oklab/)：采用作者公开为 public domain 的线性 sRGB / Oklab 转换公式。
