package com.rawlab.android.settings

import com.rawlab.android.geometry.GeometrySettings
import java.io.File
import java.io.IOException
import java.security.MessageDigest

enum class HDRMode { SDR, HDR }

fun sourceDefaultSettings(isHDRSource: Boolean, cameraRaw: Boolean = false): EditSettings =
    if (isHDRSource && !cameraRaw) EditSettings().withHDRMode(true, true) else EditSettings()

sealed class HDRModeError(message: String) : IllegalArgumentException(message) {
    data object UnsupportedSource : HDRModeError("HDR source is unavailable")
    data class Conflicts(val fields: List<String>) : HDRModeError("Unsupported HDR fields: ${fields.joinToString(",")}")
    data object InvalidSettings : HDRModeError("Invalid HDR settings")
}

data class HDRToneSettings(
    val blackPoint: Float = 0f,
    val whitePoint: Float = 0f,
    val curveStrength: Float = 0f,
    val curve: ToneCurveSettings = ToneCurveSettings(),
) {
    init { require(listOf(blackPoint, whitePoint, curveStrength).all { it in -100f..100f }) }
    val isDefault get() = blackPoint == 0f && whitePoint == 0f && curveStrength == 0f && curve.isDefault
    val isIdentity get() = blackPoint == 0f && whitePoint == 0f &&
        (if (curve.isDefault) curveStrength == 0f else curve.isIdentity)
}

data class HDRColorSettings(
    val vibrance: Float = 0f,
    val hsl: HslSettings = HslSettings(),
    val grading: ColorGradingSettings = ColorGradingSettings(),
) {
    init { require(vibrance in -100f..100f) }
    val isDefault get() = vibrance == 0f && hsl.isIdentity && grading.isDefault
    val isIdentity get() = vibrance == 0f && hsl.isIdentity && grading.isIdentity
}

data class HDRRenditionSettings(
    val peakLimitEV: Float = 0f,
    val sdrExposureEV: Float = 0f,
    val sdrContrast: Float = 0f,
    val sdrSaturation: Float = 0f,
) {
    init {
        require(peakLimitEV in 0f..6f && sdrExposureEV in -4f..4f &&
            sdrContrast in -100f..100f && sdrSaturation in -100f..100f)
    }
    val isDefault get() = peakLimitEV == 0f && sdrExposureEV == 0f && sdrContrast == 0f && sdrSaturation == 0f
}

data class HDRDetailSettings(
    val sharpening: Float = 0f,
    val clarity: Float = 0f,
    val dehaze: Float = 0f,
    val denoise: Float = 0f,
) {
    init { require(sharpening in 0f..2f && clarity in -1f..1f && dehaze in -1f..1f && denoise in 0f..1f) }
    val isDefault get() = sharpening == 0f && clarity == 0f && dehaze == 0f && denoise == 0f
}

data class HDRLookSettings(val sha256: String? = null, val name: String? = null, val strength: Float = 0f) {
    init {
        require(isDefault || sha256?.matches(fingerprint) == true && !name.isNullOrEmpty() &&
            name.toByteArray(Charsets.UTF_8).size <= 512 && name.none(Char::isISOControl) && strength in 0f..2f)
    }
    val isDefault get() = sha256 == null && name == null && strength == 0f
    fun asset(directory: File?): File? = sha256?.let { File(requireNotNull(directory), "$it.cube") }
    fun assetIsAvailable(directory: File?): Boolean {
        if (isDefault) return true
        if (directory == null) return false
        val file = requireNotNull(asset(directory))
        if (!file.isFile || file.length() !in 1..maximumBytes) return false
        return try {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(65536)
                var size = 0L
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    size += count
                    if (size > maximumBytes) return false
                    digest.update(buffer, 0, count)
                }
            }
            digest.digest().joinToString("") { "%02x".format(it) } == sha256
        } catch (_: IOException) { false }
    }
    companion object {
        internal const val maximumBytes = 32L * 1024 * 1024
        private val fingerprint = Regex("[a-f0-9]{64}")
    }
}

data class HDRCameraProfile(val sha256: String, val name: String) {
    init {
        require(sha256.matches(Regex("[a-f0-9]{64}")) && name.toByteArray(Charsets.UTF_8).size in 1..512 &&
            name.none(Char::isISOControl))
    }

    internal fun asset(directory: File): File = File(directory, "$sha256.profile")
}

