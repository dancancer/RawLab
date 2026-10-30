"""原尺寸亮度细节响应诊断；不是 SPP 算法，也不能恢复已经丢失的纹理。"""

import numpy as np


def validate_profile(profile):
    if not isinstance(profile, dict) or profile.get('schema') != 'rawlab-luma-detail-v1':
        raise ValueError('Unsupported detail response profile')
    amount, threshold = profile.get('amount'), profile.get('threshold')
    if (not isinstance(amount, (int, float)) or not np.isfinite(amount) or not 0 <= amount <= 1
            or not isinstance(threshold, (int, float)) or not np.isfinite(threshold)
            or not 0 <= threshold <= .01):
        raise ValueError('Invalid detail response amount or threshold')


def apply_detail(image, profile):
    validate_profile(profile)
    image = np.asarray(image)
    if (image.ndim != 3 or image.shape[-1] != 3 or min(image.shape[:2]) < 1
            or not np.issubdtype(image.dtype, np.floating)
            or not np.all(np.isfinite(image)) or np.any(image < 0) or np.any(image > 1)):
        raise ValueError('Detail response requires finite display RGB in [0, 1]')
    if profile['amount'] == 0:
        return image.copy()
    luma = image @ np.array([.2126, .7152, .0722], dtype=image.dtype)
    # 固定一个原生像素的支持半径，不随缩略图尺寸变化，也不在分块边界补边。
    padded = np.pad(luma, ((0, 0), (1, 1)), mode='edge')
    low = (padded[:, :-2] + 2 * padded[:, 1:-1] + padded[:, 2:]) * .25
    padded = np.pad(low, ((1, 1), (0, 0)), mode='edge')
    low = (padded[:-2] + 2 * padded[1:-1] + padded[2:]) * .25
    high = luma - low
    delta = np.sign(high) * np.maximum(np.abs(high) - profile['threshold'], 0) * profile['amount']
    # RGB 共用增量和色域限制，避免逐通道裁剪引入新的彩边。
    delta = np.clip(delta, -np.min(image, axis=-1), 1 - np.max(image, axis=-1))
    return image + delta[..., None]
