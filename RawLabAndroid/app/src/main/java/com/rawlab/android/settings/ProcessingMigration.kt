package com.rawlab.android.settings

import com.rawlab.android.json.validateStrictJSON
import org.json.JSONObject

data class ProcessingMigrationQuality(val rgbRMSE: Float, val p99Error: Float, val worstTileRMSE: Float,
    val detailRMSE: Float, val evaluations: Int) {
    val isValid get() = evaluations > 0 && listOf(rgbRMSE, p99Error, worstTileRMSE, detailRMSE).all { it.isFinite() && it >= 0 }
    val passes get() = isValid && rgbRMSE <= 2f / 255 && p99Error <= 6f / 255 && worstTileRMSE <= 4f / 255 && detailRMSE <= 2f / 255
}

enum class ProcessingMigrationStatus(val value: String) { MIGRATED("migrated"), KEPT("kept"), ROLLED_BACK("rolledBack") }

data class ProcessingMigrationReceipt(val status: ProcessingMigrationStatus, val original: EditSettings,
    val quality: ProcessingMigrationQuality) {
    init { require(original.processing.version in 1..2 && quality.isValid) }
    fun shouldAttempt(current: EditSettings, sourceVersion: Int) =
        status == ProcessingMigrationStatus.KEPT && sourceVersion in 1..2 && current != original

    internal fun encode(): String = JSONObject().put("policyVersion", 1).put("targetVersion", 3)
        .put("status", status.value).put("original", StructuredSettingsCodec.encode(original, "photo_edit"))
        .put("quality", JSONObject().put("rgbRMSE", quality.rgbRMSE).put("p99Error", quality.p99Error)
            .put("worstTileRMSE", quality.worstTileRMSE).put("detailRMSE", quality.detailRMSE)
            .put("evaluations", quality.evaluations)).toString()

    companion object {
        internal fun decode(text: String): ProcessingMigrationReceipt {
            validateStrictJSON(text, setOf("policyVersion", "targetVersion", "evaluations"))
            val value = JSONObject(text)
            require(value.keys().asSequence().toSet() == setOf("policyVersion", "targetVersion", "status", "original", "quality"))
            require(value.get("policyVersion") == 1 && value.get("targetVersion") == 3)
            val status = ProcessingMigrationStatus.entries.single { it.value == value.get("status") }
            val original = value.get("original") as? String ?: throw IllegalArgumentException("Invalid migration backup")
            val q = value.getJSONObject("quality")
            require(q.keys().asSequence().toSet() == setOf("rgbRMSE", "p99Error", "worstTileRMSE", "detailRMSE", "evaluations"))
            fun number(key: String) = (q.get(key) as? Number)?.toFloat() ?: throw IllegalArgumentException("Invalid migration quality")
            return ProcessingMigrationReceipt(status, StructuredSettingsCodec.decode(original, "photo_edit"),
                ProcessingMigrationQuality(number("rgbRMSE"), number("p99Error"), number("worstTileRMSE"),
                    number("detailRMSE"), q.getInt("evaluations")))
        }
    }
}

internal class ProcessingMigrationOutcome private constructor(
    private val before: EditSettings,
    private val result: com.rawlab.android.engine.NativeMigrationResult,
    val quality: ProcessingMigrationQuality,
) {
    fun candidate(settings: EditSettings): EditSettings? {
        require(settings == before)
        if (result.disposition != 1) return null
        return settings.copy(
            processing = ProcessingIdentity.CURRENT,
            exposure = result.exposureEv,
            contrast = result.contrast,
            highlights = result.highlights,
            shadows = result.shadows,
            saturation = result.saturation,
            blackPoint = result.blackPoint * 100f,
            whitePoint = result.whitePoint * 100f,
            vibrance = result.vibrance * 100f,
            clarity = result.clarity * 100f,
            dehaze = result.dehaze * 100f,
        ).canonicalZeros()
    }

    companion object {
        fun fromNative(
            before: EditSettings,
            result: com.rawlab.android.engine.NativeMigrationResult,
        ): ProcessingMigrationOutcome {
            val scalars = listOf(
                result.exposureEv, result.contrast, result.highlights, result.shadows, result.saturation,
                result.blackPoint, result.whitePoint, result.vibrance, result.clarity, result.dehaze,
                result.rgbRmse, result.p99Error, result.worstTileRmse, result.detailRmse,
            )
            require(scalars.all(Float::isFinite))
            require(before.processing.version in 1..2 && !before.isHDREditing && before.recipeID == null)
            require(result.sourceVersion == before.processing.version && result.targetVersion == 3 &&
                result.disposition in 1..2 && result.evaluationCount > 0)
            require(result.exposureEv in -5f..5f && result.contrast in 0f..2f && result.saturation in 0f..2f)
            require(listOf(result.highlights, result.shadows, result.blackPoint, result.whitePoint,
                result.vibrance, result.clarity, result.dehaze).all { it in -1f..1f })
            val quality = ProcessingMigrationQuality(
                result.rgbRmse, result.p99Error, result.worstTileRmse, result.detailRmse, result.evaluationCount,
            )
            require(quality.isValid && (result.disposition != 1 || quality.passes))
            return ProcessingMigrationOutcome(before, result, quality)
        }
    }
}
