"""Versioned native DCP stages, without a baked RGB CUBE."""

import json
import os
from pathlib import Path
import struct
import tempfile

import numpy as np

from . import __version__
from .dcp import DCPProfile, SRGB_TO_PROPHOTO


HEADER = struct.Struct("<8s8I")
MAGIC = b"RLOOKDCP"
MAX_BYTES = 64 * 1024 * 1024
TONE_COUNT = 4097


def _cells(encoding, hues, sats, values, optional=True):
    if optional and (encoding, hues, sats, values) == (0, 0, 0, 0):
        return 0
    if (hues < 1 or sats < 2 or values < 1 or hues * sats * values > 4_000_000
            or encoding not in (0, 1) or (values == 1 and encoding == 1)):
        raise ValueError("Invalid native DCP table dimensions or encoding")
    return hues * sats * values


def _dimensions(table, encoding):
    return (encoding, table.shape[1], table.shape[2], table.shape[0]) if table is not None else (0, 0, 0, 0)


def _validate(stages):
    tone = stages["tone"]
    arrays = [tone, stages["input_matrix"], stages["output_matrix"]]
    cells = 0
    for key, encoding_key in [("table", "encoding"), ("calibration_table", "calibration_encoding")]:
        table, encoding = stages[key], stages[encoding_key]
        if table is None:
            if encoding != 0:
                raise ValueError("Absent native DCP table must use encoding zero")
            continue
        if table.ndim != 4 or table.shape[-1] != 3:
            raise ValueError("Invalid native DCP table shape")
        cells += _cells(*_dimensions(table, encoding))
        arrays.append(table)
        if np.any(table[..., 1:] < 0) or np.any(table[:, :, 0, 2] != 1):
            raise ValueError("Native DCP table requires nonnegative scales and normalized zero-saturation values")
    if cells > 4_000_000:
        raise ValueError("Combined native DCP tables exceed supported bounds")
    if any(not np.isfinite(a).all() or np.any(abs(a) > np.finfo(np.float32).max) for a in arrays):
        raise ValueError("Native DCP stages must be finite and within float32 magnitude")
    if tone.shape != (TONE_COUNT,) or any(stages[k].shape != (3, 3) for k in ("input_matrix", "output_matrix")):
        raise ValueError("Invalid native DCP matrix or tone sample count")
    if not np.isfinite(stages["exposure"]) or not 2 ** -16 <= stages["exposure"] <= 2 ** 16:
        raise ValueError("Invalid native DCP exposure multiplier")


def read_native(path):
    with Path(path).open("rb") as stream:
        raw = stream.read(MAX_BYTES + 1)
    if not HEADER.size <= len(raw) <= MAX_BYTES:
        raise ValueError("Truncated or oversized native DCP file")
    magic, version, flags, encoding, hues, sats, values, tone_count, metadata_size = HEADER.unpack_from(raw)
    if magic != MAGIC or version not in (1, 2) or flags != 0:
        raise ValueError("Unsupported native DCP header/version/flags")
    look_spec = (encoding, hues, sats, values)
    calibration_spec = (0, 0, 0, 0)
    start = HEADER.size
    if version == 2:
        if len(raw) < start + 16:
            raise ValueError("Truncated native DCP v2 header")
        calibration_spec = struct.unpack_from("<4I", raw, start)
        start += 16
    cells = _cells(*look_spec, optional=version == 2) + _cells(*calibration_spec)
    if cells > 4_000_000 or tone_count != TONE_COUNT or metadata_size > 65536:
        raise ValueError("Invalid native DCP dimensions or metadata size")
    expected = start + 19 * 8 + cells * 12 + TONE_COUNT * 8 + metadata_size
    if len(raw) != expected:
        raise ValueError("Native DCP payload length does not match header")
    matrix_values = np.frombuffer(raw, dtype="<f8", count=19, offset=start)
    offset = start + 19 * 8
    tables = []
    for spec in (calibration_spec, look_spec):
        count = _cells(*spec)
        tables.append(np.frombuffer(raw, dtype="<f4", count=count * 3, offset=offset)
                      .reshape(spec[3], spec[1], spec[2], 3) if count else None)
        offset += count * 12
    tone = np.frombuffer(raw, dtype="<f8", count=TONE_COUNT, offset=offset)
    metadata = json.loads(raw[offset + TONE_COUNT * 8:].decode("utf-8"))
    if not isinstance(metadata, dict):
        raise ValueError("Native DCP metadata must be a JSON object")
    result = {"input_matrix": matrix_values[:9].reshape(3, 3), "output_matrix": matrix_values[9:18].reshape(3, 3),
              "exposure": float(matrix_values[18]), "encoding": encoding, "table": tables[1],
              "calibration_encoding": calibration_spec[0], "calibration_table": tables[0],
              "tone": tone, "metadata": metadata}
    _validate(result)
    return result


def compile_dcp(source, destination, *, force=False, dcp_exposure=True, tone_curve=None, no_auto_black=False):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve() or (destination.exists() and os.path.samefile(source, destination)):
        raise ValueError("Source and destination must be different files")
    if source.suffix.lower() != ".dcp" or destination.suffix.lower() != ".rlook":
        raise ValueError("Native DCP compilation requires a .dcp source and .rlook destination")
    if destination.exists() and not force:
        raise FileExistsError(f"Destination exists: {destination}; use --force to replace it")
    profile = DCPProfile.read(source, tone_curve=tone_curve, no_auto_black=no_auto_black)
    stages = {"input_matrix": profile.input_to_prophoto, "output_matrix": np.linalg.inv(SRGB_TO_PROPHOTO),
              "exposure": 2 ** profile.exposure if dcp_exposure else 1., "encoding": profile.encoding,
              "table": profile.table, "tone": profile.curve.samples,
              "calibration_table": profile.calibration_table, "calibration_encoding": profile.calibration_encoding}
    _validate(stages)
    version = 2 if profile.calibration_table is not None or profile.table is None else 1
    report = {"version": __version__, "format_version": version, "mode": "native-dcp", "source": source.name,
              "rgb_cube_baked": False, "input": "scene-linear-srgb-d65", "output": "display-srgb",
              "evaluation": "CPU double reference; optional GPU float32",
              "dcp": {**profile.describe(), "apply_profile_exposure": dcp_exposure,
                      "exposure_method": "linear EV before look; not Adobe exposure-tone emulation"}}
    metadata = json.dumps(report, ensure_ascii=True, allow_nan=False, separators=(",", ":")).encode("utf-8")
    if len(metadata) > 65536:
        raise ValueError("Native DCP metadata exceeds 65536 bytes")
    header = HEADER.pack(MAGIC, version, 0, *_dimensions(profile.table, profile.encoding), TONE_COUNT, len(metadata))
    if version == 2:
        header += struct.pack("<4I", *_dimensions(profile.calibration_table, profile.calibration_encoding))
    descriptor, name = tempfile.mkstemp(prefix=".rawlab-dcp-", suffix=".rlook", dir=destination.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(header)
            for key in ("input_matrix", "output_matrix"):
                stream.write(np.asarray(stages[key], dtype="<f8").tobytes())
            stream.write(struct.pack("<d", stages["exposure"]))
            for table in (profile.calibration_table, profile.table):
                if table is not None:
                    stream.write(np.asarray(table, dtype="<f4").tobytes())
            stream.write(np.asarray(profile.curve.samples, dtype="<f8").tobytes())
            stream.write(metadata)
        if force:
            os.replace(temporary, destination)
        else:
            os.link(temporary, destination)
        return report
    finally:
        temporary.unlink(missing_ok=True)
