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
        hints.append(
            f"S={s_pct}% > 35%: skin over-saturated/muddy; pull hsl.orange.s/red.s negative or tighten with "
            "color.point_color (negative saturation_shift and variance < 0 toward target skin anchor)"
        )
    elif s_pct < 15.0:
        hints.append(
            f"S={s_pct}% < 15%: skin pale; check vibrance or warm skin slightly (hsl.orange/red or color.point_color)"
        )
    if h_deg < 15.0:
        hints.append(
            f"H={h_deg}deg < 15deg: skin too red/magenta (redness/blotchiness); shift hsl.red.h positive, "
            "converge via color.point_color (variance < 0 toward target skin anchor, preserving natural texture), "
            "or refine color.calibration primary hue/saturation (neutral-gray safe)"
        )
    elif h_deg > 26.0:
        hints.append(
            f"H={h_deg}deg > 26deg: skin too yellow/sallow/greenish; shift hsl.orange.h negative toward peach, "
            "converge via color.point_color (variance < 0 toward target skin anchor), or refine color.calibration "
            "primary hue/saturation (neutral-gray safe)"
        )

    needs_color_convergence = h_deg < 15.0 or h_deg > 26.0 or s_pct > 35.0
    v014_tools = {
        "color_uniformity": (
            "Converge redness/blotchiness or sallow variance toward the East Asian skin anchor with "
            "color.point_color (variance < 0, preserving natural texture) and neutral-gray-safe "
            "color.calibration primary hue/saturation refinement."
            if needs_color_convergence
            else "Sample lies inside the East Asian HSB anchor; use color.point_color (variance < 0) only if multiple skin zones show blotchiness."
        ),
        "micro_texture_and_sharpening": (
            "Shape micro-contrast with effects.texture (mild negative softens skin texture; positive crispens facial details) "
            "and use detail.sharpening.luminance_v2=true with detail.sharpening.masking >= 50 (e.g. 55..75) for skin edge protection."
        ),
    }
    return {
        "target_east_asian_hsb": dict(TARGET_EAST_ASIAN_HSB),
        "in_window": not hints,
        "hints": hints,
        "v014_tools": v014_tools,
    }


def _collect_skin_samples(samples: Any) -> list[dict[str, float]]:
    skin: list[dict[str, float]] = []
    if not isinstance(samples, list):
        return skin
    for item in samples:
        if not (isinstance(item, dict) and "label" in item and isinstance(item.get("hsb"), dict)):
            continue
        if not _is_skin_label(str(item["label"])):
            continue
        hsb = item["hsb"]
        h_deg, s_pct, b_pct = hsb.get("h_deg"), hsb.get("s_pct"), hsb.get("b_pct")
        if _is_number(h_deg) and _is_number(s_pct) and _is_number(b_pct):
            skin.append({"h_deg": float(h_deg), "s_pct": float(s_pct), "b_pct": float(b_pct)})
    return skin


def _build_portrait_diagnostics(skin_samples: list[dict[str, float]], hsl_channels: Any) -> dict[str, Any] | None:
    if not skin_samples:
        return None
    hs = [s["h_deg"] for s in skin_samples]
    ss = [s["s_pct"] for s in skin_samples]
    bs = [s["b_pct"] for s in skin_samples]
    hue_spread = round(max(hs) - min(hs), 1)
    sat_spread = round(max(ss) - min(ss), 1)
    b_spread = round(max(bs) - min(bs), 1)
    in_window_count = sum(
        1 for s in skin_samples if 15.0 <= s["h_deg"] <= 26.0 and 15.0 <= s["s_pct"] <= 35.0 and 70.0 <= s["b_pct"] <= 85.0
    )
    redness_or_sallow = any(s["h_deg"] < 15.0 or s["h_deg"] > 26.0 for s in skin_samples)
    blotchy_variance = len(skin_samples) >= 2 and (hue_spread >= 6.0 or sat_spread >= 10.0 or b_spread >= 12.0)

    hsl_red = hsl_channels.get("red") if isinstance(hsl_channels, dict) else None
    hsl_orange = hsl_channels.get("orange") if isinstance(hsl_channels, dict) else None
    red_cov = float(hsl_red["coverage_pct"]) if isinstance(hsl_red, dict) and _is_number(hsl_red.get("coverage_pct")) else 0.0
    orange_cov = float(hsl_orange["coverage_pct"]) if isinstance(hsl_orange, dict) and _is_number(hsl_orange.get("coverage_pct")) else 0.0

    recs: list[str] = []
    if blotchy_variance or redness_or_sallow or any(s["s_pct"] > 35.0 for s in skin_samples) or red_cov > orange_cov:
        recs.append(
            "Portrait skin variance/redness or sallow drift: converge uneven skin toward the target skin anchor "
            "using color.point_color (variance < 0, preserving natural texture) and neutral-gray-safe "
            "color.calibration primary hue/saturation refinement."
        )
    recs.append(
        "Portrait micro-texture & edge protection: use effects.texture (mild negative avoids plastic clarity smoothing) "
        "with detail.sharpening.luminance_v2=true and detail.sharpening.masking >= 50 (e.g. 55..75) to protect smooth skin."
    )
    return {
        "skin_sample_count": len(skin_samples),
        "in_window_count": in_window_count,
        "hue_spread_deg": hue_spread,
        "sat_spread_pct": sat_spread,
        "b_spread_pct": b_spread,
        "blotchy_variance_detected": blotchy_variance,
        "recommended_controls": [
            "color.point_color",
            "color.calibration.red_hue",
            "color.calibration.red_saturation",
            "effects.texture",
            "detail.sharpening.luminance_v2",
            "detail.sharpening.masking",
        ],
        "recommendations": recs,
    }


