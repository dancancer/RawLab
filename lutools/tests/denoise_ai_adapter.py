"""Test-only fixed-weight RawNIND adapters; never imported by product code."""

from pathlib import Path

import cv2
import numpy as np


# Native sRGB-to-XYZ and the pinned upstream demo's XYZ-to-linear-Rec.2020.
_SRGB_TO_2020 = np.asarray([
    [1.71666343, -.35567332, -.25336809],
    [-.66667384, 1.61645574, .0157683],
    [.01764248, -.04277698, .94224328]], dtype=np.float32) @ np.asarray([
        [.4124564, .3575761, .1804375],
        [.2126729, .7151522, .0721750],
        [.0193339, .1191920, .9503041]], dtype=np.float32)
_REC2020_TO_SRGB = np.linalg.inv(_SRGB_TO_2020).astype(np.float32)
MODEL_HASHES = {
    "bayer": "da27509dab6a2915da67e988acd86cf71f9d5bbc8d1aa0ed32933578a887b901",
    "linear": "df957efadcc152c007d5d3b0917bdff9e41c0d4a0efe56584ef30b36393cd181",
}


def model_session(directory, variant):
    import onnxruntime as ort
    from run_denoise_quality import sha256
    path = directory / f"model_{variant}.onnx"
    if sha256(path) != MODEL_HASHES[variant]:
        raise ValueError("model differs from the pinned experiment weights")
    options = ort.SessionOptions()
    options.intra_op_num_threads = 6
    options.inter_op_num_threads = 1
    session = ort.InferenceSession(str(path), sess_options=options, providers=["CPUExecutionProvider"])
    channels, scale = (4, 2) if variant == "bayer" else (3, 1)
    source, output = session.get_inputs()[0], session.get_outputs()[0]
    if (source.type != "tensor(float)" or source.shape != [1, channels, 512, 512] or
            output.shape != [1, 3, 512 * scale, 512 * scale] or session.get_providers() != ["CPUExecutionProvider"]):
        raise ValueError("unexpected model tensor/provider contract")
    return session, source.name, {"sha256": MODEL_HASHES[variant], "onnxruntime": ort.__version__,
                                  "providers": session.get_providers(), "dtype": "float32", "threads": 6}


def linear_to_rec2020(image):
    return np.asarray(image, dtype=np.float32) @ _SRGB_TO_2020.T


def rec2020_to_linear(image):
    return np.asarray(image, dtype=np.float32) @ _REC2020_TO_SRGB.T


