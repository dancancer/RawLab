from contextlib import contextmanager
import json
import math
import os
from pathlib import Path
import sys
import tempfile
import time
from typing import Any
import unicodedata
import uuid

from .errors import AdapterError

if os.name == "nt":
    import msvcrt
else:
    import fcntl


# Matches AdjustmentPreset.nameWhitespace in AdjustmentPresetStore.swift & AdjustmentPresetStore.cs
_PRESET_WHITESPACE_CHARS = (
    "\u0009\u000A\u000B\u000C\u000D\u0020\u0085\u00A0\u1680"
    "\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200A\u200B"
    "\u2028\u2029\u202F\u205F\u3000"
)

_SWIFT_REFERENCE_EPOCH_OFFSET = 978307200  # 2001-01-01T00:00:00Z

BUNDLED_TRANSFER_SPEC_PATH = Path(__file__).resolve().with_name("transfer_spec.json")


def _discover_repo_spec_path() -> Path | None:
    env_repo = os.environ.get("RAWLAB_REPO")
    candidates: list[Path] = []
    if env_repo:
        candidates.append(Path(env_repo))
    here = Path(__file__).resolve()
    if len(here.parents) >= 5:
        candidates.append(here.parents[4])
    for candidate in candidates:
        spec_file = candidate / "Shared" / "specs" / "adjustment-fields-v1.json"
        if spec_file.is_file():
            return spec_file
    return None


def _load_transfer_spec() -> dict[str, dict[str, Any]]:
    repo_spec = _discover_repo_spec_path()
    if repo_spec is not None:
        raw = json.loads(repo_spec.read_text(encoding="utf-8"))
        fields: dict[str, dict[str, Any]] = {}
        for entry in raw.get("fields", []):
            proto = entry.get("protocol", {})
            if proto.get("transferable"):
                fields[entry["field_id"]] = {
                    "value_type": proto["value_type"],
                    "nullable": bool(proto["nullable"]),
                    "min": proto["min"],
                    "max": proto["max"],
                    "exclusive_min": bool(proto.get("exclusive_min", False)),
                    "exclusive_max": bool(proto.get("exclusive_max", False)),
                    "non_empty": bool(proto.get("non_empty", False)),
                    "allowed_values": proto.get("allowed_values"),
                    "object_keys": proto.get("object_keys"),
                    "optional_keys": proto.get("optional_keys"),
                    "hdr_only": bool(proto.get("hdr_only", False)),
                    "sub_fields": proto.get("sub_fields"),
                }
        return fields
    bundled = json.loads(BUNDLED_TRANSFER_SPEC_PATH.read_text(encoding="utf-8"))
    return bundled["fields"]


_TRANSFER_FIELDS: dict[str, dict[str, Any]] = _load_transfer_spec()

_HSL_CHANNELS = ("red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta")

_GRADING_WHEEL_FIELDS = {
    "color.grading.shadows",
    "color.grading.midtones",
    "color.grading.highlights",
    "color.grading.global",
}

_HDR_COMMON = {
    "light.exposure",
    "light.contrast",
    "light.highlights",
    "light.shadows",
    "color.saturation",
    "hdr.relative_temperature",
    "hdr.relative_tint",
}
_HDR_GEOMETRY = {
    "geometry.crop.x",
    "geometry.crop.y",
    "geometry.crop.width",
    "geometry.crop.height",
    "geometry.quarter_turns",
    "geometry.flip_horizontal",
    "geometry.flip_vertical",
    "geometry.straighten_degrees",
    "geometry.perspective.horizontal",
    "geometry.perspective.vertical",
}
_HDR_TONE = {"tone.black_point", "tone.white_point", "light.s_curve", "light.curve"}
_HDR_COLOR = {
    "color.vibrance",
    "color.grading.shadows",
    "color.grading.midtones",
    "color.grading.highlights",
    *(f"color.hsl.{axis}.{ch}" for axis in ("hue", "saturation", "lightness") for ch in _HSL_CHANNELS),
}
_HDR_RENDITION = {"hdr.peak_limit_ev", "hdr.sdr_exposure_ev", "hdr.sdr_contrast", "hdr.sdr_saturation"}
_HDR_EFFECTS = {
    "effects.vignette.amount",
    "effects.vignette.midpoint",
    "effects.vignette.roundness",
    "effects.vignette.feather",
    "effects.vignette.highlights",
    "effects.grain.amount",
    "effects.grain.size",
    "effects.grain.roughness",
}
_HDR_DETAIL = {"detail.sharpening", "effects.clarity", "effects.dehaze", "detail.denoise.post_rgb"}
_HDR_V9_EXTENSIONS = {
    "light.curve.apply_to_luminosity",
    "light.curve.parametric",
    "color.grading.global",
    "color.grading.blending",
    "color.grading.balance",
}


def _hdr_supported_fields(version: int) -> set[str]:
    supported = set(_HDR_COMMON) | _HDR_GEOMETRY
    if version >= 2:
        supported |= _HDR_TONE
    if version >= 3:
        supported |= _HDR_COLOR
    if version >= 4:
        supported |= _HDR_RENDITION
    if version >= 5:
        supported |= _HDR_EFFECTS
    if version >= 6:
        supported |= _HDR_DETAIL
    if version >= 7:
        supported.add("hdr.look")
    if version >= 9:
        supported |= _HDR_V9_EXTENSIONS
    supported.add("hdr.camera_development")
    return supported


def normalize_preset_name(name: str) -> str:
    if not isinstance(name, str):
        raise AdapterError("Preset name must be a string")
    return unicodedata.normalize("NFC", name.strip(_PRESET_WHITESPACE_CHARS))


def resolve_controlled_subpath(data_dir: Path, subdir: str, filename: str) -> Path:
    if not subdir or "/" in subdir or "\\" in subdir or subdir in (".", ".."):
        raise AdapterError("Invalid controlled subdirectory")
    if not filename or "/" in filename or "\\" in filename or filename in (".", ".."):
        raise AdapterError("Invalid controlled filename")

    canonical_root = Path(os.path.realpath(data_dir))
    if canonical_root.exists() and not canonical_root.is_dir():
        raise AdapterError("Controlled data_dir must be a directory")

    target_dir = canonical_root / subdir
    if os.path.lexists(target_dir):
        if target_dir.is_symlink():
            raise AdapterError(f"Controlled directory '{subdir}' cannot be a symbolic link")
        if not target_dir.is_dir():
            raise AdapterError(f"Controlled directory '{subdir}' is not a directory")
        if Path(os.path.realpath(target_dir)) != canonical_root / subdir:
            raise AdapterError(f"Controlled directory '{subdir}' escaped data_dir")

    target_file = target_dir / filename
    if os.path.lexists(target_file):
        if target_file.is_symlink():
            raise AdapterError(f"Controlled store '{filename}' cannot be a symbolic link")
        if not target_file.is_file():
            raise AdapterError(f"Controlled store '{filename}' is not a regular file")
        if Path(os.path.realpath(target_file)) != canonical_root / subdir / filename:
            raise AdapterError(f"Controlled store '{filename}' escaped data_dir")

    return target_file


@contextmanager
def _store_lock(lock_path: Path):
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    if os.path.lexists(lock_path) and lock_path.is_symlink():
        raise AdapterError("Lock file cannot be a symbolic link")
    with open(lock_path, "a+", encoding="utf-8") as handle:
        if os.name == "nt":
            deadline = time.monotonic() + 5.0
            locked = False
            while True:
                try:
                    handle.seek(0)
                    msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                    locked = True
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise AdapterError("Timed out waiting for store lock", "output_io_error")
                    time.sleep(0.01)
            try:
                yield
            finally:
                if locked:
                    try:
                        handle.seek(0)
                        msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
                    except OSError:
                        pass
        else:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def atomic_write_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        deadline = time.monotonic() + 2.0
        while True:
            try:
                os.replace(tmp_name, path)
                return
            except OSError as error:
                winerr = getattr(error, "winerror", None)
                if os.name == "nt" and winerr in (5, 32, 33) and time.monotonic() < deadline:
                    time.sleep(0.01)
                    continue
                raise
    except Exception:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)
        raise