data class HDRCameraDevelopmentSettings(
    val customWhiteBalance: Boolean = false, val temperature: Float = 0f, val tint: Float = 0f,
    val sensorExposure: Boolean = false, val fbddLevel: Int = 0, val lensDistortion: Boolean = false,
    val lensTca: Boolean = false, val lensAutoCrop: Boolean = true, val lensProfile: String? = null,
    val cameraProfile: HDRCameraProfile? = null,
) {
    init {
        require(if (customWhiteBalance) temperature in 2000f..50000f && tint in -150f..150f else temperature == 0f && tint == 0f)
        require(fbddLevel in 0..2)
        require(lensProfile == null || lensActive && lensProfile.toByteArray(Charsets.UTF_8).size in 1..1024 &&
            lensProfile.none(Char::isISOControl))
    }
    val lensActive get() = lensDistortion || lensTca
    val isDefault get() = this == HDRCameraDevelopmentSettings()
}

/** Android representation of shared HDRSettings. Tone scalars use percentages. */
data class HDRSettings(
    val mode: HDRMode = HDRMode.HDR,
    val exposure: Float = 0f,
    val temperature: Float = 6500f,
    val tint: Float = 0f,
    val contrast: Float = 0f,
    val highlights: Float = 0f,
    val shadows: Float = 0f,
    val saturation: Float = 0f,
    val geometry: GeometrySettings = GeometrySettings(),
    val tone: HDRToneSettings? = null,
    val color: HDRColorSettings? = null,
    val rendition: HDRRenditionSettings? = null,
    val effects: PhotoEffectsSettings? = null,
    val detail: HDRDetailSettings? = null,
    val look: HDRLookSettings? = null,
    val cameraDevelopment: HDRCameraDevelopmentSettings? = null,
) {
    init {
        require(exposure.isFinite() && exposure in -4f..4f)
        require(temperature.isFinite() && temperature in 2000f..50000f)
        require(tint.isFinite() && tint in -150f..150f)
        require(listOf(contrast, highlights, shadows, saturation).all { it.isFinite() && it in -100f..100f })
        require(color == null || tone != null)
        require(rendition == null || color != null)
        require(effects == null || rendition != null)
        require(detail == null || effects != null)
        require(look == null || detail != null)
    }

    val recordVersion get() = if (cameraDevelopment == null) processingVersion else 8
    val processingVersion get() = when {
        look != null -> 7
        detail != null -> 6
        effects != null -> 5
        rendition != null -> 4
        color != null -> 3
        tone != null -> 2
        else -> 1
    }
    val toneSettings get() = tone ?: HDRToneSettings()
    val colorSettings get() = color ?: HDRColorSettings()
    val renditionSettings get() = rendition ?: HDRRenditionSettings()
    val effectSettings get() = effects ?: PhotoEffectsSettings()
    val detailSettings get() = detail ?: HDRDetailSettings()
    val lookSettings get() = look ?: HDRLookSettings()
    val cameraSettings get() = cameraDevelopment ?: HDRCameraDevelopmentSettings()
    val isIdentity get() = copy(tone = null, color = null, rendition = null, effects = null, detail = null, look = null,
        cameraDevelopment = null) == HDRSettings(mode = mode) &&
        (tone?.isIdentity ?: true) && (color?.isIdentity ?: true) && (rendition?.isDefault ?: true) &&
        (effects == null || effects.vignetteAmount == 0f && effects.grainAmount == 0f) && (detail?.isDefault ?: true) &&
        lookSettings.isDefault && cameraSettings.isDefault
    fun reset() = HDRSettings(mode = mode, tone = tone?.let { HDRToneSettings() }, color = color?.let { HDRColorSettings() },
        rendition = rendition?.let { HDRRenditionSettings() }, effects = effects?.let { PhotoEffectsSettings() },
        detail = detail?.let { HDRDetailSettings() }, look = look?.let { HDRLookSettings() },
        cameraDevelopment = cameraDevelopment?.let { HDRCameraDevelopmentSettings() })
    fun withTone(value: HDRToneSettings) = copy(tone = value.takeUnless { tone == null && it.isDefault })
    fun withColor(value: HDRColorSettings): HDRSettings {
        if (color == null && value.isDefault) return this
        return copy(tone = toneSettings, color = value)
    }
    fun withRendition(value: HDRRenditionSettings): HDRSettings {
        if (rendition == null && value.isDefault) return this
        return copy(tone = toneSettings, color = colorSettings, rendition = value)
    }
    fun withEffects(value: PhotoEffectsSettings): HDRSettings =
        if (effects == null && value == PhotoEffectsSettings()) this
        else copy(tone = toneSettings, color = colorSettings, rendition = renditionSettings, effects = value)
    fun withDetail(value: HDRDetailSettings): HDRSettings = if (detail == null && value.isDefault) this
        else copy(tone = toneSettings, color = colorSettings, rendition = renditionSettings, effects = effectSettings, detail = value)
    fun withLook(value: HDRLookSettings): HDRSettings = if (look == null && value.isDefault) this
        else copy(tone = toneSettings, color = colorSettings, rendition = renditionSettings, effects = effectSettings,
            detail = detailSettings, look = value)
    fun withCameraDevelopment(value: HDRCameraDevelopmentSettings) =
        if (cameraDevelopment == null && value.isDefault) this else copy(cameraDevelopment = value)

    companion object {
        fun from(settings: EditSettings) = HDRSettings(
            exposure = settings.exposure,
            temperature = settings.temperature,
            tint = settings.tint,
            contrast = settings.contrast * 100f,
            highlights = settings.highlights * 100f,
            shadows = settings.shadows * 100f,
            saturation = settings.saturation * 100f,
            geometry = settings.geometry,
        )
    }
}

