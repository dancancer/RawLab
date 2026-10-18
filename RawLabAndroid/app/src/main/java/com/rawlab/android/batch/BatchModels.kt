package com.rawlab.android.batch

import java.io.File
import java.util.UUID
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
) {
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
