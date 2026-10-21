package com.rawlab.android.settings

import com.rawlab.android.geometry.GeometrySettings

// ============================================================================
//  调整参数的紧凑编码：批量快照与日志使用，格式不随界面改变
// ============================================================================

internal object SettingsCodec {
    fun encode(settings: EditSettings): String = listOf(
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

    fun decode(value: String): EditSettings {
        val fields = value.split('|')
        require(fields.size in listOf(12, 16, 25, 50, 51, 52, 53, 54))
        return EditSettings(film = fields[0], strength = fields[1].toFloat(), exposure = fields[2].toFloat(),
            highlights = fields[3].toFloat(), shadows = fields[4].toFloat(), contrast = fields[5].toFloat(),
            toneCurve = fields[6].toFloat(), saturation = fields[7].toFloat(), customWb = fields[8].toBoolean(),
            temperature = fields[9].toFloat(), tint = fields[10].toFloat(), sharpening = fields[11].toFloat(),
            denoise = if (fields.size == 16) DenoiseSettings(fields[12].toBoolean(), fields[13].toFloat(),
                fields[14].toFloat(), fields[15].toFloat())
            else if (fields.size >= 25) DenoiseSettings(fields[12].toBoolean(), fields[13].toFloat(),
                fields[14].toFloat(), fields[15].toFloat())
            else DenoiseSettings(),
            displayChromaDenoise = if (fields.size >= 25) parseChromaMode(fields[16]) else 0,
            exposureMode = if (fields.size >= 50) parseChromaMode(fields[25]) else 0,
            hsl = if (fields.size >= 50) HslSettings(fields.subList(26, 50).map(String::toFloat)) else HslSettings(),
            recipeID = if (fields.size >= 51) fields[50].ifEmpty { null } else null,
            lens = if (fields.size >= 52) LensSettings.decode(String(java.util.Base64.getUrlDecoder().decode(fields[51]), Charsets.UTF_8)) else LensSettings(),
            geometry = GeometrySettings.decode(fields.getOrNull(52)),
            processing = ProcessingIdentity.decode(fields.getOrNull(53)),
            effects = if (fields.size >= 25) PhotoEffectsSettings(
                vignetteAmount = fields[17].toFloat(), vignetteMidpoint = fields[18].toFloat(),
                vignetteRoundness = fields[19].toFloat(), vignetteFeather = fields[20].toFloat(),
                vignetteHighlights = fields[21].toFloat(), grainAmount = fields[22].toFloat(),
                grainSize = fields[23].toFloat(), grainRoughness = fields[24].toFloat(),
            ) else PhotoEffectsSettings())
    }

    private fun parseChromaMode(value: String): Int {
        val number = value.toFloat()
        require(number.isFinite() && number == number.toInt().toFloat())
        return number.toInt()
    }
}
