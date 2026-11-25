package com.rawlab.android.settings

import kotlin.math.ceil
import kotlin.math.floor
import com.rawlab.android.adjustments.AdjustmentFieldSpec
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.geometry.GeometrySettings

data class ProcessingIdentity(val family: String = "rawlab", val version: Int = 3, val quality: String = "standard") {
    init { require(family == "rawlab" && version in 1..3 && quality == "standard") }
    fun encode() = "$family,$version,$quality"
    companion object {
        val LEGACY = ProcessingIdentity(version = 1)
        val C5 = ProcessingIdentity(version = 2)
        val CURRENT = ProcessingIdentity()
        fun decode(value: String?): ProcessingIdentity {
            if (value == null) return LEGACY
            val fields = value.split(',')
            require(fields.size == 3)
            return ProcessingIdentity(fields[0], fields[1].toInt(), fields[2])
        }
    }
}

enum class X3fMode(val id: String, val nativeValue: Int) {
    LEGACY("legacy", 0), NORMAL("normal-v1", 1);
    companion object {
        fun decode(value: String): X3fMode = entries.firstOrNull { it.id == value }
            ?: throw IllegalArgumentException("Unsupported X3F rendering mode")
    }
}

data class EditSettings(
    val film: String = "neutral",
    val strength: Float = 1f,
    val exposure: Float = 0f,
    val highlights: Float = 0f,
    val shadows: Float = 0f,
    val contrast: Float = 1f,
    val toneCurve: Float = 0f,
    val saturation: Float = 1f,
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
    val x3fMode: X3fMode = X3fMode.NORMAL,
    val blackPoint: Float = 0f,
    val whitePoint: Float = 0f,
    val vibrance: Float = 0f,
    val clarity: Float = 0f,
    val dehaze: Float = 0f,
    val colorGrading: ColorGradingSettings = ColorGradingSettings(),
    val curve: ToneCurveSettings = ToneCurveSettings(),
    val masterRecipeSettingsVersion: Int = 3,
    /** Null preserves pre-HDR records as SDR; non-null also retains the inactive mode snapshot. */
    val hdr: HDRSettings? = null,
    val sdrSnapshot: String? = null,
    val proRAWDecodeVersion: Int? = null,
) {
    init {
        val f = AdjustmentFieldSpec.Fields
        require(masterRecipeSettingsVersion in 2..4)
        require(blackPoint.isFinite() && blackPoint in f.TONE_BLACK_POINT.androidModel.floatRange!!)
        require(whitePoint.isFinite() && whitePoint in f.TONE_WHITE_POINT.androidModel.floatRange!!)
        require(vibrance.isFinite() && vibrance in f.COLOR_VIBRANCE.androidModel.floatRange!!)
        require(clarity.isFinite() && clarity in f.EFFECTS_CLARITY.androidModel.floatRange!!)
        require(dehaze.isFinite() && dehaze in f.EFFECTS_DEHAZE.androidModel.floatRange!!)
        require(exposureMode in f.LIGHT_EXPOSURE_MODE.androidModel.min!!.toInt()..f.LIGHT_EXPOSURE_MODE.androidModel.max!!.toInt())
        require(strength.isFinite() && strength in f.LOOKS_STRENGTH.androidModel.floatRange!!)
        require(exposure.isFinite() && exposure in f.LIGHT_EXPOSURE.androidModel.floatRange!!)
        require(highlights.isFinite() && highlights in f.LIGHT_HIGHLIGHTS.androidModel.floatRange!!)
        require(shadows.isFinite() && shadows in f.LIGHT_SHADOWS.androidModel.floatRange!!)
        require(contrast.isFinite() && contrast in f.LIGHT_CONTRAST.androidModel.floatRange!!)
        require(toneCurve.isFinite() && toneCurve in f.LIGHT_S_CURVE.androidModel.floatRange!!)
        require(saturation.isFinite() && saturation in f.COLOR_SATURATION.androidModel.floatRange!!)
        require(temperature.isFinite() && temperature in f.COLOR_WHITE_BALANCE_TEMPERATURE_KELVIN.androidModel.floatRange!!)
        require(tint.isFinite() && tint in f.COLOR_WHITE_BALANCE_TINT.androidModel.floatRange!!)
        require(sharpening.isFinite() && sharpening in f.DETAIL_SHARPENING.androidModel.floatRange!!)
        require(displayChromaDenoise in f.DETAIL_DENOISE_CHROMA_MODE.androidModel.min!!.toInt()..f.DETAIL_DENOISE_CHROMA_MODE.androidModel.max!!.toInt())
        if (hdr == null) require(sdrSnapshot == null)
        else require(sdrSnapshot == null || sdrSnapshot.startsWith("v2:") || sdrSnapshot.startsWith("v3:"))
    }
    val isHDREditing get() = hdr?.mode == HDRMode.HDR

    fun reset(): EditSettings = if (isHDREditing) hdrDefaults()
    else EditSettings(film = film, processing = processing, x3fMode = x3fMode, hdr = hdr,
        proRAWDecodeVersion = proRAWDecodeVersion)

    fun selectX3fMode(mode: X3fMode): EditSettings = if (mode == X3fMode.NORMAL) copy(
        x3fMode = mode,
        lens = lens.copy(distortion = false, tca = false, vignetting = false),
    ) else copy(x3fMode = mode)

    /** Camera-only controls are resolved per target; the persisted edit remains unchanged. */
    fun effectiveFor(input: PhotoInputKind): EditSettings = if (isHDREditing) this else if (input == PhotoInputKind.RASTER) {
        val keepRelativeWb = !customWb && recipeID == null
        copy(
            exposureMode = 2,
            customWb = false,
            temperature = if (keepRelativeWb) temperature else 6500f,
            tint = if (keepRelativeWb) tint else 0f,
        )
    } else this
    fun resetWhiteBalance(asShotTemperature: Float?, asShotTint: Float?): EditSettings = copy(
        customWb = false,
        temperature = asShotTemperature ?: 6500f,
        tint = if (recipeID == null) asShotTint ?: 0f else 0f,
    )
    val recipeScale get() = if (recipeID == null) 1f else strength
    val refinementScale get() = if (masterRecipeSettingsVersion >= 4) recipeScale else 1f
    val renderHsl get() = hsl.scaled(if (masterRecipeSettingsVersion >= 3) recipeScale else 1f)
    val renderBlackPoint get() = (blackPoint * refinementScale).coerceIn(-100f, 100f).canonicalZero()
    val renderWhitePoint get() = (whitePoint * refinementScale).coerceIn(-100f, 100f).canonicalZero()
    val renderVibrance get() = (vibrance * refinementScale).coerceIn(-100f, 100f).canonicalZero()
    val renderClarity get() = (clarity * refinementScale).coerceIn(-100f, 100f).canonicalZero()
    val renderDehaze get() = (dehaze * refinementScale).coerceIn(-100f, 100f).canonicalZero()
    val renderCurve get() = curve.scaled(refinementScale)
    val renderColorGrading get() = colorGrading.scaled(refinementScale)
    val renderToneCurve get() = if (curve.mode == ToneCurveMode.CUSTOM) 0f else (toneCurve * refinementScale).coerceIn(-1f, 1f).canonicalZero()
    fun selectFilm(id: String, cameraTint: Float? = null, cameraTemperature: Float? = null,
        input: PhotoInputKind = PhotoInputKind.RAW): EditSettings {
        if (isHDREditing) return this
        if (recipeID == null) return copy(film = id)
        val independent = requireNotNull(independentForReset(input, cameraTemperature, cameraTint)) {
            "Recipe values cannot be represented without loss"
        }
        return independent.copy(film = id, strength = strength)
    }
}

