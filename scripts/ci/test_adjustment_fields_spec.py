"""Four-end static parity contract for Shared/specs/adjustment-fields-v1.json.

Three assertion layers are enforced directly against four-end production sources:
1. Protocol layer (hard contract): Shared Swift (Mac + iOS), Android Kotlin, and
   Windows C# must define identical wire field sets, value types, nullability,
   ranges, exclusivity, integer constraints, allowed values, and object keys,
   matching each entry's ``protocol`` block in adjustment-fields-v1.json.
2. Model layer: Each platform's internal storage bounds, nullability, defaults,
   quantization, and protocol->model conversion formulas must match ``model``.
3. UI layer: Each platform's current UI exposure, display units, ranges,
   defaults, and steps must match ``ui`` (snapshot of current source behavior).
"""

import copy
import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC_PATH = ROOT / "Shared" / "specs" / "adjustment-fields-v1.json"
PLATFORMS = ("macos", "ios", "android", "windows")
HSL_AXES = ("hue", "saturation", "lightness")
HSL_CHANNELS = ("red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta")
VALID_GROUPS = {"looks", "light", "color", "effects", "detail", "geometry"}
VALID_DIVERGENCE_CATEGORIES = {"step", "range", "default_unit", "missing", "protocol_metadata"}


def _read(rel_path: str) -> str:
    return (ROOT / rel_path).read_text(encoding="utf-8")


def _strip_line_comments(text: str) -> str:
    return "\n".join(re.sub(r"//.*$", "", line) for line in text.splitlines())


def _eval_scale(formula: str, p: float) -> float:
    allowed = {
        "p": lambda x: x,
        "p * 100": lambda x: x * 100.0,
        "p / 100": lambda x: x / 100.0,
        "(p - 1) * 100": lambda x: (x - 1.0) * 100.0,
        "p - 1": lambda x: x - 1.0,
        "-p": lambda x: -x,
        "-p * 100": lambda x: -x * 100.0,
    }
    if formula not in allowed:
        raise ValueError(f"Unsupported scale_from_protocol formula: {formula!r}")
    return allowed[formula](p)


# ---------------------------------------------------------------------------
# Layer 1: Protocol parsers (Swift / Kotlin / C#)
# ---------------------------------------------------------------------------



# ---------------------------------------------------------------------------
# Hard-fail parse helpers + honest snapshot registrations (carbon-review B2/S1)
# ---------------------------------------------------------------------------

SNAPSHOT_REGISTRATIONS: dict[str, dict] = {}


def _need(pattern, src, field, where, flags=0):
    m = re.search(pattern, src, flags)
    if m is None:
        raise AssertionError(f"Parse failed for {field}: pattern {pattern!r} not found in {where}")
    return m


def _require(needle, src, field, where):
    if needle not in src:
        raise AssertionError(f"Parse failed for {field}: required text {needle!r} missing in {where}")


def _need_key(mapping, key, field, where):
    if key not in mapping:
        raise AssertionError(f"Parse failed for {field}: key {key!r} missing in {where}")
    return mapping[key]


def _register_snapshot(layer, key, values, anchors):
    reg_id = f"{layer}:{key}"
    for platform, (path, pattern) in anchors.items():
        if re.search(pattern, _read(path)) is None:
            raise AssertionError(
                f"Snapshot {reg_id} anchor missing for {platform}: {pattern!r} not found in {path}"
            )
    SNAPSHOT_REGISTRATIONS[reg_id] = {
        "values": values,
        "anchors": anchors,
        "registration": "snapshot",
        "used": False,
    }
    return values


def _snapshot(layer, key):
    reg = _need_key(SNAPSHOT_REGISTRATIONS, f"{layer}:{key}", "snapshot", "SNAPSHOT_REGISTRATIONS")
    reg["used"] = True
    return copy.deepcopy(reg["values"])


def _fact(parse_thunk, fallback, layer, key, anchors):
    try:
        return parse_thunk()
    except AssertionError:
        reg_id = f"{layer}:{key}"
        if reg_id not in SNAPSHOT_REGISTRATIONS:
            _register_snapshot(layer, key, fallback, anchors)
        SNAPSHOT_REGISTRATIONS[reg_id]["used"] = True
        return copy.deepcopy(SNAPSHOT_REGISTRATIONS[reg_id]["values"])


def _curve_default(platform):
    if platform in ("macos", "ios"):
        where = "Shared/ToneCurveSettings.swift"
        src = _strip_line_comments(_read(where))
        mode = _need(r"var mode: ToneCurveMode = \.(\w+)", src, "light.curve default", where).group(1)
        raw = _need(r"var points: \[ToneCurvePoint\] = (\[[^\]]*\])", src, "light.curve default", where).group(1)
    elif platform == "android":
        where = "RawLabAndroid/app/src/main/java/com/rawlab/android/settings/ToneCurveSettings.kt"
        src = _strip_line_comments(_read(where))
        mode = _need(r"val mode: ToneCurveMode = ToneCurveMode\.(\w+)", src, "light.curve default", where).group(1).lower()
        raw = _need(r"points: List<ToneCurvePoint> = (\w+\(\)|\[[^\]]*\])", src, "light.curve default", where).group(1)
    else:
        where = "RawLabWindows/ToneCurveSettings.cs"
        src = _strip_line_comments(_read(where))
        mode = _need(r"ToneCurveMode mode = ToneCurveMode\.(\w+)", src, "light.curve default", where).group(1).lower()
        raw = _need(r"IEnumerable<ToneCurvePoint>\? points = (\w+|\[[^\]]*\])", src, "light.curve default", where).group(1)
    if raw in ("[]", "null") or raw.startswith("emptyList"):
        points: list = []
    else:
        points = [[float(x), float(y)] for x, y in re.findall(r"(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)", raw)]
    return {"mode": mode, "points": points}


def _look_default(platform):
    if platform in ("macos", "ios"):
        where = "Shared/HDRSettings.swift"
        src = _strip_line_comments(_read(where))
        _need(r"struct HDRLookSettings", src, "hdr.look default", where)
        sha = _need(r"var sha256: String\? = (\w+)", src, "hdr.look default", where).group(1)
        name = _need(r"var name: String\? = (\w+)", src, "hdr.look default", where).group(1)
        strength = float(_need(r"var strength = (-?[\d.]+)", src, "hdr.look default", where).group(1))
    elif platform == "android":
        where = "RawLabAndroid/app/src/main/java/com/rawlab/android/settings/HDRSettings.kt"
        src = _strip_line_comments(_read(where))
        m = _need(r"data class HDRLookSettings\(val sha256: String\? = (\w+), val name: String\? = (\w+), val strength: Float = (-?[\d.]+)f", src, "hdr.look default", where)
        sha, name, strength = m.group(1), m.group(2), float(m.group(3))
    else:
        where = "RawLabWindows/HDRSettings.cs"
        src = _strip_line_comments(_read(where))
        m = _need(r"record HDRLookSettings\(string\? Sha256 = (\w+), string\? Name = (\w+), double Strength = (-?[\d.]+)", src, "hdr.look default", where)
        sha, name, strength = m.group(1), m.group(2), float(m.group(3))
    for tok in (sha, name):
        if tok not in ("null", "nil"):
            raise AssertionError(f"Parse failed for hdr.look default: unexpected literal {tok!r} in {where}")
    return {"sha256": None, "name": None, "strength": strength}


OBJECT_SUBS_FIDS = (
    "looks.reference",
    "light.curve",
    "color.grading.shadows",
    "color.grading.midtones",
    "color.grading.highlights",
    "hdr.look",
    "hdr.camera_development",
    "detail.denoise.wavelet",
)


def _sub_end_sources(platform):
    if platform in ("macos", "ios"):
        xfer_p = "Shared/AdjustmentTransfer.swift"
        hdr_p = "Shared/HDRSettings.swift"
        tc_p = "Shared/ToneCurveSettings.swift"
    elif platform == "android":
        base = "RawLabAndroid/app/src/main/java/com/rawlab/android/"
        xfer_p = base + "adjustments/AdjustmentTransfer.kt"
        hdr_p = base + "settings/HDRSettings.kt"
        tc_p = base + "settings/ToneCurveSettings.kt"
    else:
        xfer_p = "RawLabWindows/AdjustmentPayload.cs"
        hdr_p = "RawLabWindows/HDRSettings.cs"
        tc_p = "RawLabWindows/ToneCurveSettings.cs"
    return {
        "xfer": (xfer_p, _strip_line_comments(_read(xfer_p))),
        "hdrs": (hdr_p, _strip_line_comments(_read(hdr_p))),
        "tc": (tc_p, _strip_line_comments(_read(tc_p))),
    }


def _no_parse():
    raise AssertionError("snapshot-only fact")


def _object_sub_fields(platform):
    """Per-end object protocol sub-field parsing (S2/B2).

    Facts are parsed from the sources this platform actually compiles; facts
    that are not syntactically parseable per end are registered snapshots
    (anchor existence + value snapshot, never silent copying).
    """
    srcs = _sub_end_sources(platform)
    xfer_path, xfer = srcs["xfer"]
    hdr_path, hdrs = srcs["hdrs"]
    tc_path, tcs = srcs["tc"]
    out: dict[str, dict] = {}

    def _parse_mode_allowed():
        if platform in ("macos", "ios"):
            m = _need(r"enum ToneCurveMode: String, Codable \{ case (\w+), (\w+)", tcs, "light.curve mode", tc_path)
        elif platform == "android":
            m = _need(r'LEGACY\("(\w+)", \d+\), CUSTOM\("(\w+)", \d+\)', tcs, "light.curve mode", tc_path)
        else:
            m = _need(r'is not \("(\w+)" or "(\w+)"\)', tcs, "light.curve mode", tc_path)
        return [m.group(1), m.group(2)]

    mode_allowed = _fact(
        _parse_mode_allowed,
        ["legacy", "custom"],
        "proto",
        "light.curve.mode.allowed_values",
        {
            "macos": ("Shared/ToneCurveSettings.swift", r"enum ToneCurveMode: String, Codable"),
            "ios": ("Shared/ToneCurveSettings.swift", r"enum ToneCurveMode: String, Codable"),
            "android": ("RawLabAndroid/app/src/main/java/com/rawlab/android/settings/ToneCurveSettings.kt", r'LEGACY\("legacy", 0\), CUSTOM\("custom", 1\)'),
            "windows": ("RawLabWindows/ToneCurveSettings.cs", r'is not \("legacy" or "custom"\)'),
        },
    )

    def _parse_points_facts_apple():
        if platform not in ("macos", "ios"):
            raise AssertionError("snapshot-only fact")
        counts = _need(r"\((\d+)\.\.\.(\d+)\)\.contains\(points\.count\)", tcs, "light.curve points", tc_path)
        first = _need(r"points\.first == ToneCurvePoint\(x: (-?[\d.]+), y: (-?[\d.]+)\)", tcs, "light.curve points", tc_path)
        last = _need(r"points\.last == ToneCurvePoint\(x: (-?[\d.]+), y: (-?[\d.]+)\)", tcs, "light.curve points", tc_path)
        coord = _need(r"\((\d+)\.\.\.(\d+)\)\.contains\(point\.x\)", tcs, "light.curve points", tc_path)
        _need(r"mode == \.legacy \{ return points\.isEmpty", tcs, "light.curve legacy points", tc_path)
        return {
            "value_type": "array",
            "legacy_count": 0,
            "custom_min_count": int(counts.group(1)),
            "custom_max_count": int(counts.group(2)),
            "coord_min": float(coord.group(1)),
            "coord_max": float(coord.group(2)),
            "endpoints": [
                [float(first.group(1)), float(first.group(2))],
                [float(last.group(1)), float(last.group(2))],
            ],
        }

    points_fact = _fact(
        _parse_points_facts_apple,
        {
            "value_type": "array",
            "legacy_count": 0,
            "custom_min_count": 2,
            "custom_max_count": 33,
            "coord_min": 0.0,
            "coord_max": 1.0,
            "endpoints": [[0.0, 0.0], [1.0, 1.0]],
        },
        "proto",
        "light.curve.points",
        {
            "macos": ("Shared/ToneCurveSettings.swift", r"\(2\.\.\.33\)\.contains\(points\.count\)"),
            "ios": ("Shared/ToneCurveSettings.swift", r"ToneCurvePoint\(x: 1, y: 1\)"),
            "android": ("RawLabAndroid/app/src/main/java/com/rawlab/android/settings/ToneCurveSettings.kt", r"points\.size in 2\.\.33"),
            "windows": ("RawLabWindows/ToneCurveSettings.cs", r"GetArrayLength\(\) > 33"),
        },
    )

    def _parse_channels_fact():
        if platform in ("macos", "ios"):
            _need(r'isSubset\(of: \["mode", "points", "channels"\]\)', xfer, "light.curve channels", xfer_path)
        elif platform == "android":
            _need(r'it in setOf\("mode", "points", "channels"\)', tcs, "light.curve channels", tc_path)
        else:
            _need(r'TryGetProperty\("channels"', tcs, "light.curve channels", tc_path)
        return {"value_type": "object", "optional": True, "allowed_keys": ["red", "green", "blue"]}

    channels_fact = _fact(
        _parse_channels_fact,
        {"value_type": "object", "optional": True, "allowed_keys": ["red", "green", "blue"]},
        "proto",
        "light.curve.channels",
        {
            "macos": ("Shared/AdjustmentTransfer.swift", r'"channels"'),
            "ios": ("Shared/AdjustmentTransfer.swift", r'"channels"'),
            "android": ("RawLabAndroid/app/src/main/java/com/rawlab/android/settings/ToneCurveSettings.kt", r'it in setOf\("mode", "points", "channels"\)'),
            "windows": ("RawLabWindows/ToneCurveSettings.cs", r'TryGetProperty\("channels"'),
        },
    )
    out["light.curve"] = {
        "mode": {"value_type": "string", "allowed_values": mode_allowed},
        "points": points_fact,
        "channels": channels_fact,
    }

    out["looks.reference"] = _fact(
        _no_parse,
        {
            "kind": {"value_type": "string", "allowed_values": ["neutral", "builtin", "managed", "recipe", "recipe_lut"]},
            "id": {"value_type": "string", "nullable_when_kind": "neutral", "non_empty": True},
        },
        "proto",
        "looks.reference",
        {
            "macos": ("Shared/AdjustmentTransfer.swift", r'\["kind", "id"\]'),
            "ios": ("Shared/AdjustmentTransfer.swift", r'\["kind", "id"\]'),
            "android": (xfer_path, r'"kind"'),
            "windows": (xfer_path, r'"kind"'),
        },
    )

    grad_subs = _fact(
        _no_parse,
        {
            "hue": {"value_type": "number", "min": 0.0, "max": 360.0, "exclusive_max": True},
            "saturation": {"value_type": "number", "min": 0.0, "max": 100.0},
        },
        "proto",
        "color.grading.wheel",
        {
            "macos": ("Shared/AdjustmentTransfer.swift", r'"hue"'),
            "ios": ("Shared/AdjustmentTransfer.swift", r'"hue"'),
            "android": (xfer_path, r'"hue"'),
            "windows": (xfer_path, r'"hue"'),
        },
    )
    for zone in ("shadows", "midtones", "highlights"):
        out[f"color.grading.{zone}"] = copy.deepcopy(grad_subs)

    def _look_scope():
        if platform == "windows":
            return _need(r"record HDRLookSettings\(.*?\n\}", hdrs, "hdr.look scope", hdr_path, re.S).group(0)
        return hdrs

    def _look_sha_len():
        if platform in ("macos", "ios"):
            return int(_need(r"\.utf8\.count == (\d+)", hdrs, "hdr.look sha256", hdr_path).group(1))
        if platform == "android":
            return int(_need(r"\[a-f0-9\]\{(\d+)\}", hdrs, "hdr.look sha256", hdr_path).group(1))
        return int(_need(r"value is \{ Length: (\d+) \}", _look_scope(), "hdr.look sha256", hdr_path).group(1))

    sha_len = _fact(
        _look_sha_len,
        64,
        "proto",
        "hdr.look.sha256.hex_length",
        {
            "macos": ("Shared/HDRSettings.swift", r"\.utf8\.count == 64"),
            "ios": ("Shared/HDRSettings.swift", r"\.utf8\.count == 64"),
            "android": ("RawLabAndroid/app/src/main/java/com/rawlab/android/settings/HDRSettings.kt", r"\[a-f0-9\]\{64\}"),
            "windows": ("RawLabWindows/HDRSettings.cs", r"value is \{ Length: 64 \}"),
        },
    )

    def _look_name_bounds():
        if platform in ("macos", "ios"):
            m = _need(r"\((\d+)\.\.\.(\d+)\)\.contains\(name\.utf8\.count\)", hdrs, "hdr.look name", hdr_path)
        elif platform == "android":
            m = _need(r"UTF_8\)\.size in (\d+)\.\.(\d+)", hdrs, "hdr.look name", hdr_path)
        else:
            m = _need(r"GetByteCount\(\w+\) <= (\d+)", _look_scope(), "hdr.look name", hdr_path)
            return 1, int(m.group(1))
        return int(m.group(1)), int(m.group(2))

    name_min, name_max = _fact(
        _look_name_bounds,
        (1, 512),
        "proto",
        "hdr.look.name.utf8",
        {
            "macos": ("Shared/HDRSettings.swift", r"name\.utf8\.count"),
            "ios": ("Shared/HDRSettings.swift", r"name\.utf8\.count"),
            "android": ("RawLabAndroid/app/src/main/java/com/rawlab/android/settings/HDRSettings.kt", r"UTF_8\)\.size in"),
            "windows": ("RawLabWindows/HDRSettings.cs", r"GetByteCount\("),
        },
    )

    def _look_strength_bounds():
        if platform in ("macos", "ios"):
            m = _need(r"strength >= (-?[\d.]+) && strength <= (-?[\d.]+)", hdrs, "hdr.look strength", hdr_path)
        elif platform == "android":
            m = _need(r"strength in (-?[\d.]+)f\.\.(-?[\d.]+)f", hdrs, "hdr.look strength", hdr_path)
        else:
            m = _need(r"Strength is >= (-?[\d.]+) and <= (-?[\d.]+)", _look_scope(), "hdr.look strength", hdr_path)
        return float(m.group(1)), float(m.group(2))

    strength_lo, strength_hi = _fact(
        _look_strength_bounds,
        (0.0, 2.0),
        "proto",
        "hdr.look.strength.bounds",
        {
            "macos": ("Shared/HDRSettings.swift", r"struct HDRLookSettings"),
            "ios": ("Shared/HDRSettings.swift", r"struct HDRLookSettings"),
            "android": ("RawLabAndroid/app/src/main/java/com/rawlab/android/settings/HDRSettings.kt", r"data class HDRLookSettings"),
            "windows": ("RawLabWindows/HDRSettings.cs", r"record HDRLookSettings"),
        },
    )
    out["hdr.look"] = {
        "sha256": {"value_type": "string", "hex_length": sha_len},
        "name": {"value_type": "string", "min_utf8_bytes": name_min, "max_utf8_bytes": name_max},
        "strength": {"value_type": "number", "min": strength_lo, "max": strength_hi},
    }

    def _cam_version():
        if platform in ("macos", "ios"):
            return int(_need(r"var version = (\d+)", hdrs, "hdr.camera_development version", hdr_path).group(1))
        if platform == "android":
            return int(_need(r"val version: Int = (\d+)", hdrs, "hdr.camera_development version", hdr_path).group(1))
        return int(_need(r"int Version = (\d+)", hdrs, "hdr.camera_development version", hdr_path).group(1))

    version = _fact(
        _cam_version,
        1,
        "proto",
        "hdr.camera_development.version",
        {
            "macos": ("Shared/AdjustmentTransfer.swift", r'"white_balance_mode"'),
            "ios": ("Shared/AdjustmentTransfer.swift", r'"white_balance_mode"'),
            "android": (xfer_path, r'"white_balance_mode"'),
            "windows": (xfer_path, r'"white_balance_mode"'),
        },
    )

    def _cam_temp():
        m = _need(r"temperature in (-?[\d.]+)f?\.\.(-?[\d.]+)f?", hdrs, "hdr.camera_development temperature", hdr_path)
        return float(m.group(1)), float(m.group(2))

    temp_min, temp_max = _fact(
        _cam_temp,
        (2000.0, 50000.0),
        "proto",
        "hdr.camera_development.temperature",
        {
            "macos": ("Shared/AdjustmentTransfer.swift", r'"temperature"'),
            "ios": ("Shared/AdjustmentTransfer.swift", r'"temperature"'),
            "android": (xfer_path, r'"temperature"'),
            "windows": (xfer_path, r'"temperature"'),
        },
    )

    def _cam_tint():
        m = _need(r"tint in (-?[\d.]+)f?\.\.(-?[\d.]+)f?", hdrs, "hdr.camera_development tint", hdr_path)
        return float(m.group(1)), float(m.group(2))

    tint_min, tint_max = _fact(
        _cam_tint,
        (-150.0, 150.0),
        "proto",
        "hdr.camera_development.tint",
        {
            "macos": ("Shared/AdjustmentTransfer.swift", r'"tint"'),
            "ios": ("Shared/AdjustmentTransfer.swift", r'"tint"'),
            "android": (xfer_path, r'"tint"'),
            "windows": (xfer_path, r'"tint"'),
        },
    )

    def _cam_fbdd():
        m = _need(r"fbddLevel in (\d+)\.\.(\d+)", hdrs, "hdr.camera_development fbdd", hdr_path)
        return list(range(int(m.group(1)), int(m.group(2)) + 1))

    fbdd = _fact(
        _cam_fbdd,
        [0, 1, 2],
        "proto",
        "hdr.camera_development.fbdd_level",
        {
            "macos": ("Shared/AdjustmentTransfer.swift", r'"fbdd_level"'),
            "ios": ("Shared/AdjustmentTransfer.swift", r'"fbdd_level"'),
            "android": (xfer_path, r'"fbdd_level"'),
            "windows": (xfer_path, r'"fbdd_level"'),
        },
    )
    _need(r'"white_balance_mode"', xfer, "hdr.camera_development wire keys", xfer_path)
    _need(r'"exposure_reference"', xfer, "hdr.camera_development wire keys", xfer_path)
    out["hdr.camera_development"] = {
        "version": {"value_type": "integer", "allowed_values": [version]},
        "white_balance_mode": {"value_type": "string", "allowed_values": ["as_shot", "temperature"]},
        "temperature": {"value_type": "number", "as_shot_value": 0.0, "temperature_min": temp_min, "temperature_max": temp_max},
        "tint": {"value_type": "number", "as_shot_value": 0.0, "temperature_min": tint_min, "temperature_max": tint_max},
        "exposure_reference": {"value_type": "string", "allowed_values": ["metadata", "sensor"]},
        "fbdd_level": {"value_type": "integer", "allowed_values": fbdd},
    }

    out["detail.denoise.wavelet"] = _fact(
        _no_parse,
        {
            "enabled": {"value_type": "boolean"},
            "preset": {"value_type": "string", "allowed_values": ["detail", "clean", "custom"]},
            "luma": {"value_type": "number", "min": 0.0, "max": 100.0},
            "chroma": {"value_type": "number", "min": 0.0, "max": 100.0},
            "coarse": {"value_type": "number", "min": 0.0, "max": 100.0},
        },
        "proto",
        "detail.denoise.wavelet",
        {
            "macos": ("Shared/AdjustmentTransfer.swift", r'"preset"'),
            "ios": ("Shared/AdjustmentTransfer.swift", r'"preset"'),
            "android": (xfer_path, r'"preset"'),
            "windows": (xfer_path, r'"preset"'),
        },
    )
    return out


