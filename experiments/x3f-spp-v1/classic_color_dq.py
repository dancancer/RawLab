"""Classic ColorDQ 与定点颜色矩阵实验；输入是显式校准后的原生计数。

参数必须由调用方给定。本模块不猜测机身校准、不读取 SPP 保存参数、不加载 Sigma 库。
"""

import math
from numbers import Integral

import numpy as np


def make_color_dq_luts(strengths):
    """恢复 lib98 GetTanhLUT 的 B=(.8,.8,.8) 路径，返回三张 signed16 表。"""
    values = np.asarray(strengths)
    if (values.shape != (3,) or not np.issubdtype(values.dtype, np.number)
            or np.iscomplexobj(values) or not np.all(np.isfinite(values)) or np.any(values < 0)):
        raise ValueError('Expected three finite nonnegative ColorDQ strengths')
    values = values.astype(np.float64)
    maximum = float(np.max(values / .8))
    if maximum == 0:
        return np.zeros((3, 512), np.int16)
    if not math.isfinite(maximum):
        raise ValueError('ColorDQ strength exceeds supported floating-point range')
    step = (.5 / maximum) * .5
    if step == 0 or not math.isfinite(step):
        raise ValueError('ColorDQ lookup extent is outside the supported range')
    extent = 6.2853 / step
    requested = min(2147483647, int(extent)) if math.isfinite(extent) else 2147483647
    size = next((size for size in (512, 1024, 2048, 4096) if requested <= size), 8192)
    tables = np.zeros((3, size), np.int16)
    for index in range(size // 2):
        phase = step * index
        window = (math.cos(phase) + 1) * .5 if phase < 3.1416 else 0.
        for channel, strength in enumerate(values):
            if strength:
                tables[channel, index] = int(strength * window * math.tanh(.8 * index / strength) + .5)
    tables[:, size // 2 + 1:] = -tables[:, 1:size // 2][:, ::-1]
    tables[:, size // 2] = tables[:, size // 2 + 1]
    return tables


def _integer_array(values, shape, name):
    result = np.asarray(values)
    if (result.shape != shape or not np.issubdtype(result.dtype, np.integer)
            or np.any(result < -2147483648) or np.any(result > 2147483647)):
        raise ValueError(f'Expected {name} with shape {shape} and signed32 integer values')
    return result.astype(np.int64)


def transform_counts(pixels, tables, fixed_matrix, shift, black_offset=(0, 0, 0), bounds=(-500, 24000)):
    """返回 (矩阵后计数, 矩阵前副本)，均为 signed16；Retinex 使用前者。

fixed_matrix 是已经量化的行优先 3×3 矩阵，shift 是其定点小数位数。
复现 native W-register 溢出、索引限幅与整数移位，不把浮点 RGB 默认为同域数据。
"""
    pixels = np.asarray(pixels)
    tables = np.asarray(tables)
    if pixels.ndim not in (2, 3) or pixels.shape[-1] != 3 or not pixels.size or pixels.dtype != np.int16:
        raise ValueError('Expected a nonempty signed16 count image or pixel row')
    if (tables.ndim != 2 or tables.shape[0] != 3 or tables.shape[1] not in (512, 1024, 2048, 4096, 8192)
            or tables.dtype != np.int16):
        raise ValueError('Expected three signed16 native ColorDQ lookup tables')
    if not isinstance(shift, Integral) or not 1 <= shift <= 31:
        raise ValueError('Fixed-point matrix shift must be an integer in [1,31]')
    matrix = _integer_array(fixed_matrix, (3, 3), 'fixed matrix')
    offset = _integer_array(black_offset, (3,), 'black offset')
    limits = _integer_array(bounds, (2,), 'output bounds')
    if not -32768 <= limits[0] <= limits[1] <= 32767:
        raise ValueError('Output bounds must be ordered signed16 limits')
    mask = tables.shape[1] - 1
    limit = tables.shape[1] // 2 - 1
    channels = np.arange(3)

    def lookup(values):
        indices = np.clip(values, -limit, limit).astype(np.int32) & mask
        return tables[channels, indices].astype(np.int32)

    original = (pixels.astype(np.int64) - offset).astype(np.int32)
    first = (original.astype(np.int64) - lookup(original)).astype(np.int32)
    light = (first[..., 0].astype(np.int64) + 2 * first[..., 1].astype(np.int64)
             + first[..., 2]).astype(np.int32) >> 2
    residual = (first.astype(np.int64) - light[..., None]).astype(np.int32)
    # Classic 的第二次扣减作用于第一次结果；不能套用 Merrill 的浮点版本。
    corrected = (first.astype(np.int64) - lookup(residual)).astype(np.int32)
    before_matrix = corrected.astype(np.int16)
    # 任意 64-bit 中间回绕不会改变最终低 32 位，等价于逐项 MUL/MADD W。
    summed = corrected.astype(np.int64) @ matrix.T + (1 << (int(shift) - 1))
    transformed = summed.astype(np.int32) >> int(shift)
    output = np.clip(transformed, limits[0], limits[1]).astype(np.int16)
    return output, before_matrix
