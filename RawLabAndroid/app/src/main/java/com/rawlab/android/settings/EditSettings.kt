package com.rawlab.android.settings

import kotlin.math.ceil
import kotlin.math.floor
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.geometry.GeometrySettings

data class ProcessingIdentity(val family: String = "rawlab", val version: Int = 2, val quality: String = "standard") {
    init { require(family == "rawlab" && version in 1..2 && quality == "standard") }
    fun encode() = "$family,$version,$quality"
    companion object {
        val LEGACY = ProcessingIdentity(version = 1)
        val CURRENT = ProcessingIdentity()
        fun decode(value: String?): ProcessingIdentity {
            if (value == null) return LEGACY
            val fields = value.split(',')
            require(fields.size == 3)
            return ProcessingIdentity(fields[0], fields[1].toInt(), fields[2])
        }
    }
}

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
    val exposureMode: Int = 1,
    val hsl: HslSettings = HslSettings(),
    val recipeID: String? = null,
    val lens: LensSettings = LensSettings(),
    val geometry: GeometrySettings = GeometrySettings(),
    val processing: ProcessingIdentity = ProcessingIdentity.CURRENT,
    val blackPoint: Float = 0f,
    val whitePoint: Float = 0f,
    val vibrance: Float = 0f,
    val colorGrading: ColorGradingSettings = ColorGradingSettings(),
    val curve: ToneCurveSettings = ToneCurveSettings(),
) {
    init {
        require(listOf(blackPoint, whitePoint, vibrance).all { it.isFinite() && it in -100f..100f })
        require(exposureMode in 0..2)
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
    fun reset() = EditSettings(film = film, processing = processing)

    /** Camera-only controls are resolved per target; the persisted edit remains unchanged. */
    fun effectiveFor(input: PhotoInputKind): EditSettings = if (input == PhotoInputKind.RASTER) copy(
        exposureMode = 2,
        customWb = false,
        temperature = 6500f,
        tint = 0f,
        lens = LensSettings(),
    ) else this
    fun resetWhiteBalance(asShotTemperature: Float?, asShotTint: Float?): EditSettings = copy(
        customWb = false,
        temperature = asShotTemperature ?: 6500f,
        tint = if (recipeID == null) asShotTint ?: 0f else 0f,
    )
    val recipeScale get() = if (recipeID == null) 1f else strength
    val renderHsl get() = hsl.scaled(recipeScale)
    val renderToneCurve get() = if (curve.mode == ToneCurveMode.CUSTOM) 0f else toneCurve
    fun selectFilm(id: String, cameraTint: Float? = null): EditSettings {
        if (recipeID == null) return copy(film = id)
        val baseTint = cameraTint?.takeIf { it.isFinite() }
        val independent = if (!customWb && (tint == 0f || baseTint == null))
            copy(recipeID = null, tint = baseTint ?: 0f)
        else copy(recipeID = null, customWb = true, tint = ((baseTint ?: 0f) + tint).coerceIn(-150f, 150f))
        return independent.copy(film = id)
    }
}

data class LensSettings(val distortion: Boolean = false, val tca: Boolean = false,
    val autoCrop: Boolean = true, val manual: Boolean = false, val profileId: String? = null) {
    val enabled: Boolean get() = distortion || tca
    val coreProfileId: String get() = if (manual) profileId ?: "__rawlab_manual_selection_required__" else ""
    fun encode(): String = listOf(if (distortion) 1 else 0, if (tca) 1 else 0,
        if (autoCrop) 1 else 0, if (manual) 1 else 0,
        profileId?.let { java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(it.toByteArray(Charsets.UTF_8)) } ?: "")
        .joinToString("|")
    companion object {
        fun decode(value: String?): LensSettings {
            if (value == null) return LensSettings()
            val fields = value.split('|')
            require(fields.size == 5 && fields.take(4).all { it == "0" || it == "1" })
            return LensSettings(fields[0] == "1", fields[1] == "1", fields[2] == "1", fields[3] == "1",
                fields[4].takeIf { it.isNotEmpty() }?.let { String(java.util.Base64.getUrlDecoder().decode(it), Charsets.UTF_8) })
        }
    }
}

enum class DenoisePreset { DETAIL, CLEAN, CUSTOM }

class HslSettings(values: List<Float> = List(24) { 0f }) {
    private val values = values.toList()
    init { require(this.values.size == 24 && this.values.all { it.isFinite() && it in -100f..100f }) }
    val isIdentity get() = values.all { it == 0f }
    fun packed() = values.toFloatArray()
    fun scaled(strength: Float) = HslSettings(values.map { (it * strength).coerceIn(-100f, 100f) })
    fun value(axis: Int, channel: Int) = values[axis * 8 + channel]
    fun withValue(axis: Int, channel: Int, value: Float): HslSettings {
        require(axis in 0..2 && channel in 0..7)
        if (!value.isFinite()) return this
        return HslSettings(values.toMutableList().also { it[axis * 8 + channel] = value.coerceIn(-100f, 100f) })
    }
    override fun equals(other: Any?) = other is HslSettings && values == other.values
    override fun hashCode() = values.hashCode()
}

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

data class Film(val id: String, val name: String, val file: String?, val artworkName: String = id) {
    val fileName: String? get() = file?.let { if (it.endsWith(".cube")) it else "FLog2_to_${it}_65grid_V.1.00.cube" }
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

internal data class ResetRenderValues(
    val core: List<Float>, val temperature: Float, val tint: Float,
)

/**
 * 重置外观前捕获 JNI 非外观 Float 值。
 * 计算顺序对应 rawlab_jni.cpp 的 prepareRecipeWb/recipeActive 分支及 render_request.h；
 * HSL 直接消费既有 renderHsl，避免把旧记录的小数再次送进输入控件量化。
 */
internal fun EditSettings.resetRenderValues(
    input: PhotoInputKind, asShotTemperature: Float?, asShotTint: Float?,
): ResetRenderValues? {
    val effective = effectiveFor(input)
    var custom = effective.customWb
    var kelvin = effective.temperature
    var wbTint = effective.tint
    if (input == PhotoInputKind.RAW && recipeID != null && (custom || tint * strength != 0f)) {
        if (asShotTemperature == null || asShotTint == null ||
            !asShotTemperature.isFinite() || !asShotTint.isFinite()) return null
        if (!custom) kelvin = nativeRound(asShotTemperature)
        wbTint = (nativeRound(asShotTint) + tint * strength).coerceIn(-150f, 150f)
        custom = true
    }
    return ResetRenderValues(listOf(exposure * recipeScale, -highlights * recipeScale, shadows * recipeScale,
        1f + contrast * recipeScale, toneCurve, 1f + saturation * recipeScale, sharpening,
        effective.exposureMode.toFloat(), if (custom) 1f else 0f,
        if (custom) kelvin else 6500f, if (custom) wbTint else 0f) + renderHsl.packed().toList(), kelvin, wbTint)
}

// Float 上先加 0.5 会把 0.49999997 提前进位；转成 Double 后再取整才能对应 std::round(float)。
internal fun nativeRound(value: Float): Float =
    (if (value >= 0f) floor(value.toDouble() + .5) else ceil(value.toDouble() - .5)).toFloat()

/** 无法用现有字段精确表示时返回 null；不夹紧物化后的普通调整值。 */
internal fun EditSettings.independentForReset(
    input: PhotoInputKind, asShotTemperature: Float?, asShotTint: Float?,
): EditSettings? {
    val before = resetRenderValues(input, asShotTemperature, asShotTint) ?: return null
    val scaledExposure = exposure * recipeScale
    val scaledHighlights = highlights * recipeScale
    val scaledShadows = shadows * recipeScale
    val scaledContrast = contrast * recipeScale
    val scaledSaturation = saturation * recipeScale
    val convertWb = input == PhotoInputKind.RAW && recipeID != null && (customWb || tint * strength != 0f)
    if (scaledExposure !in -4f..4f ||
        listOf(scaledHighlights, scaledShadows, scaledContrast, scaledSaturation).any { it !in -1f..1f } ||
        (convertWb && (before.temperature !in 2000f..50000f || before.tint !in -150f..150f))) return null
    val candidate = copy(film = "neutral", recipeID = null, strength = 1f,
        exposure = scaledExposure, highlights = scaledHighlights, shadows = scaledShadows,
        contrast = scaledContrast, saturation = scaledSaturation, hsl = renderHsl,
        customWb = if (convertWb) true else customWb,
        temperature = if (convertWb) before.temperature else temperature,
        tint = if (convertWb) before.tint else if (input == PhotoInputKind.RAW && recipeID != null) 0f else tint)
    val after = candidate.resetRenderValues(input, asShotTemperature, asShotTint) ?: return null
    return candidate.takeIf { before.core.size == after.core.size && before.core.zip(after.core).all { (a, b) -> a == b } }
}