def pack_bayer(raw, metadata, clip=True):
    raw = np.asarray(raw)
    pattern = np.asarray(metadata["pattern"])
    black = np.asarray(metadata["cblack"], dtype=np.float64)
    white = float(metadata["white"])
    if raw.ndim != 2 or min(raw.shape) < 2 or pattern.shape != (2, 2):
        raise ValueError("invalid Bayer dimensions or pattern")
    if sorted(pattern.ravel().tolist()) != [0, 1, 2, 3] or len(black) < 6 or np.any(black[4:6]):
        raise ValueError("only ordinary four-phase Bayer black levels are supported")
    levels = black[:4] + float(metadata["black"])
    if not np.isfinite(levels).all() or not np.isfinite(white) or np.any(white <= levels):
        raise ValueError("invalid sensor black/white levels")
    red = np.argwhere(pattern == 0)[0]
    y, x = map(int, red)
    height, width = ((raw.shape[0] - y) // 2) * 2, ((raw.shape[1] - x) // 2) * 2
    if height == 0 or width == 0:
        raise ValueError("Bayer crop has no complete RGGB cell")
    active = raw[y:y + height, x:x + width]
    channels = []
    for dy, dx in ((0, 0), (0, 1), (1, 0), (1, 1)):
        channel = int(pattern[(y + dy) % 2, (x + dx) % 2])
        if (dy, dx) == (1, 1) and channel != 2:
            raise ValueError("unsupported non-RGGB Bayer layout")
        values = (active[dy::2, dx::2].astype(np.float32) - levels[channel]) / (white - levels[channel])
        channels.append(np.clip(values, 0, 1) if clip else values)
    return np.asarray(channels, dtype=np.float32), (y, x)


def input_anchor(packed, method):
    means = np.asarray(packed).mean(axis=(1, 2), dtype=np.float64)
    if len(means) != 4 or not np.isfinite(means).all():
        raise ValueError("expected finite packed RGGB")
    if method == "plane_mean":
        return float(means.mean())
    if method == "camera_rgb_mean":
        return float((means[0] + .5 * (means[1] + means[2]) + means[3]) / 3)
    raise ValueError("unknown input anchor")


def match_input_gain(output, anchor):
    """Normalize arbitrary signed model scale, not physical exposure or camera gain."""
    mean = float(np.asarray(output).mean(dtype=np.float64))
    if not np.isfinite(anchor) or anchor <= 0 or not np.isfinite(mean) or abs(mean) <= 1e-12:
        raise ValueError("degenerate input/output gain")
    gain = anchor / mean
    if not np.isfinite(gain) or gain == 0:
        raise ValueError("invalid gain")
    return np.asarray(output, dtype=np.float32) * np.float32(gain), gain


def _reflect(indices, length):
    if length == 1:
        return np.zeros_like(indices)
    period = 2 * length - 2
    folded = indices % period
    return np.where(folded < length, folded, period - folded)


def tiled_inference(source, infer, tile_size=512, halo=64, scale=1, output_path=None):
    source = np.asarray(source)
    if source.ndim != 3 or min(source.shape) < 1 or scale not in (1, 2) or not 0 <= 2 * halo < tile_size:
        raise ValueError("invalid tensor or tile geometry")
    channels, height, width = source.shape
    step = tile_size - 2 * halo
    output = None
    for y in range(0, height, step):
        yy = _reflect(np.arange(y - halo, y - halo + tile_size), height)
        for x in range(0, width, step):
            xx = _reflect(np.arange(x - halo, x - halo + tile_size), width)
            tile = source[np.ix_(np.arange(channels), yy, xx)].astype(np.float32)
            result = np.asarray(infer(tile))
            if result.ndim != 3 or result.shape[1:] != (tile_size * scale, tile_size * scale) or not np.isfinite(result).all():
                raise ValueError("model returned invalid tile")
            if output is None:
                shape = (height * scale, width * scale, result.shape[0])
                if output_path is not None:
                    path = Path(output_path)
                    with path.open("xb"):
                        pass
                    output = np.memmap(path, mode="r+", dtype="<f4", shape=shape)
                else:
                    output = np.empty(shape, dtype=np.float32)
            if result.shape[0] != output.shape[2]:
                raise ValueError("model changed output channels")
            h, w = min(step, height - y) * scale, min(step, width - x) * scale
            start = halo * scale
            output[y * scale:y * scale + h, x * scale:x * scale + w] = result[:, start:start + h, start:start + w].transpose(1, 2, 0)
    if isinstance(output, np.memmap):
        output.flush()
    return output


def orient(image, flip):
    if type(flip) is not int or not 0 <= flip <= 7:
        raise ValueError("invalid LibRaw orientation")
    result = image[::-1] if flip & 2 else image
    result = result[:, ::-1] if flip & 1 else result
    return result.swapaxes(0, 1) if flip & 4 else result


def sensor_view(image, flip):
    if type(flip) is not int or not 0 <= flip <= 7:
        raise ValueError("invalid LibRaw orientation")
    result = image.swapaxes(0, 1) if flip & 4 else image
    result = result[:, ::-1] if flip & 1 else result
    return result[::-1] if flip & 2 else result


def camera_to_native(camera_rgb, metadata):
    wb = np.asarray(metadata["post_scale_pre_mul"][:3], dtype=np.float32)
    matrix = np.asarray(metadata["rgb_cam"], dtype=np.float32)
    working = np.asarray(metadata["native_working_matrix"], dtype=np.float32)
    if (wb.shape != (3,) or matrix.shape != (3, 3) or working.shape != (3, 3) or
            not all(np.isfinite(value).all() for value in (wb, matrix, working)) or np.any(wb <= 0)):
        raise ValueError("invalid camera transform")
    balanced = np.asarray(camera_rgb, dtype=np.float32) * (wb / wb[1])
    return (balanced @ matrix.T) @ working.T


def clipped_input_weight(packed_unclipped, sensor_shape, offset, radius=8):
    # 只由传感器饱和决定保护区域，不查看模型误差或低 ISO 参考。
    clipped = np.any(packed_unclipped >= .995, axis=0).astype(np.float32)
    clipped = cv2.dilate(clipped, np.ones((3, 3), dtype=np.uint8))
    enlarged = np.repeat(np.repeat(clipped, 2, axis=0), 2, axis=1)
    mask = np.zeros(sensor_shape, dtype=np.float32)
    y, x = offset
    mask[y:y + enlarged.shape[0], x:x + enlarged.shape[1]] = enlarged
    if radius:
        softened = cv2.GaussianBlur(mask, (0, 0), radius)
        mask = np.maximum(mask, softened)
    return np.clip(mask, 0, 1)


def highlight_fallback(candidate, native, weight):
    if candidate.shape != native.shape or candidate.shape[:2] != weight.shape:
        raise ValueError("highlight mask shape mismatch")
    if not np.isfinite(weight).all() or np.any(weight < 0) or np.any(weight > 1):
        raise ValueError("invalid highlight weights")
    return candidate * (1 - weight[..., None]) + native * weight[..., None]