def _build_v014_guidance(
    result: dict[str, Any],
    portrait_diag: dict[str, Any] | None,
) -> dict[str, Any] | None:
    clipping = result.get("clipping")
    luma_zones = result.get("luma_zones")
    saturation = result.get("saturation")
    color_balance = result.get("color_balance")
    has_telemetry = (
        isinstance(clipping, dict)
        and isinstance(luma_zones, dict)
        and isinstance(saturation, dict)
        and isinstance(color_balance, dict)
    )
    if not has_telemetry and portrait_diag is None:
        return None

    guidance: dict[str, Any] = {}
    if portrait_diag is not None:
        guidance["portrait"] = portrait_diag

    if has_telemetry:
        wb = float(clipping.get("white_blowout_pct") or 0.0)
        lights = float(luma_zones.get("lights_65_90_pct") or 0.0)
        highlights = float(luma_zones.get("highlights_90_100_pct") or 0.0)
        bright_pct = lights + highlights
        spread = float(luma_zones.get("dynamic_spread_p95_minus_p05") or 0.0)
        pcts = luma_zones.get("percentiles_0_1") if isinstance(luma_zones.get("percentiles_0_1"), dict) else {}
        p05 = float(pcts.get("p05") or 0.0) if _is_number(pcts.get("p05")) else 0.0
        mean_s = float(saturation.get("mean_s_pct") or 0.0) if _is_number(saturation.get("mean_s_pct")) else 0.0
        low_sat = float(saturation.get("low_sat_pct") or 0.0) if _is_number(saturation.get("low_sat_pct")) else 0.0
        melt = float(saturation.get("melting_saturation_pct") or 0.0) if _is_number(saturation.get("melting_saturation_pct")) else 0.0

        is_portrait = portrait_diag is not None
        guidance["detail_and_texture"] = {
            "micro_contrast": (
                "effects.texture (-15..-5 gently smooths uneven skin micro-texture; +10..+25 adds crispness to eyes/fabric/foliage without wide-radius halos)."
            ),
            "luminance_sharpening": (
                "Enable detail.sharpening.luminance_v2=true with detail.sharpening.masking >= 50 (55..75) for portrait skin/sky edge protection, "
                "or 20..40 for landscape/architectural detail (tune radius 0.8..1.4, detail 20..40)."
                if is_portrait or low_sat >= 20.0
                else "Enable detail.sharpening.luminance_v2=true (radius/detail tuned cleanly) with detail.sharpening.masking >= 50 when large sky/smooth regions need noise protection."
            ),
            "recommended_masking_min": 50.0 if (is_portrait or low_sat >= 20.0) else 25.0,
        }

        film_notes: list[str] = []
        if bright_pct >= 20.0 or wb > 0.5:
            film_notes.append(
                "Bright specular/highlight distribution: keep clipping controlled first, then add analog glow with "
                "effects.halation (amount/threshold/radius/hue) and effects.bloom (amount/threshold/radius)."
            )
        else:
            film_notes.append(
                "Optional analog finish: pair negative film grain (effects.grain.tone_curve='negative_asymmetric' with "
                "effects.grain.format_preset='135' or '120') and subtle effects.halation / effects.bloom for bright sources."
            )
        if melt > 2.0 or isinstance(result.get("hsl_channels"), dict) and result.get("hsl_channels"):
            film_notes.append(
                "Targeted palette sculpting: use color.selective_color (relative/absolute CMYK adjustments on reds..blacks) "
                "or neutral-gray-safe color.calibration to shift overall primaries cleanly."
            )
        monochrome_candidate = mean_s <= 12.0 or low_sat >= 75.0
        if monochrome_candidate:
            film_notes.append(
                f"Low-chroma/monochrome candidate (mean_s={mean_s}%, low_sat={low_sat}%): enable color.bw.enabled=true "
                "and balance tonal separation across channels with color.bw.mixer."
            )
        guidance["film_and_color"] = {
            "monochrome_candidate": monochrome_candidate,
            "grain_presets": {
                "tone_curve": "negative_asymmetric",
                "format_presets": ["135", "120"],
            },
            "notes": film_notes,
            "recommended_controls": [
                "effects.halation.amount",
                "effects.bloom.amount",
                "effects.grain.tone_curve",
                "effects.grain.format_preset",
                "color.selective_color",
                "color.bw.enabled",
                "color.bw.mixer",
            ],
        }

        high_contrast_fringing_risk = spread >= 0.78 and bright_pct >= 30.0 and p05 <= 0.10
        guidance["lens_optics"] = {
            "axial_fringing_risk": high_contrast_fringing_risk,
            "note": (
                "High-contrast highlight edges detected: check axial purple/green fringing and apply "
                "geometry.lens.defringe_purple_amount / defringe_purple_hue and geometry.lens.defringe_green_amount / defringe_green_hue."
                if high_contrast_fringing_risk
                else "If backlit edges or foliage show axial color fringes, enable geometry.lens.defringe_purple_amount/hue and defringe_green_amount/hue."
            ),
        }

    return guidance


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
    mean_s_pct = saturation.get("mean_s_pct")
    low_sat_pct = saturation.get("low_sat_pct")
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
            "reduce UI highlights (negative) or exposure_ev; keep effects.halation / effects.bloom restrained until clipping clears."
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
            "reduce global saturation/look strength, pull offending HSL channel saturation, or tame with color.selective_color / color.point_color."
        )
    if cast_hint in ("green_cast", "magenta_cast"):
        alerts.append(
            f"Midtone neutral cast detected ({cast_hint}: R/G={rg}, B/G={bg}): "
            "check white_balance tint, color grading, or neutral-gray-safe color.calibration / color.selective_color neutrals band."
        )

    if _is_number(mean_s_pct) and _is_number(low_sat_pct):
        mean_s = float(mean_s_pct)
        low_sat = float(low_sat_pct)
        if mean_s <= 8.0 and low_sat >= 80.0:
            alerts.append(
                f"Low-saturation / near-monochrome candidate (mean_s={mean_s}%, low_sat={low_sat}%): "
                "consider color.bw.enabled=true with color.bw.mixer and negative-style grain (effects.grain.tone_curve='negative_asymmetric')."
            )

    hsl_channels = result.get("hsl_channels")
    skin_samples = _collect_skin_samples(result.get("samples"))
    if isinstance(hsl_channels, dict) and hsl_channels:
        red_ch = hsl_channels.get("red")
        orange_ch = hsl_channels.get("orange")
        red_drift = isinstance(red_ch, dict) and _is_number(red_ch.get("mean_hue_deg")) and float(red_ch["mean_hue_deg"]) < 15.0 and float(red_ch.get("coverage_pct", 0.0)) >= 3.0
        orange_drift = isinstance(orange_ch, dict) and _is_number(orange_ch.get("mean_hue_deg")) and float(orange_ch["mean_hue_deg"]) > 26.0 and float(orange_ch.get("coverage_pct", 0.0)) >= 3.0
        if skin_samples and (red_drift or orange_drift or (len(skin_samples) >= 2 and (max(s["h_deg"] for s in skin_samples) - min(s["h_deg"] for s in skin_samples)) >= 6.0)):
            alerts.append(
                "Portrait skin tone drift/variance detected: converge uneven skin hues with color.point_color (variance < 0, preserving texture), "
                "refine neutral-gray-safe color.calibration, and protect skin pores with detail.sharpening.luminance_v2 + masking >= 50."
            )

    lights = luma_zones.get("lights_65_90_pct")
    highlights = luma_zones.get("highlights_90_100_pct")
    spread = luma_zones.get("dynamic_spread_p95_minus_p05")
    if _is_number(lights) and _is_number(highlights) and _is_number(spread):
        bright_pct = float(lights) + float(highlights)
        if float(spread) >= 0.78 and bright_pct >= 30.0 and p05_val <= 0.10:
            alerts.append(
                f"High-contrast backlit dynamic spread ({float(spread):.2f}): watch axial fringing with geometry.lens.defringe_* "
                "and finish highlights with effects.halation / effects.bloom + detail.sharpening.masking >= 50."
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

    skin_samples = _collect_skin_samples(enriched.get("samples"))
    portrait_diag = _build_portrait_diagnostics(skin_samples, enriched.get("hsl_channels"))
    if portrait_diag is not None and "portrait_diagnostics" not in enriched:
        enriched["portrait_diagnostics"] = portrait_diag

    if "v014_guidance" not in enriched:
        v014 = _build_v014_guidance(enriched, portrait_diag)
        if v014 is not None:
            enriched["v014_guidance"] = v014

    return enriched
