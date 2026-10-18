package com.rawlab.android.batch.journal

import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.BatchRow
import com.rawlab.android.batch.BatchRowStatus
import com.rawlab.android.batch.BatchSourceSnapshot
import com.rawlab.android.batch.BatchTarget
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.ExportSize
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.settings.SettingsCodec
import java.io.File
import java.io.IOException
import java.util.Properties

/* 快照保留旧字段；行日志只保存可变行状态，不重复任务元数据和输入信息。 */
internal object JournalCodec {
    const val VERSION = 3

    fun snapshot(job: BatchJob, generation: String) = Properties().apply {
        setProperty("journal.version", VERSION.toString())
        setProperty("journal.generation", generation)
        setProperty("source.identity", job.source.identity.value)
        setProperty("source.path", job.source.sourceFile.path)
        setProperty("source.name", job.source.displayName)
        setProperty("source.look", job.source.lookFile?.path.orEmpty())
        setProperty("source.kind", job.source.inputKind.name)
        setProperty("source.settings", SettingsCodec.encode(job.source.settings))
        setProperty("global.error", job.globalError.orEmpty())
        setProperty("output.format", job.outputFormat.name.lowercase())
        setProperty("output.png", (job.outputFormat == ExportFormat.PNG).toString())
        setProperty("output.longEdge", job.outputLongEdge?.toString().orEmpty())
        setProperty("output.destination", job.destination.orEmpty())
        setProperty("row.count", job.rows.size.toString())
        job.rows.forEachIndexed { index, row ->
            val prefix = "row.$index."
            setProperty(prefix + "id", row.id)
            setProperty(prefix + "path", row.target.sourceFile.path)
            setProperty(prefix + "name", row.target.displayName)
            setProperty(prefix + "uri", row.target.sourceUri.orEmpty())
            setProperty(prefix + "kind", row.target.inputKind.name)
            putAll(rowState(row, prefix))
        }
    }

    fun rowState(row: BatchRow, prefix: String = "") = Properties().apply {
        setProperty(prefix + "status", row.status.name)
        setProperty(prefix + "error", row.error.orEmpty())
        setProperty(prefix + "output", row.outputName)
        setProperty(prefix + "output.uri", row.outputUri.orEmpty())
        setProperty(prefix + "output.ready", row.outputReady.toString())
    }

    fun readRow(properties: Properties, row: BatchRow, prefix: String = "") = row.copy(
        status = properties.getProperty(prefix + "status")?.let(BatchRowStatus::valueOf) ?: row.status,
        error = properties.getProperty(prefix + "error").orEmpty().ifBlank { null },
        outputName = properties.getProperty(prefix + "output", row.outputName),
        outputUri = properties.getProperty(prefix + "output.uri").orEmpty().ifBlank { null },
        outputReady = properties.getProperty(prefix + "output.ready", "false").toBoolean())

    fun readSnapshot(id: String, properties: Properties): BatchJob {
        val version = properties.getProperty("journal.version", "1").toIntOrNull() ?: 1
        if (version > VERSION) throw IOException("Unsupported batch journal version: $version")
        val source = BatchSourceSnapshot(PhotoIdentity(properties.getProperty("source.identity")),
            File(properties.getProperty("source.path")), SettingsCodec.decode(properties.getProperty("source.settings")),
            properties.getProperty("source.name"), properties.getProperty("source.look").orEmpty().takeIf { it.isNotEmpty() }?.let(::File),
            properties.getProperty("source.kind").toInputKind())
        val count = properties.getProperty("row.count", "0").toInt()
        val targets = (0 until count).map { index ->
            val prefix = "row.$index."
            BatchTarget(PhotoIdentity(properties.getProperty(prefix + "id")), File(properties.getProperty(prefix + "path")),
                properties.getProperty(prefix + "name"), properties.getProperty(prefix + "uri").ifBlank { null },
                properties.getProperty(prefix + "kind").toInputKind())
        }
        val format = if (version >= 2) ExportFormat.fromPersisted(properties.getProperty("output.format"))
            else if (properties.getProperty("output.png", "false").toBoolean()) ExportFormat.PNG else ExportFormat.JPEG
        val base = BatchJob(source, targets, id = id, outputFormat = format,
            outputLongEdge = properties.getProperty("output.longEdge").orEmpty().toIntOrNull()?.takeIf { ExportSize.isValid(it) },
            destination = properties.getProperty("output.destination").orEmpty().ifBlank { null })
        return base.withRows(base.rows.mapIndexed { index, row -> readRow(properties, row, "row.$index.") },
            properties.getProperty("global.error").orEmpty().ifBlank { null })
    }

    private fun String?.toInputKind(): PhotoInputKind = runCatching {
        PhotoInputKind.valueOf(this.orEmpty())
    }.getOrDefault(PhotoInputKind.RAW)
}
