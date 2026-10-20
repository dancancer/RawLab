# 降噪质量基准

此工具测量现有小波降噪，不自动判定“画质通过”。真实 RAW 不入库；原始文件放在主工作区
`.cache/shared/`，本次运行输出放在主工作区 `.cache/tmp/<task>/`。每次输出目录必须是新目录。
执行基准不会下载素材、修改 RAW、调用 Lightroom 或修改其目录。

## 构建与运行

沿用项目的依赖和 CMake 构建配置，启用 `BUILD_TESTING` 和
`SONY2FUJI_ENABLE_WAVELET_DENOISE`。在已有构建中运行：

```sh
cmake --build lutools/build-macos --target denoise_quality_probe denoise_quality_metrics_tests
ctest --test-dir lutools/build-macos -R 'denoise_quality|wavelet_diagnostics' --output-on-failure
python3 lutools/tests/run_denoise_quality.py \
  --manifest lutools/tests/fixtures/denoise-synthetic.json \
  --assets /absolute/path/to/main-workspace/.cache/shared/raw \
  --probe lutools/build-macos/bin/denoise_quality_probe \
  --output /absolute/path/to/main-workspace/.cache/tmp/task/baseline \
  --presets off detail clean --backend cpu --repeat 3 --cache-check --crops
```

Python 需要 3.9 或更新版本。`--backend` 支持 `cpu`、`auto`、`force`；后两项保留核心的
Auto 回退和 Force 失败语义。请求 GPU 不代表实际使用 GPU，查看 `diagnostics.applied`、
`gpu_filter_used` 和 `build.gpu_backend`。跳过降噪时不会声称 GPU 已执行。
`--only` 可选择 case，但整个清单会先检查调参／验收集泄漏。

`detail` 为 `enabled=true,luma=0,chroma=46,coarse=50`；`clean` 为 `10,72,100`。
`off` 关闭降噪。重复运行分别启动新进程；`--cache-check` 在同一进程中用相同输入与参数
再滤波一次，单独记录分析缓存命中时间，并检查输出指纹一致。它不模拟客户端参数拖动或结果缓存。

`--bayer-demosaic vng|dht` 默认 `vng`，与共享核心一致；`dht` 用于显式选择备选算法。
该选项对输入 RAW 和参考 RAW 同时生效，不改变 FBDD。非 Bayer 保持 LibRaw 原有路径，
合成 RGB 不经过插值。`bayer_demosaic_requested` 记录请求，`pipeline.demosaic` 和
`pipeline.reference_demosaic` 分别记录所选路径；非 Bayer 为 `libraw_default`，无插值时
为 `not_applicable`。旧基准未记录此选项时，须核对其二进制/源码来源，不假定它采用 VNG。

## 输入与划分

清单 `version=1`，每个 case 必须包含唯一 `id`、`split`（`tune`／`holdout`）、
`capture_group`、`input` 和 `regions`。同一拍摄组、RAW 或参考图的 SHA-256，以及完全相同的
合成输入都不能跨越两个集合。不同裁剪、重命名文件、同次拍摄的不同曝光应共用拍摄组。
这些检查不能自动识别重编码副本或错误的拍摄组声明，维护者仍须核实来源。

同一测试卡／场景被不同机型或不同拍摄组重复拍摄时，设置相同的 `content_group`。
此字段也禁止跨集合；未提供时使用 `capture_group`，兼容已有清单。不同机型不等于不同场景。
本地 RAW 清单中的 DPReview studio 样片全部属于同一内容组，统一用于诊断／调参；独立
Sony 实拍和 DJI 样片只补充未配对场景覆盖，不是干净参考。合成图的不同随机种子只是
噪声重复实验，也不能代替真实场景泛化验证。

- RAW：`input.kind=raw`，`path` 为素材根目录内的相对路径，`sha256` 为完整文件校验值。
  每次运行重新校验；缺失、损坏、校验失败、超时和探针失败均返回非零退出码，不算通过。
- 合成图：指定 `pattern,seed,width,height,shot,read`。真值生成后，在显影后线性 RGB 中注入
  独立 Poisson 散粒噪声和 Gaussian 读出噪声，方差为 `shot*max(signal,0)+read^2`。
  `shot/read` 范围为 `[0,0.1]`，正的 `shot` 不得小于 `1e-8`，避免 Poisson 计数溢出。
  不是 CFA 噪声，不模拟去马赛克相关性，不是相机标定。随机分布跨标准库版本不保证逐像素一致，
  因此同时记录输入指纹、编译器、平台和探针 SHA-256。
