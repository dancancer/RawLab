package com.rawlab.android.batch.journal

import com.rawlab.android.batch.BatchJob
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.settings.SettingsCodec
import java.io.File
import java.util.Properties

/* 原样保留 a83dc79 的 v2 编码部分，不能用新 codec 生成兼容夹具。 */
internal fun writeV2Fixture(directory: File, job: BatchJob) {
    val JOURNAL_VERSION = 2
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
    File(directory, "${job.id}.properties").outputStream().use { properties.store(it, null) }
}
