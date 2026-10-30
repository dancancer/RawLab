package com.rawlab.android.settings

import com.rawlab.android.geometry.GeometrySettings

// ============================================================================
//  调整参数的紧凑编码：批量快照与日志使用，格式不随界面改变
// ============================================================================

internal object SettingsCodec {
    fun encode(settings: EditSettings): String = StructuredSettingsCodec.encode(settings, "batch_settings")

    fun decode(value: String): EditSettings {
        if (value.startsWith("v2:")) {
            // 旧 film ID 也能以 v2: 开头；只有完整合法的旧记录才走此兼容分支。
            return runCatching { decodeLegacy(value) }.getOrElse {
                StructuredSettingsCodec.decode(value, "batch_settings")
            }
        }
        return decodeLegacy(value)
    }

    private fun decodeLegacy(value: String): EditSettings {
        val fields = value.split('|')
        require(fields.size in listOf(12, 16, 25, 50, 51, 52, 53, 54))
        return EditSettings(film = fields[0], strength = fields[1].toFloat(), exposure = fields[2].toFloat(),
            x3fMode = X3fMode.LEGACY,
            highlights = fields[3].toFloat(), shadows = fields[4].toFloat(), contrast = fields[5].toFloat(),
            toneCurve = fields[6].toFloat(), saturation = fields[7].toFloat(), customWb = parseBoolean(fields[8]),
            temperature = fields[9].toFloat(), tint = fields[10].toFloat(), sharpening = fields[11].toFloat(),
            denoise = if (fields.size == 16) DenoiseSettings(parseBoolean(fields[12]), fields[13].toFloat(),
                fields[14].toFloat(), fields[15].toFloat())
            else if (fields.size >= 25) DenoiseSettings(parseBoolean(fields[12]), fields[13].toFloat(),
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

    private fun parseBoolean(value: String): Boolean = when (value.lowercase(java.util.Locale.ROOT)) {
        "true" -> true
        "false" -> false
        else -> throw IllegalArgumentException("Invalid legacy batch boolean")
    }

    private fun parseChromaMode(value: String): Int {
        val number = value.toFloat()
        require(number.isFinite() && number == number.toInt().toFloat())
        return number.toInt()
    }
}
