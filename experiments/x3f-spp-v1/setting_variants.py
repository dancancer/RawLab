"""在内存副本中只修改公开 HeaderExt，供 SPP 单参数对照；不写入原照片。"""

import math
import struct
from saved_settings import parse_saved_settings


def neutral_variant(data: bytes, overrides: dict[str, float]) -> bytes:
    parse_saved_settings(data)
    kinds = {"exposure": 1, "contrast": 2, "shadow": 3, "highlight": 4,
             "saturation": 5, "sharpness": 6, "red": 7, "green": 8,
             "blue": 9, "fill_light": 10}
    if overrides.keys() - kinds.keys():
        raise ValueError("Unknown saved control")
    values = {name: 1.0 if name in ("red", "green", "blue") else 0.0 for name in kinds}
    values.update(overrides)
    if any(not math.isfinite(value) for value in values.values()):
        raise ValueError("Nonfinite saved control")
    if any(values[name] <= 0 for name in ("red", "green", "blue")):
        raise ValueError("Color gains must be positive")
    output = bytearray(data)
    for name, kind in kinds.items():
        slots = [i for i, tag in enumerate(output[72:104]) if tag == kind]
        if not slots:
            try:
                slot = output[72:104].index(0)
            except ValueError as error:
                raise ValueError("No empty HeaderExt slot") from error
            output[72 + slot] = kind
            slots = [slot]
        for slot in slots:
            struct.pack_into("<f", output, 104 + 4 * slot, values[name])
    return bytes(output)
