"""固定响应模型的分块渲染；不读取参考图，不重新拟合。"""

import numpy as np
from calibration import predict_polynomial, srgb_encode


def prepare_input(scene, settings, stage, matrix):
    if settings.unknown_adjustments:
        raise ValueError(f"Unknown nonzero saved adjustments: {settings.unknown_adjustments}")
    for control in ("contrast", "shadow", "saturation", "sharpness"):
        if getattr(settings, control) != 0:
            raise ValueError(f"Unmodeled saved control: {control}")
    rgb = np.asarray(scene, dtype=np.float64).reshape(-1, 3).copy()
    gain = np.asarray(settings.color_adjustment)
    if stage == "scene":
        rgb *= gain
    elif stage == "camera":
        rgb = ((rgb @ np.linalg.inv(matrix).T) * gain) @ matrix.T
    elif stage != "none":
        raise ValueError("Unknown color adjustment stage")
    rgb *= 2 ** settings.exposure
    encoded = np.sign(rgb) * srgb_encode(np.abs(rgb))
    context = np.tile([settings.fill_light, settings.highlight], (len(rgb), 1))
    return encoded, context


def render(scene, settings, matrix, model, chunk_rows=128):
    if scene.ndim != 3 or scene.shape[2] != 3 or chunk_rows < 1:
        raise ValueError("Invalid scene dimensions or chunk size")
    output = np.empty(scene.shape, dtype=np.float32)
    weights = np.asarray(model["weights"], dtype=np.float64)
    for y in range(0, scene.shape[0], chunk_rows):
        block = scene[y:y + chunk_rows]
        encoded, context = prepare_input(block, settings, model["stage"], matrix)
        predicted = predict_polynomial(encoded, weights, model["degree"],
                                       context if model["context"] else None)
        if not np.all(np.isfinite(predicted)):
            raise ValueError("Nonfinite model output")
        output[y:y + chunk_rows] = predicted.reshape(block.shape)
    return output
