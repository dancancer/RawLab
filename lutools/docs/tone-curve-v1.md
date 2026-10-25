# Tone curve v1

全局 RGB 主曲线工作于显示编码 sRGB，在 highlights/shadows 后、contrast/saturation 前。
各通道独立使用同一映射，不改变此前 RAW/WB、Look、黑白场的顺序。

## 数据与兼容

`sony2fuji_tone_curve_config` v1 是 544 bytes：四个 32-bit 头字段
`version/struct_size/mode/count`，随后 33 组 binary64 `x/y`。request v2 保持原布局。
`legacy=0,count=0` 直接沿用 request 中的旧 scalar；`custom=1` 要求 2～33 点。
custom 的 request scalar 必须是 0，否则整个请求拒绝。非法 setter 不改变 session。
每个 native 请求显式配置完整对象，未启用 custom 时明确清零回 legacy。

custom 坐标必须有限且在 `[0,1]`，端点严格为 `(0,0)/(1,1)`，x 严格递增，y 非递减。
不以 epsilon 合并点，不限制合法相邻点的最小间距。所有控制点 `x=y` 时精确旁路，
包括保留输入的暂时越界工作值；非 identity 曲线将输入裁到 `[0,1]` 并产生有界结果。

legacy 的四段线性公式保留，不从旧 scalar 自动拟合或采样生成新曲线。UI 显式确认
切换 custom 后从 identity 开始；本端记录允许保存 inactive legacy scalar，但 native
与 Agent adapter 必须按当前模式输出互斥的最终参数。

## PCHIP 系数

采用 [SciPy PchipInterpolator 算法说明](https://docs.scipy.org/doc/scipy/reference/generated/scipy.interpolate.PchipInterpolator.html)
描述的 Fritsch–Butland 加权调和斜率与单边端点限制，应用不依赖 SciPy。
对相邻区间 `h0,h1` 和斜率 `d0,d1`，内部斜率为：

```
任一 d=0：m=0
w1=2*h1+h0，w2=h1+2*h0
m=(w1+w2)/(w1/d0+w2/d1)
```

端点使用 `((2*h0+h1)*d0-h0*d1)/(h0+h1)`，方向为负时置零，超过 `3*d0` 时限制。
两个点直接线性连接。每段保存 `x0,x1,y0,y1,h*m0,h*m1`，以归一化 Hermite 基函数
求值；不展开包含 `1/h³` 的系数，避免合法极窄区间溢出。实现用比例与二进制指数
运算处理极端间距，输出额外限于该段 `[y0,y1]` 以约束舍入误差。数学曲线 C1 连续，
平坦区间保持平坦，不过冲。

## GPU 精度准入

三个 shader 消费同一 CPU 计算的区间值和切线，使用同一 Hermite 源函数。
binary64 → float 后相邻 x 必须仍严格递增，差值至少为 float 最小正规数（避免 GPU
flush-to-zero），且每段 `3*(y1-y0)/(x1-x0) <= 16`。
该值是三次 Bezier 导数控制点的保守绝对上界，限制坐标舍入的放大；无效准入只限制
GPU，不限制合法曲线。Auto 整条 photo 路径回 CPU，Force 返回 `UNSUPPORTED`。
identity 无须上传区间，保持原 GPU 路径。

## 可复现验证

- 固定 [参考向量](../tests/fixtures/tone-curve-v1-reference.json) 由独立 SciPy 1.18.1
  `PchipInterpolator` 生成，包含 identity、S 形、平坦区间、非均匀点和 33 点；
  binary64 参考误差上限 `2e-14`。
- `tone_curve_tests` 覆盖 120 组固定种子的 2～33 点随机曲线，每组 10001 个样本；
  另测 C1、固定控制点、非法值、subnormal 间距与 float 合并点。
- `curve_gpu_boundary.h` 用 4097 个灰阶样本对照 CPU，包含五类形状，float 误差上限
  `5e-6`；API/组合渲染要求 RGB8 各通道最多 2 DN，验证实际后端和精度回退。
- `tone_curve_api` 覆盖原 scalar、custom、identity、非法状态保留、session 清零、
  pre-HSL probe 与可选真实 RAW。CLI/MCP 验证 v5 严格解析及相同输出。

上述是测试合同；实际执行、设备与 UI 状态记入本轮验收证据，不能由测试存在推定通过。
