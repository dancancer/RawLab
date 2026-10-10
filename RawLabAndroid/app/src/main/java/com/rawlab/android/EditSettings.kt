package com.rawlab.android

import kotlin.math.ceil
import kotlin.math.floor

data class EditSettings(
    val film: String = "neutral",
    val strength: Float = 1f,
    val exposure: Float = 0f,
    val highlights: Float = 0f,
    val shadows: Float = 0f,
    val contrast: Float = 0f,
    val toneCurve: Float = 0f,
    val saturation: Float = 0f,
    val customWb: Boolean = false,
    val temperature: Float = 6500f,
    val tint: Float = 0f,
    val denoise: DenoiseSettings = DenoiseSettings(),
    val sharpening: Float = 0f,
    val effects: PhotoEffectsSettings = PhotoEffectsSettings(),
    val displayChromaDenoise: Int = 0,
) {
    init {
        require(strength.isFinite() && strength in 0f..2f)
        require(exposure.isFinite() && exposure in -4f..4f)
        require(highlights.isFinite() && highlights in -1f..1f)
        require(shadows.isFinite() && shadows in -1f..1f)
        require(contrast.isFinite() && contrast in -1f..1f)
        require(toneCurve.isFinite() && toneCurve in -1f..1f)
        require(saturation.isFinite() && saturation in -1f..1f)
        require(temperature.isFinite() && temperature in 2000f..50000f)
        require(tint.isFinite() && tint in -150f..150f)
        require(sharpening.isFinite() && sharpening in 0f..2f)
        require(displayChromaDenoise in 0..2)
    }
    fun reset() = EditSettings(film = film)
}

enum class DenoisePreset { DETAIL, CLEAN, CUSTOM }

data class DenoiseSettings(val enabled: Boolean = false, val luma: Float = 0f,
    val chroma: Float = 46f, val coarse: Float = 50f) {
    init { require(listOf(luma, chroma, coarse).all { it.isFinite() && it in 0f..100f }) }
    val preset: DenoisePreset get() = when {
        luma == 0f && chroma == 46f && coarse == 50f -> DenoisePreset.DETAIL
        luma == 10f && chroma == 72f && coarse == 100f -> DenoisePreset.CLEAN
        else -> DenoisePreset.CUSTOM
    }
    fun withPreset(value: DenoisePreset) = when (value) {
        DenoisePreset.DETAIL -> DenoiseSettings(enabled = true)
        DenoisePreset.CLEAN -> DenoiseSettings(true, 10f, 72f, 100f)
        DenoisePreset.CUSTOM -> this
    }
}

enum class PhotoEffectParameter(
    val isVignette: Boolean,
    val range: ClosedFloatingPointRange<Float>,
    val defaultValue: Float,
) {
    VIGNETTE_AMOUNT(true, -100f..100f, 0f),
    VIGNETTE_MIDPOINT(true, 0f..100f, 50f),
    VIGNETTE_ROUNDNESS(true, -100f..100f, 0f),
    VIGNETTE_FEATHER(true, 0f..100f, 50f),
    VIGNETTE_HIGHLIGHTS(true, 0f..100f, 0f),
    GRAIN_AMOUNT(false, 0f..100f, 0f),
    GRAIN_SIZE(false, 0f..100f, 25f),
    GRAIN_ROUGHNESS(false, 0f..100f, 50f),
}