data class LensSettings(val distortion: Boolean = false, val tca: Boolean = false,
    val autoCrop: Boolean = true, val manual: Boolean = false, val profileId: String? = null,
    val focalLength: Float? = null, val cropFactor: Float? = null, val vignetting: Boolean = false) {
    init {
        require(focalLength == null || focalLength.isFinite() && focalLength in 0.1f..10000f)
        require(cropFactor == null || cropFactor.isFinite() && cropFactor in 0.1f..100f)
    }
    val enabled: Boolean get() = distortion || tca || vignetting
    val coreProfileId: String get() = if (manual) profileId ?: "__rawlab_manual_selection_required__" else ""
    fun encode(): String = listOf(if (distortion) 1 else 0, if (tca) 1 else 0,
        if (autoCrop) 1 else 0, if (manual) 1 else 0,
        profileId?.let { java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(it.toByteArray(Charsets.UTF_8)) } ?: "",
        focalLength?.toString() ?: "", cropFactor?.toString() ?: "", if (vignetting) "1" else "0")
        .joinToString("|")
    companion object {
        fun decode(value: String?): LensSettings {
            if (value == null) return LensSettings()
            val fields = value.split('|')
            require(fields.size in setOf(5, 7, 8) && fields.take(4).all { it == "0" || it == "1" })
            require(fields.size < 8 || fields[7] in setOf("0", "1"))
            return LensSettings(fields[0] == "1", fields[1] == "1", fields[2] == "1", fields[3] == "1",
                fields[4].takeIf { it.isNotEmpty() }?.let { String(java.util.Base64.getUrlDecoder().decode(it), Charsets.UTF_8) },
                fields.getOrNull(5)?.takeIf { it.isNotEmpty() }?.toFloat(),
                fields.getOrNull(6)?.takeIf { it.isNotEmpty() }?.toFloat(), fields.getOrNull(7) == "1")
        }
    }
}

