package com.rawlab.android.settings

import com.rawlab.android.geometry.GeometrySettings

enum class HDRMode { SDR, HDR }

fun sourceDefaultSettings(isHDRSource: Boolean): EditSettings =
    if (isHDRSource) EditSettings().withHDRMode(true, true) else EditSettings()

sealed class HDRModeError(message: String) : IllegalArgumentException(message) {
    data object UnsupportedSource : HDRModeError("HDR source is unavailable")
    data class Conflicts(val fields: List<String>) : HDRModeError("Unsupported HDR fields: ${fields.joinToString(",")}")
    data object InvalidSettings : HDRModeError("Invalid HDR settings")
}

/** Android representation of shared HDRSettings; contrast/color scalars retain the shared percentage contract. */
data class HDRSettings(
    val mode: HDRMode = HDRMode.HDR,
    val recordVersion: Int = 1,
    val processingVersion: Int = 1,
    val exposure: Float = 0f,
    val temperature: Float = 6500f,
    val tint: Float = 0f,
    val contrast: Float = 0f,
    val highlights: Float = 0f,
    val shadows: Float = 0f,
    val saturation: Float = 0f,
    val geometry: GeometrySettings = GeometrySettings(),
) {
    init {
        require(recordVersion == 1 && processingVersion == 1)
        require(exposure.isFinite() && exposure in -4f..4f)
        require(temperature.isFinite() && temperature in 2000f..50000f)
        require(tint.isFinite() && tint in -150f..150f)
        require(listOf(contrast, highlights, shadows, saturation).all { it.isFinite() && it in -100f..100f })
    }

    val isIdentity: Boolean get() = copy(mode = mode) == HDRSettings(mode = mode)
    fun reset() = HDRSettings(mode = mode, processingVersion = processingVersion)

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
fun EditSettings.withHDRMode(enabled: Boolean, sourceIsHDR: Boolean, hasLook: Boolean = false): EditSettings {
    if (!sourceIsHDR) throw HDRModeError.UnsupportedSource
    val synchronized = synchronizeHDR()
    if (enabled == synchronized.isHDREditing) return synchronized
    if (enabled) {
        val stored = synchronized.hdr
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
    return restored.copy(hdr = stored.copy(mode = HDRMode.SDR), sdrSnapshot = null)
}

/** Keep the active scalar/geometry fields and the typed HDR record byte-for-byte aligned. */
fun EditSettings.synchronizeHDR(): EditSettings {
    val value = hdr ?: return this
    if (!isHDREditing) return this
    return copy(hdr = value.copy(mode = value.mode, exposure = exposure, temperature = temperature,
        tint = tint, contrast = contrast * 100f, highlights = highlights * 100f,
        shadows = shadows * 100f, saturation = saturation * 100f, geometry = geometry))
}

fun EditSettings.sdrSnapshotSettings(): EditSettings? = sdrSnapshot?.let { SettingsCodec.decode(it) }
