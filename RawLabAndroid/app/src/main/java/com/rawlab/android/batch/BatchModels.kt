package com.rawlab.android.batch

import java.io.File
import java.util.UUID
import java.security.MessageDigest
import com.rawlab.android.R
import com.rawlab.android.engine.NativeProcessingException
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.photo.BatchGlobalFailure
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.LensSettings
import com.rawlab.android.settings.PhotoIdentity

// ============================================================================
//  批量导出的数据模型：源快照、目标、行状态与任务
// ============================================================================

/** 输出端 I/O 失败升级为整批失败；describe 把底层原因变成界面文案（JVM 测试可换成不依赖资源的写法） */
internal fun asBatchOutputFailure(
    error: Throwable,
    describe: (String) -> String = { AppStrings.format(R.string.message_output_storage_failed, it) },
): Throwable =
    if (error is NativeProcessingException && error.status == NativeProcessingException.OUTPUT_IO_ERROR)
        BatchGlobalFailure(describe(error.message.orEmpty()), error)
    else error

enum class BatchRowStatus { PENDING, PROCESSING, PUBLISHING, NEEDS_CONFIRMATION, SUCCESS, FAILED, CANCELLED }

enum class BatchSettingsMode(val persisted: String) {
    UNIFORM_FROZEN("uniform_frozen"), PER_TARGET_FROZEN("per_target_frozen");

    companion object {
        fun decode(value: String?): BatchSettingsMode = if (value == null) UNIFORM_FROZEN else
            entries.firstOrNull { it.persisted == value } ?: throw IllegalArgumentException("Unsupported batch settings mode")
    }
}

data class BatchFrozenSettings(
    val version: Int = 1,
    val settingsVersion: Int = 1,
    val ordinal: Int,
    val settings: EditSettings,
    val inputSHA256: String,
    val lookFile: File? = null,
    val lookSHA256: String? = null,
    val outputFormat: ExportFormat,
    val longEdge: Int? = null,
) {
    fun validate() {
        require(version == 1 && settingsVersion == 1 && ordinal >= 0 &&
            com.rawlab.android.format.ExportSize.isValid(longEdge)) { "Unsupported frozen batch item" }
        require(inputSHA256.matches(Regex("[0-9a-f]{64}"))) { "Missing frozen input checksum" }
        require((lookFile == null && lookSHA256 == null) ||
            (lookFile != null && lookSHA256?.matches(Regex("[0-9a-f]{64}")) == true)) { "Missing frozen look checksum" }
    }

    fun verifyFiles(input: File) {
        check(checksum(input) == inputSHA256) { "Frozen input changed" }
        if (lookFile != null) check(checksum(lookFile) == lookSHA256) { "Frozen look changed" }
    }

    companion object {
        fun checksum(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(1024 * 1024)
                while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
    }
}

data class BatchSourceSnapshot(
    val identity: PhotoIdentity,
    val sourceFile: File,
    val settings: EditSettings,
    val displayName: String = sourceFile.name,
    val lookFile: File? = null,
    val inputKind: PhotoInputKind = PhotoInputKind.RAW,
) {
    /** Resolve camera-only state for a target without mutating the frozen source edit. */
    fun settingsFor(targetKind: PhotoInputKind): EditSettings {
        if (inputKind != PhotoInputKind.RASTER || targetKind != PhotoInputKind.RAW) return settings
        return settings.copy(
            exposureMode = EditSettings().exposureMode,
            customWb = false,
            temperature = 6500f,
            tint = if (settings.recipeID == null) 0f else settings.tint,
            lens = LensSettings(),
        )
    }
}

data class BatchTarget(
    val identity: PhotoIdentity,
    val sourceFile: File,
    val displayName: String,
    val sourceUri: String? = null,
    val inputKind: PhotoInputKind = PhotoInputKind.RAW,
    val frozen: BatchFrozenSettings? = null,
    val sourceIsHDR: Boolean = false,
) {
    val id: String get() = identity.value
}

data class BatchRow(
    val target: BatchTarget,
    val status: BatchRowStatus = BatchRowStatus.PENDING,
    val error: String? = null,
    val outputName: String = "",
    val outputUri: String? = null,
    val outputReady: Boolean = false,
) {
    val id: String get() = target.identity.value
}

data class BatchJob(
    val source: BatchSourceSnapshot,
    val targets: List<BatchTarget>,
    val id: String = UUID.randomUUID().toString(),
    val outputFormat: ExportFormat = ExportFormat.JPEG,
    val outputLongEdge: Int? = null,
    val destination: String? = null,
    val rows: List<BatchRow> = uniqueRows(targets, outputFormat),
    val globalError: String? = null,
    val settingsMode: BatchSettingsMode = BatchSettingsMode.UNIFORM_FROZEN,
) {
    fun validate() {
        if (settingsMode == BatchSettingsMode.UNIFORM_FROZEN) {
            require(rows.all { it.target.frozen == null } && targets.all { it.frozen == null }) { "Frozen items require per-target mode" }
            return
        }
        require(rows.isNotEmpty() && rows.map { it.id }.toSet().size == rows.size) { "Invalid per-target batch" }
        rows.forEachIndexed { index, row ->
            val frozen = requireNotNull(row.target.frozen) { "Missing frozen batch item" }
            frozen.validate()
            require(frozen.ordinal == index && frozen.outputFormat == outputFormat && frozen.longEdge == outputLongEdge) {
                "Frozen batch order or output settings changed"
            }
        }
    }

    fun settingsFor(target: BatchTarget): EditSettings = if (settingsMode == BatchSettingsMode.PER_TARGET_FROZEN)
        requireNotNull(target.frozen).settings else source.settingsFor(target.inputKind)

    fun lookFor(target: BatchTarget): File? = if (settingsMode == BatchSettingsMode.PER_TARGET_FROZEN)
        requireNotNull(target.frozen).lookFile else source.lookFile

    fun formatFor(target: BatchTarget): ExportFormat = if (settingsMode == BatchSettingsMode.PER_TARGET_FROZEN)
        requireNotNull(target.frozen).outputFormat else outputFormat

    fun longEdgeFor(target: BatchTarget): Int? = if (settingsMode == BatchSettingsMode.PER_TARGET_FROZEN)
        requireNotNull(target.frozen).longEdge else outputLongEdge

    companion object {
        private fun uniqueRows(targets: List<BatchTarget>, format: ExportFormat): List<BatchRow> {
            val used = mutableSetOf<String>()
            return targets.filter { used.add(it.identity.value) }.map { target ->
                BatchRow(target = target, outputName = uniqueName(target.displayName, format, used = mutableSetOf()))
            }.let { rows ->
                val names = mutableSetOf<String>()
                rows.map { row -> row.copy(outputName = uniqueName(row.outputName, format, names)) }
            }
        }

        private fun uniqueName(displayName: String, format: ExportFormat, used: MutableSet<String>): String {
            val base = displayName.substringAfterLast('/').substringBeforeLast('.', "RawLab").ifBlank { "RawLab" }
            var name = "$base${format.suffix}"
            var suffix = 2
            while (!used.add(name.lowercase())) name = "$base-$suffix${format.suffix}".also { suffix++ }
            return name
        }
    }

    fun withRows(updated: List<BatchRow>, globalError: String? = this.globalError) = copy(rows = updated, globalError = globalError)
}