- 参考 RAW：可选 `reference.path,sha256,registered=true,exposure_matched=true`。声明针对
  本工具解码后的 RGB；不自动估计配准或曝光。未提供变换时尺寸不一致会失败。
  可选 `reference.registration` 应包含 `input_to_reference_affine`（2×3，完整分辨率像素
  坐标）、`reference_to_input_gain`、`estimated_from="input_and_reference"`、
  `candidate_output_used=false` 和 `method`。探针用 OpenCV 双线性仿射采样参考图，再将
  参考图乘以该增益；输入和降噪输出不被配准或归一化。超出参考边界的测量区域报错，
  不使用外推像素计算误差。变换须在查看候选输出前由输入／参考确定，并保留估计来源、
  局部配准误差与白平衡差异。此类参考仍称为“声明配准的低噪声参考”，不称无噪声真值；
  插值也可能改变其细节。
- 区域：`id,kind,rect=[x,y,width,height]`，坐标归一化到完整解码图像。区域仅用于测量和输出
  裁剪；噪声估计与滤波始终处理全幅。真实清单的固定中心、边缘、角落初始为未分类区域，
  不应未经目检就标成平坦背景、细织物或文字。

`denoise-raw-local.json` 是已有本地缓存的校验索引，不是下载或分发许可清单；来源和许可尚未
完整恢复，不能据此重新分发素材。CFA 是素材清单声明，camera/ISO 来自实际 RAW 元数据。
Lightroom、DxO 的成片只能作为竞品参考；没有配对输出和明确设置时，不进行定量归因。

`denoise-dark-local.json` 索引用户提供的 A7C II 全遮光 RAW：ISO100／12800 各四张、1/13 秒。
它们是相机噪声控制样本，不是独立自然场景，也不将显影后的黑场当作全零 RGB 真值。
原图不入库；这类控制帧不能替代受光平场的信号相关噪声检查或自然纹理画质验收。

`denoise-holdout-local.json` 的素材根目录是主工作区 `.cache/shared`，记录独立场景、
来源、许可和固定区域。它们没有配对真值；holdout 身份仅相对于选片前冻结的候选。
以后根据其输出调参，就应按回归样片管理，不能继续称为未参与调参的验收集。

## 测量边界

RAW 固定为全分辨率线性 sRGB、相机白平衡、传感器基准曝光；关闭嵌入 JPEG 曝光匹配、
BaselineExposure、FBDD、镜头校正、LUT 和锐化。不裁切负值或超白值，不在 ROI 内单独拟合。
这覆盖算法层，不代替镜头校正／LUT／锐化／缩放／导出的成片层验证。

RAW 的 `off` 仍包含白平衡和去马赛克，不是未经插值的传感器样本。跨显影器对比中，
即使双方都关闭降噪，去马赛克、相机配置和色调处理也可能不同。应先比较同一解码器下
的 `off`／`on`；若 `off` 已有方向性彩色纹理，需在固定 CFA、白平衡和曝光后单独检查
去马赛克，不能把全部差异归因于小波阈值或通过提高强度掩盖。

`results.json` 记录完整清单、输入 SHA-256、探针 SHA-256、运行时工作区 HEAD/dirty 状态、
构建信息、参数、全幅浮点指纹、每区测量、解码／滤波耗时及进程峰值 RSS。运行时工作区状态
不等于二进制来源证明；对比旧二进制时应保留对应构建日志和变更记录。
runner 校验报告回写的请求摘要、case/split、参数、尺寸、执行后端、区域和有限数值指标；
不完整或属于其他请求的报告会返回 `REPORT_ERROR`，不会标为测量完成。
浮点指纹为非加密 FNV-1a，适合同平台回归定位，不作为资产完整性校验。
峰值 RSS 包括解码和测量，不等于单独滤波内存；不支持该统计的平台返回 `null`。

- 无参考：报告 RGB 均值的标准差、`R-G/B-G` 变化、输出相对输入的改变量。图像结构也参与
  这些值，不能将方差降低直接解释为降噪收益。
- 有参考：补充 RGB、RGB 均值、`R-G/B-G` 误差 RMSE、通道均值偏差和亮度对比投影增益。
  这里“亮度”固定为 `(R+G+B)/3`，不是 Rec.709 光度亮度；恒定参考的投影增益为 `null`。
  不为无界 HDR 线性数据虚构 PSNR 峰值。
- `luma_laplacian_gain` 使用区域内部像素的四邻域归一化 Laplacian 投影，另外输出
  `reference_laplacian_rms`，用于检查细尺度参考能量。区域小于 3×3 时两项为 `null`，
  参考能量不足时增益为 `null`。这不是细节质量分数：噪声、亮度增益和参考插值都会影响
  它，只能结合明确的结构区域、均值偏差和视觉检查解释，不能据平坦区域的投影排名。
