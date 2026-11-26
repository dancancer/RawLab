package com.rawlab.android.settings

import com.rawlab.android.adjustments.AdjustmentFieldSpec

enum class GrainToneCurve(val wireValue: String) {
    LEGACY("legacy"),
    NEGATIVE_ASYMMETRIC("negative_asymmetric");

    companion object {
        fun fromWire(value: String?): GrainToneCurve = when (value) {
            null, "legacy" -> LEGACY
            "negative_asymmetric" -> NEGATIVE_ASYMMETRIC
            else -> throw IllegalArgumentException("Unknown grainToneCurve: $value")
        }
    }
}

enum class GrainFormatPreset(val wireValue: String) {
    CUSTOM("custom"),
    FILM_135("135"),
    FILM_120("120");

    companion object {
        fun fromWire(value: String?): GrainFormatPreset = when (value) {
            null, "custom" -> CUSTOM
            "135" -> FILM_135
            "120" -> FILM_120
            else -> throw IllegalArgumentException("Unknown grainFormatPreset: $value")
        }
    }
}

data class CameraCalibrationSettings(
    val shadowTint: Float = 0f,
    val redHue: Float = 0f,
    val redSaturation: Float = 0f,
    val greenHue: Float = 0f,
    val greenSaturation: Float = 0f,
    val blueHue: Float = 0f,
    val blueSaturation: Float = 0f,
) {
    init {
        val range = AdjustmentFieldSpec.Fields.COLOR_CALIBRATION_SHADOW_TINT.androidModel.floatRange!!
        require(listOf(shadowTint, redHue, redSaturation, greenHue, greenSaturation, blueHue, blueSaturation)
            .all { it.isFinite() && it in range }) { "Calibration parameter out of range" }
    }
    val isDefault get() = this == CameraCalibrationSettings()
}

data class PointColorSwatch(
    val srcHue: Float = 0f,
    val srcSaturation: Float = 0.5f,
    val srcLuminance: Float = 0.5f,
    val hueShift: Float = 0f,
    val saturationShift: Float = 0f,
    val luminanceShift: Float = 0f,
    val range: Float = 50f,
    val hueRange: Float = 50f,
    val satRange: Float = 50f,
    val lumRange: Float = 50f,
    val variance: Float = 0f,
    val enabled: Boolean = true,
) {
    init {
        val sf = AdjustmentFieldSpec.SubFields.PointColor
        require(srcHue.isFinite() && srcHue >= sf.srcHueMin && srcHue < sf.srcHueMax) { "Invalid srcHue" }
        require(srcSaturation.isFinite() && srcSaturation.toDouble() in sf.srcSaturationMin..sf.srcSaturationMax) { "Invalid srcSaturation" }
        require(srcLuminance.isFinite() && srcLuminance.toDouble() in sf.srcLuminanceMin..sf.srcLuminanceMax) { "Invalid srcLuminance" }
        require(listOf(hueShift, saturationShift, luminanceShift, variance)
            .all { it.isFinite() && it.toDouble() in sf.shiftMin..sf.shiftMax }) { "Invalid shift" }
        require(listOf(range, hueRange, satRange, lumRange)
            .all { it.isFinite() && it.toDouble() in sf.rangeControlMin..sf.rangeControlMax }) { "Invalid range control" }
    }
}

data class PointColorSettings(val swatches: List<PointColorSwatch> = emptyList()) {
    init {
        require(swatches.size <= AdjustmentFieldSpec.SubFields.PointColor.maxSwatches) { "Too many swatches" }
    }
    val isDefault get() = swatches.isEmpty()
}

enum class SelectiveColorMethod(val wireValue: String) {
    RELATIVE("relative"),
    ABSOLUTE("absolute");

    companion object {
        fun fromWire(value: String?): SelectiveColorMethod = when (value) {
            null, "relative" -> RELATIVE
            "absolute" -> ABSOLUTE
            else -> throw IllegalArgumentException("Unknown selective color method: $value")
        }
    }
}

data class SelectiveColorBand(
    val cyan: Float = 0f,
    val magenta: Float = 0f,
    val yellow: Float = 0f,
    val black: Float = 0f,
) {
    init {
        val sf = AdjustmentFieldSpec.SubFields.SelectiveColor
        require(listOf(cyan, magenta, yellow, black).all { it.isFinite() && it.toDouble() in sf.componentMin..sf.componentMax }) {
            "Selective color component out of range"
        }
    }
    val isDefault get() = this == SelectiveColorBand()
}

