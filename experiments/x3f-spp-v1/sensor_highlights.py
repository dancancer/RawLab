"""按原始感光层接近实测上限的程度，验证高光中性色近似；不是 SPP 算法。"""

import re
import numpy as np


def validate_camera(metadata, profile):
    sections = metadata.split("BEGIN: PROP meta data\n")
    if len(sections) != 2 or "END: PROP meta data" not in sections[1]:
        raise ValueError("Missing or ambiguous camera properties")
    properties = sections[1].split("END: PROP meta data", 1)[0]
    for key, field in (("CAMMODEL", "camera_model"), ("CAMSERIAL", "camera_serial")):
        values = re.findall(r'^\s*\[\d+\]\s+"' + key + r'"\s*=\s*"([^"\n]*)"\s*$',
                            properties, re.MULTILINE)
        if len(values) != 1 or not profile.get(field) or values[0] != profile[field]:
            raise ValueError(f"Sensor profile does not match {key}")


def neutralize_highlights(scene, sensor, profile):
    scene, sensor = np.asarray(scene), np.asarray(sensor)
    ceiling = np.asarray(profile["ceiling"], dtype=np.float64)
    start, end = float(profile["start"]), float(profile["end"])
    if (scene.ndim != 3 or scene.shape[-1] != 3 or scene.shape != sensor.shape
            or not np.issubdtype(scene.dtype, np.floating)
            or not np.all(np.isfinite(scene)) or not np.all(np.isfinite(sensor))
            or np.any(sensor < 0) or np.any(sensor > 65535)):
        raise ValueError("Invalid or unaligned scene and sensor pixels")
    if (ceiling.shape != (3,) or not np.all(np.isfinite(ceiling)) or np.any(ceiling <= 0)
            or not np.isfinite(start) or not np.isfinite(end) or not 0 < start < end <= 1):
        raise ValueError("Invalid sensor highlight profile")
    # 必须三个感光层都接近上限；单层明亮不足以判断颜色信息已经失真。
    ratio = np.min(sensor.astype(np.float64) / ceiling, axis=-1)
    t = np.clip((ratio - start) / (end - start), 0, 1)
    confidence = t * t * (3 - 2 * t)
    output = scene.copy()
    selected = confidence > 0
    colors = scene[selected]
    # 在保存曝光和颜色调整之前修正；保留高光幅度，不在这里裁剪到显示范围。
    output[selected] = colors + (np.max(colors, axis=-1, keepdims=True) - colors) * confidence[selected, None]
    return output, confidence
