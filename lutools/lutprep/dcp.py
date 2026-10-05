"""D65-normalized DNG profile adaptation, not a full Adobe renderer.

HSV look and tone operations follow Adobe DNG SDK reference algorithms.
Copyright 2006-2023 Adobe Systems Incorporated (reference/profile algorithms).
Copyright 2006-2019 Adobe Systems Incorporated (spline algorithm).
All Rights Reserved.
Adobe permits use, modification, and distribution under the Adobe license
agreement in ../third_party/Adobe-DNG-SDK-LICENSE.txt (relative to lutprep/).
Reference: dng_reference.cpp, dng_spline.cpp, dng_camera_profile.cpp.
"""

from pathlib import Path
import struct

import numpy as np

from .color import SRGB_TO_XYZ, srgb_decode, srgb_encode


PROPHOTO_TO_XYZ = np.array([[.7976749, .1351917, .0313534],
                           [.2880402, .7118741, .0000857], [0., 0., .8252100]])
BRADFORD = np.array([[.8951, .2664, -.1614], [-.7502, 1.7135, .0367], [.0389, -.0685, 1.0296]])
D65, D50 = np.array([.95047, 1., 1.08883]), np.array([.96422, 1., .82521])
D65_TO_D50 = np.linalg.inv(BRADFORD) @ np.diag((BRADFORD @ D50) / (BRADFORD @ D65)) @ BRADFORD
SRGB_TO_PROPHOTO = np.linalg.solve(PROPHOTO_TO_XYZ, D65_TO_D50 @ SRGB_TO_XYZ)


def _read_tags(path):
    if path.stat().st_size > 128 * 1024 * 1024:
        raise ValueError("DCP exceeds the 128 MiB preparation limit")
    raw = path.read_bytes()
    if len(raw) < 8 or raw[:2] not in (b"II", b"MM"):
        raise ValueError("Invalid DCP byte order/header")
    order = "<" if raw[:2] == b"II" else ">"
    magic, start = struct.unpack_from(order + "HI", raw, 2)
    if magic not in (0x4352, 42) or start < 8 or start + 2 > len(raw):
        raise ValueError("Invalid DCP IFD offset")
    count = struct.unpack_from(order + "H", raw, start)[0]
    end = start + 2 + count * 12
    if count > 4096 or end + 4 > len(raw):
        raise ValueError("Truncated or excessive DCP IFD")
    if struct.unpack_from(order + "I", raw, end)[0] != 0:
        raise ValueError("Multiple DCP IFDs are unsupported")
    sizes = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8}
    types = {1: "u1", 3: "u2", 4: "u4", 6: "i1", 7: "u1", 8: "i2", 9: "i4", 11: "f4", 12: "f8"}
    tags = {}
    for index in range(count):
        offset = start + 2 + index * 12
        tag, kind, length = struct.unpack_from(order + "HHI", raw, offset)
        if tag in tags or kind not in sizes:
            raise ValueError("Duplicate DCP tag or unsupported TIFF type")
        size = length * sizes[kind]
        location = offset + 8 if size <= 4 else struct.unpack_from(order + "I", raw, offset + 8)[0]
        if location + size > len(raw):
            raise ValueError(f"Truncated DCP tag {tag}")
        if kind == 2:
            value = raw[location:location + size].rstrip(b"\0").decode("utf-8", errors="replace")
        elif kind in (5, 10):
            pairs = np.frombuffer(raw, dtype=order + ("u4" if kind == 5 else "i4"),
                                  count=length * 2, offset=location).reshape(-1, 2)
            if np.any(pairs[:, 1] == 0):
                raise ValueError(f"Zero denominator in DCP tag {tag}")
            value = pairs[:, 0] / pairs[:, 1]
        else:
            value = np.frombuffer(raw, dtype=order + types[kind], count=length, offset=location)
        tags[tag] = (kind, value)
    return tags