def _is_finite_number(val: Any) -> bool:
    return isinstance(val, (int, float)) and type(val) is not bool and math.isfinite(float(val))


def _has_control_chars(value: str) -> bool:
    return any(ord(ch) < 0x20 or 0x7F <= ord(ch) <= 0x9F for ch in value)


def _is_canonical_uuid(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    try:
        return str(uuid.UUID(value)).lower() == value
    except ValueError:
        return False


def _validate_tone_curve_shape(obj: Any, *, field_name: str) -> dict[str, Any]:
    if not isinstance(obj, dict) or set(obj.keys()) != {"mode", "points"}:
        raise AdapterError(f"{field_name} must contain exactly mode and points")
    mode = obj["mode"]
    if mode not in ("legacy", "custom"):
        raise AdapterError(f"{field_name}.mode must be legacy or custom")
    points = obj["points"]
    if not isinstance(points, list):
        raise AdapterError(f"{field_name}.points must be an array")
    if mode == "legacy":
        if len(points) != 0:
            raise AdapterError(f"{field_name}.points must be empty when mode is legacy")
        return {"mode": "legacy", "points": []}
    if not (2 <= len(points) <= 33):
        raise AdapterError(f"{field_name}.points must contain 2..33 points when mode is custom")
    out_points: list[list[float]] = []
    for idx, pt in enumerate(points):
        if not isinstance(pt, list) or len(pt) != 2 or not _is_finite_number(pt[0]) or not _is_finite_number(pt[1]):
            raise AdapterError(f"{field_name}.points[{idx}] must be [x, y]")
        x, y = float(pt[0]), float(pt[1])
        if not (0.0 <= x <= 1.0 and 0.0 <= y <= 1.0):
            raise AdapterError(f"{field_name}.points[{idx}] coordinates must be in [0, 1]")
        if idx > 0:
            prev_x, prev_y = out_points[idx - 1]
            if x <= prev_x:
                raise AdapterError(f"{field_name}.points x values must be strictly increasing")
            if y < prev_y:
                raise AdapterError(f"{field_name}.points y values must be non-decreasing")
        out_points.append([x, y])
    if out_points[0][0] != 0.0 or out_points[-1][0] != 1.0:
        raise AdapterError(f"{field_name}.points must start at x=0 and end at x=1")
    return {"mode": "custom", "points": out_points}


def _validate_parametric_curve(p_in: Any, *, field_name: str) -> dict[str, float]:
    sub = _TRANSFER_FIELDS["light.curve.parametric"]["sub_fields"]
    expected_keys = set(_TRANSFER_FIELDS["light.curve.parametric"]["object_keys"])
    if not isinstance(p_in, dict) or set(p_in.keys()) != expected_keys:
        raise AdapterError(
            f"{field_name} must contain exactly {', '.join(sorted(expected_keys))}"
        )
    out: dict[str, float] = {}
    for k in expected_keys:
        v = p_in[k]
        lo = float(sub[k]["min"])
        hi = float(sub[k]["max"])
        if not _is_finite_number(v) or not (lo <= float(v) <= hi):
            raise AdapterError(f"{field_name}.{k} must be in [{lo}, {hi}]")
        out[k] = float(v)
    gap = float(sub["split_min_gap"])
    if out["split_shadow"] + gap > out["split_midtone"] or out["split_midtone"] + gap > out["split_highlight"]:
        raise AdapterError(
            f"{field_name} split points must maintain at least {gap} separation"
        )
    return out


def _validate_grading_wheel(val: Any, *, field_name: str) -> dict[str, float]:
    proto = _TRANSFER_FIELDS["color.grading.shadows"]
    req_keys = set(proto["object_keys"])
    opt_keys = set(proto.get("optional_keys") or [])
    sub = proto["sub_fields"]
    if not isinstance(val, dict) or not req_keys.issubset(val.keys()):
        raise AdapterError(f"{field_name} must be a grading wheel object")
    if not set(val.keys()).issubset(req_keys | opt_keys):
        raise AdapterError(f"{field_name} contains unexpected keys")
    hue, sat = val["hue"], val["saturation"]
    hue_min, hue_max = float(sub["hue"]["min"]), float(sub["hue"]["max"])
    if not _is_finite_number(hue) or not (hue_min <= float(hue) < hue_max):
        raise AdapterError(f"{field_name}.hue must be in [{hue_min}, {hue_max})")
    sat_min, sat_max = float(sub["saturation"]["min"]), float(sub["saturation"]["max"])
    if not _is_finite_number(sat) or not (sat_min <= float(sat) <= sat_max):
        raise AdapterError(f"{field_name}.saturation must be in [{sat_min}, {sat_max}]")
    lum = 0.0
    if "luminance" in val:
        lum_in = val["luminance"]
        lum_min, lum_max = float(sub["luminance"]["min"]), float(sub["luminance"]["max"])
        if not _is_finite_number(lum_in) or not (lum_min <= float(lum_in) <= lum_max):
            raise AdapterError(f"{field_name}.luminance must be in [{lum_min}, {lum_max}]")
        lum = float(lum_in)
    return {"hue": float(hue), "saturation": float(sat), "luminance": lum}


def _validate_scalar_against_proto(key: str, val: Any, proto: dict[str, Any]) -> None:
    vtype = proto["value_type"]
    if vtype == "boolean":
        if type(val) is not bool:
            raise AdapterError(f"Field '{key}' must be a boolean")
        return
    if vtype == "integer":
        if type(val) is not int:
            raise AdapterError(f"Field '{key}' must be an integer")
        if proto["min"] is not None and val < int(proto["min"]):
            raise AdapterError(f"Field '{key}' below minimum {proto['min']}")
        if proto["max"] is not None and val > int(proto["max"]):
            raise AdapterError(f"Field '{key}' exceeds maximum {proto['max']}")
        if proto.get("allowed_values") is not None and val not in proto["allowed_values"]:
            raise AdapterError(f"Field '{key}' has invalid integer enum value")
        return
    if vtype == "number":
        if not _is_finite_number(val):
            raise AdapterError(f"Field '{key}' must be a finite number")
        num = float(val)
        lo = proto["min"]
        hi = proto["max"]
        if lo is not None:
            if proto["exclusive_min"]:
                if not (num > float(lo)):
                    raise AdapterError(f"Field '{key}' must be > {lo}")
            elif num < float(lo):
                raise AdapterError(f"Field '{key}' must be >= {lo}")
        if hi is not None:
            if proto["exclusive_max"]:
                if not (num < float(hi)):
                    raise AdapterError(f"Field '{key}' must be < {hi}")
            elif num > float(hi):
                raise AdapterError(f"Field '{key}' must be <= {hi}")
        return
    if vtype == "string":
        if not isinstance(val, str):
            raise AdapterError(f"Field '{key}' must be a string")
        if proto.get("non_empty") and not val:
            raise AdapterError(f"Field '{key}' must be nonempty")
        if proto.get("allowed_values") is not None and val not in proto["allowed_values"]:
            raise AdapterError(f"Field '{key}' has invalid enum value")
        return
    raise AdapterError(f"Unsupported value_type '{vtype}' for field '{key}'")


def validate_transfer_values(
    values: dict[str, Any],
    *,
    is_hdr: bool,
    hdr_processing_version: int | None = None,
    is_raw: bool | None = None,
    recipe_context: dict[str, Any] | None = None,
) -> None:
    if not isinstance(values, dict) or not values:
        raise AdapterError("Preset values must be a non-empty dictionary")

    if is_hdr:
        if is_raw is True:
            raise AdapterError("HDR presets require is_raw=False")
        if recipe_context is not None:
            raise AdapterError("HDR presets cannot include recipe_context")
        if hdr_processing_version is not None:
            allowed_hdr = _hdr_supported_fields(hdr_processing_version)
            disallowed = set(values.keys()) - allowed_hdr
            unknown = disallowed - set(_TRANSFER_FIELDS.keys())
            if unknown:
                raise AdapterError(f"Unknown adjustment transfer field: {sorted(unknown)[0]}")
            if disallowed:
                raise AdapterError(
                    f"Fields {sorted(disallowed)} are not supported in hdr_processing_version={hdr_processing_version}"
                )

    for key, val in values.items():
        if not isinstance(key, str):
            raise AdapterError("Field keys must be strings")
        proto = _TRANSFER_FIELDS.get(key)
        if proto is None:
            raise AdapterError(f"Unknown adjustment transfer field: {key}")
        if proto["hdr_only"] and not is_hdr:
            raise AdapterError(f"HDR field '{key}' requires hdr_processing_version")
        if val is None:
            if proto["nullable"]:
                continue
            raise AdapterError(f"Field '{key}' is not nullable")

        if key in _GRADING_WHEEL_FIELDS:
            _validate_grading_wheel(val, field_name=key)
        elif key == "looks.reference":
            sub = proto["sub_fields"]
            if not isinstance(val, dict) or set(val.keys()) != set(proto["object_keys"]):
                raise AdapterError("looks.reference must contain exactly kind and id")
            kind, ref_id = val["kind"], val["id"]
            if not isinstance(kind, str) or kind not in sub["kind"]["allowed_values"]:
                raise AdapterError("Invalid looks.reference.kind")
            if kind == sub["id"]["nullable_when_kind"]:
                if ref_id is not None:
                    raise AdapterError("looks.reference.id must be null when kind is neutral")
            elif (
                not isinstance(ref_id, str)
                or not ref_id
                or ref_id in {".", ".."}
                or "/" in ref_id
                or "\\" in ref_id
            ):
                raise AdapterError("Invalid looks.reference.id")
        elif key == "light.curve":
            if not isinstance(val, dict) or not {"mode", "points"}.issubset(val.keys()):
                raise AdapterError("light.curve must include mode and points")
            if not set(val.keys()).issubset({"mode", "points", "channels"}):
                raise AdapterError("light.curve contains unexpected keys")
            _validate_tone_curve_shape(
                {"mode": val["mode"], "points": val["points"]},
                field_name="light.curve",
            )
            if "channels" in val:
                ch = val["channels"]
                if not isinstance(ch, dict):
                    raise AdapterError("light.curve.channels must be an object")
                allowed_ch = set(proto["sub_fields"]["channels"]["allowed_keys"])
                if not set(ch.keys()).issubset(allowed_ch):
                    raise AdapterError("light.curve.channels keys must be a subset of red, green, blue")
                for c_name, c_shape in ch.items():
                    _validate_tone_curve_shape(c_shape, field_name=f"light.curve.channels.{c_name}")
        elif key == "light.curve.parametric":
            _validate_parametric_curve(val, field_name="light.curve.parametric")
        elif key == "detail.denoise.wavelet":
            sub = proto["sub_fields"]
            if not isinstance(val, dict) or set(val.keys()) != set(proto["object_keys"]):
                raise AdapterError("detail.denoise.wavelet has invalid keys")
            if type(val["enabled"]) is not bool or val["preset"] not in sub["preset"]["allowed_values"]:
                raise AdapterError("Invalid detail.denoise.wavelet flags")
            for k in ("luma", "chroma", "coarse"):
                lo, hi = float(sub[k]["min"]), float(sub[k]["max"])
                if not _is_finite_number(val[k]) or not (lo <= float(val[k]) <= hi):
                    raise AdapterError(f"detail.denoise.wavelet.{k} must be in [{lo}, {hi}]")
        elif key == "hdr.look":
            sub = proto["sub_fields"]
            if not isinstance(val, dict) or set(val.keys()) != set(proto["object_keys"]):
                raise AdapterError("hdr.look must contain sha256, name, strength")
            sha = val["sha256"]
            hex_len = int(sub["sha256"]["hex_length"])
            if not isinstance(sha, str) or len(sha) != hex_len or any(c not in "0123456789abcdef" for c in sha):
                raise AdapterError("hdr.look.sha256 must be 64 lowercase hex characters")
            name_val = val["name"]
            if not isinstance(name_val, str) or _has_control_chars(name_val):
                raise AdapterError("hdr.look.name must be a valid string without control characters")
            name_bytes = len(name_val.encode("utf-8"))
            if not (int(sub["name"]["min_utf8_bytes"]) <= name_bytes <= int(sub["name"]["max_utf8_bytes"])):
                raise AdapterError("hdr.look.name UTF-8 byte length out of range")
            s_lo, s_hi = float(sub["strength"]["min"]), float(sub["strength"]["max"])
            if not _is_finite_number(val["strength"]) or not (s_lo <= float(val["strength"]) <= s_hi):
                raise AdapterError(f"hdr.look.strength must be in [{s_lo}, {s_hi}]")
        elif key == "hdr.camera_development":
            sub = proto["sub_fields"]
            if not isinstance(val, dict) or set(val.keys()) != set(proto["object_keys"]):
                raise AdapterError("hdr.camera_development has invalid keys")
            if type(val["version"]) is not int or val["version"] not in sub["version"]["allowed_values"]:
                raise AdapterError("hdr.camera_development has invalid version")
            wb_mode = val["white_balance_mode"]
            if not isinstance(wb_mode, str) or wb_mode not in sub["white_balance_mode"]["allowed_values"]:
                raise AdapterError("hdr.camera_development has invalid white_balance_mode")
            exp_ref = val["exposure_reference"]
            if not isinstance(exp_ref, str) or exp_ref not in sub["exposure_reference"]["allowed_values"]:
                raise AdapterError("hdr.camera_development has invalid exposure_reference")
            if type(val["fbdd_level"]) is not int or val["fbdd_level"] not in sub["fbdd_level"]["allowed_values"]:
                raise AdapterError("hdr.camera_development has invalid fbdd_level")
            if not _is_finite_number(val["temperature"]) or not _is_finite_number(val["tint"]):
                raise AdapterError("hdr.camera_development temperature and tint must be finite numbers")
            temp_val = float(val["temperature"])
            tint_val = float(val["tint"])
            if wb_mode == "as_shot":
                if (
                    temp_val != float(sub["temperature"]["as_shot_value"])
                    or tint_val != float(sub["tint"]["as_shot_value"])
                ):
                    raise AdapterError("hdr.camera_development temperature and tint must be 0.0 when white_balance_mode is as_shot")
            else:
                t_lo, t_hi = float(sub["temperature"]["temperature_min"]), float(sub["temperature"]["temperature_max"])
                ti_lo, ti_hi = float(sub["tint"]["temperature_min"]), float(sub["tint"]["temperature_max"])
                if not (t_lo <= temp_val <= t_hi):
                    raise AdapterError("hdr.camera_development.temperature out of range")
                if not (ti_lo <= tint_val <= ti_hi):
                    raise AdapterError("hdr.camera_development.tint out of range")
        else:
            _validate_scalar_against_proto(key, val, proto)

    if recipe_context is not None:
        if "looks.strength" in values and float(values["looks.strength"]) != float(recipe_context["strength"]):
            raise AdapterError("looks.strength must match recipe_context.strength")
        look_val = values.get("looks.reference")
        if isinstance(look_val, dict) and look_val.get("kind") == "recipe" and look_val.get("id") != recipe_context["id"]:
            raise AdapterError("looks.reference.id must match recipe_context.id")

    if is_raw is not None and not is_hdr:
        if not is_raw:
            if "light.exposure_mode" in values and values["light.exposure_mode"] != "sensor":
                raise AdapterError("Raster SDR presets require light.exposure_mode == 'sensor'")
            if "detail.denoise.raw_level" in values and values["detail.denoise.raw_level"] != 0:
                raise AdapterError("Raster SDR presets require detail.denoise.raw_level == 0")
            if "detail.denoise.post_rgb" in values and float(values["detail.denoise.post_rgb"]) != 0.0:
                raise AdapterError("Raster SDR presets require detail.denoise.post_rgb == 0")

        wb_mode = values.get("color.white_balance.mode")
        wb_temp = values.get("color.white_balance.temperature_kelvin")
        wb_tint = values.get("color.white_balance.tint")
        if wb_mode is not None:
            if is_raw and wb_mode == "none":
                raise AdapterError("RAW presets cannot use color.white_balance.mode == 'none'")
            if not is_raw and wb_mode in ("camera", "temperature"):
                raise AdapterError("Raster presets cannot use camera or temperature white_balance.mode")
        if not is_raw and wb_mode != "relative":
            if wb_temp is not None or (recipe_context is None and wb_tint is not None):
                raise AdapterError("Raster presets without relative WB cannot specify temperature_kelvin or tint")
        if recipe_context is not None and "color.white_balance.tint" in values and wb_tint is None:
            raise AdapterError("Recipe presets cannot set color.white_balance.tint to null")
        if wb_mode == "camera" and (wb_temp is not None or (recipe_context is None and wb_tint is not None)):
            raise AdapterError("Camera white balance conflicts with temperature_kelvin or tint")
        if wb_mode == "temperature" and (wb_temp is None or wb_tint is None):
            raise AdapterError("Temperature white balance requires non-null temperature_kelvin and tint")


class _StrictJSONScanner:
    """Matches PresetJSONScanner.swift: strict JSON syntax, byte slice bounds, duplicate-key & integer-literal tracking."""

    def __init__(self, data: bytes) -> None:
        self.data = data
        self.n = len(data)
        self.idx = 0

    def _skip_ws(self) -> None:
        data, n, i = self.data, self.n, self.idx
        while i < n and data[i] in (9, 10, 13, 32):
            i += 1
        self.idx = i

    @staticmethod
    def is_integer_literal(literal: str) -> bool:
        if not literal:
            return False
        digits = literal[1:] if literal[0] == "-" else literal
        return bool(digits) and all("0" <= c <= "9" for c in digits)

    def scan_root(self) -> tuple[str, int, int, bool, bool, Any]:
        node = self._parse(depth=0)
        self._skip_ws()
        if self.idx != self.n:
            raise ValueError("Trailing content in JSON")
        return node

    def _parse(self, depth: int) -> tuple[str, int, int, bool, bool, Any]:
        if depth > 64:
            raise ValueError("JSON nesting depth exceeded")
        self._skip_ws()
        if self.idx >= self.n:
            raise ValueError("Unexpected end of JSON")
        start = self.idx
        b = self.data[self.idx]
        if b == 0x7B:  # '{'
            self.idx += 1
            members: list[tuple[str, Any]] = []
            seen: set[str] = set()
            own_dup = False
            nested_dup = False
            self._skip_ws()
            if self.idx < self.n and self.data[self.idx] == 0x7D:
                self.idx += 1
                return ("object", start, self.idx, False, False, members)
            while True:
                self._skip_ws()
                if self.idx >= self.n or self.data[self.idx] != 0x22:
                    raise ValueError("Expected string key")
                key = self._parse_string()
                self._skip_ws()
                if self.idx >= self.n or self.data[self.idx] != 0x3A:
                    raise ValueError("Expected ':'")
                self.idx += 1
                val_node = self._parse(depth + 1)
                nested_dup = nested_dup or val_node[4]
                if key in seen:
                    own_dup = True
                else:
                    seen.add(key)
                members.append((key, val_node))
                self._skip_ws()
                if self.idx < self.n and self.data[self.idx] == 0x7D:
                    self.idx += 1
                    break
                if self.idx >= self.n or self.data[self.idx] != 0x2C:
                    raise ValueError("Expected ',' or '}'")
                self.idx += 1
            return ("object", start, self.idx, own_dup, own_dup or nested_dup, members)
        if b == 0x5B:  # '['
            self.idx += 1
            items: list[Any] = []
            nested_dup = False
            self._skip_ws()
            if self.idx < self.n and self.data[self.idx] == 0x5D:
                self.idx += 1
                return ("array", start, self.idx, False, False, items)
            while True:
                item = self._parse(depth + 1)
                nested_dup = nested_dup or item[4]
                items.append(item)
                self._skip_ws()
                if self.idx < self.n and self.data[self.idx] == 0x5D:
                    self.idx += 1
                    break
                if self.idx >= self.n or self.data[self.idx] != 0x2C:
                    raise ValueError("Expected ',' or ']'")
                self.idx += 1
            return ("array", start, self.idx, False, nested_dup, items)
        if b == 0x22:  # '"'
            s = self._parse_string()
            return ("string", start, self.idx, False, False, s)
        if b == 0x74 and self.data[start:start + 4] == b"true":
            self.idx = start + 4
            return ("boolean", start, self.idx, False, False, True)
        if b == 0x66 and self.data[start:start + 5] == b"false":
            self.idx = start + 5
            return ("boolean", start, self.idx, False, False, False)
        if b == 0x6E and self.data[start:start + 4] == b"null":
            self.idx = start + 4
            return ("null", start, self.idx, False, False, None)
        num_chars = b"-0123456789.eE+"
        while self.idx < self.n and self.data[self.idx] in num_chars:
            self.idx += 1
        literal = self.data[start:self.idx].decode("ascii")
        if not self._is_valid_json_number(literal):
            raise ValueError(f"Invalid JSON number: {literal!r}")
        return ("number", start, self.idx, False, False, literal)

    @staticmethod
    def _is_valid_json_number(literal: str) -> bool:
        i = 0
        n = len(literal)
        if i < n and literal[i] == "-":
            i += 1
        if i >= n or not ("0" <= literal[i] <= "9"):
            return False
        if literal[i] == "0":
            i += 1
            if i < n and ("0" <= literal[i] <= "9"):
                return False
        else:
            while i < n and ("0" <= literal[i] <= "9"):
                i += 1
        if i < n and literal[i] == ".":
            i += 1
            if i >= n or not ("0" <= literal[i] <= "9"):
                return False
            while i < n and ("0" <= literal[i] <= "9"):
                i += 1
        if i < n and literal[i] in ("e", "E"):
            i += 1
            if i < n and literal[i] in ("+", "-"):
                i += 1
            if i >= n or not ("0" <= literal[i] <= "9"):
                return False
            while i < n and ("0" <= literal[i] <= "9"):
                i += 1
        return i == n

    def _parse_string(self) -> str:
        self.idx += 1
        out: list[str] = []
        data, n = self.data, self.n
        while self.idx < n:
            b = data[self.idx]
            if b == 0x22:
                self.idx += 1
                return "".join(out)
            if b == 0x5C:
                self.idx += 1
                if self.idx >= n:
                    raise ValueError("Unterminated escape")
                esc = data[self.idx]
                self.idx += 1
                if esc == 0x22:
                    out.append('"')
                elif esc == 0x5C:
                    out.append("\\")
                elif esc == 0x2F:
                    out.append("/")
                elif esc == 0x62:
                    out.append("\b")
                elif esc == 0x66:
                    out.append("\f")
                elif esc == 0x6E:
                    out.append("\n")
                elif esc == 0x72:
                    out.append("\r")
                elif esc == 0x74:
                    out.append("\t")
                elif esc == 0x75:
                    if self.idx + 4 > n:
                        raise ValueError("Short \\u escape")
                    code = int(data[self.idx:self.idx + 4].decode("ascii"), 16)
                    self.idx += 4
                    if 0xD800 <= code <= 0xDBFF:
                        if self.idx + 6 > n or data[self.idx:self.idx + 2] != b"\\u":
                            raise ValueError("Missing low surrogate")
                        low = int(data[self.idx + 2:self.idx + 6].decode("ascii"), 16)
                        if not (0xDC00 <= low <= 0xDFFF):
                            raise ValueError("Invalid low surrogate")
                        self.idx += 6
                        out.append(chr(0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)))
                    elif 0xDC00 <= code <= 0xDFFF:
                        raise ValueError("Lone low surrogate")
                    else:
                        out.append(chr(code))
                else:
                    raise ValueError("Invalid escape")
            else:
                run_start = self.idx
                while self.idx < n and data[self.idx] not in (0x22, 0x5C):
                    if data[self.idx] < 0x20:
                        raise ValueError("Unescaped control char in string")
                    self.idx += 1
                out.append(data[run_start:self.idx].decode("utf-8"))
        raise ValueError("Unterminated JSON string")