internal val EditSettings.editingCurve get() = if (isHDREditing) hdr!!.toneSettings.curve else curve
internal val EditSettings.editingCurveStrength get() = if (isHDREditing) hdr!!.toneSettings.curveStrength / 100 else toneCurve
internal val EditSettings.editingBlackPoint get() = if (isHDREditing) hdr!!.toneSettings.blackPoint else blackPoint
internal val EditSettings.editingWhitePoint get() = if (isHDREditing) hdr!!.toneSettings.whitePoint else whitePoint
internal val EditSettings.editingVibrance get() = if (isHDREditing) hdr!!.colorSettings.vibrance else vibrance
internal val EditSettings.editingHsl get() = if (isHDREditing) hdr!!.colorSettings.hsl else hsl
internal val EditSettings.editingGrading get() = if (isHDREditing) hdr!!.colorSettings.grading else colorGrading
internal val EditSettings.editingSharpening get() = if (isHDREditing) hdr!!.detailSettings.sharpening else sharpening
internal val EditSettings.editingClarity get() = if (isHDREditing) hdr!!.detailSettings.clarity * 100 else clarity
internal val EditSettings.editingDehaze get() = if (isHDREditing) hdr!!.detailSettings.dehaze * 100 else dehaze

internal fun EditSettings.withEditingSharpening(value: Float) =
    if (isHDREditing) copy(hdr = hdr!!.withDetail(hdr.detailSettings.copy(sharpening = value))) else copy(sharpening = value)
internal fun EditSettings.withEditingClarity(value: Float) =
    if (isHDREditing) copy(hdr = hdr!!.withDetail(hdr.detailSettings.copy(clarity = value / 100))) else copy(clarity = value)
internal fun EditSettings.withEditingDehaze(value: Float) =
    if (isHDREditing) copy(hdr = hdr!!.withDetail(hdr.detailSettings.copy(dehaze = value / 100))) else copy(dehaze = value)
internal fun EditSettings.withHDRDenoise(value: Float): EditSettings {
    val active = requireNotNull(hdr).also { require(it.mode == HDRMode.HDR) }
    return copy(hdr = active.withDetail(active.detailSettings.copy(denoise = value)))
}

internal fun EditSettings.withEditingCurve(value: ToneCurveSettings) =
    if (isHDREditing) copy(hdr = hdr!!.withTone(hdr.toneSettings.copy(curve = value))) else copy(curve = value)
internal fun EditSettings.withEditingCurveStrength(value: Float) =
    if (isHDREditing) copy(hdr = hdr!!.withTone(hdr.toneSettings.copy(curveStrength = value * 100))) else copy(toneCurve = value)
internal fun EditSettings.withEditingBlackPoint(value: Float) =
    if (isHDREditing) copy(hdr = hdr!!.withTone(hdr.toneSettings.copy(blackPoint = value))) else copy(blackPoint = value)
internal fun EditSettings.withEditingWhitePoint(value: Float) =
    if (isHDREditing) copy(hdr = hdr!!.withTone(hdr.toneSettings.copy(whitePoint = value))) else copy(whitePoint = value)
internal fun EditSettings.withEditingVibrance(value: Float) =
    if (isHDREditing) copy(hdr = hdr!!.withColor(hdr.colorSettings.copy(vibrance = value.canonicalZero()))) else copy(vibrance = value)
internal fun EditSettings.withEditingHsl(value: HslSettings) =
    if (isHDREditing) copy(hdr = hdr!!.withColor(hdr.colorSettings.copy(hsl = value))) else copy(hsl = value)
internal fun EditSettings.withEditingGrading(value: ColorGradingSettings) =
    if (isHDREditing) copy(hdr = hdr!!.withColor(hdr.colorSettings.copy(grading = value))) else copy(colorGrading = value)

private fun EditSettings.applyHDRValues(value: HDRSettings, mode: HDRMode, snapshot: String?): EditSettings = copy(
    exposure = value.exposure,
    temperature = value.temperature,
    tint = value.tint,
    contrast = value.contrast / 100f,
    highlights = value.highlights / 100f,
    shadows = value.shadows / 100f,
    saturation = value.saturation / 100f,
    geometry = value.geometry,
    hdr = value.copy(mode = mode),
    sdrSnapshot = snapshot,
)

