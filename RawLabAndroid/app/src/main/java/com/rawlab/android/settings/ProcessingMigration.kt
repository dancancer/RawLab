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

internal class ProcessingMigrationOutcome private constructor(private val before: EditSettings,
    private val values: FloatArray, val quality: ProcessingMigrationQuality) {
    fun candidate(settings: EditSettings): EditSettings? {
        require(settings == before)
        if (values[4] != 1f) return null
        return settings.copy(processing = ProcessingIdentity.CURRENT, exposure = values[6], contrast = values[7] - 1,
            highlights = -values[8], shadows = values[9], saturation = values[10] - 1,
            blackPoint = values[11] * 100, whitePoint = values[12] * 100, vibrance = values[13] * 100,
            clarity = values[14] * 100, dehaze = values[15] * 100).canonicalZeros()
    }
    companion object {
        fun decode(before: EditSettings, values: FloatArray): ProcessingMigrationOutcome {
            require(values.size == 20 && values.all(Float::isFinite))
            require(before.processing.version in 1..2 && !before.isHDREditing && before.recipeID == null)
            require(values[0] == 1f && values[1] == 80f && values[2] == before.processing.version.toFloat() &&
                values[3] == 3f && values[4] in listOf(1f, 2f) && values[5] == values[5].toInt().toFloat())
            require(values[6] in -5f..5f && values[7] in 0f..2f && values[10] in 0f..2f)
            require(listOf(8, 9, 11, 12, 13, 14, 15).all { values[it] in -1f..1f })
            val quality = ProcessingMigrationQuality(values[16], values[17], values[18], values[19], values[5].toInt())
            require(quality.isValid && (values[4] != 1f || quality.passes))
            return ProcessingMigrationOutcome(before, values.copyOf(), quality)
        }
    }
}