class ToneCurve:
    def __init__(self, points):
        try:
            points = np.asarray(points, dtype=np.float64)
        except (TypeError, ValueError) as error:
            raise ValueError("DCP tone curve requires numeric x/y pairs") from error
        if (points.ndim != 2 or points.shape[1] != 2 or not 2 <= len(points) <= 8192
                or not np.all(np.isfinite(points)) or np.any(points < 0) or np.any(points > 1)
                or np.any(np.diff(points[:, 0]) <= 0)):
            raise ValueError("DCP tone curve requires 2..8192 finite [0,1] points with increasing x")
        self.x, self.y = points.T
        h = np.diff(self.x)
        second = np.zeros(len(points))
        if len(points) > 2:
            diagonal = 2 * (h[:-1] + h[1:])
            rhs = 6 * np.diff(np.diff(self.y) / h)
            for j in range(1, len(diagonal)):
                ratio = h[j] / diagonal[j - 1]
                diagonal[j] -= ratio * h[j]
                rhs[j] -= ratio * rhs[j - 1]
            for j in range(len(diagonal) - 1, -1, -1):
                second[j + 1] = (rhs[j] - h[j + 1] * second[j + 2]) / diagonal[j]
        self.axis = np.linspace(0, 1, 4097)
        index = np.clip(np.searchsorted(self.x, self.axis) - 1, 0, len(h) - 1)
        width = h[index]
        a = (self.x[index + 1] - self.axis) / width
        b = (self.axis - self.x[index]) / width
        samples = (a * self.y[index] + b * self.y[index + 1] + width ** 2 / 6 *
                   ((a ** 3 - a) * second[index] + (b ** 3 - b) * second[index + 1]))
        self.samples = np.where(self.axis <= self.x[0], self.y[0],
                                np.where(self.axis >= self.x[-1], self.y[-1], samples))

    def evaluate(self, value):
        return np.interp(value, self.axis, self.samples)

    def apply(self, rgb):
        rgb = np.clip(rgb, 0, 1)
        lo, hi = rgb.min(axis=-1, keepdims=True), rgb.max(axis=-1, keepdims=True)
        fraction = np.divide(rgb - lo, hi - lo, out=np.zeros_like(rgb), where=hi != lo)
        lower = self.evaluate(lo)
        return lower + (self.evaluate(hi) - lower) * fraction


def _rgb_to_hsv(rgb):
    high, low = rgb.max(axis=-1), rgb.min(axis=-1)
    delta = high - low
    divisor = np.where(delta > 0, delta, 1)
    r, g, b = rgb.T
    hue = np.select([high == r, high == g], [(g - b) / divisor, 2 + (b - r) / divisor],
                    default=4 + (r - g) / divisor) % 6
    saturation = np.divide(delta, high, out=np.zeros_like(high), where=high > 0)
    return hue, saturation, high


def _hsv_to_rgb(hue, saturation, value):
    hue = hue % 6
    chroma = value * saturation
    x = chroma * (1 - np.abs(hue % 2 - 1))
    zero = np.zeros_like(x)
    sector = np.floor(hue).astype(int) % 6
    result = np.stack([np.choose(sector, [chroma, x, zero, zero, x, chroma]),
                       np.choose(sector, [x, chroma, chroma, x, zero, zero]),
                       np.choose(sector, [zero, zero, x, chroma, chroma, x])], axis=-1)
    return result + (value - chroma)[:, None]


def apply_look_table(rgb, table, encoding):
    shape = np.asarray(rgb).shape
    rgb = np.clip(np.asarray(rgb, dtype=np.float64).reshape(-1, 3), 0, 1)
    h, s, v = _rgb_to_hsv(rgb)
    values, hues, sats, _ = table.shape
    encoded_v = srgb_encode(v) if encoding == 1 else v
    hs, ss, vs = h * hues / 6, s * (sats - 1), encoded_v * (values - 1)
    h0 = np.minimum(hs.astype(int), hues - 1)
    s0 = np.minimum(ss.astype(int), sats - 2)
    v0 = np.minimum(vs.astype(int), max(0, values - 2))
    hf, sf, vf = hs - h0, ss - s0, vs - v0
    delta = np.zeros_like(rgb)
    for dh in (0, 1):
        for ds in (0, 1):
            for dv in (0, 1):
                weight = (hf if dh else 1 - hf) * (sf if ds else 1 - sf) * (vf if dv else 1 - vf)
                delta += weight[:, None] * table[np.minimum(v0 + dv, values - 1), (h0 + dh) % hues, s0 + ds]
    h += delta[:, 0] / 60
    s = np.clip(s * delta[:, 1], 0, 1)
    v = np.clip(encoded_v * delta[:, 2], 0, 1)
    if encoding == 1:
        v = srgb_decode(v)
    return _hsv_to_rgb(h, s, v).reshape(shape)


