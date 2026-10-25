package com.rawlab.android.adjustments

import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.settings.*

internal object AdjustmentTransferValues {
    val scalars = setOf(AdjustmentField.STRENGTH, AdjustmentField.EXPOSURE, AdjustmentField.CONTRAST,
        AdjustmentField.HIGHLIGHTS, AdjustmentField.SHADOWS, AdjustmentField.S_CURVE,
        AdjustmentField.SATURATION, AdjustmentField.SHARPENING, AdjustmentField.BLACK_POINT, AdjustmentField.WHITE_POINT, AdjustmentField.VIBRANCE, AdjustmentField.CLARITY, AdjustmentField.DEHAZE)
    val effects = AdjustmentField.entries.filter { it.id.startsWith("effects.vignette.") || it.id.startsWith("effects.grain.") }.toSet()
    val scaled = setOf(AdjustmentField.EXPOSURE, AdjustmentField.CONTRAST, AdjustmentField.HIGHLIGHTS,
        AdjustmentField.SHADOWS, AdjustmentField.SATURATION)
    fun logical(settings: EditSettings, field: AdjustmentField): Double = when (field) {
        AdjustmentField.STRENGTH -> settings.strength.toDouble()
        AdjustmentField.EXPOSURE -> settings.exposure.toDouble()
        AdjustmentField.CONTRAST -> 1.0 + settings.contrast.toDouble()
        AdjustmentField.HIGHLIGHTS -> -settings.highlights.toDouble()
        AdjustmentField.SHADOWS -> settings.shadows.toDouble()
        AdjustmentField.S_CURVE -> settings.toneCurve.toDouble()
        AdjustmentField.SATURATION -> 1.0 + settings.saturation.toDouble()
        AdjustmentField.BLACK_POINT -> settings.blackPoint.toDouble()
        AdjustmentField.WHITE_POINT -> settings.whitePoint.toDouble()
        AdjustmentField.VIBRANCE -> settings.vibrance.toDouble()
        AdjustmentField.CLARITY -> settings.clarity.toDouble()
        AdjustmentField.DEHAZE -> settings.dehaze.toDouble()
        AdjustmentField.SHARPENING -> settings.sharpening.toDouble()
        else -> field.hslLocation!!.let { (axis, channel) -> settings.hsl.value(axis, channel).toDouble() }
    }
    fun setLogical(settings: EditSettings, field: AdjustmentField, value: Double): EditSettings = when (field) {
        AdjustmentField.STRENGTH -> settings.copy(strength = value.toFloat())
        AdjustmentField.EXPOSURE -> settings.copy(exposure = value.toFloat())
        AdjustmentField.CONTRAST -> settings.copy(contrast = (value - 1).toFloat())
        AdjustmentField.HIGHLIGHTS -> settings.copy(highlights = -value.toFloat())
        AdjustmentField.SHADOWS -> settings.copy(shadows = value.toFloat())
        AdjustmentField.S_CURVE -> settings.copy(toneCurve = value.toFloat())
        AdjustmentField.SATURATION -> settings.copy(saturation = (value - 1).toFloat())
        AdjustmentField.BLACK_POINT -> settings.copy(blackPoint = value.toFloat())
        AdjustmentField.WHITE_POINT -> settings.copy(whitePoint = value.toFloat())
        AdjustmentField.VIBRANCE -> settings.copy(vibrance = value.toFloat())
        AdjustmentField.CLARITY -> settings.copy(clarity = value.toFloat())
        AdjustmentField.DEHAZE -> settings.copy(dehaze = value.toFloat())
        AdjustmentField.SHARPENING -> settings.copy(sharpening = value.toFloat())
        else -> {
            val (axis, channel) = field.hslLocation!!
            settings.copy(hsl = HslSettings(settings.hsl.packed().toMutableList().also { it[axis * 8 + channel] = value.toFloat() }))
        }
    }

