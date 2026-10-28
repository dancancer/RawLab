package com.rawlab.android.settings

// 冻结旧记录的写法，仅供 reader 兼容回归，不能通过新 writer 生成旧 fixture。
fun legacyPipeSettings(settings: EditSettings): String = listOf(
        settings.film, settings.strength, settings.exposure, settings.highlights, settings.shadows,
        settings.contrast, settings.toneCurve, settings.saturation, settings.customWb,
        settings.temperature, settings.tint, settings.sharpening,
        settings.denoise.enabled, settings.denoise.luma, settings.denoise.chroma, settings.denoise.coarse,
        settings.displayChromaDenoise,
        settings.effects.vignetteAmount, settings.effects.vignetteMidpoint, settings.effects.vignetteRoundness,
        settings.effects.vignetteFeather, settings.effects.vignetteHighlights,
        settings.effects.grainAmount, settings.effects.grainSize, settings.effects.grainRoughness,
    ).plus(settings.exposureMode).plus(settings.hsl.packed().toList()).plus(settings.recipeID ?: "")
        .plus(java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(settings.lens.encode().toByteArray(Charsets.UTF_8)))
        .plus(settings.geometry.encode()).plus(settings.processing.encode())
        .joinToString("|")

fun legacyCSVSettings(settings: EditSettings): String = listOf(
        settings.strength, settings.exposure, settings.highlights, settings.shadows,
        settings.contrast, settings.toneCurve, settings.saturation,
        if (settings.customWb) 1f else 0f, settings.temperature, settings.tint, settings.sharpening,
        if (settings.denoise.enabled) 1f else 0f, settings.denoise.luma, settings.denoise.chroma, settings.denoise.coarse,
        settings.displayChromaDenoise,
        settings.effects.vignetteAmount, settings.effects.vignetteMidpoint, settings.effects.vignetteRoundness,
        settings.effects.vignetteFeather, settings.effects.vignetteHighlights,
        settings.effects.grainAmount, settings.effects.grainSize, settings.effects.grainRoughness,
    ).plus(settings.exposureMode).plus(settings.hsl.packed().toList()).joinToString(",")