def _timestamps_are_integers(node: tuple[str, int, int, bool, bool, Any]) -> bool:
    kind, _, _, _, _, payload = node
    if kind == "object":
        for key, child in payload:
            if key in ("created_at", "updated_at"):
                if child[0] != "number" or not _StrictJSONScanner.is_integer_literal(child[5]):
                    return False
            if not _timestamps_are_integers(child):
                return False
    elif kind == "array":
        for child in payload:
            if not _timestamps_are_integers(child):
                return False
    return True


def _validate_recipe_context(recipe_context: Any) -> None:
    if not isinstance(recipe_context, dict) or set(recipe_context.keys()) != {"id", "strength", "settings_version"}:
        raise AdapterError("recipe_context must contain id, strength, settings_version")
    if not isinstance(recipe_context["id"], str) or not recipe_context["id"]:
        raise AdapterError("recipe_context.id must be a nonempty string")
    if not _is_finite_number(recipe_context["strength"]) or not (0.0 <= float(recipe_context["strength"]) <= 2.0):
        raise AdapterError("recipe_context.strength must be in [0, 2]")
    if type(recipe_context["settings_version"]) is not int or recipe_context["settings_version"] not in (2, 3, 4):
        raise AdapterError("recipe_context.settings_version must be 2, 3, or 4")