    fun values(s: EditSettings, context: AdjustmentTransferContext): Map<AdjustmentField, AdjustmentValue> {
        val values = linkedMapOf<AdjustmentField, AdjustmentValue>()
        values[AdjustmentField.CURVE] = AdjustmentPayload.curveValue(s.curve)
        fun number(field: AdjustmentField, value: Number) { values[field] = AdjustmentValue.Number(value.toDouble()) }
        fun boolean(field: AdjustmentField, value: Boolean) { values[field] = AdjustmentValue.Boolean(value) }
        for (field in scalars + AdjustmentField.entries.filter { it.hslLocation != null }) number(field, logical(s, field))
        for (field in AdjustmentField.entries) field.gradingZone?.let { zone ->
            values[field] = AdjustmentValue.Object(mapOf("hue" to AdjustmentValue.Number(s.colorGrading[zone].hue.toDouble()),
                "saturation" to AdjustmentValue.Number(s.colorGrading[zone].saturation.toDouble())))
        }
        val kind: String; val id: String?
        when {
            s.recipeID != null -> { kind = "recipe"; id = s.recipeID }
            s.film == "neutral" -> { kind = "neutral"; id = null }
            s.film.startsWith("recipe-lut:") -> { kind = "recipe_lut"; id = s.film.removePrefix("recipe-lut:") }
            else -> {
                val builtIn = context.builtinLookIDs.entries.firstOrNull { it.value == s.film }?.key
                kind = if (builtIn == null) "managed" else "builtin"; id = builtIn ?: s.film
            }
        }
        values[AdjustmentField.LOOK] = AdjustmentValue.Object(mapOf("kind" to AdjustmentValue.Text(kind),
            "id" to (id?.let(AdjustmentValue::Text) ?: AdjustmentValue.Null)))
        values[AdjustmentField.EXPOSURE_MODE] = AdjustmentValue.Text(if (!context.isRaw) "sensor" else listOf("scene", "preview", "sensor")[s.exposureMode])
        val camera = !context.isRaw || !s.customWb
        values[AdjustmentField.WHITE_BALANCE_MODE] = AdjustmentValue.Text(if (!context.isRaw) "none" else if (camera) "camera" else "temperature")
        values[AdjustmentField.TEMPERATURE] = if (camera) AdjustmentValue.Null else AdjustmentValue.Number(s.temperature.toDouble())
        values[AdjustmentField.TINT] = if (s.recipeID != null || !camera) AdjustmentValue.Number(s.tint.toDouble()) else AdjustmentValue.Null
        with(s.effects) {
            number(AdjustmentField.VIGNETTE_AMOUNT, vignetteAmount); number(AdjustmentField.VIGNETTE_MIDPOINT, vignetteMidpoint)
            number(AdjustmentField.VIGNETTE_ROUNDNESS, vignetteRoundness); number(AdjustmentField.VIGNETTE_FEATHER, vignetteFeather)
            number(AdjustmentField.VIGNETTE_HIGHLIGHTS, vignetteHighlights); number(AdjustmentField.GRAIN_AMOUNT, grainAmount)
            number(AdjustmentField.GRAIN_SIZE, grainSize); number(AdjustmentField.GRAIN_ROUGHNESS, grainRoughness)
        }
        number(AdjustmentField.RAW_DENOISE, 0); number(AdjustmentField.POST_RGB_DENOISE, 0)
        number(AdjustmentField.CHROMA_DENOISE, s.displayChromaDenoise)
        values[AdjustmentField.WAVELET_DENOISE] = AdjustmentValue.Object(mapOf(
            "enabled" to AdjustmentValue.Boolean(s.denoise.enabled), "luma" to AdjustmentValue.Number(s.denoise.luma.toDouble()),
            "chroma" to AdjustmentValue.Number(s.denoise.chroma.toDouble()), "coarse" to AdjustmentValue.Number(s.denoise.coarse.toDouble()),
            "preset" to AdjustmentValue.Text(s.denoise.preset.name.lowercase())))
        with(s.geometry) {
            number(AdjustmentField.CROP_X, cropX); number(AdjustmentField.CROP_Y, cropY)
            number(AdjustmentField.CROP_WIDTH, cropWidth); number(AdjustmentField.CROP_HEIGHT, cropHeight)
            number(AdjustmentField.QUARTER_TURNS, quarterTurns); boolean(AdjustmentField.FLIP_HORIZONTAL, flipHorizontal)
            boolean(AdjustmentField.FLIP_VERTICAL, flipVertical); number(AdjustmentField.STRAIGHTEN, straightenDegrees)
            number(AdjustmentField.PERSPECTIVE_HORIZONTAL, perspectiveHorizontal); number(AdjustmentField.PERSPECTIVE_VERTICAL, perspectiveVertical)
        }
        val lens = if (context.isRaw) s.lens else LensSettings()
        boolean(AdjustmentField.LENS_DISTORTION, lens.distortion); boolean(AdjustmentField.LENS_TCA, lens.tca)
        boolean(AdjustmentField.LENS_AUTO_CROP, lens.autoCrop)
        values[AdjustmentField.LENS_PROFILE] = if (!lens.manual) AdjustmentValue.Null else AdjustmentValue.Text(lens.coreProfileId)
        return values
    }