data class SelectiveColorBands(
    val reds: SelectiveColorBand = SelectiveColorBand(),
    val yellows: SelectiveColorBand = SelectiveColorBand(),
    val greens: SelectiveColorBand = SelectiveColorBand(),
    val cyans: SelectiveColorBand = SelectiveColorBand(),
    val blues: SelectiveColorBand = SelectiveColorBand(),
    val magentas: SelectiveColorBand = SelectiveColorBand(),
    val whites: SelectiveColorBand = SelectiveColorBand(),
    val neutrals: SelectiveColorBand = SelectiveColorBand(),
    val blacks: SelectiveColorBand = SelectiveColorBand(),
) {
    fun asMap(): Map<String, SelectiveColorBand> = linkedMapOf(
        "reds" to reds, "yellows" to yellows, "greens" to greens, "cyans" to cyans,
        "blues" to blues, "magentas" to magentas, "whites" to whites, "neutrals" to neutrals, "blacks" to blacks,
    )
    val isDefault get() = this == SelectiveColorBands()
}

data class SelectiveColorSettings(
    val method: SelectiveColorMethod = SelectiveColorMethod.RELATIVE,
    val bands: SelectiveColorBands = SelectiveColorBands(),
) {
    val isDefault get() = method == SelectiveColorMethod.RELATIVE && bands.isDefault
}

data class BwMixerWeights(
    val red: Float = 0f,
    val orange: Float = 0f,
    val yellow: Float = 0f,
    val green: Float = 0f,
    val aqua: Float = 0f,
    val blue: Float = 0f,
    val purple: Float = 0f,
    val magenta: Float = 0f,
) {
    init {
        val sf = AdjustmentFieldSpec.SubFields.BwMixer
        require(listOf(red, orange, yellow, green, aqua, blue, purple, magenta)
            .all { it.isFinite() && it.toDouble() in sf.channelMin..sf.channelMax }) { "BW mixer weight out of range" }
    }
    fun asMap(): Map<String, Float> = linkedMapOf(
        "red" to red, "orange" to orange, "yellow" to yellow, "green" to green,
        "aqua" to aqua, "blue" to blue, "purple" to purple, "magenta" to magenta,
    )
    val isDefault get() = this == BwMixerWeights()
}

data class BwMixerSettings(
    val enabled: Boolean = false,
    val mixer: BwMixerWeights = BwMixerWeights(),
) {
    val isDefault get() = !enabled && mixer.isDefault
}

data class SharpenV2Settings(
    val luminanceV2: Boolean = false,
    val radius: Float = 1.0f,
    val detail: Float = 25f,
    val masking: Float = 0f,
) {
    init {
        val f = AdjustmentFieldSpec.Fields
        require(radius.isFinite() && radius in f.DETAIL_SHARPENING_RADIUS.androidModel.floatRange!!) { "Invalid sharpen radius" }
        require(detail.isFinite() && detail in f.DETAIL_SHARPENING_DETAIL.androidModel.floatRange!!) { "Invalid sharpen detail" }
        require(masking.isFinite() && masking in f.DETAIL_SHARPENING_MASKING.androidModel.floatRange!!) { "Invalid sharpen masking" }
    }
    val isDefault get() = this == SharpenV2Settings()
}

data class FilmOpticsSettings(
    val halationAmount: Float = 0f,
    val halationThreshold: Float = 75f,
    val halationRadius: Float = 35f,
    val halationHue: Float = 0f,
    val bloomAmount: Float = 0f,
    val bloomThreshold: Float = 70f,
    val bloomRadius: Float = 40f,
) {
    init {
        val f = AdjustmentFieldSpec.Fields
        require(halationAmount.isFinite() && halationAmount in f.EFFECTS_HALATION_AMOUNT.androidModel.floatRange!!)
        require(halationThreshold.isFinite() && halationThreshold in f.EFFECTS_HALATION_THRESHOLD.androidModel.floatRange!!)
        require(halationRadius.isFinite() && halationRadius in f.EFFECTS_HALATION_RADIUS.androidModel.floatRange!!)
        require(halationHue.isFinite() && halationHue in f.EFFECTS_HALATION_HUE.androidModel.floatRange!!)
        require(bloomAmount.isFinite() && bloomAmount in f.EFFECTS_BLOOM_AMOUNT.androidModel.floatRange!!)
        require(bloomThreshold.isFinite() && bloomThreshold in f.EFFECTS_BLOOM_THRESHOLD.androidModel.floatRange!!)
        require(bloomRadius.isFinite() && bloomRadius in f.EFFECTS_BLOOM_RADIUS.androidModel.floatRange!!)
    }
    val isDefault get() = this == FilmOpticsSettings()
    val isHalationDefault get() = halationAmount == 0f && halationThreshold == 75f && halationRadius == 35f && halationHue == 0f
    val isBloomDefault get() = bloomAmount == 0f && bloomThreshold == 70f && bloomRadius == 40f

    fun resetHalation(): FilmOpticsSettings = copy(
        halationAmount = 0f,
        halationThreshold = 75f,
        halationRadius = 35f,
        halationHue = 0f,
    )

    fun resetBloom(): FilmOpticsSettings = copy(
        bloomAmount = 0f,
        bloomThreshold = 70f,
        bloomRadius = 40f,
    )
}