fun EditSettings.hdrDefaults(): EditSettings = applyHDRValues(
    requireNotNull(hdr).reset(), HDRMode.HDR, sdrSnapshot)

/** Enable/disable HDR without changing the inactive mode's edit snapshot. */
fun EditSettings.withHDRMode(enabled: Boolean, sourceIsHDR: Boolean, hasLook: Boolean = false,
    cameraRaw: Boolean = false, proRAW: Boolean = false): EditSettings {
    if (!sourceIsHDR && !cameraRaw) throw HDRModeError.UnsupportedSource
    if (enabled && proRAW) requireProRAWDecoder()
    val synchronized = synchronizeHDR()
    if (enabled == synchronized.isHDREditing) return synchronized
    if (enabled) {
        val stored = synchronized.hdr
        if (cameraRaw) {
            // Camera RAW HDR is a separate post-demosaic path. Keep every SDR-only
            // edit in the inactive snapshot and start the HDR request from neutral
            // values (or the previously saved HDR snapshot).
            val base = synchronized.copy(hdr = null, sdrSnapshot = null)
            return base.applyHDRValues(stored ?: HDRSettings(), HDRMode.HDR, SettingsCodec.encode(base)).let {
                if (proRAW) it.copy(proRAWDecodeVersion = com.rawlab.android.photo.HDRSourceInfo.PRORAW_DECODE_VERSION) else it
            }
        }
        if (stored == null) {
            val conflicts = buildList {
                if (synchronized.temperature != 6500f || synchronized.tint != 0f) add("white_balance")
                if (hasLook || synchronized.film != "neutral" || synchronized.recipeID != null || synchronized.strength != 1f) add("look")
                if (synchronized.denoise != DenoiseSettings()) add("denoise")
                if (synchronized.sharpening != 0f) add("sharpening")
                if (synchronized.effects != PhotoEffectsSettings()) add("effects")
                if (synchronized.displayChromaDenoise != 0) add("chroma_denoise")
                if (!synchronized.hsl.isIdentity) add("hsl")
                if (!synchronized.colorGrading.isDefault) add("color_grading")
                if (!synchronized.curve.isDefault || synchronized.toneCurve != 0f) add("tone_curve")
                if (synchronized.blackPoint != 0f || synchronized.whitePoint != 0f || synchronized.vibrance != 0f ||
                    synchronized.clarity != 0f || synchronized.dehaze != 0f) add("refinement")
                if (synchronized.lens.enabled) add("lens")
            }
            if (conflicts.isNotEmpty()) throw HDRModeError.Conflicts(conflicts)
        }
        val base = synchronized.copy(hdr = null, sdrSnapshot = null)
        val snapshot = SettingsCodec.encode(base)
        return base.applyHDRValues(stored ?: HDRSettings.from(base), HDRMode.HDR, snapshot)
    }
    val stored = synchronized.hdr ?: return synchronized.copy(sdrSnapshot = null)
    val restored = synchronized.sdrSnapshotSettings() ?: synchronized.copy(hdr = null, sdrSnapshot = null)
    return restored.copy(hdr = stored.copy(mode = HDRMode.SDR), sdrSnapshot = null, proRAWDecodeVersion = proRAWDecodeVersion)
}

fun EditSettings.requireProRAWDecoder() {
    if (proRAWDecodeVersion != null && proRAWDecodeVersion != com.rawlab.android.photo.HDRSourceInfo.PRORAW_DECODE_VERSION)
        throw HDRModeError.InvalidSettings
}

internal fun EditSettings.requireHDRDecodeVersion(isProRAW: Boolean) {
    if (isProRAW) requireProRAWDecoder()
    else if (proRAWDecodeVersion != null) throw HDRModeError.InvalidSettings
}

internal val EditSettings.editingEffects: PhotoEffectsSettings
    get() = if (isHDREditing) requireNotNull(hdr).effectSettings else effects

internal fun EditSettings.withEditingEffects(value: PhotoEffectsSettings): EditSettings =
    if (isHDREditing) copy(hdr = requireNotNull(hdr).withEffects(value)) else copy(effects = value)

/** Keep the active scalar/geometry fields and the typed HDR record byte-for-byte aligned. */
fun EditSettings.synchronizeHDR(): EditSettings {
    val value = hdr ?: return this
    if (!isHDREditing) return this
    return copy(hdr = value.copy(mode = value.mode, exposure = exposure, temperature = temperature,
        tint = tint, contrast = contrast * 100f, highlights = highlights * 100f,
        shadows = shadows * 100f, saturation = saturation * 100f, geometry = geometry))
}

fun EditSettings.sdrSnapshotSettings(): EditSettings? = sdrSnapshot?.let { SettingsCodec.decode(it) }