    fun applyObjects(payload: AdjustmentPayload, original: EditSettings, context: AdjustmentTransferContext): EditSettings {
        fun number(field: AdjustmentField, fallback: Float) = payload[field]?.number?.toFloat() ?: fallback
        fun boolean(field: AdjustmentField, fallback: Boolean) = payload[field]?.boolean ?: fallback
        for (field in listOf(AdjustmentField.RAW_DENOISE, AdjustmentField.POST_RGB_DENOISE)) {
            if (payload[field]?.number?.let { it != 0.0 } == true) throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, field.id)
        }
        var result = original
        payload[AdjustmentField.CURVE]?.let { result = result.copy(curve = AdjustmentPayload.curve(it)) }
        for (field in payload.fields) field.gradingZone?.let { zone ->
            val wheel = payload[field]!!.objectValue!!
            result = result.copy(colorGrading = result.colorGrading.with(zone,
                ColorGradingWheel.fromNumbers(wheel["hue"]!!.number!!, wheel["saturation"]!!.number!!)))
        }
        payload[AdjustmentField.CHROMA_DENOISE]?.let { result = result.copy(displayChromaDenoise = it.number?.toInt() ?: 0) }
        payload[AdjustmentField.WAVELET_DENOISE]?.let { value ->
            val wavelet = value.objectValue
            val denoise = if (wavelet == null) DenoiseSettings() else DenoiseSettings(wavelet["enabled"]!!.boolean!!,
                wavelet["luma"]!!.number!!.toFloat(), wavelet["chroma"]!!.number!!.toFloat(), wavelet["coarse"]!!.number!!.toFloat())
            if (wavelet != null && denoise.preset.name.lowercase() != wavelet["preset"]!!.text)
                throw AdjustmentTransferException(AdjustmentFailure.UNREPRESENTABLE, "detail.denoise.wavelet.preset")
            result = result.copy(denoise = denoise)
        }
        if (payload.fields.any { it in effects }) result = result.copy(effects = with(original.effects) {
            PhotoEffectsSettings(number(AdjustmentField.VIGNETTE_AMOUNT, vignetteAmount), number(AdjustmentField.VIGNETTE_MIDPOINT, vignetteMidpoint),
                number(AdjustmentField.VIGNETTE_ROUNDNESS, vignetteRoundness), number(AdjustmentField.VIGNETTE_FEATHER, vignetteFeather),
                number(AdjustmentField.VIGNETTE_HIGHLIGHTS, vignetteHighlights), number(AdjustmentField.GRAIN_AMOUNT, grainAmount),
                number(AdjustmentField.GRAIN_SIZE, grainSize), number(AdjustmentField.GRAIN_ROUGHNESS, grainRoughness))
        })
        if (payload.fields.any { it.group == "geometry" && it !in AdjustmentField.LENS }) result = result.copy(geometry = with(original.geometry) {
            GeometrySettings(number(AdjustmentField.CROP_X, cropX), number(AdjustmentField.CROP_Y, cropY),
                number(AdjustmentField.CROP_WIDTH, cropWidth), number(AdjustmentField.CROP_HEIGHT, cropHeight),
                payload[AdjustmentField.QUARTER_TURNS]?.number?.toInt() ?: quarterTurns,
                boolean(AdjustmentField.FLIP_HORIZONTAL, flipHorizontal), boolean(AdjustmentField.FLIP_VERTICAL, flipVertical),
                number(AdjustmentField.STRAIGHTEN, straightenDegrees), number(AdjustmentField.PERSPECTIVE_HORIZONTAL, perspectiveHorizontal),
                number(AdjustmentField.PERSPECTIVE_VERTICAL, perspectiveVertical))
        })
        if (payload.fields.any { it in AdjustmentField.LENS }) {
            if (!context.isRaw) {
                val neutral = mapOf(AdjustmentField.LENS_DISTORTION to AdjustmentValue.Boolean(false),
                    AdjustmentField.LENS_TCA to AdjustmentValue.Boolean(false), AdjustmentField.LENS_AUTO_CROP to AdjustmentValue.Boolean(true),
                    AdjustmentField.LENS_PROFILE to AdjustmentValue.Null)
                if (neutral.any { (field, value) -> payload[field] != null && payload[field] != value })
                    throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "geometry.lens")
            }
            val profile = payload[AdjustmentField.LENS_PROFILE]
            val lens = with(original.lens) { copy(distortion = boolean(AdjustmentField.LENS_DISTORTION, distortion),
                tca = boolean(AdjustmentField.LENS_TCA, tca), autoCrop = boolean(AdjustmentField.LENS_AUTO_CROP, autoCrop),
                manual = if (profile != null) profile != AdjustmentValue.Null else manual,
                profileId = if (profile != null) profile.text?.takeUnless { it == LensSettings(manual = true).coreProfileId } else profileId) }
            if (lens.enabled && lens.manual && lens.profileId == null)
                throw AdjustmentTransferException(AdjustmentFailure.UNREPRESENTABLE, AdjustmentField.LENS_PROFILE.id)
            if (lens.enabled) {
                if (!context.isRaw || context.validateLens == null) throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "target lens calibration unavailable")
                context.validateLens.invoke(lens)
            }
            result = result.copy(lens = lens)
        }
        return result
    }
}