enum class DenoisePreset { DETAIL, CLEAN, CUSTOM }

class HslSettings(values: List<Float> = List(24) { 0f }) {
    private val values = values.map { it.canonicalZero() }
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
    VIGNETTE_AMOUNT(true, AdjustmentFieldSpec.Fields.EFFECTS_VIGNETTE_AMOUNT.androidModel.floatRange!!, AdjustmentFieldSpec.Fields.EFFECTS_VIGNETTE_AMOUNT.androidModel.defaultFloat!!),
    VIGNETTE_MIDPOINT(true, AdjustmentFieldSpec.Fields.EFFECTS_VIGNETTE_MIDPOINT.androidModel.floatRange!!, AdjustmentFieldSpec.Fields.EFFECTS_VIGNETTE_MIDPOINT.androidModel.defaultFloat!!),
    VIGNETTE_ROUNDNESS(true, AdjustmentFieldSpec.Fields.EFFECTS_VIGNETTE_ROUNDNESS.androidModel.floatRange!!, AdjustmentFieldSpec.Fields.EFFECTS_VIGNETTE_ROUNDNESS.androidModel.defaultFloat!!),
    VIGNETTE_FEATHER(true, AdjustmentFieldSpec.Fields.EFFECTS_VIGNETTE_FEATHER.androidModel.floatRange!!, AdjustmentFieldSpec.Fields.EFFECTS_VIGNETTE_FEATHER.androidModel.defaultFloat!!),
    VIGNETTE_HIGHLIGHTS(true, AdjustmentFieldSpec.Fields.EFFECTS_VIGNETTE_HIGHLIGHTS.androidModel.floatRange!!, AdjustmentFieldSpec.Fields.EFFECTS_VIGNETTE_HIGHLIGHTS.androidModel.defaultFloat!!),
    GRAIN_AMOUNT(false, AdjustmentFieldSpec.Fields.EFFECTS_GRAIN_AMOUNT.androidModel.floatRange!!, AdjustmentFieldSpec.Fields.EFFECTS_GRAIN_AMOUNT.androidModel.defaultFloat!!),
    GRAIN_SIZE(false, AdjustmentFieldSpec.Fields.EFFECTS_GRAIN_SIZE.androidModel.floatRange!!, AdjustmentFieldSpec.Fields.EFFECTS_GRAIN_SIZE.androidModel.defaultFloat!!),
    GRAIN_ROUGHNESS(false, AdjustmentFieldSpec.Fields.EFFECTS_GRAIN_ROUGHNESS.androidModel.floatRange!!, AdjustmentFieldSpec.Fields.EFFECTS_GRAIN_ROUGHNESS.androidModel.defaultFloat!!),
}