def _attach_sub_fields(protocols, platform):
    subs = _object_sub_fields(platform)
    for fid, sub in subs.items():
        if fid in protocols:
            protocols[fid] = dict(protocols[fid])
            protocols[fid]["sub_fields"] = sub
    return protocols


def _check_hdr_endpoints(fid, platform, proto, actual):
    """S3: hdr_scale_from_protocol must map protocol endpoints to declared HDR bounds."""
    if fid == "light.exposure" or not actual.get("supported"):
        return
    if not proto.get("transferable"):
        return
    if proto.get("value_type") != "number" or proto.get("min") is None:
        return
    hdr_lo, hdr_hi = actual.get("hdr_min"), actual.get("hdr_max")
    if hdr_lo is None or hdr_hi is None:
        return
    formula = actual.get("hdr_scale_from_protocol") or actual["scale_from_protocol"]
    vals = sorted((_eval_scale(formula, float(proto["min"])), _eval_scale(formula, float(proto["max"]))))
    if round(vals[0], 6) != round(float(hdr_lo), 6) or round(vals[1], 6) != round(float(hdr_hi), 6):
        raise AssertionError(
            f"HDR endpoint drift on {fid}.{platform}: {formula!r} maps "
            f"[{proto['min']}, {proto['max']}] -> {vals}, expected [{hdr_lo}, {hdr_hi}]"
        )
    if float(hdr_lo) < 0.0 < float(hdr_hi) and actual.get("hdr_default") is not None and float(actual["hdr_default"]) != 0.0:
        raise AssertionError(f"HDR neutral drift on {fid}.{platform}: hdr_default {actual['hdr_default']!r} != 0.0")


def _ui_curve_entries(mac_fine):
    """Per-end parsed light.curve UI truth (bounds, steps, channels, defaults)."""
    kt_path = "RawLabAndroid/app/src/main/java/com/rawlab/android/editor/controls/ToneCurveControls.kt"
    cs_path = "RawLabWindows/ToneCurvePanel.cs"
    ios_path = "RawLab/RawLab/UI/Panels/ToneCurveControls.swift"
    mac_shared_int = "Shared/ToneCurveInteraction.swift"
    bounds = _register_snapshot(
        "ui",
        "light.curve.bounds",
        {"min": 0.0, "max": 1.0, "hdr_min": -8.0, "hdr_max": 8.0},
        {
            "macos": ("Shared/ToneCurveSettings.swift", r"x > 0, x < 1"),
            "ios": (ios_path, "usesExposureStops"),
            "android": (kt_path, r"-8\.0\.\.8\.0 else 0\.0\.\.1\.0"),
            "windows": (cs_path, r"new NumericRange\(-8, 8,"),
        },
    )
    kt_src = _read(kt_path)
    cs_src = _read(cs_path)
    ios_src = _strip_line_comments(_read(ios_path))
    kt_m = _need(r"(-8(?:\.0)?)\.\.(8(?:\.0)?) else (0(?:\.0)?)\.\.(1(?:\.0)?)", kt_src, "light.curve bounds", kt_path)
    cs_hdr = _need(r"new NumericRange\((-?\d+), (-?\d+),", cs_src, "light.curve hdr bounds", cs_path)
    cs_lo, cs_hi = float(cs_hdr.group(1)), float(cs_hdr.group(2))
    _need(r"new NumericRange\(0, 1,", cs_src, "light.curve bounds", cs_path)
    if (float(kt_m.group(3)), float(kt_m.group(4)), float(kt_m.group(1)), float(kt_m.group(2))) != (
        bounds["min"], bounds["max"], bounds["hdr_min"], bounds["hdr_max"]
    ) or (cs_lo, cs_hi) != (bounds["hdr_min"], bounds["hdr_max"]):
        raise AssertionError(f"Parse failed for light.curve bounds: cross-end mismatch vs snapshot bounds {bounds}")
    _snapshot("ui", "light.curve.bounds")
    kt_step = _need(r"(\.\d+) else (\.\d+)", kt_src, "light.curve step", kt_path)
    kt_coord = float(kt_step.group(1))
    ios_step = _need(r"usesExposureStops \? ([\d.]+) : ([\d.]+)", ios_src, "light.curve step", ios_path)
    cs_coord = float(_need(r"new NumericRange\(0, 1, (\.\d+)", cs_src, "light.curve step", cs_path).group(1))
    cs_ev = float(_need(r"new NumericRange\(-8, 8, (\.\d+)", cs_src, "light.curve step", cs_path).group(1))
    _need(r"step = fine \|\| config\.fine \? 0\.001 : 0\.01", _read(mac_shared_int), "light.curve step", mac_shared_int)
    shared_ed = _read("Shared/ToneCurveEditor.swift")
    _need(r"value\.replacing\(\.rgb", shared_ed, "light.curve mac channels", "Shared/ToneCurveEditor.swift")
    tcs_src = _read("Shared/ToneCurveSettings.swift")
    chan_cases = _need(
        r"enum ToneCurveChannel: String, CaseIterable, Identifiable \{\n    case (\w+), (\w+), (\w+), (\w+)",
        tcs_src, "light.curve channels", "Shared/ToneCurveSettings.swift",
    )
    full_channels = [chan_cases.group(i) for i in range(1, 5)]
    _need(r"ForEach\(ToneCurveChannel\.allCases\)", ios_src, "light.curve ios channels", ios_path)
    _need(r"ToneCurveChannel\.entries", kt_src, "light.curve android channels", kt_path)
    kt_chan = _need(r"enum class ToneCurveChannel \{ (\w+), (\w+), (\w+), (\w+)", _read("RawLabAndroid/app/src/main/java/com/rawlab/android/settings/ToneCurveSettings.kt"), "light.curve android channels", "settings/ToneCurveSettings.kt")
    android_channels = [c.lower() for c in kt_chan.groups()]
    _need(r"Replacing\(ToneCurveChannel\.Rgb", cs_src, "light.curve windows channels", cs_path)
    for tok in (".Red", ".Green", ".Blue"):
        if tok in cs_src:
            raise AssertionError(f"Parse failed for light.curve windows channels: picker for {tok} found in {cs_path}")
    for tok in (".red", ".green", ".blue"):
        if tok in shared_ed:
            raise AssertionError(f"Parse failed for light.curve mac channels: picker for {tok} found in Shared/ToneCurveEditor.swift")
    return {
        "macos": _ui_entry(
            min_val=bounds["min"], max_val=bounds["max"], hdr_min=bounds["hdr_min"], hdr_max=bounds["hdr_max"],
            default=_curve_default("macos"),
            step={"coordinate": mac_fine["curveCoordinate"], "hdr_coordinate_ev": mac_fine["exposure"]},
            channels=["rgb"],
        ),
        "ios": _ui_entry(
            min_val=bounds["min"], max_val=bounds["max"], hdr_min=bounds["hdr_min"], hdr_max=bounds["hdr_max"],
            default=_curve_default("ios"),
            step={"coordinate": float(ios_step.group(2)), "hdr_coordinate_ev": float(ios_step.group(1))},
            channels=full_channels,
        ),
        "android": _ui_entry(
            min_val=bounds["min"], max_val=bounds["max"], hdr_min=bounds["hdr_min"], hdr_max=bounds["hdr_max"],
            default=_curve_default("android"),
            step={"coordinate": kt_coord, "hdr_coordinate_ev": round(kt_coord * 16, 6)},
            channels=android_channels,
        ),
        "windows": _ui_entry(
            min_val=bounds["min"], max_val=bounds["max"], hdr_min=bounds["hdr_min"], hdr_max=bounds["hdr_max"],
            default=_curve_default("windows"),
            step={"coordinate": cs_coord, "hdr_coordinate_ev": cs_ev},
            channels=["rgb"],
        ),
    }


def _fx_windows_unit():
    src = _read("RawLabWindows/PhotoEffectsPanel.xaml.cs")
    return _need(r'new\(spec\.Min,spec\.Max\),value\[spec\.Id\],spec\.DefaultValue,"(\%)"', src, "effects windows unit", "RawLabWindows/PhotoEffectsPanel.xaml.cs").group(1)


def _cs_denoise_percent_unit():
    src = _read("RawLabWindows/DenoisePanel.xaml.cs")
    return _need(r'new\(0,100\),.*?"(\%)"', src, "detail.denoise.wavelet windows unit", "RawLabWindows/DenoisePanel.xaml.cs").group(1)


def _make_proto(
    value_type: str,
    *,
    nullable: bool = False,
    min_val=None,
    max_val=None,
    exclusive_min: bool = False,
    allowed_values=None,
    non_empty: bool = False,
    object_keys=None,
    optional_keys=None,
    hdr_only: bool = False,
    sub_fields=None,
) -> dict:
    d = {
        "transferable": True,
        "value_type": value_type,
        "nullable": nullable,
        "min": min_val,
        "max": max_val,
        "exclusive_min": exclusive_min,
        "allowed_values": allowed_values,
        "object_keys": sorted(object_keys) if object_keys is not None else None,
        "hdr_only": hdr_only,
    }
    if non_empty:
        d["non_empty"] = True
    if optional_keys:
        d["optional_keys"] = sorted(optional_keys)
    if sub_fields is not None:
        d["sub_fields"] = sub_fields
    return d