data class PhotoEffectsSettings(
    val vignetteAmount: Float = 0f,
    val vignetteMidpoint: Float = 50f,
    val vignetteRoundness: Float = 0f,
    val vignetteFeather: Float = 50f,
    val vignetteHighlights: Float = 0f,
    val grainAmount: Float = 0f,
    val grainSize: Float = 25f,
    val grainRoughness: Float = 50f,
) {
    init {
        require(vignetteAmount.isFinite() && vignetteAmount in -100f..100f)
        require(vignetteMidpoint.isFinite() && vignetteMidpoint in 0f..100f)
        require(vignetteRoundness.isFinite() && vignetteRoundness in -100f..100f)
        require(vignetteFeather.isFinite() && vignetteFeather in 0f..100f)
        require(vignetteHighlights.isFinite() && vignetteHighlights in 0f..100f)
        require(grainAmount.isFinite() && grainAmount in 0f..100f)
        require(grainSize.isFinite() && grainSize in 0f..100f)
        require(grainRoughness.isFinite() && grainRoughness in 0f..100f)
    }

    /** Numeric controls clamp finite input and ignore non-finite drafts. */
    fun withEffect(parameter: PhotoEffectParameter, value: Float): PhotoEffectsSettings {
        if (!value.isFinite()) return this
        val rounded = if (value >= 0f) floor(value + .5f) else ceil(value - .5f)
        val normalized = rounded.coerceIn(parameter.range.start, parameter.range.endInclusive)
        return when (parameter) {
            PhotoEffectParameter.VIGNETTE_AMOUNT -> copy(vignetteAmount = normalized)
            PhotoEffectParameter.VIGNETTE_MIDPOINT -> copy(vignetteMidpoint = normalized)
            PhotoEffectParameter.VIGNETTE_ROUNDNESS -> copy(vignetteRoundness = normalized)
            PhotoEffectParameter.VIGNETTE_FEATHER -> copy(vignetteFeather = normalized)
            PhotoEffectParameter.VIGNETTE_HIGHLIGHTS -> copy(vignetteHighlights = normalized)
            PhotoEffectParameter.GRAIN_AMOUNT -> copy(grainAmount = normalized)
            PhotoEffectParameter.GRAIN_SIZE -> copy(grainSize = normalized)
            PhotoEffectParameter.GRAIN_ROUGHNESS -> copy(grainRoughness = normalized)
        }
    }

    fun value(parameter: PhotoEffectParameter): Float = when (parameter) {
        PhotoEffectParameter.VIGNETTE_AMOUNT -> vignetteAmount
        PhotoEffectParameter.VIGNETTE_MIDPOINT -> vignetteMidpoint
        PhotoEffectParameter.VIGNETTE_ROUNDNESS -> vignetteRoundness
        PhotoEffectParameter.VIGNETTE_FEATHER -> vignetteFeather
        PhotoEffectParameter.VIGNETTE_HIGHLIGHTS -> vignetteHighlights
        PhotoEffectParameter.GRAIN_AMOUNT -> grainAmount
        PhotoEffectParameter.GRAIN_SIZE -> grainSize
        PhotoEffectParameter.GRAIN_ROUGHNESS -> grainRoughness
    }

    fun resetEffects(vignette: Boolean): PhotoEffectsSettings =
        PhotoEffectParameter.entries.filter { it.isVignette == vignette }
            .fold(this) { state, parameter -> state.withEffect(parameter, parameter.defaultValue) }

    fun isEffectDefault(vignette: Boolean): Boolean =
        PhotoEffectParameter.entries.filter { it.isVignette == vignette }
            .all { value(it) == it.defaultValue }
}

data class Film(val id: String, val name: String, val file: String?) {
    companion object {
        val all = listOf(
            Film("neutral", "中性", null),
            Film("provia", "PROVIA", "PROVIA"), Film("velvia", "Velvia", "Velvia"),
            Film("astia", "ASTIA", "ASTIA"), Film("classic-chrome", "CLASSIC CHROME", "CLASSIC-CHROME"),
            Film("classic-neg", "CLASSIC Neg.", "CLASSIC-Neg."), Film("reala-ace", "REALA ACE", "REALA-ACE"),
            Film("pro-neg-std", "PRO Neg. Std", "PRO-Neg.Std"), Film("eterna", "ETERNA", "ETERNA"),
            Film("eterna-bb", "ETERNA BLEACH BYPASS", "ETERNA-BB"), Film("acros", "ACROS", "ACROS"),
        )
    }
}

data class LookChoice(val id: String, val name: String, val managed: Boolean, val available: Boolean = true) {
    companion object {
        val builtIns = Film.all.map { Film(it.id, it.name, it.file).toChoice() }

        private fun Film.toChoice() = LookChoice(id, name, managed = false)
    }
}
