"""SPP 6.9 Classic 静态指令恢复的 Retinex 原语；输入单位必须由调用方确认。

这不是完整 SPP 显影器。本模块不加载 Sigma 库，也不把归一化 scene/display RGB
自动当成 Classic 的内部计数。测试使用独立进程记录的原生合成像素结果。
"""

from functools import lru_cache
from decimal import Decimal, localcontext
import math
from numbers import Real

import numpy as np


def _mono(image):
    values = np.asarray(image)
    if values.ndim != 2 or not values.size or values.dtype != np.int16:
        raise ValueError('Expected a nonempty 2D signed int16 image')
    return values


def downscale2x2(image):
    """原生 2×2 整数均值；奇数末行复制，末列使用最后两个列值。"""
    values = _mono(image).astype(np.int32)
    h, w = values.shape
    padded = np.pad(values, ((0, h % 2), (0, w % 2)), mode='edge')
    if w % 2 and w > 1:
        padded[:, -1] = padded[:, -3]
    result = ((padded[::2, ::2] + padded[1::2, ::2]
               + padded[::2, 1::2] + padded[1::2, 1::2]) >> 2).astype(np.int16)
    return result


def _smooth_axis(image, axis):
    indices = np.arange(image.shape[axis])
    left = np.take(image, np.maximum(indices - 1, 0), axis=axis).astype(np.int32)
    right = np.take(image, np.minimum(indices + 1, len(indices) - 1), axis=axis)
    return ((left + 2 * image.astype(np.int32) + right) >> 2).astype(np.int16)