def _is_canonical_preset_entry(entry: Any) -> bool:
    if not isinstance(entry, dict):
        return False
    if set(entry.keys()) != {"id", "name", "created_at", "updated_at", "payload"}:
        return False
    eid, ename = entry.get("id"), entry.get("name")
    cat, uat = entry.get("created_at"), entry.get("updated_at")
    payload = entry.get("payload")
    if not _is_canonical_uuid(eid) or not isinstance(ename, str) or not ename or normalize_preset_name(ename) != ename:
        return False
    if type(cat) is not int or type(uat) is not int or cat < 0 or uat < cat:
        return False
    if not isinstance(payload, dict):
        return False
    if set(payload.keys()) != {"payload_version", "scope_version", "source", "values"}:
        return False
    pv = payload.get("payload_version")
    sv = payload.get("scope_version")
    if type(pv) is not int or type(sv) is not int or pv not in (1, 2) or pv != sv:
        return False
    source = payload.get("source")
    if not isinstance(source, dict):
        return False
    allowed_source_keys = {"identifier", "is_raw", "processing_version", "recipe", "hdr_processing_version"}
    if not {"identifier", "is_raw", "processing_version"}.issubset(source.keys()):
        return False
    if not set(source.keys()).issubset(allowed_source_keys):
        return False
    if source.get("identifier") != f"preset:{eid}":
        return False
    is_raw = source.get("is_raw")
    proc_ver = source.get("processing_version")
    if type(is_raw) is not bool or type(proc_ver) is not int or proc_ver not in (1, 2, 3):
        return False
    hdr_ver = source.get("hdr_processing_version")
    if (pv == 2) != (hdr_ver is not None):
        return False
    if hdr_ver is not None and (type(hdr_ver) is not int or not (1 <= hdr_ver <= 9)):
        return False
    recipe_ctx = source.get("recipe")
    if recipe_ctx is not None:
        try:
            _validate_recipe_context(recipe_ctx)
        except AdapterError:
            return False
    values = payload.get("values")
    if not isinstance(values, dict) or not values:
        return False
    try:
        validate_transfer_values(
            values,
            is_hdr=(hdr_ver is not None),
            hdr_processing_version=hdr_ver,
            is_raw=is_raw,
            recipe_context=recipe_ctx,
        )
    except AdapterError:
        return False
    return True


