"""Four-end static parity contract for Shared/specs/adjustment-fields-v1.json.

Three assertion layers are enforced directly against four-end production sources:
1. Protocol layer (hard contract): Shared Swift (Mac + iOS), Android Kotlin, and
   Windows C# must define identical wire field sets, value types, nullability,
   ranges, exclusivity, integer constraints, allowed values, and object keys,
   matching each entry's ``protocol`` block in adjustment-fields-v1.json.
2. Model layer: Each platform's internal storage bounds, nullability, defaults,
   quantization, and protocol->model conversion formulas must match ``model``.
3. UI layer: Each platform's current UI exposure, display units, ranges,
   defaults, and steps must match ``ui`` (parsed directly per end).
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
# Hard-fail parse helpers + explicit unanchored-skip registry
# ---------------------------------------------------------------------------

# Explicit registry for any (layer, field_id, platform, attribute) whose value
# genuinely lacks a static source anchor on that platform. Never silently skip
# an attribute without registering it here with a documented reason.
UNANCHORED_SKIPS: dict[tuple[str, str, str, str], str] = {}


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


def _require_absent(needle, src, field, where):
    if needle in src:
        raise AssertionError(f"Parse failed for {field}: text {needle!r} unexpectedly present in {where}")


def _extract_brace_block(src, anchor_pattern, field, where, flags=0):
    """Extract the brace-balanced block {...} following `anchor_pattern`."""
    m = _need(anchor_pattern, src, field, where, flags)
    start = src.find("{", m.start())
    if start < 0:
        raise AssertionError(f"Parse failed for {field}: opening '{{' not found after {anchor_pattern!r} in {where}")
    depth = 0
    for idx in range(start, len(src)):
        ch = src[idx]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return src[m.start() : idx + 1]
    raise AssertionError(f"Parse failed for {field}: unbalanced braces after {anchor_pattern!r} in {where}")


def _extract_kt_class_block(src, anchor_pattern, field, where, flags=0):
    """Extract a Kotlin class declaration from `anchor_pattern`, skipping constructor `(...)` lambdas, through its `{...}` body."""
    m = _need(anchor_pattern, src, field, where, flags)
    idx = m.end()
    n = len(src)
    while idx < n and src[idx].isspace():
        idx += 1
    if idx < n and src[idx] == "(":
        pdepth = 0
        while idx < n:
            if src[idx] == "(":
                pdepth += 1
            elif src[idx] == ")":
                pdepth -= 1
                if pdepth == 0:
                    idx += 1
                    break
            idx += 1
    start = src.find("{", idx)
    if start < 0:
        raise AssertionError(f"Parse failed for {field}: opening '{{' not found after {anchor_pattern!r} in {where}")
    depth = 0
    for pos in range(start, n):
        ch = src[pos]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return src[m.start() : pos + 1]
    raise AssertionError(f"Parse failed for {field}: unbalanced braces after {anchor_pattern!r} in {where}")


def _parse_quoted_list(expr):
    return re.findall(r'"([^"]+)"', expr)


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
        payload_p = xfer_p
        hdr_p = "Shared/HDRSettings.swift"
        hdr_tr_p = "Shared/HDRAdjustmentTransfer.swift"
        tc_p = "Shared/ToneCurveSettings.swift"
    elif platform == "android":
        base = "RawLabAndroid/app/src/main/java/com/rawlab/android/"
        xfer_p = base + "adjustments/AdjustmentTransfer.kt"
        payload_p = base + "adjustments/AdjustmentPayload.kt"
        hdr_p = base + "settings/HDRSettings.kt"
        hdr_tr_p = xfer_p
        tc_p = base + "settings/ToneCurveSettings.kt"
    else:
        xfer_p = "RawLabWindows/AdjustmentPayload.cs"
        payload_p = xfer_p
        hdr_p = "RawLabWindows/HDRSettings.cs"
        hdr_tr_p = "RawLabWindows/HDRAdjustmentTransfer.cs"
        tc_p = "RawLabWindows/ToneCurveSettings.cs"
    return {
        "xfer": (xfer_p, _strip_line_comments(_read(xfer_p))),
        "payload": (payload_p, _strip_line_comments(_read(payload_p))),
        "hdrs": (hdr_p, _strip_line_comments(_read(hdr_p))),
        "hdr_tr": (hdr_tr_p, _strip_line_comments(_read(hdr_tr_p))),
        "tc": (tc_p, _strip_line_comments(_read(tc_p))),
    }


def _object_sub_fields(platform):
    """Per-end object protocol sub-field parsing directly from each platform's own files."""
    srcs = _sub_end_sources(platform)
    xfer_path, xfer = srcs["xfer"]
    payload_path, payload = srcs["payload"]
    hdr_path, hdrs = srcs["hdrs"]
    hdr_tr_path, hdr_tr = srcs["hdr_tr"]
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

    mode_allowed = _parse_mode_allowed()

    def _parse_points_facts():
        if platform in ("macos", "ios"):
            counts = _need(r"\((\d+)\.\.\.(\d+)\)\.contains\(points\.count\)", tcs, "light.curve points", tc_path)
            first = _need(r"points\.first == ToneCurvePoint\(x: (-?[\d.]+), y: (-?[\d.]+)\)", tcs, "light.curve points", tc_path)
            last = _need(r"points\.last == ToneCurvePoint\(x: (-?[\d.]+), y: (-?[\d.]+)\)", tcs, "light.curve points", tc_path)
            coord = _need(r"\((-?\d+(?:\.\d+)?)\.\.\.(-?\d+(?:\.\d+)?)\)\.contains\(point\.x\)", tcs, "light.curve points", tc_path)
            _need(r"\(" + re.escape(coord.group(1)) + r"\.\.\." + re.escape(coord.group(2)) + r"\)\.contains\(point\.y\)", tcs, "light.curve points y", tc_path)
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
        if platform == "android":
            _need(r"mode == ToneCurveMode\.LEGACY\) this\.points\.isEmpty\(\)", tcs, "light.curve legacy points", tc_path)
            counts = _need(r"this\.points\.size in (\d+)\.\.(\d+)", tcs, "light.curve points", tc_path)
            first = _need(r"this\.points\.first\(\) == ToneCurvePoint\((-?[\d.]+),\s*(-?[\d.]+)\)", tcs, "light.curve points", tc_path)
            last = _need(r"this\.points\.last\(\) == ToneCurvePoint\((-?[\d.]+),\s*(-?[\d.]+)\)", tcs, "light.curve points", tc_path)
            coord = _need(
                r"it\.x in (-?\d+(?:\.\d+)?)\.\.(-?\d+(?:\.\d+)?) && it\.y in (-?\d+(?:\.\d+)?)\.\.(-?\d+(?:\.\d+)?)",
                tcs, "light.curve points coords", tc_path,
            )
            if (coord.group(1), coord.group(2)) != (coord.group(3), coord.group(4)):
                raise AssertionError(f"Android light.curve x/y coord range mismatch in {tc_path}")
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
        legacy_count = int(_need(r"Mode == ToneCurveMode\.Legacy \? Points\.Count == (\d+)", tcs, "light.curve legacy points", tc_path).group(1))
        counts = _need(r"Points\.Count is >= (\d+) and <= (\d+)", tcs, "light.curve points", tc_path)
        _need(r"GetArrayLength\(\) > " + re.escape(counts.group(2)), tcs, "light.curve points max", tc_path)
        first = _need(r"Points\[0\] == new ToneCurvePoint\((-?[\d.]+),\s*(-?[\d.]+)\)", tcs, "light.curve points", tc_path)
        last = _need(r"Points\[\^1\] == new ToneCurvePoint\((-?[\d.]+),\s*(-?[\d.]+)\)", tcs, "light.curve points", tc_path)
        coord = _need(
            r"p\.X is >= (-?\d+(?:\.\d+)?) and <= (-?\d+(?:\.\d+)?) && p\.Y is >= (-?\d+(?:\.\d+)?) and <= (-?\d+(?:\.\d+)?)",
            tcs, "light.curve points coords", tc_path,
        )
        if (coord.group(1), coord.group(2)) != (coord.group(3), coord.group(4)):
            raise AssertionError(f"Windows light.curve x/y coord range mismatch in {tc_path}")
        return {
            "value_type": "array",
            "legacy_count": legacy_count,
            "custom_min_count": int(counts.group(1)),
            "custom_max_count": int(counts.group(2)),
            "coord_min": float(coord.group(1)),
            "coord_max": float(coord.group(2)),
            "endpoints": [
                [float(first.group(1)), float(first.group(2))],
                [float(last.group(1)), float(last.group(2))],
            ],
        }

    points_fact = _parse_points_facts()

    def _parse_channels_fact():
        if platform in ("macos", "ios"):
            _need(r'isSubset\(of: \["mode", "points", "channels"\]\)', xfer, "light.curve channels", xfer_path)
        elif platform == "android":
            _need(r'it in setOf\("mode", "points", "channels"\)', tcs, "light.curve channels", tc_path)
        else:
            _need(r'TryGetProperty\("channels"', tcs, "light.curve channels", tc_path)
        return {"value_type": "object", "optional": True, "allowed_keys": ["red", "green", "blue"]}

    channels_fact = _parse_channels_fact()
    out["light.curve"] = {
        "mode": {"value_type": "string", "allowed_values": mode_allowed},
        "points": points_fact,
        "channels": channels_fact,
    }

    def _parse_looks_reference():
        if platform in ("macos", "ios"):
            block = _need(r"case \.look:(.*?)case \.lensProfile:", payload, "looks.reference", payload_path, re.S).group(1)
            neutral = _need(r'if kind == "(\w+)" \{ return object\["id"\] == \.null \}', block, "looks.reference neutral", payload_path).group(1)
            non_neutral = _parse_quoted_list(_need(r"guard \[([^\]]+)\]\.contains\(kind\), let id = object\[\"id\"\]\?\.string,\s*!id\.isEmpty", block, "looks.reference non-neutral", payload_path, re.S).group(1))
        elif platform == "android":
            block = _need(r"AdjustmentField\.LOOK -> \{(.*?)\n\s+\}", payload, "looks.reference", payload_path, re.S).group(1)
            neutral = _need(r'if \(look\["kind"\]\?\.text == "(\w+)"\) return look\["id"\] == AdjustmentValue\.Null', block, "looks.reference neutral", payload_path).group(1)
            non_neutral = _parse_quoted_list(_need(r'look\["kind"\]\?\.text in setOf\(([^)]+)\) &&\s*id\.isNotEmpty\(\)', block, "looks.reference non-neutral", payload_path, re.S).group(1))
        else:
            block = _need(r"case AdjustmentField\.Look:(.*?)case AdjustmentField\.WaveletDenoise:", payload, "looks.reference", payload_path, re.S).group(1)
            neutral = _need(r'kind=="(\w+)" \? Null\(value\.GetProperty\("id"\)\)', block, "looks.reference neutral", payload_path).group(1)
            non_neutral = _parse_quoted_list(_need(r"kind is ([^&]+?) &&\s*id is \{Length:>0\}", block, "looks.reference non-neutral", payload_path, re.S).group(1))
        return {
            "kind": {"value_type": "string", "allowed_values": [neutral] + non_neutral},
            "id": {"value_type": "string", "nullable_when_kind": neutral, "non_empty": True},
        }

    out["looks.reference"] = _parse_looks_reference()

    if platform in ("macos", "ios"):
        cg_where = "Shared/ColorGradingSettings.swift"
        cg_src = _strip_line_comments(_read(cg_where))
        cg_hue = _need(r"hue >= ([0-9.]+) && hue < ([0-9.]+)", cg_src, "color.grading.wheel hue bounds", cg_where)
        cg_sat = _need(r"\(([0-9.]+)\.\.\.([0-9.]+)\)\.contains\(saturation\)", cg_src, "color.grading.wheel saturation bounds", cg_where)
    elif platform == "android":
        cg_where = "RawLabAndroid/app/src/main/java/com/rawlab/android/settings/ColorGradingSettings.kt"
        cg_src = _strip_line_comments(_read(cg_where))
        cg_hue = _need(r"hue >= ([0-9.]+) && hue < ([0-9.]+)", cg_src, "color.grading.wheel hue bounds", cg_where)
        cg_sat = _need(r"saturation in ([0-9.]+)\.\.([0-9.]+)", cg_src, "color.grading.wheel saturation bounds", cg_where)
    else:
        cg_where = "RawLabWindows/ColorGradingSettings.cs"
        cg_src = _strip_line_comments(_read(cg_where))
        cg_hue = _need(r"Hue is >= ([0-9.]+) and < ([0-9.]+)", cg_src, "color.grading.wheel hue bounds", cg_where)
        cg_sat = _need(r"Saturation is >= ([0-9.]+) and <= ([0-9.]+)", cg_src, "color.grading.wheel saturation bounds", cg_where)
    grad_subs = {
        "hue": {"value_type": "number", "min": float(cg_hue.group(1)), "max": float(cg_hue.group(2)), "exclusive_max": True},
        "saturation": {"value_type": "number", "min": float(cg_sat.group(1)), "max": float(cg_sat.group(2))},
    }
    for zone in ("shadows", "midtones", "highlights"):
        out[f"color.grading.{zone}"] = copy.deepcopy(grad_subs)

    def _look_scope():
        if platform == "windows":
            return _extract_brace_block(hdrs, r"record HDRLookSettings\(", "hdr.look scope", hdr_path)
        if platform == "android":
            return _extract_brace_block(hdrs, r"data class HDRLookSettings\(", "hdr.look scope", hdr_path)
        return _extract_brace_block(hdrs, r"struct HDRLookSettings\b", "hdr.look scope", hdr_path)

    look_scope = _look_scope()

    def _look_sha_len():
        if platform in ("macos", "ios"):
            return int(_need(r"\.utf8\.count == (\d+)", look_scope, "hdr.look sha256", hdr_path).group(1))
        if platform == "android":
            return int(_need(r"\[a-f0-9\]\{(\d+)\}", look_scope, "hdr.look sha256", hdr_path).group(1))
        return int(_need(r"value is \{ Length: (\d+) \}", look_scope, "hdr.look sha256", hdr_path).group(1))

    sha_len = _look_sha_len()

    def _look_name_bounds():
        if platform in ("macos", "ios"):
            m = _need(r"\((\d+)\.\.\.(\d+)\)\.contains\(name\.utf8\.count\)", look_scope, "hdr.look name", hdr_path)
            return int(m.group(1)), int(m.group(2))
        if platform == "android":
            _require("!name.isNullOrEmpty()", look_scope, "hdr.look name non-empty", hdr_path)
            m = _need(r"UTF_8\)\.size <= (\d+)", look_scope, "hdr.look name", hdr_path)
            return 1, int(m.group(1))
        _require("Name is { Length: > 0 }", look_scope, "hdr.look name non-empty", hdr_path)
        m = _need(r"GetByteCount\(\w+\) <= (\d+)", look_scope, "hdr.look name", hdr_path)
        return 1, int(m.group(1))

    name_min, name_max = _look_name_bounds()

    def _look_strength_bounds():
        if platform in ("macos", "ios"):
            m = _need(r"\((\d+)\.\.\.(\d+)\)\.contains\(strength\)", look_scope, "hdr.look strength", hdr_path)
        elif platform == "android":
            m = _need(r"strength in (-?[\d.]+)f\.\.(-?[\d.]+)f", look_scope, "hdr.look strength", hdr_path)
        else:
            m = _need(r"Strength is >= (-?[\d.]+) and <= (-?[\d.]+)", look_scope, "hdr.look strength", hdr_path)
        return float(m.group(1)), float(m.group(2))

    strength_lo, strength_hi = _look_strength_bounds()
    out["hdr.look"] = {
        "sha256": {"value_type": "string", "hex_length": sha_len},
        "name": {"value_type": "string", "min_utf8_bytes": name_min, "max_utf8_bytes": name_max},
        "strength": {"value_type": "number", "min": strength_lo, "max": strength_hi},
    }

    def _cam_scope():
        if platform in ("macos", "ios"):
            return _extract_brace_block(hdrs, r"struct HDRCameraDevelopmentSettings\b", "hdr.camera_development", hdr_path)
        if platform == "android":
            return _extract_brace_block(hdrs, r"data class HDRCameraDevelopmentSettings\(", "hdr.camera_development", hdr_path)
        return _extract_brace_block(hdrs, r"record HDRCameraDevelopmentSettings\(", "hdr.camera_development", hdr_path)

    cam_scope = _cam_scope()

    def _cam_version():
        if platform in ("macos", "ios"):
            v_model = int(_need(r"var version = (\d+)", cam_scope, "hdr.camera_development version", hdr_path).group(1))
            v_wire = int(_need(r'"version": \.number\((\d+)\)', hdr_tr, "hdr.camera_development wire version", hdr_tr_path).group(1))
            if v_model != v_wire:
                raise AssertionError(f"Apple hdr.camera_development version mismatch: {v_model} != {v_wire}")
            return v_model
        if platform == "android":
            v_decode = int(_need(r'camera\["version"\]\?\.number != (\d+)\.0', payload, "hdr.camera_development version", payload_path).group(1))
            v_encode = int(_need(r'"version" to AdjustmentValue\.Number\((\d+)\.0\)', hdr_tr, "hdr.camera_development wire version", hdr_tr_path).group(1))
            if v_decode != v_encode:
                raise AssertionError(f"Android hdr.camera_development version mismatch: {v_decode} != {v_encode}")
            return v_decode
        v_decode = int(_need(r'value\.GetProperty\("version"\)\.GetInt32\(\) != (\d+)', hdrs, "hdr.camera_development version", hdr_path).group(1))
        v_encode = int(_need(r"CameraValue\([^)]*\).*?version = (\d+)", hdr_tr, "hdr.camera_development wire version", hdr_tr_path, re.S).group(1))
        if v_decode != v_encode:
            raise AssertionError(f"Windows hdr.camera_development version mismatch: {v_decode} != {v_encode}")
        return v_decode

    version = _cam_version()

    def _cam_wb_and_exposure_enums():
        if platform in ("macos", "ios"):
            wb = _need(r'enum WhiteBalance:\s*String.*?\{\s*case asShot\s*=\s*"([^"]+)",\s*(\w+)\s*\}', cam_scope, "hdr.camera_development wb enum", hdr_path, re.S)
            exp = _need(r'enum ExposureReference:\s*String.*?\{\s*case (\w+),\s*(\w+)\s*\}', cam_scope, "hdr.camera_development exposure ref", hdr_path, re.S)
            return [wb.group(1), wb.group(2)], [exp.group(1), exp.group(2)]
        if platform == "android":
            fn = _extract_brace_block(payload, r"internal fun AdjustmentValue\.hdrCameraDevelopment\(\)", "hdr.camera_development decode", payload_path)
            wb = _parse_quoted_list(_need(r"mode !in setOf\(([^)]+)\)", fn, "hdr.camera_development wb", payload_path).group(1))
            exp = _parse_quoted_list(_need(r"exposure !in setOf\(([^)]+)\)", fn, "hdr.camera_development exp", payload_path).group(1))
            return wb, exp
        fn = _extract_brace_block(hdrs, r"ReadCameraDevelopment\(JsonElement value\)", "hdr.camera_development decode", hdr_path)
        wb = _need(r'value\.GetProperty\("white_balance_mode"\)\.GetString\(\) switch \{\s*"([^"]+)" => false,\s*"([^"]+)" => true', fn, "hdr.camera_development wb", hdr_path, re.S)
        exp = _need(r'value\.GetProperty\("exposure_reference"\)\.GetString\(\) switch \{\s*"([^"]+)" => false,\s*"([^"]+)" => true', fn, "hdr.camera_development exp", hdr_path, re.S)
        return [wb.group(1), wb.group(2)], [exp.group(1), exp.group(2)]

    cam_wb_allowed, cam_exp_allowed = _cam_wb_and_exposure_enums()

    def _cam_temp():
        if platform in ("macos", "ios"):
            m = _need(r"\((\d+)\.\.\.(\d+)\)\.contains\(temperature\)", cam_scope, "hdr.camera_development temperature", hdr_path)
            as_shot = float(_need(r"whiteBalance == \.asShot \? temperature == (-?[\d.]+) && tint == -?[\d.]+", cam_scope, "hdr.camera_development as_shot temp", hdr_path).group(1))
        elif platform == "android":
            m = _need(r"temperature in (-?[\d.]+)f\.\.(-?[\d.]+)f", cam_scope, "hdr.camera_development temperature", hdr_path)
            as_shot = float(_need(r"else temperature == (-?[\d.]+)f && tint == -?[\d.]+f", cam_scope, "hdr.camera_development as_shot temp", hdr_path).group(1))
        else:
            m = _need(r"Temperature is >= (-?[\d.]+) and <= (-?[\d.]+)", cam_scope, "hdr.camera_development temperature", hdr_path)
            as_shot = float(_need(r": Temperature == (-?[\d.]+) && Tint == -?[\d.]+", cam_scope, "hdr.camera_development as_shot temp", hdr_path).group(1))
        return as_shot, float(m.group(1)), float(m.group(2))

    temp_as_shot, temp_min, temp_max = _cam_temp()

    def _cam_tint():
        if platform in ("macos", "ios"):
            m = _need(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(tint\)", cam_scope, "hdr.camera_development tint", hdr_path)
            as_shot = float(_need(r"whiteBalance == \.asShot \? temperature == -?[\d.]+ && tint == (-?[\d.]+)", cam_scope, "hdr.camera_development as_shot tint", hdr_path).group(1))
        elif platform == "android":
            m = _need(r"tint in (-?[\d.]+)f\.\.(-?[\d.]+)f", cam_scope, "hdr.camera_development tint", hdr_path)
            as_shot = float(_need(r"else temperature == -?[\d.]+f && tint == (-?[\d.]+)f", cam_scope, "hdr.camera_development as_shot tint", hdr_path).group(1))
        else:
            m = _need(r"Tint is >= (-?[\d.]+) and <= (-?[\d.]+)", cam_scope, "hdr.camera_development tint", hdr_path)
            as_shot = float(_need(r": Temperature == -?[\d.]+ && Tint == (-?[\d.]+)", cam_scope, "hdr.camera_development as_shot tint", hdr_path).group(1))
        return as_shot, float(m.group(1)), float(m.group(2))

    tint_as_shot, tint_min, tint_max = _cam_tint()

    def _cam_fbdd():
        if platform in ("macos", "ios"):
            m = _need(r"\((\d+)\.\.\.(\d+)\)\.contains\(fbddLevel\)", cam_scope, "hdr.camera_development fbdd", hdr_path)
        elif platform == "android":
            m = _need(r"fbddLevel in (\d+)\.\.(\d+)", cam_scope, "hdr.camera_development fbdd", hdr_path)
        else:
            m = _need(r"FbddLevel is >= (\d+) and <= (\d+)", cam_scope, "hdr.camera_development fbdd", hdr_path)
        return list(range(int(m.group(1)), int(m.group(2)) + 1))

    fbdd = _cam_fbdd()
    out["hdr.camera_development"] = {
        "version": {"value_type": "integer", "allowed_values": [version]},
        "white_balance_mode": {"value_type": "string", "allowed_values": cam_wb_allowed},
        "temperature": {"value_type": "number", "as_shot_value": temp_as_shot, "temperature_min": temp_min, "temperature_max": temp_max},
        "tint": {"value_type": "number", "as_shot_value": tint_as_shot, "temperature_min": tint_min, "temperature_max": tint_max},
        "exposure_reference": {"value_type": "string", "allowed_values": cam_exp_allowed},
        "fbdd_level": {"value_type": "integer", "allowed_values": fbdd},
    }

    def _parse_wavelet_sub_fields():
        if platform in ("macos", "ios"):
            fn = _extract_brace_block(payload, r"private static func validWavelet", "detail.denoise.wavelet", payload_path)
            _require('wavelet["enabled"]?.boolean != nil', fn, "wavelet.enabled", payload_path)
            presets = _parse_quoted_list(_need(r"\[([^\]]+)\]\.contains\(wavelet\[\"preset\"\]\?\.string \?\? \"\"\)", fn, "wavelet.preset", payload_path).group(1))
            axes = _parse_quoted_list(_need(r"return \[([^\]]+)\]\.allSatisfy", fn, "wavelet axes", payload_path).group(1))
            bounds = _need(r"\((-?\d+(?:\.\d+)?)\.\.\.(-?\d+(?:\.\d+)?)\)\.contains\(\$0\)", fn, "wavelet axis bounds", payload_path)
        elif platform == "android":
            fn = _extract_brace_block(payload, r"AdjustmentField\.WAVELET_DENOISE -> \{", "detail.denoise.wavelet", payload_path)
            _require('wavelet["enabled"]?.boolean != null', fn, "wavelet.enabled", payload_path)
            presets = _parse_quoted_list(_need(r'wavelet\["preset"\]\?\.text in setOf\(([^)]+)\)', fn, "wavelet.preset", payload_path).group(1))
            axes = _parse_quoted_list(_need(r"listOf\(([^)]+)\)\.all", fn, "wavelet axes", payload_path).group(1))
            bounds = _need(r"n in (-?\d+(?:\.\d+)?)\.\.(-?\d+(?:\.\d+)?)", fn, "wavelet axis bounds", payload_path)
        else:
            block = _need(r"case AdjustmentField\.WaveletDenoise:(.*?)default:", payload, "detail.denoise.wavelet", payload_path, re.S).group(1)
            _require('Boolean(value.GetProperty("enabled"))!=null', block, "wavelet.enabled", payload_path)
            presets = _parse_quoted_list(_need(r'Text\(value\.GetProperty\("preset"\)\) is ([^&]+)', block, "wavelet.preset", payload_path).group(1))
            axes = _parse_quoted_list(_need(r"new\[\]\{([^}]+)\}\.All", block, "wavelet axes", payload_path).group(1))
            bounds = _need(r"Number\(value\.GetProperty\(k\)\) is >=(-?\d+(?:\.\d+)?) and <=(-?\d+(?:\.\d+)?)", block, "wavelet axis bounds", payload_path)
        lo, hi = float(bounds.group(1)), float(bounds.group(2))
        if axes != ["luma", "chroma", "coarse"]:
            raise AssertionError(f"Unexpected wavelet axes on {platform}: {axes}")
        spec: dict[str, dict] = {
            "enabled": {"value_type": "boolean"},
            "preset": {"value_type": "string", "allowed_values": presets},
        }
        for axis in axes:
            spec[axis] = {"value_type": "number", "min": lo, "max": hi}
        return spec

    out["detail.denoise.wavelet"] = _parse_wavelet_sub_fields()
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


def _ui_curve_entry(platform: str, mac_fine: dict[str, float] | None = None) -> dict:
    """Per-end parsed light.curve UI truth (bounds, steps, channels, defaults)."""
    if platform == "macos":
        assert mac_fine is not None
        tcs_path = "Shared/ToneCurveSettings.swift"
        tcs_src = _strip_line_comments(_read(tcs_path))
        mac_shared_int = "Shared/ToneCurveInteraction.swift"
        mac_shared_ed = "Shared/ToneCurveEditor.swift"
        shared_ed = _read(mac_shared_ed)
        coord_m = _need(r"\((-?\d+(?:\.\d+)?)\.\.\.(-?\d+(?:\.\d+)?)\)\.contains\(point\.x\)", tcs_src, "light.curve mac coord bounds", tcs_path)
        ev_m = _need(r'if usesExposureStops \{.*?−(\d+) EV.*?0 EV.*?\+(\d+) EV', shared_ed, "light.curve mac hdr ev bounds", mac_shared_ed, re.S)
        _need(r"step = fine \|\| config\.fine \? 0\.001 : 0\.01", _read(mac_shared_int), "light.curve mac step", mac_shared_int)
        _need(r"value\.replacing\(\.rgb", shared_ed, "light.curve mac channels", mac_shared_ed)
        for tok in (".red", ".green", ".blue"):
            if tok in shared_ed:
                raise AssertionError(f"Parse failed for light.curve mac channels: picker for {tok} found in {mac_shared_ed}")
        return _ui_entry(
            min_val=float(coord_m.group(1)),
            max_val=float(coord_m.group(2)),
            hdr_min=-float(ev_m.group(1)),
            hdr_max=float(ev_m.group(2)),
            default=_curve_default("macos"),
            step={"coordinate": mac_fine["curveCoordinate"], "hdr_coordinate_ev": mac_fine["exposure"]},
            channels=["rgb"],
        )

    if platform == "ios":
        tcs_path = "Shared/ToneCurveSettings.swift"
        tcs_src = _strip_line_comments(_read(tcs_path))
        ios_path = "RawLab/RawLab/UI/Panels/ToneCurveControls.swift"
        ios_src = _strip_line_comments(_read(ios_path))
        coord_m = _need(r"\((-?\d+(?:\.\d+)?)\.\.\.(-?\d+(?:\.\d+)?)\)\.contains\(point\.x\)", tcs_src, "light.curve ios coord bounds", tcs_path)
        ev_m = _need(r'if usesExposureStops \{.*?−(\d+) EV.*?0 EV.*?\+(\d+) EV', ios_src, "light.curve ios hdr ev bounds", ios_path, re.S)
        ios_step = _need(r"usesExposureStops \? ([\d.]+) : ([\d.]+)", ios_src, "light.curve step", ios_path)
        chan_cases = _need(
            r"enum ToneCurveChannel: String, CaseIterable, Identifiable \{\n    case (\w+), (\w+), (\w+), (\w+)",
            tcs_src, "light.curve channels", tcs_path,
        )
        _need(r"ForEach\(ToneCurveChannel\.allCases\)", ios_src, "light.curve ios channels", ios_path)
        return _ui_entry(
            min_val=float(coord_m.group(1)),
            max_val=float(coord_m.group(2)),
            hdr_min=-float(ev_m.group(1)),
            hdr_max=float(ev_m.group(2)),
            default=_curve_default("ios"),
            step={"coordinate": float(ios_step.group(2)), "hdr_coordinate_ev": float(ios_step.group(1))},
            channels=[chan_cases.group(i) for i in range(1, 5)],
        )

    if platform == "android":
        kt_path = "RawLabAndroid/app/src/main/java/com/rawlab/android/editor/controls/ToneCurveControls.kt"
        kt_model_path = "RawLabAndroid/app/src/main/java/com/rawlab/android/settings/ToneCurveSettings.kt"
        kt_src = _read(kt_path)
        kt_model_src = _strip_line_comments(_read(kt_model_path))
        kt_m = _need(r"(-?\d+(?:\.\d+)?)\.\.(-?\d+(?:\.\d+)?) else (-?\d+(?:\.\d+)?)\.\.(-?\d+(?:\.\d+)?)", kt_src, "light.curve bounds", kt_path)
        kt_step = _need(r"(\.\d+) else (\.\d+)", kt_src, "light.curve step", kt_path)
        kt_coord = float(kt_step.group(1))
        hdr_scale = int(_need(r"usesExposureStops\) value \* (\d+) - 8", kt_src, "light.curve android hdr scale", kt_path).group(1))
        _need(r"ToneCurveChannel\.entries", kt_src, "light.curve android channels", kt_path)
        kt_chan = _need(r"enum class ToneCurveChannel \{ (\w+), (\w+), (\w+), (\w+)", kt_model_src, "light.curve android channels", kt_model_path)
        return _ui_entry(
            min_val=float(kt_m.group(3)),
            max_val=float(kt_m.group(4)),
            hdr_min=float(kt_m.group(1)),
            hdr_max=float(kt_m.group(2)),
            default=_curve_default("android"),
            step={"coordinate": kt_coord, "hdr_coordinate_ev": round(kt_coord * hdr_scale, 6)},
            channels=[c.lower() for c in kt_chan.groups()],
        )

    cs_path = "RawLabWindows/ToneCurvePanel.cs"
    cs_src = _read(cs_path)
    cs_ranges = [(float(a), float(b), float(s)) for a, b, s in re.findall(r"new NumericRange\((-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?),\s*(\.\d+|\d+(?:\.\d+)?)", cs_src)]
    cs_sdr_entry = next(((lo, hi, st) for lo, hi, st in cs_ranges if lo >= 0), None)
    cs_hdr_entry = next(((lo, hi, st) for lo, hi, st in cs_ranges if lo < 0), None)
    if cs_sdr_entry is None or cs_hdr_entry is None:
        raise AssertionError(f"Parse failed for light.curve windows bounds in {cs_path}: {cs_ranges}")
    _need(r"Replacing\(ToneCurveChannel\.Rgb", cs_src, "light.curve windows channels", cs_path)
    for tok in (".Red", ".Green", ".Blue"):
        if tok in cs_src:
            raise AssertionError(f"Parse failed for light.curve windows channels: picker for {tok} found in {cs_path}")
    return _ui_entry(
        min_val=cs_sdr_entry[0],
        max_val=cs_sdr_entry[1],
        hdr_min=cs_hdr_entry[0],
        hdr_max=cs_hdr_entry[1],
        default=_curve_default("windows"),
        step={"coordinate": cs_sdr_entry[2], "hdr_coordinate_ev": cs_hdr_entry[2]},
        channels=["rgb"],
    )


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


def _parse_apple_shared_models() -> dict:
    """Parse models defined in Shared/*.swift (compiled into macOS and iOS only)."""
    hdr_swift = _strip_line_comments(_read("Shared/HDRSettings.swift"))
    hdr_transfer_swift = _strip_line_comments(_read("Shared/HDRAdjustmentTransfer.swift"))
    geom_swift = _strip_line_comments(_read("Shared/GeometrySettings.swift"))
    hsl_swift = _strip_line_comments(_read("Shared/HSLSettings.swift"))
    tone_swift = _strip_line_comments(_read("Shared/ToneControlsSettings.swift"))
    atmos_swift = _strip_line_comments(_read("Shared/AtmosphereSettings.swift"))
    grading_swift = _strip_line_comments(_read("Shared/ColorGradingSettings.swift"))

    def _swift_bounds(text: str, prop: str, label: str, rel: str) -> tuple[float, float]:
        m = re.search(rf"\((-?\d+)\.\.\.(-?\d+)\)\.contains\({re.escape(prop)}\)", text)
        if not m:
            m = _need(
                rf"\[[^\]]*\b{re.escape(prop)}\b[^\]]*\]\s*\.allSatisfy\s*\{{\s*(?:\$0\.isFinite\s*&&\s*)?\((-?\d+)\.\.\.(-?\d+)\)\.contains\(\$0\)",
                text,
                label,
                rel,
            )
        return (float(m.group(1)), float(m.group(2)))

    # HDRSettings
    hdr_settings_blk = _extract_brace_block(hdr_swift, r"(?:public\s+)?struct HDRSettings\b", "hdr settings", "Shared/HDRSettings.swift")
    hdr_exp_def = float(_need(r"(?:public\s+)?var exposure(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", hdr_settings_blk, "hdr.exposure default", "Shared/HDRSettings.swift").group(1))
    hdr_temp_def = float(_need(r"(?:public\s+)?var temperature(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", hdr_settings_blk, "hdr.relative_temperature default", "Shared/HDRSettings.swift").group(1))
    hdr_tint_def = float(_need(r"(?:public\s+)?var tint(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", hdr_settings_blk, "hdr.relative_tint default", "Shared/HDRSettings.swift").group(1))
    hdr_exp_range = _swift_bounds(hdr_settings_blk, "exposure", "hdr.exposure bounds", "Shared/HDRSettings.swift")
    hdr_temp_range = _swift_bounds(hdr_settings_blk, "temperature", "hdr.relative_temperature bounds", "Shared/HDRSettings.swift")
    hdr_tint_range = _swift_bounds(hdr_settings_blk, "tint", "hdr.relative_tint bounds", "Shared/HDRSettings.swift")
    hdr_scalar_100: dict[str, tuple[float, float]] = {}
    hdr_scalar_defs: dict[str, float] = {}
    for prop in ("contrast", "highlights", "shadows", "saturation"):
        hdr_scalar_100[prop] = _swift_bounds(hdr_settings_blk, prop, f"hdr.{prop} bounds", "Shared/HDRSettings.swift")
        hdr_scalar_defs[prop] = float(
            _need(rf"(?:public\s+)?var {prop}(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", hdr_settings_blk, f"hdr.{prop} default", "Shared/HDRSettings.swift").group(1)
        )

    # HDRToneSettings + HDRColorSettings + HDRRenditionSettings + HDRDetailSettings + HDRPhotoEffectsSettings
    hdr_tone_blk = _extract_brace_block(hdr_swift, r"(?:public\s+)?struct HDRToneSettings\b", "hdr tone", "Shared/HDRSettings.swift")
    hdr_color_blk = _extract_brace_block(hdr_swift, r"(?:public\s+)?struct HDRColorSettings\b", "hdr color", "Shared/HDRSettings.swift")
    hdr_rend_blk = _extract_brace_block(hdr_swift, r"(?:public\s+)?struct HDRRenditionSettings\b", "hdr rendition", "Shared/HDRSettings.swift")
    hdr_det_blk = _extract_brace_block(hdr_swift, r"(?:public\s+)?struct HDRDetailSettings\b", "hdr detail", "Shared/HDRSettings.swift")
    hdr_fx_blk = _extract_brace_block(hdr_swift, r"(?:public\s+)?struct HDRPhotoEffectsSettings\b", "hdr effects", "Shared/HDRSettings.swift")
    hdr_cam_blk = _extract_brace_block(hdr_swift, r"(?:public\s+)?struct HDRCameraDevelopmentSettings\b", "hdr camera dev", "Shared/HDRSettings.swift")

    hdr_peak_range = _swift_bounds(hdr_rend_blk, "peakLimitEV", "hdr.peak bounds", "Shared/HDRSettings.swift")
    hdr_sdr_exp_range = _swift_bounds(hdr_rend_blk, "sdrExposureEV", "hdr.sdr_exposure bounds", "Shared/HDRSettings.swift")
    hdr_sdr_con_range = _swift_bounds(hdr_rend_blk, "sdrContrast", "hdr.sdr_contrast bounds", "Shared/HDRSettings.swift")
    hdr_sdr_sat_range = _swift_bounds(hdr_rend_blk, "sdrSaturation", "hdr.sdr_saturation bounds", "Shared/HDRSettings.swift")
    hdr_peak_def = float(_need(r"(?:public\s+)?var peakLimitEV(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", hdr_rend_blk, "hdr.peak default", "Shared/HDRSettings.swift").group(1))
    hdr_sdr_exp_def = float(_need(r"(?:public\s+)?var sdrExposureEV(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", hdr_rend_blk, "hdr.sdr_exposure default", "Shared/HDRSettings.swift").group(1))
    hdr_sdr_con_def = float(_need(r"(?:public\s+)?var sdrContrast(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", hdr_rend_blk, "hdr.sdr_contrast default", "Shared/HDRSettings.swift").group(1))
    hdr_sdr_sat_def = float(_need(r"(?:public\s+)?var sdrSaturation(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", hdr_rend_blk, "hdr.sdr_saturation default", "Shared/HDRSettings.swift").group(1))

    hdr_sharp_range = _swift_bounds(hdr_det_blk, "sharpening", "hdr.sharpen bounds", "Shared/HDRSettings.swift")
    hdr_clarity_range = _swift_bounds(hdr_det_blk, "clarity", "hdr.clarity bounds", "Shared/HDRSettings.swift")
    hdr_dehaze_range = _swift_bounds(hdr_det_blk, "dehaze", "hdr.dehaze bounds", "Shared/HDRSettings.swift")
    hdr_denoise_range = _swift_bounds(hdr_det_blk, "denoise", "hdr.denoise bounds", "Shared/HDRSettings.swift")
    hdr_sharp_def = float(_need(r"(?:public\s+)?var sharpening(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", hdr_det_blk, "hdr.sharpen default", "Shared/HDRSettings.swift").group(1))
    hdr_clarity_def = float(_need(r"(?:public\s+)?var clarity(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", hdr_det_blk, "hdr.clarity default", "Shared/HDRSettings.swift").group(1))
    hdr_dehaze_def = float(_need(r"(?:public\s+)?var dehaze(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", hdr_det_blk, "hdr.dehaze default", "Shared/HDRSettings.swift").group(1))
    hdr_denoise_def = float(_need(r"(?:public\s+)?var denoise(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", hdr_det_blk, "hdr.denoise default", "Shared/HDRSettings.swift").group(1))

    hdr_fx_defs = {}
    hdr_fx_ranges = {}
    for prop in (
        "vignetteAmount", "vignetteMidpoint", "vignetteRoundness", "vignetteFeather",
        "vignetteHighlights", "grainAmount", "grainSize", "grainRoughness",
    ):
        hdr_fx_defs[prop] = float(_need(rf"(?:public\s+)?var {prop}(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", hdr_fx_blk, f"hdr fx.{prop} default", "Shared/HDRSettings.swift").group(1))
        hdr_fx_ranges[prop] = _swift_bounds(hdr_fx_blk, prop, f"hdr fx.{prop} bounds", "Shared/HDRSettings.swift")

    hdr_cam_wb = _need(r'case asShot\s*=\s*"([^"]+)"', hdr_cam_blk, "hdr.cam wb wire", "Shared/HDRSettings.swift").group(1)
    _need(r"var whiteBalance(?:\s*:\s*WhiteBalance)?\s*=\s*(?:WhiteBalance)?\.asShot", hdr_cam_blk, "hdr.cam wb default", "Shared/HDRSettings.swift")
    hdr_cam_expref = _need(r'case (\w+),\s*\w+', hdr_cam_blk, "hdr.cam expref wire", "Shared/HDRSettings.swift").group(1)
    _need(r"var exposureReference(?:\s*:\s*ExposureReference)?\s*=\s*(?:ExposureReference)?\.metadata", hdr_cam_blk, "hdr.cam expref default", "Shared/HDRSettings.swift")
    hdr_cam_def = {
        "version": int(_need(r"var version(?:\s*:\s*Int)?\s*=\s*(\d+)", hdr_cam_blk, "hdr.cam version", "Shared/HDRSettings.swift").group(1)),
        "white_balance_mode": hdr_cam_wb,
        "temperature": float(_need(r"var temperature(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", hdr_cam_blk, "hdr.cam temp", "Shared/HDRSettings.swift").group(1)),
        "tint": float(_need(r"var tint(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", hdr_cam_blk, "hdr.cam tint", "Shared/HDRSettings.swift").group(1)),
        "exposure_reference": hdr_cam_expref,
        "fbdd_level": int(_need(r"var fbddLevel(?:\s*:\s*Int)?\s*=\s*(\d+)", hdr_cam_blk, "hdr.cam fbdd", "Shared/HDRSettings.swift").group(1)),
    }

    # HDRAdjustmentTransfer scales
    _require("(number - 1) * 100", hdr_transfer_swift, "hdr contrast/saturation scale", "Shared/HDRAdjustmentTransfer.swift")
    _require("-number * 100", hdr_transfer_swift, "hdr highlights scale", "Shared/HDRAdjustmentTransfer.swift")
    _require("number * 100", hdr_transfer_swift, "hdr shadows scale", "Shared/HDRAdjustmentTransfer.swift")
    _require("tone.curveStrength = value * 100", hdr_transfer_swift, "hdr sCurve scale", "Shared/HDRAdjustmentTransfer.swift")
    _require("field == .clarity || field == .dehaze ? value * 100 : value", hdr_transfer_swift, "hdr clarity/dehaze scale", "Shared/HDRAdjustmentTransfer.swift")
    _require("field == .clarity || field == .dehaze ? value / 100 : value", hdr_transfer_swift, "hdr clarity/dehaze decode scale", "Shared/HDRAdjustmentTransfer.swift")

    # ToneControlsSettings & AtmosphereSettings & HSLSettings & ColorGradingSettings
    tone_blk = _extract_brace_block(tone_swift, r"(?:public\s+)?struct ToneControlsSettings\b", "tone controls", "Shared/ToneControlsSettings.swift")
    tone_range = _swift_bounds(tone_blk, "blackPoint", "tone controls bounds", "Shared/ToneControlsSettings.swift")
    tone_bp_def = float(_need(r"(?:public\s+)?var blackPoint(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", tone_blk, "tone.black_point default", "Shared/ToneControlsSettings.swift").group(1))
    tone_wp_def = float(_need(r"(?:public\s+)?var whitePoint(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", tone_blk, "tone.white_point default", "Shared/ToneControlsSettings.swift").group(1))
    vib_def = float(_need(r"(?:public\s+)?var vibrance(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", hdr_color_blk, "hdr color.vibrance default", "Shared/HDRSettings.swift").group(1))
    hdr_vib_range = _swift_bounds(hdr_color_blk, "vibrance", "hdr color.vibrance bounds", "Shared/HDRSettings.swift")
    hdr_bp_range = _swift_bounds(hdr_tone_blk, "blackPoint", "hdr blackPoint bounds", "Shared/HDRSettings.swift")
    hdr_wp_range = _swift_bounds(hdr_tone_blk, "whitePoint", "hdr whitePoint bounds", "Shared/HDRSettings.swift")

    atmos_blk = _extract_brace_block(atmos_swift, r"(?:public\s+)?struct AtmosphereSettings\b", "atmosphere", "Shared/AtmosphereSettings.swift")
    atmos_range = _swift_bounds(atmos_blk, "clarity", "atmosphere bounds", "Shared/AtmosphereSettings.swift")
    atmos_cl_def = float(_need(r"(?:public\s+)?var clarity(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", atmos_blk, "effects.clarity default", "Shared/AtmosphereSettings.swift").group(1))
    atmos_dh_def = float(_need(r"(?:public\s+)?var dehaze(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", atmos_blk, "effects.dehaze default", "Shared/AtmosphereSettings.swift").group(1))

    hsl_blk = _extract_brace_block(hsl_swift, r"(?:public\s+)?struct HSLSettings\b", "color.hsl", "Shared/HSLSettings.swift")
    hsl_range = tuple(float(x) for x in _need(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(\$0\)", hsl_blk, "color.hsl bounds", "Shared/HSLSettings.swift").groups())
    _need(r"repeating:\s*0,\s*count:\s*8", hsl_blk, "color.hsl default 0", "Shared/HSLSettings.swift")

    grad_blk = _extract_brace_block(grading_swift, r"(?:public\s+)?struct ColorGradingWheel\b", "color.grading.*", "Shared/ColorGradingSettings.swift")
    grad_hue_def = float(_need(r"(?:public\s+)?var hue(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", grad_blk, "color.grading hue default", "Shared/ColorGradingSettings.swift").group(1))
    grad_sat_def = float(_need(r"(?:public\s+)?var saturation(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", grad_blk, "color.grading saturation default", "Shared/ColorGradingSettings.swift").group(1))

    # GeometrySettings
    geom_blk = _extract_brace_block(geom_swift, r"(?:public\s+)?struct GeometrySettings\b", "geometry.*", "Shared/GeometrySettings.swift")
    geom_crop_x = float(_need(r"(?:public\s+)?var cropX(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", geom_blk, "geometry.crop.x default", "Shared/GeometrySettings.swift").group(1))
    geom_crop_y = float(_need(r"(?:public\s+)?var cropY(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", geom_blk, "geometry.crop.y default", "Shared/GeometrySettings.swift").group(1))
    geom_crop_w = float(_need(r"(?:public\s+)?var cropWidth(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", geom_blk, "geometry.crop.width default", "Shared/GeometrySettings.swift").group(1))
    geom_crop_h = float(_need(r"(?:public\s+)?var cropHeight(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", geom_blk, "geometry.crop.height default", "Shared/GeometrySettings.swift").group(1))
    crop_min = float(_need(r"cropX\s*>=\s*(-?\d+(?:\.\d+)?)\s*&&\s*cropY\s*>=\s*\1", geom_blk, "geometry.crop min bound", "Shared/GeometrySettings.swift").group(1))
    _need(r"cropWidth\s*>\s*0\s*&&\s*cropHeight\s*>\s*0", geom_blk, "geometry.crop positive size guard", "Shared/GeometrySettings.swift")
    crop_max = float(_need(r"cropX\s*\+\s*cropWidth\s*<=\s*(-?\d+(?:\.\d+)?)\s*&&\s*cropY\s*\+\s*cropHeight\s*<=\s*\1", geom_blk, "geometry.crop max bound", "Shared/GeometrySettings.swift").group(1))
    geom_crop_bounds = (crop_min, crop_max)
    qt_range = tuple(int(x) for x in _need(r"\((\d+)\.\.\.(\d+)\)\.contains\(quarterTurns\)", geom_blk, "geometry.quarter_turns bounds", "Shared/GeometrySettings.swift").groups())
    qt_def = int(_need(r"(?:public\s+)?var quarterTurns(?:\s*:\s*Int)?\s*=\s*(\d+)", geom_blk, "geometry.quarter_turns default", "Shared/GeometrySettings.swift").group(1))
    flip_h_def = _need(r"(?:public\s+)?var flipHorizontal(?:\s*:\s*Bool)?\s*=\s*(true|false)", geom_blk, "geometry.flip_horizontal default", "Shared/GeometrySettings.swift").group(1) == "true"
    flip_v_def = _need(r"(?:public\s+)?var flipVertical(?:\s*:\s*Bool)?\s*=\s*(true|false)", geom_blk, "geometry.flip_vertical default", "Shared/GeometrySettings.swift").group(1) == "true"
    straight_range = _swift_bounds(geom_blk, "straightenDegrees", "geometry.straighten bounds", "Shared/GeometrySettings.swift")
    straight_def = float(_need(r"(?:public\s+)?var straightenDegrees(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", geom_blk, "geometry.straighten default", "Shared/GeometrySettings.swift").group(1))
    persp_h_range = _swift_bounds(geom_blk, "perspectiveHorizontal", "geometry.perspective.horizontal bounds", "Shared/GeometrySettings.swift")
    persp_v_range = _swift_bounds(geom_blk, "perspectiveVertical", "geometry.perspective.vertical bounds", "Shared/GeometrySettings.swift")
    persp_h_def = float(_need(r"(?:public\s+)?var perspectiveHorizontal(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", geom_blk, "geometry.perspective.horizontal default", "Shared/GeometrySettings.swift").group(1))
    persp_v_def = float(_need(r"(?:public\s+)?var perspectiveVertical(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", geom_blk, "geometry.perspective.vertical default", "Shared/GeometrySettings.swift").group(1))

    return {
        "hdr_exp_range": hdr_exp_range,
        "hdr_exp_def": hdr_exp_def,
        "hdr_temp_range": hdr_temp_range,
        "hdr_temp_def": hdr_temp_def,
        "hdr_tint_range": hdr_tint_range,
        "hdr_tint_def": hdr_tint_def,
        "hdr_scalar_100": hdr_scalar_100,
        "hdr_scalar_defs": hdr_scalar_defs,
        "hdr_peak_range": hdr_peak_range,
        "hdr_sdr_exp_range": hdr_sdr_exp_range,
        "hdr_sdr_con_range": hdr_sdr_con_range,
        "hdr_sdr_sat_range": hdr_sdr_sat_range,
        "hdr_peak_def": hdr_peak_def,
        "hdr_sdr_exp_def": hdr_sdr_exp_def,
        "hdr_sdr_con_def": hdr_sdr_con_def,
        "hdr_sdr_sat_def": hdr_sdr_sat_def,
        "hdr_sharp_range": hdr_sharp_range,
        "hdr_clarity_range": hdr_clarity_range,
        "hdr_dehaze_range": hdr_dehaze_range,
        "hdr_denoise_range": hdr_denoise_range,
        "hdr_sharp_def": hdr_sharp_def,
        "hdr_clarity_def": hdr_clarity_def,
        "hdr_dehaze_def": hdr_dehaze_def,
        "hdr_denoise_def": hdr_denoise_def,
        "hdr_fx_defs": hdr_fx_defs,
        "hdr_fx_ranges": hdr_fx_ranges,
        "hdr_cam_def": hdr_cam_def,
        "tone_range": tone_range,
        "tone_bp_def": tone_bp_def,
        "tone_wp_def": tone_wp_def,
        "vib_def": vib_def,
        "hdr_vib_range": hdr_vib_range,
        "hdr_bp_range": hdr_bp_range,
        "hdr_wp_range": hdr_wp_range,
        "atmos_range": atmos_range,
        "atmos_cl_def": atmos_cl_def,
        "atmos_dh_def": atmos_dh_def,
        "hsl_range": hsl_range,
        "grad_def": {"hue": grad_hue_def, "saturation": grad_sat_def},
        "geom_crop_bounds": geom_crop_bounds,
        "geom_crop_defs": {"x": geom_crop_x, "y": geom_crop_y, "width": geom_crop_w, "height": geom_crop_h},
        "qt_range": qt_range,
        "qt_def": qt_def,
        "flip_h_def": flip_h_def,
        "flip_v_def": flip_v_def,
        "straight_range": straight_range,
        "straight_def": straight_def,
        "persp_h_range": persp_h_range,
        "persp_v_range": persp_v_range,
        "persp_h_def": persp_h_def,
        "persp_v_def": persp_v_def,
    }


def _parse_mac_model(shared: dict) -> dict[str, dict]:
    """Parse macOS model entries from RawLabMac/ and Shared/."""
    mac_adj = _strip_line_comments(_read("RawLabMac/Sources/Adjustments/Adjustments.swift"))
    mac_types = _strip_line_comments(_read("RawLabMac/Sources/Adjustments/AdjustmentTypes.swift"))
    mac_tv = _strip_line_comments(_read("RawLabMac/Sources/Adjustments/MacAdjustmentTransferValues.swift"))
    mac_tr = _strip_line_comments(_read("RawLabMac/Sources/Adjustments/MacAdjustmentTransfer.swift"))

    _require("context.transferNotices?(.retainedTargetProcessingVersion)", mac_tr, "processing version mac", "MacAdjustmentTransfer.swift")
    _need(
        r"if let value = payload\[\.postRGBDenoise\]\?\.number,\s*value != 0\s*\{\s*context\.transferNotices\?\(\.ignoredPostRGBDenoise\)",
        mac_tv,
        "detail.denoise.post_rgb mac sdr ignored with notice",
        "MacAdjustmentTransferValues.swift",
    )

    mac_specs: dict[str, tuple[float, float, float]] = {}
    spec_blk = _extract_brace_block(mac_types, r"var spec:\s*AdjustmentSpec\b", "mac specs", "AdjustmentTypes.swift")
    for m in re.finditer(
        r"case \.(\w+):\s*return AdjustmentSpec\(.*?range:\s*(-?\d+(?:\.\d+)?)\.\.\.(-?\d+(?:\.\d+)?),\s*defaultValue:\s*(-?\d+(?:\.\d+)?)",
        spec_blk,
        re.S,
    ):
        mac_specs[m.group(1)] = (float(m.group(2)), float(m.group(3)), float(m.group(4)))

    _require("case .contrast, .saturation: native = (value - 1) * 100", mac_tv, "contrast/saturation scale", "MacAdjustmentTransferValues.swift")
    _require("case .highlights: native = -value * 100", mac_tv, "highlights scale", "MacAdjustmentTransferValues.swift")
    _require("case .shadows, .sCurve, .sharpening: native = value * 100", mac_tv, "shadows/sCurve/sharpening scale", "MacAdjustmentTransferValues.swift")
    mac_contrast_scale, mac_hi_scale, mac_sh_scale = "(p - 1) * 100", "-p * 100", "p * 100"

    # look.reference
    _require('PhotoEditState(settings: defaults, filmID: "")', mac_tr, "looks.reference mac filmID", "MacAdjustmentTransfer.swift")
    _require('look = ["kind": .string("neutral"), "id": .null]', mac_tv, "looks.reference mac neutral wire", "MacAdjustmentTransferValues.swift")
    look_ref_def = {"kind": "neutral", "id": None}

    # modes
    exp_mode_def = _need(r"var exposureMode(?:\s*:\s*ExposureMode)?\s*=\s*(?:ExposureMode)?\.(\w+)", mac_adj, "light.exposure_mode mac default", "Adjustments.swift").group(1)
    wb_mode_var = _need(r"var whiteBalanceMode(?:\s*:\s*WhiteBalanceMode)?\s*=\s*(?:WhiteBalanceMode)?\.(\w+)", mac_adj, "color.white_balance.mode mac default", "Adjustments.swift").group(1)
    _need(rf"whiteBalanceMode\s*==\s*\.{re.escape(wb_mode_var)}", mac_adj, "color.white_balance.mode usesAsShot", "Adjustments.swift")
    wb_mode_wire = _need(r'let camera = !isRaw \|\| settings\.usesAsShotWhiteBalance.*?camera \? "([^"]+)"', mac_tv, "color.white_balance.mode mac wire", "MacAdjustmentTransferValues.swift", re.S).group(1)

    # chroma_mode
    _require("var chromaNoiseReduction: Double?", mac_adj, "detail.denoise.chroma_mode nullable", "Adjustments.swift")
    chroma_default_none = bool(re.search(r"var chromaNoiseReduction:\s*Double\?(?:\s*=\s*nil)?\s*$", mac_adj, re.M))
    assert chroma_default_none
    chroma_bounds_m = _need(
        r"chromaNoiseReduction\.map\(\{\s*\$0\.isFinite\s*&&\s*\((-?\d+(?:\.\d+)?)\.\.\.(-?\d+(?:\.\d+)?)\)\.contains\(\$0\)",
        mac_adj,
        "detail.denoise.chroma_mode mac bounds",
        "Adjustments.swift",
    )
    chroma_lo = float(chroma_bounds_m.group(1))
    chroma_hi = float(chroma_bounds_m.group(2))

    # wavelet
    _require("var waveletNoiseReduction: WaveletDenoiseSettings?", mac_adj, "detail.denoise.wavelet nullable", "Adjustments.swift")

    # photo effects directly from Mac AdjustmentTypes.swift
    mac_fx_blk = _extract_brace_block(mac_types, r"struct PhotoEffectsSettings\b", "effects.* mac defaults", "AdjustmentTypes.swift")
    mac_fx_range_blk = _extract_brace_block(mac_types, r"enum PhotoEffectParameter\b", "effects.* mac ranges", "AdjustmentTypes.swift")
    signed_m = _need(
        r"self == \.vignetteAmount \|\| self == \.vignetteRoundness \? (-?\d+)\.\.\.(-?\d+) : (-?\d+)\.\.\.(-?\d+)",
        mac_fx_range_blk, "effects.* mac PhotoEffectParameter.range", "AdjustmentTypes.swift",
    )
    signed_range = (float(signed_m.group(1)), float(signed_m.group(2)))
    unsigned_range = (float(signed_m.group(3)), float(signed_m.group(4)))

    # lens directly from Mac AdjustmentTypes.swift
    mac_lens_blk = _extract_brace_block(mac_types, r"struct LensCorrectionSettings\b", "geometry.lens.* mac", "AdjustmentTypes.swift")
    lens_dist = _need(r"var distortion(?:\s*:\s*Bool)?\s*=\s*(true|false)", mac_lens_blk, "lens.distortion mac", "AdjustmentTypes.swift").group(1) == "true"
    lens_tca = _need(r"var tca(?:\s*:\s*Bool)?\s*=\s*(true|false)", mac_lens_blk, "lens.tca mac", "AdjustmentTypes.swift").group(1) == "true"
    lens_vig = _need(r"var vignetting(?:\s*:\s*Bool)?\s*=\s*(true|false)", mac_lens_blk, "lens.vignetting mac", "AdjustmentTypes.swift").group(1) == "true"
    lens_auto = _need(r"var autoCrop(?:\s*:\s*Bool)?\s*=\s*(true|false)", mac_lens_blk, "lens.auto_crop mac", "AdjustmentTypes.swift").group(1) == "true"
    _need(r"var profileID:\s*String\?(?:\s*=\s*nil)?(?=\s|$)", mac_lens_blk, "lens.profile_id mac", "AdjustmentTypes.swift")

    # local AI
    _require("var aiDenoiseEnabled = false", mac_adj, "local.ai_denoise_enabled mac", "Adjustments.swift")
    _require("var hdrCameraAIEnabled: Bool", mac_adj, "local.hdr_camera_ai_enabled mac", "Adjustments.swift")
    _require("hdrCameraAI == true", mac_adj, "local.hdr_camera_ai_enabled mac default false", "Adjustments.swift")

    m: dict[str, dict] = {}
    m["looks.reference"] = _model_entry("object", modes=("sdr",), default=look_ref_def, quantization="discrete")
    m["looks.strength"] = _model_entry("double", modes=("sdr",), min_val=mac_specs["strength"][0], max_val=mac_specs["strength"][1], default=mac_specs["strength"][2], scale_from_protocol="p")
    m["light.exposure"] = _model_entry("double", min_val=mac_specs["exposure"][0], max_val=mac_specs["exposure"][1], hdr_min=shared["hdr_exp_range"][0], hdr_max=shared["hdr_exp_range"][1], default=mac_specs["exposure"][2])
    m["light.exposure_mode"] = _model_entry("enum", modes=("sdr",), default=exp_mode_def, quantization="discrete")
    m["light.contrast"] = _model_entry("double", min_val=mac_specs["contrast"][0], max_val=mac_specs["contrast"][1], default=mac_specs["contrast"][2], scale_from_protocol=mac_contrast_scale)
    m["light.highlights"] = _model_entry("double", min_val=mac_specs["highlights"][0], max_val=mac_specs["highlights"][1], default=mac_specs["highlights"][2], scale_from_protocol=mac_hi_scale)
    m["light.shadows"] = _model_entry("double", min_val=mac_specs["shadows"][0], max_val=mac_specs["shadows"][1], default=mac_specs["shadows"][2], scale_from_protocol=mac_sh_scale)
    m["light.s_curve"] = _model_entry("double", min_val=mac_specs["toneCurve"][0], max_val=mac_specs["toneCurve"][1], default=mac_specs["toneCurve"][2], scale_from_protocol=mac_sh_scale)
    m["light.curve"] = _model_entry("object", default=_curve_default("macos"))

    for fid, def_val in (
        ("tone.black_point", shared["tone_bp_def"]),
        ("tone.white_point", shared["tone_wp_def"]),
        ("color.vibrance", shared["vib_def"]),
    ):
        m[fid] = _model_entry("double", min_val=shared["tone_range"][0], max_val=shared["tone_range"][1], default=def_val)

    for zone in ("shadows", "midtones", "highlights"):
        m[f"color.grading.{zone}"] = _model_entry("object", default=shared["grad_def"])

    m["color.white_balance.mode"] = _model_entry("enum", modes=("sdr",), default=wb_mode_wire, quantization="discrete")
    m["color.white_balance.temperature_kelvin"] = _model_entry("double", modes=("sdr",), min_val=mac_specs["temperature"][0], max_val=mac_specs["temperature"][1], default=mac_specs["temperature"][2])
    m["color.white_balance.tint"] = _model_entry("double", modes=("sdr",), min_val=mac_specs["tint"][0], max_val=mac_specs["tint"][1], default=mac_specs["tint"][2])
    m["color.saturation"] = _model_entry("double", min_val=mac_specs["saturation"][0], max_val=mac_specs["saturation"][1], default=mac_specs["saturation"][2], scale_from_protocol=mac_contrast_scale)

    m["hdr.relative_temperature"] = _model_entry("double", modes=("hdr",), min_val=shared["hdr_temp_range"][0], max_val=shared["hdr_temp_range"][1], default=shared["hdr_temp_def"])
    m["hdr.relative_tint"] = _model_entry("double", modes=("hdr",), min_val=shared["hdr_tint_range"][0], max_val=shared["hdr_tint_range"][1], default=shared["hdr_tint_def"])
    m["hdr.peak_limit_ev"] = _model_entry("double", modes=("hdr",), min_val=shared["hdr_peak_range"][0], max_val=shared["hdr_peak_range"][1], default=shared["hdr_peak_def"])
    m["hdr.sdr_exposure_ev"] = _model_entry("double", modes=("hdr",), min_val=shared["hdr_sdr_exp_range"][0], max_val=shared["hdr_sdr_exp_range"][1], default=shared["hdr_sdr_exp_def"])
    m["hdr.sdr_contrast"] = _model_entry("double", modes=("hdr",), min_val=shared["hdr_sdr_con_range"][0], max_val=shared["hdr_sdr_con_range"][1], default=shared["hdr_sdr_con_def"])
    m["hdr.sdr_saturation"] = _model_entry("double", modes=("hdr",), min_val=shared["hdr_sdr_sat_range"][0], max_val=shared["hdr_sdr_sat_range"][1], default=shared["hdr_sdr_sat_def"])
    m["hdr.look"] = _model_entry("object", modes=("hdr",), nullable=True, default=_look_default("macos"))
    m["hdr.camera_development"] = _model_entry("object", modes=("hdr",), default=shared["hdr_cam_def"])

    for axis in HSL_AXES:
        for ch in HSL_CHANNELS:
            m[f"color.hsl.{axis}.{ch}"] = _model_entry("double", min_val=shared["hsl_range"][0], max_val=shared["hsl_range"][1], default=0.0)

    for fid, prop, is_signed in (
        ("effects.vignette.amount", "vignetteAmount", True),
        ("effects.vignette.midpoint", "vignetteMidpoint", False),
        ("effects.vignette.roundness", "vignetteRoundness", True),
        ("effects.vignette.feather", "vignetteFeather", False),
        ("effects.vignette.highlights", "vignetteHighlights", False),
        ("effects.grain.amount", "grainAmount", False),
        ("effects.grain.size", "grainSize", False),
        ("effects.grain.roughness", "grainRoughness", False),
    ):
        dflt = float(_need(rf"var {prop}(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", mac_fx_blk, f"{fid} mac default", "AdjustmentTypes.swift").group(1))
        lo, hi = signed_range if is_signed else unsigned_range
        m[fid] = _model_entry("double", min_val=lo, max_val=hi, default=dflt)

    m["effects.clarity"] = _model_entry("double", min_val=shared["atmos_range"][0], max_val=shared["atmos_range"][1], hdr_min=shared["hdr_clarity_range"][0], hdr_max=shared["hdr_clarity_range"][1], default=shared["atmos_cl_def"], hdr_default=shared["hdr_clarity_def"], scale_from_protocol="p", hdr_scale_from_protocol="p / 100")
    m["effects.dehaze"] = _model_entry("double", min_val=shared["atmos_range"][0], max_val=shared["atmos_range"][1], hdr_min=shared["hdr_dehaze_range"][0], hdr_max=shared["hdr_dehaze_range"][1], default=shared["atmos_dh_def"], hdr_default=shared["hdr_dehaze_def"], scale_from_protocol="p", hdr_scale_from_protocol="p / 100")

    m["detail.sharpening"] = _model_entry("double", min_val=mac_specs["sharpening"][0], max_val=mac_specs["sharpening"][1], hdr_min=shared["hdr_sharp_range"][0], hdr_max=shared["hdr_sharp_range"][1], default=mac_specs["sharpening"][2], hdr_default=shared["hdr_sharp_def"], scale_from_protocol=mac_sh_scale, hdr_scale_from_protocol="p")
    m["detail.denoise.raw_level"] = _model_entry("double", modes=("sdr",), min_val=mac_specs["rawNoiseReduction"][0], max_val=mac_specs["rawNoiseReduction"][1], default=mac_specs["rawNoiseReduction"][2], quantization="discrete")
    m["detail.denoise.post_rgb"] = _model_entry("double", modes=("hdr",), min_val=shared["hdr_denoise_range"][0], max_val=shared["hdr_denoise_range"][1], default=shared["hdr_denoise_def"])
    m["detail.denoise.chroma_mode"] = _model_entry("double", modes=("sdr",), nullable=True, min_val=chroma_lo, max_val=chroma_hi, default=None, quantization="discrete")
    m["detail.denoise.wavelet"] = _model_entry("object", modes=("sdr",), nullable=True, default=None)

    for key, fid in (("x", "geometry.crop.x"), ("y", "geometry.crop.y"), ("width", "geometry.crop.width"), ("height", "geometry.crop.height")):
        m[fid] = _model_entry("double", min_val=shared["geom_crop_bounds"][0], max_val=shared["geom_crop_bounds"][1], default=shared["geom_crop_defs"][key])
    m["geometry.quarter_turns"] = _model_entry("int", min_val=shared["qt_range"][0], max_val=shared["qt_range"][1], default=shared["qt_def"], quantization="discrete")
    m["geometry.flip_horizontal"] = _model_entry("bool", default=shared["flip_h_def"], quantization="discrete")
    m["geometry.flip_vertical"] = _model_entry("bool", default=shared["flip_v_def"], quantization="discrete")
    m["geometry.straighten_degrees"] = _model_entry("double", min_val=shared["straight_range"][0], max_val=shared["straight_range"][1], default=shared["straight_def"])
    m["geometry.perspective.horizontal"] = _model_entry("double", min_val=shared["persp_h_range"][0], max_val=shared["persp_h_range"][1], default=shared["persp_h_def"])
    m["geometry.perspective.vertical"] = _model_entry("double", min_val=shared["persp_v_range"][0], max_val=shared["persp_v_range"][1], default=shared["persp_v_def"])

    for fid, dflt in (
        ("geometry.lens.distortion", lens_dist),
        ("geometry.lens.tca", lens_tca),
        ("geometry.lens.vignetting", lens_vig),
        ("geometry.lens.auto_crop", lens_auto),
    ):
        m[fid] = _model_entry("bool", modes=("sdr", "hdr"), default=dflt, quantization="discrete")
    m["geometry.lens.profile_id"] = _model_entry("string", modes=("sdr",), nullable=True, default=None, quantization="discrete")

    m["local.ai_denoise_enabled"] = _model_entry("bool", supported=True, modes=("sdr",), default=False, scale_from_protocol="none", quantization="discrete")
    m["local.hdr_camera_ai_enabled"] = _model_entry("bool", supported=True, modes=("hdr",), default=False, scale_from_protocol="none", quantization="discrete")
    return m


def _parse_ios_model(shared: dict) -> dict[str, dict]:
    """Parse iOS model entries from RawLab/ and Shared/ (NO Windows/Android borrowing)."""
    ios_raw = _strip_line_comments(_read("RawLab/RawLab/Core/Models/RawSettings.swift"))
    ios_rules = _strip_line_comments(_read("RawLab/RawLab/Core/Models/EditorAdjustmentRules.swift"))
    ios_tr = _strip_line_comments(_read("RawLab/RawLab/Core/Models/IOSAdjustmentTransfer.swift"))
    ios_tv = _strip_line_comments(_read("RawLab/RawLab/Core/Models/IOSAdjustmentTransferValues.swift"))

    _require("context.transferNotices?(.retainedTargetProcessingVersion)", ios_tr, "processing version ios", "IOSAdjustmentTransfer.swift")
    _require("if let raw = payload[.rawDenoise]?.number, raw != 0 { context.transferNotices?(.ignoredRawDenoise) }", ios_tv, "detail.denoise.raw_level ios ignored with notice", "IOSAdjustmentTransferValues.swift")
    _require("for (field, key) in scalarKeys { result[field.rawValue] = .number(settings[keyPath: key]) }", ios_tv, "ios direct scalar transfer", "IOSAdjustmentTransferValues.swift")
    _require_absent("aiDenoiseEnabled", ios_raw, "local.ai_denoise_enabled unsupported ios", "RawSettings.swift")
    _require_absent("hdrCameraAIEnabled", ios_raw, "local.hdr_camera_ai_enabled unsupported ios", "RawSettings.swift")

    valid_section = _need(r"static func valid\(_ settings: RawSettings\) -> Bool \{(.*?)\n    \}", ios_rules, "ios valid() bounds", "EditorAdjustmentRules.swift", re.S).group(1)
    ios_valid_ranges: dict[str, tuple[float, float]] = {}
    for prop, lo, hi in re.findall(r"\(settings\.(\w+),\s*(-?\d+(?:\.\d+)?)\.\.\.(-?\d+(?:\.\d+)?)\)", valid_section):
        ios_valid_ranges[prop] = (float(lo), float(hi))

    ios_lut_range = tuple(float(x) for x in _need(r"lutStrengthRange:\s*ClosedRange<Double>\s*=\s*(-?\d+(?:\.\d+)?)\.\.\.(-?\d+(?:\.\d+)?)", ios_raw, "looks.strength bounds", "RawSettings.swift").groups())
    ios_temp_range = tuple(float(x) for x in _need(r"temperatureRange:\s*ClosedRange<Double>\s*=\s*(-?\d+(?:\.\d+)?)\.\.\.(-?\d+(?:\.\d+)?)", ios_raw, "white_balance.temperature bounds", "RawSettings.swift").groups())
    ios_tint_range = tuple(float(x) for x in _need(r"tintRange:\s*ClosedRange<Double>\s*=\s*(-?\d+(?:\.\d+)?)\.\.\.(-?\d+(?:\.\d+)?)", ios_raw, "white_balance.tint bounds", "RawSettings.swift").groups())

    raw_blk = _extract_brace_block(ios_raw, r"struct RawSettings\b", "RawSettings", "RawSettings.swift")
    default_blk = _extract_brace_block(raw_blk, r"init\(from decoder: Decoder\)", "RawSettings decoder defaults", "RawSettings.swift")
    def_instance_blk = _need(r"static let `default`\s*=\s*RawSettings\((.*?)\n    \)", raw_blk, "RawSettings.default", "RawSettings.swift", re.S).group(1)
    ios_def = {}
    for prop in ("exposure", "contrast", "saturation", "temperature", "tint", "highlights", "shadows", "toneCurve", "noiseReduction", "sharpening", "lutStrength"):
        ios_def[prop] = float(_need(rf"{prop}:\s*(-?\d+(?:\.\d+)?)", def_instance_blk, f"{prop} ios default", "RawSettings.swift").group(1))
        dec_def = float(_need(rf"{prop} = try values\.decodeIfPresent.*? \?\? (-?\d+(?:\.\d+)?)", default_blk, f"{prop} ios decoder default", "RawSettings.swift").group(1))
        assert ios_def[prop] == dec_def
    _require("lutID: nil", def_instance_blk, "looks.reference ios default nil", "RawSettings.swift")
    _require("lutID = try values.decodeIfPresent(String.self, forKey: .lutID)", default_blk, "looks.reference ios nullable", "RawSettings.swift")
    _require('look = ["kind": .string("neutral"), "id": .null]', ios_tv, "looks.reference ios neutral wire", "IOSAdjustmentTransferValues.swift")

    exp_mode_def = _need(r"var exposureMode\s*=\s*RawExposureMode\.(\w+)", raw_blk, "light.exposure_mode ios default", "RawSettings.swift").group(1)
    wb_mode_var = _need(r"whiteBalanceMode\s*:\s*\.(\w+)", def_instance_blk, "color.white_balance.mode ios default", "RawSettings.swift").group(1)
    _need(rf"\bcase {re.escape(wb_mode_var)}\b", _extract_brace_block(ios_raw, r"enum RawWhiteBalanceMode\b", "RawWhiteBalanceMode", "RawSettings.swift"), "color.white_balance.mode ios enum", "RawSettings.swift")
    wb_mode_wire = _need(r'camera = !context\.isRaw \|\| settings\.usesCustomWhiteBalance|camera = !context\.isRaw \|\| settings\.whiteBalanceMode == \.camera', ios_tv, "wb mode check", "IOSAdjustmentTransferValues.swift")
    _ = wb_mode_wire
    wb_mode_wire = _need(r'camera \? "([^"]+)"', ios_tv, "color.white_balance.mode ios wire", "IOSAdjustmentTransferValues.swift").group(1)

    # displayChromaDenoise directly from RawSettings.swift + EditorAdjustmentRules.swift
    chroma_m = _need(r"var displayChromaDenoise(?:\s*:\s*Int)?\s*=\s*(\d+)", raw_blk, "detail.denoise.chroma_mode ios default", "RawSettings.swift")
    chroma_def = int(chroma_m.group(1))
    chroma_clamp_m = _need(r"clampedDisplayChromaDenoise.*?min\((\d+),\s*max\((\d+),\s*mode\)\)", raw_blk, "detail.denoise.chroma_mode ios clamp", "RawSettings.swift", re.S)
    chroma_rules_m = _need(r"\((\d+)\.\.\.(\d+)\)\.contains\(settings\.displayChromaDenoise\)", valid_section, "detail.denoise.chroma_mode ios valid", "EditorAdjustmentRules.swift")
    chroma_lo = int(chroma_rules_m.group(1))
    chroma_hi = int(chroma_rules_m.group(2))
    assert (int(chroma_clamp_m.group(2)), int(chroma_clamp_m.group(1))) == (chroma_lo, chroma_hi)

    # wavelet directly from RawDenoiseSettings in RawSettings.swift
    dn_blk = _extract_brace_block(ios_raw, r"struct RawDenoiseSettings\b", "detail.denoise.wavelet ios", "RawSettings.swift")
    dn_enabled = _need(r"var enabled(?:\s*:\s*Bool)?\s*=\s*(true|false)", dn_blk, "wavelet.enabled ios", "RawSettings.swift").group(1) == "true"
    dn_luma = float(_need(r"var luma(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", dn_blk, "wavelet.luma ios", "RawSettings.swift").group(1))
    dn_chroma = float(_need(r"var chroma(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", dn_blk, "wavelet.chroma ios", "RawSettings.swift").group(1))
    dn_coarse = float(_need(r"var coarse(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", dn_blk, "wavelet.coarse ios", "RawSettings.swift").group(1))
    dn_preset_case = _need(rf"if luma == {int(dn_luma) if dn_luma.is_integer() else dn_luma} && chroma == {int(dn_chroma) if dn_chroma.is_integer() else dn_chroma} && coarse == {int(dn_coarse) if dn_coarse.is_integer() else dn_coarse} \{{ return \.(\w+) \}}", dn_blk, "wavelet.preset ios default", "RawSettings.swift").group(1)
    dn_preset_wire = _need(rf'case \.{re.escape(dn_preset_case)}:\s*return "([^"]+)"', ios_tv, "wavelet.preset ios wire", "IOSAdjustmentTransferValues.swift").group(1)
    ios_wavelet_default = {
        "enabled": dn_enabled,
        "luma": dn_luma,
        "chroma": dn_chroma,
        "coarse": dn_coarse,
        "preset": dn_preset_wire,
    }

    # effects.* directly from PhotoEffectsSettings in RawSettings.swift
    fx_blk = _extract_brace_block(ios_raw, r"struct PhotoEffectsSettings\b", "effects.* ios", "RawSettings.swift")
    _need(r"private static func clamped[\s\S]*?value\.rounded\(\)", fx_blk, "effects ios quantization", "RawSettings.swift", re.S)
    _require("guard value.rounded() == value else { throw AdjustmentTransferError.unrepresentable(field.rawValue) }", ios_tr, "effects ios transfer rejects fractional", "IOSAdjustmentTransfer.swift")
    fx_init_blk = _need(r"init\((.*?)\)", fx_blk, "effects.* ios init", "RawSettings.swift", re.S).group(1)

    # lens defaults from RawSettings.swift (or LensCorrectionSettings if defined there)
    lens_blk = _extract_brace_block(ios_raw, r"struct (?:Raw)?Lens\w*Settings\b", "geometry.lens.* ios", "RawSettings.swift")
    lens_dist = _need(r"var distortion(?:\s*:\s*Bool)?\s*=\s*(true|false)", lens_blk, "lens.distortion ios", "RawSettings.swift")
    lens_tca = _need(r"var tca(?:\s*:\s*Bool)?\s*=\s*(true|false)", lens_blk, "lens.tca ios", "RawSettings.swift")
    lens_vig = _need(r"var vignetting(?:\s*:\s*Bool)?\s*=\s*(true|false)", lens_blk, "lens.vignetting ios", "RawSettings.swift")
    lens_auto = _need(r"var autoCrop(?:\s*:\s*Bool)?\s*=\s*(true|false)", lens_blk, "lens.auto_crop ios", "RawSettings.swift")
    _require("profileID: String? = nil", lens_blk, "lens.profile_id ios", "RawSettings.swift")

    m: dict[str, dict] = {}
    m["looks.reference"] = _model_entry("object", modes=("sdr",), default={"kind": "neutral", "id": None}, quantization="discrete")
    m["looks.strength"] = _model_entry("double", modes=("sdr",), min_val=ios_lut_range[0], max_val=ios_lut_range[1], default=ios_def["lutStrength"], scale_from_protocol="p")
    m["light.exposure"] = _model_entry("double", min_val=ios_valid_ranges["exposure"][0], max_val=ios_valid_ranges["exposure"][1], hdr_min=shared["hdr_exp_range"][0], hdr_max=shared["hdr_exp_range"][1], default=ios_def["exposure"])
    m["light.exposure_mode"] = _model_entry("enum", modes=("sdr",), default=exp_mode_def, quantization="discrete")

    hdr_100 = shared["hdr_scalar_100"]
    hdr_defs = shared["hdr_scalar_defs"]
    m["light.contrast"] = _model_entry("double", min_val=ios_valid_ranges["contrast"][0], max_val=ios_valid_ranges["contrast"][1], hdr_min=hdr_100["contrast"][0], hdr_max=hdr_100["contrast"][1], default=ios_def["contrast"], hdr_default=hdr_defs["contrast"], scale_from_protocol="p", hdr_scale_from_protocol="(p - 1) * 100")
    m["light.highlights"] = _model_entry("double", min_val=ios_valid_ranges["highlights"][0], max_val=ios_valid_ranges["highlights"][1], hdr_min=hdr_100["highlights"][0], hdr_max=hdr_100["highlights"][1], default=ios_def["highlights"], hdr_default=hdr_defs["highlights"], scale_from_protocol="p", hdr_scale_from_protocol="-p * 100")
    m["light.shadows"] = _model_entry("double", min_val=ios_valid_ranges["shadows"][0], max_val=ios_valid_ranges["shadows"][1], hdr_min=hdr_100["shadows"][0], hdr_max=hdr_100["shadows"][1], default=ios_def["shadows"], hdr_default=hdr_defs["shadows"], scale_from_protocol="p", hdr_scale_from_protocol="p * 100")
    m["light.s_curve"] = _model_entry("double", min_val=ios_valid_ranges["toneCurve"][0], max_val=ios_valid_ranges["toneCurve"][1], hdr_min=hdr_100["shadows"][0], hdr_max=hdr_100["shadows"][1], default=ios_def["toneCurve"], hdr_default=hdr_defs["shadows"], scale_from_protocol="p", hdr_scale_from_protocol="p * 100")
    m["light.curve"] = _model_entry("object", default=_curve_default("ios"))

    for fid, def_val in (
        ("tone.black_point", shared["tone_bp_def"]),
        ("tone.white_point", shared["tone_wp_def"]),
        ("color.vibrance", shared["vib_def"]),
    ):
        m[fid] = _model_entry("double", min_val=shared["tone_range"][0], max_val=shared["tone_range"][1], default=def_val)

    for zone in ("shadows", "midtones", "highlights"):
        m[f"color.grading.{zone}"] = _model_entry("object", default=shared["grad_def"])

    m["color.white_balance.mode"] = _model_entry("enum", modes=("sdr",), default=wb_mode_wire, quantization="discrete")
    m["color.white_balance.temperature_kelvin"] = _model_entry("double", modes=("sdr",), min_val=ios_temp_range[0], max_val=ios_temp_range[1], default=ios_def["temperature"])
    m["color.white_balance.tint"] = _model_entry("double", modes=("sdr",), min_val=ios_tint_range[0], max_val=ios_tint_range[1], default=ios_def["tint"])
    m["color.saturation"] = _model_entry("double", min_val=ios_valid_ranges["saturation"][0], max_val=ios_valid_ranges["saturation"][1], hdr_min=hdr_100["saturation"][0], hdr_max=hdr_100["saturation"][1], default=ios_def["saturation"], hdr_default=hdr_defs["saturation"], scale_from_protocol="p", hdr_scale_from_protocol="(p - 1) * 100")

    m["hdr.relative_temperature"] = _model_entry("double", modes=("hdr",), min_val=shared["hdr_temp_range"][0], max_val=shared["hdr_temp_range"][1], default=shared["hdr_temp_def"])
    m["hdr.relative_tint"] = _model_entry("double", modes=("hdr",), min_val=shared["hdr_tint_range"][0], max_val=shared["hdr_tint_range"][1], default=shared["hdr_tint_def"])
    m["hdr.peak_limit_ev"] = _model_entry("double", modes=("hdr",), min_val=shared["hdr_peak_range"][0], max_val=shared["hdr_peak_range"][1], default=shared["hdr_peak_def"])
    m["hdr.sdr_exposure_ev"] = _model_entry("double", modes=("hdr",), min_val=shared["hdr_sdr_exp_range"][0], max_val=shared["hdr_sdr_exp_range"][1], default=shared["hdr_sdr_exp_def"])
    m["hdr.sdr_contrast"] = _model_entry("double", modes=("hdr",), min_val=shared["hdr_sdr_con_range"][0], max_val=shared["hdr_sdr_con_range"][1], default=shared["hdr_sdr_con_def"])
    m["hdr.sdr_saturation"] = _model_entry("double", modes=("hdr",), min_val=shared["hdr_sdr_sat_range"][0], max_val=shared["hdr_sdr_sat_range"][1], default=shared["hdr_sdr_sat_def"])
    m["hdr.look"] = _model_entry("object", modes=("hdr",), nullable=True, default=_look_default("ios"))
    m["hdr.camera_development"] = _model_entry("object", modes=("hdr",), default=shared["hdr_cam_def"])

    for axis in HSL_AXES:
        for ch in HSL_CHANNELS:
            m[f"color.hsl.{axis}.{ch}"] = _model_entry("double", min_val=shared["hsl_range"][0], max_val=shared["hsl_range"][1], default=0.0)

    for fid, prop in (
        ("effects.vignette.amount", "vignetteAmount"),
        ("effects.vignette.midpoint", "vignetteMidpoint"),
        ("effects.vignette.roundness", "vignetteRoundness"),
        ("effects.vignette.feather", "vignetteFeather"),
        ("effects.vignette.highlights", "vignetteHighlights"),
        ("effects.grain.amount", "grainAmount"),
        ("effects.grain.size", "grainSize"),
        ("effects.grain.roughness", "grainRoughness"),
    ):
        r_m = _need(rf"static let {prop}Range:\s*ClosedRange<Double>\s*=\s*(-?\d+(?:\.\d+)?)\.\.\.(-?\d+(?:\.\d+)?)", fx_blk, f"{fid} ios range", "RawSettings.swift")
        d_m = _need(rf"{prop}:\s*Double\s*=\s*(-?\d+(?:\.\d+)?)", fx_init_blk, f"{fid} ios default", "RawSettings.swift")
        m[fid] = _model_entry(
            "double",
            min_val=float(r_m.group(1)),
            max_val=float(r_m.group(2)),
            default=float(d_m.group(1)),
            quantization="round_int",
            transfer_rejects_fractional=True,
        )

    m["effects.clarity"] = _model_entry("double", min_val=shared["atmos_range"][0], max_val=shared["atmos_range"][1], hdr_min=shared["hdr_clarity_range"][0], hdr_max=shared["hdr_clarity_range"][1], default=shared["atmos_cl_def"], hdr_default=shared["hdr_clarity_def"], scale_from_protocol="p", hdr_scale_from_protocol="p / 100")
    m["effects.dehaze"] = _model_entry("double", min_val=shared["atmos_range"][0], max_val=shared["atmos_range"][1], hdr_min=shared["hdr_dehaze_range"][0], hdr_max=shared["hdr_dehaze_range"][1], default=shared["atmos_dh_def"], hdr_default=shared["hdr_dehaze_def"], scale_from_protocol="p", hdr_scale_from_protocol="p / 100")

    m["detail.sharpening"] = _model_entry("double", min_val=ios_valid_ranges["sharpening"][0], max_val=ios_valid_ranges["sharpening"][1], default=ios_def["sharpening"], scale_from_protocol="p")
    m["detail.denoise.raw_level"] = _model_entry("none", supported=False, modes=(), scale_from_protocol="none", quantization="none")
    m["detail.denoise.post_rgb"] = _model_entry("double", modes=("sdr", "hdr"), min_val=ios_valid_ranges["noiseReduction"][0], max_val=ios_valid_ranges["noiseReduction"][1], default=ios_def["noiseReduction"])
    m["detail.denoise.chroma_mode"] = _model_entry("int", modes=("sdr",), min_val=chroma_lo, max_val=chroma_hi, default=chroma_def, quantization="discrete")
    m["detail.denoise.wavelet"] = _model_entry("object", modes=("sdr",), default=ios_wavelet_default)

    for key, fid in (("x", "geometry.crop.x"), ("y", "geometry.crop.y"), ("width", "geometry.crop.width"), ("height", "geometry.crop.height")):
        m[fid] = _model_entry("double", min_val=shared["geom_crop_bounds"][0], max_val=shared["geom_crop_bounds"][1], default=shared["geom_crop_defs"][key])
    m["geometry.quarter_turns"] = _model_entry("int", min_val=shared["qt_range"][0], max_val=shared["qt_range"][1], default=shared["qt_def"], quantization="discrete")
    m["geometry.flip_horizontal"] = _model_entry("bool", default=shared["flip_h_def"], quantization="discrete")
    m["geometry.flip_vertical"] = _model_entry("bool", default=shared["flip_v_def"], quantization="discrete")
    m["geometry.straighten_degrees"] = _model_entry("double", min_val=shared["straight_range"][0], max_val=shared["straight_range"][1], default=shared["straight_def"])
    m["geometry.perspective.horizontal"] = _model_entry("double", min_val=shared["persp_h_range"][0], max_val=shared["persp_h_range"][1], default=shared["persp_h_def"])
    m["geometry.perspective.vertical"] = _model_entry("double", min_val=shared["persp_v_range"][0], max_val=shared["persp_v_range"][1], default=shared["persp_v_def"])

    for fid, grp in (
        ("geometry.lens.distortion", lens_dist),
        ("geometry.lens.tca", lens_tca),
        ("geometry.lens.vignetting", lens_vig),
        ("geometry.lens.auto_crop", lens_auto),
    ):
        dflt = grp.group(1) == "true"
        m[fid] = _model_entry("bool", modes=("sdr", "hdr"), default=dflt, quantization="discrete")
    m["geometry.lens.profile_id"] = _model_entry("string", modes=("sdr",), nullable=True, default=None, quantization="discrete")

    m["local.ai_denoise_enabled"] = _model_entry("none", supported=False, modes=(), scale_from_protocol="none", quantization="none")
    m["local.hdr_camera_ai_enabled"] = _model_entry("none", supported=False, modes=(), scale_from_protocol="none", quantization="none")
    return m


def _parse_android_model() -> dict[str, dict]:
    """Parse Android model entries solely from RawLabAndroid Kotlin sources."""
    kt_edit = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/settings/EditSettings.kt"))
    kt_hdr = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/settings/HDRSettings.kt"))
    kt_grading = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/settings/ColorGradingSettings.kt"))
    kt_geom = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/geometry/GeometrySettings.kt"))
    kt_tr = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/adjustments/AdjustmentTransfer.kt"))
    kt_tv = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/adjustments/AdjustmentTransferValues.kt"))

    _require("context.onTransferNotice?.invoke(AdjustmentTransferNotice.RETAINED_TARGET_PROCESSING_VERSION)", kt_tr, "processing version android", "AdjustmentTransfer.kt")
    _require("context.onTransferNotice?.invoke(", kt_tv, "detail.denoise kt sdr ignored with notice", "AdjustmentTransferValues.kt")
    _require("for (field in listOf(AdjustmentField.RAW_DENOISE, AdjustmentField.POST_RGB_DENOISE))", kt_tv, "detail.denoise kt sdr unsupported", "AdjustmentTransferValues.kt")
    _require_absent("aiDenoiseEnabled", kt_edit, "local.ai_denoise_enabled unsupported android", "EditSettings.kt")
    _require_absent("hdrCameraAIEnabled", kt_edit + "\n" + kt_hdr, "local.hdr_camera_ai_enabled unsupported android", "EditSettings.kt")

    def _collect_kt_bounds(block: str) -> dict[str, tuple[float, float]]:
        bounds: dict[str, tuple[float, float]] = {}
        for prop, lo, hi in re.findall(r"(\w+)\s+in\s+(-?\d+(?:\.\d+)?)f\.\.(-?\d+(?:\.\d+)?)f", block):
            if prop != "it":
                bounds[prop] = (float(lo), float(hi))
        for props_raw, lo, hi in re.findall(
            r"listOf\(([^)]+)\)\.all\s*\{\s*(?:it\.isFinite\(\)\s*&&\s*)?it\s+in\s+(-?\d+(?:\.\d+)?)f\.\.(-?\d+(?:\.\d+)?)f",
            block,
        ):
            for prop in re.findall(r"\b(\w+)\b", props_raw):
                bounds[prop] = (float(lo), float(hi))
        return bounds

    edit_blk = _extract_brace_block(kt_edit, r"data class EditSettings\b", "EditSettings", "EditSettings.kt")
    kt_defaults: dict[str, float] = {}
    for prop, val in re.findall(r"val (\w+):\s*Float\s*=\s*(-?\d+(?:\.\d+)?)f", edit_blk):
        kt_defaults[prop] = float(val)
    kt_bounds = _collect_kt_bounds(edit_blk)

    _require("AdjustmentField.CONTRAST -> settings.copy(contrast = (value - 1).toFloat())", kt_tv, "contrast scale android", "AdjustmentTransferValues.kt")
    _require("AdjustmentField.SATURATION -> settings.copy(saturation = (value - 1).toFloat())", kt_tv, "saturation scale android", "AdjustmentTransferValues.kt")
    _require("AdjustmentField.HIGHLIGHTS -> settings.copy(highlights = (-value.toFloat())", kt_tv, "highlights scale android", "AdjustmentTransferValues.kt")
    _require("AdjustmentField.CONTRAST)?.let { result = result.copy(contrast = (it - 1).toFloat()); hdr = hdr.copy(contrast = ((it - 1) * 100).toFloat()) }", kt_tr, "hdr contrast scale android", "AdjustmentTransfer.kt")
    _require("AdjustmentField.HIGHLIGHTS)?.let { result = result.copy(highlights = (-it).toFloat()); hdr = hdr.copy(highlights = (-it * 100).toFloat()) }", kt_tr, "hdr highlights scale android", "AdjustmentTransfer.kt")
    _require("AdjustmentField.SHADOWS)?.let { result = result.copy(shadows = it.toFloat()); hdr = hdr.copy(shadows = (it * 100).toFloat()) }", kt_tr, "hdr shadows scale android", "AdjustmentTransfer.kt")
    _require("AdjustmentField.SATURATION)?.let { result = result.copy(saturation = (it - 1).toFloat()); hdr = hdr.copy(saturation = ((it - 1) * 100).toFloat()) }", kt_tr, "hdr saturation scale android", "AdjustmentTransfer.kt")
    _require("clarity = number(AdjustmentField.CLARITY)?.let { (it / 100).toFloat().canonicalZero() } ?: detail.clarity", kt_tr, "hdr clarity scale android", "AdjustmentTransfer.kt")
    _require("dehaze = number(AdjustmentField.DEHAZE)?.let { (it / 100).toFloat().canonicalZero() } ?: detail.dehaze", kt_tr, "hdr dehaze scale android", "AdjustmentTransfer.kt")

    film_def = _need(r'val film:\s*String\s*=\s*"([^"]+)"', edit_blk, "looks.reference android film", "EditSettings.kt").group(1)
    _require("val recipeID: String? = null", edit_blk, "looks.reference android recipeID nullable", "EditSettings.kt")
    _require(f's.film == "{film_def}" -> {{ kind = "neutral"; id = null }}', kt_tv, "looks.reference android neutral wire", "AdjustmentTransferValues.kt")

    exp_mode_bounds = tuple(int(x) for x in _need(r"require\(exposureMode in (\d+)\.\.(\d+)\)", edit_blk, "light.exposure_mode android bounds", "EditSettings.kt").groups())
    exp_mode_int = int(_need(r"val exposureMode:\s*Int\s*=\s*(\d+)", edit_blk, "light.exposure_mode android default", "EditSettings.kt").group(1))
    exp_modes_raw = _need(r"AdjustmentField\.EXPOSURE_MODE\]\s*=.*?listOf\(([^)]+)\)\[s\.exposureMode\]", kt_tv, "light.exposure_mode android wires", "AdjustmentTransferValues.kt").group(1)
    exp_mode_wire = _parse_quoted_list(exp_modes_raw)[exp_mode_int]

    custom_wb_def = _need(r"val customWb:\s*Boolean\s*=\s*(true|false)", edit_blk, "color.white_balance.mode android default", "EditSettings.kt").group(1) == "true"
    wb_wire_m = _need(
        r'val camera = !context\.isRaw \|\| !s\.customWb.*?if \(camera\) "([^"]+)" else "([^"]+)"',
        kt_tv,
        "color.white_balance.mode android wire",
        "AdjustmentTransferValues.kt",
        re.S,
    )
    wb_mode_wire = wb_wire_m.group(2 if custom_wb_def else 1)

    chroma_bounds = tuple(int(x) for x in _need(r"require\(displayChromaDenoise in (\d+)\.\.(\d+)\)", edit_blk, "detail.denoise.chroma_mode android bounds", "EditSettings.kt").groups())
    chroma_def = int(_need(r"val displayChromaDenoise:\s*Int\s*=\s*(\d+)", edit_blk, "detail.denoise.chroma_mode android default", "EditSettings.kt").group(1))

    # HslSettings
    hsl_blk = _extract_kt_class_block(kt_edit, r"class HslSettings\b", "color.hsl.* android", "EditSettings.kt")
    hsl_range = tuple(float(x) for x in _need(r"(-?\d+(?:\.\d+)?)f\.\.(-?\d+(?:\.\d+)?)f", hsl_blk, "color.hsl.* android bounds", "EditSettings.kt").groups())

    # ColorGradingSettings
    grad_blk = _extract_kt_class_block(kt_grading, r"data class ColorGradingWheel\b", "color.grading.* android", "ColorGradingSettings.kt")
    grad_def = {
        "hue": float(_need(r"val hue:\s*Float\s*=\s*(-?\d+(?:\.\d+)?)f", grad_blk, "grading.hue android", "ColorGradingSettings.kt").group(1)),
        "saturation": float(_need(r"val saturation:\s*Float\s*=\s*(-?\d+(?:\.\d+)?)f", grad_blk, "grading.saturation android", "ColorGradingSettings.kt").group(1)),
    }

    # DenoiseSettings
    dn_blk = _extract_brace_block(kt_edit, r"data class DenoiseSettings\b", "detail.denoise.wavelet android", "EditSettings.kt")
    kt_wavelet_default = {
        "enabled": _need(r"val enabled:\s*Boolean\s*=\s*(true|false)", dn_blk, "wavelet.enabled android", "EditSettings.kt").group(1) == "true",
        "luma": float(_need(r"val luma:\s*Float\s*=\s*(-?\d+(?:\.\d+)?)f", dn_blk, "wavelet.luma android", "EditSettings.kt").group(1)),
        "chroma": float(_need(r"val chroma:\s*Float\s*=\s*(-?\d+(?:\.\d+)?)f", dn_blk, "wavelet.chroma android", "EditSettings.kt").group(1)),
        "coarse": float(_need(r"val coarse:\s*Float\s*=\s*(-?\d+(?:\.\d+)?)f", dn_blk, "wavelet.coarse android", "EditSettings.kt").group(1)),
        "preset": _need(r"luma == 0f && chroma == 46f && coarse == 50f -> DenoisePreset\.(\w+)", dn_blk, "wavelet.preset android", "EditSettings.kt").group(1).lower(),
    }

    # PhotoEffectParameter enum
    fx_enum_blk = _extract_brace_block(kt_edit, r"enum class PhotoEffectParameter\b", "effects.* android", "EditSettings.kt")
    kt_fx: dict[str, tuple[float, float, float]] = {}
    for m_fx in re.finditer(r"(\w+)\((?:true|false),\s*(-?\d+(?:\.\d+)?)f\.\.(-?\d+(?:\.\d+)?)f,\s*(-?\d+(?:\.\d+)?)f\)", fx_enum_blk):
        parts = m_fx.group(1).lower().split("_", 1)
        kt_fx[f"effects.{parts[0]}.{parts[1]}"] = (float(m_fx.group(2)), float(m_fx.group(3)), float(m_fx.group(4)))

    # LensSettings
    lens_blk = _extract_brace_block(kt_edit, r"data class LensSettings\b", "geometry.lens.* android", "EditSettings.kt")
    lens_dist = _need(r"val distortion:\s*Boolean\s*=\s*(true|false)", lens_blk, "lens.distortion android", "EditSettings.kt").group(1) == "true"
    lens_tca = _need(r"val tca:\s*Boolean\s*=\s*(true|false)", lens_blk, "lens.tca android", "EditSettings.kt").group(1) == "true"
    lens_vig = _need(r"val vignetting:\s*Boolean\s*=\s*(true|false)", lens_blk, "lens.vignetting android", "EditSettings.kt").group(1) == "true"
    lens_auto = _need(r"val autoCrop:\s*Boolean\s*=\s*(true|false)", lens_blk, "lens.auto_crop android", "EditSettings.kt").group(1) == "true"
    _require("val profileId: String? = null", lens_blk, "lens.profile_id android", "EditSettings.kt")

    # GeometrySettings
    geom_blk = _extract_brace_block(kt_geom, r"data class GeometrySettings\b", "geometry.* android", "GeometrySettings.kt")
    kt_crop_defs = {k: float(_need(rf"val {k}:\s*Float\s*=\s*(-?\d+(?:\.\d+)?)f", geom_blk, f"geometry.{k} android default", "GeometrySettings.kt").group(1)) for k in ("cropX", "cropY", "cropWidth", "cropHeight")}
    crop_min_val = float(_need(r"require\(cropX\s*>=\s*(-?\d+(?:\.\d+)?)f\s*&&\s*cropX\s*<\s*1f\s*&&\s*cropY\s*>=\s*\1f", geom_blk, "geometry.crop min android", "GeometrySettings.kt").group(1))
    crop_max_val = float(_need(r"cropWidth\s*<=\s*(-?\d+(?:\.\d+)?)f\s*&&\s*cropHeight\s*<=\s*\1f", geom_blk, "geometry.crop max android", "GeometrySettings.kt").group(1))
    kt_crop_bounds = (crop_min_val, crop_max_val)
    kt_qt_def = int(_need(r"val quarterTurns:\s*Int\s*=\s*(\d+)", geom_blk, "geometry.quarter_turns android default", "GeometrySettings.kt").group(1))
    kt_qt_bounds = tuple(int(x) for x in _need(r"quarterTurns in (\d+)\.\.(\d+)", geom_blk, "geometry.quarter_turns android bounds", "GeometrySettings.kt").groups())
    kt_flip_h = _need(r"val flipHorizontal:\s*Boolean\s*=\s*(true|false)", geom_blk, "geometry.flip_horizontal android", "GeometrySettings.kt").group(1) == "true"
    kt_flip_v = _need(r"val flipVertical:\s*Boolean\s*=\s*(true|false)", geom_blk, "geometry.flip_vertical android", "GeometrySettings.kt").group(1) == "true"
    kt_straight_def = float(_need(r"val straightenDegrees:\s*Float\s*=\s*(-?\d+(?:\.\d+)?)f", geom_blk, "geometry.straighten android default", "GeometrySettings.kt").group(1))
    kt_straight_bounds = tuple(float(x) for x in _need(r"straightenDegrees in (-?\d+(?:\.\d+)?)f\.\.(-?\d+(?:\.\d+)?)f", geom_blk, "geometry.straighten android bounds", "GeometrySettings.kt").groups())
    kt_persp_h_def = float(_need(r"val perspectiveHorizontal:\s*Float\s*=\s*(-?\d+(?:\.\d+)?)f", geom_blk, "geometry.perspective.horizontal android default", "GeometrySettings.kt").group(1))
    kt_persp_v_def = float(_need(r"val perspectiveVertical:\s*Float\s*=\s*(-?\d+(?:\.\d+)?)f", geom_blk, "geometry.perspective.vertical android default", "GeometrySettings.kt").group(1))
    kt_persp_h_bounds = tuple(float(x) for x in _need(r"perspectiveHorizontal in (-?\d+(?:\.\d+)?)f\.\.(-?\d+(?:\.\d+)?)f", geom_blk, "geometry.perspective.horizontal android bounds", "GeometrySettings.kt").groups())
    kt_persp_v_bounds = tuple(float(x) for x in _need(r"perspectiveVertical in (-?\d+(?:\.\d+)?)f\.\.(-?\d+(?:\.\d+)?)f", geom_blk, "geometry.perspective.vertical android bounds", "GeometrySettings.kt").groups())

    # HDRSettings.kt
    hdr_defaults: dict[str, float] = {}
    hdr_bounds: dict[str, tuple[float, float]] = {}
    for cls_name in ("HDRToneSettings", "HDRColorSettings", "HDRRenditionSettings", "HDRDetailSettings", "HDRSettings"):
        blk = _extract_brace_block(kt_hdr, rf"data class {cls_name}\b", f"hdr {cls_name} android", "HDRSettings.kt")
        for prop, val in re.findall(r"val (\w+):\s*Float\s*=\s*(-?\d+(?:\.\d+)?)f", blk):
            hdr_defaults[prop] = float(val)
        hdr_bounds.update(_collect_kt_bounds(blk))
    kt_hdr_cam_blk = _extract_brace_block(kt_hdr, r"data class HDRCameraDevelopmentSettings\b", "hdr.camera_development android", "HDRSettings.kt")
    custom_cam_wb = _need(r"val customWhiteBalance:\s*Boolean\s*=\s*(true|false)", kt_hdr_cam_blk, "hdr.cam wb flag android", "HDRSettings.kt").group(1) == "true"
    sensor_cam_exp = _need(r"val sensorExposure:\s*Boolean\s*=\s*(true|false)", kt_hdr_cam_blk, "hdr.cam exp flag android", "HDRSettings.kt").group(1) == "true"
    cam_wb_m = _need(r'"white_balance_mode" to AdjustmentValue\.Text\(if \(camera\.customWhiteBalance\) "([^"]+)" else "([^"]+)"\)', kt_tr, "hdr.cam wb wire android", "AdjustmentTransfer.kt")
    cam_exp_m = _need(r'"exposure_reference" to AdjustmentValue\.Text\(if \(camera\.sensorExposure\) "([^"]+)" else "([^"]+)"\)', kt_tr, "hdr.cam exp wire android", "AdjustmentTransfer.kt")
    kt_hdr_cam_def = {
        "version": int(float(_need(r'"version" to AdjustmentValue\.Number\((-?\d+(?:\.\d+)?)\)', kt_tr, "hdr.cam version android", "AdjustmentTransfer.kt").group(1))),
        "white_balance_mode": cam_wb_m.group(1 if custom_cam_wb else 2),
        "temperature": float(_need(r"val temperature:\s*Float\s*=\s*(-?\d+(?:\.\d+)?)f", kt_hdr_cam_blk, "hdr.cam temp android", "HDRSettings.kt").group(1)),
        "tint": float(_need(r"val tint:\s*Float\s*=\s*(-?\d+(?:\.\d+)?)f", kt_hdr_cam_blk, "hdr.cam tint android", "HDRSettings.kt").group(1)),
        "exposure_reference": cam_exp_m.group(1 if sensor_cam_exp else 2),
        "fbdd_level": int(_need(r"val fbddLevel:\s*Int\s*=\s*(\d+)", kt_hdr_cam_blk, "hdr.cam fbdd android", "HDRSettings.kt").group(1)),
    }

    m: dict[str, dict] = {}
    m["looks.reference"] = _model_entry("object", modes=("sdr",), default={"kind": "neutral", "id": None}, quantization="discrete")
    m["looks.strength"] = _model_entry("float", modes=("sdr",), min_val=kt_bounds["strength"][0], max_val=kt_bounds["strength"][1], default=kt_defaults["strength"], scale_from_protocol="p")
    m["light.exposure"] = _model_entry("float", min_val=kt_bounds["exposure"][0], max_val=kt_bounds["exposure"][1], hdr_min=hdr_bounds["exposure"][0], hdr_max=hdr_bounds["exposure"][1], default=kt_defaults["exposure"])
    m["light.exposure_mode"] = _model_entry("int", modes=("sdr",), min_val=exp_mode_bounds[0], max_val=exp_mode_bounds[1], default=exp_mode_wire, quantization="discrete")
    m["light.contrast"] = _model_entry("float", min_val=kt_bounds["contrast"][0], max_val=kt_bounds["contrast"][1], hdr_min=hdr_bounds["contrast"][0], hdr_max=hdr_bounds["contrast"][1], default=kt_defaults["contrast"], hdr_default=hdr_defaults["contrast"], scale_from_protocol="p - 1", hdr_scale_from_protocol="(p - 1) * 100")
    m["light.highlights"] = _model_entry("float", min_val=kt_bounds["highlights"][0], max_val=kt_bounds["highlights"][1], hdr_min=hdr_bounds["highlights"][0], hdr_max=hdr_bounds["highlights"][1], default=kt_defaults["highlights"], hdr_default=hdr_defaults["highlights"], scale_from_protocol="-p", hdr_scale_from_protocol="-p * 100")
    m["light.shadows"] = _model_entry("float", min_val=kt_bounds["shadows"][0], max_val=kt_bounds["shadows"][1], hdr_min=hdr_bounds["shadows"][0], hdr_max=hdr_bounds["shadows"][1], default=kt_defaults["shadows"], hdr_default=hdr_defaults["shadows"], scale_from_protocol="p", hdr_scale_from_protocol="p * 100")
    m["light.s_curve"] = _model_entry("float", min_val=kt_bounds["toneCurve"][0], max_val=kt_bounds["toneCurve"][1], hdr_min=hdr_bounds["curveStrength"][0], hdr_max=hdr_bounds["curveStrength"][1], default=kt_defaults["toneCurve"], hdr_default=hdr_defaults["curveStrength"], scale_from_protocol="p", hdr_scale_from_protocol="p * 100")
    m["light.curve"] = _model_entry("object", default=_curve_default("android"))

    for fid, prop in (("tone.black_point", "blackPoint"), ("tone.white_point", "whitePoint"), ("color.vibrance", "vibrance")):
        m[fid] = _model_entry("float", min_val=kt_bounds[prop][0], max_val=kt_bounds[prop][1], default=kt_defaults[prop])

    for zone in ("shadows", "midtones", "highlights"):
        m[f"color.grading.{zone}"] = _model_entry("object", default=grad_def)

    m["color.white_balance.mode"] = _model_entry("bool", modes=("sdr",), default=wb_mode_wire, quantization="discrete")
    m["color.white_balance.temperature_kelvin"] = _model_entry("float", modes=("sdr",), min_val=kt_bounds["temperature"][0], max_val=kt_bounds["temperature"][1], default=kt_defaults["temperature"])
    m["color.white_balance.tint"] = _model_entry("float", modes=("sdr",), min_val=kt_bounds["tint"][0], max_val=kt_bounds["tint"][1], default=kt_defaults["tint"])
    m["color.saturation"] = _model_entry("float", min_val=kt_bounds["saturation"][0], max_val=kt_bounds["saturation"][1], hdr_min=hdr_bounds["saturation"][0], hdr_max=hdr_bounds["saturation"][1], default=kt_defaults["saturation"], hdr_default=hdr_defaults["saturation"], scale_from_protocol="p - 1", hdr_scale_from_protocol="(p - 1) * 100")

    m["hdr.relative_temperature"] = _model_entry("float", modes=("hdr",), min_val=hdr_bounds["temperature"][0], max_val=hdr_bounds["temperature"][1], default=hdr_defaults["temperature"])
    m["hdr.relative_tint"] = _model_entry("float", modes=("hdr",), min_val=hdr_bounds["tint"][0], max_val=hdr_bounds["tint"][1], default=hdr_defaults["tint"])
    m["hdr.peak_limit_ev"] = _model_entry("float", modes=("hdr",), min_val=hdr_bounds["peakLimitEV"][0], max_val=hdr_bounds["peakLimitEV"][1], default=hdr_defaults["peakLimitEV"])
    m["hdr.sdr_exposure_ev"] = _model_entry("float", modes=("hdr",), min_val=hdr_bounds["sdrExposureEV"][0], max_val=hdr_bounds["sdrExposureEV"][1], default=hdr_defaults["sdrExposureEV"])
    m["hdr.sdr_contrast"] = _model_entry("float", modes=("hdr",), min_val=hdr_bounds["sdrContrast"][0], max_val=hdr_bounds["sdrContrast"][1], default=hdr_defaults["sdrContrast"])
    m["hdr.sdr_saturation"] = _model_entry("float", modes=("hdr",), min_val=hdr_bounds["sdrSaturation"][0], max_val=hdr_bounds["sdrSaturation"][1], default=hdr_defaults["sdrSaturation"])
    m["hdr.look"] = _model_entry("object", modes=("hdr",), nullable=True, default=_look_default("android"))
    m["hdr.camera_development"] = _model_entry("object", modes=("hdr",), default=kt_hdr_cam_def)

    for axis in HSL_AXES:
        for ch in HSL_CHANNELS:
            m[f"color.hsl.{axis}.{ch}"] = _model_entry("float", min_val=hsl_range[0], max_val=hsl_range[1], default=0.0)

    for fid, (lo, hi, dflt) in kt_fx.items():
        m[fid] = _model_entry("float", min_val=lo, max_val=hi, default=dflt)

    for fid, prop in (("effects.clarity", "clarity"), ("effects.dehaze", "dehaze")):
        m[fid] = _model_entry("float", min_val=kt_bounds[prop][0], max_val=kt_bounds[prop][1], hdr_min=hdr_bounds[prop][0], hdr_max=hdr_bounds[prop][1], default=kt_defaults[prop], hdr_default=hdr_defaults[prop], scale_from_protocol="p", hdr_scale_from_protocol="p / 100")

    m["detail.sharpening"] = _model_entry("float", min_val=kt_bounds["sharpening"][0], max_val=kt_bounds["sharpening"][1], default=kt_defaults["sharpening"], scale_from_protocol="p")
    m["detail.denoise.raw_level"] = _model_entry("none", supported=False, modes=(), scale_from_protocol="none", quantization="none")
    m["detail.denoise.post_rgb"] = _model_entry("float", modes=("hdr",), min_val=hdr_bounds["denoise"][0], max_val=hdr_bounds["denoise"][1], default=hdr_defaults["denoise"])
    m["detail.denoise.chroma_mode"] = _model_entry("int", modes=("sdr",), min_val=chroma_bounds[0], max_val=chroma_bounds[1], default=chroma_def, quantization="discrete")
    m["detail.denoise.wavelet"] = _model_entry("object", modes=("sdr",), default=kt_wavelet_default)

    for key, fid in (("cropX", "geometry.crop.x"), ("cropY", "geometry.crop.y"), ("cropWidth", "geometry.crop.width"), ("cropHeight", "geometry.crop.height")):
        m[fid] = _model_entry("float", min_val=kt_crop_bounds[0], max_val=kt_crop_bounds[1], default=kt_crop_defs[key])
    m["geometry.quarter_turns"] = _model_entry("int", min_val=kt_qt_bounds[0], max_val=kt_qt_bounds[1], default=kt_qt_def, quantization="discrete")
    m["geometry.flip_horizontal"] = _model_entry("bool", default=kt_flip_h, quantization="discrete")
    m["geometry.flip_vertical"] = _model_entry("bool", default=kt_flip_v, quantization="discrete")
    m["geometry.straighten_degrees"] = _model_entry("float", min_val=kt_straight_bounds[0], max_val=kt_straight_bounds[1], default=kt_straight_def)
    m["geometry.perspective.horizontal"] = _model_entry("float", min_val=kt_persp_h_bounds[0], max_val=kt_persp_h_bounds[1], default=kt_persp_h_def)
    m["geometry.perspective.vertical"] = _model_entry("float", min_val=kt_persp_v_bounds[0], max_val=kt_persp_v_bounds[1], default=kt_persp_v_def)

    for fid, dflt in (
        ("geometry.lens.distortion", lens_dist),
        ("geometry.lens.tca", lens_tca),
        ("geometry.lens.vignetting", lens_vig),
        ("geometry.lens.auto_crop", lens_auto),
    ):
        m[fid] = _model_entry("bool", modes=("sdr", "hdr"), default=dflt, quantization="discrete")
    m["geometry.lens.profile_id"] = _model_entry("string", modes=("sdr",), nullable=True, default=None, quantization="discrete")

    m["local.ai_denoise_enabled"] = _model_entry("none", supported=False, modes=(), scale_from_protocol="none", quantization="none")
    m["local.hdr_camera_ai_enabled"] = _model_entry("none", supported=False, modes=(), scale_from_protocol="none", quantization="none")
    return m


def _parse_windows_model() -> dict[str, dict]:
    """Parse Windows model entries solely from RawLabWindows C# sources."""
    cs_adj = _strip_line_comments(_read("RawLabWindows/Adjustments.cs"))
    cs_fx = _strip_line_comments(_read("RawLabWindows/PhotoEffectsSettings.cs"))
    cs_dn = _strip_line_comments(_read("RawLabWindows/DenoiseSettings.cs"))
    cs_tone = _strip_line_comments(_read("RawLabWindows/ToneControlsSettings.cs"))
    cs_atmos = _strip_line_comments(_read("RawLabWindows/AtmosphereSettings.cs"))
    cs_hsl = _strip_line_comments(_read("RawLabWindows/HslSettings.cs"))
    cs_grad = _strip_line_comments(_read("RawLabWindows/ColorGradingSettings.cs"))
    cs_geom = _strip_line_comments(_read("RawLabWindows/GeometrySettings.cs"))
    cs_hdr = _strip_line_comments(_read("RawLabWindows/HDRSettings.cs"))
    cs_tr = _strip_line_comments(_read("RawLabWindows/AdjustmentTransfer.cs"))
    cs_tv = _strip_line_comments(_read("RawLabWindows/AdjustmentTransferValues.cs"))
    cs_hdr_tr = _strip_line_comments(_read("RawLabWindows/HDRAdjustmentTransfer.cs"))

    _require("context.OnTransferNotice?.Invoke(AdjustmentTransferNotice.RetainedTargetProcessingVersion)", cs_tr, "processing version windows", "AdjustmentTransfer.cs")
    _require("context.OnTransferNotice?.Invoke(", cs_tv, "detail.denoise cs sdr ignored with notice", "AdjustmentTransferValues.cs")
    _require("foreach(var field in new[]{F.RawDenoise,F.PostRGBDenoise})", cs_tv, "detail.denoise windows sdr unsupported", "AdjustmentTransferValues.cs")
    _require("Math.Round(value, 1, MidpointRounding.AwayFromZero)", cs_adj, "effects windows quantization", "Adjustments.cs")
    _require("F.Contrast or F.Saturation=>(value-1)*100", cs_tv, "contrast/saturation scale windows", "AdjustmentTransferValues.cs")
    _require("F.Highlights=>-value*100", cs_tv, "highlights scale windows", "AdjustmentTransferValues.cs")
    _require("_=>value*100", cs_tv, "default scale windows", "AdjustmentTransferValues.cs")
    _require("public bool AIDenoiseEnabled { get; set; }", cs_adj, "local.ai_denoise_enabled windows", "Adjustments.cs")
    _require("internal bool HDRCameraAIEnabled { get; set; }", cs_adj, "local.hdr_camera_ai_enabled windows", "Adjustments.cs")

    cs_specs: dict[str, tuple[float, float, float]] = {}
    for m_sp in re.finditer(r'new\(Parameter\.(\w+),"[^"]*","[^"]*",(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?),(-?\.\d+|\d+(?:\.\d+)?)', cs_adj):
        cs_specs[m_sp.group(1)] = (float(m_sp.group(2)), float(m_sp.group(3)), float(m_sp.group(4)))

    cs_defaults_arr = [float(x) for x in _need(r"private double\[\] values = \[([^\]]+)\];", cs_adj, "windows defaults array", "Adjustments.cs").group(1).split(",")]
    cs_param_order = re.findall(r"[A-Za-z]\w*", _need(r"public enum Parameter \{([^}]*)\}", cs_adj, "windows Parameter enum order", "Adjustments.cs", re.S).group(1))
    assert cs_param_order[: len(cs_defaults_arr)] == [
        "Strength", "Exposure", "Temperature", "Tint", "Contrast",
        "Highlights", "Shadows", "ToneCurve", "Saturation", "Sharpening",
    ], f"windows Parameter enum order drifted: {cs_param_order[:10]}"
    cs_defaults = dict(zip(cs_param_order, cs_defaults_arr))

    _require('else if(edit.Look==null) { kind="neutral";id=null; }', cs_tv, "looks.reference windows neutral", "AdjustmentTransferValues.cs")
    _require('Put(F.Look,new {kind,id});', cs_tv, "looks.reference windows put", "AdjustmentTransferValues.cs")
    exp_mode_def_i = int(_need(r"public int ExposureMode \{ get; set; \} = (\d+);", cs_adj, "light.exposure_mode windows default", "Adjustments.cs").group(1))
    exp_mode_bounds = tuple(int(x) for x in _need(r"snapshot\.ExposureMode is < (\d+) or > (\d+)", cs_adj, "exposure mode clamp windows", "Adjustments.cs").groups())
    exp_modes_raw = _need(r'Put\(F\.ExposureMode,context\.IsRaw \? new\[\]\{([^}]+)\}\[s\.ExposureMode\]', cs_tv, "light.exposure_mode windows wire", "AdjustmentTransferValues.cs").group(1)
    exp_mode_wire = _parse_quoted_list(exp_modes_raw)[exp_mode_def_i]

    cam_wb_def = _need(r"public bool CameraWhiteBalance \{ get; private set; \} = (true|false);", cs_adj, "wb mode windows default", "Adjustments.cs").group(1) == "true"
    wb_wire_m = _need(
        r'var camera=!context\.IsRaw \|\| s\.CameraWhiteBalance;\s*Put\(F\.WhiteBalanceMode,!context\.IsRaw \? "none" : camera \? "([^"]+)" : "([^"]+)"\);',
        cs_tv,
        "wb mode windows wire",
        "AdjustmentTransferValues.cs",
    )
    wb_mode_wire = wb_wire_m.group(1 if cam_wb_def else 2)

    # PhotoEffectsSettings.cs
    cs_fx_defs: dict[str, tuple[float, float, float]] = {}
    for m_fx in re.finditer(r"new\(PhotoEffectParameter\.(\w+),\s*Loc\.Text\([^\)]+\),\s*(?:true|false),\s*(-?\d+),\s*(-?\d+),\s*(-?\d+)\)", cs_fx):
        cs_fx_defs[m_fx.group(1)] = (float(m_fx.group(2)), float(m_fx.group(3)), float(m_fx.group(4)))

    # DenoiseSettings.cs
    dn_m = _need(r"record DenoiseSettings\(bool Enabled=(false|true),double Luma=(\d+),double Chroma=(\d+),double Coarse=(\d+)\)", cs_dn, "detail.denoise.wavelet defaults", "DenoiseSettings.cs")
    cs_preset_raw = _need(r'new\[\]\{([^}]+)\}\[denoise\.Preset\]', cs_tv, "detail.denoise.wavelet preset wire", "AdjustmentTransferValues.cs").group(1)
    cs_preset_names = _parse_quoted_list(cs_preset_raw)
    _require("public int Preset => (this with {Enabled=true})==Detail ? 0 : (this with {Enabled=true})==Clean ? 1 : 2;", cs_dn, "detail.denoise.wavelet preset detail", "DenoiseSettings.cs")
    cs_wavelet_default = {
        "enabled": dn_m.group(1) == "true",
        "luma": float(dn_m.group(2)),
        "chroma": float(dn_m.group(3)),
        "coarse": float(dn_m.group(4)),
        "preset": cs_preset_names[0],
    }

    # DisplayChromaDenoise
    _require("private int displayChromaDenoise;", cs_adj, "chroma_mode windows backing field", "Adjustments.cs")
    chroma_def = int(_need(r"DisplayChromaDenoise\s*=\s*(\d+);", cs_adj, "chroma_mode windows reset default", "Adjustments.cs").group(1))
    chroma_bounds = tuple(int(x) for x in _need(r"if \(value is < (\d+) or > (\d+)\)", _extract_brace_block(cs_adj, r"public int DisplayChromaDenoise\b", "chroma_mode property", "Adjustments.cs"), "chroma clamp windows", "Adjustments.cs").groups())

    # ToneControlsSettings.cs, AtmosphereSettings.cs, HslSettings.cs, ColorGradingSettings.cs, GeometrySettings.cs
    tone_bp_def = float(_need(r"double BlackPoint = (-?\d+(?:\.\d+)?)", cs_tone, "tone.black_point default windows", "ToneControlsSettings.cs").group(1))
    tone_wp_def = float(_need(r"double WhitePoint = (-?\d+(?:\.\d+)?)", cs_tone, "tone.white_point default windows", "ToneControlsSettings.cs").group(1))
    tone_vib_def = float(_need(r"double Vibrance = (-?\d+(?:\.\d+)?)", cs_tone, "color.vibrance default windows", "ToneControlsSettings.cs").group(1))
    tone_range = tuple(float(x) for x in _need(r"value is < (-?\d+(?:\.\d+)?) or > (-?\d+(?:\.\d+)?)", cs_tone, "tone bounds windows", "ToneControlsSettings.cs").groups())
    atmos_cl_def = float(_need(r"double Clarity = (-?\d+(?:\.\d+)?)", cs_atmos, "effects.clarity default windows", "AtmosphereSettings.cs").group(1))
    atmos_dh_def = float(_need(r"double Dehaze = (-?\d+(?:\.\d+)?)", cs_atmos, "effects.dehaze default windows", "AtmosphereSettings.cs").group(1))
    atmos_range = tuple(float(x) for x in _need(r"value is < (-?\d+(?:\.\d+)?) or > (-?\d+(?:\.\d+)?)", cs_atmos, "atmos bounds windows", "AtmosphereSettings.cs").groups())
    _require("new double[24]", cs_hsl, "hsl default 0 windows", "HslSettings.cs")
    hsl_range = tuple(float(x) for x in _need(r"value is < (-?\d+(?:\.\d+)?) or > (-?\d+(?:\.\d+)?)", cs_hsl, "hsl bounds windows", "HslSettings.cs").groups())
    grad_wheel_blk = _extract_brace_block(cs_grad, r"public sealed record ColorGradingWheel\b", "color.grading wheel windows", "ColorGradingSettings.cs")
    _require("public double Hue { get; init; }", grad_wheel_blk, "grading hue prop windows", "ColorGradingSettings.cs")
    _require("public double Saturation { get; init; }", grad_wheel_blk, "grading sat prop windows", "ColorGradingSettings.cs")
    _require("IsDefault => Hue == 0 && Saturation == 0;", grad_wheel_blk, "grading default windows", "ColorGradingSettings.cs")
    grad_def = {"hue": 0.0, "saturation": 0.0}

    geom_rec_m = _need(r"public sealed record GeometrySettings\((.*?)\)\s*\{", cs_geom, "geometry.* windows defaults", "GeometrySettings.cs", re.S).group(1)
    cs_crop_defs = {k: float(_need(rf"double {k} = (-?\d+(?:\.\d+)?)", geom_rec_m, f"geometry.{k} windows default", "GeometrySettings.cs").group(1)) for k in ("CropX", "CropY", "CropWidth", "CropHeight")}
    cs_qt_def = int(_need(r"int QuarterTurns = (\d+)", geom_rec_m, "geometry.quarter_turns windows default", "GeometrySettings.cs").group(1))
    cs_flip_h = _need(r"bool FlipHorizontal = (true|false)", geom_rec_m, "geometry.flip_horizontal windows default", "GeometrySettings.cs").group(1) == "true"
    cs_flip_v = _need(r"bool FlipVertical = (true|false)", geom_rec_m, "geometry.flip_vertical windows default", "GeometrySettings.cs").group(1) == "true"
    cs_straight_def = float(_need(r"double StraightenDegrees = (-?\d+(?:\.\d+)?)", geom_rec_m, "geometry.straighten windows default", "GeometrySettings.cs").group(1))
    cs_persp_h_def = float(_need(r"double PerspectiveHorizontal = (-?\d+(?:\.\d+)?)", geom_rec_m, "geometry.perspective.horizontal windows default", "GeometrySettings.cs").group(1))
    cs_persp_v_def = float(_need(r"double PerspectiveVertical = (-?\d+(?:\.\d+)?)", geom_rec_m, "geometry.perspective.vertical windows default", "GeometrySettings.cs").group(1))
    crop_lo = float(_need(r"CropX < (-?\d+(?:\.\d+)?) \|\| CropY < \1", cs_geom, "geometry.crop min windows", "GeometrySettings.cs").group(1))
    crop_hi = float(_need(r"CropX \+ CropWidth > (-?\d+(?:\.\d+)?) \+ 1e-12 \|\| CropY \+ CropHeight > \1 \+ 1e-12", cs_geom, "geometry.crop max windows", "GeometrySettings.cs").group(1))
    cs_crop_bounds = (crop_lo, crop_hi)
    cs_qt_bounds = tuple(int(x) for x in _need(r"QuarterTurns is < (\d+) or > (\d+)", cs_geom, "geometry.quarter_turns windows bounds", "GeometrySettings.cs").groups())
    cs_straight_bounds = tuple(float(x) for x in _need(r"StraightenDegrees is < (-?\d+(?:\.\d+)?) or > (-?\d+(?:\.\d+)?)", cs_geom, "geometry.straighten windows bounds", "GeometrySettings.cs").groups())
    cs_persp_h_bounds = tuple(float(x) for x in _need(r"PerspectiveHorizontal is < (-?\d+(?:\.\d+)?) or > (-?\d+(?:\.\d+)?)", cs_geom, "geometry.perspective.horizontal windows bounds", "GeometrySettings.cs").groups())
    cs_persp_v_bounds = tuple(float(x) for x in _need(r"PerspectiveVertical is < (-?\d+(?:\.\d+)?) or > (-?\d+(?:\.\d+)?)", cs_geom, "geometry.perspective.vertical windows bounds", "GeometrySettings.cs").groups())

    # LensSettings in Adjustments.cs
    lens_blk = _extract_brace_block(cs_adj, r"(?:public |internal )?(?:sealed )?(?:record|class|struct) LensSettings\b", "geometry.lens.* windows", "Adjustments.cs")
    lens_dist = _need(r"bool Distortion\s*=\s*(true|false)", lens_blk, "lens.distortion windows", "Adjustments.cs").group(1) == "true"
    lens_tca = _need(r"bool Tca\s*=\s*(true|false)", lens_blk, "lens.tca windows", "Adjustments.cs").group(1) == "true"
    lens_vig = _need(r"bool Vignetting\s*=\s*(true|false)", lens_blk, "lens.vignetting windows", "Adjustments.cs").group(1) == "true"
    lens_auto = _need(r"bool AutoCrop\s*=\s*(true|false)", lens_blk, "lens.auto_crop windows", "Adjustments.cs").group(1) == "true"
    _require("ProfileId = null", lens_blk, "lens.profile_id windows", "Adjustments.cs")

    # Windows HDRSettings.cs + HDRAdjustmentTransfer.cs
    def _cs_is_bounds(src: str, prop: str, field: str, where: str) -> tuple[float, float]:
        m = _need(rf"\b{re.escape(prop)}\s+is\s+>=\s*(-?\d+(?:\.\d+)?)\s+and\s+<=\s*(-?\d+(?:\.\d+)?)", src, field, where)
        return (float(m.group(1)), float(m.group(2)))

    cs_hdr_cam_blk = _need(r"internal sealed record HDRCameraDevelopmentSettings\((.*?)\)\s*\{", cs_hdr, "hdr.camera_development windows", "HDRSettings.cs", re.S).group(1)
    cs_cam_custom_wb = _need(r"bool CustomWhiteBalance = (true|false)", cs_hdr_cam_blk, "hdr.cam wb flag windows", "HDRSettings.cs").group(1) == "true"
    cs_cam_sensor_exp = _need(r"bool SensorExposure = (true|false)", cs_hdr_cam_blk, "hdr.cam exp flag windows", "HDRSettings.cs").group(1) == "true"
    cs_cam_wb_m = _need(r'white_balance_mode\s*=\s*camera\.CustomWhiteBalance\s*\?\s*"([^"]+)"\s*:\s*"([^"]+)"', cs_hdr_tr, "hdr.cam wb wire windows", "HDRAdjustmentTransfer.cs")
    cs_cam_exp_m = _need(r'exposure_reference\s*=\s*camera\.SensorExposure\s*\?\s*"([^"]+)"\s*:\s*"([^"]+)"', cs_hdr_tr, "hdr.cam exp wire windows", "HDRAdjustmentTransfer.cs")
    cs_hdr_cam_def = {
        "version": int(_need(r"CameraValue\([^\)]*\)[\s\S]*?version\s*=\s*(\d+)", cs_hdr_tr, "hdr.cam version windows", "HDRAdjustmentTransfer.cs").group(1)),
        "white_balance_mode": cs_cam_wb_m.group(1 if cs_cam_custom_wb else 2),
        "temperature": float(_need(r"double Temperature = (-?\d+(?:\.\d+)?)", cs_hdr_cam_blk, "hdr.cam temp windows", "HDRSettings.cs").group(1)),
        "tint": float(_need(r"double Tint = (-?\d+(?:\.\d+)?)", cs_hdr_cam_blk, "hdr.cam tint windows", "HDRSettings.cs").group(1)),
        "exposure_reference": cs_cam_exp_m.group(1 if cs_cam_sensor_exp else 2),
        "fbdd_level": int(_need(r"int FbddLevel = (\d+)", cs_hdr_cam_blk, "hdr.cam fbdd windows", "HDRSettings.cs").group(1)),
    }
    cs_hdr_rend_blk = _extract_brace_block(cs_hdr, r"internal sealed record HDRRenditionSettings\b", "hdr rendition windows", "HDRSettings.cs")
    cs_hdr_det_blk = _need(r"internal sealed record HDRDetailSettings\((.*?)\)\s*\{.*?\n\}", cs_hdr, "hdr detail windows", "HDRSettings.cs", re.S).group(0)
    cs_hdr_main_blk = _extract_brace_block(cs_hdr, r"public sealed record HDRSettings\b", "hdr main windows", "HDRSettings.cs")
    cs_hdr_exp = _cs_is_bounds(cs_hdr_main_blk, "Exposure", "hdr.exposure windows bounds", "HDRSettings.cs")
    cs_hdr_temp = _cs_is_bounds(cs_hdr_main_blk, "Temperature", "hdr.temp windows bounds", "HDRSettings.cs")
    cs_hdr_tint = _cs_is_bounds(cs_hdr_main_blk, "Tint", "hdr.tint windows bounds", "HDRSettings.cs")
    cs_hdr_peak = _cs_is_bounds(cs_hdr_rend_blk, "PeakLimitEV", "hdr.peak windows bounds", "HDRSettings.cs")
    cs_hdr_sdr_exp = _cs_is_bounds(cs_hdr_rend_blk, "SdrExposureEV", "hdr.sdr_exposure windows bounds", "HDRSettings.cs")
    cs_hdr_sdr_con = _cs_is_bounds(cs_hdr_rend_blk, "SdrContrast", "hdr.sdr_contrast windows bounds", "HDRSettings.cs")
    cs_hdr_sdr_sat = _cs_is_bounds(cs_hdr_rend_blk, "SdrSaturation", "hdr.sdr_saturation windows bounds", "HDRSettings.cs")
    cs_hdr_clarity = _cs_is_bounds(cs_hdr_det_blk, "Clarity", "hdr.clarity windows bounds", "HDRSettings.cs")
    cs_hdr_dehaze = _cs_is_bounds(cs_hdr_det_blk, "Dehaze", "hdr.dehaze windows bounds", "HDRSettings.cs")
    cs_hdr_sharp = _cs_is_bounds(cs_hdr_det_blk, "Sharpening", "hdr.sharpen windows bounds", "HDRSettings.cs")
    cs_hdr_denoise = _cs_is_bounds(cs_hdr_det_blk, "Denoise", "hdr.denoise windows bounds", "HDRSettings.cs")
    cs_hdr_temp_def = float(_need(r"public double Temperature \{ get; init; \} = (-?\d+(?:\.\d+)?);", cs_hdr_main_blk, "hdr.temp default windows", "HDRSettings.cs").group(1))
    _require("value / 100", cs_hdr_tr, "hdr clarity/dehaze decode scale windows", "HDRAdjustmentTransfer.cs")

    m: dict[str, dict] = {}
    m["looks.reference"] = _model_entry("object", modes=("sdr",), default={"kind": "neutral", "id": None}, quantization="discrete")
    m["looks.strength"] = _model_entry("double", modes=("sdr",), min_val=cs_specs["Strength"][0], max_val=cs_specs["Strength"][1], default=cs_defaults["Strength"], scale_from_protocol="p * 100")
    m["light.exposure"] = _model_entry("double", min_val=cs_specs["Exposure"][0], max_val=cs_specs["Exposure"][1], hdr_min=cs_hdr_exp[0], hdr_max=cs_hdr_exp[1], default=cs_defaults["Exposure"])
    m["light.exposure_mode"] = _model_entry("int", modes=("sdr",), min_val=exp_mode_bounds[0], max_val=exp_mode_bounds[1], default=exp_mode_wire, quantization="discrete")
    m["light.contrast"] = _model_entry("double", min_val=cs_specs["Contrast"][0], max_val=cs_specs["Contrast"][1], default=cs_defaults["Contrast"], scale_from_protocol="(p - 1) * 100")
    m["light.highlights"] = _model_entry("double", min_val=cs_specs["Highlights"][0], max_val=cs_specs["Highlights"][1], default=cs_defaults["Highlights"], scale_from_protocol="-p * 100")
    m["light.shadows"] = _model_entry("double", min_val=cs_specs["Shadows"][0], max_val=cs_specs["Shadows"][1], default=cs_defaults["Shadows"], scale_from_protocol="p * 100")
    m["light.s_curve"] = _model_entry("double", min_val=cs_specs["ToneCurve"][0], max_val=cs_specs["ToneCurve"][1], default=cs_defaults["ToneCurve"], scale_from_protocol="p * 100")
    m["light.curve"] = _model_entry("object", default=_curve_default("windows"))

    for fid, def_val in (("tone.black_point", tone_bp_def), ("tone.white_point", tone_wp_def), ("color.vibrance", tone_vib_def)):
        m[fid] = _model_entry("double", min_val=tone_range[0], max_val=tone_range[1], default=def_val)

    for zone in ("shadows", "midtones", "highlights"):
        m[f"color.grading.{zone}"] = _model_entry("object", default=grad_def)

    m["color.white_balance.mode"] = _model_entry("bool", modes=("sdr",), default=wb_mode_wire, quantization="discrete")
    m["color.white_balance.temperature_kelvin"] = _model_entry("double", modes=("sdr",), min_val=cs_specs["Temperature"][0], max_val=cs_specs["Temperature"][1], default=cs_defaults["Temperature"])
    m["color.white_balance.tint"] = _model_entry("double", modes=("sdr",), min_val=cs_specs["Tint"][0], max_val=cs_specs["Tint"][1], default=cs_defaults["Tint"])
    m["color.saturation"] = _model_entry("double", min_val=cs_specs["Saturation"][0], max_val=cs_specs["Saturation"][1], default=cs_defaults["Saturation"], scale_from_protocol="(p - 1) * 100")

    m["hdr.relative_temperature"] = _model_entry("double", modes=("hdr",), min_val=cs_hdr_temp[0], max_val=cs_hdr_temp[1], default=cs_hdr_temp_def)
    m["hdr.relative_tint"] = _model_entry("double", modes=("hdr",), min_val=cs_hdr_tint[0], max_val=cs_hdr_tint[1], default=0.0)
    m["hdr.peak_limit_ev"] = _model_entry("double", modes=("hdr",), min_val=cs_hdr_peak[0], max_val=cs_hdr_peak[1], default=0.0)
    m["hdr.sdr_exposure_ev"] = _model_entry("double", modes=("hdr",), min_val=cs_hdr_sdr_exp[0], max_val=cs_hdr_sdr_exp[1], default=0.0)
    m["hdr.sdr_contrast"] = _model_entry("double", modes=("hdr",), min_val=cs_hdr_sdr_con[0], max_val=cs_hdr_sdr_con[1], default=0.0)
    m["hdr.sdr_saturation"] = _model_entry("double", modes=("hdr",), min_val=cs_hdr_sdr_sat[0], max_val=cs_hdr_sdr_sat[1], default=0.0)
    m["hdr.look"] = _model_entry("object", modes=("hdr",), nullable=True, default=_look_default("windows"))
    m["hdr.camera_development"] = _model_entry("object", modes=("hdr",), default=cs_hdr_cam_def)

    for axis in HSL_AXES:
        for ch in HSL_CHANNELS:
            m[f"color.hsl.{axis}.{ch}"] = _model_entry("double", min_val=hsl_range[0], max_val=hsl_range[1], default=0.0)

    fx_map = (
        ("effects.vignette.amount", "VignetteAmount"),
        ("effects.vignette.midpoint", "VignetteMidpoint"),
        ("effects.vignette.roundness", "VignetteRoundness"),
        ("effects.vignette.feather", "VignetteFeather"),
        ("effects.vignette.highlights", "VignetteHighlights"),
        ("effects.grain.amount", "GrainAmount"),
        ("effects.grain.size", "GrainSize"),
        ("effects.grain.roughness", "GrainRoughness"),
    )
    for fid, cs_name in fx_map:
        lo, hi, dflt = _need_key(cs_fx_defs, cs_name, fid, "PhotoEffectsSettings.cs")
        m[fid] = _model_entry("double", min_val=lo, max_val=hi, default=dflt, quantization="round_1")

    m["effects.clarity"] = _model_entry("double", min_val=atmos_range[0], max_val=atmos_range[1], hdr_min=cs_hdr_clarity[0], hdr_max=cs_hdr_clarity[1], default=atmos_cl_def, hdr_default=0.0, scale_from_protocol="p", hdr_scale_from_protocol="p / 100")
    m["effects.dehaze"] = _model_entry("double", min_val=atmos_range[0], max_val=atmos_range[1], hdr_min=cs_hdr_dehaze[0], hdr_max=cs_hdr_dehaze[1], default=atmos_dh_def, hdr_default=0.0, scale_from_protocol="p", hdr_scale_from_protocol="p / 100")

    m["detail.sharpening"] = _model_entry("double", min_val=cs_specs["Sharpening"][0], max_val=cs_specs["Sharpening"][1], hdr_min=cs_hdr_sharp[0], hdr_max=cs_hdr_sharp[1], default=cs_defaults["Sharpening"], hdr_default=0.0, scale_from_protocol="p * 100", hdr_scale_from_protocol="p")
    m["detail.denoise.raw_level"] = _model_entry("none", supported=False, modes=(), scale_from_protocol="none", quantization="none")
    m["detail.denoise.post_rgb"] = _model_entry("double", modes=("hdr",), min_val=cs_hdr_denoise[0], max_val=cs_hdr_denoise[1], default=0.0)
    m["detail.denoise.chroma_mode"] = _model_entry("int", modes=("sdr",), min_val=chroma_bounds[0], max_val=chroma_bounds[1], default=chroma_def, quantization="discrete")
    m["detail.denoise.wavelet"] = _model_entry("object", modes=("sdr",), default=cs_wavelet_default)

    for key, fid in (("CropX", "geometry.crop.x"), ("CropY", "geometry.crop.y"), ("CropWidth", "geometry.crop.width"), ("CropHeight", "geometry.crop.height")):
        m[fid] = _model_entry("double", min_val=cs_crop_bounds[0], max_val=cs_crop_bounds[1], default=cs_crop_defs[key])
    m["geometry.quarter_turns"] = _model_entry("int", min_val=cs_qt_bounds[0], max_val=cs_qt_bounds[1], default=cs_qt_def, quantization="discrete")
    m["geometry.flip_horizontal"] = _model_entry("bool", default=cs_flip_h, quantization="discrete")
    m["geometry.flip_vertical"] = _model_entry("bool", default=cs_flip_v, quantization="discrete")
    m["geometry.straighten_degrees"] = _model_entry("double", min_val=cs_straight_bounds[0], max_val=cs_straight_bounds[1], default=cs_straight_def)
    m["geometry.perspective.horizontal"] = _model_entry("double", min_val=cs_persp_h_bounds[0], max_val=cs_persp_h_bounds[1], default=cs_persp_h_def)
    m["geometry.perspective.vertical"] = _model_entry("double", min_val=cs_persp_v_bounds[0], max_val=cs_persp_v_bounds[1], default=cs_persp_v_def)

    for fid, dflt in (
        ("geometry.lens.distortion", lens_dist),
        ("geometry.lens.tca", lens_tca),
        ("geometry.lens.vignetting", lens_vig),
        ("geometry.lens.auto_crop", lens_auto),
    ):
        m[fid] = _model_entry("bool", modes=("sdr", "hdr"), default=dflt, quantization="discrete")
    m["geometry.lens.profile_id"] = _model_entry("string", modes=("sdr",), nullable=True, default=None, quantization="discrete")

    m["local.ai_denoise_enabled"] = _model_entry("bool", supported=True, modes=("sdr",), default=False, scale_from_protocol="none", quantization="discrete")
    m["local.hdr_camera_ai_enabled"] = _model_entry("bool", supported=True, modes=("hdr",), default=False, scale_from_protocol="none", quantization="discrete")
    return m


def parse_models_from_sources() -> dict[str, dict[str, dict]]:
    """Parse model defaults, bounds, nullability, and transfer scales independently per end."""
    shared = _parse_apple_shared_models()
    per_platform = {
        "macos": _parse_mac_model(shared),
        "ios": _parse_ios_model(shared),
        "android": _parse_android_model(),
        "windows": _parse_windows_model(),
    }
    all_fields = set(per_platform["macos"])
    for plat in PLATFORMS[1:]:
        assert set(per_platform[plat]) == all_fields, f"Model field mismatch on {plat}: {set(per_platform[plat]) ^ all_fields}"
    return {fid: {plat: per_platform[plat][fid] for plat in PLATFORMS} for fid in all_fields}


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


def _parse_mac_ui(mac_fine: dict[str, float]) -> dict[str, dict]:
    """Parse macOS UI metadata solely from RawLabMac/ and Shared/."""
    mac_types = _strip_line_comments(_read("RawLabMac/Sources/Adjustments/AdjustmentTypes.swift"))
    mac_adj = _strip_line_comments(_read("RawLabMac/Sources/Adjustments/Adjustments.swift"))
    mac_tv = _strip_line_comments(_read("RawLabMac/Sources/Adjustments/MacAdjustmentTransferValues.swift"))
    mac_dock = _strip_line_comments(_read("RawLabMac/Sources/Editor/View/AdjustmentDock.swift"))
    mac_hsl_prec = _strip_line_comments(_read("RawLabMac/Sources/Controls/MacHSLPrecision.swift"))
    mac_hsl_ctrl = _strip_line_comments(_read("RawLabMac/Sources/Controls/MacHSLMixer.swift"))
    mac_grad_ctrl = _strip_line_comments(_read("RawLabMac/Sources/Controls/MacColorGradingControls.swift"))
    mac_dn = _strip_line_comments(_read("RawLabMac/Sources/Controls/DenoiseControls.swift"))
    mac_fx_ctrl = _strip_line_comments(_read("RawLabMac/Sources/Controls/PhotoEffectsControls.swift"))
    mac_adj_row = _strip_line_comments(_read("RawLabMac/Sources/Editor/View/AdjustmentRow.swift"))
    mac_geom_ctrl = _strip_line_comments(_read("RawLabMac/Sources/Geometry/GeometryControls.swift"))
    mac_lens = _strip_line_comments(_read("RawLabMac/Sources/Lens/LensControls.swift"))
    hdr_mon = _strip_line_comments(_read("Shared/Native/HDRMonitoring.swift"))
    hdr_swift = _strip_line_comments(_read("Shared/HDRSettings.swift"))
    tone_swift = _strip_line_comments(_read("Shared/ToneControlsSettings.swift"))
    atmos_swift = _strip_line_comments(_read("Shared/AtmosphereSettings.swift"))
    hsl_swift = _strip_line_comments(_read("Shared/HSLSettings.swift"))
    geom_swift = _strip_line_comments(_read("Shared/GeometrySettings.swift"))

    mac_hsl_step = round(1.0 / float(_need(r"\*\s*(\d+)\)\.rounded\(\)\s*/\s*\1", mac_hsl_prec, "color.hsl mac step", "MacHSLPrecision.swift").group(1)), 6)
    mac_crop_min_pct = round(float(_need(r"case \.cropWidth:\s*return min\((0\.\d+),", mac_types, "geometry.crop min mac", "AdjustmentTypes.swift").group(1)) * 100.0, 6)
    mac_persp_unit = _need(r'case \.perspectiveHorizontal,\s*\.perspectiveVertical:\s*return "([^"]*)"', mac_types, "geometry.perspective mac unit", "AdjustmentTypes.swift").group(1)
    mac_lens_options = _need(r"private var correctionOptions.*?\}", mac_lens, "geometry.lens.vignetting mac sdr scope", "LensControls.swift", re.S).group(0)
    _require_absent("vignetting", mac_lens_options, "geometry.lens.vignetting mac sdr", "LensControls.swift")
    _require('accessibilityIdentifier("chromaNoiseReduction.mode")', mac_dn, "detail.denoise.chroma_mode mac picker", "DenoiseControls.swift")
    _require("precision: isEV ? .exposure : .standard", mac_dock, "hdr UI precision steps", "AdjustmentDock.swift")

    hdr_mon_peak_step = float(_need(r'slider\("HDR 亮度上限".*?step:\s*(\d+(?:\.\d+)?)', hdr_mon, "hdr.peak sec step", "Shared/Native/HDRMonitoring.swift").group(1))
    hdr_mon_sdr_exp_step = float(_need(r'slider\("SDR 底图曝光".*?step:\s*(\d+(?:\.\d+)?)', hdr_mon, "hdr.sdr_exp sec step", "Shared/Native/HDRMonitoring.swift").group(1))
    hdr_mon_sdr_con_step = float(_need(r'slider\("SDR 底图对比度".*?step:\s*(\d+(?:\.\d+)?)', hdr_mon, "hdr.sdr_con sec step", "Shared/Native/HDRMonitoring.swift").group(1))
    hdr_mon_sdr_sat_step = float(_need(r'slider\("SDR 底图饱和度".*?step:\s*(\d+(?:\.\d+)?)', hdr_mon, "hdr.sdr_sat sec step", "Shared/Native/HDRMonitoring.swift").group(1))
    hdr_mon_look_m = _need(r"Slider\(value:\s*\$settings\.lookSettings\.strength,\s*in:\s*(\d+)\.\.\.(\d+),\s*step:\s*(\d+(?:\.\d+)?)", hdr_mon, "hdr.look mac ui", "Shared/Native/HDRMonitoring.swift")
    hdr_look_lo = float(hdr_mon_look_m.group(1)) * 100.0
    hdr_look_hi = float(hdr_mon_look_m.group(2)) * 100.0
    hdr_mon_look_step = round(float(hdr_mon_look_m.group(3)) * 100.0, 6)
    hdr_mon_cam_temp_step = float(_need(r'cameraSlider\("色温".*?step:\s*(\d+(?:\.\d+)?)', hdr_mon, "hdr.cam temp step", "Shared/Native/HDRMonitoring.swift").group(1))
    hdr_mon_cam_tint_step = float(_need(r'cameraSlider\("色调".*?step:\s*(\d+(?:\.\d+)?)', hdr_mon, "hdr.cam tint step", "Shared/Native/HDRMonitoring.swift").group(1))

    mac_specs: dict[str, tuple[float, float, float, str]] = {}
    for m in re.finditer(
        r'case \.(\w+):\s*return AdjustmentSpec\(.*?range:\s*(-?\d+(?:\.\d+)?)\.\.\.(-?\d+(?:\.\d+)?),\s*defaultValue:\s*(-?\d+(?:\.\d+)?)(?:,\s*unit:\s*"([^"]*)")?',
        mac_types,
    ):
        mac_specs[m.group(1)] = (float(m.group(2)), float(m.group(3)), float(m.group(4)), m.group(5) or "")

    hdr_exp_range = tuple(float(x) for x in _need(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(exposure\)", hdr_swift, "hdr.exposure bounds", "Shared/HDRSettings.swift").groups())
    hdr_peak_range = tuple(float(x) for x in _need(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(peakLimitEV\)", hdr_swift, "hdr.peak bounds", "Shared/HDRSettings.swift").groups())
    hdr_sdr_exp_range = tuple(float(x) for x in _need(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(sdrExposureEV\)", hdr_swift, "hdr.sdr_exp bounds", "Shared/HDRSettings.swift").groups())
    hdr_sdr_con_range = tuple(float(x) for x in _need(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(sdrContrast\)", hdr_swift, "hdr.sdr_con bounds", "Shared/HDRSettings.swift").groups())
    hdr_sdr_sat_range = tuple(float(x) for x in _need(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(sdrSaturation\)", hdr_swift, "hdr.sdr_sat bounds", "Shared/HDRSettings.swift").groups())
    hdr_temp_range = tuple(float(x) for x in _need(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(temperature\)", hdr_swift, "hdr.temp bounds", "Shared/HDRSettings.swift").groups())
    hdr_tint_range = tuple(float(x) for x in _need(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(tint\)", hdr_swift, "hdr.tint bounds", "Shared/HDRSettings.swift").groups())
    hdr_denoise_range = tuple(float(x) for x in _need(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(denoise\)", hdr_swift, "hdr.denoise bounds", "Shared/HDRSettings.swift").groups())

    _require('PhotoEditState(settings: defaults, filmID: "")', _strip_line_comments(_read("RawLabMac/Sources/Adjustments/MacAdjustmentTransfer.swift")), "looks.reference mac", "MacAdjustmentTransfer.swift")
    _require('look = ["kind": .string("neutral"), "id": .null]', mac_tv, "looks.reference mac wire", "MacAdjustmentTransferValues.swift")
    exp_mode_def = _need(r"var exposureMode(?:\s*:\s*ExposureMode)?\s*=\s*(?:ExposureMode)?\.(\w+)", mac_adj, "light.exposure_mode mac", "Adjustments.swift").group(1)
    wb_mode_var = _need(r"var whiteBalanceMode(?:\s*:\s*WhiteBalanceMode)?\s*=\s*(?:WhiteBalanceMode)?\.(\w+)", mac_adj, "wb.mode mac", "Adjustments.swift").group(1)
    _need(rf"whiteBalanceMode\s*==\s*\.{re.escape(wb_mode_var)}", mac_adj, "wb.mode usesAsShot mac", "Adjustments.swift")
    wb_mode_wire = _need(r'let camera = !isRaw \|\| settings\.usesAsShotWhiteBalance.*?camera \? "([^"]+)"', mac_tv, "wb.mode mac wire", "MacAdjustmentTransferValues.swift", re.S).group(1)

    tone_range = tuple(float(x) for x in _need(r"(-?\d+)\.\.\.(-?\d+)", tone_swift, "tone range mac ui", "Shared/ToneControlsSettings.swift").groups())
    atmos_range = tuple(float(x) for x in _need(r"(-?\d+)\.\.\.(-?\d+)", atmos_swift, "atmos range mac ui", "Shared/AtmosphereSettings.swift").groups())
    hsl_range = tuple(float(x) for x in _need(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(\$0\)", hsl_swift, "hsl range mac ui", "Shared/HSLSettings.swift").groups())
    _ = mac_hsl_ctrl
    _require("0...360", mac_grad_ctrl, "color.grading mac hue range", "MacColorGradingControls.swift")

    mac_fx_blk = _extract_brace_block(mac_types, r"struct PhotoEffectsSettings\b", "effects mac defaults", "AdjustmentTypes.swift")
    mac_fx_range_blk = _extract_brace_block(mac_types, r"enum PhotoEffectParameter\b", "effects mac ranges", "AdjustmentTypes.swift")
    signed_m = _need(r"self == \.vignetteAmount \|\| self == \.vignetteRoundness \? (-?\d+)\.\.\.(-?\d+) : (-?\d+)\.\.\.(-?\d+)", mac_fx_range_blk, "effects mac range", "AdjustmentTypes.swift")
    signed_range = (float(signed_m.group(1)), float(signed_m.group(2)))
    unsigned_range = (float(signed_m.group(3)), float(signed_m.group(4)))
    _require("ParameterRow(", mac_fx_ctrl, "effects mac ParameterRow", "PhotoEffectsControls.swift")
    mac_row_blk = _extract_brace_block(mac_adj_row, r"struct ParameterRow\b", "ParameterRow", "AdjustmentRow.swift")
    fx_precision = _need(r"var precision\s*=\s*ParameterPrecision\.(\w+)", mac_row_blk, "effects mac step default", "AdjustmentRow.swift").group(1)

    mac_dn_blk = _extract_brace_block(mac_types, r"struct WaveletDenoiseSettings\b", "wavelet mac defaults", "AdjustmentTypes.swift")
    mac_wavelet_def = {
        "enabled": _need(r"var enabled(?:\s*:\s*Bool)?\s*=\s*(true|false)", mac_dn_blk, "wavelet enabled mac", "AdjustmentTypes.swift").group(1) == "true",
        "luma": float(_need(r"var luma(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", mac_dn_blk, "wavelet luma mac", "AdjustmentTypes.swift").group(1)),
        "chroma": float(_need(r"var chroma(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", mac_dn_blk, "wavelet chroma mac", "AdjustmentTypes.swift").group(1)),
        "coarse": float(_need(r"var coarse(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", mac_dn_blk, "wavelet coarse mac", "AdjustmentTypes.swift").group(1)),
        "preset": _need(r"var preset(?:\s*:\s*DenoisePreset)?\s*=\s*(?:DenoisePreset)?\.(\w+)", mac_dn_blk, "wavelet preset mac", "AdjustmentTypes.swift").group(1),
    }
    dn_ui_range = tuple(float(x) for x in _need(r"range:\s*(-?\d+)\.\.\.(-?\d+)", mac_dn, "wavelet mac ui range", "DenoiseControls.swift").groups())

    chroma_blk = _extract_brace_block(mac_types, r"enum ChromaNoiseReductionMode\b", "chroma mac enum", "AdjustmentTypes.swift")
    chroma_ui_vals = [float(x) for x in re.findall(r"\b\w+\s*=\s*(-?\d+(?:\.\d+)?)", chroma_blk.split("var ")[0])]
    chroma_ui_lo, chroma_ui_hi = min(chroma_ui_vals), max(chroma_ui_vals)
    chroma_ui_def = float(_need(r"case \.denoiseMode: return AdjustmentSpec\(.*?defaultValue:\s*(-?\d+(?:\.\d+)?)", mac_types, "chroma mac ui default", "AdjustmentTypes.swift").group(1))

    qt_range = tuple(int(x) for x in _need(r"\((\d+)\.\.\.(\d+)\)\.contains\(quarterTurns\)", geom_swift, "qt range mac ui", "Shared/GeometrySettings.swift").groups())
    qt_def = int(_need(r"var quarterTurns:\s*Int\s*=\s*(\d+)", geom_swift, "qt def mac ui", "Shared/GeometrySettings.swift").group(1))
    flip_h_def = _need(r"var flipHorizontal:\s*Bool\s*=\s*(true|false)", geom_swift, "flipH def mac ui", "Shared/GeometrySettings.swift").group(1) == "true"
    flip_v_def = _need(r"var flipVertical:\s*Bool\s*=\s*(true|false)", geom_swift, "flipV def mac ui", "Shared/GeometrySettings.swift").group(1) == "true"
    straight_range = tuple(float(x) for x in _need(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(straightenDegrees\)", geom_swift, "straighten range mac ui", "Shared/GeometrySettings.swift").groups())
    mac_geom_enum_blk = _extract_brace_block(mac_types, r"enum GeometryParameter\b", "GeometryParameter mac ui", "AdjustmentTypes.swift")
    persp_mult = float(_need(r"var multiplier:\s*Double\s*\{\s*self == \.straightenDegrees \? (\d+) : (\d+)\s*\}", mac_geom_enum_blk, "geometry persp multiplier mac", "AdjustmentTypes.swift").group(2))
    persp_h_range = tuple(float(x) * persp_mult for x in _need(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(perspectiveHorizontal\)", geom_swift, "persp h mac ui", "Shared/GeometrySettings.swift").groups())
    persp_v_range = tuple(float(x) * persp_mult for x in _need(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(perspectiveVertical\)", geom_swift, "persp v mac ui", "Shared/GeometrySettings.swift").groups())
    _require("GeometryParameter", mac_geom_ctrl, "geometry controls mac", "GeometryControls.swift")
    mac_lens_blk = _extract_brace_block(mac_types, r"struct LensCorrectionSettings\b", "geometry.lens mac ui", "AdjustmentTypes.swift")
    mac_lens_dist = _need(r"var distortion(?:\s*:\s*Bool)?\s*=\s*(true|false)", mac_lens_blk, "lens.distortion mac ui", "AdjustmentTypes.swift").group(1) == "true"
    mac_lens_tca = _need(r"var tca(?:\s*:\s*Bool)?\s*=\s*(true|false)", mac_lens_blk, "lens.tca mac ui", "AdjustmentTypes.swift").group(1) == "true"
    mac_lens_vig = _need(r"var vignetting(?:\s*:\s*Bool)?\s*=\s*(true|false)", mac_lens_blk, "lens.vignetting mac ui", "AdjustmentTypes.swift").group(1) == "true"
    mac_lens_auto = _need(r"var autoCrop(?:\s*:\s*Bool)?\s*=\s*(true|false)", mac_lens_blk, "lens.auto_crop mac ui", "AdjustmentTypes.swift").group(1) == "true"

    ui: dict[str, dict] = {}
    ui["looks.reference"] = _ui_entry(modes=("sdr",), default={"kind": "neutral", "id": None})
    ui["looks.strength"] = _ui_entry(modes=("sdr",), unit="%", min_val=mac_specs["strength"][0] * 100.0, max_val=mac_specs["strength"][1] * 100.0, default=mac_specs["strength"][2] * 100.0, step=mac_fine["standard"])
    ui["light.exposure"] = _ui_entry(unit="EV", min_val=mac_specs["exposure"][0], max_val=mac_specs["exposure"][1], hdr_min=hdr_exp_range[0], hdr_max=hdr_exp_range[1], default=mac_specs["exposure"][2], step=mac_fine["exposure"])
    ui["light.exposure_mode"] = _ui_entry(modes=("sdr",), default=exp_mode_def)

    for fid, k in (("light.contrast", "contrast"), ("light.highlights", "highlights"), ("light.shadows", "shadows"), ("light.s_curve", "toneCurve"), ("color.saturation", "saturation")):
        ui[fid] = _ui_entry(unit="%", min_val=mac_specs[k][0], max_val=mac_specs[k][1], default=mac_specs[k][2], step=mac_fine["standard"])
    ui["light.curve"] = _ui_curve_entry("macos", mac_fine)

    for fid in ("tone.black_point", "tone.white_point", "color.vibrance"):
        ui[fid] = _ui_entry(unit="%", min_val=tone_range[0], max_val=tone_range[1], default=0.0, step=mac_fine["standard"])
    for zone in ("shadows", "midtones", "highlights"):
        ui[f"color.grading.{zone}"] = _ui_entry(default={"hue": 0.0, "saturation": 0.0}, step={"hue": mac_fine["standard"], "saturation": mac_fine["standard"]})

    ui["color.white_balance.mode"] = _ui_entry(modes=("sdr",), default=wb_mode_wire)
    ui["color.white_balance.temperature_kelvin"] = _ui_entry(modes=("sdr",), unit="K", min_val=mac_specs["temperature"][0], max_val=mac_specs["temperature"][1], default=mac_specs["temperature"][2], step=mac_fine["temperature"])
    ui["color.white_balance.tint"] = _ui_entry(modes=("sdr",), unit="", min_val=mac_specs["tint"][0], max_val=mac_specs["tint"][1], default=mac_specs["tint"][2], step=mac_fine["standard"])

    ui["hdr.relative_temperature"] = _ui_entry(modes=("hdr",), unit="K", min_val=hdr_temp_range[0], max_val=hdr_temp_range[1], default=6500.0, step=mac_fine["temperature"])
    ui["hdr.relative_tint"] = _ui_entry(modes=("hdr",), unit="", min_val=hdr_tint_range[0], max_val=hdr_tint_range[1], default=0.0, step=mac_fine["standard"])
    ui["hdr.peak_limit_ev"] = _ui_entry(modes=("hdr",), unit="EV", min_val=hdr_peak_range[0], max_val=hdr_peak_range[1], default=0.0, step=mac_fine["exposure"], secondary_inspector_step=hdr_mon_peak_step)
    ui["hdr.sdr_exposure_ev"] = _ui_entry(modes=("hdr",), unit="EV", min_val=hdr_sdr_exp_range[0], max_val=hdr_sdr_exp_range[1], default=0.0, step=mac_fine["exposure"], secondary_inspector_step=hdr_mon_sdr_exp_step)
    ui["hdr.sdr_contrast"] = _ui_entry(modes=("hdr",), unit="%", min_val=hdr_sdr_con_range[0], max_val=hdr_sdr_con_range[1], default=0.0, step=mac_fine["standard"], secondary_inspector_step=hdr_mon_sdr_con_step)
    ui["hdr.sdr_saturation"] = _ui_entry(modes=("hdr",), unit="%", min_val=hdr_sdr_sat_range[0], max_val=hdr_sdr_sat_range[1], default=0.0, step=mac_fine["standard"], secondary_inspector_step=hdr_mon_sdr_sat_step)
    ui["hdr.look"] = _ui_entry(modes=("hdr",), unit="%", min_val=hdr_look_lo, max_val=hdr_look_hi, default=100.0, step={"strength": hdr_mon_look_step})
    hdr_cam_blk = _extract_brace_block(hdr_swift, r"(?:public\s+)?struct HDRCameraDevelopmentSettings\b", "hdr cam mac ui", "Shared/HDRSettings.swift")
    ui["hdr.camera_development"] = _ui_entry(
        modes=("hdr",),
        default={
            "version": int(_need(r"var version(?:\s*:\s*Int)?\s*=\s*(\d+)", hdr_cam_blk, "hdr cam ver", "Shared/HDRSettings.swift").group(1)),
            "white_balance_mode": _need(r'case asShot\s*=\s*"([^"]+)"', hdr_cam_blk, "hdr cam wb", "Shared/HDRSettings.swift").group(1),
            "temperature": float(_need(r"var temperature(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", hdr_cam_blk, "hdr cam temp", "Shared/HDRSettings.swift").group(1)),
            "tint": float(_need(r"var tint(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", hdr_cam_blk, "hdr cam tint", "Shared/HDRSettings.swift").group(1)),
            "exposure_reference": _need(r"enum ExposureReference[^{]*\{\s*case (\w+)", hdr_cam_blk, "hdr cam ref", "Shared/HDRSettings.swift").group(1),
            "fbdd_level": int(_need(r"var fbddLevel(?:\s*:\s*Int)?\s*=\s*(\d+)", hdr_cam_blk, "hdr cam fbdd", "Shared/HDRSettings.swift").group(1)),
        },
        step={"temperature": hdr_mon_cam_temp_step, "tint": hdr_mon_cam_tint_step},
    )

    for axis in HSL_AXES:
        for ch in HSL_CHANNELS:
            ui[f"color.hsl.{axis}.{ch}"] = _ui_entry(unit="", min_val=hsl_range[0], max_val=hsl_range[1], default=0.0, step=mac_hsl_step)

    for fid, prop, is_signed in (
        ("effects.vignette.amount", "vignetteAmount", True),
        ("effects.vignette.midpoint", "vignetteMidpoint", False),
        ("effects.vignette.roundness", "vignetteRoundness", True),
        ("effects.vignette.feather", "vignetteFeather", False),
        ("effects.vignette.highlights", "vignetteHighlights", False),
        ("effects.grain.amount", "grainAmount", False),
        ("effects.grain.size", "grainSize", False),
        ("effects.grain.roughness", "grainRoughness", False),
    ):
        dflt = float(_need(rf"var {prop}(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", mac_fx_blk, f"{fid} mac ui default", "AdjustmentTypes.swift").group(1))
        lo, hi = signed_range if is_signed else unsigned_range
        ui[fid] = _ui_entry(unit="", min_val=lo, max_val=hi, default=dflt, step=mac_fine[fx_precision])

    ui["effects.clarity"] = _ui_entry(unit="%", min_val=atmos_range[0], max_val=atmos_range[1], default=0.0, step=mac_fine["standard"])
    ui["effects.dehaze"] = _ui_entry(unit="%", min_val=atmos_range[0], max_val=atmos_range[1], default=0.0, step=mac_fine["standard"])

    ui["detail.sharpening"] = _ui_entry(unit="%", min_val=mac_specs["sharpening"][0], max_val=mac_specs["sharpening"][1], default=mac_specs["sharpening"][2], step=mac_fine["standard"])
    ui["detail.denoise.raw_level"] = _ui_entry(modes=("sdr",), unit="", min_val=mac_specs["rawNoiseReduction"][0], max_val=mac_specs["rawNoiseReduction"][1], default=mac_specs["rawNoiseReduction"][2], step=1.0)
    ui["detail.denoise.post_rgb"] = _ui_entry(modes=("hdr",), unit="%", min_val=hdr_denoise_range[0] * 100.0, max_val=hdr_denoise_range[1] * 100.0, default=0.0, step=mac_fine["standard"])
    ui["detail.denoise.chroma_mode"] = _ui_entry(exposed=True, modes=("sdr",), min_val=chroma_ui_lo, max_val=chroma_ui_hi, default=chroma_ui_def, step=1.0)
    ui["detail.denoise.wavelet"] = _ui_entry(modes=("sdr",), unit="", min_val=dn_ui_range[0], max_val=dn_ui_range[1], default=mac_wavelet_def, step={"luma": mac_fine["standard"], "chroma": mac_fine["standard"], "coarse": mac_fine["standard"]})

    for fid in ("geometry.crop.x", "geometry.crop.y"):
        ui[fid] = _ui_entry(unit="%", min_val=0.0, max_val=100.0, default=0.0, step=mac_fine["cropPercent"])
    for fid in ("geometry.crop.width", "geometry.crop.height"):
        ui[fid] = _ui_entry(unit="%", min_val=mac_crop_min_pct, max_val=100.0, default=100.0, step=mac_fine["cropPercent"])
    ui["geometry.quarter_turns"] = _ui_entry(min_val=qt_range[0], max_val=qt_range[1], default=qt_def, step=1)
    ui["geometry.flip_horizontal"] = _ui_entry(default=flip_h_def)
    ui["geometry.flip_vertical"] = _ui_entry(default=flip_v_def)
    ui["geometry.straighten_degrees"] = _ui_entry(unit="°", min_val=straight_range[0], max_val=straight_range[1], default=0.0, step=mac_fine["standard"])
    ui["geometry.perspective.horizontal"] = _ui_entry(unit=mac_persp_unit, min_val=persp_h_range[0], max_val=persp_h_range[1], default=0.0, step=mac_fine["standard"])
    ui["geometry.perspective.vertical"] = _ui_entry(unit=mac_persp_unit, min_val=persp_v_range[0], max_val=persp_v_range[1], default=0.0, step=mac_fine["standard"])
    for fid, dflt in (("geometry.lens.distortion", mac_lens_dist), ("geometry.lens.tca", mac_lens_tca), ("geometry.lens.auto_crop", mac_lens_auto)):
        ui[fid] = _ui_entry(modes=("sdr", "hdr"), default=dflt)
    ui["geometry.lens.vignetting"] = _ui_entry(exposed=True, modes=("hdr",), default=mac_lens_vig)
    ui["geometry.lens.profile_id"] = _ui_entry(modes=("sdr",), default=None)
    ui["local.ai_denoise_enabled"] = _ui_entry(modes=("sdr",), default=False)
    ui["local.hdr_camera_ai_enabled"] = _ui_entry(modes=("hdr",), default=False)
    return ui


def _parse_ios_ui() -> dict[str, dict]:
    """Parse iOS UI metadata directly from RawLab/ and Shared/ (NO cross-end borrowing)."""
    ios_kind = _strip_line_comments(_read("RawLab/RawLab/Core/Models/AdjustmentKind.swift"))
    ios_raw = _strip_line_comments(_read("RawLab/RawLab/Core/Models/RawSettings.swift"))
    ios_tv = _strip_line_comments(_read("RawLab/RawLab/Core/Models/IOSAdjustmentTransferValues.swift"))
    ios_panels = _strip_line_comments(_read("RawLab/RawLab/UI/Panels/AdjustmentPanels.swift"))
    ios_curve = _strip_line_comments(_read("RawLab/RawLab/UI/Panels/ToneCurveControls.swift"))
    ios_grad = _strip_line_comments(_read("RawLab/RawLab/UI/Panels/ColorGradingControls.swift"))
    ios_fx = _strip_line_comments(_read("RawLab/RawLab/UI/Panels/PhotoEffectPanels.swift"))
    ios_geom = _strip_line_comments(_read("RawLab/RawLab/UI/Controls/GeometryControls.swift"))
    ios_lens = _strip_line_comments(_read("RawLab/RawLab/UI/Controls/LensControls.swift"))
    hdr_mon = _strip_line_comments(_read("Shared/Native/HDRMonitoring.swift"))
    hdr_swift = _strip_line_comments(_read("Shared/HDRSettings.swift"))
    geom_swift = _strip_line_comments(_read("Shared/GeometrySettings.swift"))

    fx_blk = _extract_brace_block(ios_raw, r"struct PhotoEffectsSettings\b", "effects ios ui", "RawSettings.swift")
    fx_init_blk = _need(r"init\((.*?)\)", fx_blk, "effects ios init", "RawSettings.swift", re.S).group(1)

    range_block = _extract_brace_block(ios_kind, r"var range:\s*ClosedRange<Double>", "AdjustmentKind.range", "AdjustmentKind.swift")
    ios_ranges: dict[str, tuple[float, float]] = {}
    for cases_str, ref_body in re.findall(r"case ([^:]+):\s*\n?\s*return ([^\n]+)", range_block):
        ref_body = ref_body.strip()
        if ref_body.startswith("RawSettings."):
            prop = ref_body.split(".", 1)[1]
            r = tuple(float(x) for x in _need(rf"{re.escape(prop)}:\s*ClosedRange<Double>\s*=\s*(-?\d+)\.\.\.(-?\d+)", ios_raw, f"{prop} ios", "RawSettings.swift").groups())
        elif ref_body.startswith("PhotoEffectsSettings."):
            prop = ref_body.split(".", 1)[1]
            r = tuple(float(x) for x in _need(rf"{re.escape(prop)}:\s*ClosedRange<Double>\s*=\s*(-?\d+)\.\.\.(-?\d+)", fx_blk, f"{prop} ios", "RawSettings.swift").groups())
        else:
            m_r = _need(r"(-?\d+(?:\.\d+)?)\.\.\.(-?\d+(?:\.\d+)?)", ref_body, f"range {cases_str}", "AdjustmentKind.swift")
            r = (float(m_r.group(1)), float(m_r.group(2)))
        for c in cases_str.split(","):
            ios_ranges[c.strip().lstrip(".")] = r

    step_block = _extract_brace_block(ios_kind, r"var step:\s*Double", "AdjustmentKind.step", "AdjustmentKind.swift")
    ios_steps: dict[str, float] = {}
    for cases_str, val in re.findall(r"case ([^:]+):\s*\n?\s*return (\d+(?:\.\d+)?)", step_block):
        for c in cases_str.split(","):
            ios_steps[c.strip().lstrip(".")] = float(val)

    unit_block = _extract_brace_block(ios_kind, r"var unit:\s*String", "AdjustmentKind.unit", "AdjustmentKind.swift")
    ios_units: dict[str, str] = {}
    for cases_str, u in re.findall(r'case ([^:]+):\s*\n?\s*return "([^"]*)"', unit_block):
        for c in cases_str.split(","):
            ios_units[c.strip().lstrip(".")] = u
    if "default:" in unit_block:
        def_u = _need(r'default:\s*\n?\s*return "([^"]*)"', unit_block, "AdjustmentKind.unit default", "AdjustmentKind.swift").group(1)
        for k in ios_steps:
            ios_units.setdefault(k, def_u)

    _require("selectedAdjustment == .noiseReduction && !workingSettings.isHDREditing", ios_panels, "detail.denoise.post_rgb ios sdr", "AdjustmentPanels.swift")
    exp_hdr_m = _need(r"workingSettings\.isHDREditing && adjustment == \.exposure \? (-?\d+)\.\.\.(-?\d+) : adjustment\.range", ios_panels, "hdr.exposure ios ui range", "AdjustmentPanels.swift")
    ios_exp_hdr_range = (float(exp_hdr_m.group(1)), float(exp_hdr_m.group(2)))
    scale_m = _need(r"displayScale:\s*adjustment == \.strength \|\| hdrDenoise \? (\d+(?:\.\d+)?) : (\d+(?:\.\d+)?)", ios_panels, "ios displayScale", "AdjustmentPanels.swift")
    strength_scale = float(scale_m.group(1))
    ios_hdr_denoise_unit = _need(r'unit:\s*hdrDenoise \? "([^"]*)" : adjustment\.unit', ios_panels, "ios hdrDenoise unit", "AdjustmentPanels.swift").group(1)
    wb_temp_m = _need(r'RawSettings\.temperatureRange,\s*step:\s*(\d+(?:\.\d+)?)', ios_panels, "wb temp step ios", "AdjustmentPanels.swift")
    wb_temp_step = float(wb_temp_m.group(1))

    ios_scurve_ui_step = float(_need(r'AdjustmentControl\(title:\s*L10n\.text\("S 曲线"\).*?range:\s*(-?\d+)\.\.\.(-?\d+),\s*step:\s*(\d+(?:\.\d+)?)', ios_curve, "light.s_curve ios step", "ToneCurveControls.swift", re.S).group(3))
    ios_grad_step = float(_need(r"range:\s*0\.\.\.360,\s*step:\s*(\d+(?:\.\d+)?)", ios_grad, "color.grading ios step", "ColorGradingControls.swift").group(1))
    ios_fx_step = float(_need(r"struct IOSPhotoEffectsControls.*?range:\s*parameter\.range,\s*step:\s*(\d+(?:\.\d+)?)", ios_fx, "effects ios step", "PhotoEffectPanels.swift", re.S).group(1))
    ios_wavelet_m = _need(r"struct IOSDenoiseControls.*?range:\s*(-?\d+)\.\.\.(-?\d+),\s*step:\s*(\d+(?:\.\d+)?)", ios_fx, "wavelet ios ui", "PhotoEffectPanels.swift", re.S)
    ios_wavelet_range = (float(ios_wavelet_m.group(1)), float(ios_wavelet_m.group(2)))
    ios_wavelet_step = float(ios_wavelet_m.group(3))
    ios_hsl_m = _need(r"struct IOSHSLMixer.*?range:\s*(-?\d+)\.\.\.(-?\d+),\s*step:\s*(\d+(?:\.\d+)?)", ios_fx, "hsl ios ui", "PhotoEffectPanels.swift", re.S)
    ios_hsl_range = (float(ios_hsl_m.group(1)), float(ios_hsl_m.group(2)))
    ios_hsl_step = float(ios_hsl_m.group(3))

    ios_crop_min_pct = float(_need(r"let minimum = key == .*?cropWidth.*? \? (\d+(?:\.\d+)?) : 0", ios_geom, "crop min ios ui", "GeometryControls.swift").group(1))
    ios_crop_step = float(_need(r"func cropControl.*?step:\s*(\d+(?:\.\d+)?)", ios_geom, "crop step ios ui", "GeometryControls.swift", re.S).group(1))
    ios_straighten_m = _need(r'AdjustmentControl\(title:\s*L10n\.text\("拉直"\).*?range:\s*(-?\d+)\.\.\.(-?\d+),\s*step:\s*(\d+(?:\.\d+)?)', ios_geom, "straighten ios ui", "GeometryControls.swift", re.S)
    ios_straighten_range = (float(ios_straighten_m.group(1)), float(ios_straighten_m.group(2)))
    ios_straighten_step = float(ios_straighten_m.group(3))
    ios_persp_m = _need(r"func perspectiveControl.*?range:\s*(-?\d+)\.\.\.(-?\d+),\s*step:\s*(\d+(?:\.\d+)?)", ios_geom, "persp ios ui", "GeometryControls.swift", re.S)
    ios_persp_range = (float(ios_persp_m.group(1)), float(ios_persp_m.group(2)))
    ios_persp_step = float(ios_persp_m.group(3))
    _require('accessibilityIdentifier("lens.vignetting")', ios_lens, "geometry.lens.vignetting ios sdr", "LensControls.swift")

    dn_blk = _extract_brace_block(ios_raw, r"struct RawDenoiseSettings\b", "wavelet ios ui", "RawSettings.swift")
    ios_w_enabled = _need(r"var enabled(?:\s*:\s*Bool)?\s*=\s*(true|false)", dn_blk, "wavelet enabled ios", "RawSettings.swift").group(1) == "true"
    ios_w_luma = float(_need(r"var luma(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", dn_blk, "wavelet luma ios", "RawSettings.swift").group(1))
    ios_w_chroma = float(_need(r"var chroma(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", dn_blk, "wavelet chroma ios", "RawSettings.swift").group(1))
    ios_w_coarse = float(_need(r"var coarse(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", dn_blk, "wavelet coarse ios", "RawSettings.swift").group(1))
    dn_preset_blk = _extract_brace_block(dn_blk, r"var preset:\s*RawDenoisePreset\b", "wavelet preset ios", "RawSettings.swift")
    _fmt_num = lambda v: str(int(v)) if v.is_integer() else str(v)
    ios_w_preset = _need(
        rf"if luma == {_fmt_num(ios_w_luma)} && chroma == {_fmt_num(ios_w_chroma)} && coarse == {_fmt_num(ios_w_coarse)} \{{ return \.(\w+) \}}",
        dn_preset_blk,
        "wavelet preset ios",
        "RawSettings.swift",
    ).group(1)
    ios_wavelet_def = {
        "enabled": ios_w_enabled,
        "luma": ios_w_luma,
        "chroma": ios_w_chroma,
        "coarse": ios_w_coarse,
        "preset": ios_w_preset,
    }

    hdr_mon_peak_step = float(_need(r'slider\("HDR 亮度上限".*?step:\s*(\d+(?:\.\d+)?)', hdr_mon, "hdr.peak ios step", "Shared/Native/HDRMonitoring.swift").group(1))
    hdr_mon_sdr_exp_step = float(_need(r'slider\("SDR 底图曝光".*?step:\s*(\d+(?:\.\d+)?)', hdr_mon, "hdr.sdr_exp ios step", "Shared/Native/HDRMonitoring.swift").group(1))
    hdr_mon_sdr_con_step = float(_need(r'slider\("SDR 底图对比度".*?step:\s*(\d+(?:\.\d+)?)', hdr_mon, "hdr.sdr_con ios step", "Shared/Native/HDRMonitoring.swift").group(1))
    hdr_mon_sdr_sat_step = float(_need(r'slider\("SDR 底图饱和度".*?step:\s*(\d+(?:\.\d+)?)', hdr_mon, "hdr.sdr_sat ios step", "Shared/Native/HDRMonitoring.swift").group(1))
    hdr_mon_look_m = _need(r"Slider\(value:\s*\$settings\.lookSettings\.strength,\s*in:\s*(\d+)\.\.\.(\d+),\s*step:\s*(\d+(?:\.\d+)?)", hdr_mon, "hdr.look ios ui", "Shared/Native/HDRMonitoring.swift")
    hdr_mon_look_step = round(float(hdr_mon_look_m.group(3)) * 100.0, 6)
    hdr_mon_cam_temp_step = float(_need(r'cameraSlider\("色温".*?step:\s*(\d+(?:\.\d+)?)', hdr_mon, "hdr.cam temp ios", "Shared/Native/HDRMonitoring.swift").group(1))
    hdr_mon_cam_tint_step = float(_need(r'cameraSlider\("色调".*?step:\s*(\d+(?:\.\d+)?)', hdr_mon, "hdr.cam tint ios", "Shared/Native/HDRMonitoring.swift").group(1))

    hdr_peak_range = tuple(float(x) for x in _need(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(peakLimitEV\)", hdr_swift, "hdr.peak bounds", "Shared/HDRSettings.swift").groups())
    hdr_sdr_exp_range = tuple(float(x) for x in _need(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(sdrExposureEV\)", hdr_swift, "hdr.sdr_exp bounds", "Shared/HDRSettings.swift").groups())
    hdr_sdr_con_range = tuple(float(x) for x in _need(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(sdrContrast\)", hdr_swift, "hdr.sdr_con bounds", "Shared/HDRSettings.swift").groups())
    hdr_sdr_sat_range = tuple(float(x) for x in _need(r"\((-?\d+)\.\.\.(-?\d+)\)\.contains\(sdrSaturation\)", hdr_swift, "hdr.sdr_sat bounds", "Shared/HDRSettings.swift").groups())
    hdr_cam_blk = _extract_brace_block(hdr_swift, r"(?:public\s+)?struct HDRCameraDevelopmentSettings\b", "hdr cam ios ui", "Shared/HDRSettings.swift")

    _require('look = ["kind": .string("neutral"), "id": .null]', ios_tv, "looks.reference ios", "IOSAdjustmentTransferValues.swift")
    _require('result[Field.look.rawValue] = .object(look)', ios_tv, "looks.reference ios wire", "IOSAdjustmentTransferValues.swift")
    ios_raw_struct = _extract_brace_block(ios_raw, r"struct RawSettings\b", "RawSettings ios ui", "RawSettings.swift")
    exp_mode_def = _need(r"var exposureMode\s*=\s*RawExposureMode\.(\w+)", ios_raw_struct, "light.exposure_mode ios ui", "RawSettings.swift").group(1)
    wb_mode_var = _need(r"whiteBalanceMode:\s*\.(\w+)", ios_raw_struct, "wb.mode ios ui", "RawSettings.swift").group(1)
    _need(rf"whiteBalanceMode\s*==\s*\.{re.escape(wb_mode_var)}", ios_tv, "wb.mode ios tv", "IOSAdjustmentTransferValues.swift")
    wb_mode_wire = _need(r'let camera = !context\.isRaw \|\| settings\.whiteBalanceMode == \.camera.*?camera \? "([^"]+)"', ios_tv, "wb.mode ios wire", "IOSAdjustmentTransferValues.swift", re.S).group(1)

    ui: dict[str, dict] = {}
    ui["looks.reference"] = _ui_entry(modes=("sdr",), default={"kind": "neutral", "id": None})
    ui["looks.strength"] = _ui_entry(
        modes=("sdr",),
        unit="%",
        min_val=ios_ranges["strength"][0] * strength_scale,
        max_val=ios_ranges["strength"][1] * strength_scale,
        default=100.0,
        step=round(ios_steps["strength"] * strength_scale, 6),
    )
    ui["light.exposure"] = _ui_entry(unit=ios_units["exposure"], min_val=ios_ranges["exposure"][0], max_val=ios_ranges["exposure"][1], hdr_min=ios_exp_hdr_range[0], hdr_max=ios_exp_hdr_range[1], default=0.0, step=ios_steps["exposure"])
    ui["light.exposure_mode"] = _ui_entry(modes=("sdr",), default=exp_mode_def)

    for fid, k in (
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
        ui[fid] = _ui_entry(unit=ios_units[k], min_val=ios_ranges[k][0], max_val=ios_ranges[k][1], default=0.0, step=ios_steps[k])
    ui["light.s_curve"] = _ui_entry(unit=ios_units["toneCurve"], min_val=ios_ranges["toneCurve"][0], max_val=ios_ranges["toneCurve"][1], default=0.0, step=ios_scurve_ui_step)
    ui["light.curve"] = _ui_curve_entry("ios")

    for zone in ("shadows", "midtones", "highlights"):
        ui[f"color.grading.{zone}"] = _ui_entry(default={"hue": 0.0, "saturation": 0.0}, step={"hue": ios_grad_step, "saturation": ios_grad_step})

    ui["color.white_balance.mode"] = _ui_entry(modes=("sdr",), default=wb_mode_wire)
    ui["color.white_balance.temperature_kelvin"] = _ui_entry(modes=("sdr",), unit=ios_units["temperature"], min_val=ios_ranges["temperature"][0], max_val=ios_ranges["temperature"][1], default=6500.0, step=wb_temp_step)
    ui["color.white_balance.tint"] = _ui_entry(modes=("sdr",), unit=ios_units["tint"], min_val=ios_ranges["tint"][0], max_val=ios_ranges["tint"][1], default=0.0, step=ios_steps["tint"])

    ui["hdr.relative_temperature"] = _ui_entry(modes=("hdr",), unit=ios_units["temperature"], min_val=ios_ranges["temperature"][0], max_val=ios_ranges["temperature"][1], default=6500.0, step=ios_steps["temperature"])
    ui["hdr.relative_tint"] = _ui_entry(modes=("hdr",), unit=ios_units["tint"], min_val=ios_ranges["tint"][0], max_val=ios_ranges["tint"][1], default=0.0, step=ios_steps["tint"])
    ui["hdr.peak_limit_ev"] = _ui_entry(modes=("hdr",), unit="EV", min_val=hdr_peak_range[0], max_val=hdr_peak_range[1], default=0.0, step=hdr_mon_peak_step)
    ui["hdr.sdr_exposure_ev"] = _ui_entry(modes=("hdr",), unit="EV", min_val=hdr_sdr_exp_range[0], max_val=hdr_sdr_exp_range[1], default=0.0, step=hdr_mon_sdr_exp_step)
    ui["hdr.sdr_contrast"] = _ui_entry(modes=("hdr",), unit="%", min_val=hdr_sdr_con_range[0], max_val=hdr_sdr_con_range[1], default=0.0, step=hdr_mon_sdr_con_step)
    ui["hdr.sdr_saturation"] = _ui_entry(modes=("hdr",), unit="%", min_val=hdr_sdr_sat_range[0], max_val=hdr_sdr_sat_range[1], default=0.0, step=hdr_mon_sdr_sat_step)
    ui["hdr.look"] = _ui_entry(modes=("hdr",), unit="%", min_val=float(hdr_mon_look_m.group(1)) * 100.0, max_val=float(hdr_mon_look_m.group(2)) * 100.0, default=100.0, step={"strength": hdr_mon_look_step})
    ui["hdr.camera_development"] = _ui_entry(
        modes=("hdr",),
        default={
            "version": int(_need(r"var version(?:\s*:\s*Int)?\s*=\s*(\d+)", hdr_cam_blk, "hdr cam ver", "Shared/HDRSettings.swift").group(1)),
            "white_balance_mode": _need(r'case asShot\s*=\s*"([^"]+)"', hdr_cam_blk, "hdr cam wb", "Shared/HDRSettings.swift").group(1),
            "temperature": float(_need(r"var temperature(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", hdr_cam_blk, "hdr cam temp", "Shared/HDRSettings.swift").group(1)),
            "tint": float(_need(r"var tint(?:\s*:\s*Double)?\s*=\s*(-?\d+(?:\.\d+)?)", hdr_cam_blk, "hdr cam tint", "Shared/HDRSettings.swift").group(1)),
            "exposure_reference": _need(r"enum ExposureReference[^{]*\{\s*case (\w+)", hdr_cam_blk, "hdr cam ref", "Shared/HDRSettings.swift").group(1),
            "fbdd_level": int(_need(r"var fbddLevel(?:\s*:\s*Int)?\s*=\s*(\d+)", hdr_cam_blk, "hdr cam fbdd", "Shared/HDRSettings.swift").group(1)),
        },
        step={"temperature": hdr_mon_cam_temp_step, "tint": hdr_mon_cam_tint_step},
    )

    for axis in HSL_AXES:
        for ch in HSL_CHANNELS:
            ui[f"color.hsl.{axis}.{ch}"] = _ui_entry(unit="", min_val=ios_hsl_range[0], max_val=ios_hsl_range[1], default=0.0, step=ios_hsl_step)

    for fid, prop in (
        ("effects.vignette.amount", "vignetteAmount"),
        ("effects.vignette.midpoint", "vignetteMidpoint"),
        ("effects.vignette.roundness", "vignetteRoundness"),
        ("effects.vignette.feather", "vignetteFeather"),
        ("effects.vignette.highlights", "vignetteHighlights"),
        ("effects.grain.amount", "grainAmount"),
        ("effects.grain.size", "grainSize"),
        ("effects.grain.roughness", "grainRoughness"),
    ):
        r_m = _need(rf"static let {prop}Range:\s*ClosedRange<Double>\s*=\s*(-?\d+(?:\.\d+)?)\.\.\.(-?\d+(?:\.\d+)?)", fx_blk, f"{fid} ios ui range", "RawSettings.swift")
        d_m = _need(rf"{prop}:\s*Double\s*=\s*(-?\d+(?:\.\d+)?)", fx_init_blk, f"{fid} ios ui default", "RawSettings.swift")
        ui[fid] = _ui_entry(unit="", min_val=float(r_m.group(1)), max_val=float(r_m.group(2)), default=float(d_m.group(1)), step=ios_fx_step)

    ui["detail.sharpening"] = _ui_entry(unit=ios_units["sharpening"], min_val=ios_ranges["sharpening"][0], max_val=ios_ranges["sharpening"][1], default=0.0, step=ios_steps["sharpening"])
    ui["detail.denoise.raw_level"] = _ui_entry(exposed=False, modes=())
    ui["detail.denoise.post_rgb"] = _ui_entry(modes=("hdr",), unit=ios_hdr_denoise_unit, min_val=ios_ranges["noiseReduction"][0] * strength_scale, max_val=ios_ranges["noiseReduction"][1] * strength_scale, default=0.0, step=round(ios_steps["noiseReduction"] * strength_scale, 6))
    ui["detail.denoise.chroma_mode"] = _ui_entry(exposed=False, modes=())
    ui["detail.denoise.wavelet"] = _ui_entry(modes=("sdr",), unit="", min_val=ios_wavelet_range[0], max_val=ios_wavelet_range[1], default=ios_wavelet_def, step={"luma": ios_wavelet_step, "chroma": ios_wavelet_step, "coarse": ios_wavelet_step})

    for fid in ("geometry.crop.x", "geometry.crop.y"):
        ui[fid] = _ui_entry(unit="%", min_val=0.0, max_val=100.0, default=0.0, step=ios_crop_step)
    for fid in ("geometry.crop.width", "geometry.crop.height"):
        ui[fid] = _ui_entry(unit="%", min_val=ios_crop_min_pct, max_val=100.0, default=100.0, step=ios_crop_step)
    ios_qt_range = tuple(int(x) for x in _need(r"\((\d+)\.\.\.(\d+)\)\.contains\(quarterTurns\)", geom_swift, "qt range ios ui", "Shared/GeometrySettings.swift").groups())
    ios_qt_def = int(_need(r"var quarterTurns:\s*Int\s*=\s*(\d+)", geom_swift, "qt def ios ui", "Shared/GeometrySettings.swift").group(1))
    ios_flip_h = _need(r"var flipHorizontal:\s*Bool\s*=\s*(true|false)", geom_swift, "flipH def ios ui", "Shared/GeometrySettings.swift").group(1) == "true"
    ios_flip_v = _need(r"var flipVertical:\s*Bool\s*=\s*(true|false)", geom_swift, "flipV def ios ui", "Shared/GeometrySettings.swift").group(1) == "true"
    ios_lens_blk = _extract_brace_block(ios_raw, r"struct LensCorrectionSettings\b", "geometry.lens ios ui", "RawSettings.swift")
    ios_lens_defs = {
        "distortion": _need(r"var distortion(?:\s*:\s*Bool)?\s*=\s*(true|false)", ios_lens_blk, "lens.distortion ios ui", "RawSettings.swift").group(1) == "true",
        "tca": _need(r"var tca(?:\s*:\s*Bool)?\s*=\s*(true|false)", ios_lens_blk, "lens.tca ios ui", "RawSettings.swift").group(1) == "true",
        "vignetting": _need(r"var vignetting(?:\s*:\s*Bool)?\s*=\s*(true|false)", ios_lens_blk, "lens.vignetting ios ui", "RawSettings.swift").group(1) == "true",
        "auto_crop": _need(r"var autoCrop(?:\s*:\s*Bool)?\s*=\s*(true|false)", ios_lens_blk, "lens.auto_crop ios ui", "RawSettings.swift").group(1) == "true",
    }
    ui["geometry.quarter_turns"] = _ui_entry(min_val=ios_qt_range[0], max_val=ios_qt_range[1], default=ios_qt_def, step=1)
    ui["geometry.flip_horizontal"] = _ui_entry(default=ios_flip_h)
    ui["geometry.flip_vertical"] = _ui_entry(default=ios_flip_v)
    ui["geometry.straighten_degrees"] = _ui_entry(unit="°", min_val=ios_straighten_range[0], max_val=ios_straighten_range[1], default=0.0, step=ios_straighten_step)
    ui["geometry.perspective.horizontal"] = _ui_entry(unit="", min_val=ios_persp_range[0], max_val=ios_persp_range[1], default=0.0, step=ios_persp_step)
    ui["geometry.perspective.vertical"] = _ui_entry(unit="", min_val=ios_persp_range[0], max_val=ios_persp_range[1], default=0.0, step=ios_persp_step)
    for fid, key in (("geometry.lens.distortion", "distortion"), ("geometry.lens.tca", "tca"), ("geometry.lens.vignetting", "vignetting"), ("geometry.lens.auto_crop", "auto_crop")):
        ui[fid] = _ui_entry(modes=("sdr", "hdr"), default=ios_lens_defs[key])
    ui["geometry.lens.profile_id"] = _ui_entry(modes=("sdr",), default=None)
    ui["local.ai_denoise_enabled"] = _ui_entry(exposed=False, modes=())
    ui["local.hdr_camera_ai_enabled"] = _ui_entry(exposed=False, modes=())
    return ui


def _parse_android_ui() -> dict[str, dict]:
    """Parse Android UI metadata solely from RawLabAndroid Kotlin sources."""
    kt_ctrl = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/editor/controls/AdjustmentControls.kt"))
    kt_dock = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/editor/ui/AdjustmentDock.kt"))
    kt_screen = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/editor/ui/EditorScreen.kt"))
    kt_curve = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/editor/controls/ToneCurveControls.kt"))
    kt_dn = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/editor/controls/DenoiseControls.kt"))
    kt_hsl = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/editor/controls/HslControls.kt"))
    kt_grad = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/editor/controls/ColorGradingControls.kt"))
    kt_fx = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/editor/panels/PhotoEffectsControls.kt"))
    kt_geom = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/editor/geometry/GeometryControls.kt"))
    kt_lens = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/editor/panels/LensControls.kt"))
    kt_edit = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/settings/EditSettings.kt"))
    kt_hdr = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/settings/HDRSettings.kt"))
    kt_geom_model = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/geometry/GeometrySettings.kt"))
    kt_tv = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/adjustments/AdjustmentTransferValues.kt"))
    kt_hdr_tx = _strip_line_comments(_read("RawLabAndroid/app/src/main/java/com/rawlab/android/adjustments/AdjustmentTransfer.kt"))

    kt_step_block = _extract_brace_block(kt_ctrl, r"val step = stepOverride \?: when \(label\)", "android steps", "AdjustmentControls.kt")
    kt_exp_step = float(_need(r"R\.string\.exposure\s*->\s*(\.\d+|\d+(?:\.\d+)?)f", kt_step_block, "kt exp step", "AdjustmentControls.kt").group(1))
    kt_temp_step = float(_need(r"R\.string\.temperature\s*->\s*(\.\d+|\d+(?:\.\d+)?)f", kt_step_block, "kt temp step", "AdjustmentControls.kt").group(1))
    kt_straight_step = float(_need(r"R\.string\.geometry_straighten\s*->\s*(\.\d+|\d+(?:\.\d+)?)f", kt_step_block, "kt straighten step", "AdjustmentControls.kt").group(1))
    kt_crop_step = float(_need(r"R\.string\.geometry_crop_height\s*->\s*(\.\d+|\d+(?:\.\d+)?)f", kt_step_block, "kt crop step", "AdjustmentControls.kt").group(1))
    kt_default_step = float(_need(r"else\s*->\s*(\.\d+|\d+(?:\.\d+)?)f", kt_step_block, "kt default step", "AdjustmentControls.kt").group(1))

    kt_grad_m = _need(r"R\.string\.hsl_hue.*?(-?\d+)f\.\.(-?\d+)f.*?stepOverride\s*=\s*(\.\d+|\d+(?:\.\d+)?)f", kt_grad, "kt grading ui", "ColorGradingControls.kt", re.S)
    kt_grad_step = float(kt_grad_m.group(3))
    kt_hdr_look_m = _need(r"R\.string\.transfer_field_strength,\s*look\.strength \* 100f?,\s*(-?\d+)f\.\.(-?\d+)f,\s*\"([^\"]*)\".*?stepOverride\s*=\s*(\.\d+|\d+(?:\.\d+)?)f", kt_dock, "kt hdr look ui", "AdjustmentDock.kt", re.S)
    kt_hdr_look_step = float(kt_hdr_look_m.group(4))
    kt_hdr_peak_m = _need(r"R\.string\.hdr_peak_limit.*?(-?\d+)f\.\.(-?\d+)f,\s*\"([^\"]*)\".*?stepOverride\s*=\s*(\.\d+|\d+(?:\.\d+)?)f", kt_screen, "kt hdr peak ui", "EditorScreen.kt", re.S)
    kt_hdr_peak_step = float(kt_hdr_peak_m.group(4))
    _require("NumericControl(R.string.temperature, draft.temperature", kt_screen, "hdr.camera_development temp step", "EditorScreen.kt")

    kt_crop_min_pct = float(_need(r"R\.string\.geometry_crop_width.*?minOf\((\.\d+|\d+(?:\.\d+)?)f,", kt_geom, "kt crop min", "GeometryControls.kt").group(1))
    kt_persp_m = _need(r'R\.string\.geometry_perspective_horizontal,\s*value\.perspectiveHorizontal \* 100f,\s*(-?\d+)f\.\.(-?\d+)f,\s*"([^"]*)"', kt_geom, "kt persp ui", "GeometryControls.kt")
    kt_persp_range = (float(kt_persp_m.group(1)), float(kt_persp_m.group(2)))
    kt_persp_unit = kt_persp_m.group(3)
    kt_straight_m = _need(r'R\.string\.geometry_straighten,\s*value\.straightenDegrees,\s*(-?\d+)f\.\.(-?\d+)f,\s*"([^"]*)"', kt_geom, "kt straighten ui", "GeometryControls.kt")
    _require('"lens.vignetting"', kt_lens, "geometry.lens.vignetting android sdr", "LensControls.kt")

    strength_m = _need(r'R\.string\.strength,\s*edits\.strength \* 100f?,\s*(-?\d+)f\.\.(-?\d+)f,\s*"([^"]*)"', kt_dock, "kt strength ui", "AdjustmentDock.kt")
    exp_m = _need(r'R\.string\.exposure,\s*edits\.exposure,\s*if \(edits\.isHDREditing\) (-?\d+(?:\.\d+)?)f\.\.(-?\d+(?:\.\d+)?)f else (-?\d+(?:\.\d+)?)f\.\.(-?\d+(?:\.\d+)?)f,\s*"([^"]*)"', kt_dock, "kt exp ui", "AdjustmentDock.kt")
    temp_m = _need(r'R\.string\.temperature,.*?(-?\d+)f\.\.(-?\d+)f,\s*"([^"]*)"', kt_dock, "kt temp ui", "AdjustmentDock.kt", re.S)
    tint_m = _need(r'R\.string\.tint,.*?(-?\d+)f\.\.(-?\d+)f,\s*"([^"]*)"', kt_dock, "kt tint ui", "AdjustmentDock.kt", re.S)
    sharp_m = _need(r'R\.string\.sharpening,.*?(-?\d+)f\.\.(-?\d+)f,\s*"([^"]*)"', kt_dock, "kt sharp ui", "AdjustmentDock.kt", re.S)
    dn_hdr_m = _need(r'R\.string\.denoise,.*?(-?\d+)f\.\.(-?\d+)f,\s*"([^"]*)"', kt_dock, "kt hdr denoise ui", "AdjustmentDock.kt", re.S)
    _require("-100f..100f", kt_curve, "kt s_curve ui", "ToneCurveControls.kt")

    dn_ui_m = _need(r'(-?\d+)f\.\.(-?\d+)f,\s*""', kt_dn, "kt wavelet ui", "DenoiseControls.kt")
    dn_blk = _extract_kt_class_block(kt_edit, r"data class DenoiseSettings\b", "kt wavelet defaults", "EditSettings.kt")
    kt_w_en = _need(r"val enabled:\s*Boolean\s*=\s*(true|false)", dn_blk, "kt wavelet enabled", "EditSettings.kt").group(1) == "true"
    kt_w_luma = float(_need(r"val luma:\s*Float\s*=\s*(-?\d+(?:\.\d+)?)f", dn_blk, "kt wavelet luma", "EditSettings.kt").group(1))
    kt_w_chroma = float(_need(r"val chroma:\s*Float\s*=\s*(-?\d+(?:\.\d+)?)f", dn_blk, "kt wavelet chroma", "EditSettings.kt").group(1))
    kt_w_coarse = float(_need(r"val coarse:\s*Float\s*=\s*(-?\d+(?:\.\d+)?)f", dn_blk, "kt wavelet coarse", "EditSettings.kt").group(1))
    _fmt_kt = lambda v: f"{int(v)}f" if v.is_integer() else f"{v}f"
    kt_w_preset = _need(
        rf"luma == {_fmt_kt(kt_w_luma)} && chroma == {_fmt_kt(kt_w_chroma)} && coarse == {_fmt_kt(kt_w_coarse)} -> DenoisePreset\.(\w+)",
        dn_blk,
        "kt wavelet preset",
        "EditSettings.kt",
    ).group(1).lower()
    kt_wavelet_def = {
        "enabled": kt_w_en,
        "luma": kt_w_luma,
        "chroma": kt_w_chroma,
        "coarse": kt_w_coarse,
        "preset": kt_w_preset,
    }
    hsl_ui_m = _need(r'(-?\d+)f\.\.(-?\d+)f,\s*""', kt_hsl, "kt hsl ui", "HslControls.kt")
    _require("parameter.range", kt_fx, "kt effects range", "PhotoEffectsControls.kt")
    _require("parameter.defaultValue", kt_fx, "kt effects default", "PhotoEffectsControls.kt")
    fx_enum_blk = _extract_brace_block(kt_edit, r"enum class PhotoEffectParameter\b", "kt effects enum", "EditSettings.kt")
    kt_hdr_cam_blk = _extract_kt_class_block(kt_hdr, r"data class HDRCameraDevelopmentSettings\b", "kt hdr cam ui", "HDRSettings.kt")
    kt_hdr_cam_tx = _need(r"private fun cameraValue\([^)]*\)\s*=\s*AdjustmentValue\.Object\((.*?)\)\)\)", kt_hdr_tx, "kt hdr cam wire", "AdjustmentTransfer.kt", re.S).group(1)
    kt_hdr_custom_wb = _need(r"val customWhiteBalance:\s*Boolean\s*=\s*(true|false)", kt_hdr_cam_blk, "kt hdr customWb", "HDRSettings.kt").group(1) == "true"
    kt_hdr_sensor_exp = _need(r"val sensorExposure:\s*Boolean\s*=\s*(true|false)", kt_hdr_cam_blk, "kt hdr sensorExp", "HDRSettings.kt").group(1) == "true"
    kt_hdr_wb_pair = _need(r'if \(camera\.customWhiteBalance\) "([^"]+)" else "([^"]+)"', kt_hdr_cam_tx, "kt hdr cam wb wire", "AdjustmentTransfer.kt")
    kt_hdr_ref_pair = _need(r'if \(camera\.sensorExposure\) "([^"]+)" else "([^"]+)"', kt_hdr_cam_tx, "kt hdr cam ref wire", "AdjustmentTransfer.kt")

    kt_exp_mode_idx = int(_need(r"val exposureMode:\s*Int\s*=\s*(\d+)", kt_edit, "kt exp mode def", "EditSettings.kt").group(1))
    kt_exp_mode_list = _parse_quoted_list(_need(r"EXPOSURE_MODE[^\n]*listOf\(([^)]+)\)", kt_tv, "kt exp mode list", "AdjustmentTransferValues.kt").group(1))
    kt_exp_mode_def = kt_exp_mode_list[kt_exp_mode_idx]
    kt_custom_wb_def = _need(r"val customWb:\s*Boolean\s*=\s*(true|false)", kt_edit, "kt customWb def", "EditSettings.kt").group(1) == "true"
    _require("val camera = !context.isRaw || !s.customWb", kt_tv, "kt wb camera def", "AdjustmentTransferValues.kt")
    kt_wb_pair = _need(r'WHITE_BALANCE_MODE[^\n]*if \(camera\) "([^"]+)" else "([^"]+)"', kt_tv, "kt wb mode wire", "AdjustmentTransferValues.kt")
    kt_wb_mode_def = kt_wb_pair.group(1) if not kt_custom_wb_def else kt_wb_pair.group(2)

    kt_qt_range = tuple(int(x) for x in _need(r"quarterTurns in (\d+)\.\.(\d+)", kt_geom_model, "kt qt range", "GeometrySettings.kt").groups())
    kt_qt_def = int(_need(r"val quarterTurns:\s*Int\s*=\s*(\d+)", kt_geom_model, "kt qt def", "GeometrySettings.kt").group(1))
    kt_flip_h_def = _need(r"val flipHorizontal:\s*Boolean\s*=\s*(true|false)", kt_geom_model, "kt flipH def", "GeometrySettings.kt").group(1) == "true"
    kt_flip_v_def = _need(r"val flipVertical:\s*Boolean\s*=\s*(true|false)", kt_geom_model, "kt flipV def", "GeometrySettings.kt").group(1) == "true"
    kt_lens_blk = _extract_kt_class_block(kt_edit, r"data class LensSettings\b", "kt lens ui", "EditSettings.kt")
    kt_lens_defs = {
        "distortion": _need(r"val distortion:\s*Boolean\s*=\s*(true|false)", kt_lens_blk, "kt lens dist", "EditSettings.kt").group(1) == "true",
        "tca": _need(r"val tca:\s*Boolean\s*=\s*(true|false)", kt_lens_blk, "kt lens tca", "EditSettings.kt").group(1) == "true",
        "vignetting": _need(r"val vignetting:\s*Boolean\s*=\s*(true|false)", kt_lens_blk, "kt lens vig", "EditSettings.kt").group(1) == "true",
        "auto_crop": _need(r"val autoCrop:\s*Boolean\s*=\s*(true|false)", kt_lens_blk, "kt lens autoCrop", "EditSettings.kt").group(1) == "true",
    }

    ui: dict[str, dict] = {}
    ui["looks.reference"] = _ui_entry(modes=("sdr",), default={"kind": "neutral", "id": None})
    ui["looks.strength"] = _ui_entry(modes=("sdr",), unit=strength_m.group(3), min_val=float(strength_m.group(1)), max_val=float(strength_m.group(2)), default=100.0, step=kt_default_step)
    ui["light.exposure"] = _ui_entry(unit=exp_m.group(5), min_val=float(exp_m.group(3)), max_val=float(exp_m.group(4)), hdr_min=float(exp_m.group(1)), hdr_max=float(exp_m.group(2)), default=0.0, step=kt_exp_step)
    ui["light.exposure_mode"] = _ui_entry(modes=("sdr",), default=kt_exp_mode_def)

    for fid, r_name in (
        ("light.contrast", "contrast"),
        ("light.highlights", "highlights"),
        ("light.shadows", "shadows"),
        ("tone.black_point", "black_point"),
        ("tone.white_point", "white_point"),
        ("color.vibrance", "vibrance"),
        ("color.saturation", "saturation"),
        ("effects.clarity", "clarity"),
        ("effects.dehaze", "dehaze"),
    ):
        m_nc = _need(rf'R\.string\.{r_name},[^\n]*?(-?\d+(?:\.\d+)?)f\.\.(-?\d+(?:\.\d+)?)f,\s*"([^"]*)"', kt_dock, f"kt {fid} ui", "AdjustmentDock.kt")
        ui[fid] = _ui_entry(unit=m_nc.group(3), min_val=float(m_nc.group(1)), max_val=float(m_nc.group(2)), default=0.0, step=kt_default_step)
    scurve_m = _need(r'R\.string\.tone_curve.*?(-?\d+)f\.\.(-?\d+)f,\s*"([^"]*)"', kt_curve, "kt s_curve bounds", "ToneCurveControls.kt", re.S)
    ui["light.s_curve"] = _ui_entry(unit=scurve_m.group(3), min_val=float(scurve_m.group(1)), max_val=float(scurve_m.group(2)), default=0.0, step=kt_default_step)
    ui["light.curve"] = _ui_curve_entry("android")

    for zone in ("shadows", "midtones", "highlights"):
        ui[f"color.grading.{zone}"] = _ui_entry(default={"hue": 0.0, "saturation": 0.0}, step={"hue": kt_grad_step, "saturation": kt_grad_step})

    ui["color.white_balance.mode"] = _ui_entry(modes=("sdr",), default=kt_wb_mode_def)
    ui["color.white_balance.temperature_kelvin"] = _ui_entry(modes=("sdr",), unit=temp_m.group(3), min_val=float(temp_m.group(1)), max_val=float(temp_m.group(2)), default=6500.0, step=kt_temp_step)
    ui["color.white_balance.tint"] = _ui_entry(modes=("sdr",), unit=tint_m.group(3), min_val=float(tint_m.group(1)), max_val=float(tint_m.group(2)), default=0.0, step=kt_default_step)

    ui["hdr.relative_temperature"] = _ui_entry(modes=("hdr",), unit=temp_m.group(3), min_val=float(temp_m.group(1)), max_val=float(temp_m.group(2)), default=6500.0, step=kt_temp_step)
    ui["hdr.relative_tint"] = _ui_entry(modes=("hdr",), unit=tint_m.group(3), min_val=float(tint_m.group(1)), max_val=float(tint_m.group(2)), default=0.0, step=kt_default_step)
    ui["hdr.peak_limit_ev"] = _ui_entry(modes=("hdr",), unit=kt_hdr_peak_m.group(3), min_val=float(kt_hdr_peak_m.group(1)), max_val=float(kt_hdr_peak_m.group(2)), default=0.0, step=kt_hdr_peak_step)
    sdr_exp_m = _need(r'R\.string\.hdr_sdr_exposure.*?(-?\d+)f\.\.(-?\d+)f,\s*"([^"]*)"', kt_screen, "kt hdr sdr_exposure ui", "EditorScreen.kt", re.S)
    sdr_con_m = _need(r'R\.string\.hdr_sdr_contrast.*?(-?\d+)f\.\.(-?\d+)f,\s*"([^"]*)"', kt_screen, "kt hdr sdr_contrast ui", "EditorScreen.kt", re.S)
    sdr_sat_m = _need(r'R\.string\.hdr_sdr_saturation.*?(-?\d+)f\.\.(-?\d+)f,\s*"([^"]*)"', kt_screen, "kt hdr sdr_saturation ui", "EditorScreen.kt", re.S)
    ui["hdr.sdr_exposure_ev"] = _ui_entry(modes=("hdr",), unit=sdr_exp_m.group(3), min_val=float(sdr_exp_m.group(1)), max_val=float(sdr_exp_m.group(2)), default=0.0, step=kt_hdr_peak_step)
    ui["hdr.sdr_contrast"] = _ui_entry(modes=("hdr",), unit=sdr_con_m.group(3), min_val=float(sdr_con_m.group(1)), max_val=float(sdr_con_m.group(2)), default=0.0, step=kt_default_step)
    ui["hdr.sdr_saturation"] = _ui_entry(modes=("hdr",), unit=sdr_sat_m.group(3), min_val=float(sdr_sat_m.group(1)), max_val=float(sdr_sat_m.group(2)), default=0.0, step=kt_default_step)
    ui["hdr.look"] = _ui_entry(modes=("hdr",), unit=kt_hdr_look_m.group(3), min_val=float(kt_hdr_look_m.group(1)), max_val=float(kt_hdr_look_m.group(2)), default=100.0, step={"strength": kt_hdr_look_step})
    ui["hdr.camera_development"] = _ui_entry(
        modes=("hdr",),
        default={
            "version": int(float(_need(r'"version" to AdjustmentValue\.Number\((\d+(?:\.\d+)?)\)', kt_hdr_cam_tx, "hdr cam ver android", "AdjustmentTransfer.kt").group(1))),
            "white_balance_mode": kt_hdr_wb_pair.group(1) if kt_hdr_custom_wb else kt_hdr_wb_pair.group(2),
            "temperature": float(_need(r"val temperature:\s*Float\s*=\s*(-?\d+(?:\.\d+)?)f", kt_hdr_cam_blk, "hdr cam temp android", "HDRSettings.kt").group(1)),
            "tint": float(_need(r"val tint:\s*Float\s*=\s*(-?\d+(?:\.\d+)?)f", kt_hdr_cam_blk, "hdr cam tint android", "HDRSettings.kt").group(1)),
            "exposure_reference": kt_hdr_ref_pair.group(1) if kt_hdr_sensor_exp else kt_hdr_ref_pair.group(2),
            "fbdd_level": int(_need(r"val fbddLevel:\s*Int\s*=\s*(\d+)", kt_hdr_cam_blk, "hdr cam fbdd android", "HDRSettings.kt").group(1)),
        },
        step={"temperature": kt_temp_step, "tint": kt_default_step},
    )

    for axis in HSL_AXES:
        for ch in HSL_CHANNELS:
            ui[f"color.hsl.{axis}.{ch}"] = _ui_entry(unit="", min_val=float(hsl_ui_m.group(1)), max_val=float(hsl_ui_m.group(2)), default=0.0, step=kt_default_step)

    for m_fx in re.finditer(r"(\w+)\((?:true|false),\s*(-?\d+(?:\.\d+)?)f\.\.(-?\d+(?:\.\d+)?)f,\s*(-?\d+(?:\.\d+)?)f\)", fx_enum_blk):
        enum_id, lo_s, hi_s, dflt_s = m_fx.groups()
        parts = enum_id.lower().split("_", 1)
        ui[f"effects.{parts[0]}.{parts[1]}"] = _ui_entry(unit="", min_val=float(lo_s), max_val=float(hi_s), default=float(dflt_s), step=kt_default_step)

    ui["detail.sharpening"] = _ui_entry(unit=sharp_m.group(3), min_val=float(sharp_m.group(1)), max_val=float(sharp_m.group(2)), default=0.0, step=kt_default_step)
    ui["detail.denoise.raw_level"] = _ui_entry(exposed=False, modes=())
    ui["detail.denoise.post_rgb"] = _ui_entry(modes=("hdr",), unit=dn_hdr_m.group(3), min_val=float(dn_hdr_m.group(1)), max_val=float(dn_hdr_m.group(2)), default=0.0, step=kt_default_step)
    ui["detail.denoise.chroma_mode"] = _ui_entry(exposed=False, modes=())
    ui["detail.denoise.wavelet"] = _ui_entry(modes=("sdr",), unit="", min_val=float(dn_ui_m.group(1)), max_val=float(dn_ui_m.group(2)), default=kt_wavelet_def, step={"luma": kt_default_step, "chroma": kt_default_step, "coarse": kt_default_step})

    for fid in ("geometry.crop.x", "geometry.crop.y"):
        ui[fid] = _ui_entry(unit="%", min_val=0.0, max_val=100.0, default=0.0, step=kt_crop_step)
    for fid in ("geometry.crop.width", "geometry.crop.height"):
        ui[fid] = _ui_entry(unit="%", min_val=kt_crop_min_pct, max_val=100.0, default=100.0, step=kt_crop_step)
    ui["geometry.quarter_turns"] = _ui_entry(min_val=kt_qt_range[0], max_val=kt_qt_range[1], default=kt_qt_def, step=1)
    ui["geometry.flip_horizontal"] = _ui_entry(default=kt_flip_h_def)
    ui["geometry.flip_vertical"] = _ui_entry(default=kt_flip_v_def)
    ui["geometry.straighten_degrees"] = _ui_entry(unit=kt_straight_m.group(3), min_val=float(kt_straight_m.group(1)), max_val=float(kt_straight_m.group(2)), default=0.0, step=kt_straight_step)
    ui["geometry.perspective.horizontal"] = _ui_entry(unit=kt_persp_unit, min_val=kt_persp_range[0], max_val=kt_persp_range[1], default=0.0, step=kt_default_step)
    ui["geometry.perspective.vertical"] = _ui_entry(unit=kt_persp_unit, min_val=kt_persp_range[0], max_val=kt_persp_range[1], default=0.0, step=kt_default_step)
    for fid, key in (("geometry.lens.distortion", "distortion"), ("geometry.lens.tca", "tca"), ("geometry.lens.vignetting", "vignetting"), ("geometry.lens.auto_crop", "auto_crop")):
        ui[fid] = _ui_entry(modes=("sdr", "hdr"), default=kt_lens_defs[key])
    ui["geometry.lens.profile_id"] = _ui_entry(modes=("sdr",), default=None)
    ui["local.ai_denoise_enabled"] = _ui_entry(exposed=False, modes=())
    ui["local.hdr_camera_ai_enabled"] = _ui_entry(exposed=False, modes=())
    return ui


def _parse_windows_ui() -> dict[str, dict]:
    """Parse Windows UI metadata solely from RawLabWindows C# / XAML sources."""
    cs_inter = _strip_line_comments(_read("RawLabWindows/ParameterInteraction.cs"))
    cs_adj = _strip_line_comments(_read("RawLabWindows/Adjustments.cs"))
    cs_fx = _strip_line_comments(_read("RawLabWindows/PhotoEffectsSettings.cs"))
    cs_fx_panel = _strip_line_comments(_read("RawLabWindows/PhotoEffectsPanel.xaml.cs"))
    cs_dn = _strip_line_comments(_read("RawLabWindows/DenoiseSettings.cs"))
    cs_dn_panel = _strip_line_comments(_read("RawLabWindows/DenoisePanel.xaml.cs"))
    cs_hsl_panel = _strip_line_comments(_read("RawLabWindows/HslPanel.cs"))
    cs_grad_panel = _strip_line_comments(_read("RawLabWindows/ColorGradingPanel.cs"))
    cs_curve_panel = _strip_line_comments(_read("RawLabWindows/ToneCurvePanel.cs"))
    cs_hdr = _strip_line_comments(_read("RawLabWindows/MainWindow.HDR.cs"))
    cs_hdr_model = _strip_line_comments(_read("RawLabWindows/HDRSettings.cs"))
    cs_geom = _strip_line_comments(_read("RawLabWindows/GeometryPanel.xaml.cs"))
    cs_geom_model = _strip_line_comments(_read("RawLabWindows/GeometrySettings.cs"))
    cs_lens_xaml = _read("RawLabWindows/LensPanel.xaml")
    cs_tools = _strip_line_comments(_read("RawLabWindows/MainWindow/Tools.cs"))
    cs_tv = _strip_line_comments(_read("RawLabWindows/AdjustmentTransferValues.cs"))
    cs_hdr_tx = _strip_line_comments(_read("RawLabWindows/HDRAdjustmentTransfer.cs"))

    cs_default_grid = float(_need(r"record NumericRange\(double Min,\s*double Max,\s*double Grid\s*=\s*(\.\d+|\d+(?:\.\d+)?)", cs_inter, "windows default grid", "ParameterInteraction.cs").group(1))
    cs_param_steps: dict[str, tuple[float, float, float, str]] = {}
    for m in re.finditer(
        r'new\(Parameter\.(\w+),"[^"]*","[^"]*",(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?),(-?\.\d+|\d+(?:\.\d+)?),"([^"]*)"',
        cs_adj,
    ):
        cs_param_steps[m.group(1)] = (float(m.group(2)), float(m.group(3)), float(m.group(4)), m.group(5))

    cs_defaults_arr = [float(x) for x in _need(r"private double\[\] values = \[([^\]]+)\];", cs_adj, "windows ui defaults", "Adjustments.cs").group(1).split(",")]
    cs_param_order = re.findall(r"[A-Za-z]\w*", _need(r"public enum Parameter \{([^}]*)\}", cs_adj, "windows Parameter order", "Adjustments.cs", re.S).group(1))
    cs_defaults = dict(zip(cs_param_order, cs_defaults_arr))

    cs_exp_mode_idx = int(_need(r"public int ExposureMode \{ get; set; \} = (\d+);", cs_adj, "windows exp mode def", "Adjustments.cs").group(1))
    cs_exp_mode_list = _parse_quoted_list(_need(r"Put\(F\.ExposureMode,[^\n]*new\[\]\{([^}]+)\}", cs_tv, "windows exp mode list", "AdjustmentTransferValues.cs").group(1))
    cs_exp_mode_def = cs_exp_mode_list[cs_exp_mode_idx]
    cs_cam_wb_def = _need(r"public bool CameraWhiteBalance \{ get; private set; \} = (true|false);", cs_adj, "windows camWb def", "Adjustments.cs").group(1) == "true"
    _require("var camera=!context.IsRaw || s.CameraWhiteBalance;", cs_tv, "windows wb camera", "AdjustmentTransferValues.cs")
    cs_wb_pair = _need(r'Put\(F\.WhiteBalanceMode,[^\n]*camera \? "([^"]+)" : "([^"]+)"', cs_tv, "windows wb mode wire", "AdjustmentTransferValues.cs")
    cs_wb_mode_def = cs_wb_pair.group(1) if cs_cam_wb_def else cs_wb_pair.group(2)

    cs_ext_unit_m = _need(r'var unit=extensionControl \? "([^"]*)" : spec\.Unit;', cs_tools, "windows tone/atmos unit", "MainWindow/Tools.cs")
    cs_ext_range_m = _need(r"extensionControl \? new NumericRange\((-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)\) : NumericRange\.For\(spec\)", cs_tools, "windows tone/atmos range", "MainWindow/Tools.cs")
    cs_hdr_exp_m = _need(r"if\(settings\.IsHDREditing && selectedParameter==Parameter\.Exposure\)\s*\n?\s*inputRange=inputRange with \{ Min=(-?\d+(?:\.\d+)?),\s*Max=(-?\d+(?:\.\d+)?) \};", cs_tools, "windows hdr exposure bounds", "MainWindow/Tools.cs")
    scurve_m = _need(r'legacy\.Refresh\(Loc\.Text\("S 曲线"\),\s*new\((-?\d+),\s*(-?\d+)\),\s*scalar,\s*(-?\d+(?:\.\d+)?),\s*"([^"]*)"\)', cs_curve_panel, "windows s_curve ui", "ToneCurvePanel.cs")

    cs_straight_m = _need(r'angle\.Refresh\(Loc\.Text\("拉直"\),new\((-?\d+),(-?\d+),(\.\d+),', cs_geom, "windows straighten ui", "GeometryPanel.xaml.cs")
    cs_persp_m = _need(r'horizontal\.Refresh\(Loc\.Text\("水平透视"\),new\((-?\d+),(-?\d+),(\.\d+)', cs_geom, "windows persp ui", "GeometryPanel.xaml.cs")
    cs_crop_m = _need(r"new\(i<2 \? 0 : (\.\d+),maxima\[i\]\*100,(\.\d+),", cs_geom, "windows crop ui", "GeometryPanel.xaml.cs")
    cs_qt_range = tuple(int(x) for x in _need(r"QuarterTurns is < (\d+) or > (\d+)", cs_geom_model, "windows qt bounds", "GeometrySettings.cs").groups())
    cs_qt_def = int(_need(r"int QuarterTurns = (\d+)", cs_geom_model, "windows qt def", "GeometrySettings.cs").group(1))
    cs_flip_h_def = _need(r"bool FlipHorizontal = (true|false)", cs_geom_model, "windows flipH def", "GeometrySettings.cs").group(1) == "true"
    cs_flip_v_def = _need(r"bool FlipVertical = (true|false)", cs_geom_model, "windows flipV def", "GeometrySettings.cs").group(1) == "true"
    cs_lens_hdr = _need(r"public sealed record LensSettings\(([^)]+)\)", cs_adj, "windows lens defaults", "Adjustments.cs").group(1)
    cs_lens_defs = {
        "distortion": _need(r"bool Distortion = (true|false)", cs_lens_hdr, "windows lens dist", "Adjustments.cs").group(1) == "true",
        "tca": _need(r"bool Tca = (true|false)", cs_lens_hdr, "windows lens tca", "Adjustments.cs").group(1) == "true",
        "vignetting": _need(r"bool Vignetting = (true|false)", cs_lens_hdr, "windows lens vig", "Adjustments.cs").group(1) == "true",
        "auto_crop": _need(r"bool AutoCrop = (true|false)", cs_lens_hdr, "windows lens autoCrop", "Adjustments.cs").group(1) == "true",
    }
    _require_absent('x:Name="Vignetting"', cs_lens_xaml, "geometry.lens.vignetting windows sdr", "LensPanel.xaml")
    _require('LensToggle("暗角校正",draft.LensVignetting', cs_hdr, "geometry.lens.vignetting windows hdr toggle", "MainWindow.HDR.cs")

    cs_hdr_cam_temp_m = _need(r'temperature\.Refresh\(Loc\.Text\("色温"\),new\((-?\d+),(-?\d+),(\d+)\)', cs_hdr, "windows hdr cam temp step", "MainWindow.HDR.cs")
    cs_hdr_cam_tint_m = _need(r'tint\.Refresh\(Loc\.Text\("色调"\),new\((-?\d+),(-?\d+),(\d+)\)', cs_hdr, "windows hdr cam tint step", "MainWindow.HDR.cs")
    cs_hdr_cam_temp_step = float(cs_hdr_cam_temp_m.group(3))
    cs_hdr_cam_tint_step = float(cs_hdr_cam_tint_m.group(3))
    cs_hdr_look_m = _need(r'strength\.Refresh\(Loc\.Text\("外观强度"\),new\((-?\d+),(-?\d+),(\d+)\),[^,]+,(\d+),"([^"]*)"', cs_hdr, "windows hdr look ui", "MainWindow.HDR.cs")
    cs_hdr_peak_m = _need(r'Add\("peakLimit","HDR 亮度上限",new\((-?\d+),(-?\d+)(?:,(\d+(?:\.\d+)?))?\),[^,]*,"([^"]*)"', cs_hdr, "windows hdr peak ui", "MainWindow.HDR.cs")
    cs_hdr_sdr_exp_m = _need(r'Add\("sdrExposure","SDR 底图曝光",new\((-?\d+),(-?\d+)(?:,(\d+(?:\.\d+)?))?\),[^,]*,"([^"]*)"', cs_hdr, "windows hdr sdr_exp ui", "MainWindow.HDR.cs")
    cs_hdr_sdr_con_m = _need(r'Add\("sdrContrast","SDR 底图对比度",new\((-?\d+),(-?\d+),(\d+(?:\.\d+)?)\),[^,]*,"([^"]*)"', cs_hdr, "windows hdr sdr_con ui", "MainWindow.HDR.cs")
    cs_hdr_sdr_sat_m = _need(r'Add\("sdrSaturation","SDR 底图饱和度",new\((-?\d+),(-?\d+),(\d+(?:\.\d+)?)\),[^,]*,"([^"]*)"', cs_hdr, "windows hdr sdr_sat ui", "MainWindow.HDR.cs")
    cs_hdr_dn_m = _need(r'HDRAmount\.Refresh\(Loc\.Text\("降噪"\),new\((-?\d+),(-?\d+)\),strength\*100,0,"([^"]*)"', cs_dn_panel, "windows hdr denoise ui", "DenoisePanel.xaml.cs")
    cs_hdr_rel_temp_def = float(_need(r"public double Temperature \{ get; init; \} = (-?\d+(?:\.\d+)?);", cs_hdr_model, "windows hdr temp def", "HDRSettings.cs").group(1))

    dn_m = _need(r"record DenoiseSettings\(bool Enabled=(false|true),double Luma=(\d+),double Chroma=(\d+),double Coarse=(\d+)\)", cs_dn, "windows wavelet ui", "DenoiseSettings.cs")
    _require("public static DenoiseSettings Detail => new(true);", cs_dn, "windows wavelet Detail preset", "DenoiseSettings.cs")
    cs_preset_zero = _need(r"int Preset => \(this with \{Enabled=true\}\)==(\w+) \? 0", cs_dn, "windows wavelet preset zero", "DenoiseSettings.cs").group(1).lower()
    cs_wavelet_def = {"enabled": dn_m.group(1) == "true", "luma": float(dn_m.group(2)), "chroma": float(dn_m.group(3)), "coarse": float(dn_m.group(4)), "preset": cs_preset_zero}
    cs_dn_range_m = _need(r"rows\[i\]\.Refresh\([^;]+,new\((-?\d+),(-?\d+)\)", cs_dn_panel, "windows wavelet range", "DenoisePanel.xaml.cs")
    _cs_denoise_unit = _cs_denoise_percent_unit()

    cs_hsl_m = _need(r"rows\[axis\]\.Refresh\([^,]+,new\((-?\d+),(-?\d+)\)", cs_hsl_panel, "windows hsl ui", "HslPanel.cs")
    _require("0,360", cs_grad_panel.replace(" ", ""), "windows grading hue", "ColorGradingPanel.cs")

    _fx_win_unit = _fx_windows_unit()
    cs_fx_defs: dict[str, tuple[float, float, float]] = {}
    for m in re.finditer(r"new\(PhotoEffectParameter\.(\w+),\s*Loc\.Text\([^\)]+\),\s*(?:true|false),\s*(-?\d+),\s*(-?\d+),\s*(-?\d+)\)", cs_fx):
        cs_fx_defs[m.group(1)] = (float(m.group(2)), float(m.group(3)), float(m.group(4)))
    _require("rows[spec.Id].Refresh(Loc.Text(key.Title),new(spec.Min,spec.Max),value[spec.Id],spec.DefaultValue,", cs_fx_panel, "windows effects panel", "PhotoEffectsPanel.xaml.cs")

    cs_hdr_cam_params = _need(r"internal sealed record HDRCameraDevelopmentSettings\(([^)]+)\)", cs_hdr_model, "hdr cam win ui", "HDRSettings.cs").group(1)
    cs_hdr_cam_tx = _need(r"private static JsonElement CameraValue\([^)]*\)\s*=>\s*Value\(new \{(.*?)\}\);", cs_hdr_tx, "hdr cam win wire", "HDRAdjustmentTransfer.cs", re.S).group(1)
    cs_hdr_custom_wb = _need(r"bool CustomWhiteBalance = (true|false)", cs_hdr_cam_params, "hdr cam win customWb", "HDRSettings.cs").group(1) == "true"
    cs_hdr_sensor_exp = _need(r"bool SensorExposure = (true|false)", cs_hdr_cam_params, "hdr cam win sensorExp", "HDRSettings.cs").group(1) == "true"
    cs_hdr_wb_pair = _need(r'camera\.CustomWhiteBalance \? "([^"]+)" : "([^"]+)"', cs_hdr_cam_tx, "hdr cam win wb wire", "HDRAdjustmentTransfer.cs")
    cs_hdr_ref_pair = _need(r'camera\.SensorExposure \? "([^"]+)" : "([^"]+)"', cs_hdr_cam_tx, "hdr cam win ref wire", "HDRAdjustmentTransfer.cs")

    ui: dict[str, dict] = {}
    ui["looks.reference"] = _ui_entry(modes=("sdr",), default={"kind": "neutral", "id": None})
    ui["looks.strength"] = _ui_entry(modes=("sdr",), unit=cs_param_steps["Strength"][3], min_val=cs_param_steps["Strength"][0], max_val=cs_param_steps["Strength"][1], default=cs_defaults["Strength"], step=cs_param_steps["Strength"][2])
    ui["light.exposure"] = _ui_entry(unit=cs_param_steps["Exposure"][3], min_val=cs_param_steps["Exposure"][0], max_val=cs_param_steps["Exposure"][1], hdr_min=float(cs_hdr_exp_m.group(1)), hdr_max=float(cs_hdr_exp_m.group(2)), default=cs_defaults["Exposure"], step=cs_param_steps["Exposure"][2])
    ui["light.exposure_mode"] = _ui_entry(modes=("sdr",), default=cs_exp_mode_def)

    for fid, k in (("light.contrast", "Contrast"), ("light.highlights", "Highlights"), ("light.shadows", "Shadows"), ("color.saturation", "Saturation")):
        ui[fid] = _ui_entry(unit=cs_param_steps[k][3], min_val=cs_param_steps[k][0], max_val=cs_param_steps[k][1], default=cs_defaults[k], step=cs_default_grid)
    for fid in ("tone.black_point", "tone.white_point", "color.vibrance", "effects.clarity", "effects.dehaze"):
        ui[fid] = _ui_entry(unit=cs_ext_unit_m.group(1), min_val=float(cs_ext_range_m.group(1)), max_val=float(cs_ext_range_m.group(2)), default=0.0, step=cs_default_grid)
    ui["light.s_curve"] = _ui_entry(unit=scurve_m.group(4), min_val=float(scurve_m.group(1)), max_val=float(scurve_m.group(2)), default=float(scurve_m.group(3)), step=cs_default_grid)
    ui["light.curve"] = _ui_curve_entry("windows")

    for zone in ("shadows", "midtones", "highlights"):
        ui[f"color.grading.{zone}"] = _ui_entry(default={"hue": 0.0, "saturation": 0.0}, step={"hue": cs_default_grid, "saturation": cs_default_grid})

    ui["color.white_balance.mode"] = _ui_entry(modes=("sdr",), default=cs_wb_mode_def)
    ui["color.white_balance.temperature_kelvin"] = _ui_entry(modes=("sdr",), unit=cs_param_steps["Temperature"][3], min_val=cs_param_steps["Temperature"][0], max_val=cs_param_steps["Temperature"][1], default=cs_defaults["Temperature"], step=cs_param_steps["Temperature"][2])
    ui["color.white_balance.tint"] = _ui_entry(modes=("sdr",), unit=cs_param_steps["Tint"][3], min_val=cs_param_steps["Tint"][0], max_val=cs_param_steps["Tint"][1], default=cs_defaults["Tint"], step=cs_param_steps["Tint"][2])

    ui["hdr.relative_temperature"] = _ui_entry(modes=("hdr",), unit=cs_param_steps["Temperature"][3], min_val=cs_param_steps["Temperature"][0], max_val=cs_param_steps["Temperature"][1], default=cs_hdr_rel_temp_def, step=cs_param_steps["Temperature"][2])
    ui["hdr.relative_tint"] = _ui_entry(modes=("hdr",), unit=cs_param_steps["Tint"][3], min_val=cs_param_steps["Tint"][0], max_val=cs_param_steps["Tint"][1], default=0.0, step=cs_param_steps["Tint"][2])
    ui["hdr.peak_limit_ev"] = _ui_entry(modes=("hdr",), unit=cs_hdr_peak_m.group(4), min_val=float(cs_hdr_peak_m.group(1)), max_val=float(cs_hdr_peak_m.group(2)), default=0.0, step=float(cs_hdr_peak_m.group(3) or cs_default_grid))
    ui["hdr.sdr_exposure_ev"] = _ui_entry(modes=("hdr",), unit=cs_hdr_sdr_exp_m.group(4), min_val=float(cs_hdr_sdr_exp_m.group(1)), max_val=float(cs_hdr_sdr_exp_m.group(2)), default=0.0, step=float(cs_hdr_sdr_exp_m.group(3) or cs_default_grid))
    ui["hdr.sdr_contrast"] = _ui_entry(modes=("hdr",), unit=cs_hdr_sdr_con_m.group(4), min_val=float(cs_hdr_sdr_con_m.group(1)), max_val=float(cs_hdr_sdr_con_m.group(2)), default=0.0, step=float(cs_hdr_sdr_con_m.group(3)))
    ui["hdr.sdr_saturation"] = _ui_entry(modes=("hdr",), unit=cs_hdr_sdr_sat_m.group(4), min_val=float(cs_hdr_sdr_sat_m.group(1)), max_val=float(cs_hdr_sdr_sat_m.group(2)), default=0.0, step=float(cs_hdr_sdr_sat_m.group(3)))
    ui["hdr.look"] = _ui_entry(modes=("hdr",), unit=cs_hdr_look_m.group(5), min_val=float(cs_hdr_look_m.group(1)), max_val=float(cs_hdr_look_m.group(2)), default=float(cs_hdr_look_m.group(4)), step={"strength": float(cs_hdr_look_m.group(3))})
    ui["hdr.camera_development"] = _ui_entry(
        modes=("hdr",),
        default={
            "version": int(_need(r"version = (\d+)", cs_hdr_cam_tx, "hdr cam win ver", "HDRAdjustmentTransfer.cs").group(1)),
            "white_balance_mode": cs_hdr_wb_pair.group(1) if cs_hdr_custom_wb else cs_hdr_wb_pair.group(2),
            "temperature": float(_need(r"double Temperature = (-?\d+(?:\.\d+)?)", cs_hdr_cam_params, "hdr cam win temp def", "HDRSettings.cs").group(1)),
            "tint": float(_need(r"double Tint = (-?\d+(?:\.\d+)?)", cs_hdr_cam_params, "hdr cam win tint def", "HDRSettings.cs").group(1)),
            "exposure_reference": cs_hdr_ref_pair.group(1) if cs_hdr_sensor_exp else cs_hdr_ref_pair.group(2),
            "fbdd_level": int(_need(r"int FbddLevel = (\d+)", cs_hdr_cam_params, "hdr cam win fbdd def", "HDRSettings.cs").group(1)),
        },
        step={"temperature": cs_hdr_cam_temp_step, "tint": cs_hdr_cam_tint_step},
    )

    for axis in HSL_AXES:
        for ch in HSL_CHANNELS:
            ui[f"color.hsl.{axis}.{ch}"] = _ui_entry(unit="", min_val=float(cs_hsl_m.group(1)), max_val=float(cs_hsl_m.group(2)), default=0.0, step=cs_default_grid)

    fx_map = (
        ("effects.vignette.amount", "VignetteAmount"),
        ("effects.vignette.midpoint", "VignetteMidpoint"),
        ("effects.vignette.roundness", "VignetteRoundness"),
        ("effects.vignette.feather", "VignetteFeather"),
        ("effects.vignette.highlights", "VignetteHighlights"),
        ("effects.grain.amount", "GrainAmount"),
        ("effects.grain.size", "GrainSize"),
        ("effects.grain.roughness", "GrainRoughness"),
    )
    for fid, cs_name in fx_map:
        lo, hi, dflt = _need_key(cs_fx_defs, cs_name, fid, "PhotoEffectsSettings.cs")
        ui[fid] = _ui_entry(unit=_fx_win_unit, min_val=lo, max_val=hi, default=dflt, step=cs_default_grid)

    ui["detail.sharpening"] = _ui_entry(unit=cs_param_steps["Sharpening"][3], min_val=cs_param_steps["Sharpening"][0], max_val=cs_param_steps["Sharpening"][1], default=cs_defaults["Sharpening"], step=cs_param_steps["Sharpening"][2])
    ui["detail.denoise.raw_level"] = _ui_entry(exposed=False, modes=())
    ui["detail.denoise.post_rgb"] = _ui_entry(modes=("hdr",), unit=cs_hdr_dn_m.group(3), min_val=float(cs_hdr_dn_m.group(1)), max_val=float(cs_hdr_dn_m.group(2)), default=0.0, step=cs_default_grid)
    ui["detail.denoise.chroma_mode"] = _ui_entry(exposed=False, modes=())
    ui["detail.denoise.wavelet"] = _ui_entry(modes=("sdr",), unit=_cs_denoise_unit, min_val=float(cs_dn_range_m.group(1)), max_val=float(cs_dn_range_m.group(2)), default=cs_wavelet_def, step={"luma": cs_default_grid, "chroma": cs_default_grid, "coarse": cs_default_grid})

    for fid in ("geometry.crop.x", "geometry.crop.y"):
        ui[fid] = _ui_entry(unit="%", min_val=0.0, max_val=100.0, default=0.0, step=float(cs_crop_m.group(2)))
    for fid in ("geometry.crop.width", "geometry.crop.height"):
        ui[fid] = _ui_entry(unit="%", min_val=float(cs_crop_m.group(1)), max_val=100.0, default=100.0, step=float(cs_crop_m.group(2)))
    ui["geometry.quarter_turns"] = _ui_entry(min_val=cs_qt_range[0], max_val=cs_qt_range[1], default=cs_qt_def, step=1)
    ui["geometry.flip_horizontal"] = _ui_entry(default=cs_flip_h_def)
    ui["geometry.flip_vertical"] = _ui_entry(default=cs_flip_v_def)
    ui["geometry.straighten_degrees"] = _ui_entry(unit="°", min_val=float(cs_straight_m.group(1)), max_val=float(cs_straight_m.group(2)), default=0.0, step=float(cs_straight_m.group(3)))
    for fid in ("geometry.perspective.horizontal", "geometry.perspective.vertical"):
        ui[fid] = _ui_entry(unit="", min_val=float(cs_persp_m.group(1)), max_val=float(cs_persp_m.group(2)), default=0.0, step=float(cs_persp_m.group(3)))
    for fid, key in (("geometry.lens.distortion", "distortion"), ("geometry.lens.tca", "tca"), ("geometry.lens.auto_crop", "auto_crop")):
        ui[fid] = _ui_entry(modes=("sdr", "hdr"), default=cs_lens_defs[key])
    ui["geometry.lens.vignetting"] = _ui_entry(exposed=True, modes=("hdr",), default=cs_lens_defs["vignetting"])
    ui["geometry.lens.profile_id"] = _ui_entry(modes=("sdr",), default=None)
    ui["local.ai_denoise_enabled"] = _ui_entry(modes=("sdr",), default=False)
    ui["local.hdr_camera_ai_enabled"] = _ui_entry(modes=("hdr",), default=False)
    return ui


def parse_ui_from_sources() -> dict[str, dict[str, dict]]:
    """Parse UI ranges, units, defaults, and steps independently per end."""
    mac_prec_src = _strip_line_comments(_read("RawLabMac/Sources/Inputs/ParameterPrecision.swift"))
    scale_block = _extract_brace_block(mac_prec_src, r"var scale:\s*Double", "mac ParameterPrecision", "ParameterPrecision.swift")
    mac_fine: dict[str, float] = {}
    for cases_str, val in re.findall(r"case ([^:]+):\s*return (\d+(?:\.\d+)?)", scale_block):
        for c in cases_str.split(","):
            mac_fine[c.strip().lstrip(".")] = round(1.0 / float(val), 6)

    per_platform = {
        "macos": _parse_mac_ui(mac_fine),
        "ios": _parse_ios_ui(),
        "android": _parse_android_ui(),
        "windows": _parse_windows_ui(),
    }
    all_fields = set(per_platform["macos"])
    for plat in PLATFORMS[1:]:
        assert set(per_platform[plat]) == all_fields, f"UI field mismatch on {plat}: {set(per_platform[plat]) ^ all_fields}"
    return {fid: {plat: per_platform[plat][fid] for plat in PLATFORMS} for fid in all_fields}


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
        """Summary pins plus one-way derived⊆declared divergence check.

        `missing` derives from cross-end model supported/modes, UI exposed,
        UI modes, and channel-shape differences; every derived category must
        be declared in the field's divergence.categories.
        """
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
                ui0 = entry["ui"][PLATFORMS[0]]
                if any(entry["ui"][p]["exposed"] != ui0["exposed"] for p in PLATFORMS[1:]):
                    derived.add("missing")
                if any(entry["ui"][p]["modes"] != ui0["modes"] for p in PLATFORMS[1:]):
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
                if fid.startswith("effects.") and fid not in ("effects.clarity", "effects.dehaze"):
                    self.assertEqual(
                        div.get("notes"),
                        "Desktop UI step 0.1 vs mobile 1; iOS SDR PhotoEffectsSettings clamps via"
                        " rounded() and IOSAdjustmentTransfer.prepare rejects fractional values as"
                        " unrepresentable (while HDRPhotoEffectsSettings preserves decimals).",
                        f"{fid} notes must state iOS-SDR-only integer quantization with HDR keeping decimals",
                    )

    def test_apple_shared_protocol_source_is_linked_by_macos_and_ios(self):
        mac_build = _read("RawLabMac/build.sh")
        ios_pbxproj = _read("RawLab/RawLab.xcodeproj/project.pbxproj")
        self.assertIn('"$ROOT"/Shared/*.swift', mac_build)
        self.assertIn('"$ROOT"/Shared/Native/*.swift', mac_build)
        for rel_shared in (
            "../Shared/AdjustmentTransfer.swift",
            "../Shared/HDRSettings.swift",
            "../Shared/HDRAdjustmentTransfer.swift",
            "../Shared/Native/HDRMonitoring.swift",
            "../Shared/GeometrySettings.swift",
            "../Shared/ToneControlsSettings.swift",
            "../Shared/AtmosphereSettings.swift",
            "../Shared/HSLSettings.swift",
            "../Shared/ColorGradingSettings.swift",
            "../Shared/ToneCurveSettings.swift",
        ):
            name = Path(rel_shared).name
            self.assertIn(rel_shared, ios_pbxproj)
            self.assertIn(f"{name} in Sources", ios_pbxproj)

    def test_unanchored_skips_are_explicit(self):
        src = Path(__file__).read_text(encoding="utf-8")
        self.assertNotIn("_snap" + "4", src)
        self.assertNotIn("SNAPSHOT_" + "REGISTRATIONS", src)
        for key, reason in UNANCHORED_SKIPS.items():
            self.assertEqual(len(key), 4)
            layer, fid, plat, attr = key
            self.assertIn(layer, ("proto", "model", "ui"))
            self.assertIn(plat, PLATFORMS)
            self.assertTrue(isinstance(reason, str) and reason.strip(), f"Empty skip reason for {key}")
        self.assertEqual(
            UNANCHORED_SKIPS,
            {},
            f"Unexpected unanchored skips registered: {UNANCHORED_SKIPS}",
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

        # 7. Real source-mutation anchors (in-memory _read patch -> must fail validation)
        from unittest import mock

        orig_read = _read

        def _mutated_reader(rel_path: str, old: str, new: str):
            def _reader(path: str) -> str:
                txt = orig_read(path)
                if path == rel_path:
                    self.assertIn(old, txt, f"Test bug: {old!r} not in {path}")
                    return txt.replace(old, new, 1)
                return txt
            return _reader

        # 7a. RawSettings.swift vignetteMidpointRange -> Layer 2 & Layer 3 fail on iOS only
        with mock.patch(
            f"{__name__}._read",
            side_effect=_mutated_reader(
                "RawLab/RawLab/Core/Models/RawSettings.swift",
                "static let vignetteMidpointRange: ClosedRange<Double> = 0...100",
                "static let vignetteMidpointRange: ClosedRange<Double> = 1...99",
            ),
        ):
            mut_models = parse_models_from_sources()
            mut_ui = parse_ui_from_sources()
            with self.assertRaisesRegex(AssertionError, r"effects\.vignette\.midpoint\.ios"):
                validate_layer2_model(self.document, mut_models)
            with self.assertRaisesRegex(AssertionError, r"effects\.vignette\.midpoint\.ios"):
                validate_layer3_ui(self.document, mut_ui)

        # 7b. AdjustmentKind.swift .highlights range -> Layer 3 fails on iOS
        with mock.patch(
            f"{__name__}._read",
            side_effect=_mutated_reader(
                "RawLab/RawLab/Core/Models/AdjustmentKind.swift",
                "case .highlights:\n            return -100...100",
                "case .highlights:\n            return -50...50",
            ),
        ):
            mut_ui = parse_ui_from_sources()
            with self.assertRaisesRegex(AssertionError, r"light\.highlights\.ios"):
                validate_layer3_ui(self.document, mut_ui)

        # 7c. Android EditSettings.kt PhotoEffectParameter bound -> Layer 2 & Layer 3 fail on Android only
        with mock.patch(
            f"{__name__}._read",
            side_effect=_mutated_reader(
                "RawLabAndroid/app/src/main/java/com/rawlab/android/settings/EditSettings.kt",
                "VIGNETTE_MIDPOINT(true, 0f..100f, 50f)",
                "VIGNETTE_MIDPOINT(true, 10f..90f, 50f)",
            ),
        ):
            mut_models = parse_models_from_sources()
            mut_ui = parse_ui_from_sources()
            with self.assertRaisesRegex(AssertionError, r"effects\.vignette\.midpoint\.android"):
                validate_layer2_model(self.document, mut_models)
            with self.assertRaisesRegex(AssertionError, r"effects\.vignette\.midpoint\.android"):
                validate_layer3_ui(self.document, mut_ui)

        # 7d. Windows PhotoEffectsSettings.cs VignetteMidpoint bound -> Layer 2 & Layer 3 fail on Windows only
        with mock.patch(
            f"{__name__}._read",
            side_effect=_mutated_reader(
                "RawLabWindows/PhotoEffectsSettings.cs",
                'new(PhotoEffectParameter.VignetteMidpoint, Loc.Text("中点"), true, 0, 100, 50)',
                'new(PhotoEffectParameter.VignetteMidpoint, Loc.Text("中点"), true, 10, 90, 50)',
            ),
        ):
            mut_models = parse_models_from_sources()
            mut_ui = parse_ui_from_sources()
            with self.assertRaisesRegex(AssertionError, r"effects\.vignette\.midpoint\.windows"):
                validate_layer2_model(self.document, mut_models)
            with self.assertRaisesRegex(AssertionError, r"effects\.vignette\.midpoint\.windows"):
                validate_layer3_ui(self.document, mut_ui)


if __name__ == "__main__":
    unittest.main()