data class PhotoEffectsSettings(
    val vignetteAmount: Float = PhotoEffectParameter.VIGNETTE_AMOUNT.defaultValue,
    val vignetteMidpoint: Float = PhotoEffectParameter.VIGNETTE_MIDPOINT.defaultValue,
    val vignetteRoundness: Float = PhotoEffectParameter.VIGNETTE_ROUNDNESS.defaultValue,
    val vignetteFeather: Float = PhotoEffectParameter.VIGNETTE_FEATHER.defaultValue,
    val vignetteHighlights: Float = PhotoEffectParameter.VIGNETTE_HIGHLIGHTS.defaultValue,
    val grainAmount: Float = PhotoEffectParameter.GRAIN_AMOUNT.defaultValue,
    val grainSize: Float = PhotoEffectParameter.GRAIN_SIZE.defaultValue,
    val grainRoughness: Float = PhotoEffectParameter.GRAIN_ROUGHNESS.defaultValue,
) {
    init {
        require(vignetteAmount.isFinite() && vignetteAmount in PhotoEffectParameter.VIGNETTE_AMOUNT.range)
        require(vignetteMidpoint.isFinite() && vignetteMidpoint in PhotoEffectParameter.VIGNETTE_MIDPOINT.range)
        require(vignetteRoundness.isFinite() && vignetteRoundness in PhotoEffectParameter.VIGNETTE_ROUNDNESS.range)
        require(vignetteFeather.isFinite() && vignetteFeather in PhotoEffectParameter.VIGNETTE_FEATHER.range)
        require(vignetteHighlights.isFinite() && vignetteHighlights in PhotoEffectParameter.VIGNETTE_HIGHLIGHTS.range)
        require(grainAmount.isFinite() && grainAmount in PhotoEffectParameter.GRAIN_AMOUNT.range)
        require(grainSize.isFinite() && grainSize in PhotoEffectParameter.GRAIN_SIZE.range)
        require(grainRoughness.isFinite() && grainRoughness in PhotoEffectParameter.GRAIN_ROUGHNESS.range)
    }

    /** Numeric controls clamp finite input and ignore non-finite drafts. */
    fun withEffect(parameter: PhotoEffectParameter, value: Float): PhotoEffectsSettings {
        if (!value.isFinite()) return this
        val rounded = if (value >= 0f) floor(value + .5f) else ceil(value - .5f)
        val normalized = rounded.coerceIn(parameter.range.start, parameter.range.endInclusive).canonicalZero()
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

data class LookChoice(val id: String, val name: String, val managed: Boolean, val available: Boolean = true,
                      val appearanceUnverified: Boolean = false, val compatibilityMode: Int = 0) {
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
 * 计算顺序对应 Core CanonicalEditState 的 master_recipe WB 解析与渲染钳位规则；
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
    val rasterRelative = input == PhotoInputKind.RASTER && recipeID == null && (kelvin != 6500f || wbTint != 0f)
    return ResetRenderValues(listOf(exposure * recipeScale, (highlights * recipeScale).canonicalZero(), shadows * recipeScale,
        if (recipeScale == 1f) contrast else 1f + (contrast - 1f) * recipeScale, renderToneCurve,
        if (recipeScale == 1f) saturation else 1f + (saturation - 1f) * recipeScale, sharpening,
        effective.exposureMode.toFloat(), if (custom) 1f else if (rasterRelative) 4f else 0f,
        if (custom || rasterRelative) kelvin else 6500f, if (custom || rasterRelative) wbTint else 0f) + renderHsl.packed().toList() +
        listOf(renderBlackPoint, renderWhitePoint, renderVibrance, renderClarity, renderDehaze) +
        ColorGradingZone.entries.flatMap { listOf(renderColorGrading[it].hue, renderColorGrading[it].saturation, renderColorGrading[it].luminance) } +
        listOf(renderColorGrading.global.hue, renderColorGrading.global.saturation, renderColorGrading.global.luminance, renderColorGrading.blending, renderColorGrading.balance) +
        ToneCurveChannel.entries.flatMap { channel -> renderCurve.shape(channel).let { listOf(it.mode.nativeValue.toFloat()) + it.packed().map(Double::toFloat) } }, kelvin, wbTint)
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
    val scaledHighlights = (highlights * recipeScale).canonicalZero()
    val scaledShadows = shadows * recipeScale
    val scaledContrast = if (recipeScale == 1f) contrast else 1f + (contrast - 1f) * recipeScale
    val scaledSaturation = if (recipeScale == 1f) saturation else 1f + (saturation - 1f) * recipeScale
    val convertWb = input == PhotoInputKind.RAW && recipeID != null && (customWb || tint * strength != 0f)
    if (scaledExposure !in -5f..5f ||
        scaledHighlights !in -1f..1f || scaledShadows !in -1f..1f ||
        scaledContrast !in 0f..2f || scaledSaturation !in 0f..2f ||
        (convertWb && (before.temperature !in 2000f..50000f || before.tint !in -150f..150f))) return null
    val candidate = copy(film = "neutral", recipeID = null, strength = 1f, masterRecipeSettingsVersion = 3,
        blackPoint = renderBlackPoint, whitePoint = renderWhitePoint, vibrance = renderVibrance,
        clarity = renderClarity, dehaze = renderDehaze, colorGrading = renderColorGrading, curve = renderCurve,
        toneCurve = (toneCurve * refinementScale).coerceIn(-1f, 1f),
        exposure = scaledExposure, highlights = scaledHighlights, shadows = scaledShadows,
        contrast = scaledContrast, saturation = scaledSaturation, hsl = renderHsl,
        customWb = if (convertWb) true else if (input != PhotoInputKind.RAW && recipeID != null) false else customWb,
        temperature = if (convertWb) before.temperature else if (input != PhotoInputKind.RAW && recipeID != null) 6500f else temperature,
        tint = if (convertWb) before.tint else if (recipeID != null) 0f else tint).canonicalZeros()
    val after = candidate.resetRenderValues(input, asShotTemperature, asShotTint) ?: return null
    return candidate.takeIf { before.core.size == after.core.size && before.core.zip(after.core).all { (a, b) -> a == b } }
}
