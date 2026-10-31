"""小尺寸、场景分组的校准实验；不参与产品渲染。"""

from itertools import combinations_with_replacement
import numpy as np


def srgb_decode(value):
    value = np.asarray(value, dtype=np.float64)
    return np.where(value <= 0.04045, value / 12.92,
                    np.maximum((value + 0.055) / 1.055, 0) ** 2.4)


def srgb_encode(value):
    value = np.asarray(value, dtype=np.float64)
    return np.where(value <= 0.0031308, value * 12.92,
                    1.055 * np.maximum(value, 0) ** (1 / 2.4) - 0.055)


def srgb_to_lab(value):
    matrix = np.array([[0.4124564, 0.3575761, 0.1804375],
                       [0.2126729, 0.7151522, 0.0721750],
                       [0.0193339, 0.1191920, 0.9503041]])
    xyz = srgb_decode(value) @ matrix.T / [0.95047, 1.0, 1.08883]
    delta = 6 / 29
    f = np.where(xyz > delta ** 3, np.cbrt(xyz), xyz / (3 * delta ** 2) + 4 / 29)
    return np.stack((116 * f[..., 1] - 16,
                     500 * (f[..., 0] - f[..., 1]),
                     200 * (f[..., 1] - f[..., 2])), axis=-1)


def rotate_saved(image, rotation):
    if rotation not in (0, 90, 180, 270):
        raise ValueError("Invalid saved rotation")
    return np.rot90(image, k=-(rotation // 90))


def reduce_reference(encoded, block):
    height, width, channels = encoded.shape
    if channels != 3 or height % block or width % block:
        raise ValueError("Reference dimensions must match the scene reduction grid")
    linear = srgb_decode(encoded)
    reduced = linear.reshape(height // block, block, width // block, block, 3).mean(axis=(1, 3))
    return srgb_encode(reduced)


def polynomial_features(rgb, degree, context=None):
    rgb = np.asarray(rgb, dtype=np.float64).reshape(-1, 3)
    columns = [np.ones(len(rgb))]
    for order in range(1, degree + 1):
        for indices in combinations_with_replacement(range(3), order):
            columns.append(np.prod(rgb[:, indices], axis=1))
    if context is not None:
        # 探索 Fill Light / Highlight 是否能由全局响应解释；不是 SPP 的已知公式。
        fill, highlight = np.asarray(context).T
        light = np.clip(rgb @ [.2126, .7152, .0722], 0, 1)
        for power in (1, 2, 3):
            columns.append(fill * light * (1 - light) ** power)
        columns.extend([fill * (rgb[:, 0] - rgb[:, 1]) * (1 - light),
                        fill * (rgb[:, 2] - rgb[:, 1]) * (1 - light),
                        highlight * light ** 2 * (1 - light),
                        highlight * light ** 3 * (1 - light)])
    return np.column_stack(columns)


def fit_polynomial(source, target, degree, context=None):
    features = polynomial_features(source, degree, context)
    target = np.asarray(target, dtype=np.float64).reshape(-1, 3)
    if len(features) != len(target) or not np.all(np.isfinite(features)) or not np.all(np.isfinite(target)):
        raise ValueError("Invalid fitting samples")
    regularizer = np.eye(features.shape[1]) * 1e-8
    regularizer[0, 0] = 0
    return np.linalg.solve(features.T @ features + regularizer, features.T @ target)


def predict_polynomial(source, weights, degree, context=None):
    return polynomial_features(source, degree, context) @ weights


def measure(actual, reference):
    actual, reference = np.asarray(actual), np.asarray(reference)
    if actual.shape != reference.shape or actual.shape[-1] != 3:
        raise ValueError("Image dimensions differ")
    if not np.all(np.isfinite(actual)) or not np.all(np.isfinite(reference)):
        raise ValueError("Nonfinite image samples")
    bounded = np.clip(actual, 0, 1)
    delta = np.linalg.norm(srgb_to_lab(bounded) - srgb_to_lab(reference), axis=-1)
    return {"delta_e76_median": float(np.median(delta)),
            "delta_e76_mean": float(np.mean(delta)),
            "delta_e76_p90": float(np.quantile(delta, 0.9)),
            "rgb_mae_255": float(np.mean(np.abs(bounded - reference)) * 255),
            "unclipped_rgb_mae_255": float(np.mean(np.abs(actual - reference)) * 255),
            "below_zero_channel_fraction": float(np.mean(actual < 0)),
            "above_one_channel_fraction": float(np.mean(actual > 1)),
            "out_of_range_fraction": float(np.mean((actual < 0) | (actual > 1)))}
