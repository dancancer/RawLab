# X3F 保存设置与 SPP 对照

目标是复现 SIGMA Photo Pro 的 **RAW/X3F 模式**：使用文件中保存的白平衡和调整值。
拍摄时的 `PROP/WB_DESC` 只作为来源信息，不能覆盖后来保存的 header white balance。
SPP Auto、参数归零和相机内嵌 JPEG 是辅助对照，不是验收目标。

当前目录是校准实验，不改变产品默认显影。候选在留出图片上达到颜色目标之前，
不能把“能够解码”或“植被恢复绿色”当作正常显影已经完成。

## 路径与兼容

- 正常模式需要消费 X3F CAMF 校准及保存设置；明确区分 sensor/scene 数据与 SPP 显示渲染。
  不把 SPP 显示图再次作为线性 RAW 输入套用现有中性显示曲线。
- 现有 LibRaw X3F 路径作为独立旧模式保留。旧编辑缺少模式字段时仍采用旧路径。
  新模式不能覆盖旧模式的白平衡、曝光或缓存；导出、预览、批量快照保存相同模式身份。
- 当前浮点候选是 `sagwaco/x3fuse-core` 的固定提交
  `00f9ef206a2d629bca35ceead4b3951833b85d3d`。它能读取 DP1 CAMF 矩阵，
  但不应用 HeaderExt 调整；其 scene 接口还缺少可选白平衡、经典 X3F header 方向回退
  和浮点输出 C ABI。不能直接等同于 SPP。

## 实验步骤

1. 用 SPP RAW 模式、原尺寸、sRGB ICC、16-bit TIFF 生成参考；关闭保存设置到源 RAW。
2. 记录每张 RAW 和参考 TIFF 的校验值、header 保存参数、软件与解码器版本。
   原始文件和参考图只放外部样片目录，不提交到 Git。
3. 在拟合前按场景组固定训练/留出划分，近似连拍不得跨组；留出图片不参与参数选择。
4. 先比较未拟合的 CAMF 浮点候选，再逐项验证保存曝光、颜色调整、Fill Light 和高光处理。
   不用逐图自由曝光、逐图白平衡或参考图像作为运行时输入掩盖差异。
5. 报告逐图及合计误差，并保留错误像素区域的可视化。训练误差不能代替留出误差。
6. 正常路径经过画质验收后再接入产品和双模式控件；现有模式须有像素兼容回归。

## 保存参数解析