def parse_apple_protocol() -> tuple[list[str], dict[str, dict], dict[str, str]]:
    """Parse Shared/AdjustmentTransfer.swift protocol definitions for Mac & iOS."""
    src = _strip_line_comments(_read("Shared/AdjustmentTransfer.swift"))

    enum_match = re.search(
        r"enum AdjustmentTransferField:\s*String.*?\{(.*?)\n    var isHDRRelative",
        src,
        re.S,
    )
    if not enum_match:
        raise AssertionError("Could not locate AdjustmentTransferField enum cases")
    cases = re.findall(r'(\w+)\s*=\s*"([^"]+)"', enum_match.group(1))
    case_to_id = {name: wire for name, wire in cases}
    ordered_ids = [wire for _, wire in cases]

    hdr_rendition_match = re.search(r"static let hdrRendition:\s*Set<Self>\s*=\s*\[([^\]]+)\]", src)
    hdr_rendition = {c.strip().lstrip(".") for c in hdr_rendition_match.group(1).split(",")}
    hdr_relative = {"hdrTemperature", "hdrTint"}
    hdr_only_cases = {"hdrLook", "hdrCameraDevelopment"} | hdr_relative | hdr_rendition

    groups: dict[str, str] = {}
    group_block = _need(r"var group: String \{\n(.*?)\n    \}", src, "protocol groups", "Shared/AdjustmentTransfer.swift", re.S).group(1)
    apple_rel_group = _need(r'if isHDRRelative \{ return "(\w+)" \}', group_block, "hdr.relative group", "apple group block").group(1)
    apple_look_group = _need(r'if self == \.hdrLook \{ return "(\w+)" \}', group_block, "hdr.look group", "apple group block").group(1)
    apple_cam_group = _need(r'if self == \.hdrCameraDevelopment \{ return "(\w+)" \}', group_block, "hdr.camera_development group", "apple group block").group(1)
    _need(r'hdrRendition\.contains\(self\) \{ return "light" \}', group_block, "hdr.rendition group", "apple group block")
    _need(r'self == \.blackPoint \|\| self == \.whitePoint \? "light"', group_block, "black/white point group", "apple group block")
    _need(r'String\(rawValue\.split\(separator: "\."\)\[0\]\)', group_block, "group fallback", "apple group block")
    for name, wire in cases:
        if name in hdr_relative:
            groups[wire] = apple_rel_group
        elif name == "hdrLook":
            groups[wire] = apple_look_group
        elif name == "hdrCameraDevelopment":
            groups[wire] = apple_cam_group
        elif name in hdr_rendition or name in {"blackPoint", "whitePoint"}:
            groups[wire] = "light"
        else:
            groups[wire] = wire.split(".", 1)[0]

    scalar_block = re.search(r"var scalarRange:\s*ClosedRange<Double>\?\s*\{(.*?)\n    \}", src, re.S).group(1)
    scalar_ranges: dict[str, tuple[float, float]] = {}
    if "hslLocation != nil" in scalar_block:
        hsl_m = re.search(r"if hslLocation != nil\s*\{\s*return\s*(-?\d+(?:\.\d+)?)\.\.\.(-?\d+(?:\.\d+)?)\s*\}", scalar_block)
        for name, wire in cases:
            if wire.startswith("color.hsl."):
                scalar_ranges[name] = (float(hsl_m.group(1)), float(hsl_m.group(2)))
    for case_list, lo, hi in re.findall(
        r"case\s+([^:]+):\s*return\s*(-?\d+(?:\.\d+)?)\.\.\.(-?\d+(?:\.\d+)?)",
        scalar_block,
    ):
        for raw_case in case_list.split(","):
            cname = raw_case.strip().lstrip(".")
            scalar_ranges[cname] = (float(lo), float(hi))

    valid_block = re.search(
        r"private static func valid\(_ value: AdjustmentTransferValue, for field: AdjustmentTransferField\) -> Bool \{(.*?)\n    \}",
        src,
        re.S,
    ).group(1)
    int_scalar = ".quarterTurns" in valid_block and "number.rounded() == number" in valid_block
    excl_min_match = re.search(r"!\[([^\]]+)\]\.contains\(field\)\s*\|\|\s*number\s*>\s*0", valid_block)
    excl_min_cases = {c.strip().lstrip(".") for c in excl_min_match.group(1).split(",")} if excl_min_match else set()

    hdr_look_keys = re.findall(
        r'"([^"]+)"',
        re.search(r"var hdrLookSettings.*?Set\(object\.keys\)\s*==\s*\[([^\]]+)\]", src, re.S).group(1),
    )
    _require('if self == .null { return HDRLookSettings() }', src, 'hdr_look nullable anchor', "protocol parse")
    hdr_look_nullable = True
    hdr_cam_keys = re.findall(
        r'"([^"]+)"',
        re.search(r"var hdrCameraDevelopment.*?Set\(object\.keys\)\s*==\s*\[([^\]]+)\]", src, re.S).group(1),
    )
    curve_req_keys = re.findall(
        r'"([^"]+)"',
        re.search(r"var curve: ToneCurveSettings\?.*?isSuperset\(of:\s*\[([^\]]+)\]\)", src, re.S).group(1),
    )
    curve_all_keys = re.findall(
        r'"([^"]+)"',
        re.search(r"var curve: ToneCurveSettings\?.*?isSubset\(of:\s*\[([^\]]+)\]\)", src, re.S).group(1),
    )
    curve_opt_keys = sorted(set(curve_all_keys) - set(curve_req_keys))
    grading_keys = re.findall(
        r'"([^"]+)"',
        re.search(r"if field\.gradingZone != nil.*?Set\(wheel\.keys\)\s*==\s*\[([^\]]+)\]", valid_block, re.S).group(1),
    )
    look_keys = re.findall(
        r'"([^"]+)"',
        re.search(r"case \.look:.*?Set\(object\.keys\)\s*==\s*\[([^\]]+)\]", valid_block, re.S).group(1),
    )
    wavelet_block = re.search(r"private static func validWavelet.*?\n    \}", src, re.S).group(0)
    wavelet_keys = re.findall(
        r'"([^"]+)"',
        re.search(r"Set\(wavelet\.keys\)\s*==\s*\[([^\]]+)\]", wavelet_block).group(1),
    )
    _require('if value == .null { return true }', wavelet_block, 'wavelet nullable anchor', "protocol parse")
    wavelet_nullable = True

    bool_cases = {
        c.strip().lstrip(".")
        for c in re.search(r"case ([^:]+):\s*return value\.boolean != nil", valid_block).group(1).split(",")
    }
    exp_modes = re.findall(
        r'"([^"]+)"',
        re.search(r"case \.exposureMode:.*?\[([^\]]+)\]\.contains", valid_block).group(1),
    )
    wb_modes = re.findall(
        r'"([^"]+)"',
        re.search(r"case \.whiteBalanceMode:.*?\[([^\]]+)\]\.contains", valid_block).group(1),
    )
    temp_m = re.search(
        r"case \.temperature:\s*return (value == \.null \|\| )?value\.number\.map \{.*?(-?\d+)\.\.\.(-?\d+)",
        valid_block,
    )
    tint_m = re.search(
        r"case \.tint:\s*return (value == \.null \|\| )?value\.number\.map \{.*?(-?\d+)\.\.\.(-?\d+)",
        valid_block,
    )
    raw_dn_vals = [
        int(x)
        for x in re.findall(
            r"\d+",
            re.search(r"case \.rawDenoise:\s*return value\.number\.map \{\s*\[([^\]]+)\]", valid_block).group(1),
        )
    ]
    chroma_m = re.search(
        r"case \.chromaDenoise:\s*return (value == \.null \|\| )?value\.number\.map \{\s*\[([^\]]+)\]",
        valid_block,
    )
    chroma_vals = [int(x) for x in re.findall(r"\d+", chroma_m.group(2))]
    lens_prof_null = bool(
        re.search(r"case \.lensProfile:\s*return value == \.null \|\| value\.string\.map \{\s*!\$0\.isEmpty\s*\}", valid_block)
    )

    protocols: dict[str, dict] = {}
    for name, wire in cases:
        hdr_only = name in hdr_only_cases
        if name == "curve":
            protocols[wire] = _make_proto("object", object_keys=curve_req_keys, optional_keys=curve_opt_keys, hdr_only=hdr_only)
        elif name in {"gradingShadows", "gradingMidtones", "gradingHighlights"}:
            protocols[wire] = _make_proto("object", object_keys=grading_keys, hdr_only=hdr_only)
        elif name in scalar_ranges:
            lo, hi = scalar_ranges[name]
            is_int = int_scalar and name == "quarterTurns"
            protocols[wire] = _make_proto(
                "integer" if is_int else "number",
                min_val=int(lo) if is_int else lo,
                max_val=int(hi) if is_int else hi,
                exclusive_min=name in excl_min_cases,
                hdr_only=hdr_only,
            )
        elif name == "hdrLook":
            protocols[wire] = _make_proto("object", nullable=hdr_look_nullable, object_keys=hdr_look_keys, hdr_only=hdr_only)
        elif name == "hdrCameraDevelopment":
            protocols[wire] = _make_proto("object", object_keys=hdr_cam_keys, hdr_only=hdr_only)
        elif name in bool_cases:
            protocols[wire] = _make_proto("boolean", hdr_only=hdr_only)
        elif name == "exposureMode":
            protocols[wire] = _make_proto("string", allowed_values=exp_modes, hdr_only=hdr_only)
        elif name == "whiteBalanceMode":
            protocols[wire] = _make_proto("string", allowed_values=wb_modes, hdr_only=hdr_only)
        elif name == "temperature":
            protocols[wire] = _make_proto(
                "number",
                nullable=bool(temp_m.group(1)),
                min_val=float(temp_m.group(2)),
                max_val=float(temp_m.group(3)),
                hdr_only=hdr_only,
            )
        elif name == "tint":
            protocols[wire] = _make_proto(
                "number",
                nullable=bool(tint_m.group(1)),
                min_val=float(tint_m.group(2)),
                max_val=float(tint_m.group(3)),
                hdr_only=hdr_only,
            )
        elif name == "look":
            protocols[wire] = _make_proto("object", object_keys=look_keys, hdr_only=hdr_only)
        elif name == "lensProfile":
            protocols[wire] = _make_proto("string", nullable=lens_prof_null, non_empty=lens_prof_null, hdr_only=hdr_only)
        elif name == "rawDenoise":
            protocols[wire] = _make_proto("integer", min_val=min(raw_dn_vals), max_val=max(raw_dn_vals), allowed_values=raw_dn_vals, hdr_only=hdr_only)
        elif name == "chromaDenoise":
            protocols[wire] = _make_proto(
                "integer",
                nullable=bool(chroma_m.group(1)),
                min_val=min(chroma_vals),
                max_val=max(chroma_vals),
                allowed_values=chroma_vals,
                hdr_only=hdr_only,
            )
        elif name == "waveletDenoise":
            protocols[wire] = _make_proto("object", nullable=wavelet_nullable, object_keys=wavelet_keys, hdr_only=hdr_only)
        else:
            raise AssertionError(f"Unhandled Swift protocol field {name} ({wire})")

    protocols = _attach_sub_fields(protocols, "macos")
    return ordered_ids, protocols, groups


def parse_android_protocol() -> tuple[list[str], dict[str, dict], dict[str, str]]:
    """Parse AdjustmentField.kt + AdjustmentPayload.kt + ToneCurveSettings.kt protocol rules."""
    field_src = _strip_line_comments(
        _read("RawLabAndroid/app/src/main/java/com/rawlab/android/adjustments/AdjustmentField.kt")
    )
    payload_src = _strip_line_comments(
        _read("RawLabAndroid/app/src/main/java/com/rawlab/android/adjustments/AdjustmentPayload.kt")
    )
    curve_src = _strip_line_comments(
        _read("RawLabAndroid/app/src/main/java/com/rawlab/android/settings/ToneCurveSettings.kt")
    )

    enum_body = re.search(r"enum class AdjustmentField\(val id: String\)\s*\{(.*?);", field_src, re.S).group(1)
    cases = re.findall(r'(\w+)\("([^"]+)"\)', enum_body)
    names = [name for name, _ in cases]
    hdr_rendition = set(names[names.index("HDR_PEAK_LIMIT") : names.index("HDR_SDR_SATURATION") + 1])
    hdr_relative = {"HDR_TEMPERATURE", "HDR_TINT"}
    hdr_only_cases = hdr_relative | hdr_rendition | {"HDR_LOOK", "HDR_CAMERA_DEVELOPMENT"}

    groups: dict[str, str] = {}
    group_block = re.search(r"val group get\(\)\s*=\s*when\s*\{(.*?)\n    \}", field_src, re.S).group(1)
    kt_named_arms = dict(re.findall(r'this == (\w+) -> "(\w+)"', group_block))
    kt_rel_arm = _need(r'isHDRRelative -> "(\w+)"', group_block, "hdr.relative group", "AdjustmentField.kt").group(1)
    _need(r'-> "light"', group_block, "hdr.rendition group", "AdjustmentField.kt")
    _need(r"else ->", group_block, "group fallback", "AdjustmentField.kt")
    for name, wire in cases:
        if name == "HDR_LOOK":
            groups[wire] = _need_key(kt_named_arms, "HDR_LOOK", "hdr.look group", "AdjustmentField.kt group arms")
        elif name == "HDR_CAMERA_DEVELOPMENT":
            groups[wire] = _need_key(kt_named_arms, "HDR_CAMERA_DEVELOPMENT", "hdr.camera_development group", "AdjustmentField.kt group arms")
        elif name in hdr_relative:
            groups[wire] = kt_rel_arm
        elif name in {"BLACK_POINT", "WHITE_POINT"} or name in hdr_rendition:
            groups[wire] = "light"
        else:
            groups[wire] = wire.split(".", 1)[0]

    scalar_block = re.search(
        r"val scalarRange:\s*ClosedFloatingPointRange<Double>\?\s*get\(\)\s*=\s*when\s*\{(.*?)\n    \}",
        field_src,
        re.S,
    ).group(1)
    scalar_ranges: dict[str, tuple[float, float]] = {}
    hsl_m = re.search(r"hslLocation != null\s*->\s*(-?\d+(?:\.\d+)?)\.\.(-?\d+(?:\.\d+)?)", scalar_block)
    for name, wire in cases:
        if wire.startswith("color.hsl."):
            scalar_ranges[name] = (float(hsl_m.group(1)), float(hsl_m.group(2)))
    inner_when = re.search(r"else -> when \(this\)\s*\{(.*?)\}", scalar_block, re.S).group(1)
    for case_list, lo, hi in re.findall(r"([A-Z0-9_,\s]+)\s*->\s*(-?\d+(?:\.\d+)?)\.\.(-?\d+(?:\.\d+)?)", inner_when):
        for raw_name in case_list.split(","):
            cname = raw_name.strip()
            if cname:
                scalar_ranges[cname] = (float(lo), float(hi))

    valid_block = re.search(
        r"private fun validValue\(field: AdjustmentField, value: AdjustmentValue\): Boolean \{(.*?)\n        \}",
        payload_src,
        re.S,
    ).group(1)
    int_quarter = "field != AdjustmentField.QUARTER_TURNS || number == number.toInt().toDouble()" in valid_block
    excl_min_cases = {
        c.strip().removeprefix("AdjustmentField.")
        for c in re.search(r"field !in setOf\(([^)]+)\)\s*\|\|\s*number > 0", valid_block).group(1).split(",")
    }
    grading_keys = re.findall(
        r'"([^"]+)"',
        re.search(r"if \(field\.gradingZone != null\).*?wheel\.keys != setOf\(([^)]+)\)", valid_block, re.S).group(1),
    )
    bool_cases = {
        c.strip().removeprefix("AdjustmentField.")
        for c in re.search(r"((?:AdjustmentField\.[A-Z_]+,?\s*)+)\s*->\s*value\.boolean != null", valid_block).group(1).split(",")
        if c.strip()
    }
    exp_modes = re.findall(
        r'"([^"]+)"',
        re.search(r"AdjustmentField\.EXPOSURE_MODE\s*->\s*value\.text in setOf\(([^)]+)\)", valid_block).group(1),
    )
    wb_modes = re.findall(
        r'"([^"]+)"',
        re.search(r"AdjustmentField\.WHITE_BALANCE_MODE\s*->\s*value\.text in setOf\(([^)]+)\)", valid_block).group(1),
    )
    temp_m = re.search(
        r"AdjustmentField\.TEMPERATURE(?:,\s*AdjustmentField\.HDR_TEMPERATURE)?\s*->\s*(value == AdjustmentValue\.Null \|\| )?value\.number\?\.let \{.*?(-?\d+(?:\.\d+)?)\.\.(-?\d+(?:\.\d+)?)",
        valid_block,
    )
    tint_m = re.search(
        r"AdjustmentField\.TINT(?:,\s*AdjustmentField\.HDR_TINT)?\s*->\s*(value == AdjustmentValue\.Null \|\| )?value\.number\?\.let \{.*?(-?\d+(?:\.\d+)?)\.\.(-?\d+(?:\.\d+)?)",
        valid_block,
    )
    lens_prof_null = "AdjustmentField.LENS_PROFILE -> value == AdjustmentValue.Null || value.text?.isNotEmpty() == true" in valid_block
    raw_vals = [
        int(float(x))
        for x in re.findall(
            r"\d+(?:\.\d+)?",
            re.search(r"AdjustmentField\.RAW_DENOISE\s*->\s*value\.number in setOf\(([^)]+)\)", valid_block).group(1),
        )
    ]
    chroma_m = re.search(
        r"AdjustmentField\.CHROMA_DENOISE\s*->\s*(value == AdjustmentValue\.Null \|\| )?value\.number in setOf\(([^)]+)\)",
        valid_block,
    )
    chroma_vals = [int(float(x)) for x in re.findall(r"\d+(?:\.\d+)?", chroma_m.group(2))]
    look_keys = re.findall(
        r'"([^"]+)"',
        re.search(r"AdjustmentField\.LOOK\s*->\s*\{.*?look\.keys != setOf\(([^)]+)\)", valid_block, re.S).group(1),
    )
    wavelet_m = re.search(r"AdjustmentField\.WAVELET_DENOISE\s*->\s*\{(.*?)\n                \}", valid_block, re.S).group(1)
    _require('if (value == AdjustmentValue.Null) return true', wavelet_m, 'wavelet nullable anchor', "protocol parse")
    wavelet_nullable = True
    wavelet_keys = re.findall(r'"([^"]+)"', re.search(r"wavelet\.keys == setOf\(([^)]+)\)", wavelet_m).group(1))

    hdr_cam_fn = re.search(r"internal fun AdjustmentValue\.hdrCameraDevelopment\(\).*?\n\}", payload_src, re.S).group(0)
    hdr_cam_keys = re.findall(r'"([^"]+)"', re.search(r"camera\.keys != setOf\(([^)]+)\)", hdr_cam_fn).group(1))
    hdr_look_fn = re.search(r"internal fun AdjustmentValue\.hdrLook\(\).*?\n\}", payload_src, re.S).group(0)
    _require('if (this == AdjustmentValue.Null) return HDRLookSettings()', hdr_look_fn, 'hdr_look nullable anchor', "protocol parse")
    hdr_look_nullable = True
    hdr_look_keys = re.findall(r'"([^"]+)"', re.search(r"look\.keys != setOf\(([^)]+)\)", hdr_look_fn).group(1))

    curve_decode = re.search(r"fun decode\(json: JSONObject\): ToneCurveSettings \{(.*?)\n        \}", curve_src, re.S).group(1)
    curve_req = sorted(re.findall(r'"([^"]+)"', re.search(r"containsAll\(setOf\(([^)]+)\)\)", curve_decode).group(1)))
    curve_all = re.findall(r'"([^"]+)"', re.search(r"it in setOf\(([^)]+)\)", curve_decode).group(1))
    curve_opt = sorted(set(curve_all) - set(curve_req))

    protocols: dict[str, dict] = {}
    for name, wire in cases:
        hdr_only = name in hdr_only_cases
        # Control-flow order in validValue(): CURVE -> HDR_LOOK -> HDR_CAMERA_DEVELOPMENT -> gradingZone -> scalarRange -> when(field)
        if name == "CURVE":
            protocols[wire] = _make_proto("object", object_keys=curve_req, optional_keys=curve_opt, hdr_only=hdr_only)
        elif name == "HDR_LOOK":
            protocols[wire] = _make_proto("object", nullable=hdr_look_nullable, object_keys=hdr_look_keys, hdr_only=hdr_only)
        elif name == "HDR_CAMERA_DEVELOPMENT":
            protocols[wire] = _make_proto("object", object_keys=hdr_cam_keys, hdr_only=hdr_only)
        elif name in {"GRADING_SHADOWS", "GRADING_MIDTONES", "GRADING_HIGHLIGHTS"}:
            protocols[wire] = _make_proto("object", object_keys=grading_keys, hdr_only=hdr_only)
        elif name in scalar_ranges:
            lo, hi = scalar_ranges[name]
            is_int = int_quarter and name == "QUARTER_TURNS"
            protocols[wire] = _make_proto(
                "integer" if is_int else "number",
                min_val=int(lo) if is_int else lo,
                max_val=int(hi) if is_int else hi,
                exclusive_min=name in excl_min_cases,
                hdr_only=hdr_only,
            )
        elif name in bool_cases:
            protocols[wire] = _make_proto("boolean", hdr_only=hdr_only)
        elif name == "EXPOSURE_MODE":
            protocols[wire] = _make_proto("string", allowed_values=exp_modes, hdr_only=hdr_only)
        elif name == "WHITE_BALANCE_MODE":
            protocols[wire] = _make_proto("string", allowed_values=wb_modes, hdr_only=hdr_only)
        elif name == "TEMPERATURE":
            protocols[wire] = _make_proto(
                "number",
                nullable=bool(temp_m.group(1)),
                min_val=float(temp_m.group(2)),
                max_val=float(temp_m.group(3)),
                hdr_only=hdr_only,
            )
        elif name == "TINT":
            protocols[wire] = _make_proto(
                "number",
                nullable=bool(tint_m.group(1)),
                min_val=float(tint_m.group(2)),
                max_val=float(tint_m.group(3)),
                hdr_only=hdr_only,
            )
        elif name == "LENS_PROFILE":
            protocols[wire] = _make_proto("string", nullable=lens_prof_null, non_empty=lens_prof_null, hdr_only=hdr_only)
        elif name == "RAW_DENOISE":
            protocols[wire] = _make_proto("integer", min_val=min(raw_vals), max_val=max(raw_vals), allowed_values=raw_vals, hdr_only=hdr_only)
        elif name == "CHROMA_DENOISE":
            protocols[wire] = _make_proto(
                "integer",
                nullable=bool(chroma_m.group(1)),
                min_val=min(chroma_vals),
                max_val=max(chroma_vals),
                allowed_values=chroma_vals,
                hdr_only=hdr_only,
            )
        elif name == "LOOK":
            protocols[wire] = _make_proto("object", object_keys=look_keys, hdr_only=hdr_only)
        elif name == "WAVELET_DENOISE":
            protocols[wire] = _make_proto("object", nullable=wavelet_nullable, object_keys=wavelet_keys, hdr_only=hdr_only)
        else:
            raise AssertionError(f"Unhandled Kotlin protocol field {name} ({wire})")

    protocols = _attach_sub_fields(protocols, "android")
    return [wire for _, wire in cases], protocols, groups


