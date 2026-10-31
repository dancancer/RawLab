"""把派生 scene 数据绑定到原照片、解码版本与处理设置。"""

import hashlib
import json
from pathlib import Path
import subprocess
import numpy as np

DECODER_REVISION = "00f9ef206a2d629bca35ceead4b3951833b85d3d"


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _paths(prefix):
    return Path(str(prefix) + ".json"), Path(str(prefix) + ".f32")


def validate_metadata(meta, source, settings, expected_block=None):
    if meta.get("source_path") != str(Path(source).resolve()):
        raise ValueError("Scene source path differs from the requested RAW")
    if meta.get("decoder_revision") != DECODER_REVISION:
        raise ValueError("Unexpected scene decoder revision")
    if meta.get("denoise_intensity") != 10 or meta.get("denoise_backend") != "cpu" or meta.get("highlight_recovery") is not False:
        raise ValueError("Unexpected scene processing settings")
    if meta.get("saved_header_white_balance") != settings.white_balance:
        raise ValueError("Scene white balance differs from saved settings")
    if (meta.get("source_width"), meta.get("source_height")) != (settings.width, settings.height):
        raise ValueError("Scene source dimensions differ from the RAW header")
    block = meta.get("block")
    if not isinstance(block, int) or not 1 <= block <= 64 or (expected_block is not None and block != expected_block):
        raise ValueError("Unexpected scene reduction block")
    size = ((settings.width + block - 1) // block, (settings.height + block - 1) // block)
    if (meta.get("width"), meta.get("height")) != size:
        raise ValueError("Scene dimensions do not match the reduction grid")


def load_scene(source, prefix, settings, expected_block=None):
    metadata, pixels = _paths(prefix)
    meta = json.loads(metadata.read_text())
    validate_metadata(meta, source, settings, expected_block)
    if meta.get("source_sha256") != digest(source):
        raise ValueError("Scene source hash differs from the requested RAW")
    data = pixels.read_bytes()
    if meta.get("float_sha256") != hashlib.sha256(data).hexdigest():
        raise ValueError("Scene pixel hash differs from the recorded decoder output")
    if len(data) != meta["width"] * meta["height"] * 3 * 4:
        raise ValueError("Scene byte length does not match its dimensions")
    image = np.frombuffer(data, dtype="<f4").reshape(meta["height"], meta["width"], 3)
    if not np.all(np.isfinite(image)):
        raise ValueError("Nonfinite scene data")
    return image, meta


def decode_fresh(decoder, source, output, settings, block=1):
    source = Path(source).absolute()
    before = digest(source)
    subprocess.run([str(Path(decoder).resolve()), str(block), "10", "0", str(output), str(source)], check=True)
    prefix = Path(output) / source.stem
    metadata, pixels = _paths(prefix)
    meta = json.loads(metadata.read_text())
    validate_metadata(meta, source, settings, block)
    if digest(source) != before:
        raise ValueError("RAW changed while decoding")
    meta.update(source_sha256=before, float_sha256=digest(pixels), decoder_binary_sha256=digest(decoder))
    metadata.write_text(json.dumps(meta, indent=2) + "\n")
    return load_scene(source, prefix, settings, block)
