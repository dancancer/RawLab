"""Independent display-domain noise-aware sharpening experiment, not a renderer."""

import math

import cv2
import numpy as np

CANDIDATE_ID = "p3-bounded-edge-endpoint-v2"
STRENGTH_SEMANTICS = "linear_blend_to_limited_endpoint"


def _validate(image, amount):
    image = np.asarray(image)
    if image.ndim != 3 or image.shape[2] != 3 or min(image.shape[:2]) < 1 or not np.isfinite(image).all():
        raise ValueError("expected a nonempty finite RGB image")
    if not math.isfinite(amount) or not 0 <= amount <= 2:
        raise ValueError("sharpening strength must be in [0, 2]")
    return image.astype(np.float32, copy=False)


def luma(image):
    return image @ np.array([.2126, .7152, .0722], dtype=np.float32)


def ordinary_sharpen(image, amount):
    image = _validate(image, amount)
    if amount == 0:
        return image.copy()
    blurred = cv2.blur(image, (3, 3), borderType=cv2.BORDER_REPLICATE)
    return np.clip(image + np.float32(amount) * (image - blurred), 0, 1)


def equivalent_strength(response, target):
    """Invert a measured monotonic response, never silently saturating a target."""
    values = np.asarray(response, dtype=np.float64)
    if (values.ndim != 2 or values.shape[1] != 2 or len(values) < 2 or
            not np.isfinite(values).all() or not math.isfinite(target) or target < 0 or
            values[0, 0] != 0 or values[-1, 0] > 2 or
            np.any(np.diff(values[:, 0]) <= 0) or np.any(np.diff(values[:, 1]) < 0)):
        raise ValueError("expected a finite monotonic strength response in [0, 2]")
    if target < values[0, 1] or target > values[-1, 1]:
        return {"status": "UNREACHABLE", "amount": None}
    index = int(np.searchsorted(values[:, 1], target, side="left"))
    if index == 0:
        amount = values[0, 0]
    else:
        low, high = values[index - 1], values[index]
        fraction = (target - low[1]) / (high[1] - low[1])
        amount = low[0] + fraction * (high[0] - low[0])
    return {"status": "INTERPOLATED", "amount": float(amount)}


def _neighbors(plane):
    padded = np.pad(plane, 1, mode="edge")
    return padded[1:-1, :-2], padded[1:-1, 2:], padded[:-2, 1:-1], padded[2:, 1:-1]