class DCPProfile:
    def __init__(self, tags, *, tone_curve=None, no_auto_black=False):
        self.tags = tags
        self.name = self._text(50936)
        self.source_model = self._text(50708)
        unsupported = set(tags) & {52525, 52539, 52543, 52544, 52551}
        if unsupported:
            raise ValueError(f"Unsupported DCP spatial/HDR/RGB-table stages: {sorted(unsupported)}")
        self.input_calibration_tags, self.input_to_prophoto = self._input_adapter()
        self.calibration_table, self.calibration_encoding, self.calibration_data_tag = None, 0, None
        if set(tags) & {50937, 50938, 50939, 51107, 52537}:
            if 52529 in tags or 52537 in tags:
                raise ValueError("Triple-illuminant HueSatMap interpolation is unsupported")
            if 50937 not in tags or 50938 not in tags:
                raise ValueError("DCP HueSatMap requires dimensions and Data1")
            selected = 50939 if 50939 in tags and self.input_calibration_tags[0] == 50779 else 50938
            for data_tag in (50938, 50939):
                if data_tag in tags:
                    table, encoding = self._hsv_table(50937, data_tag, 51107)
                    if data_tag == selected:
                        self.calibration_table, self.calibration_encoding = table, encoding
            self.calibration_data_tag = selected
        self.table, self.encoding = None, 0
        if set(tags) & {50981, 50982, 51108}:
            self.table, self.encoding = self._hsv_table(50981, 50982, 51108)
        if tone_curve is not None:
            if 50940 in tags:
                raise ValueError("External tone curve cannot replace an existing DCP tone curve")
            self.curve = ToneCurve(tone_curve)
            self.tone_source = "external"
        else:
            if 50940 not in tags:
                raise ValueError("DCP has no ProfileToneCurve; supply --tone-curve explicitly (Adobe renderer defaults are not inferred)")
            points = self._array(50940, 11)
            if len(points) % 2:
                raise ValueError("DCP tone curve requires x/y pairs")
            self.curve = ToneCurve(points.reshape(-1, 2))
            self.tone_source = "profile"
        black = self._scalar(51110, 4, 0)
        if black not in (0, 1):
            raise ValueError("Unsupported DCP default black rendering policy")
        if black == 0 and (self.calibration_table is not None or tone_curve is not None) and not no_auto_black:
            raise ValueError("This profile requires auto black rendering; choose --no-auto-black explicitly to omit it")
        self.black_render_policy = "none-profile" if black == 1 else "omitted-explicitly" if no_auto_black else "not-emulated"
        self.exposure = float(self._scalar(51109, 10, 0))
        if not np.isfinite(self.exposure) or abs(self.exposure) > 16:
            raise ValueError("DCP profile exposure must be finite and within +/-16 EV")

    def _hsv_table(self, dimensions_tag, data_tag, encoding_tag):
        dimensions = self._array(dimensions_tag, 4)
        if len(dimensions) not in (2, 3):
            raise ValueError("Invalid DCP look table dimensions")
        hues, sats, values = (*dimensions, 1) if len(dimensions) == 2 else dimensions
        hues, sats, values = int(hues), int(sats), int(values)
        if hues < 1 or sats < 2 or values < 1 or hues * sats * values > 4_000_000:
            raise ValueError("DCP look table dimensions exceed supported bounds")
        data = self._array(data_tag, 11)
        if data.size == hues * (sats - 1) * values * 3:
            table = np.zeros((values, hues, sats, 3))
            table[:, :, 1:] = data.reshape(values, hues, sats - 1, 3)
            table[:, :, 0] = table[:, :, 1]
        elif data.size == hues * sats * values * 3:
            table = data.reshape(values, hues, sats, 3).copy()
        else:
            raise ValueError("DCP look table data count does not match dimensions")
        if not np.all(np.isfinite(table)) or np.any(table[..., 1:] < 0):
            raise ValueError("DCP look table contains nonfinite or negative scale values")
        table[:, :, 0, 2] = 1
        encoding = int(self._scalar(encoding_tag, 4, 0))
        if encoding not in (0, 1) or (values == 1 and encoding == 1):
            raise ValueError("Unsupported DCP look table encoding (sRGB requires a value axis)")
        return table, encoding

    @classmethod
    def read(cls, path, *, tone_curve=None, no_auto_black=False):
        return cls(_read_tags(Path(path)), tone_curve=tone_curve, no_auto_black=no_auto_black)

    def _array(self, tag, kind):
        if tag not in self.tags or self.tags[tag][0] != kind:
            raise ValueError(f"Missing or incorrectly typed DCP tag {tag}")
        return np.asarray(self.tags[tag][1], dtype=np.float64)

    def _text(self, tag):
        if tag not in self.tags:
            return ""
        kind, value = self.tags[tag]
        if kind == 2:
            return value
        if kind == 1:
            return bytes(value).rstrip(b"\0").decode("utf-8", errors="replace")
        raise ValueError(f"DCP tag {tag} requires ASCII/BYTE text")

    def _scalar(self, tag, kind, default):
        if tag not in self.tags:
            return default
        value = self._array(tag, kind)
        if len(value) != 1:
            raise ValueError(f"DCP tag {tag} must contain one value")
        return value[0]

    def _input_adapter(self):
        pairs = [(50778, 50721, 50964), (50779, 50722, 50965), (52529, 52531, 52532)]
        matches = [pair for pair in pairs if self._scalar(pair[0], 3, 0) == 21]
        if len(matches) != 1:
            raise ValueError("DCP requires exactly one explicit D65 ColorMatrix/ForwardMatrix pair")
        illuminant, color_tag, forward_tag = matches[0]
        matrices = []
        for tag in (color_tag, forward_tag):
            values = self._array(tag, 10)
            if values.size != 9 or not np.all(np.isfinite(values)):
                raise ValueError(f"DCP calibration tag {tag} must be a finite 3x3 matrix")
            matrices.append(values.reshape(3, 3))
        color, forward = matrices
        if np.linalg.matrix_rank(color) != 3:
            raise ValueError("DCP ColorMatrix must be invertible")
        camera_white = color @ D65
        forward_white = forward @ np.ones(3)
        if np.any(camera_white <= 0) or np.any(forward_white <= 0):
            raise ValueError("DCP matrices must map their reference whites to positive channels")
        forward = np.diag((PROPHOTO_TO_XYZ @ np.ones(3)) / forward_white) @ forward
        # Reconstruct white-relative donor camera values from common XYZ, not target RAW channels.
        # Normalizing virtual camera values and its WB white by max(camera_white) cancels that scale.
        matrix = (np.linalg.inv(PROPHOTO_TO_XYZ) @ forward @ np.diag(1 / camera_white)
                  @ color @ SRGB_TO_XYZ)
        if not np.all(np.isfinite(matrix)):
            raise ValueError("DCP input adapter produced nonfinite values")
        return [illuminant, color_tag, forward_tag], matrix

    def describe(self):
        consumed = {50940, 50981, 50982, 51108, 51109, 51110, *self.input_calibration_tags}
        if self.calibration_data_tag is not None:
            consumed.update({50937, self.calibration_data_tag, 51107})
        metadata = {50708, 50932, 50936, 50941, 50942}
        def dimensions(table):
            return [table.shape[1], table.shape[2], table.shape[0]] if table is not None else None
        return {"format": "dcp", "canonical": False,
                "name": self.name, "source_model": self.source_model,
                "look_dimensions": dimensions(self.table),
                "hue_sat_map_dimensions": dimensions(self.calibration_table),
                "hue_sat_map_encoding": self.calibration_encoding,
                "hue_sat_map_data_tag": self.calibration_data_tag,
                "look_encoding": self.encoding, "tone_points": len(self.curve.x),
                "tone_source": self.tone_source, "black_render_policy": self.black_render_policy,
                "profile_exposure_ev": self.exposure,
                "input_adapter": "d65-white-relative-virtual-camera",
                "input_calibration_tags": self.input_calibration_tags,
                "excluded_tags": sorted(set(self.tags) - consumed - metadata),
                "scope": "D65-adapted profile appearance; target RAW calibration/WB unchanged; no Adobe rendering parity"}

    def evaluate(self, linear_srgb, apply_exposure=True):
        rgb = np.asarray(linear_srgb, dtype=np.float64)
        if rgb.ndim < 1 or rgb.shape[-1] != 3 or not np.all(np.isfinite(rgb)):
            raise ValueError("Expected finite linear-sRGB triples")
        rgb = rgb @ self.input_to_prophoto.T
        if self.calibration_table is not None:
            rgb = apply_look_table(rgb, self.calibration_table, self.calibration_encoding)
        if apply_exposure:
            rgb *= 2 ** self.exposure
        if self.table is not None:
            rgb = apply_look_table(rgb, self.table, self.encoding)
        rgb = self.curve.apply(rgb) @ np.linalg.inv(SRGB_TO_PROPHOTO).T
        return np.clip(srgb_encode(rgb), 0, 1)
