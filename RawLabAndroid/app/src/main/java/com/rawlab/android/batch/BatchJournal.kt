package com.rawlab.android.batch

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Properties
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.ExportSize
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.settings.SettingsCodec

// ============================================================================
//  批量任务日志：写入、恢复与删除，进程重启后据此续跑
// ============================================================================

private fun String?.toInputKind(): PhotoInputKind = runCatching {
    PhotoInputKind.valueOf(this.orEmpty())
}.getOrDefault(PhotoInputKind.RAW)

class BatchJournal(private val directory: File) {
    private companion object { const val JOURNAL_VERSION = 2 }

    init { if (!directory.exists() && !directory.mkdirs()) throw IOException("Cannot create batch journal") }

    private fun journalFile(id: String) = File(directory, "$id.properties")

    fun contains(id: String): Boolean = journalFile(id).isFile

    @Synchronized
    fun save(job: BatchJob) {
        val properties = Properties()
        properties.setProperty("source.identity", job.source.identity.value)
        properties.setProperty("source.path", job.source.sourceFile.path)
        properties.setProperty("source.name", job.source.displayName)
        properties.setProperty("source.look", job.source.lookFile?.path.orEmpty())
        properties.setProperty("source.kind", job.source.inputKind.name)
        properties.setProperty("global.error", job.globalError.orEmpty())
        properties.setProperty("source.settings", SettingsCodec.encode(job.source.settings))
        properties.setProperty("journal.version", JOURNAL_VERSION.toString())
        properties.setProperty("output.format", job.outputFormat.name.lowercase())
        // Keep the old flag for clients that only know JPEG/PNG journals.
        properties.setProperty("output.png", (job.outputFormat == ExportFormat.PNG).toString())
        properties.setProperty("output.longEdge", job.outputLongEdge?.toString().orEmpty())
        properties.setProperty("output.destination", job.destination.orEmpty())
        properties.setProperty("row.count", job.rows.size.toString())
        job.rows.forEachIndexed { index, row ->
            val prefix = "row.${index}."
            properties.setProperty(prefix + "id", row.id)
            properties.setProperty(prefix + "path", row.target.sourceFile.path)
            properties.setProperty(prefix + "name", row.target.displayName)
            properties.setProperty(prefix + "uri", row.target.sourceUri.orEmpty())
            properties.setProperty(prefix + "kind", row.target.inputKind.name)
            properties.setProperty(prefix + "status", row.status.name)
            properties.setProperty(prefix + "error", row.error.orEmpty())
            properties.setProperty(prefix + "output", row.outputName)
            properties.setProperty(prefix + "output.uri", row.outputUri.orEmpty())
            properties.setProperty(prefix + "output.ready", row.outputReady.toString())
        }
        val file = journalFile(job.id)
        val temporary = File(directory, "${job.id}.${System.nanoTime()}.tmp")
        try {
            temporary.outputStream().use { properties.store(it, null) }
            try {
                Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
            } catch (_: java.nio.file.AtomicMoveNotSupportedException) {
                Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
        } finally { temporary.delete() }
    }

    fun load(id: String): BatchJob? {
        if (!contains(id)) return null
        val file = journalFile(id)
        val properties = Properties().also { file.inputStream().use(it::load) }
        val source = BatchSourceSnapshot(PhotoIdentity(properties.getProperty("source.identity")),
            File(properties.getProperty("source.path")), SettingsCodec.decode(properties.getProperty("source.settings")),
            properties.getProperty("source.name"), properties.getProperty("source.look").orEmpty().takeIf { it.isNotEmpty() }?.let(::File),
            properties.getProperty("source.kind").toInputKind())
        val count = properties.getProperty("row.count", "0").toInt()
        val targets = (0 until count).map { index ->
            val prefix = "row.${index}."
            BatchTarget(PhotoIdentity(properties.getProperty(prefix + "id")), File(properties.getProperty(prefix + "path")),
                properties.getProperty(prefix + "name"), properties.getProperty(prefix + "uri").ifBlank { null },
                properties.getProperty(prefix + "kind").toInputKind())
        }
        val journalVersion = properties.getProperty("journal.version", "1").toIntOrNull() ?: 1
        if (journalVersion > JOURNAL_VERSION) throw IOException("Unsupported batch journal version: $journalVersion")
        val outputFormat = if (journalVersion >= JOURNAL_VERSION) {
            ExportFormat.fromPersisted(properties.getProperty("output.format"))
        } else if (properties.getProperty("output.png", "false").toBoolean()) {
            ExportFormat.PNG
        } else {
            ExportFormat.JPEG
        }
        val base = BatchJob(source, targets, id = id,
            outputFormat = outputFormat,
            outputLongEdge = properties.getProperty("output.longEdge").orEmpty().toIntOrNull()
                ?.takeIf { ExportSize.isValid(it) },
            destination = properties.getProperty("output.destination").orEmpty().ifBlank { null })
        return base.withRows(base.rows.map { row ->
            val prefix = "row.${base.rows.indexOf(row)}."
            val stored = properties.getProperty(prefix + "status")?.let(BatchRowStatus::valueOf) ?: row.status
            row.copy(status = when (stored) {
                BatchRowStatus.PROCESSING -> BatchRowStatus.PENDING
                BatchRowStatus.PUBLISHING -> BatchRowStatus.NEEDS_CONFIRMATION
                else -> stored
            },
                error = properties.getProperty(prefix + "error").orEmpty().ifBlank { null },
                outputUri = properties.getProperty(prefix + "output.uri").orEmpty().ifBlank { null },
                outputReady = properties.getProperty(prefix + "output.ready", "false").toBoolean(),
                outputName = properties.getProperty(prefix + "output", row.outputName))
        }, properties.getProperty("global.error").orEmpty().ifBlank { null })
    }

    fun pending(): List<String> = directory.listFiles().orEmpty()
        .filter { it.extension == "properties" }
        .mapNotNull { file -> load(file.nameWithoutExtension)?.let { job ->
            if (job.rows.isNotEmpty() && job.rows.all { it.status == BatchRowStatus.SUCCESS }) {
                discard(job.id)
                null
            } else job.takeIf { it.rows.isNotEmpty() }?.id
        } }

    fun discard(id: String) {
        journalFile(id).delete()
        File(directory, id).deleteRecursively()
    }
}