def noise_aware_sharpen(image, amount):
    image = _validate(image, amount)
    diagnostics = {"domain": "display_RGB_before_sharpen", "noise_estimator": "64px_tile_residual_MAD",
                   "structure_window": 9, "noise_power_gate": 4, "local_range_limit": 3,
                   "edge_limiter": "coherent_headroom_then_reversal_floor", "projection_passes": 2,
                   "candidate": CANDIDATE_ID, "strength_semantics": STRENGTH_SEMANTICS}
    if amount == 0:
        return image.copy(), {**diagnostics, "enabled": False}
    # 色调/LUT 可产生显示范围外的值；先确定 SDR 基线，避免不可行的共同增量区间。
    image = np.clip(image, 0, 1)
    height, width = image.shape[:2]
    luminance = luma(image)
    residual = luminance - cv2.blur(luminance, (3, 3), borderType=cv2.BORDER_REPLICATE)
    # 估计的是当前显示域残差，不复用 RAW 线性域的 a/b，也不读取干净参考。
    tile = 64
    sigma = np.empty(((height + tile - 1) // tile, (width + tile - 1) // tile), dtype=np.float32)
    for row, y in enumerate(range(0, height, tile)):
        for col, x in enumerate(range(0, width, tile)):
            values = residual[y:y + tile, x:x + tile]
            sigma[row, col] = np.median(np.abs(values - np.median(values))) / .67448975
    noise = cv2.resize(sigma * sigma, (width, height), interpolation=cv2.INTER_LINEAR)
    power = cv2.blur(residual * residual, (9, 9), borderType=cv2.BORDER_REPLICATE)
    weight = np.maximum(power - 4 * noise, 0) / np.maximum(power + noise, 1e-12)
    requested = np.float32(2) * weight * residual
    kernel = np.ones((3, 3), dtype=np.uint8)
    lower = cv2.erode(image, kernel, borderType=cv2.BORDER_REPLICATE)
    upper = cv2.dilate(image, kernel, borderType=cv2.BORDER_REPLICATE)
    # 限制共同亮度增量，而非逐通道裁剪，避免局部边界把亮度锐化变成色度变化。
    lower_delta = np.max(np.maximum(lower, 0) - image, axis=2)
    upper_delta = np.min(np.minimum(upper, 1) - image, axis=2)
    gx = cv2.Sobel(luminance, cv2.CV_32F, 1, 0, ksize=3, scale=.125, borderType=cv2.BORDER_REPLICATE)
    gy = cv2.Sobel(luminance, cv2.CV_32F, 0, 1, ksize=3, scale=.125, borderType=cv2.BORDER_REPLICATE)
    horizontal = np.abs(gx) >= np.abs(gy)
    gradient = np.where(horizontal, gx, gy)
    magnitude = np.hypot(gx, gy)
    average_x = cv2.blur(gx, (9, 9), borderType=cv2.BORDER_REPLICATE)
    average_y = cv2.blur(gy, (9, 9), borderType=cv2.BORDER_REPLICATE)
    average_magnitude = cv2.blur(magnitude, (9, 9), borderType=cv2.BORDER_REPLICATE)
    coherence = np.hypot(average_x, average_y) / np.maximum(average_magnitude, 1e-12)
    peak = cv2.dilate(magnitude, np.ones((9, 9), np.uint8), borderType=cv2.BORDER_REPLICATE)
    core = np.clip((magnitude / np.maximum(peak, 1e-12) - .2) / .2, 0, 1)
    core = core * core * (3 - 2 * core) * (coherence > .75)
    # 通道裁切会把共同增量变成单向移动；保持这些邻域的 SDR 基线，不尝试重建。
    in_gamut = np.all((image > 0) & (image < 1), axis=2).astype(np.uint8)
    core *= cv2.erode(in_gamut, kernel, borderType=cv2.BORDER_REPLICATE)
    requested *= core
    addition = np.minimum(np.maximum(requested, lower_delta), upper_delta)
    direction = np.where(gradient >= 0, np.float32(1), np.float32(-1))
    left, right, up, down = _neighbors(luminance)
    previous, following = np.where(horizontal, left, up), np.where(horizontal, right, down)
    before = direction * (luminance - previous)
    after = direction * (following - luminance)
    sigma_map = np.sqrt(noise)
    edge = (np.abs(gradient) > sigma_map) & (weight > 0) & (core > 0)
    coherent = edge & (before > 2 * sigma_map) & (after > 2 * sigma_map)
    left, right, up, down = _neighbors(addition)
    previous_delta, following_delta = np.where(horizontal, left, up), np.where(horizontal, right, down)
    # 强边缘允许使用相邻像素已有的移动空间，但不能跨过其结果形成反向梯度。
    floor = np.minimum(direction * previous_delta - before, 0)
    ceiling = np.maximum(direction * following_delta + after, 0)
    relaxed = direction * np.minimum(np.maximum(direction * requested, floor), ceiling)
    addition = np.where(coherent, relaxed, addition)
    gamut_low, gamut_high = -image.min(axis=2), 1 - image.max(axis=2)
    addition = np.minimum(np.maximum(addition, gamut_low), gamut_high)
    # 弱斜率尾部只容许一个显示量化级的移动；强边缘仍保留完整增益空间。
    addition = np.where(magnitude < .75 * peak, np.clip(addition, -1 / 255, 1 / 255), addition)
    step_peak = cv2.dilate(np.maximum(np.abs(before), np.abs(after)),
                          np.ones((9, 9), np.uint8), borderType=cv2.BORDER_REPLICATE)
    # 保护峰值附近的斜率；肩部仍须能变平，否则会反过来限制中心锐化。
    before_floor = np.where(before >= .9 * step_peak, 0, np.maximum(before, 0))
    after_floor = np.where(after >= .9 * step_peak, 0, np.maximum(after, 0))
    # 只收回会新增反向梯度的增量；不为了满足邻点而强迫原图产生新的移动。
    for _ in range(2):
        left, right, up, down = _neighbors(addition)
        previous_delta, following_delta = np.where(horizontal, left, up), np.where(horizontal, right, down)
        floor = np.minimum(direction * previous_delta - before_floor, 0)
        ceiling = np.maximum(direction * following_delta + after_floor, 0)
        projected = direction * np.minimum(np.maximum(direction * addition, floor), ceiling)
        addition = np.where(edge, projected, addition)
    result = np.clip(image + np.float32(amount / 2) * addition[..., None], 0, 1)
    diagnostics.update(enabled=True, noise_sigma_median=float(np.median(sigma)),
                       noise_sigma_max=float(sigma.max()), weighted_pixel_fraction=float(np.mean(weight > 0)))
    return result, diagnostics
