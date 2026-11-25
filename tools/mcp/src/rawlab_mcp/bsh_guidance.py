"""Upper-layer portrait skin-tone and BSH grading guidance for MCP diagnose_image."""

from __future__ import annotations

from typing import Any

TARGET_EAST_ASIAN_HSB = {"h_deg": "15..26", "s_pct": "15..35", "b_pct": "70..85"}
_SKIN_ASCII_TOKENS = ("skin", "face", "cheek", "portrait")
_SKIN_CJK_TOKENS = ("肤", "脸")


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _is_skin_label(label: str) -> bool:
    lowered = label.lower()
    return any(tok in lowered for tok in _SKIN_ASCII_TOKENS) or any(tok in label for tok in _SKIN_CJK_TOKENS)


def _portrait_skin_check(h_deg: float, s_pct: float, b_pct: float) -> dict[str, Any]:
    hints: list[str] = []
    if b_pct < 70.0:
        hints.append(f"B={b_pct}% < 70%: consider lifting exposure or hsl.orange.l/red.l")
    elif b_pct > 85.0:
        hints.append(f"B={b_pct}% > 85%: consider recovering highlights or pulling orange.l slightly down")
    if s_pct > 35.0:
        hints.append(f"S={s_pct}% > 35%: skin over-saturated/muddy; pull hsl.orange.s/red.s negative")
    elif s_pct < 15.0:
        hints.append(f"S={s_pct}% < 15%: skin pale; check vibrance or warm skin slightly")
    if h_deg < 15.0:
        hints.append(f"H={h_deg}deg < 15deg: skin too red/magenta; shift hsl.red.h positive or warm tint toward yellow")
    elif h_deg > 26.0:
        hints.append(f"H={h_deg}deg > 26deg: skin too yellow/greenish; shift hsl.orange.h negative toward peach")
    return {
        "target_east_asian_hsb": dict(TARGET_EAST_ASIAN_HSB),
        "in_window": not hints,
        "hints": hints,
    }


def _compute_auto_diagnostics(result: dict[str, Any]) -> list[str] | None:
    clipping = result.get("clipping")
    luma_zones = result.get("luma_zones")
    saturation = result.get("saturation")
    color_balance = result.get("color_balance")
    if not (isinstance(clipping, dict) and isinstance(luma_zones, dict) and
            isinstance(saturation, dict) and isinstance(color_balance, dict)):
        return None
    channel_clip = clipping.get("channel_clip_high_pct")
    pcts = luma_zones.get("percentiles_0_1")
    if not (isinstance(channel_clip, dict) and isinstance(pcts, dict)):
        return None

    wb_pct = clipping.get("white_blowout_pct")
    clip_any_pct = channel_clip.get("any")
    sc_pct = clipping.get("shadow_crush_pct")
    p05 = pcts.get("p05")
    blacks_pct = luma_zones.get("blacks_0_10_pct")
    melt_pct = saturation.get("melting_saturation_pct")
    cast_hint = color_balance.get("cast_hint")
    r_over_g = color_balance.get("r_over_g")
    b_over_g = color_balance.get("b_over_g")
    if not all(_is_number(v) for v in (wb_pct, clip_any_pct, sc_pct, p05, blacks_pct, melt_pct, r_over_g, b_over_g)):
        return None

    wb = float(wb_pct)
    clip_any = float(clip_any_pct)
    sc = float(sc_pct)
    p05_val = float(p05)
    blacks = float(blacks_pct)
    melt = float(melt_pct)
    rg = float(r_over_g)
    bg = float(b_over_g)

    alerts: list[str] = []
    if wb > 1.5 or clip_any > 3.0:
        alerts.append(
            f"Highlight clipping ({wb}% white blowout, {clip_any}% single-channel clip): "
            "reduce UI highlights (negative) or exposure_ev."
        )
    if sc > 3.0:
        alerts.append(
            f"Shadow crush ({sc}% pure black): lift shadows (+), black_point (+), or soften blacks toe."
        )
    elif p05_val > 0.14 and blacks < 1.0:
        alerts.append(
            f"Weak dark anchor (p05={p05_val:.3f}, blacks={blacks}%): "
            "image may look hazy/unanchored; lower black_point or anchor dark toe unless flat look is intended."
        )
    if melt > 2.0:
        alerts.append(
            f"Melting saturation risk ({melt}% pixels S>85% & V>35%): "
            "reduce global saturation/look strength or pull offending HSL channel saturation."
        )
    if cast_hint in ("green_cast", "magenta_cast"):
        alerts.append(
            f"Midtone neutral cast detected ({cast_hint}: R/G={rg}, B/G={bg}): "
            "check white_balance tint or color grading."
        )
    return alerts


def enrich_bsh_diagnosis(result: dict[str, Any]) -> dict[str, Any]:
    enriched = dict(result)
    samples = enriched.get("samples")
    if isinstance(samples, list):
        new_samples: list[Any] = []
        for item in samples:
            if isinstance(item, dict) and "label" in item and isinstance(item.get("hsb"), dict):
                hsb = item["hsb"]
                h_deg = hsb.get("h_deg")
                s_pct = hsb.get("s_pct")
                b_pct = hsb.get("b_pct")
                if (_is_number(h_deg) and _is_number(s_pct) and _is_number(b_pct) and
                        "portrait_skin_check" not in item and _is_skin_label(str(item["label"]))):
                    copy_item = dict(item)
                    copy_item["portrait_skin_check"] = _portrait_skin_check(
                        float(h_deg), float(s_pct), float(b_pct)
                    )
                    new_samples.append(copy_item)
                    continue
            new_samples.append(item)
        enriched["samples"] = new_samples

    if "auto_diagnostics" not in enriched:
        alerts = _compute_auto_diagnostics(enriched)
        if alerts is not None:
            enriched["auto_diagnostics"] = alerts
    return enriched