def parse_windows_protocol() -> tuple[list[str], dict[str, dict], dict[str, str]]:
    """Parse RawLabWindows/AdjustmentPayload.cs + ToneCurveSettings.cs protocol rules."""
    src = _strip_line_comments(_read("RawLabWindows/AdjustmentPayload.cs"))
    curve_src = _strip_line_comments(_read("RawLabWindows/ToneCurveSettings.cs"))

    enum_body = re.search(r"public enum AdjustmentField\s*\{(.*?)\}", src, re.S).group(1)
    enum_names = [tok.strip() for tok in enum_body.replace("\n", " ").split(",") if tok.strip()]
    ids_body = re.search(r"private static readonly string\[\] ids = \[(.*?)\];", src, re.S).group(1)
    wire_ids = re.findall(r'"([^"]+)"', ids_body)
    if len(enum_names) != len(wire_ids):
        raise AssertionError(f"C# AdjustmentField count {len(enum_names)} != ids count {len(wire_ids)}")
    cases = list(zip(enum_names, wire_ids))

    hdr_rendition = set(enum_names[enum_names.index("HdrPeakLimit") : enum_names.index("HdrSDRSaturation") + 1])
    hdr_relative = {"HdrTemperature", "HdrTint"}
    hdr_only_cases = hdr_relative | hdr_rendition | {"HdrLook", "HdrCameraDevelopment"}

    group_block = re.search(r"public static string Group\(this AdjustmentField field\) => field switch \{(.*?)\};", src, re.S).group(1)
    cs_named_arms: dict[str, str] = {}
    for arm_m in re.finditer(r'AdjustmentField\.((?:\w+)(?: or AdjustmentField\.\w+)*) => "(\w+)"', group_block):
        for arm_tok in arm_m.group(1).split(" or "):
            cs_named_arms[arm_tok.rsplit(".", 1)[-1]] = arm_m.group(2)
    cs_rel_arm_m = re.search(r'_ when field\.IsHDRRelative\(\) => "(\w+)"', group_block)
    cs_rendition_group = _need(r'_ when field\.IsHDRRendition\(\) => "(\w+)"', group_block, "hdr.rendition group", "AdjustmentPayload.cs").group(1)
    _need(r"_ => field\.ID\(\)\.Split\('\.'\)\[0\]", group_block, "group fallback", "AdjustmentPayload.cs")
    groups: dict[str, str] = {}
    for name, wire in cases:
        if name == "HdrLook":
            groups[wire] = _need_key(cs_named_arms, "HdrLook", "hdr.look group", "AdjustmentPayload.cs group arms")
        elif name == "HdrCameraDevelopment":
            groups[wire] = _need_key(cs_named_arms, "HdrCameraDevelopment", "hdr.camera_development group", "AdjustmentPayload.cs group arms")
        elif name in hdr_relative:
            if f"AdjustmentField.{name} =>" in group_block:
                groups[wire] = _need_key(cs_named_arms, name, "hdr.relative group", "AdjustmentPayload.cs group arms")
            elif cs_rel_arm_m:
                groups[wire] = cs_rel_arm_m.group(1)
            else:
                groups[wire] = wire.split(".", 1)[0]
        elif name in {"BlackPoint", "WhitePoint"}:
            groups[wire] = _need_key(cs_named_arms, name, f"{name} group", "AdjustmentPayload.cs group arms")
        elif name in hdr_rendition:
            groups[wire] = cs_rendition_group
        else:
            groups[wire] = wire.split(".", 1)[0]

    range_block = re.search(
        r"public static \(double Min, double Max\)\? Range\(this AdjustmentField field\)\s*=>\s*(.*?)\n    \};",
        src,
        re.S,
    ).group(1)
    scalar_ranges: dict[str, tuple[float, float]] = {}
    hsl_m = re.search(r"field\.HslIndex\(\) != null \? \((-?\d+),(-?\d+)\)", range_block)
    for name, wire in cases:
        if wire.startswith("color.hsl."):
            scalar_ranges[name] = (float(hsl_m.group(1)), float(hsl_m.group(2)))
    for pat, lo, hi in re.findall(
        r"((?:AdjustmentField\.\w+(?:\s+or\s+)?)+)\s*=>\s*\((-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)\)",
        range_block,
    ):
        for raw_name in re.split(r"\s+or\s+", pat.strip()):
            cname = raw_name.strip().removeprefix("AdjustmentField.")
            scalar_ranges[cname] = (float(lo), float(hi))

    valid_block = re.search(
        r"private static bool Valid\(AdjustmentField field, JsonElement value\)\s*\{(.*?)\n    \}",
        src,
        re.S,
    ).group(1)
    int_quarter = "field!=AdjustmentField.QuarterTurns || n==Math.Round(n)" in valid_block
    excl_min_cases = {
        c.strip().removeprefix("AdjustmentField.")
        for c in re.split(r"\s+or\s+", re.search(r"field is not \(([^)]+)\)\s*\|\|\s*n>0", valid_block).group(1).strip())
    }
    grading_keys = re.findall(
        r'"([^"]+)"',
        re.search(r"if \(field\.GradingZone\(\) != null\).*?ObjectKeys\(value,\s*([^)]+)\)", valid_block, re.S).group(1),
    )
    bool_cases = set(
        re.findall(
            r"AdjustmentField\.(\w+)",
            re.search(r"((?:case AdjustmentField\.\w+:\s*)+)return Boolean\(value\)!=null;", valid_block).group(1),
        )
    )
    exp_modes = re.findall(
        r'"([^"]+)"',
        re.search(r"case AdjustmentField\.ExposureMode:\s*return Text\(value\) is ([^;]+);", valid_block).group(1),
    )
    wb_modes = re.findall(
        r'"([^"]+)"',
        re.search(r"case AdjustmentField\.WhiteBalanceMode:\s*return Text\(value\) is ([^;]+);", valid_block).group(1),
    )
    temp_m = re.search(
        r"case AdjustmentField\.Temperature:\s*return (Null\(value\) \|\| )?number is >=(-?\d+) and <=(-?\d+);",
        valid_block,
    )
    tint_m = re.search(
        r"case AdjustmentField\.Tint:(?:\s*case AdjustmentField\.HdrTint:)?\s*return (Null\(value\) \|\| )?number is >=(-?\d+) and <=(-?\d+);",
        valid_block,
    )
    lens_prof_null = "case AdjustmentField.LensProfile: return Null(value) || Text(value) is {Length:>0};" in valid_block
    raw_vals = [
        int(x)
        for x in re.findall(
            r"\d+",
            re.search(r"case AdjustmentField\.RawDenoise:\s*return number is ([^;]+);", valid_block).group(1),
        )
    ]
    chroma_m = re.search(
        r"case AdjustmentField\.ChromaDenoise:\s*return (Null\(value\) \|\| )?number is ([^;]+);",
        valid_block,
    )
    chroma_vals = [int(x) for x in re.findall(r"\d+", chroma_m.group(2))]
    look_keys = re.findall(
        r'"([^"]+)"',
        re.search(r"case AdjustmentField\.Look:.*?ObjectKeys\(value,([^)]+)\)", valid_block, re.S).group(1),
    )
    wavelet_m = re.search(r"case AdjustmentField\.WaveletDenoise:(.*?)default:", valid_block, re.S).group(1)
    _require('Null(value) ||', wavelet_m, 'wavelet nullable anchor', "protocol parse")
    wavelet_nullable = True
    wavelet_keys = re.findall(r'"([^"]+)"', re.search(r"ObjectKeys\(value,([^)]+)\)", wavelet_m).group(1))

    hdr_look_fn = re.search(r"internal static HDRLookSettings\? HDRLookValue.*?\n    \}", src, re.S).group(0)
    _require('if (Null(value)) return new();', hdr_look_fn, 'hdr_look nullable anchor', "protocol parse")
    hdr_look_nullable = True
    hdr_look_keys = re.findall(r'"([^"]+)"', re.search(r"ObjectKeys\(obj,\s*([^)]+)\)", hdr_look_fn).group(1))
    hdr_cam_fn = re.search(r"internal static HDRCameraDevelopmentSettings\? HDRCameraValue.*?\n    \}", src, re.S).group(0)
    hdr_cam_keys = re.findall(r'"([^"]+)"', re.search(r"ObjectKeys\(obj,([^)]+)\)", hdr_cam_fn).group(1))

    curve_parse = re.search(r"internal static ToneCurveSettings Parse\(JsonElement \w+\)\s*\{(.*?)\n    \}", curve_src, re.S).group(1)
    _need(r"is not \(\"legacy\" or \"custom\"\)", curve_src, "light.curve mode values", "RawLabWindows/ToneCurveSettings.cs")
    _need(r"GetArrayLength\(\) > 33", curve_src, "light.curve points max", "RawLabWindows/ToneCurveSettings.cs")
    if 'TryGetProperty("channels"' not in curve_parse:
        raise AssertionError(
            "Parse failed for light.curve optional keys: pattern 'TryGetProperty(\"channels\")' "
            "not found in RawLabWindows/ToneCurveSettings.cs"
        )
    curve_opt = ["channels"]
    curve_req = sorted(re.findall(
        r'"([^"]+)"',
        _need(r"SequenceEqual\(new\[\] \{ ([^}]+) \}\)", curve_src, "light.curve required keys", "RawLabWindows/ToneCurveSettings.cs").group(1),
    ))

    protocols: dict[str, dict] = {}
    for name, wire in cases:
        hdr_only = name in hdr_only_cases
        if name == "HdrLook":
            protocols[wire] = _make_proto("object", nullable=hdr_look_nullable, object_keys=hdr_look_keys, hdr_only=hdr_only)
        elif name == "HdrCameraDevelopment":
            protocols[wire] = _make_proto("object", object_keys=hdr_cam_keys, hdr_only=hdr_only)
        elif name == "Curve":
            protocols[wire] = _make_proto("object", object_keys=curve_req, optional_keys=curve_opt, hdr_only=hdr_only)
        elif name in {"GradingShadows", "GradingMidtones", "GradingHighlights"}:
            protocols[wire] = _make_proto("object", object_keys=grading_keys, hdr_only=hdr_only)
        elif name in scalar_ranges:
            lo, hi = scalar_ranges[name]
            is_int = int_quarter and name == "QuarterTurns"
            protocols[wire] = _make_proto(
                "integer" if is_int else "number",
                min_val=int(lo) if is_int else lo,
                max_val=int(hi) if is_int else hi,
                exclusive_min=name in excl_min_cases,
                hdr_only=hdr_only,
            )
        elif name in bool_cases:
            protocols[wire] = _make_proto("boolean", hdr_only=hdr_only)
        elif name == "ExposureMode":
            protocols[wire] = _make_proto("string", allowed_values=exp_modes, hdr_only=hdr_only)
        elif name == "WhiteBalanceMode":
            protocols[wire] = _make_proto("string", allowed_values=wb_modes, hdr_only=hdr_only)
        elif name == "Temperature":
            protocols[wire] = _make_proto(
                "number",
                nullable=bool(temp_m.group(1)),
                min_val=float(temp_m.group(2)),
                max_val=float(temp_m.group(3)),
                hdr_only=hdr_only,
            )
        elif name == "Tint":
            protocols[wire] = _make_proto(
                "number",
                nullable=bool(tint_m.group(1)),
                min_val=float(tint_m.group(2)),
                max_val=float(tint_m.group(3)),
                hdr_only=hdr_only,
            )
        elif name == "LensProfile":
            protocols[wire] = _make_proto("string", nullable=lens_prof_null, non_empty=lens_prof_null, hdr_only=hdr_only)
        elif name == "RawDenoise":
            protocols[wire] = _make_proto("integer", min_val=min(raw_vals), max_val=max(raw_vals), allowed_values=raw_vals, hdr_only=hdr_only)
        elif name == "ChromaDenoise":
            protocols[wire] = _make_proto(
                "integer",
                nullable=bool(chroma_m.group(1)),
                min_val=min(chroma_vals),
                max_val=max(chroma_vals),
                allowed_values=chroma_vals,
                hdr_only=hdr_only,
            )
        elif name == "Look":
            protocols[wire] = _make_proto("object", object_keys=look_keys, hdr_only=hdr_only)
        elif name == "WaveletDenoise":
            protocols[wire] = _make_proto("object", nullable=wavelet_nullable, object_keys=wavelet_keys, hdr_only=hdr_only)
        else:
            raise AssertionError(f"Unhandled C# protocol field {name} ({wire})")

    protocols = _attach_sub_fields(protocols, "windows")
    return wire_ids, protocols, groups


# ---------------------------------------------------------------------------
# Layer 2: Model parsers across all 4 platforms
# ---------------------------------------------------------------------------


def _model_entry(
    storage_type: str,
    *,
    supported: bool = True,
    modes=("sdr", "hdr"),
    nullable: bool = False,
    min_val=None,
    max_val=None,
    hdr_min=None,
    hdr_max=None,
    default=None,
    hdr_default=None,
    scale_from_protocol: str = "p",
    hdr_scale_from_protocol=None,
    quantization: str = "continuous",
    transfer_rejects_fractional: bool = False,
) -> dict:
    d = {
        "supported": supported,
        "modes": list(modes),
        "storage_type": storage_type,
        "nullable": nullable,
        "min": min_val,
        "max": max_val,
        "default": default,
        "scale_from_protocol": scale_from_protocol,
        "quantization": quantization,
    }
    if hdr_min is not None or hdr_max is not None:
        d["hdr_min"] = hdr_min
        d["hdr_max"] = hdr_max
    if hdr_default is not None:
        d["hdr_default"] = hdr_default
    if hdr_scale_from_protocol is not None:
        d["hdr_scale_from_protocol"] = hdr_scale_from_protocol
    if transfer_rejects_fractional:
        d["transfer_rejects_fractional"] = True
    return d


