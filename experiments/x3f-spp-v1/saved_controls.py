"""由单参数 SPP 对照校准的实验响应；不声称是官方处理公式。"""

import numpy as np
from calibration import srgb_decode, srgb_encode


def fit_curve(source, target, levels=1025):
    source = np.asarray(source, dtype=np.float64).ravel()
    target = np.asarray(target, dtype=np.float64).ravel()
    if source.shape != target.shape or not np.all(np.isfinite(source)) or not np.all(np.isfinite(target)):
        raise ValueError("Invalid curve samples")
    indices = np.clip(np.rint(source * (levels - 1)).astype(int), 0, levels - 1)
    count = np.bincount(indices, minlength=levels)
    sums = np.bincount(indices, weights=target, minlength=levels)
    xsum = np.bincount(indices, weights=source, minlength=levels)
    valid = np.flatnonzero(count)
    if len(valid) < 2:
        raise ValueError("Not enough curve input variation")
    blocks = []
    for index in valid:
        blocks.append([index, index, count[index], sums[index]])
        while len(blocks) > 1 and blocks[-2][3] / blocks[-2][2] > blocks[-1][3] / blocks[-1][2]:
            right = blocks.pop(); left = blocks.pop()
            blocks.append([left[0], right[1], left[2] + right[2], left[3] + right[3]])
    values = np.zeros(levels)
    for first, last, weight, total in blocks:
        values[first:last + 1] = total / weight
    positions = np.linspace(0, 1, levels)
    fitted = np.interp(positions, xsum[valid] / count[valid], values[valid])
    return {"x": positions.tolist(), "y": np.clip(fitted, 0, 1).tolist()}


def curve_lookup(curve, values):
    return np.interp(values, curve["x"], curve["y"])


def apply_curve(image, amount, curves):
    if amount == 0:
        return np.asarray(image).copy()
    unit = curves["amount"]
    if abs(amount) > unit + 1e-6:
        raise ValueError("Saved tone control is outside the calibrated range")
    positive = curve_lookup(curves["positive"], image) - image
    negative = curve_lookup(curves["negative"], image) - image
    factor = amount / unit
    return image + .5 * factor * (positive - negative) + .5 * factor ** 2 * (positive + negative)


def apply_saturation(image, amount):
    if amount == 0:
        return np.asarray(image).copy()
    if not -.5 <= amount <= .5:
        raise ValueError("Saved saturation is outside the calibrated range")
    linear = srgb_decode(image)
    luma = (linear @ [.2126, .7152, .0722])[..., None]
    return srgb_encode(luma + (1 + .5 * amount) * (linear - luma))


def box_mean(image, scale):
    kernel = max(1, int(round(max(image.shape) * scale)))
    if kernel % 2 == 0:
        kernel += 1
    radius = kernel // 2
    padded = np.pad(image, ((radius, radius), (radius, radius)), mode="edge")
    integral = np.pad(padded, ((1, 0), (1, 0))).cumsum(0).cumsum(1)
    return (integral[kernel:, kernel:] - integral[:-kernel, kernel:]
            - integral[kernel:, :-kernel] + integral[:-kernel, :-kernel]) / kernel ** 2


def apply_fill(image, amount, model, chunk_rows=128):
    if amount == 0:
        return np.asarray(image).copy()
    if not -.5 <= amount <= .600001:
        raise ValueError("Saved Fill Light is outside the experimental range")
    if chunk_rows < 1:
        raise ValueError("Chunk rows must be positive")
    luma = srgb_decode(image) @ [.2126, .7152, .0722]
    local = box_mean(luma, model["scale"]) - luma
    weights = np.asarray(model["weights"])
    output = np.empty(image.shape, dtype=np.float32)
    for y in range(0, image.shape[0], chunk_rows):
        block = image[y:y + chunk_rows]
        rgb = block.reshape(-1, 3)
        light = luma[y:y + chunk_rows].ravel()
        pixel = np.column_stack([np.ones(len(rgb)), rgb, light, light ** 2, rgb * (1 - rgb)])
        contrast = local[y:y + chunk_rows].ravel()
        features = np.column_stack([amount * pixel, amount ** 2 * pixel,
                                    amount * contrast, amount ** 2 * contrast])
        output[y:y + chunk_rows] = (rgb + features @ weights).reshape(block.shape)
    return output
