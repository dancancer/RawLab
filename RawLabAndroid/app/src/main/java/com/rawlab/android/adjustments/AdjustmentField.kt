package com.rawlab.android.adjustments

/** 跨端逻辑字段；与 Shared/AdjustmentTransfer.swift 及同一 JSON 向量保持一致。 */
enum class AdjustmentField(val id: String) {
    LOOK("looks.reference"),
    STRENGTH("looks.strength"),
    EXPOSURE("light.exposure"),
    EXPOSURE_MODE("light.exposure_mode"),
    CONTRAST("light.contrast"),
    HIGHLIGHTS("light.highlights"),
    SHADOWS("light.shadows"),
    S_CURVE("light.s_curve"),
    WHITE_BALANCE_MODE("color.white_balance.mode"),
    TEMPERATURE("color.white_balance.temperature_kelvin"),
    TINT("color.white_balance.tint"),
    SATURATION("color.saturation"),
    HSL_HUE_RED("color.hsl.hue.red"),
    HSL_HUE_ORANGE("color.hsl.hue.orange"),
    HSL_HUE_YELLOW("color.hsl.hue.yellow"),
    HSL_HUE_GREEN("color.hsl.hue.green"),
    HSL_HUE_AQUA("color.hsl.hue.aqua"),
    HSL_HUE_BLUE("color.hsl.hue.blue"),
    HSL_HUE_PURPLE("color.hsl.hue.purple"),
    HSL_HUE_MAGENTA("color.hsl.hue.magenta"),
    HSL_SATURATION_RED("color.hsl.saturation.red"),
    HSL_SATURATION_ORANGE("color.hsl.saturation.orange"),
    HSL_SATURATION_YELLOW("color.hsl.saturation.yellow"),
    HSL_SATURATION_GREEN("color.hsl.saturation.green"),
    HSL_SATURATION_AQUA("color.hsl.saturation.aqua"),
    HSL_SATURATION_BLUE("color.hsl.saturation.blue"),
    HSL_SATURATION_PURPLE("color.hsl.saturation.purple"),
    HSL_SATURATION_MAGENTA("color.hsl.saturation.magenta"),
    HSL_LIGHTNESS_RED("color.hsl.lightness.red"),
    HSL_LIGHTNESS_ORANGE("color.hsl.lightness.orange"),
    HSL_LIGHTNESS_YELLOW("color.hsl.lightness.yellow"),
    HSL_LIGHTNESS_GREEN("color.hsl.lightness.green"),
    HSL_LIGHTNESS_AQUA("color.hsl.lightness.aqua"),
    HSL_LIGHTNESS_BLUE("color.hsl.lightness.blue"),
    HSL_LIGHTNESS_PURPLE("color.hsl.lightness.purple"),
    HSL_LIGHTNESS_MAGENTA("color.hsl.lightness.magenta"),
    VIGNETTE_AMOUNT("effects.vignette.amount"),
    VIGNETTE_MIDPOINT("effects.vignette.midpoint"),
    VIGNETTE_ROUNDNESS("effects.vignette.roundness"),
    VIGNETTE_FEATHER("effects.vignette.feather"),
    VIGNETTE_HIGHLIGHTS("effects.vignette.highlights"),
    GRAIN_AMOUNT("effects.grain.amount"),
    GRAIN_SIZE("effects.grain.size"),
    GRAIN_ROUGHNESS("effects.grain.roughness"),
    SHARPENING("detail.sharpening"),
    RAW_DENOISE("detail.denoise.raw_level"),
    POST_RGB_DENOISE("detail.denoise.post_rgb"),
    CHROMA_DENOISE("detail.denoise.chroma_mode"),
    WAVELET_DENOISE("detail.denoise.wavelet"),
    CROP_X("geometry.crop.x"),
    CROP_Y("geometry.crop.y"),
    CROP_WIDTH("geometry.crop.width"),
    CROP_HEIGHT("geometry.crop.height"),
    QUARTER_TURNS("geometry.quarter_turns"),
    FLIP_HORIZONTAL("geometry.flip_horizontal"),
    FLIP_VERTICAL("geometry.flip_vertical"),
    STRAIGHTEN("geometry.straighten_degrees"),
    PERSPECTIVE_HORIZONTAL("geometry.perspective.horizontal"),
    PERSPECTIVE_VERTICAL("geometry.perspective.vertical"),
    LENS_DISTORTION("geometry.lens.distortion"),
    LENS_TCA("geometry.lens.tca"),
    LENS_AUTO_CROP("geometry.lens.auto_crop"),
    LENS_PROFILE("geometry.lens.profile_id");

    val group get() = id.substringBefore('.')
    val hslLocation: Pair<Int, Int>? get() {
        val parts = id.split('.')
        if (parts.size != 4 || parts[1] != "hsl") return null
        return listOf("hue", "saturation", "lightness").indexOf(parts[2]) to
            listOf("red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta").indexOf(parts[3])
    }
    val scalarRange: ClosedFloatingPointRange<Double>? get() = when {
        hslLocation != null -> -100.0..100.0
        else -> when (this) {
            STRENGTH, CONTRAST, SATURATION, SHARPENING -> 0.0..2.0
            EXPOSURE -> -20.0..20.0
            HIGHLIGHTS, SHADOWS, S_CURVE, PERSPECTIVE_HORIZONTAL, PERSPECTIVE_VERTICAL -> -1.0..1.0
            VIGNETTE_AMOUNT, VIGNETTE_ROUNDNESS -> -100.0..100.0
            VIGNETTE_MIDPOINT, VIGNETTE_FEATHER, VIGNETTE_HIGHLIGHTS, GRAIN_AMOUNT, GRAIN_SIZE, GRAIN_ROUGHNESS -> 0.0..100.0
            QUARTER_TURNS -> 0.0..3.0
            CROP_X, CROP_Y, CROP_WIDTH, CROP_HEIGHT, POST_RGB_DENOISE -> 0.0..1.0
            STRAIGHTEN -> -45.0..45.0
            else -> null
        }
    }

    companion object {
        val COMMON = entries.filterTo(linkedSetOf()) { it.group != "geometry" }
        val WHITE_BALANCE = setOf(WHITE_BALANCE_MODE, TEMPERATURE, TINT)
        val LENS = setOf(LENS_DISTORTION, LENS_TCA, LENS_AUTO_CROP, LENS_PROFILE)
        val DENOISE = setOf(RAW_DENOISE, POST_RGB_DENOISE, CHROMA_DENOISE, WAVELET_DENOISE)
        val RECIPE_DEPENDENCIES = setOf(LOOK, STRENGTH, EXPOSURE, CONTRAST, HIGHLIGHTS, SHADOWS, SATURATION) +
            WHITE_BALANCE + entries.filter { it.hslLocation != null }
        fun fromID(id: String) = entries.firstOrNull { it.id == id }
    }
}

sealed interface AdjustmentScope {
    data object All : AdjustmentScope
    data object Modified : AdjustmentScope
    data class Custom(val fields: Set<AdjustmentField>) : AdjustmentScope
}