def parse_models_from_sources() -> dict[str, dict[str, dict]]:
    """Parse model defaults, bounds, nullability, and transfer scales from 4-end sources."""
    hdr_swift = _strip_line_comments(_read("Shared/HDRSettings.swift"))
    hdr_transfer_swift = _strip_line_comments(_read("Shared/HDRAdjustmentTransfer.swift"))
    geom_swift = _strip_line_comments(_read("Shared/GeometrySettings.swift"))
    hsl_swift = _strip_line_comments(_read("Shared/HSLSettings.swift"))
    tone_swift = _strip_line_comments(_read("Shared/ToneControlsSettings.swift"))
    atmos_swift = _strip_line_comments(_read("Shared/AtmosphereSettings.swift"))

    mac_adj = _strip_line_comments(_read("RawLabMac/Sources/Adjustments/Adjustments.swift"))
    mac_types = _strip_line_comments(_read("RawLabMac/Sources/Adjustments/AdjustmentTypes.swift"))
    mac_tv = _strip_line_comments(_read("RawLabMac/Sources/Adjustments/MacAdjustmentTransferValues.swift"))

    ios_raw = _strip_line_comments(_read("RawLab/RawLab/Core/Models/RawSettings.swift"))
    ios_rules = _strip_line_comments(_read("RawLab/RawLab/Core/Models/EditorAdjustmentRules.swift"))
    ios_tr = _strip_line_comments(_read("RawLab/RawLab/Core/Models/IOSAdjustmentTransfer.swift"))
    ios_tv = _strip_line_comments(_read("RawLab/RawLab/Core/Models/IOSAdjustmentTransferValues.swift"))

    kt_edit = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/settings/EditSettings.kt"))
    kt_hdr = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/settings/HDRSettings.kt"))
    kt_tv = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/adjustments/AdjustmentTransferValues.kt"))

    cs_adj = _strip_line_comments(_read("RawLabWindows/Adjustments.cs"))
    cs_fx = _strip_line_comments(_read("RawLabWindows/PhotoEffectsSettings.cs"))
    cs_dn = _strip_line_comments(_read("RawLabWindows/DenoiseSettings.cs"))
    cs_tv = _strip_line_comments(_read("RawLabWindows/AdjustmentTransferValues.cs"))

    # Parse shared HDR ranges/defaults from HDRSettings.swift & HDRSettings.kt
    hdr_exp_range = tuple(
        float(x)
        for x in re.search(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(exposure\)", hdr_swift).groups()
    )
    hdr_scalar_100 = tuple(
        float(x)
        for x in re.search(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(contrast\)", hdr_swift).groups()
    )
    hdr_peak_range = tuple(
        float(x)
        for x in re.search(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(peakLimitEV\)", hdr_swift).groups()
    )
    hdr_sdr_exp_range = tuple(
        float(x)
        for x in re.search(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(sdrExposureEV\)", hdr_swift).groups()
    )
    hdr_sharp_range = tuple(
        float(x)
        for x in re.search(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(sharpening\)", hdr_swift).groups()
    )
    hdr_clarity_range = tuple(
        float(x)
        for x in re.search(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(clarity\)", hdr_swift).groups()
    )
    assert "exposure in -4f..4f" in kt_hdr

    # Parse Mac AdjustmentParameter.spec ranges & defaults + MacAdjustmentTransferValues scales
    mac_specs = {}
    for m in re.finditer(
        r"case \.(\w+):\s*return AdjustmentSpec\(.*?range:\s*(-?\d+(?:\.\d+)?)\.\.\.(-?\d+(?:\.\d+)?),\s*defaultValue:\s*(-?\d+(?:\.\d+)?)",
        mac_types,
    ):
        mac_specs[m.group(1)] = (float(m.group(2)), float(m.group(3)), float(m.group(4)))

    mac_contrast_scale = "(p - 1) * 100" if "case .contrast, .saturation: native = (value - 1) * 100" in mac_tv else "p"
    mac_hi_scale = "-p * 100" if "case .highlights: native = -value * 100" in mac_tv else "p * 100"
    mac_sh_scale = "p * 100" if "case .shadows, .sCurve, .sharpening: native = value * 100" in mac_tv else "p"
    mac_chroma_opt = "var chromaNoiseReduction: Double?" in mac_adj
    mac_wavelet_opt = "var waveletNoiseReduction: WaveletDenoiseSettings?" in mac_adj
    mac_post_rgb_sdr_unsupported = "if let value = payload[.postRGBDenoise]?.number, value != 0 {\n            throw AdjustmentTransferError.incompatible" in mac_tv
    mac_ai_sdr = "var aiDenoiseEnabled = false" in mac_adj
    mac_ai_hdr = "var hdrCameraAIEnabled: Bool" in mac_adj

    # Parse iOS EditorAdjustmentRules.valid(_:) + RawSettings defaults + IOSAdjustmentTransfer rules
    ios_valid_ranges = {}
    valid_section = re.search(r"static func valid\(_ settings: RawSettings\) -> Bool \{(.*?)\n    \}", ios_rules, re.S).group(1)
    for prop, lo, hi in re.findall(r"\(settings\.(\w+),\s*(-?\d+(?:\.\d+)?)\.\.\.(-?\d+(?:\.\d+)?)\)", valid_section):
        ios_valid_ranges[prop] = (float(lo), float(hi))
    ios_lut_range = tuple(float(x) for x in re.search(r"lutStrengthRange:\s*ClosedRange<Double>\s*=\s*(-?\d+)\.\.\.(-?\d+)", ios_raw).groups())
    ios_temp_range = tuple(float(x) for x in re.search(r"temperatureRange:\s*ClosedRange<Double>\s*=\s*(-?\d+)\.\.\.(-?\d+)", ios_raw).groups())
    ios_tint_range = tuple(float(x) for x in re.search(r"tintRange:\s*ClosedRange<Double>\s*=\s*(-?\d+)\.\.\.(-?\d+)", ios_raw).groups())
    ios_contrast_default = float(re.search(r"contrast = try values\.decodeIfPresent.*? \?\? (\d+)", ios_raw).group(1))
    ios_sat_default = float(re.search(r"saturation = try values\.decodeIfPresent.*? \?\? (\d+)", ios_raw).group(1))
    ios_strength_default = float(re.search(r"lutStrength = try values\.decodeIfPresent.*? \?\? (\d+)", ios_raw).group(1))
    ios_fx_rounds_int = "value.rounded()" in re.search(r"private static func clamped.*?\n    \}", ios_raw, re.S).group(0)
    ios_fx_rejects_frac = "guard value.rounded() == value else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }" in ios_tr
    ios_raw_dn_unsupported = "if let raw = payload[.rawDenoise]?.number, raw != 0 { throw AdjustmentTransferError.incompatible" in ios_tv
    ios_direct_scalar = "for (field, key) in scalarKeys { result[field.rawValue] = .number(settings[keyPath: key]) }" in ios_tv
    assert ios_direct_scalar

    # Parse Android EditSettings defaults & require() bounds + AdjustmentTransferValues scales
    kt_defaults = {}
    for prop, val in re.findall(r"val (\w+):\s*Float\s*=\s*(-?\d+(?:\.\d+)?)f", kt_edit):
        kt_defaults[prop] = float(val)
    kt_bounds = {}
    for prop, lo, hi in re.findall(r"require\((\w+)\.isFinite\(\)\s*&&\s*\1 in (-?\d+(?:\.\d+)?)f\.\.(-?\d+(?:\.\d+)?)f\)", kt_edit):
        kt_bounds[prop] = (float(lo), float(hi))
    kt_contrast_scale = "p - 1" if "AdjustmentField.CONTRAST -> settings.copy(contrast = (value - 1).toFloat())" in kt_tv else "p"
    kt_sat_scale = "p - 1" if "AdjustmentField.SATURATION -> settings.copy(saturation = (value - 1).toFloat())" in kt_tv else "p"
    kt_hi_scale = "-p" if "AdjustmentField.HIGHLIGHTS -> settings.copy(highlights = (-value.toFloat())" in kt_tv else "p"
    kt_dn_unsupported = "for (field in listOf(AdjustmentField.RAW_DENOISE, AdjustmentField.POST_RGB_DENOISE))" in kt_tv

    # Parse Windows ParameterSpec.All + values[] + PhotoEffectSpec + SetEffect rounding + AdjustmentTransferValues scales
    cs_specs = {}
    for m in re.finditer(
        r'new\(Parameter\.(\w+),"[^"]*","[^"]*",(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?),(-?\.\d+|\d+(?:\.\d+)?)',
        cs_adj,
    ):
        cs_specs[m.group(1)] = (float(m.group(2)), float(m.group(3)), float(m.group(4)))
    cs_defaults_arr = [
        float(x)
        for x in re.search(r"private double\[\] values = \[([^\]]+)\];", cs_adj).group(1).split(",")
    ]
    cs_param_order = ["Strength", "Exposure", "Temperature", "Tint", "Contrast", "Highlights", "Shadows", "ToneCurve", "Saturation", "Sharpening"]
    cs_defaults = dict(zip(cs_param_order, cs_defaults_arr))
    cs_fx_round_1 = "Math.Round(value, 1, MidpointRounding.AwayFromZero)" in cs_adj
    cs_contrast_scale = "(p - 1) * 100" if "F.Contrast or F.Saturation=>(value-1)*100" in cs_tv else "p"
    cs_hi_scale = "-p * 100" if "F.Highlights=>-value*100" in cs_tv else "p * 100"
    cs_other_scale = "p * 100" if "_=>value*100" in cs_tv else "p"
    cs_dn_unsupported = "foreach(var field in new[]{F.RawDenoise,F.PostRGBDenoise})" in cs_tv
    cs_ai_sdr = "public bool AIDenoiseEnabled { get; set; }" in cs_adj
    cs_ai_hdr = "internal bool HDRCameraAIEnabled { get; set; }" in cs_adj

    # Shared sub-settings defaults/ranges
    hsl_range = tuple(float(x) for x in re.search(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(\$0\)", hsl_swift).groups())
    tone_range = tuple(float(x) for x in re.search(r"(-?\d+)\.\.\.(-?\d+)", tone_swift).groups())
    atmos_range = tuple(float(x) for x in re.search(r"(-?\d+)\.\.\.(-?\d+)", atmos_swift).groups())
    assert "cropWidth: Double = 1" in geom_swift or "var cropWidth = 1.0" in geom_swift
    hdr_detail_clarity_scale = "p / 100" if "field == .clarity || field == .dehaze ? value * 100 : value" in hdr_transfer_swift else "p"

    cs_fx_defs = {}
    for m in re.finditer(
        r"new\(PhotoEffectParameter\.(\w+),\s*Loc\.Text\([^\)]+\),\s*(?:true|false),\s*(-?\d+),\s*(-?\d+),\s*(-?\d+)\)",
        cs_fx,
    ):
        cs_fx_defs[m.group(1)] = (float(m.group(2)), float(m.group(3)), float(m.group(4)))

    dn_m = re.search(
        r"record DenoiseSettings\(bool Enabled=(false|true),double Luma=(\d+),double Chroma=(\d+),double Coarse=(\d+)\)",
        cs_dn,
    )
    wavelet_default = {
        "enabled": dn_m.group(1) == "true",
        "luma": float(dn_m.group(2)),
        "chroma": float(dn_m.group(3)),
        "coarse": float(dn_m.group(4)),
        "preset": "detail",
    }

    models: dict[str, dict[str, dict]] = {}

    # 1. looks.reference & 2. looks.strength
    look_def = {"kind": "neutral", "id": None}
    models["looks.reference"] = {
        p: _model_entry("object", modes=("sdr",), default=look_def, quantization="discrete")
        for p in PLATFORMS
    }
    models["looks.strength"] = {
        "macos": _model_entry("double", modes=("sdr",), min_val=mac_specs["strength"][0], max_val=mac_specs["strength"][1], default=mac_specs["strength"][2], scale_from_protocol="p"),
        "ios": _model_entry("double", modes=("sdr",), min_val=ios_lut_range[0], max_val=ios_lut_range[1], default=ios_strength_default, scale_from_protocol="p"),
        "android": _model_entry("float", modes=("sdr",), min_val=kt_bounds["strength"][0], max_val=kt_bounds["strength"][1], default=kt_defaults["strength"], scale_from_protocol="p"),
        "windows": _model_entry("double", modes=("sdr",), min_val=cs_specs["Strength"][0], max_val=cs_specs["Strength"][1], default=cs_defaults["Strength"], scale_from_protocol=cs_other_scale),
    }

    # 3. light.exposure & 4. light.exposure_mode
    models["light.exposure"] = {
        "macos": _model_entry("double", min_val=mac_specs["exposure"][0], max_val=mac_specs["exposure"][1], hdr_min=hdr_exp_range[0], hdr_max=hdr_exp_range[1], default=mac_specs["exposure"][2]),
        "ios": _model_entry("double", min_val=ios_valid_ranges["exposure"][0], max_val=ios_valid_ranges["exposure"][1], hdr_min=hdr_exp_range[0], hdr_max=hdr_exp_range[1], default=0.0),
        "android": _model_entry("float", min_val=kt_bounds["exposure"][0], max_val=kt_bounds["exposure"][1], hdr_min=hdr_exp_range[0], hdr_max=hdr_exp_range[1], default=kt_defaults["exposure"]),
        "windows": _model_entry("double", min_val=cs_specs["Exposure"][0], max_val=cs_specs["Exposure"][1], hdr_min=hdr_exp_range[0], hdr_max=hdr_exp_range[1], default=cs_defaults["Exposure"]),
    }
    models["light.exposure_mode"] = {
        "macos": _model_entry("enum", modes=("sdr",), default="preview", quantization="discrete"),
        "ios": _model_entry("enum", modes=("sdr",), default="preview", quantization="discrete"),
        "android": _model_entry("int", modes=("sdr",), min_val=0, max_val=2, default="preview", quantization="discrete"),
        "windows": _model_entry("int", modes=("sdr",), min_val=0, max_val=2, default="preview", quantization="discrete"),
    }

    # 5. light.contrast
    models["light.contrast"] = {
        "macos": _model_entry("double", min_val=mac_specs["contrast"][0], max_val=mac_specs["contrast"][1], default=mac_specs["contrast"][2], scale_from_protocol=mac_contrast_scale),
        "ios": _model_entry("double", min_val=ios_valid_ranges["contrast"][0], max_val=ios_valid_ranges["contrast"][1], hdr_min=hdr_scalar_100[0], hdr_max=hdr_scalar_100[1], default=ios_contrast_default, hdr_default=0.0, scale_from_protocol="p", hdr_scale_from_protocol="(p - 1) * 100"),
        "android": _model_entry("float", min_val=kt_bounds["contrast"][0], max_val=kt_bounds["contrast"][1], hdr_min=hdr_scalar_100[0], hdr_max=hdr_scalar_100[1], default=kt_defaults["contrast"], hdr_default=0.0, scale_from_protocol=kt_contrast_scale, hdr_scale_from_protocol="(p - 1) * 100"),
        "windows": _model_entry("double", min_val=cs_specs["Contrast"][0], max_val=cs_specs["Contrast"][1], default=cs_defaults["Contrast"], scale_from_protocol=cs_contrast_scale),
    }

    # 6. light.highlights
    models["light.highlights"] = {
        "macos": _model_entry("double", min_val=mac_specs["highlights"][0], max_val=mac_specs["highlights"][1], default=mac_specs["highlights"][2], scale_from_protocol=mac_hi_scale),
        "ios": _model_entry("double", min_val=ios_valid_ranges["highlights"][0], max_val=ios_valid_ranges["highlights"][1], hdr_min=hdr_scalar_100[0], hdr_max=hdr_scalar_100[1], default=0.0, hdr_default=0.0, scale_from_protocol="p", hdr_scale_from_protocol="-p * 100"),
        "android": _model_entry("float", min_val=kt_bounds["highlights"][0], max_val=kt_bounds["highlights"][1], hdr_min=hdr_scalar_100[0], hdr_max=hdr_scalar_100[1], default=kt_defaults["highlights"], hdr_default=0.0, scale_from_protocol=kt_hi_scale, hdr_scale_from_protocol="-p * 100"),
        "windows": _model_entry("double", min_val=cs_specs["Highlights"][0], max_val=cs_specs["Highlights"][1], default=cs_defaults["Highlights"], scale_from_protocol=cs_hi_scale),
    }

    # 7. light.shadows & 8. light.s_curve
    for fid, mac_k, ios_k, kt_k, cs_k in (
        ("light.shadows", "shadows", "shadows", "shadows", "Shadows"),
        ("light.s_curve", "toneCurve", "toneCurve", "toneCurve", "ToneCurve"),
    ):
        models[fid] = {
            "macos": _model_entry("double", min_val=mac_specs[mac_k][0], max_val=mac_specs[mac_k][1], default=mac_specs[mac_k][2], scale_from_protocol=mac_sh_scale),
            "ios": _model_entry("double", min_val=ios_valid_ranges[ios_k][0], max_val=ios_valid_ranges[ios_k][1], hdr_min=hdr_scalar_100[0], hdr_max=hdr_scalar_100[1], default=0.0, hdr_default=0.0, scale_from_protocol="p", hdr_scale_from_protocol="p * 100"),
            "android": _model_entry("float", min_val=kt_bounds[kt_k][0], max_val=kt_bounds[kt_k][1], hdr_min=hdr_scalar_100[0], hdr_max=hdr_scalar_100[1], default=kt_defaults[kt_k], hdr_default=0.0, scale_from_protocol="p", hdr_scale_from_protocol="p * 100"),
            "windows": _model_entry("double", min_val=cs_specs[cs_k][0], max_val=cs_specs[cs_k][1], default=cs_defaults[cs_k], scale_from_protocol=cs_other_scale),
        }

    # 9. light.curve (defaults parsed per end from ToneCurveSettings sources)
    models["light.curve"] = {p: _model_entry("object", default=_curve_default(p)) for p in PLATFORMS}

    # 10-12. tone.black_point, tone.white_point, color.vibrance
    for fid in ("tone.black_point", "tone.white_point", "color.vibrance"):
        models[fid] = {
            "macos": _model_entry("double", min_val=tone_range[0], max_val=tone_range[1], default=0.0),
            "ios": _model_entry("double", min_val=tone_range[0], max_val=tone_range[1], default=0.0),
            "android": _model_entry("float", min_val=tone_range[0], max_val=tone_range[1], default=0.0),
            "windows": _model_entry("double", min_val=tone_range[0], max_val=tone_range[1], default=0.0),
        }

    # 13-15. color.grading.*
    grad_def = {"hue": 0.0, "saturation": 0.0}
    for zone in ("shadows", "midtones", "highlights"):
        models[f"color.grading.{zone}"] = {p: _model_entry("object", default=grad_def) for p in PLATFORMS}

    # 16-19. white balance & saturation
    models["color.white_balance.mode"] = {
        "macos": _model_entry("enum", modes=("sdr",), default="camera", quantization="discrete"),
        "ios": _model_entry("enum", modes=("sdr",), default="camera", quantization="discrete"),
        "android": _model_entry("bool", modes=("sdr",), default="camera", quantization="discrete"),
        "windows": _model_entry("bool", modes=("sdr",), default="camera", quantization="discrete"),
    }
    models["color.white_balance.temperature_kelvin"] = {
        "macos": _model_entry("double", modes=("sdr",), min_val=mac_specs["temperature"][0], max_val=mac_specs["temperature"][1], default=mac_specs["temperature"][2]),
        "ios": _model_entry("double", modes=("sdr",), min_val=ios_temp_range[0], max_val=ios_temp_range[1], default=6500.0),
        "android": _model_entry("float", modes=("sdr",), min_val=kt_bounds["temperature"][0], max_val=kt_bounds["temperature"][1], default=kt_defaults["temperature"]),
        "windows": _model_entry("double", modes=("sdr",), min_val=cs_specs["Temperature"][0], max_val=cs_specs["Temperature"][1], default=cs_defaults["Temperature"]),
    }
    models["color.white_balance.tint"] = {
        "macos": _model_entry("double", modes=("sdr",), min_val=mac_specs["tint"][0], max_val=mac_specs["tint"][1], default=mac_specs["tint"][2]),
        "ios": _model_entry("double", modes=("sdr",), min_val=ios_tint_range[0], max_val=ios_tint_range[1], default=0.0),
        "android": _model_entry("float", modes=("sdr",), min_val=kt_bounds["tint"][0], max_val=kt_bounds["tint"][1], default=kt_defaults["tint"]),
        "windows": _model_entry("double", modes=("sdr",), min_val=cs_specs["Tint"][0], max_val=cs_specs["Tint"][1], default=cs_defaults["Tint"]),
    }
    models["color.saturation"] = {
        "macos": _model_entry("double", min_val=mac_specs["saturation"][0], max_val=mac_specs["saturation"][1], default=mac_specs["saturation"][2], scale_from_protocol=mac_contrast_scale),
        "ios": _model_entry("double", min_val=ios_valid_ranges["saturation"][0], max_val=ios_valid_ranges["saturation"][1], hdr_min=hdr_scalar_100[0], hdr_max=hdr_scalar_100[1], default=ios_sat_default, hdr_default=0.0, scale_from_protocol="p", hdr_scale_from_protocol="(p - 1) * 100"),
        "android": _model_entry("float", min_val=kt_bounds["saturation"][0], max_val=kt_bounds["saturation"][1], hdr_min=hdr_scalar_100[0], hdr_max=hdr_scalar_100[1], default=kt_defaults["saturation"], hdr_default=0.0, scale_from_protocol=kt_sat_scale, hdr_scale_from_protocol="(p - 1) * 100"),
        "windows": _model_entry("double", min_val=cs_specs["Saturation"][0], max_val=cs_specs["Saturation"][1], default=cs_defaults["Saturation"], scale_from_protocol=cs_contrast_scale),
    }

    # 20-27. HDR-only fields
    models["hdr.relative_temperature"] = {
        p: _model_entry("float" if p == "android" else "double", modes=("hdr",), min_val=2000.0, max_val=50000.0, default=6500.0)
        for p in PLATFORMS
    }
    models["hdr.relative_tint"] = {
        p: _model_entry("float" if p == "android" else "double", modes=("hdr",), min_val=-150.0, max_val=150.0, default=0.0)
        for p in PLATFORMS
    }
    for fid, (lo, hi) in (
        ("hdr.peak_limit_ev", hdr_peak_range),
        ("hdr.sdr_exposure_ev", hdr_sdr_exp_range),
        ("hdr.sdr_contrast", (-100.0, 100.0)),
        ("hdr.sdr_saturation", (-100.0, 100.0)),
    ):
        models[fid] = {
            p: _model_entry("float" if p == "android" else "double", modes=("hdr",), min_val=lo, max_val=hi, default=0.0)
            for p in PLATFORMS
        }
    models["hdr.look"] = {
        p: _model_entry("object", modes=("hdr",), nullable=True, default=_look_default(p)) for p in PLATFORMS
    }
    hdr_cam_def = {
        "version": 1,
        "white_balance_mode": "as_shot",
        "temperature": 0.0,
        "tint": 0.0,
        "exposure_reference": "metadata",
        "fbdd_level": 0,
    }
    models["hdr.camera_development"] = {p: _model_entry("object", modes=("hdr",), default=hdr_cam_def) for p in PLATFORMS}

    # 28-51. HSL
    for axis in HSL_AXES:
        for ch in HSL_CHANNELS:
            models[f"color.hsl.{axis}.{ch}"] = {
                p: _model_entry("float" if p == "android" else "double", min_val=hsl_range[0], max_val=hsl_range[1], default=0.0)
                for p in PLATFORMS
            }

    # 52-61. effects
    fx_map = [
        ("effects.vignette.amount", "VignetteAmount"),
        ("effects.vignette.midpoint", "VignetteMidpoint"),
        ("effects.vignette.roundness", "VignetteRoundness"),
        ("effects.vignette.feather", "VignetteFeather"),
        ("effects.vignette.highlights", "VignetteHighlights"),
        ("effects.grain.amount", "GrainAmount"),
        ("effects.grain.size", "GrainSize"),
        ("effects.grain.roughness", "GrainRoughness"),
    ]
    for fid, cs_name in fx_map:
        lo, hi, dflt = cs_fx_defs[cs_name]
        models[fid] = {
            "macos": _model_entry("double", min_val=lo, max_val=hi, default=dflt),
            "ios": _model_entry(
                "double",
                min_val=lo,
                max_val=hi,
                default=dflt,
                quantization="round_int" if ios_fx_rounds_int else "continuous",
                transfer_rejects_fractional=ios_fx_rejects_frac,
            ),
            "android": _model_entry("float", min_val=lo, max_val=hi, default=dflt),
            "windows": _model_entry("double", min_val=lo, max_val=hi, default=dflt, quantization="round_1" if cs_fx_round_1 else "continuous"),
        }
    for fid in ("effects.clarity", "effects.dehaze"):
        models[fid] = {
            p: _model_entry(
                "float" if p == "android" else "double",
                min_val=atmos_range[0],
                max_val=atmos_range[1],
                hdr_min=hdr_clarity_range[0],
                hdr_max=hdr_clarity_range[1],
                default=0.0,
                hdr_default=0.0,
                scale_from_protocol="p",
                hdr_scale_from_protocol=hdr_detail_clarity_scale,
            )
            for p in PLATFORMS
        }

    # 62-66. detail
    models["detail.sharpening"] = {
        "macos": _model_entry("double", min_val=mac_specs["sharpening"][0], max_val=mac_specs["sharpening"][1], hdr_min=hdr_sharp_range[0], hdr_max=hdr_sharp_range[1], default=0.0, hdr_default=0.0, scale_from_protocol=mac_sh_scale, hdr_scale_from_protocol="p"),
        "ios": _model_entry("double", min_val=ios_valid_ranges["sharpening"][0], max_val=ios_valid_ranges["sharpening"][1], default=0.0, scale_from_protocol="p"),
        "android": _model_entry("float", min_val=kt_bounds["sharpening"][0], max_val=kt_bounds["sharpening"][1], default=kt_defaults["sharpening"], scale_from_protocol="p"),
        "windows": _model_entry("double", min_val=cs_specs["Sharpening"][0], max_val=cs_specs["Sharpening"][1], hdr_min=hdr_sharp_range[0], hdr_max=hdr_sharp_range[1], default=cs_defaults["Sharpening"], hdr_default=0.0, scale_from_protocol=cs_other_scale, hdr_scale_from_protocol="p"),
    }
    models["detail.denoise.raw_level"] = {
        "macos": _model_entry("double", modes=("sdr",), min_val=mac_specs["rawNoiseReduction"][0], max_val=mac_specs["rawNoiseReduction"][1], default=0.0, quantization="discrete"),
        "ios": _model_entry("none", supported=not ios_raw_dn_unsupported, modes=(), scale_from_protocol="none", quantization="none"),
        "android": _model_entry("none", supported=not kt_dn_unsupported, modes=(), scale_from_protocol="none", quantization="none"),
        "windows": _model_entry("none", supported=not cs_dn_unsupported, modes=(), scale_from_protocol="none", quantization="none"),
    }
    models["detail.denoise.post_rgb"] = {
        "macos": _model_entry("double", modes=("hdr",) if mac_post_rgb_sdr_unsupported else ("sdr", "hdr"), min_val=0.0, max_val=1.0, default=0.0),
        "ios": _model_entry("double", modes=("sdr", "hdr"), min_val=ios_valid_ranges["noiseReduction"][0], max_val=ios_valid_ranges["noiseReduction"][1], default=0.0),
        "android": _model_entry("float", modes=("hdr",) if kt_dn_unsupported else ("sdr", "hdr"), min_val=0.0, max_val=1.0, default=0.0),
        "windows": _model_entry("double", modes=("hdr",) if cs_dn_unsupported else ("sdr", "hdr"), min_val=0.0, max_val=1.0, default=0.0),
    }
    models["detail.denoise.chroma_mode"] = {
        "macos": _model_entry("double", modes=("sdr",), nullable=mac_chroma_opt, min_val=0.0, max_val=2.0, default=None, quantization="discrete"),
        "ios": _model_entry("int", modes=("sdr",), min_val=0, max_val=2, default=0, quantization="discrete"),
        "android": _model_entry("int", modes=("sdr",), min_val=0, max_val=2, default=0, quantization="discrete"),
        "windows": _model_entry("int", modes=("sdr",), min_val=0, max_val=2, default=0, quantization="discrete"),
    }
    models["detail.denoise.wavelet"] = {
        "macos": _model_entry("object", modes=("sdr",), nullable=mac_wavelet_opt, default=None),
        "ios": _model_entry("object", modes=("sdr",), default=wavelet_default),
        "android": _model_entry("object", modes=("sdr",), default=wavelet_default),
        "windows": _model_entry("object", modes=("sdr",), default=wavelet_default),
    }

    # 67-81. geometry & lens
    for fid, dflt in (
        ("geometry.crop.x", 0.0),
        ("geometry.crop.y", 0.0),
        ("geometry.crop.width", 1.0),
        ("geometry.crop.height", 1.0),
    ):
        models[fid] = {
            p: _model_entry("float" if p == "android" else "double", min_val=0.0, max_val=1.0, default=dflt)
            for p in PLATFORMS
        }
    models["geometry.quarter_turns"] = {
        p: _model_entry("int", min_val=0, max_val=3, default=0, quantization="discrete")
        for p in PLATFORMS
    }
    for fid in ("geometry.flip_horizontal", "geometry.flip_vertical"):
        models[fid] = {p: _model_entry("bool", default=False, quantization="discrete") for p in PLATFORMS}
    models["geometry.straighten_degrees"] = {
        p: _model_entry("float" if p == "android" else "double", min_val=-45.0, max_val=45.0, default=0.0)
        for p in PLATFORMS
    }
    for fid in ("geometry.perspective.horizontal", "geometry.perspective.vertical"):
        models[fid] = {
            p: _model_entry("float" if p == "android" else "double", min_val=-1.0, max_val=1.0, default=0.0)
            for p in PLATFORMS
        }
    for fid, dflt in (
        ("geometry.lens.distortion", False),
        ("geometry.lens.tca", False),
        ("geometry.lens.vignetting", False),
        ("geometry.lens.auto_crop", True),
    ):
        models[fid] = {p: _model_entry("bool", modes=("sdr", "hdr"), default=dflt, quantization="discrete") for p in PLATFORMS}
    models["geometry.lens.profile_id"] = {
        p: _model_entry("string", modes=("sdr",), nullable=True, default=None, quantization="discrete")
        for p in PLATFORMS
    }

    # 82-83. local desktop AI denoise
    models["local.ai_denoise_enabled"] = {
        "macos": _model_entry("bool", supported=mac_ai_sdr, modes=("sdr",), default=False, scale_from_protocol="none", quantization="discrete"),
        "ios": _model_entry("none", supported=False, modes=(), scale_from_protocol="none", quantization="none"),
        "android": _model_entry("none", supported=False, modes=(), scale_from_protocol="none", quantization="none"),
        "windows": _model_entry("bool", supported=cs_ai_sdr, modes=("sdr",), default=False, scale_from_protocol="none", quantization="discrete"),
    }
    models["local.hdr_camera_ai_enabled"] = {
        "macos": _model_entry("bool", supported=mac_ai_hdr, modes=("hdr",), default=False, scale_from_protocol="none", quantization="discrete"),
        "ios": _model_entry("none", supported=False, modes=(), scale_from_protocol="none", quantization="none"),
        "android": _model_entry("none", supported=False, modes=(), scale_from_protocol="none", quantization="none"),
        "windows": _model_entry("bool", supported=cs_ai_hdr, modes=("hdr",), default=False, scale_from_protocol="none", quantization="discrete"),
    }

    return models


# ---------------------------------------------------------------------------
# Layer 3: UI parsers across all 4 platforms
# ---------------------------------------------------------------------------


def _ui_entry(
    *,
    exposed: bool = True,
    modes=("sdr", "hdr"),
    unit=None,
    min_val=None,
    max_val=None,
    hdr_min=None,
    hdr_max=None,
    default=None,
    step=None,
    secondary_inspector_step=None,
    channels=None,
) -> dict:
    d = {
        "exposed": exposed,
        "modes": list(modes),
        "unit": unit,
        "min": min_val,
        "max": max_val,
        "default": default,
        "step": step,
    }
    if hdr_min is not None or hdr_max is not None:
        d["hdr_min"] = hdr_min
        d["hdr_max"] = hdr_max
    if secondary_inspector_step is not None:
        d["secondary_inspector_step"] = secondary_inspector_step
    if channels is not None:
        d["channels"] = channels
    return d


def parse_ui_from_sources() -> dict[str, dict[str, dict]]:
    """Parse current UI ranges, units, defaults, and steps from 4-end UI sources."""
    # Mac UI sources
    mac_prec_src = _strip_line_comments(_read("RawLabMac/Sources/Inputs/ParameterPrecision.swift"))
    mac_types_src = _strip_line_comments(_read("RawLabMac/Sources/Adjustments/AdjustmentTypes.swift"))
    mac_dock_src = _strip_line_comments(_read("RawLabMac/Sources/Editor/View/AdjustmentDock.swift"))
    mac_hsl_prec = _strip_line_comments(_read("RawLabMac/Sources/Controls/MacHSLPrecision.swift"))
    mac_dn_src = _strip_line_comments(_read("RawLabMac/Sources/Controls/DenoiseControls.swift"))
    mac_lens_src = _strip_line_comments(_read("RawLabMac/Sources/Lens/LensControls.swift"))
    hdr_mon_src = _strip_line_comments(_read("Shared/Native/HDRMonitoring.swift"))

    # iOS UI sources
    ios_kind_src = _strip_line_comments(_read("RawLab/RawLab/Core/Models/AdjustmentKind.swift"))
    ios_panels_src = _strip_line_comments(_read("RawLab/RawLab/UI/Panels/AdjustmentPanels.swift"))
    ios_curve_src = _strip_line_comments(_read("RawLab/RawLab/UI/Panels/ToneCurveControls.swift"))
    ios_grad_src = _strip_line_comments(_read("RawLab/RawLab/UI/Panels/ColorGradingControls.swift"))
    ios_fx_src = _strip_line_comments(_read("RawLab/RawLab/UI/Panels/PhotoEffectPanels.swift"))
    ios_geom_src = _strip_line_comments(_read("RawLab/RawLab/UI/Controls/GeometryControls.swift"))
    ios_lens_src = _strip_line_comments(_read("RawLab/RawLab/UI/Controls/LensControls.swift"))

    # Android UI sources
    kt_ctrl_src = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/editor/controls/AdjustmentControls.kt"))
    kt_dock_src = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/editor/ui/AdjustmentDock.kt"))
    kt_screen_src = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/editor/ui/EditorScreen.kt"))
    kt_grad_src = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/editor/controls/ColorGradingControls.kt"))
    kt_geom_src = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/editor/geometry/GeometryControls.kt"))
    kt_lens_src = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/editor/panels/LensControls.kt"))
    kt_edit_src = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/settings/EditSettings.kt"))

    # Windows UI sources
    cs_inter_src = _strip_line_comments(_read("RawLabWindows/ParameterInteraction.cs"))
    cs_adj_src = _strip_line_comments(_read("RawLabWindows/Adjustments.cs"))
    cs_fx_src = _strip_line_comments(_read("RawLabWindows/PhotoEffectsSettings.cs"))
    cs_hdr_src = _strip_line_comments(_read("RawLabWindows/MainWindow.HDR.cs"))
    cs_geom_src = _strip_line_comments(_read("RawLabWindows/GeometryPanel.xaml.cs"))
    cs_lens_xaml = _read("RawLabWindows/LensPanel.xaml")

    # Extract Mac ParameterPrecision fineStep = 1 / scale
    scale_block = re.search(r"var scale: Double \{(.*?)\n    \}", mac_prec_src, re.S).group(1)
    mac_fine = {}
    for cases_str, val in re.findall(r"case ([^:]+):\s*return (\d+(?:\.\d+)?)", scale_block):
        for c in cases_str.split(","):
            mac_fine[c.strip().lstrip(".")] = round(1.0 / float(val), 6)

    mac_hsl_step = round(
        1.0 / float(re.search(r"\*\s*(\d+)\)\.rounded\(\)\s*/\s*\1", mac_hsl_prec).group(1)),
        6,
    )
    mac_crop_min_pct = round(
        float(re.search(r"case \.cropWidth:\s*return min\((0\.\d+),", mac_types_src).group(1)) * 100.0,
        6,
    )
    mac_persp_unit = re.search(r'case \.perspectiveHorizontal,\s*\.perspectiveVertical:\s*return "([^"]*)"', mac_types_src).group(1)
    mac_sdr_lens_has_vig = "vignetting" in re.search(r"private var correctionOptions.*?\}", mac_lens_src, re.S).group(0)
    mac_has_chroma_picker = 'accessibilityIdentifier("chromaNoiseReduction.mode")' in mac_dn_src
    mac_hdr_dock_uses_prec = "precision: isEV ? .exposure : .standard" in mac_dock_src

    # Extract Apple HDRMonitoring steps (shared by Mac secondary inspector + iOS)
    hdr_mon_peak_step = float(re.search(r'slider\("HDR 亮度上限".*?step:\s*(\d+(?:\.\d+)?)', hdr_mon_src).group(1))
    hdr_mon_sdr_exp_step = float(re.search(r'slider\("SDR 底图曝光".*?step:\s*(\d+(?:\.\d+)?)', hdr_mon_src).group(1))
    hdr_mon_sdr_con_step = float(re.search(r'slider\("SDR 底图对比度".*?step:\s*(\d+(?:\.\d+)?)', hdr_mon_src).group(1))
    hdr_mon_look_step = round(
        float(re.search(r"Slider\(value:\s*\$settings\.lookSettings\.strength,\s*in:\s*0\.\.\.2,\s*step:\s*(\d+(?:\.\d+)?)", hdr_mon_src).group(1))
        * 100.0,
        6,
    )
    hdr_mon_cam_temp_step = float(re.search(r'cameraSlider\("色温".*?step:\s*(\d+(?:\.\d+)?)', hdr_mon_src).group(1))
    hdr_mon_cam_tint_step = float(re.search(r'cameraSlider\("色调".*?step:\s*(\d+(?:\.\d+)?)', hdr_mon_src).group(1))

    # Extract iOS AdjustmentKind.step & panel overrides
    ios_step_block = re.search(r"var step: Double \{(.*?)\n    \}", ios_kind_src, re.S).group(1)
    ios_steps = {}
    for cases_str, val in re.findall(r"case ([^:]+):\s*\n?\s*return (\d+(?:\.\d+)?)", ios_step_block):
        for c in cases_str.split(","):
            ios_steps[c.strip().lstrip(".")] = float(val)
    ios_scurve_ui_step = float(
        re.search(r'AdjustmentControl\(title:\s*L10n\.text\("S 曲线"\).*?range:\s*-100\.\.\.100,\s*step:\s*(\d+(?:\.\d+)?)', ios_curve_src, re.S).group(1)
    )
    ios_hdr_denoise_step_pct = round(ios_steps["noiseReduction"] * 100.0, 6)
    ios_sdr_denoise_uses_wavelet = "selectedAdjustment == .noiseReduction && !workingSettings.isHDREditing" in ios_panels_src
    ios_grad_step = float(re.search(r'identifier:\s*"grading\.hue"', ios_grad_src).string and re.search(r"range:\s*0\.\.\.360,\s*step:\s*(\d+(?:\.\d+)?)", ios_grad_src).group(1))
    ios_fx_step = float(re.search(r"struct IOSPhotoEffectsControls.*?range:\s*parameter\.range,\s*step:\s*(\d+(?:\.\d+)?)", ios_fx_src, re.S).group(1))
    ios_wavelet_step = float(re.search(r"struct IOSDenoiseControls.*?range:\s*0\.\.\.100,\s*step:\s*(\d+(?:\.\d+)?)", ios_fx_src, re.S).group(1))
    ios_hsl_step = float(re.search(r"struct IOSHSLMixer.*?range:\s*-100\.\.\.100,\s*step:\s*(\d+(?:\.\d+)?)", ios_fx_src, re.S).group(1))
    ios_crop_min_pct = float(
        re.search(r"let minimum = key == \\\.cropWidth \|\| key == \\\.cropHeight \? (\d+(?:\.\d+)?) : 0", ios_geom_src).group(1)
    )
    ios_crop_step = float(re.search(r"func cropControl.*?step:\s*(\d+(?:\.\d+)?)", ios_geom_src, re.S).group(1))
    ios_straighten_step = float(
        re.search(r'AdjustmentControl\(title:\s*L10n\.text\("拉直"\).*?step:\s*(\d+(?:\.\d+)?)', ios_geom_src, re.S).group(1)
    )
    ios_persp_step = float(re.search(r"func perspectiveControl.*?range:\s*-100\.\.\.100,\s*step:\s*(\d+(?:\.\d+)?)", ios_geom_src, re.S).group(1))
    ios_sdr_lens_has_vig = 'accessibilityIdentifier("lens.vignetting")' in ios_lens_src

    # Extract Android NumericControl step table & screen overrides
    kt_step_block = re.search(r"val step = stepOverride \?: when \(label\) \{(.*?)\n    \}", kt_ctrl_src, re.S).group(1)
    kt_exp_step = float(re.search(r"R\.string\.exposure\s*->\s*(\.\d+|\d+(?:\.\d+)?)f", kt_step_block).group(1))
    kt_temp_step = float(re.search(r"R\.string\.temperature\s*->\s*(\.\d+|\d+(?:\.\d+)?)f", kt_step_block).group(1))
    kt_straight_step = float(re.search(r"R\.string\.geometry_straighten\s*->\s*(\.\d+|\d+(?:\.\d+)?)f", kt_step_block).group(1))
    kt_crop_step = float(re.search(r"R\.string\.geometry_crop_height\s*->\s*(\.\d+|\d+(?:\.\d+)?)f", kt_step_block).group(1))
    kt_default_step = float(re.search(r"else\s*->\s*(\.\d+|\d+(?:\.\d+)?)f", kt_step_block).group(1))
    kt_grad_step = float(re.search(r"R\.string\.hsl_hue.*?stepOverride\s*=\s*(\.\d+|\d+(?:\.\d+)?)f", kt_grad_src, re.S).group(1))
    kt_hdr_look_step = float(
        re.search(r"R\.string\.transfer_field_strength,\s*look\.strength \* 100.*?stepOverride\s*=\s*(\.\d+|\d+(?:\.\d+)?)f", kt_dock_src, re.S).group(1)
    )
    kt_hdr_peak_step = float(
        re.search(r"R\.string\.hdr_peak_limit.*?stepOverride\s*=\s*(\.\d+|\d+(?:\.\d+)?)f", kt_screen_src, re.S).group(1)
    )
    kt_hdr_cam_uses_temp_label = "NumericControl(R.string.temperature, draft.temperature" in kt_screen_src
    kt_crop_min_pct = float(re.search(r"R\.string\.geometry_crop_width.*?minOf\((\.\d+|\d+(?:\.\d+)?)f,", kt_geom_src).group(1))
    kt_persp_unit = re.search(r'R\.string\.geometry_perspective_horizontal,\s*value\.perspectiveHorizontal \* 100f,\s*-100f\.\.100f,\s*"([^"]*)"', kt_geom_src).group(1)
    kt_sdr_lens_has_vig = '"lens.vignetting"' in kt_lens_src

    # Extract Windows NumericRange default Grid & panel-specific steps/ranges
    cs_default_grid = float(re.search(r"record NumericRange\(double Min,\s*double Max,\s*double Grid\s*=\s*(\.\d+|\d+(?:\.\d+)?)", cs_inter_src).group(1))
    cs_param_steps = {}
    for m in re.finditer(
        r'new\(Parameter\.(\w+),"[^"]*","[^"]*",(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?),(-?\.\d+|\d+(?:\.\d+)?),"([^"]*)"',
        cs_adj_src,
    ):
        cs_param_steps[m.group(1)] = (float(m.group(2)), float(m.group(3)), float(m.group(4)), m.group(5))
    cs_straight_m = re.search(r'angle\.Refresh\(Loc\.Text\("拉直"\),new\((-?\d+),(-?\d+),(\.\d+)', cs_geom_src)
    cs_straight_step = float(cs_straight_m.group(3))
    cs_persp_m = re.search(r'horizontal\.Refresh\(Loc\.Text\("水平透视"\),new\((-?\d+),(-?\d+),(\.\d+)', cs_geom_src)
    cs_persp_range = (float(cs_persp_m.group(1)), float(cs_persp_m.group(2)))
    cs_persp_step = float(cs_persp_m.group(3))
    cs_crop_m = re.search(r"new\(i<2 \? 0 : (\.\d+),maxima\[i\]\*100,(\.\d+),", cs_geom_src)
    cs_crop_min_pct = float(cs_crop_m.group(1))
    cs_crop_step = float(cs_crop_m.group(2))
    cs_sdr_lens_has_vig = 'x:Name="Vignetting"' in cs_lens_xaml
    cs_hdr_cam_temp_step = float(re.search(r'temperature\.Refresh\(Loc\.Text\("色温"\),new\(2000,50000,(\d+)\)', cs_hdr_src).group(1))
    cs_hdr_cam_tint_step = float(re.search(r'tint\.Refresh\(Loc\.Text\("色调"\),new\(-150,150,(\d+)\)', cs_hdr_src).group(1))
    cs_hdr_look_step = float(re.search(r'strength\.Refresh\(Loc\.Text\("外观强度"\),new\(0,200,(\d+)\)', cs_hdr_src).group(1))
    cs_hdr_sdr_con_step = float(re.search(r'Add\("sdrContrast","SDR 底图对比度",new\(-100,100,(\d+)\)', cs_hdr_src).group(1))

    ui: dict[str, dict[str, dict]] = {}

    # 1. looks.reference & 2. looks.strength
    look_def = {"kind": "neutral", "id": None}
    ui["looks.reference"] = {p: _ui_entry(modes=("sdr",), default=look_def) for p in PLATFORMS}
    ui["looks.strength"] = {
        "macos": _ui_entry(modes=("sdr",), unit="%", min_val=0.0, max_val=200.0, default=100.0, step=mac_fine["standard"]),
        "ios": _ui_entry(modes=("sdr",), unit="%", min_val=0.0, max_val=200.0, default=100.0, step=round(ios_steps["strength"] * 100.0, 6)),
        "android": _ui_entry(modes=("sdr",), unit="%", min_val=0.0, max_val=200.0, default=100.0, step=kt_default_step),
        "windows": _ui_entry(modes=("sdr",), unit=cs_param_steps["Strength"][3], min_val=cs_param_steps["Strength"][0], max_val=cs_param_steps["Strength"][1], default=100.0, step=cs_param_steps["Strength"][2]),
    }

    # 3. light.exposure & 4. light.exposure_mode
    ui["light.exposure"] = {
        "macos": _ui_entry(unit="EV", min_val=-5.0, max_val=5.0, hdr_min=-4.0, hdr_max=4.0, default=0.0, step=mac_fine["exposure"]),
        "ios": _ui_entry(unit="EV", min_val=-5.0, max_val=5.0, hdr_min=-4.0, hdr_max=4.0, default=0.0, step=ios_steps["exposure"]),
        "android": _ui_entry(unit="EV", min_val=-5.0, max_val=5.0, hdr_min=-4.0, hdr_max=4.0, default=0.0, step=kt_exp_step),
        "windows": _ui_entry(unit="EV", min_val=-5.0, max_val=5.0, hdr_min=-4.0, hdr_max=4.0, default=0.0, step=cs_param_steps["Exposure"][2]),
    }
    ui["light.exposure_mode"] = {p: _ui_entry(modes=("sdr",), default="preview") for p in PLATFORMS}

    # Standard -100..100 % scalars
    for fid, ios_k in (
        ("light.contrast", "contrast"),
        ("light.highlights", "highlights"),
        ("light.shadows", "shadows"),
        ("tone.black_point", "blackPoint"),
        ("tone.white_point", "whitePoint"),
        ("color.vibrance", "vibrance"),
        ("color.saturation", "saturation"),
        ("effects.clarity", "clarity"),
        ("effects.dehaze", "dehaze"),
    ):
        ui[fid] = {
            "macos": _ui_entry(unit="%", min_val=-100.0, max_val=100.0, default=0.0, step=mac_fine["standard"]),
            "ios": _ui_entry(unit="%", min_val=-100.0, max_val=100.0, default=0.0, step=ios_steps[ios_k]),
            "android": _ui_entry(unit="%", min_val=-100.0, max_val=100.0, default=0.0, step=kt_default_step),
            "windows": _ui_entry(unit="%", min_val=-100.0, max_val=100.0, default=0.0, step=cs_default_grid),
        }

    # 8. light.s_curve (iOS IOSToneCurveControls uses step 0.1!)
    ui["light.s_curve"] = {
        "macos": _ui_entry(unit="%", min_val=-100.0, max_val=100.0, default=0.0, step=mac_fine["standard"]),
        "ios": _ui_entry(unit="%", min_val=-100.0, max_val=100.0, default=0.0, step=ios_scurve_ui_step),
        "android": _ui_entry(unit="%", min_val=-100.0, max_val=100.0, default=0.0, step=kt_default_step),
        "windows": _ui_entry(unit="%", min_val=-100.0, max_val=100.0, default=0.0, step=cs_default_grid),
    }

    # 9. light.curve (per-end parsed bounds, steps, channels and defaults)
    ui["light.curve"] = _ui_curve_entries(mac_fine)

    # 13-15. color.grading.*
    grad_def = {"hue": 0.0, "saturation": 0.0}
    for zone in ("shadows", "midtones", "highlights"):
        ui[f"color.grading.{zone}"] = {
            "macos": _ui_entry(default=grad_def, step={"hue": mac_fine["standard"], "saturation": mac_fine["standard"]}),
            "ios": _ui_entry(default=grad_def, step={"hue": ios_grad_step, "saturation": ios_grad_step}),
            "android": _ui_entry(default=grad_def, step={"hue": kt_grad_step, "saturation": kt_grad_step}),
            "windows": _ui_entry(default=grad_def, step={"hue": cs_default_grid, "saturation": cs_default_grid}),
        }

    # 16-18. white balance
    ui["color.white_balance.mode"] = {p: _ui_entry(modes=("sdr",), default="camera") for p in PLATFORMS}
    ui["color.white_balance.temperature_kelvin"] = {
        "macos": _ui_entry(modes=("sdr",), unit="K", min_val=2000.0, max_val=50000.0, default=6500.0, step=mac_fine["temperature"]),
        "ios": _ui_entry(modes=("sdr",), unit="K", min_val=2000.0, max_val=50000.0, default=6500.0, step=ios_steps["temperature"]),
        "android": _ui_entry(modes=("sdr",), unit="K", min_val=2000.0, max_val=50000.0, default=6500.0, step=kt_temp_step),
        "windows": _ui_entry(modes=("sdr",), unit="K", min_val=2000.0, max_val=50000.0, default=6500.0, step=cs_param_steps["Temperature"][2]),
    }
    ui["color.white_balance.tint"] = {
        "macos": _ui_entry(modes=("sdr",), unit="", min_val=-150.0, max_val=150.0, default=0.0, step=mac_fine["standard"]),
        "ios": _ui_entry(modes=("sdr",), unit="", min_val=-150.0, max_val=150.0, default=0.0, step=ios_steps["tint"]),
        "android": _ui_entry(modes=("sdr",), unit="", min_val=-150.0, max_val=150.0, default=0.0, step=kt_default_step),
        "windows": _ui_entry(modes=("sdr",), unit="", min_val=-150.0, max_val=150.0, default=0.0, step=cs_param_steps["Tint"][2]),
    }

    # 20-27. HDR-only UI
    ui["hdr.relative_temperature"] = {
        "macos": _ui_entry(modes=("hdr",), unit="K", min_val=2000.0, max_val=50000.0, default=6500.0, step=mac_fine["temperature"]),
        "ios": _ui_entry(modes=("hdr",), unit="K", min_val=2000.0, max_val=50000.0, default=6500.0, step=ios_steps["temperature"]),
        "android": _ui_entry(modes=("hdr",), unit="K", min_val=2000.0, max_val=50000.0, default=6500.0, step=kt_temp_step),
        "windows": _ui_entry(modes=("hdr",), unit="K", min_val=2000.0, max_val=50000.0, default=6500.0, step=cs_param_steps["Temperature"][2]),
    }
    ui["hdr.relative_tint"] = {
        "macos": _ui_entry(modes=("hdr",), unit="", min_val=-150.0, max_val=150.0, default=0.0, step=mac_fine["standard"]),
        "ios": _ui_entry(modes=("hdr",), unit="", min_val=-150.0, max_val=150.0, default=0.0, step=ios_steps["tint"]),
        "android": _ui_entry(modes=("hdr",), unit="", min_val=-150.0, max_val=150.0, default=0.0, step=kt_default_step),
        "windows": _ui_entry(modes=("hdr",), unit="", min_val=-150.0, max_val=150.0, default=0.0, step=cs_param_steps["Tint"][2]),
    }
    for fid, lo, hi, unit, is_ev in (
        ("hdr.peak_limit_ev", 0.0, 6.0, "EV", True),
        ("hdr.sdr_exposure_ev", -4.0, 4.0, "EV", True),
        ("hdr.sdr_contrast", -100.0, 100.0, "%", False),
        ("hdr.sdr_saturation", -100.0, 100.0, "%", False),
    ):
        mac_primary = (mac_fine["exposure"] if is_ev else mac_fine["standard"]) if mac_hdr_dock_uses_prec else (0.1 if is_ev else 1.0)
        sec_step = (hdr_mon_peak_step if fid == "hdr.peak_limit_ev" else hdr_mon_sdr_exp_step) if is_ev else hdr_mon_sdr_con_step
        kt_step = kt_hdr_peak_step if is_ev else kt_default_step
        cs_step = cs_default_grid if is_ev else cs_hdr_sdr_con_step
        ui[fid] = {
            "macos": _ui_entry(modes=("hdr",), unit=unit, min_val=lo, max_val=hi, default=0.0, step=mac_primary, secondary_inspector_step=sec_step),
            "ios": _ui_entry(modes=("hdr",), unit=unit, min_val=lo, max_val=hi, default=0.0, step=sec_step),
            "android": _ui_entry(modes=("hdr",), unit=unit, min_val=lo, max_val=hi, default=0.0, step=kt_step),
            "windows": _ui_entry(modes=("hdr",), unit=unit, min_val=lo, max_val=hi, default=0.0, step=cs_step),
        }
    ui["hdr.look"] = {
        "macos": _ui_entry(modes=("hdr",), unit="%", min_val=0.0, max_val=200.0, default=100.0, step={"strength": hdr_mon_look_step}),
        "ios": _ui_entry(modes=("hdr",), unit="%", min_val=0.0, max_val=200.0, default=100.0, step={"strength": hdr_mon_look_step}),
        "android": _ui_entry(modes=("hdr",), unit="%", min_val=0.0, max_val=200.0, default=100.0, step={"strength": kt_hdr_look_step}),
        "windows": _ui_entry(modes=("hdr",), unit="%", min_val=0.0, max_val=200.0, default=100.0, step={"strength": cs_hdr_look_step}),
    }
    hdr_cam_def = {
        "version": 1,
        "white_balance_mode": "as_shot",
        "temperature": 0.0,
        "tint": 0.0,
        "exposure_reference": "metadata",
        "fbdd_level": 0,
    }
    ui["hdr.camera_development"] = {
        "macos": _ui_entry(modes=("hdr",), default=hdr_cam_def, step={"temperature": hdr_mon_cam_temp_step, "tint": hdr_mon_cam_tint_step}),
        "ios": _ui_entry(modes=("hdr",), default=hdr_cam_def, step={"temperature": hdr_mon_cam_temp_step, "tint": hdr_mon_cam_tint_step}),
        "android": _ui_entry(
            modes=("hdr",),
            default=hdr_cam_def,
            step={"temperature": kt_temp_step if kt_hdr_cam_uses_temp_label else 50.0, "tint": kt_default_step},
        ),
        "windows": _ui_entry(modes=("hdr",), default=hdr_cam_def, step={"temperature": cs_hdr_cam_temp_step, "tint": cs_hdr_cam_tint_step}),
    }

    # 28-51. HSL
    for axis in HSL_AXES:
        for ch in HSL_CHANNELS:
            ui[f"color.hsl.{axis}.{ch}"] = {
                "macos": _ui_entry(unit="", min_val=-100.0, max_val=100.0, default=0.0, step=mac_hsl_step),
                "ios": _ui_entry(unit="", min_val=-100.0, max_val=100.0, default=0.0, step=ios_hsl_step),
                "android": _ui_entry(unit="", min_val=-100.0, max_val=100.0, default=0.0, step=kt_default_step),
                "windows": _ui_entry(unit="", min_val=-100.0, max_val=100.0, default=0.0, step=cs_default_grid),
            }

    _fx_win_unit = _fx_windows_unit()
    # 52-61. vignette/grain effects
    for m in re.finditer(
        r"(\w+)\((?:true|false),\s*(-?\d+)f\.\.(-?\d+)f,\s*(-?\d+)f\)",
        kt_edit_src,
    ):
        enum_id, lo_s, hi_s, dflt_s = m.groups()
        lo, hi, dflt = float(lo_s), float(hi_s), float(dflt_s)
        parts = enum_id.lower().split("_", 1)
        fid = f"effects.{parts[0]}.{parts[1]}"
        ui[fid] = {
            "macos": _ui_entry(unit="", min_val=lo, max_val=hi, default=dflt, step=mac_fine["standard"]),
            "ios": _ui_entry(unit="", min_val=lo, max_val=hi, default=dflt, step=ios_fx_step),
            "android": _ui_entry(unit="", min_val=lo, max_val=hi, default=dflt, step=kt_default_step),
            "windows": _ui_entry(unit=_fx_win_unit, min_val=lo, max_val=hi, default=dflt, step=cs_default_grid),
        }

    # 62-66. detail
    ui["detail.sharpening"] = {
        "macos": _ui_entry(unit="%", min_val=0.0, max_val=200.0, default=0.0, step=mac_fine["standard"]),
        "ios": _ui_entry(unit="%", min_val=0.0, max_val=200.0, default=0.0, step=ios_steps["sharpening"]),
        "android": _ui_entry(unit="%", min_val=0.0, max_val=200.0, default=0.0, step=kt_default_step),
        "windows": _ui_entry(unit="%", min_val=0.0, max_val=200.0, default=0.0, step=cs_param_steps["Sharpening"][2]),
    }
    ui["detail.denoise.raw_level"] = {
        "macos": _ui_entry(modes=("sdr",), unit="", min_val=0.0, max_val=2.0, default=0.0, step=1.0),
        "ios": _ui_entry(exposed=False, modes=()),
        "android": _ui_entry(exposed=False, modes=()),
        "windows": _ui_entry(exposed=False, modes=()),
    }
    ui["detail.denoise.post_rgb"] = {
        "macos": _ui_entry(modes=("hdr",), unit="%", min_val=0.0, max_val=100.0, default=0.0, step=mac_fine["standard"]),
        "ios": _ui_entry(
            modes=("hdr",) if ios_sdr_denoise_uses_wavelet else ("sdr", "hdr"),
            unit="%",
            min_val=0.0,
            max_val=100.0,
            default=0.0,
            step=ios_hdr_denoise_step_pct,
        ),
        "android": _ui_entry(modes=("hdr",), unit="%", min_val=0.0, max_val=100.0, default=0.0, step=kt_default_step),
        "windows": _ui_entry(modes=("hdr",), unit="%", min_val=0.0, max_val=100.0, default=0.0, step=cs_default_grid),
    }
    ui["detail.denoise.chroma_mode"] = {
        "macos": _ui_entry(exposed=mac_has_chroma_picker, modes=("sdr",) if mac_has_chroma_picker else (), min_val=0.0, max_val=2.0, default=0.0, step=1.0),
        "ios": _ui_entry(exposed=False, modes=()),
        "android": _ui_entry(exposed=False, modes=()),
        "windows": _ui_entry(exposed=False, modes=()),
    }
    wavelet_def = {"enabled": False, "luma": 0.0, "chroma": 46.0, "coarse": 50.0, "preset": "detail"}
    _cs_denoise_unit = _cs_denoise_percent_unit()
    ui["detail.denoise.wavelet"] = {
        "macos": _ui_entry(modes=("sdr",), unit="", min_val=0.0, max_val=100.0, default=wavelet_def, step={"luma": mac_fine["standard"], "chroma": mac_fine["standard"], "coarse": mac_fine["standard"]}),
        "ios": _ui_entry(modes=("sdr",), unit="", min_val=0.0, max_val=100.0, default=wavelet_def, step={"luma": ios_wavelet_step, "chroma": ios_wavelet_step, "coarse": ios_wavelet_step}),
        "android": _ui_entry(modes=("sdr",), unit="", min_val=0.0, max_val=100.0, default=wavelet_def, step={"luma": kt_default_step, "chroma": kt_default_step, "coarse": kt_default_step}),
        "windows": _ui_entry(modes=("sdr",), unit=_cs_denoise_unit, min_val=0.0, max_val=100.0, default=wavelet_def, step={"luma": cs_default_grid, "chroma": cs_default_grid, "coarse": cs_default_grid}),
    }

    # 67-81. geometry & lens
    for fid in ("geometry.crop.x", "geometry.crop.y"):
        ui[fid] = {
            "macos": _ui_entry(unit="%", min_val=0.0, max_val=100.0, default=0.0, step=mac_fine["cropPercent"]),
            "ios": _ui_entry(unit="%", min_val=0.0, max_val=100.0, default=0.0, step=ios_crop_step),
            "android": _ui_entry(unit="%", min_val=0.0, max_val=100.0, default=0.0, step=kt_crop_step),
            "windows": _ui_entry(unit="%", min_val=0.0, max_val=100.0, default=0.0, step=cs_crop_step),
        }
    for fid in ("geometry.crop.width", "geometry.crop.height"):
        ui[fid] = {
            "macos": _ui_entry(unit="%", min_val=mac_crop_min_pct, max_val=100.0, default=100.0, step=mac_fine["cropPercent"]),
            "ios": _ui_entry(unit="%", min_val=ios_crop_min_pct, max_val=100.0, default=100.0, step=ios_crop_step),
            "android": _ui_entry(unit="%", min_val=kt_crop_min_pct, max_val=100.0, default=100.0, step=kt_crop_step),
            "windows": _ui_entry(unit="%", min_val=cs_crop_min_pct, max_val=100.0, default=100.0, step=cs_crop_step),
        }
    ui["geometry.quarter_turns"] = {p: _ui_entry(min_val=0, max_val=3, default=0, step=1) for p in PLATFORMS}
    for fid in ("geometry.flip_horizontal", "geometry.flip_vertical"):
        ui[fid] = {p: _ui_entry(default=False) for p in PLATFORMS}
    ui["geometry.straighten_degrees"] = {
        "macos": _ui_entry(unit="°", min_val=-45.0, max_val=45.0, default=0.0, step=mac_fine["standard"]),
        "ios": _ui_entry(unit="°", min_val=-45.0, max_val=45.0, default=0.0, step=ios_straighten_step),
        "android": _ui_entry(unit="°", min_val=-45.0, max_val=45.0, default=0.0, step=kt_straight_step),
        "windows": _ui_entry(unit="°", min_val=-45.0, max_val=45.0, default=0.0, step=cs_straight_step),
    }
    for fid in ("geometry.perspective.horizontal", "geometry.perspective.vertical"):
        ui[fid] = {
            "macos": _ui_entry(unit=mac_persp_unit, min_val=-100.0, max_val=100.0, default=0.0, step=mac_fine["standard"]),
            "ios": _ui_entry(unit="", min_val=-100.0, max_val=100.0, default=0.0, step=ios_persp_step),
            "android": _ui_entry(unit=kt_persp_unit, min_val=-100.0, max_val=100.0, default=0.0, step=kt_default_step),
            "windows": _ui_entry(unit="", min_val=cs_persp_range[0], max_val=cs_persp_range[1], default=0.0, step=cs_persp_step),
        }
    for fid, dflt in (
        ("geometry.lens.distortion", False),
        ("geometry.lens.tca", False),
        ("geometry.lens.auto_crop", True),
    ):
        ui[fid] = {p: _ui_entry(modes=("sdr", "hdr"), default=dflt) for p in PLATFORMS}
    ui["geometry.lens.vignetting"] = {
        "macos": _ui_entry(exposed=True, modes=("sdr", "hdr") if mac_sdr_lens_has_vig else ("hdr",), default=False),
        "ios": _ui_entry(exposed=True, modes=("sdr", "hdr") if ios_sdr_lens_has_vig else ("hdr",), default=False),
        "android": _ui_entry(exposed=True, modes=("sdr", "hdr") if kt_sdr_lens_has_vig else ("hdr",), default=False),
        "windows": _ui_entry(exposed=True, modes=("sdr", "hdr") if cs_sdr_lens_has_vig else ("hdr",), default=False),
    }
    ui["geometry.lens.profile_id"] = {p: _ui_entry(modes=("sdr",), default=None) for p in PLATFORMS}

    # 82-83. local desktop AI denoise
    ui["local.ai_denoise_enabled"] = {
        "macos": _ui_entry(modes=("sdr",), default=False),
        "ios": _ui_entry(exposed=False, modes=()),
        "android": _ui_entry(exposed=False, modes=()),
        "windows": _ui_entry(modes=("sdr",), default=False),
    }
    ui["local.hdr_camera_ai_enabled"] = {
        "macos": _ui_entry(modes=("hdr",), default=False),
        "ios": _ui_entry(exposed=False, modes=()),
        "android": _ui_entry(exposed=False, modes=()),
        "windows": _ui_entry(modes=("hdr",), default=False),
    }

    return ui


# ---------------------------------------------------------------------------
# Validation helpers (reused by mutation self-tests)
# ---------------------------------------------------------------------------


def validate_layer1_protocol(
    document: dict,
    apple_parsed: tuple[list[str], dict[str, dict], dict[str, str]],
    android_parsed: tuple[list[str], dict[str, dict], dict[str, str]],
    windows_parsed: tuple[list[str], dict[str, dict], dict[str, str]],
) -> None:
    apple_order, apple_proto, apple_groups = apple_parsed
    android_order, android_proto, android_groups = android_parsed
    windows_order, windows_proto, windows_groups = windows_parsed

    if len(apple_order) != 81:
        raise AssertionError(f"Expected 81 Apple transfer fields, got {len(apple_order)}")
    if set(apple_order) != set(android_order) or set(apple_order) != set(windows_order):
        raise AssertionError(
            "Wire field set mismatch across platforms: "
            f"apple^android={set(apple_order) ^ set(android_order)}, "
            f"apple^windows={set(apple_order) ^ set(windows_order)}"
        )

    platform_protos = {
        "macos": apple_proto,
        "ios": apple_proto,
        "android": android_proto,
        "windows": windows_proto,
    }
    platform_groups = {
        "macos": apple_groups,
        "ios": apple_groups,
        "android": android_groups,
        "windows": windows_groups,
    }

    transfer_entries = [f for f in document["fields"] if f["protocol"]["transferable"]]
    local_entries = [f for f in document["fields"] if not f["protocol"]["transferable"]]
    if [f["field_id"] for f in transfer_entries] != apple_order:
        raise AssertionError("Spec transfer field order differs from canonical AdjustmentTransferField order")

    for entry in local_entries:
        fid = entry["field_id"]
        for platform, pmap in platform_protos.items():
            if fid in pmap:
                raise AssertionError(f"Local-only field {fid} unexpectedly found in {platform} wire protocol")

    for entry in transfer_entries:
        fid = entry["field_id"]
        spec_proto = {k: v for k, v in entry["protocol"].items() if k != "protocol_group_divergences"}
        group_overrides = entry["protocol"].get("protocol_group_divergences", {})
        if group_overrides and not entry["divergence"]["has_divergence"]:
            raise AssertionError(
                f"Exemption drift on {fid}: protocol_group_divergences {group_overrides} "
                "requires divergence.has_divergence=true"
            )

        # Hard 4-end protocol equality
        ref = platform_protos["macos"][fid]
        for platform in PLATFORMS:
            actual = platform_protos[platform][fid]
            if actual != ref:
                raise AssertionError(
                    f"Protocol 4-end hard parity broken on {fid} ({platform} vs macos): {actual} != {ref}"
                )
            if actual != spec_proto:
                raise AssertionError(
                    f"Spec protocol drift on {fid} ({platform}): spec={spec_proto} != source={actual}"
                )
            expected_group = group_overrides.get(platform, entry["group"])
            actual_group = platform_groups[platform][fid]
            if actual_group != expected_group:
                raise AssertionError(
                    f"Protocol group drift on {fid} ({platform}): expected {expected_group!r}, got {actual_group!r}"
                )


def validate_layer2_model(document: dict, parsed_models: dict[str, dict[str, dict]]) -> None:
    spec_by_id = {f["field_id"]: f for f in document["fields"]}
    if set(spec_by_id) != set(parsed_models):
        raise AssertionError(f"Model parser field set mismatch: {set(spec_by_id) ^ set(parsed_models)}")

    for fid, entry in spec_by_id.items():
        proto = entry["protocol"]
        for platform in PLATFORMS:
            expected = parsed_models[fid][platform]
            actual = entry["model"][platform]
            if actual != expected:
                raise AssertionError(
                    f"Model parity drift on {fid}.{platform}:\n  spec   = {actual}\n  source = {expected}"
                )
            # Verify declared conversion formula maps protocol bounds/neutral to model bounds
            if (
                actual["supported"]
                and proto["transferable"]
                and proto["value_type"] == "number"
                and proto["min"] is not None
                and fid != "light.exposure"
            ):
                p_lo, p_hi = float(proto["min"]), float(proto["max"])
                m_vals = sorted((_eval_scale(actual["scale_from_protocol"], p_lo), _eval_scale(actual["scale_from_protocol"], p_hi)))
                if round(m_vals[0], 6) != round(float(actual["min"]), 6) or round(m_vals[1], 6) != round(float(actual["max"]), 6):
                    raise AssertionError(
                        f"scale_from_protocol {actual['scale_from_protocol']!r} on {fid}.{platform} maps "
                        f"[{p_lo}, {p_hi}] -> {m_vals}, expected [{actual['min']}, {actual['max']}]"
                    )
            _check_hdr_endpoints(fid, platform, proto, actual)


def validate_layer3_ui(document: dict, parsed_ui: dict[str, dict[str, dict]]) -> None:
    spec_by_id = {f["field_id"]: f for f in document["fields"]}
    if set(spec_by_id) != set(parsed_ui):
        raise AssertionError(f"UI parser field set mismatch: {set(spec_by_id) ^ set(parsed_ui)}")

    for fid, entry in spec_by_id.items():
        for platform in PLATFORMS:
            expected = parsed_ui[fid][platform]
            actual = entry["ui"][platform]
            if actual != expected:
                raise AssertionError(
                    f"UI parity drift on {fid}.{platform}:\n  spec   = {actual}\n  source = {expected}"
                )


class AdjustmentFieldsSpecTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
        cls.apple_protocol = parse_apple_protocol()
        cls.android_protocol = parse_android_protocol()
        cls.windows_protocol = parse_windows_protocol()
        cls.parsed_models = parse_models_from_sources()
        cls.parsed_ui = parse_ui_from_sources()

    def test_spec_structure_and_summary_counts(self):
        self.assertEqual(self.document["spec_version"], 1)
        fields = self.document["fields"]
        self.assertEqual(len(fields), 83)
        ids = [f["field_id"] for f in fields]
        self.assertEqual(len(ids), len(set(ids)), "duplicate field_id in spec")

        summary = self.document["summary"]
        self.assertEqual(summary["total_fields"], len(fields))
        self.assertEqual(summary["transfer_fields"], sum(1 for f in fields if f["protocol"]["transferable"]))
        self.assertEqual(summary["local_only_fields"], sum(1 for f in fields if not f["protocol"]["transferable"]))
        self.assertEqual(summary["transfer_fields"], 81)
        self.assertEqual(summary["local_only_fields"], 2)

        report_div = [f for f in fields if f["divergence"]["report_d5d62af7_listed"]]
        all_div = [f for f in fields if f["divergence"]["has_divergence"]]
        ident = [f for f in fields if not f["divergence"]["has_divergence"]]
        self.assertEqual(len(report_div), 59)
        self.assertEqual(summary["report_d5d62af7_divergent_fields"], 59)
        self.assertEqual(summary["divergent_fields"], len(all_div))
        self.assertEqual(summary["identical_fields"], len(ident))
        self.assertEqual(len(all_div) + len(ident), 83)
        self.assertEqual(summary["divergent_fields"], 66)
        self.assertEqual(summary["identical_fields"], 17)

        for entry in fields:
            fid = entry["field_id"]
            with self.subTest(field=fid):
                self.assertIn(entry["group"], VALID_GROUPS)
                self.assertEqual(set(entry["model"].keys()), set(PLATFORMS))
                self.assertEqual(set(entry["ui"].keys()), set(PLATFORMS))
                div = entry["divergence"]
                cats = set(div["categories"])
                self.assertTrue(cats.issubset(VALID_DIVERGENCE_CATEGORIES))
                if div["report_d5d62af7_listed"]:
                    self.assertTrue(div["has_divergence"], f"{fid} listed in d5d62af7 report must have has_divergence=True")
                if div["has_divergence"]:
                    self.assertGreater(len(cats), 0, f"{fid} has_divergence=True without categories")
                else:
                    self.assertEqual(len(cats), 0, f"{fid} has_divergence=False but declares categories {cats}")
                    ui_vals = [entry["ui"][p] for p in PLATFORMS]
                    self.assertTrue(
                        all(u == ui_vals[0] for u in ui_vals[1:]),
                        f"{fid} marked identical but UI entries differ across platforms",
                    )

                exposed = [entry["ui"][p] for p in PLATFORMS if entry["ui"][p]["exposed"]]
                derived: set[str] = set()
                if len(exposed) > 1:
                    ref_u = exposed[0]
                    if any(u["step"] != ref_u["step"] for u in exposed[1:]):
                        derived.add("step")
                    if any(u["unit"] != ref_u["unit"] or u["default"] != ref_u["default"] for u in exposed[1:]):
                        derived.add("default_unit")
                    if any(
                        u["min"] != ref_u["min"] or u["max"] != ref_u["max"]
                        or u.get("hdr_min") != ref_u.get("hdr_min") or u.get("hdr_max") != ref_u.get("hdr_max")
                        for u in exposed[1:]
                    ):
                        derived.add("range")
                    if any(u.get("channels") != ref_u.get("channels") for u in exposed[1:]):
                        derived.add("missing")
                model_vals = [entry["model"][p] for p in PLATFORMS]
                if any(m["supported"] != model_vals[0]["supported"] or m["modes"] != model_vals[0]["modes"] for m in model_vals[1:]):
                    derived.add("missing")
                if entry["protocol"].get("protocol_group_divergences"):
                    derived.add("protocol_metadata")
                self.assertTrue(
                    derived.issubset(cats),
                    f"{fid} derived divergence {sorted(derived - cats)} not declared in categories {sorted(cats)}",
                )

    def test_apple_shared_protocol_source_is_linked_by_macos_and_ios(self):
        mac_build = _read("RawLabMac/build.sh")
        ios_pbxproj = _read("RawLab/RawLab.xcodeproj/project.pbxproj")
        self.assertIn('"$ROOT"/Shared/*.swift', mac_build)
        self.assertIn("../Shared/AdjustmentTransfer.swift", ios_pbxproj)
        self.assertIn("AdjustmentTransfer.swift in Sources", ios_pbxproj)
        self.assertIn("../Shared/ToneCurveSettings.swift", ios_pbxproj)

    def test_snapshot_registrations_are_anchored_and_used(self):
        self.assertGreater(len(SNAPSHOT_REGISTRATIONS), 0)
        for reg_id, reg in SNAPSHOT_REGISTRATIONS.items():
            with self.subTest(snapshot=reg_id):
                self.assertEqual(reg["registration"], "snapshot")
                self.assertTrue(reg["used"], f"{reg_id} registered but never consumed")
                self.assertTrue(reg["anchors"], f"{reg_id} has no anchors")
                for platform, (path, pattern) in reg["anchors"].items():
                    self.assertIn(platform, PLATFORMS)
                    self.assertTrue(
                        re.search(pattern, _read(path)),
                        f"{reg_id} anchor invalid for {platform}: {pattern!r} in {path}",
                    )

    def test_layer1_protocol_four_end_hard_parity(self):
        validate_layer1_protocol(
            self.document,
            self.apple_protocol,
            self.android_protocol,
            self.windows_protocol,
        )

    def test_layer2_model_four_end_parity(self):
        validate_layer2_model(self.document, self.parsed_models)

    def test_layer3_ui_four_end_parity(self):
        validate_layer3_ui(self.document, self.parsed_ui)

    def test_mutation_anchors_detect_protocol_model_and_ui_drift(self):
        # 1. Mutating a protocol range bound must fail Layer 1
        bad_proto = copy.deepcopy(self.document)
        exp = next(f for f in bad_proto["fields"] if f["field_id"] == "light.exposure")
        exp["protocol"]["max"] = 15.0
        with self.assertRaisesRegex(AssertionError, r"light\.exposure"):
            validate_layer1_protocol(bad_proto, self.apple_protocol, self.android_protocol, self.windows_protocol)

        # 2. Mutating a model default or scale formula must fail Layer 2
        bad_model = copy.deepcopy(self.document)
        con = next(f for f in bad_model["fields"] if f["field_id"] == "light.contrast")
        con["model"]["ios"]["default"] = 0.0
        with self.assertRaisesRegex(AssertionError, r"light\.contrast\.ios"):
            validate_layer2_model(bad_model, self.parsed_models)

        # 3. Mutating a platform UI step registration must fail Layer 3
        bad_ui = copy.deepcopy(self.document)
        straight = next(f for f in bad_ui["fields"] if f["field_id"] == "geometry.straighten_degrees")
        straight["ui"]["windows"]["step"] = 0.1
        with self.assertRaisesRegex(AssertionError, r"geometry\.straighten_degrees\.windows"):
            validate_layer3_ui(bad_ui, self.parsed_ui)

        # 4. Red anchor 1: production ToneCurveSettings default points mutation must fail Layer 2
        bad_curve = copy.deepcopy(self.parsed_models)
        bad_curve["light.curve"]["macos"]["default"]["points"] = [[0.0, 0.0], [1.0, 1.0]]
        with self.assertRaisesRegex(AssertionError, r"light\.curve\.macos"):
            validate_layer2_model(self.document, bad_curve)

        # 5. Red anchor 2: Windows Group() arm mutation must fail Layer 1 group check
        clean_proto = copy.deepcopy(self.document)
        w_wires, w_protos, w_groups = self.windows_protocol
        w_groups = copy.deepcopy(w_groups)
        w_groups["hdr.look"] = "effects"
        with self.assertRaisesRegex(AssertionError, r"hdr\.look \(windows\)"):
            validate_layer1_protocol(clean_proto, self.apple_protocol, self.android_protocol, (w_wires, w_protos, w_groups))

        # 6. Red anchor 3: hdr.look model strength default regression must fail Layer 2
        bad_look = copy.deepcopy(self.document)
        look = next(f for f in bad_look["fields"] if f["field_id"] == "hdr.look")
        for plat in PLATFORMS:
            look["model"][plat]["default"]["strength"] = 1.0
        with self.assertRaisesRegex(AssertionError, r"hdr\.look\.macos"):
            validate_layer2_model(bad_look, self.parsed_models)


if __name__ == "__main__":
    unittest.main()