`saved_settings.py` 只读取经典 X3F 2.1/2.2 扩展文件头。其布局来自 Foveon 的
[公开 FOVb 规范](https://libopenraw.freedesktop.org/formats/x3f/x3f-raw-format.pdf)。
未经编辑的 RGB 调整槽位可能全为零，渲染含义为无颜色调整；不能把整张图乘成黑色。
不支持的文件头或非有限调整值明确拒绝。

从仓库根目录验证：

```sh
python3 -m unittest discover -s experiments/x3f-spp-v1 -p 'test_*.py'
```

NumPy/Pillow 用于图像对照，读取原始 16-bit TIFF 时使用 tifffile；不以 Pillow 的 RGB8
转换结果代替高精度测量。运行结果、拟合参数、缩略图、完整 RAW/TIFF 均在仓库外或
主工作区 `.cache/` 中保存。

## 可复跑工具

把 `decode_scene.rs` 复制到上述固定版本 `x3f-core` 的 `examples/` 目录，使用保留的
`Cargo.lock` 构建：`cargo build --release --locked -p x3f-core --example decode_scene`。
第三方源码副本及 `CARGO_TARGET_DIR` 都放任务临时目录，依赖下载沿用共享缓存。

以下变量由运行者指定：`DATA` 是带 `manifest.json` 的外部样片目录；`WORK` 是临时输出目录；
`DECODER` 是构建出的 `decode_scene`。manifest 记录源 RAW/参考 TIFF 的 SHA-256、参考路径、
内嵌预览路径、场景组和 `train`/`validation` 划分。

```sh
# BLOCK_SIZE、DENOISE(0..10)、RECOVERY(0/1)、输出目录、输入文件
"$DECODER" 8 0 0 "$DATA/scene-linear" "$DATA/inputs/"*.X3F
python3 compare_corpus.py --data "$DATA" --output "$WORK/fit"

# 系数冻结后，独立生成全分辨率数据；此处使用现有传感器色度 NLM。
"$DECODER" 1 10 0 "$WORK/full-scene" "$DATA/inputs/"*.X3F
python3 evaluate_frozen.py --data "$DATA" --scene "$WORK/full-scene" \
  --model "$WORK/fit/frozen-model.json" --output "$WORK/full-evaluation"

# 实际渲染只需要原始照片、解码器和固定模型，不需要 SPP 参考图。
python3 render_image.py --decoder "$DECODER" --model "$WORK/fit/frozen-model.json" \
  --denoise 10 INPUT.X3F OUTPUT.tif
```

Python 命令在本目录运行。`render_image.py` 拒绝覆盖已有文件，输出带 sRGB ICC 的
16-bit TIFF。所有渲染入口写入 180 DPI/inch，与本实验 SPP 原尺寸导出一致；
DP1S 的原生画幅为 2640×1760（464.64 万像素），保存方向可交换宽高，不做空间放大。
DPI 只描述物理显示或打印尺寸，不能改变像素数；省略该值会被 macOS 读成 1 DPI，
导致按物理尺寸显示时的比例异常。其像素已经包含实验显示响应，不能当作 scene-linear 数据再次套用
RawLab 中性显示曲线。`--highlight-recovery` 控制解码器的传感器高光重建，
它不等于显示端高光压缩。临时解码数据由渲染脚本自动清理。

## 方法边界

- `compare_corpus.py` 中的 baseline 是 CAMF 候选加 RawLab 中性显示曲线的离线模拟，
  不是产品现有 LibRaw 伪红外模式。不要用这里的 baseline 指标声称旧模式的实测画质。
- 模型是经验响应近似，Fill Light/Highlight 是拟合上下文，尚不是已知 SPP 算法。
  非零 Contrast、Shadow、Saturation、Sharpness 会明确拒绝；缺少覆盖的数据不能算支持。
- 训练/选择仅使用训练组，但 CV 和汇总按图片等权，连拍较多的组权重也更高。
  场景组数比照片张数更能反映独立样本数量。`SDIM0019` 属于训练集。
- CIE76 和显示 RGB MAE 计算于限制到 `[0,1]` 后的最终显示值；同时报告未限制 RGB MAE、
  上下溢出通道比例。原始模型越界不自动等于可见缺陷，仍需检查错误纯白和暗部截断。
- 参考图要求本轮经核验的 SPP sRGB ICC。`load_samples()` 校验 RAW/TIFF 校验值，
  以及 scene 对应的输入路径、保存 WB 和解码开关；不得混用不同解码设置的缓存。
- 8× 缩小的响应拟合不能证明细节、锐化和噪声匹配。全尺寸核验先渲染全部像素，
  再单独报告原尺寸误差及渲染后缩小的误差。
- 查看留出组结果后选择的降噪或其他处理，只能算诊断改进；这批图片不能再次视为
  从未查看过的独立验收集。外部场景、新 ISO、其他保存参数和其他 X3F 机型仍需新验证。

具体实验数值、截图、冻结模型和机型样片索引保存在任务证据目录，不作为产品配置入库。

## Classic Retinex 原生算法对照

`classic_retinex.py` 独立重实现 SPP 6.9 Classic 的局部对数增益处理：原生亮度计数、
对数查表、两次整数金字塔滤波、局部方差、增益图及 Q8 增益查表。
采用该版本的整数取整、奇偶尺寸边界、轮转工作行和层间均值归一化规则。
实现只依赖 NumPy 和标准库，不加载 Sigma 私有库。

`retinex_log_map(native_rgb)` 的输入是 **SPP Classic 前置校准之后的原生线性 RGB 计数**；
不能把 `prepare_scene_linear()` 的归一化 RGB 或最终 sRGB 图直接传入。
目前尚未建立两个管线之间可靠的数值转换，因而本模块没有自动接入现有 `render_v2.py`、
`render_highlights.py` 或 RawLab 产品显影。DP1S 的绿色偏差和完整 RAW 画质仍需分别验收。

`gain_from_log_map(log_map, amount)` 返回按原生 Q8 量化的 RGB 共用乘数。
原生调用顺序是在色调曲线之前应用该乘数；现有 v2 的显示域 Fill Light 仍属于历史近似。
实验入口限制 `amount` 为 `[-2,2]`，不据此宣称完整保存参数范围已获支持。
非零控制下的 `-32768` 索引在原生表中没有初始化，入口会明确拒绝。
金字塔只接受非负 int16、两边至少 3 像素、长边大于 64 的输入。

`fixtures/classic-retinex-native.npz` 保存合成输入及固定 SHA 的 arm64 原生函数输出；
对应 JSON 记录来源和边界。它不是照片素材，也不含 Sigma 库。
普通回归无需安装 SPP：

```sh
python3 -m unittest discover -s experiments/x3f-spp-v1 -p 'test_classic_retinex.py'
```

原生 `SmoothDoubleBlend` 的独立输入尾行可能受其后工作内存影响；重实现把
`PyramidFilter` 的工作行布局显式建模为自有数组，避免读取数组外内存。
因此独立 helper 的对照需要相同工作区条件，不能用任意裸数组声称逐字节兼容。
内核对照不代表完整相机校准、SPP 保存参数、其它 X3 代际或其他平台已经验证。

## Classic ColorDQ 与矩阵前置处理

`classic_color_dq.py` 重实现 Classic `GetTanhLUT` 和 `ColorMatrixTransformRowWithX3Copy`
的两次整数扣减、定点矩阵乘加、溢出语义和输出限幅。
Classic 第二次扣减作用于第一次的结果，与依赖库 Merrill 浮点处理的计算方式不同；
不能因为 LUT 公式相同就混用两代像素处理。

`make_color_dq_luts(strengths)` 需要显式的三个非负强度，第二组原生参数固定为
`[0.8,0.8,0.8]`，返回长度为 512／1024／2048／4096／8192 的三个 signed16 表。
`transform_counts(pixels, tables, fixed_matrix, shift, black_offset, bounds)` 只接受 signed16
原生计数和明确给定的整数矩阵／小数位数，返回 `(矩阵后计数, 矩阵前副本)`。
默认输出范围 `[-500,24000]` 来自原生行函数的限幅，**不是场景白点或归一化系数**。
矩阵后的输出转成 float32 后才是本轮核验的 Retinex 输入边界。

原生 Retinex 亮度计算包含融合乘加（FMA）。普通浮点点积在整数边界可能选错对数表索引；
实现固定原生运算顺序，并只对可能改变索引的边界使用标准库 Decimal 保留最终一次舍入。
相关跨阶段回归来自原生矩阵输出和原生 Retinex 输出，不使用自身实现生成期望值。

`fixtures/classic-color-dq-native.npz` 记录合成计数、零强度、全部表长、偏移、非单位矩阵、
signed32 溢出和自定义限幅的原生结果；测试校验来源库及 fixture 校验值。
这些参数只是内核测试输入，不是 DP1S 或其他机型的正式配置。

目前没有自动从 CAMF／保存设置生成完整校准输入。真实强度还受白平衡、增益、ISO、
机型分支及跳过标志影响，矩阵前的黑电平／漂移／空间处理也尚未重建。
不能把 RAW 感光层、归一化 scene 或最终显示 RGB 直接当作该阶段的输入。
本模块没有替换产品显影，也未替换既有离线 TIFF 输出。

## 原生分代路径对照

长期目标覆盖 Classic、Merrill 和 Quattro。各代算法、机身 CAMF 和保存参数分别核验；
DP1S 的拟合颜色表和实测高光阈值不能用于其他机身。能够解码、能够执行指定路径、
与 SPP 画质接近是不同的验收项。

`decode_family.rs` / `render_family.py` 提供独立的原生路径对照入口，不使用 DP1S 模型，
也不修改产品默认显影。仍固定使用前述 `x3fuse-core` revision：

| `--pipeline` | 行为与范围 |
| --- | --- |
| `native` | 解码器默认颜色路径，固定 sRGB、CPU、降噪强度 10；用于比较基线。 |
| `as-shot` | 在默认路径上请求文件记录的相机色彩模式；不是完整保存调整重放。 |
| `merrill-spp` | 明确启用 Merrill 专门浮点显影、降噪和输出路径，并请求 AsShot 色彩模式。 |

`merrill-spp` 的原生限制仍有效：只接受支持的 Merrill HI、颜色输出和相应校准，
不支持 Classic、Quattro、MED/LOW、黑白或强制 GPU。请求失败直接报错，不自动退回
普通路径。该路径使用中间档噪声滑块、Sharpness/Fill Light/Saturation=0、
Highlight Control=1；**不会自动应用文件保存的全部曝光、色调、颜色轮和其它用户调整**。
AsShot 沿用依赖库的解析策略，缺失或未知模式可能回退 Standard 并输出警告，
因此证据文件保留完整原生 stdout/stderr；这类结果不能当作保存模式已正确重放。

使用独立探针 crate，将 `decode_family.rs` 原样复制为其 `src/main.rs`，通过 path 依赖
引用固定源码中的 `crates/x3f-core`，并添加 `serde_json = "1"`。固定源码归档本身没有
`Cargo.lock`；首次准备该探针时生成并保留 lockfile，后续使用相同文件进行锁定构建。
`family_contract.py` 检查 Cargo 实际解析的 core/sys 来源、Git revision/干净状态和
探针源码，按当前 host target 执行 `--release --locked --offline` 构建，再记录依赖树、
lockfile、工具链、二进制和 Python 实现校验值。源码或实现变更后重新冻结，不复用旧契约。
共享源码和正式 RAW 不应作为构建或设置写回目标；构建目录按临时文件约定放置。

```sh
python3 family_contract.py --manifest "$PROBE_CRATE/Cargo.toml" --output "$FAMILY_CONTRACT"
python3 render_family.py --decoder "$FAMILY_DECODER" --contract "$FAMILY_CONTRACT" \
  --pipeline merrill-spp INPUT.X3F OUTPUT.tif
python3 render_family.py --decoder "$FAMILY_DECODER" --contract "$FAMILY_CONTRACT" \
  --pipeline as-shot INPUT.X3F OUTPUT.tif
```

输出为显示编码的 16-bit RGB TIFF，保留原生 ICC；只按 TIFF Orientation 重排像素、
归一化为 180 DPI，不缩放或重新套用显影曲线。缺失方向标签按 1 处理，不推测额外的
RAW 方向。配套 `.tif.json` 记录输入/解码器/输出校验值、路径参数、原始 metadata、
警告和适用限制。固定对照会在子进程中清除 `X3F_*` 研究环境开关，避免继承的 EV、
高光或降噪调参改变结果；外层证据记录被忽略的变量名。解码失败时也检查 RAW/二进制
完整性。已有输出或证据文件拒绝覆盖，普通失败清理本次暂存数据。
这两个文件不构成跨文件系统的崩溃事务。

当前分代参考包含 DP2 Merrill 和 dp2 Quattro 各一张 SPP 6.9 原尺寸样片，
只能证明这些样片与指定参数的结果，不能据此宣称整个机型系列已完成画质验收。

可选真实回归通过 `RAWLAB_X3F_FAMILY_DECODER`、`RAWLAB_X3F_FAMILY_CONTRACT`、
`RAWLAB_X3F_MERRILL_RAW`、`RAWLAB_X3F_QUATTRO_RAW` 和
`RAWLAB_X3F_MERRILL_SPP_REFERENCE` 传入固定探针/契约和样片；未配置时明确跳过。
它检查 Merrill 的固定 SPP 参考、错误机型无回退、环境开关隔离以及失败/已有目录保护。

## 扩展日期实验（v2）

v1 文件及其冻结参数保留，用于同一 scene 数据上的对照。v2 仍是离线原型，
没有接入产品或改变旧显影模式。

- `setting_variants.py` 只在内存副本中改写公开 HeaderExt。生成单参数对照时保持白平衡、
  方向和 232 字节之后的全部 RAW/CAMF 数据不变；输出副本与原照片分别校验。
- `bounded_lut.py` / `fit_bounded.py` 使用中性保存设置的开发图拟合有界三线性响应，
  对整个拍摄日期做交叉验证，按日期等权选择网格和平滑强度。输出节点限制在 `[0,1]`，
  这是数值边界约束，不代表颜色已准确或高光色相已完全匹配。
- `saved_controls.py` 的色调曲线来自单参数 SPP 输出；Fill Light 使用独立校准的像素基函数
  和约长边 3% 的局部亮度对比。局部均值在整图上计算，随后分块计算响应，避免块边界改变效果。
- `render_v2.py` 先在未裁剪 scene 数据上应用曝光与校准过的颜色增益响应，再执行基础映射、
  保存色调、饱和度和 Fill Light。这个顺序是经过样片检查的近似实现，不是已知官方处理顺序。
- `evaluate_v2.py` 默认只评估 development；独立日期必须显式传入 `--split holdout`。
  模型应先冻结、记录校验值，随后才读独立日期的图像误差。`--files` 可明确限定原尺寸抽查。
  `scene_cache.py` 同时校验源文件、scene 像素、解码版本、尺寸、WB 和处理设置，
  不以“文件名相同”或“白平衡相同”作为缓存对应的证据。

在本目录中运行：

```sh
python3 render_v2.py --decoder "$DECODER" --model "$CANDIDATE_V2" INPUT.X3F OUTPUT.tif
python3 evaluate_v2.py --data "$DATA" --model "$CANDIDATE_V2" \
  --v1-model "$MODEL_V1" --split development --output "$WORK/development"
# 候选、准备好的训练数组 manifest 和新日期数据集分别传入；冻结文件不会覆盖旧文件。
python3 evaluation_contract.py --candidate "$CANDIDATE_V2" --data "$DATA" \
  --training-manifest "$TRAINING_MANIFEST" --output "$MODEL_V2"
# 仅在参数冻结后执行。不得根据这一步的结果继续选择参数，再称其为独立测试。
python3 evaluate_v2.py --data "$DATA" --model "$MODEL_V2" \
  --v1-model "$MODEL_V1" --split holdout --output "$WORK/holdout"
```

v2 目前拒绝保存白平衡 `Monochrome`、非零 Sharpness、非零未知 HeaderExt，以及超出
已校准区间的色调参数。Contrast/Shadow/Highlight/Saturation 的响应范围为 `[-0.5,0.5]`；
Fill Light 的独立控制样本为 `-0.5/0.3/0.5`，`0.6` 是额外用真实开发照片检查的有限外推。
曝光直接作用于 scene 值；大于已观察范围的曝光和颜色增益不因此获得画质保证。

色彩指标包含输出裁剪、噪声及空间处理差异。报告对比两个版本时必须同时给出可比较的
图片数量；v1 拒绝的新控制不能从结果中悄悄消失，也不能把不同图片集合的均值称作同集改善。
报告中的 `paired` 专门统计两个版本共同可处理的同一批图片。顶层同时记录实际 block，
`1` 才是原尺寸测量，不能把 `8` 的缩小图误差称为原尺寸结果。

`fit_bounded.py --data` 接受的是准备好的中性数组目录，不是原始照片目录。其 manifest 为对象，
`role` 固定为 `neutral-development-v2`，含 `excluded_dates` 和 `samples`；每个 sample 包含
`name/group/path/array_sha256/split`，其中 `split` 必须为 `development`。路径指向含
`scene/reference` 的 NPZ。已查看的旧验证集如需复用，应明确归为历史开发数据，不能继续称作
独立验证。冻结检查会拒绝训练日期与新 holdout 日期相交、参数/源码变化或数据 manifest 变化。

## 原始感光层高光诊断

`sensor_highlights.py` 和 `render_highlights.py` 是独立、显式启用的候选，不改变 v2。
它用三个原始感光层同时接近实测亮部上限的程度，平滑地把 scene RGB 向当前最大通道
对应的中性色靠近，再交给 v2 应用保存曝光、颜色和色调参数。它不恢复已经丢失的纹理，
也不能代替完整的传感器线性化。只达到单层高值的像素保持原样。

外部 profile 必须提供 `camera_model`、`camera_serial`、三个 `ceiling` 原始计数，
以及 `0 < start < end <= 1` 的过渡区间。实测亮部上限不等于厂家标定的物理饱和容量；
当前 profile 只验证过同一台 DP1S，不能自动用于其他机身。渲染会核对机型和序列号。
候选是在查看 v2 留出失败样片后提出的，原有留出照片只能用作这项候选的诊断回归。

在同一固定版本 `x3f-core` 中加入 `decode_scene.rs` 与 `decode_sensor.rs` 并构建：

```sh
cargo build --release --locked -p x3f-core --example decode_scene --example decode_sensor
python3 highlight_contract.py --decoder "$DECODER" --sensor-decoder "$SENSOR_DECODER" \
  --model "$MODEL_V2" --profile "$HIGHLIGHT_PROFILE" --output "$HIGHLIGHT_CONTRACT"
python3 render_highlights.py --decoder "$DECODER" --sensor-decoder "$SENSOR_DECODER" \
  --model "$MODEL_V2" --contract "$HIGHLIGHT_CONTRACT" INPUT.X3F OUTPUT.tif
```

`decode_sensor` 使用原始感光层 TIFF 接口，不需要改动第三方显影代码。两个探针分别读取
同一 RAW，均输出未旋转的有效区域；Python 核对原始文件校验值、处理协议、像素尺寸和
相机身份后，统一应用保存方向。v2 参数与源码必须仍匹配其冻结记录，但实际渲染无需访问
SPP 参考、训练数组或数据清单。输出为带 sRGB ICC 的 16-bit TIFF，并附 `.tif.json` 记录
来源、参数、探针及实验源码校验值。已有输出和证据文件均拒绝覆盖；临时像素自动清理。
独立的高光 contract 同时绑定 profile 内容、v2 模型、新增实现源码及两个探针二进制。
更换平台或重建探针后需要重新生成 contract，并单独验证；不能把新构建视作旧运行的证据。
两份最终输出写完整后才发布；普通写入失败会回滚本次输出，进程被强制终止不具有双文件
事务保证。原始感光层探针要求一个不存在的输出目录，正常失败时清理该目录。

## 原尺寸细节响应诊断

`detail_response.py` 是显式启用的基础亮度细节实验。高光 profile 可选包含
`detail_response: {"schema": "rawlab-luma-detail-v1", "amount": 1.0, "threshold": 0.002}`；
缺少该字段时保持原来的像素路径。它不替代保存设置 `Sharpness` 的实现，
也不能恢复已经丢失的纹理，不能把视觉变锐等同于真实细节恢复。

处理在完整、已按保存方向旋转的最终显示 RGB 上执行。固定三点核 `[0.25, 0.5, 0.25]`
分别沿两轴计算亮度低通，小幅高频经过软阈值后不增强；所有 RGB 通道使用同一个亮度
增量和共同色域限制，避免逐通道裁剪造成新的彩边。支持半径为一个原生像素，不在
缩略图上校准或按分块分别补边。`amount` 范围为 `[0,1]`，`threshold` 为 `[0,0.01]`。

高光 contract 会校验可选参数，并绑定该实现源码。改变 TIFF metadata 或新增实验步骤后
必须生成新的 contract；旧候选及其源文件快照保留，不能改写历史独立验证记录。
画质检查需要同时比较固定坐标的原尺寸纹理、边缘误差、平坦区噪声和亮暗光晕，
不能只以高频能量增加作为改善证据。已有日期用来选择参数后只作为诊断回归集合。