def save_preset(
    *,
    data_dir: Path,
    name: str,
    values: dict[str, Any],
    is_raw: bool | None = None,
    processing_version: int = 3,
    overwrite: bool = False,
    recipe_context: dict[str, Any] | None = None,
    hdr_processing_version: int | None = None,
) -> dict[str, Any]:
    normalized_name = normalize_preset_name(name)
    if not normalized_name:
        raise AdapterError("Preset name cannot be empty")
    if hdr_processing_version is not None and (
        type(hdr_processing_version) is not int or not (1 <= hdr_processing_version <= 9)
    ):
        raise AdapterError("hdr_processing_version must be 1..9")
    if is_raw is None:
        effective_is_raw = hdr_processing_version is None
    elif type(is_raw) is not bool:
        raise AdapterError("is_raw must be a boolean")
    else:
        effective_is_raw = is_raw
    if type(processing_version) is not int or processing_version not in (1, 2, 3):
        raise AdapterError("processing_version must be 1, 2, or 3")
    if recipe_context is not None:
        _validate_recipe_context(recipe_context)

    is_hdr = hdr_processing_version is not None
    validate_transfer_values(
        values,
        is_hdr=is_hdr,
        hdr_processing_version=hdr_processing_version,
        is_raw=effective_is_raw,
        recipe_context=recipe_context,
    )

    presets_file = resolve_controlled_subpath(data_dir, "Presets", "presets.json")
    lock_name = "presets.json.lock" if os.name == "nt" else ".presets.lock"
    lock_file = resolve_controlled_subpath(data_dir, "Presets", lock_name)

    presets_file.parent.mkdir(parents=True, exist_ok=True)
    with _store_lock(lock_file):
        readable: list[dict[str, Any]] = []
        unreadable_items: list[tuple[str | None, str | None, bytes]] = []
        retired_ids: list[str] = []

        if presets_file.exists():
            try:
                raw_bytes = presets_file.read_bytes()
                root_node = _StrictJSONScanner(raw_bytes).scan_root()
            except (OSError, ValueError, UnicodeError) as e:
                raise AdapterError(f"Corrupt presets library: {e}", "output_io_error") from e

            if root_node[0] != "object" or root_node[3]:
                raise AdapterError("Unsupported or corrupt presets.json", "output_io_error")
            member_map = {k: child for k, child in root_node[5]}
            root_keys = set(member_map.keys())
            if not {"registry_version", "presets"}.issubset(root_keys) or not root_keys.issubset(
                {"registry_version", "presets", "retired_ids"}
            ):
                raise AdapterError("Corrupt presets.json root keys", "output_io_error")

            rv_node = member_map["registry_version"]
            if rv_node[0] != "number" or not _StrictJSONScanner.is_integer_literal(rv_node[5]) or int(rv_node[5]) != 1:
                raise AdapterError("Unsupported or corrupt presets.json", "output_io_error")

            presets_node = member_map["presets"]
            if presets_node[0] != "array":
                raise AdapterError("Unsupported or corrupt presets.json", "output_io_error")

            if "retired_ids" in member_map:
                retired_node = member_map["retired_ids"]
                if retired_node[0] != "array":
                    raise AdapterError("Corrupt presets.json retired_ids", "output_io_error")
                for item in retired_node[5]:
                    if item[0] != "string" or not _is_canonical_uuid(item[5]):
                        raise AdapterError("Corrupt presets.json retired_ids", "output_io_error")
                    retired_ids.append(item[5])
                if len(set(retired_ids)) != len(retired_ids):
                    raise AdapterError("Duplicate entries in presets.json retired_ids", "output_io_error")

            for element in presets_node[5]:
                el_start, el_end = element[1], element[2]
                raw_slice = raw_bytes[el_start:el_end]
                entry_id: str | None = None
                entry_name: str | None = None
                if element[0] == "object":
                    for mk, mv in element[5]:
                        if mk == "id" and mv[0] == "string" and entry_id is None:
                            entry_id = mv[5]
                        elif mk == "name" and mv[0] == "string" and entry_name is None:
                            entry_name = mv[5]
                parsed_entry: Any = None
                if element[0] == "object" and not element[4] and _timestamps_are_integers(element):
                    try:
                        parsed_entry = json.loads(raw_slice.decode("utf-8"))
                    except (ValueError, UnicodeError):
                        parsed_entry = None
                if parsed_entry is not None and _is_canonical_preset_entry(parsed_entry):
                    readable.append(parsed_entry)
                else:
                    unreadable_items.append((entry_id, entry_name, raw_slice))
                    if entry_name == normalized_name:
                        raise AdapterError(f"Preset name conflicts with an unreadable future entry: {normalized_name}")

            readable_ids = [p["id"] for p in readable]
            readable_names = [p["name"] for p in readable]
            if (
                len(set(readable_ids)) != len(readable_ids)
                or len(set(readable_names)) != len(readable_names)
                or any(pid in retired_ids for pid in readable_ids)
            ):
                raise AdapterError("Corrupt presets.json identity collision", "output_io_error")

        existing_ids = {p["id"] for p in readable} | {
            uid for uid, _, _ in unreadable_items if uid is not None
        }
        retired_set = set(retired_ids)
        now_ms = int(time.time() * 1000)

        existing = next((p for p in readable if p["name"] == normalized_name), None)
        if existing is not None:
            if not overwrite:
                raise AdapterError(f"Preset '{normalized_name}' already exists; pass overwrite=true to update")
            pid = existing["id"]
            created_at = int(existing["created_at"])
            updated_at = max(now_ms, int(existing["updated_at"]) + 1)
            action = "updated"
        else:
            pid = str(uuid.uuid4()).lower()
            while pid in existing_ids or pid in retired_set:
                pid = str(uuid.uuid4()).lower()
            created_at = now_ms
            updated_at = now_ms
            action = "created"

        source: dict[str, Any] = {
            "identifier": f"preset:{pid}",
            "is_raw": bool(effective_is_raw),
            "processing_version": int(processing_version),
            "recipe": recipe_context,
        }
        if hdr_processing_version is not None:
            source["hdr_processing_version"] = int(hdr_processing_version)
        payload_ver = 2 if is_hdr else 1
        preset_entry = {
            "id": pid,
            "name": normalized_name,
            "created_at": created_at,
            "updated_at": updated_at,
            "payload": {
                "payload_version": payload_ver,
                "scope_version": payload_ver,
                "source": source,
                "values": values,
            },
        }

        if existing is not None:
            readable = [preset_entry if p["id"] == pid else p for p in readable]
        else:
            readable.append(preset_entry)

        pieces: list[bytes] = [
            json.dumps(p, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
            for p in readable
        ]
        for _, _, raw_slice in unreadable_items:
            pieces.append(raw_slice)
        retired_bytes = json.dumps(retired_ids, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        encoded = (
            b'{"presets":['
            + b",".join(pieces)
            + b'],"registry_version":1,"retired_ids":'
            + retired_bytes
            + b"}"
        )
        atomic_write_bytes(presets_file, encoded)

    return {
        "action": action,
        "id": pid,
        "name": normalized_name,
        "presets_file": str(presets_file),
    }


def _mac_foundation_canonical_path(photo_path: Path) -> str:
    real = os.path.realpath(photo_path)
    if sys.platform == "darwin":
        for prefix in ("/private/tmp", "/private/var", "/private/etc"):
            if real == prefix or real.startswith(prefix + "/"):
                return real[len("/private"):]
    return real


def _swift_identity_for_file(photo_path: Path) -> dict[str, Any]:
    real = _mac_foundation_canonical_path(photo_path)
    if not os.path.isfile(real):
        raise AdapterError(f"Photo does not exist: {photo_path}", "io_error", 3)
    st = os.stat(real)
    sec = st.st_mtime_ns // 1_000_000_000
    nsec = st.st_mtime_ns % 1_000_000_000
    modified_cf = float(sec - _SWIFT_REFERENCE_EPOCH_OFFSET) + (float(nsec) / 1e9)
    return {
        "fileNumber": int(st.st_ino),
        "modified": modified_cf,
        "path": real,
        "size": int(st.st_size),
    }


def _num_in(obj: dict[str, Any], key: str, default: float, lo: float, hi: float, *, exclusive_min: bool = False) -> float:
    if key not in obj or obj[key] is None:
        return default
    val = obj[key]
    if not _is_finite_number(val):
        raise AdapterError(f"Adjustment '{key}' must be a finite number")
    num = float(val)
    if exclusive_min:
        if not (lo < num <= hi):
            raise AdapterError(f"Adjustment '{key}' must be in ({lo}, {hi}]")
    elif not (lo <= num <= hi):
        raise AdapterError(f"Adjustment '{key}' must be in [{lo}, {hi}]")
    return num


def _build_mac_photo_edit_state(
    *,
    adjustments: dict[str, Any],
    is_raster: bool,
    film_id: str = "",
    master_recipe_id: str | None = None,
) -> dict[str, Any]:
    if not isinstance(adjustments, dict):
        raise AdapterError("adjustments must be an object")

    allowed_keys = {
        "processing_version",
        "x3f_mode",
        "exposure_mode",
        "exposure",
        "contrast",
        "highlights",
        "shadows",
        "s_curve",
        "saturation",
        "vibrance",
        "black_point",
        "white_point",
        "clarity",
        "dehaze",
        "sharpening",
        "strength",
        "white_balance_mode",
        "temperature",
        "tint",
        "raw_noise_reduction",
        "chroma_noise_reduction",
        "wavelet",
        "hsl",
        "tone_curve",
        "color_grading",
        "photo_effects",
        "geometry",
        "lens_correction",
        "master_recipe_settings_version",
    }
    unknown = set(adjustments.keys()) - allowed_keys
    if unknown:
        raise AdapterError(f"Unsupported adjustment keys: {sorted(unknown)}")

    proc_ver = adjustments.get("processing_version", 3)
    if type(proc_ver) is not int or proc_ver not in (1, 2, 3):
        raise AdapterError("processing_version must be 1, 2, or 3")

    exp_mode_in = adjustments.get("exposure_mode", "sensor" if is_raster else "preview")
    exp_mode_map = {
        "preview": "匹配内嵌预览",
        "scene": "标准显影",
        "sensor": "传感器基准",
    }
    if exp_mode_in not in exp_mode_map:
        raise AdapterError("exposure_mode must be preview, scene, or sensor")

    if "white_balance_mode" in adjustments:
        wb_mode_in = adjustments["white_balance_mode"]
    else:
        wb_mode_in = "none" if is_raster else "camera"
    if not isinstance(wb_mode_in, str):
        raise AdapterError("white_balance_mode must be a string")

    has_wb_temp = "temperature" in adjustments and adjustments["temperature"] is not None
    has_wb_tint = "tint" in adjustments and adjustments["tint"] is not None

    if is_raster:
        if wb_mode_in not in ("camera", "none", "relative"):
            raise AdapterError("Raster white_balance_mode must be relative, none, or camera")
        if wb_mode_in != "relative" and (has_wb_temp or has_wb_tint):
            raise AdapterError("Raster temperature and tint require white_balance_mode='relative'")
        effective_temp = (
            round(_num_in(adjustments, "temperature", 6500.0, 2000.0, 50000.0), 2)
            if wb_mode_in == "relative"
            else 6500.0
        )
        effective_tint = (
            round(_num_in(adjustments, "tint", 0.0, -150.0, 150.0), 2)
            if wb_mode_in == "relative"
            else 0.0
        )
        effective_wb_mode = "拍摄时设置"
    else:
        if wb_mode_in not in ("camera", "temperature"):
            raise AdapterError("RAW white_balance_mode must be camera or temperature")
        if wb_mode_in == "camera" and (has_wb_temp or (master_recipe_id is None and has_wb_tint)):
            raise AdapterError("RAW camera white_balance_mode conflicts with temperature or tint")
        effective_temp = (
            round(_num_in(adjustments, "temperature", 6500.0, 2000.0, 50000.0), 2)
            if wb_mode_in == "temperature"
            else 6500.0
        )
        effective_tint = (
            round(_num_in(adjustments, "tint", 0.0, -150.0, 150.0), 2)
            if (wb_mode_in == "temperature" or master_recipe_id is not None)
            else 0.0
        )
        effective_wb_mode = "拍摄时设置" if wb_mode_in == "camera" else "自定义"

    recipe_ver = adjustments.get("master_recipe_settings_version", 4 if master_recipe_id else 3)
    if type(recipe_ver) is not int or recipe_ver not in (2, 3, 4):
        raise AdapterError("master_recipe_settings_version must be 2, 3, or 4")

    raw_dn = adjustments.get("raw_noise_reduction", 0)
    if type(raw_dn) is not int or raw_dn not in (0, 1, 2):
        raise AdapterError("raw_noise_reduction must be 0, 1, or 2")

    x3f_mode = adjustments.get("x3f_mode", "normal-v1")
    if x3f_mode not in ("legacy", "normal-v1"):
        raise AdapterError("x3f_mode must be legacy or normal-v1")

    settings: dict[str, Any] = {
        "processing": {"family": "rawlab", "quality": "standard", "version": proc_ver},
        "x3fMode": x3f_mode,
        "exposureMode": exp_mode_map[exp_mode_in],
        "exposure": round(_num_in(adjustments, "exposure", 0.0, -5.0, 5.0), 6),
        "temperature": effective_temp,
        "tint": effective_tint,
        "whiteBalanceMode": effective_wb_mode,
        "strength": round(_num_in(adjustments, "strength", 1.0, 0.0, 2.0), 6),
        "contrast": round(_num_in(adjustments, "contrast", 0.0, -100.0, 100.0), 4),
        "highlights": round(_num_in(adjustments, "highlights", 0.0, -100.0, 100.0), 4),
        "shadows": round(_num_in(adjustments, "shadows", 0.0, -100.0, 100.0), 4),
        "toneCurve": round(_num_in(adjustments, "s_curve", 0.0, -100.0, 100.0), 4),
        "saturation": round(_num_in(adjustments, "saturation", 0.0, -100.0, 100.0), 4),
        "sharpening": round(_num_in(adjustments, "sharpening", 0.0, 0.0, 200.0), 4),
        "rawNoiseReduction": float(raw_dn),
        "aiDenoiseEnabled": False,
        "supportsRawNoiseReduction": not is_raster,
        "masterRecipeSettingsVersion": recipe_ver,
    }

    if "chroma_noise_reduction" in adjustments and adjustments["chroma_noise_reduction"] is not None:
        cdn = adjustments["chroma_noise_reduction"]
        if type(cdn) is not int or cdn not in (0, 1, 2):
            raise AdapterError("chroma_noise_reduction must be 0, 1, or 2")
        if cdn != 0:
            settings["chromaNoiseReduction"] = float(cdn)

    if "wavelet" in adjustments and adjustments["wavelet"] is not None:
        wv = adjustments["wavelet"]
        if not isinstance(wv, dict):
            raise AdapterError("wavelet must be an object")
        unknown_wv = set(wv.keys()) - {"enabled", "luma", "chroma", "coarse", "preset"}
        if unknown_wv:
            raise AdapterError(f"Unsupported wavelet keys: {sorted(unknown_wv)}")
        enabled_wv = wv.get("enabled", False)
        if type(enabled_wv) is not bool:
            raise AdapterError("wavelet.enabled must be a boolean")
        preset_wv = wv.get("preset", "detail")
        if preset_wv not in ("detail", "clean", "custom"):
            raise AdapterError("wavelet.preset must be detail, clean, or custom")
        settings["waveletNoiseReduction"] = {
            "enabled": enabled_wv,
            "luma": round(_num_in(wv, "luma", 0.0, 0.0, 100.0), 2),
            "chroma": round(_num_in(wv, "chroma", 46.0, 0.0, 100.0), 2),
            "coarse": round(_num_in(wv, "coarse", 50.0, 0.0, 100.0), 2),
            "preset": preset_wv,
        }

    bp = _num_in(adjustments, "black_point", 0.0, -100.0, 100.0)
    wp = _num_in(adjustments, "white_point", 0.0, -100.0, 100.0)
    vib = _num_in(adjustments, "vibrance", 0.0, -100.0, 100.0)
    if bp != 0.0 or wp != 0.0 or vib != 0.0:
        settings["toneControls"] = {
            "blackPoint": round(bp, 4),
            "whitePoint": round(wp, 4),
            "vibrance": round(vib, 4),
        }

    clr = _num_in(adjustments, "clarity", 0.0, -100.0, 100.0)
    dhz = _num_in(adjustments, "dehaze", 0.0, -100.0, 100.0)
    if clr != 0.0 or dhz != 0.0:
        settings["atmosphere"] = {
            "clarity": round(clr, 4),
            "dehaze": round(dhz, 4),
        }

    if "tone_curve" in adjustments and adjustments["tone_curve"] is not None:
        tc_in = adjustments["tone_curve"]
        if not isinstance(tc_in, dict):
            raise AdapterError("tone_curve must be an object")
        unknown_tc = set(tc_in.keys()) - {"mode", "points", "channels", "apply_to_luminosity", "parametric"}
        if unknown_tc:
            raise AdapterError(f"Unsupported tone_curve keys: {sorted(unknown_tc)}")
        master = _validate_tone_curve_shape(
            {"mode": tc_in.get("mode", "legacy"), "points": tc_in.get("points", [])},
            field_name="tone_curve",
        )
        tc_out: dict[str, Any] = {"mode": master["mode"], "points": master["points"]}
        if master["mode"] == "custom":
            settings["toneCurve"] = 0.0
        if "channels" in tc_in and tc_in["channels"] is not None:
            ch = tc_in["channels"]
            if not isinstance(ch, dict) or not set(ch.keys()).issubset({"red", "green", "blue"}):
                raise AdapterError("tone_curve.channels must be an object with keys subset of red, green, blue")
            ch_out = {
                c_name: _validate_tone_curve_shape(c_shape, field_name=f"tone_curve.channels.{c_name}")
                for c_name, c_shape in ch.items()
            }
            if ch_out:
                tc_out["channels"] = ch_out
        if "apply_to_luminosity" in tc_in:
            if type(tc_in["apply_to_luminosity"]) is not bool:
                raise AdapterError("tone_curve.apply_to_luminosity must be bool")
            if tc_in["apply_to_luminosity"]:
                tc_out["apply_to_luminosity"] = True
        if "parametric" in tc_in and tc_in["parametric"] is not None:
            p_validated = _validate_parametric_curve(tc_in["parametric"], field_name="tone_curve.parametric")
            tc_out["parametric"] = {k: round(v, 4) for k, v in p_validated.items()}
            # Re-verify split gap after rounding
            if (
                tc_out["parametric"]["split_shadow"] + 0.02 > tc_out["parametric"]["split_midtone"]
                or tc_out["parametric"]["split_midtone"] + 0.02 > tc_out["parametric"]["split_highlight"]
            ):
                raise AdapterError("tone_curve.parametric split points violate split_min_gap after rounding")
        settings["toneCurveConfig"] = tc_out

    if "color_grading" in adjustments and adjustments["color_grading"] is not None:
        cg_in = adjustments["color_grading"]
        if not isinstance(cg_in, dict):
            raise AdapterError("color_grading must be an object")
        unknown_cg = set(cg_in.keys()) - {"shadows", "midtones", "highlights", "global", "blending", "balance"}
        if unknown_cg:
            raise AdapterError(f"Unsupported color_grading keys: {sorted(unknown_cg)}")
        cg_out: dict[str, Any] = {}

        def _round_wheel(w: dict[str, float], zone_name: str) -> dict[str, float]:
            hue_r = round(w["hue"], 4)
            if not (0.0 <= hue_r < 360.0):
                raise AdapterError(f"color_grading.{zone_name}.hue must be strictly < 360.0")
            return {
                "hue": hue_r,
                "saturation": round(w["saturation"], 4),
                "luminance": round(w["luminance"], 4),
            }

        for zone in ("shadows", "midtones", "highlights"):
            if zone in cg_in and cg_in[zone] is not None:
                validated_w = _validate_grading_wheel(cg_in[zone], field_name=f"color_grading.{zone}")
                cg_out[zone] = _round_wheel(validated_w, zone)
            else:
                cg_out[zone] = {"hue": 0.0, "saturation": 0.0, "luminance": 0.0}
        if "global" in cg_in and cg_in["global"] is not None:
            validated_g = _validate_grading_wheel(cg_in["global"], field_name="color_grading.global")
            cg_out["global"] = _round_wheel(validated_g, "global")
        if "blending" in cg_in:
            cg_out["blending"] = round(_num_in(cg_in, "blending", 50.0, 0.0, 100.0), 4)
        if "balance" in cg_in:
            cg_out["balance"] = round(_num_in(cg_in, "balance", 0.0, -100.0, 100.0), 4)
        settings["colorGrading"] = cg_out

    if "hsl" in adjustments and adjustments["hsl"] is not None:
        hsl = adjustments["hsl"]
        if not isinstance(hsl, dict) or set(hsl.keys()) != {"hue", "saturation", "lightness"}:
            raise AdapterError("hsl must contain hue, saturation, lightness arrays of length 8")
        for axis in ("hue", "saturation", "lightness"):
            arr = hsl[axis]
            if not isinstance(arr, list) or len(arr) != 8 or any(not _is_finite_number(v) or not (-100.0 <= float(v) <= 100.0) for v in arr):
                raise AdapterError(f"hsl.{axis} must contain 8 numbers in [-100.0, 100.0]")
        settings["hsl"] = {
            axis: [float(v) for v in hsl[axis]]
            for axis in ("hue", "saturation", "lightness")
        }

    if "photo_effects" in adjustments and adjustments["photo_effects"] is not None:
        eff = adjustments["photo_effects"]
        if not isinstance(eff, dict):
            raise AdapterError("photo_effects must be an object")
        unknown_eff = set(eff.keys()) - {
            "vignette_amount", "vignette_midpoint", "vignette_roundness", "vignette_feather",
            "vignette_highlights", "grain_amount", "grain_size", "grain_roughness",
        }
        if unknown_eff:
            raise AdapterError(f"Unsupported photo_effects keys: {sorted(unknown_eff)}")
        settings["photoEffects"] = {
            "vignetteAmount": round(_num_in(eff, "vignette_amount", 0.0, -100.0, 100.0), 2),
            "vignetteMidpoint": round(_num_in(eff, "vignette_midpoint", 50.0, 0.0, 100.0), 2),
            "vignetteRoundness": round(_num_in(eff, "vignette_roundness", 0.0, -100.0, 100.0), 2),
            "vignetteFeather": round(_num_in(eff, "vignette_feather", 50.0, 0.0, 100.0), 2),
            "vignetteHighlights": round(_num_in(eff, "vignette_highlights", 0.0, 0.0, 100.0), 2),
            "grainAmount": round(_num_in(eff, "grain_amount", 0.0, 0.0, 100.0), 2),
            "grainSize": round(_num_in(eff, "grain_size", 25.0, 0.0, 100.0), 2),
            "grainRoughness": round(_num_in(eff, "grain_roughness", 50.0, 0.0, 100.0), 2),
        }

    if "lens_correction" in adjustments and adjustments["lens_correction"] is not None:
        lc = adjustments["lens_correction"]
        if not isinstance(lc, dict):
            raise AdapterError("lens_correction must be an object")
        unknown_lc = set(lc.keys()) - {"distortion", "tca", "vignetting", "auto_crop", "profile_id"}
        if unknown_lc:
            raise AdapterError(f"Unsupported lens_correction keys: {sorted(unknown_lc)}")
        for bkey in ("distortion", "tca", "vignetting", "auto_crop"):
            if bkey in lc and type(lc[bkey]) is not bool:
                raise AdapterError(f"lens_correction.{bkey} must be a boolean")
        pid_val = lc.get("profile_id")
        if pid_val is not None and (not isinstance(pid_val, str) or not pid_val):
            raise AdapterError("lens_correction.profile_id must be a nonempty string or null")
        settings["lensCorrection"] = {
            "distortion": bool(lc.get("distortion", False)),
            "tca": bool(lc.get("tca", False)),
            "vignetting": bool(lc.get("vignetting", False)),
            "autoCrop": bool(lc.get("auto_crop", True)),
            "mode": "manual" if pid_val else "automatic",
            "profileID": pid_val,
        }

    if "geometry" in adjustments and adjustments["geometry"] is not None:
        geom = adjustments["geometry"]
        if not isinstance(geom, dict):
            raise AdapterError("geometry must be an object")
        unknown_geom = set(geom.keys()) - {
            "crop_x", "crop_y", "crop_width", "crop_height", "quarter_turns",
            "flip_horizontal", "flip_vertical", "straighten_degrees",
            "perspective_horizontal", "perspective_vertical",
        }
        if unknown_geom:
            raise AdapterError(f"Unsupported geometry keys: {sorted(unknown_geom)}")
        qt = geom.get("quarter_turns", 0)
        if type(qt) is not int or qt not in (0, 1, 2, 3):
            raise AdapterError("geometry.quarter_turns must be 0, 1, 2, or 3")
        for bkey in ("flip_horizontal", "flip_vertical"):
            if bkey in geom and type(geom[bkey]) is not bool:
                raise AdapterError(f"geometry.{bkey} must be a boolean")
        crop_x = round(_num_in(geom, "crop_x", 0.0, 0.0, 1.0), 6)
        crop_y = round(_num_in(geom, "crop_y", 0.0, 0.0, 1.0), 6)
        crop_w = round(_num_in(geom, "crop_width", 1.0, 0.0, 1.0, exclusive_min=True), 6)
        crop_h = round(_num_in(geom, "crop_height", 1.0, 0.0, 1.0, exclusive_min=True), 6)
        if crop_w <= 0.0 or crop_h <= 0.0:
            raise AdapterError("geometry.crop_width and crop_height must be > 0")
        if crop_x + crop_w > 1.0 or crop_y + crop_h > 1.0:
            raise AdapterError("geometry crop bounds must satisfy crop_x + crop_width <= 1.0 and crop_y + crop_height <= 1.0")
        settings["geometry"] = {
            "cropX": crop_x,
            "cropY": crop_y,
            "cropWidth": crop_w,
            "cropHeight": crop_h,
            "quarterTurns": qt,
            "flipHorizontal": bool(geom.get("flip_horizontal", False)),
            "flipVertical": bool(geom.get("flip_vertical", False)),
            "straightenDegrees": round(_num_in(geom, "straighten_degrees", 0.0, -45.0, 45.0), 4),
            "perspectiveHorizontal": round(_num_in(geom, "perspective_horizontal", 0.0, -1.0, 1.0), 6),
            "perspectiveVertical": round(_num_in(geom, "perspective_vertical", 0.0, -1.0, 1.0), 6),
        }

    if master_recipe_id is not None:
        if not isinstance(master_recipe_id, str) or not master_recipe_id:
            raise AdapterError("master_recipe_id must be a nonempty string or null")
        settings["masterRecipeID"] = master_recipe_id

    return {
        "filmID": "" if master_recipe_id else film_id,
        "masterRecipeID": master_recipe_id,
        "settings": settings,
    }


def sync_photo_edit(
    *,
    data_dir: Path,
    photo_canonical: Path,
    adjustments: dict[str, Any],
    is_raster: bool,
    film_id: str = "",
    master_recipe_id: str | None = None,
) -> dict[str, Any]:
    if sys.platform != "darwin":
        raise AdapterError(
            "sync_photo_edit currently targets macOS RawLab (Edits/edits.json); use save_preset on this OS",
            "unsupported",
        )

    identity = _swift_identity_for_file(photo_canonical)
    state = _build_mac_photo_edit_state(
        adjustments=adjustments,
        is_raster=is_raster,
        film_id=film_id,
        master_recipe_id=master_recipe_id,
    )

    edits_file = resolve_controlled_subpath(data_dir, "Edits", "edits.json")
    lock_file = resolve_controlled_subpath(data_dir, "Edits", ".edits.lock")
    edits_file.parent.mkdir(parents=True, exist_ok=True)

    with _store_lock(lock_file):
        if edits_file.exists():
            try:
                registry = json.loads(edits_file.read_text(encoding="utf-8"))
            except (OSError, ValueError, UnicodeError) as e:
                raise AdapterError(f"Corrupt edits.json: {e}", "output_io_error") from e
            if (not isinstance(registry, dict) or registry.get("version") != 1
                    or type(registry.get("version")) is not int
                    or not isinstance(registry.get("records"), dict)):
                raise AdapterError("Unsupported or corrupt edits.json", "output_io_error")
        else:
            registry = {"records": {}, "version": 1}

        records: dict[str, Any] = dict(registry["records"])
        had_existing = identity["path"] in records
        records[identity["path"]] = {"identity": identity, "state": state}

        out_reg: dict[str, Any] = {"records": records}
        if registry.get("processingMigrations") is not None:
            out_reg["processingMigrations"] = registry["processingMigrations"]
        out_reg["version"] = 1

        encoded = json.dumps(out_reg, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
        atomic_write_bytes(edits_file, encoded)

    return {
        "action": "updated" if had_existing else "created",
        "photo_path": identity["path"],
        "edits_file": str(edits_file),
        "filmID": state["filmID"],
        "masterRecipeID": state["masterRecipeID"],
    }