- `--crops` 输出区域中心最多 512×512 的 100% PNG。统一 `view_ev` 后按 sRGB 编码，
  仅显示裁剪会限制到 `[0,1]`；记录实际像素区域和变换，指标仍使用未裁切的线性浮点数据。

结果始终标记 `quality_verdict=NOT_EVALUATED`。质量门槛、视觉缺陷和性能预算需要在明确的
保留验收集上单独评估；脚本退出 0 只表示所选测量均完成，不代表算法有提升。
正式验收分别记录画质、当前版本保存／重开、精确预览／导出、性能和旧处理版本兼容。
跨端允许采用不同算法与资源档位，不要求不同算法逐像素相同；同一版本的缓存与导出
语义仍须稳定。旧记录兼容见 [处理版本约定](processing-version.md)，不能由当前版本
保存／重开通过来替代。

## 内部诊断

`WaveletDenoiseDiagnostics` 不进入公共 C ABI、配方或预设。`outcome` 区分关闭、零强度、
参数／图像无效、不支持的构建、过小、低噪声、样本不足、已执行和 GPU／处理失败。

候选块先按尺寸不足、结构明显、噪声过低、周期结构检查，拒绝计数互斥归类。
通过数量与各拒绝数量之和等于候选数量；不会为了统计而额外对已拒绝块运行频谱检查。
仅所有候选块都因噪声过低被拒绝时使用 `low_noise`，混合原因归为 `insufficient_samples`。
有效样本少于 8 时仍保守跳过。

首轮通过至少 8 块时，用这些块的稳健模型再检查一次梯度：局部结构门的 sigma 不得超过
模型预测 sigma 的 4 倍，仍保留原来的 0.35 梯度比例和 `2e-5` 绝对下限。该宽限用于避免
图案靠自身抬高的 MAD 放宽结构门，不是置信区间。截距命中 `1e-12` 约束下限的通道不收紧。
额外拒绝仍计入结构类；不改变候选块的方差测量值，不重新筛选已拒绝块，也不循环重拟合。
后续模型只由最终接受块拟合，最终不足 8 块时仍不执行降噪。这不能识别所有随机状纹理，
尤其不能声称整幅图案占多数时已有独立噪声参考。

样本均值范围来自原始样本，各通道分别记录，允许负值／超白值。拟合仍使用非负信号均值。
`relative_fit_rmse` 为样本方差预测 RMSE 除以 `max(样本方差中位数, 1e-12)`，不是置信概率
或已校准误差上界。
同时记录 `sample_variance_median` 和未归一化的 `fit_rmse`，避免只看比值而无法判断量级。
`relative_fit_median_abs_residual` 为绝对残差中位数除以相同的 `max(中位数, 1e-12)`；
`fit_top_decile_error_fraction` 是残差最大的 `ceil(n/10)` 个样本占总平方误差的比例，
所有残差为零时为零。这些字段描述异常值集中程度，不剔除样本、不重新拟合，也不是自动
画质门禁。绝对 RMSE 的单位是线性 RGB 的方差，不是像素 RGB 的 RMSE。
这里的样本方差实际是显影后 `patch - GaussianBlur(sigma=3)` 残差的高斯等效 MAD 尺度平方，
不是传感器 ADU 的方差，也不保证等于残差的完整二阶矩。近黑裁切、去马赛克相关性和异常值
会改变两者关系；暗帧差分可用于核验，但不能用一个倍率直接校正所有亮度、ISO 和机型。
`constant_variance_fallback` 只表示原有的均值跨度不足 0.01 分支，不涵盖约束解恰好得到零斜率。
无模型时拟合字段为 `null`。缓存命中复用同一估计诊断；每次入口清空上次的执行结果。

实际滤波使用归一化、对手色转换之后重新测得的小波 band MAD，而不是直接将上述样本方差
作为阈值。常方差模型中，三个通道的 `b` 共同缩放会在归一化、band 校准和恢复之间近似抵消；
仅把 `b` 乘以暗帧方差比的倒数，不是可靠的强度修正。重尾噪声中的 MAD 和完整方差即使
不同，也需要结合实际残差、均值偏置和纹理保留判断，不能只追求二者的比值变为 1。

`wavelet_noise_model` 覆盖手算残差、少数高方差污染下的稳健拟合、宽带图案误收、相关／
异方差噪声、常方差缩放等变性，以及未裁切／裁切／重尾近黑噪声的均值与纹理回归。
相关性指标仅供离线诊断；线性混合后的随机噪声同样可以有很高的 RGB 相关性，去马赛克
也会引入空间相关。不能将相关性直接当作结构拒绝阈值，或把测试用合成噪声视作相机标定。
