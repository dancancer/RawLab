"""Verified float IO and explicitly scoped measurements for offline experiments."""

import math
from pathlib import Path

import cv2
import numpy as np

from run_denoise_quality import sha256


def load_buffer(descriptor):
    path = Path(descriptor["path"])
    shape = descriptor["shape"]
    dtype = descriptor["dtype"]
    if dtype not in ("<f4", "<u2") or not isinstance(shape, list) or len(shape) not in (2, 3) or not all(
            type(value) is int and value > 0 for value in shape):
        raise ValueError("invalid buffer layout")
    if path.stat().st_size != math.prod(shape) * np.dtype(dtype).itemsize or sha256(path) != descriptor["sha256"]:
        raise ValueError("buffer length/hash mismatch")
    return np.memmap(path, mode="r", shape=tuple(shape), dtype=dtype)


def write_buffer(path, image, space, stage):
    image = np.asarray(image, dtype="<f4")
    with Path(path).open("xb") as stream:
        image.tofile(stream)
    return {"path": str(path), "dtype": "<f4", "shape": list(image.shape),
            "space": space, "stage": stage, "sha256": sha256(Path(path))}


def luma(image):
    return np.asarray(image) @ np.array([.2126, .7152, .0722])


def chroma(image):
    values = np.asarray(image)
    return np.stack(((values[..., 0] - values[..., 1]) / np.sqrt(2),
                     (values[..., 0] + values[..., 1] - 2 * values[..., 2]) / np.sqrt(6)), axis=-1)


def detail(image):
    values = luma(image).astype(np.float32)
    return cv2.GaussianBlur(values, (0, 0), .5) - cv2.GaussianBlur(values, (0, 0), 1.5)


def edge_profile_metrics(image, reference, edge_x, guard=4, extent=24):
    if image.shape != reference.shape or image.shape[0] < 33 or not 0 < guard < extent <= edge_x < image.shape[1] - extent:
        raise ValueError("invalid edge profile geometry")
    actual = luma(image[16:-16]).mean(axis=0)
    expected = luma(reference[16:-16]).mean(axis=0)
    difference = actual - expected
    outside_edge = np.concatenate((difference[edge_x - extent:edge_x - guard],
                                   difference[edge_x + guard:edge_x + extent]))
    return {"guard_pixels": guard, "extent_pixels": extent,
            "guard_max_abs_error": float(np.max(np.abs(outside_edge))),
            "guard_rms_error": float(np.sqrt(np.mean(outside_edge ** 2))),
            "profile_actual": actual[edge_x - extent:edge_x + extent].tolist(),
            "profile_reference": expected[edge_x - extent:edge_x + extent].tolist()}


def measure(image, reference=None):
    image = np.asarray(image)
    if image.ndim != 3 or image.shape[2] != 3 or min(image.shape[:2]) < 3 or not np.isfinite(image).all():
        raise ValueError("measurement requires finite RGB with a 3x3 interior")
    y, uv, high = luma(image), chroma(image), detail(image)
    result = {"mean_rgb": image.mean(axis=(0, 1), dtype=np.float64).tolist(),
              "luma_mean": float(y.mean()), "luma_stddev": float(y.std()),
              "chroma_stddev": float(np.sqrt(np.mean(np.var(uv, axis=(0, 1))))),
              "detail_rms": float(np.sqrt(np.mean(high.astype(np.float64) ** 2))),
              "reference_kind": "none"}
    if reference is None:
        return result
    reference = np.asarray(reference)
    if reference.shape != image.shape or not np.isfinite(reference).all():
        raise ValueError("reference shape/finite check failed")
    delta = image.astype(np.float64) - reference
    reference_detail = detail(reference).astype(np.float64)
    energy = float(np.mean(reference_detail ** 2))
    reference_mean = float(luma(reference).mean())
    brightness_ratio = float(y.mean() / reference_mean) if abs(reference_mean) > 1e-8 else None
    result.update(
        reference_kind="caller_declared_reference",
        rgb_rmse=float(np.sqrt(np.mean(delta ** 2))),
        luma_rmse=float(np.sqrt(np.mean(luma(delta) ** 2))),
        chroma_rmse=float(np.sqrt(np.mean(chroma(delta) ** 2))),
        mean_rgb_bias=delta.mean(axis=(0, 1)).tolist(),
        reference_detail_rms=float(np.sqrt(energy)),
        mean_luma_ratio=brightness_ratio,
        normalized_detail_projection=(
            float(np.mean(high.astype(np.float64) * reference_detail) / energy / brightness_ratio)
            if energy > 1e-10 and brightness_ratio is not None and brightness_ratio > 1e-8 else None))
    return result


def pixel_rect(image, region):
    height, width = image.shape[:2]
    x, y, w, h = region["rect"]
    left, top = math.floor(x * width), math.floor(y * height)
    right, bottom = min(width, math.ceil((x + w) * width)), min(height, math.ceil((y + h) * height))
    if min(left, top) < 0 or right - left < 3 or bottom - top < 3:
        raise ValueError("invalid measurement region")
    return left, top, right - left, bottom - top


def crop(image, rect):
    x, y, width, height = rect
    return np.asarray(image[y:y + height, x:x + width])


def save_comparison(path, rows, labels, display=False, view_ev=0, subtitle=""):
    from PIL import Image, ImageDraw, ImageFont
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 15)
    except OSError:
        font = ImageFont.load_default()
    width = max(images[0].shape[1] for _, images in rows)
    heights = [images[0].shape[0] for _, images in rows]
    canvas_width = len(labels) * (width + 12) + 12
    lines, line = [], ""
    for word in subtitle.split():
        candidate = (line + " " + word).strip()
        if line and font.getlength(candidate) > canvas_width - 24:
            lines.append(line)
            line = word
        else:
            line = candidate
    lines.append(line)
    label_top = 12 + 20 * len(lines)
    top = label_top + 29
    canvas = Image.new("RGB", (canvas_width, sum(heights) + len(rows) * 42 + top + 12), "#eeeeee")
    draw = ImageDraw.Draw(canvas)
    for index, line in enumerate(lines):
        draw.text((12, 8 + index * 20), line, font=font, fill="#111111")
    for col, label in enumerate(labels):
        draw.text((12 + col * (width + 12), label_top), label, font=font, fill="#111111")
    for (name, images), height in zip(rows, heights):
        draw.text((12, top), name, font=font, fill="#111111")
        top += 24
        for col, image in enumerate(images):
            values = np.clip(image if display else image * 2 ** view_ev, 0, 1)
            if not display:
                values = np.where(values <= .0031308, values * 12.92, 1.055 * values ** (1 / 2.4) - .055)
            bitmap = Image.fromarray(np.rint(values * 255).astype(np.uint8))
            canvas.paste(bitmap, (12 + col * (width + 12), top))
        top += height + 18
    canvas.save(path)