def smooth_double_blend(half, full, smooth_weight, full_weight):
    """逐轴整数平滑、四 tap 二倍插值，再按原生 Q8 权重混合。"""
    half, full = _mono(half), _mono(full)
    if any(f not in (2 * h, 2 * h - 1) for h, f in zip(half.shape, full.shape)):
        raise ValueError('Full image dimensions must be twice the half image, optionally minus one')
    if not all(isinstance(v, Real) and np.isfinite(v) and 0 <= v <= 16
               for v in (smooth_weight, full_weight)):
        raise ValueError('Unsupported blend weights')
    a, b = (int(v * 256 + .5) for v in (smooth_weight, full_weight))
    h, w = half.shape
    # 对应原生五个轮转行与一个插值行。显式保存边界状态，所有访问均在数组内。
    scratch = np.zeros((5, w + 4), dtype=np.int16)
    def make_row(destination, center, initial=False):
        if center - 1 < h:
            left = half[max(center - 1, 0)].astype(np.int32)
        else:
            # 原生读取紧邻 half 的工作缓冲。固定为本函数自己的缓冲内容，
            # 不读取调用者数组之外的内存；这是 PyramidFilter 的实际布局。
            left = scratch[0, :w].astype(np.int32).copy()
        middle = half[min(center, h - 1)].astype(np.int32)
        right = half[min(center + 1, h - 1)].astype(np.int32)
        if center - 1 >= h and destination == 0:
            # 标量重叠路径先写两个元素之后的位置；后续读取会看到这个写入。
            for x in range(w):
                scratch[0, x + 2] = (int(scratch[0, x]) + 2 * middle[x] + right[x]) >> 2
            vertical = scratch[0, 2:w + 2].copy()
        else:
            vertical = ((left + 2 * middle + right) >> 2).astype(np.int16)
        smoothed = _smooth_axis(vertical.reshape(1, -1), 1)[0]
        scratch[destination, 2:w + 2] = smoothed
        scratch[destination, :2] = vertical[0] if initial else smoothed[0]
        scratch[destination, w + 2:] = smoothed[-1]
    make_row(3, 0)
    make_row(4, min(1, h - 1), initial=True)
    scratch[1] = scratch[3]
    scratch[2] = scratch[3]
    spare, far, previous, current, following = 0, 1, 2, 3, 4
    result = np.empty_like(full)
    x = np.arange(full.shape[1])
    center_x = 2 + x // 2
    direction = np.where(x % 2 == 0, -1, 1)
    for y in range(full.shape[0]):
        if y % 2 == 0:
            make_row(spare, y // 2 + 2 if h > 1 else 0)
            center_row, near_row = scratch[current], scratch[previous]
        else:
            center_row, near_row = scratch[previous], scratch[current]
        interpolated = ((25 * center_row.astype(np.int32) + 9 * near_row.astype(np.int32)
                         - scratch[far] - scratch[following]) >> 5).astype(np.int16).astype(np.int32)
        expanded = ((25 * interpolated[center_x] + 9 * interpolated[center_x + direction]
                     - interpolated[center_x - direction]
                     - interpolated[center_x + 2 * direction]) >> 5)
        result[y] = ((a * expanded + b * full[y].astype(np.int32)) >> 8).astype(np.int16)
        if y % 2 == 0:
            spare, far, previous, current, following = far, previous, current, following, spare
    return result


def _mean_ratio(numerator, denominator):
    if denominator == 0:
        if numerator == 0:
            # 原生 0/0 后的 FCVTZS 产生零；显式处理，避免传播 NaN。
            return 0.0
        raise ValueError('Zero pyramid mean cannot normalize nonzero brightness')
    return numerator / denominator


def pyramid_filter(image):
    """Classic Retinex 的多尺度整数滤波；仅接受其非负亮度/方差域。"""
    values = _mono(image)
    if min(values.shape) < 3 or max(values.shape) <= 64 or np.any(values < 0):
        raise ValueError('Pyramid requires nonnegative values, both dimensions >=3 and long edge >64')
    initial_mean = int(np.mean(values, dtype=np.float64))
    levels, means = [], []
    current = values
    while min(current.shape) > 1:
        current = downscale2x2(current)
        mean = float(np.mean(current, dtype=np.float64))
        if max(current.shape) <= 32:
            mean = means[-1]
        levels.append(current)
        means.append(mean)
    current = np.trunc(levels[-1].astype(np.float64)
                       * _mean_ratio(initial_mean, means[-1]) + .5).astype(np.int16)
    for step, level in enumerate(range(len(levels) - 1, -1, -1)):
        fraction = .9 * .65 ** step
        if level:
            full = levels[level - 1]
            weight = fraction * _mean_ratio(initial_mean, means[level - 1])
        else:
            full, weight = values, fraction
        current = smooth_double_blend(current, full, 1 - fraction, weight)
    return current


def log_luminance(native_rgb):
    """将原生线性 RGB 计数转成有符号 16-bit 对数亮度，保留全图尺寸。"""
    image = np.asarray(native_rgb)
    if (image.ndim != 3 or image.shape[-1] != 3 or not image.size
            or not np.issubdtype(image.dtype, np.number) or np.iscomplexobj(image)
            or not np.all(np.isfinite(image))):
        raise ValueError('Expected a finite, nonempty native RGB count image')
    # 原生输入为 float32；G*.65 先舍入，再执行 R*.25 和 B*.1 的两次 FMA。
    with np.errstate(over='ignore'):
        samples = image.astype(np.float32).astype(np.float64)
    if not np.all(np.isfinite(samples)):
        raise ValueError('Native RGB counts must fit finite float32 values')
    partial = samples[..., 1] * .65 + samples[..., 0] * .25
    term = samples[..., 2] * .1
    light = partial + term
    # 只有接近整数索引的误差会改变 LUT。Python 3.12 没有 math.fma，
    # 在这些少数边界用精确十进制运算复现一次最终舍入，避免加载任何原生库。
    tolerance = 2 * np.finfo(np.float64).eps * (np.abs(partial) + np.abs(term))
    near_integer = (light > 0) & (light < 32767) & (np.abs(light - np.rint(light)) <= tolerance)
    with localcontext() as context:
        context.prec = 200
        factor = Decimal.from_float(.1)
        for index in np.flatnonzero(near_integer):
            light.flat[index] = float(Decimal.from_float(float(samples[..., 2].flat[index])) * factor
                                      + Decimal.from_float(float(partial.flat[index])))
    indices = np.clip(light, 0, 32767).astype(np.int32)
    return np.floor(1024 * np.log(indices + 30.0) + .5).astype(np.int16)


def retinex_log_map(native_rgb):
    """从已校准的 Classic 原生线性计数生成完整尺寸 log-gain map。"""
    log_light = log_luminance(native_rgb)
    local = pyramid_filter(log_light)
    mean = int(np.mean(log_light, dtype=np.float64))
    shift = mean + int(.5 * (6761.438964354475 - mean) + 512)
    centered = (log_light.astype(np.int32) - shift).astype(np.int16)
    local = (local.astype(np.int32) - shift).astype(np.int16)
    residual = centered.astype(np.int32) - local.astype(np.int32)
    variance = np.minimum((residual.astype(np.int64) ** 2) >> 10, 32767).astype(np.int16)
    filtered = pyramid_filter(variance).astype(np.int32)
    denominator = np.floor(32 * np.sqrt(np.maximum(filtered + 64, 64)) + .5)
    # ImageMean(pVar) 在方差转成标准差查表值之后调用（0x75a9c..0x75d70）。
    global_scale = 1024 * math.sqrt(int(np.mean(denominator, dtype=np.float64)) / 1024)
    result = global_scale * residual / denominator - centered
    return np.trunc(result).astype(np.int16)


@lru_cache(maxsize=16)
def _gain_lut(amount):
    # lib98 arm64 0x76308–0x764e0；索引按有符号值的低 16 位寻址。
    strength = 1.33 * amount
    lut = np.zeros(65536, dtype=np.int16)
    lut[0] = 256
    extent = 1024 * (abs(strength) + .0625) ** .25
    target = int(256 * math.exp(strength))
    positive = negative = 0
    for index in range(1, 32768):
        if positive == target:
            # 原生会提前冻结正负两侧；不能逐点 round(exp) 代替。
            lut[index:32768] = target
            lut[32769:65537 - index] = negative
            break
        gain = math.exp(strength * math.tanh(index / extent))
        positive = int(256 * gain + .5)
        negative = int(256 / gain + .5)
        lut[index] = positive
        lut[65536 - index] = negative
    # 非零分支没有写入 -32768；入口拒绝这个未定义的索引。
    lut.flags.writeable = False
    return lut


def gain_from_log_map(log_map, amount):
    """把有符号 log-gain map 转成共用的 RGB 乘数，包含原生 Q8 量化。"""
    values = np.asarray(log_map)
    if values.ndim != 2 or not values.size or values.dtype != np.int16:
        raise ValueError('Expected a nonempty 2D signed int16 log-gain map')
    if not isinstance(amount, Real) or not np.isfinite(amount) or not -2 <= amount <= 2:
        raise ValueError('Fill Light must be finite and in the supported interval [-2,2]')
    if amount == 0:
        return np.ones(values.shape, dtype=np.float32)
    if np.any(values == -32768):
        raise ValueError('Native nonzero Fill Light leaves index -32768 undefined')
    return _gain_lut(float(amount))[values.astype(np.int32) & 65535].astype(np.float32) / 256
