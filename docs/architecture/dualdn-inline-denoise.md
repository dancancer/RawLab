# DualDn 在原照片编辑流程中的接入

## 目标与范围

在原始 RAW 的编辑记录中启用 AI 降噪，原文件不变。用户手动触发一次全尺寸计算，
完成后曝光、曲线、外观、裁剪和导出复用结果，不因拖动普通滑杆重新运行网络。
关闭 AI 即恢复原来的显影路径；旧编辑记录缺少 AI 字段时等价于关闭。

桌面实验入口覆盖 Mac 与 Windows，共用 C++ 核心；移动端随后验证，
未支持的平台不得把带 AI 的编辑记录当作已经执行 AI。现有 C5 保留。
不训练新权重，不生成独立增强 DNG，不把 AI 隐式应用于缩略图或所有照片。

模型固定为 [DualDn Big / Restormer](https://github.com/OpenImagingLab/DualDn/tree/7ec5f6a21c04321beb0d3297d6e9ac5f50635555)，
源码 revision 为 `7ec5f6a21c04321beb0d3297d6e9ac5f50635555`，原始权重 SHA-256 为
`9bd36c18afd6148d3b5d50c215d77cc17a745851ed2735f1b655013e71c38e1d`。
完整目标包含 RAW 分支和 RGB 分支；RAW-only 是独立标注的对照模式，不能称作完整 DualDn。

## 固定模型协议

- 输入来自 LibRaw 解包后的有效 Bayer 区域，使用实际 active crop、CFA、黑位、白位。
  不使用显示 RGB、JPEG 预览或降采样 RAW；拒绝 X-Trans、线性 RGB RAW 和不支持的排列。
- RAW 网络输入是 NCHW 四相位张量，通道为 RGGB 的行优先位置
  `[R, G(top), G(bottom), B]`。相位变换必须同时作用于输入和输出，不交换绿色位置。
- 原始归一化为 `(DN - black[phase]) / (white - black[phase])`；
  进入网络前下限为 `1e-8`，上限不裁切。这保留前期验证的网络输入约定。
- 噪声参数为标量 `k` 和读出**方差** `b`，网络噪声图为
  `sqrt(max(k * input + b, 1e-7))`。不把标准差传入 `b`，不复用 RawNIND 的全局增益。
- RAW 分块使用 packed core 384 / halo 128；RGB 分块使用 mosaic core 512 / halo 64。
  两者实际网络边长均为 640。反射扩边、有效核心裁切和边缘尺寸统一由共享核心执行。
  改变分块会影响全局注意力，必须更新协议版本并重新比较，不视为纯性能改动。
- RGB 噪声图源自**原始 noisy RAW**。官方 ISP 使用当前 RAW 白平衡、相机矩阵、
  AHD、D65、Rec.709、`alpha=0`、无 BGU。先对齐官方行为，再接入应用颜色管线。
- 模型包包含两个网络与 ISP 图、输入输出形状、版本、来源、每个文件的 SHA-256、
  原始权重 SHA-256 和许可说明。导出工具只在开发环境使用；产品不依赖 Python/PyTorch。

图边界：`raw.onnx(packed_raw, k, b) -> denoised_packed`；
`isp.onnx(mosaic, wb, camera_to_xyz) -> encoded_rgb`；
`rgb.onnx(skip_rgb, noise_rgb) -> denoised_rgb`。
`skip_rgb = ISP(denoised_mosaic)`，`noise_rgb = ISP(sqrt(max(k * noisy_mosaic + b, 1e-7)))`。
RGB 输出已包含 skip，使用 Rec.709 编码但不保证处于 `[0,1]`；应用不得再次加 skip。

### 已知数值差异

官方 AHD 在横向与纵向评分接近时使用硬判定。不同 float32 执行环境的微小累积误差
可能改变少数像素的插值方向；RAW/RGB 网络单独对齐不代表完整链路逐像素对齐。
当前实验版本保留官方规则，接受经样例检查的局部数值差异，不因此修改权重、加入后处理
或替换 AHD。此接受范围限于已有证据，不代表跨机型泛化、无噪声真值或其他后端验证。

原定 max-abs/mean-abs 检查继续保留。诊断工具分别报告各阶段与完整链路的结果，
超限仍显示 `strict_parity=false`；不能通过降低门槛或仅看平均误差把它改写为通过。
新增后端、模型或处理规则需要重新做局部像素及实际观感检查；稳定 AHD 作为独立变体评估。
样片的具体差值、图像与执行记录保留在验证交付物或 PR 描述中，不成为通用误差上限。

## 噪声配置适用边界

以已测量的 Sony ILCE-7CM2 ISO 100/800/3200/12800 标定为初始实验配置。
配置保留机型、黑白位、采集条件、参数来源和有效 ISO 范围，不称作全相机标定。
范围内非锚点 ISO 的 log-log 插值必须标为实验推导；范围外和其他机型不静默外推。
无适用配置时明确说明原因并保留普通降噪。压力样片中的跨机身或 ISO 51200 外推
仅用于研究回归，不进入默认产品配置。

## 编辑空间与高光

共享管线遵守 [颜色契约](../../lutools/docs/color-contract.md)。RAW 分支先产生未白平衡的
去噪 Bayer，再通过现有原生显影路径获得 scene-linear 基线。曝光基准只应用一次。

官方 RGB 分支的 skip 图经过白平衡后的 `[1e-8, 1]` 裁切和 Rec.709 编码，
因此不能只反解 gamma 就替换 RawLab 的线性 RAW。接入方案是：

1. 分别反解网络 RGB 输出与其官方 skip 图的 Rec.709，得到 RGB 分支的线性修正量。
2. 使用已验证的官方 ISP 到原生 scene-linear 坐标变换，将修正量加到原生 RAW-only 基线上。
   修正量为零时必须严格保留原生基线；不得再次乘白平衡或重复应用曝光。
3. 官方 ISP 已裁切的区域不携带可信修正量。根据原始 RAW 与去噪 RAW 的白平衡后饱和程度平滑退出
   RGB 修正，保留 RAW-only 高光。阈值、邻域和颜色变换属于需要实测冻结的桥接协议。
4. 通过合成灰阶、负值、超白、白平衡变化及真实高光测试，比较完整官方结果、
   RAW-only、桥接结果。若桥接不能满足契约，完整模式保持不可用，不能以 RAW-only 冒充。

桥接坐标明确为颜色契约的**线性 sRGB float**，在曝光、显示曲线、LUT 和几何变换之前。
令 `P = row_normalized_XYZ_to_sRGB * camera_to_XYZ`（官方 ISP），`N = LibRaw rgb_cam`
（三通道原生矩阵），`a = min(WB) / WB_green`，则
`delta = a * N * inverse(P) * (inverse709(denoised_rgb) - inverse709(skip_rgb))`。
在未旋转的有效 sensor 坐标中对齐后加回原生基线，再走现有方向/镜头/曝光路径。
原生基线沿用当前 processing version 的 VNG/legacy 规则，不改成官方 AHD；
因此这是“原生基线 + RGB 分支修正”，不是声称两种去马赛克等价。processing version
和影响显影的参数必须进入桥接缓存键。非可逆矩阵、无有效 WB 或未支持的四颜色输入拒绝桥接。

桥接协议 v2：以原始与去噪 mosaic 逐点最大值经白平衡后建立保护图，向外扩展 8 个
sensor 像素；`t = clamp((1 - peak) / 0.15, 0, 1)`，修正权重为 `t*t*(3-2*t)`。
所有通道使用同一权重；peak >= 1 的保护区域严格返回原生 RAW-only 基线。
不裁切最终线性负值或超白值。这是当前实验桥接参数；后续若发现光晕或颜色退化，
则停用受影响的完整模式，修改协议版本后再验证。已看过的 11 张样片只用于回归，
不用来宣称独立 holdout 或机型泛化。

这是一种明确标注的 RawLab 适配结果，与官方显示空间输出不是逐像素相同的产品承诺。
官方参考模式保留在验证工具中，便于区分模型差异与宿主管线差异。

## 缓存、任务与故障语义

RAW 缓存键包含文件身份及变化信息、模型/协议/噪声配置摘要、有效区域和 CFA。
RGB/线性缓存额外包含白平衡、相机矩阵和桥接协议。曝光、外观、曲线和输出尺寸
不进入 AI 缓存键；白平衡改变只复用 RAW 分支，重新生成 RGB 结果。

有效区域、CFA 与相机矩阵由原片身份和固定解码协议共同确定；解码规则或矩阵来源变化时
必须升级 `rawlab-bayer-v1`，标定值变化必须更换 calibration 摘要，桥接规则变化升级 bridge
版本。RGB 缓存头另绑定所依赖 RAW 输出的 SHA-256；RAW 损坏后重建时，只有实际输出
完全相同才可复用已有 RGB 修正，避免把两个不匹配的阶段结果组合。

计算在后台执行。状态为 idle/running/ready/failed/cancelled；进度以阶段和已完成分块表示。
取消在分块边界生效。未完成结果不发布；切换照片、关闭 AI 或新请求到来时，旧任务
即使稍后返回也不得覆盖当前照片。缓存采用有版本的原子写入，损坏或不匹配就重建。
预览和导出读取同一份全尺寸完成结果；导出不得静默使用较低分辨率或部分 AI 结果。

CPU 是必需后端。Auto 可在加速失败后从干净状态重跑 CPU，并报告实际执行后端；
Force 不能把 CPU 回退当作加速成功。CoreML 算子覆盖、真实硬件分配、速度和内存都以
测量为准，不能把注册 CoreML provider 等同于整图在 GPU/ANE 上运行。

Mac 的 Auto 使用直接转换的 float32 Core ML MLProgram 执行 RAW/RGB 网络，
`CPUAndGPU` 且禁用 GPU 低精度累加；不经 ONNX CoreML provider 拆分子图。
官方 ISP 固定为 ONNX CPU，强制 CoreML 也只要求两个神经网络使用原生 Core ML。
目标为 Apple Silicon/macOS 14 及以上；其他环境通过 Auto 回退 CPU。
原生包包含逐文件摘要，拒绝符号链接、越界路径及未列入 manifest 的文件。
网络输入、权重、float32、640 分块和 halo 均保持现有协议。

Windows 的 Auto 使用 ONNX Runtime DirectML 执行 RAW/RGB 网络，禁用会话内隐式
CPU provider 回退；若阶段失败，则现有 Auto 逻辑从干净状态重跑 CPU。Force 使用
DirectML，拒绝 DXGI 软件适配器和 WARP。固定 ONNX Runtime DirectML 1.23.0 与
DirectML 1.15.4，不启用半精度，官方 ISP 仍为 ONNX CPU。运行库放在程序旁，避免
Windows 搜索顺序加载系统旧版 ONNX DLL。缓存身份包含 DirectML 运行库、实际适配器
及驱动版本；Windows 原片身份还含内容摘要，覆盖保留尺寸和修改时间的原地写入。
Windows 批量任务固定请求后端，检查和导出使用相同后端缓存。

请求后端进入缓存键，原生运行库身份还包括 macOS 版本。缓存头记录实际阶段后端，
读取时保留该记录；旧缓存未记录的后端标为 unknown，不猜测为 CPU 或 GPU。
共享 C ABI 的 `sony2fuji_session_get_ai_backend` 提供完成结果的生成后端，
与显示渲染的 `sony2fuji_session_get_last_backend` 分开。

模型缺失、校验失败、配置不适用和计算失败均给出可理解的状态。只有完整结果成功后
启用 AI 外观，避免导出无声变回普通降噪。AI 生效时停用重复的 RAW/C5 降噪，保留锐化。
已有普通降噪参数保留在编辑记录，关闭 AI 后可恢复。
首次计算中尚未保存 `enabled=true`，界面显示处理进度，暂时禁用导出和复制设置；
计算成功后才保存启用状态并允许导出。已经启用的记录若缓存失效/缺失，则导出等待准备完成，
失败或取消时阻止该次导出并说明原因；用户关闭 AI 后可正常导出，不能静默删掉启用字段。

## 交付边界

模型权重、RAW 样片、校准原片、缓存、测量输出和本机路径不入库；可复现的导出工具、
协议、回归测试及必要的标量配置可以入库。产品资源需保留上游来源和许可。
转换后的模型保留上游 CC BY-NC 4.0 许可；实验接入不包含模型分发、发布或商业使用授权。
