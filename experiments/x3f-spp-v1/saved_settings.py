"""读取经典 X3F 2.x 文件头中保存的显影参数，不改写源文件。"""

from dataclasses import asdict, dataclass
import math
from pathlib import Path
import struct


@dataclass(frozen=True)
class SavedSettings:
    width: int
    height: int
    rotation: int
    white_balance: str
    exposure: float = 0.0
    contrast: float = 0.0
    shadow: float = 0.0
    highlight: float = 0.0
    saturation: float = 0.0
    sharpness: float = 0.0
    fill_light: float = 0.0
    color_adjustment: tuple[float, float, float] = (1.0, 1.0, 1.0)
    unknown_adjustments: tuple[tuple[int, float], ...] = ()

    def to_dict(self):
        return asdict(self)


def parse_saved_settings(data: bytes) -> SavedSettings:
    if len(data) < 232 or data[:4] != b"FOVb":
        raise ValueError("Truncated or invalid X3F header")
    version = struct.unpack_from("<I", data, 4)[0]
    if version not in (0x00020001, 0x00020002):
        raise ValueError("Only the classic X3F 2.1/2.2 extended header is supported")
    width, height, rotation = struct.unpack_from("<III", data, 28)
    if not width or not height or width * height > 128_000_000:
        raise ValueError("Invalid image dimensions")
    if rotation not in (0, 90, 180, 270):
        raise ValueError("Invalid image rotation")
    try:
        wb = data[40:72].split(b"\0", 1)[0].decode("ascii")
    except UnicodeDecodeError as error:
        raise ValueError("Invalid white-balance name") from error
    if not wb:
        raise ValueError("Missing saved white balance")

    names = {1: "exposure", 2: "contrast", 3: "shadow", 4: "highlight",
             5: "saturation", 6: "sharpness", 10: "fill_light"}
    values = {}
    color = [0.0, 0.0, 0.0]
    unknown = []
    for index, kind in enumerate(data[72:104]):
        if kind == 0:
            continue
        value = struct.unpack_from("<f", data, 104 + 4 * index)[0]
        if not math.isfinite(value):
            raise ValueError("Nonfinite saved adjustment")
        if kind in names:
            values[names[kind]] = value
        elif kind in (7, 8, 9):
            color[kind - 7] = value
        elif value != 0:
            unknown.append((kind, value))

    # 未经 SPP 调整的文件使用全零槽位；其渲染含义是无颜色调整。
    if color == [0.0, 0.0, 0.0]:
        color = [1.0, 1.0, 1.0]
    elif any(value <= 0 for value in color):
        raise ValueError("Invalid saved color adjustment")
    return SavedSettings(width, height, rotation, wb,
                         color_adjustment=tuple(color), unknown_adjustments=tuple(unknown), **values)


def read_saved_settings(path: str | Path) -> SavedSettings:
    with Path(path).open("rb") as source:
        return parse_saved_settings(source.read(232))
