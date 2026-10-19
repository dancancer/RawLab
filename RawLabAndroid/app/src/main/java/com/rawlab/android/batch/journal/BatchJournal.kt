package com.rawlab.android.batch.journal

import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.BatchRowStatus
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.io.UTFDataFormatException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Properties
import java.util.UUID
import java.util.zip.CRC32

// ============================================================================
//  批量任务日志：快照、增量记录与恢复
// ============================================================================

class BatchJournal(private val directory: File) {
    private companion object { const val LOG_MAGIC = 0x52424a33 }
    private val generations = mutableMapOf<String, String>()

    init { if (!directory.exists() && !directory.mkdirs()) throw IOException("Cannot create batch journal") }

    private fun journalFile(id: String) = File(directory, "$id.properties")
    private fun logFile(id: String) = File(directory, "$id.rows")

    fun contains(id: String): Boolean = journalFile(id).isFile

    @Synchronized
    fun save(job: BatchJob) {
        generations.remove(job.id)
        val generation = UUID.randomUUID().toString()
        replace(journalFile(job.id)) { JournalCodec.snapshot(job, generation).store(it, null) }
        // 先换快照再换日志，旧代日志不能覆盖新快照。
        replace(logFile(job.id)) { stream ->
            DataOutputStream(stream).apply { writeInt(LOG_MAGIC); writeUTF(generation); flush() }
        }
        generations[job.id] = generation
    }

    @Synchronized
    fun recordRow(job: BatchJob, index: Int) {
        val row = job.rows[index]
        val generation = generations[job.id]
        if (generation == null || !contains(job.id) || logGeneration(logFile(job.id)) != generation) {
            save(job)
            return
        }
        val payload = ByteArrayOutputStream().use { bytes ->
            JournalCodec.rowState(row).apply {
                setProperty("row.index", index.toString())
                setProperty("row.id", row.id)
            }.store(bytes, null)
            bytes.toByteArray()
        }
        try {
            FileOutputStream(logFile(job.id), true).use { stream ->
                DataOutputStream(stream).apply {
                    writeInt(payload.size)
                    write(payload)
                    writeInt(CRC32().apply { update(payload) }.value.toInt())
                    flush()
                }
                stream.fd.sync()
            }
        } catch (error: IOException) {
            // 追加失败后先重建快照，不能越过残尾继续追加。
            generations.remove(job.id)
            throw error
        }
    }

    @Synchronized
    fun load(id: String): BatchJob? {
        if (!contains(id)) return null
        val properties = Properties().also { journalFile(id).inputStream().use(it::load) }
        val snapshot = JournalCodec.readSnapshot(id, properties)
        val replayed = replay(snapshot, properties.getProperty("journal.generation"))
        return replayed.withRows(replayed.rows.map { row ->
            row.copy(status = when (row.status) {
                BatchRowStatus.PROCESSING -> BatchRowStatus.PENDING
                BatchRowStatus.PUBLISHING -> BatchRowStatus.NEEDS_CONFIRMATION
                else -> row.status
            })
        })
    }

    private fun replay(job: BatchJob, generation: String?): BatchJob {
        val file = logFile(job.id)
        if (generation == null || logGeneration(file) != generation) return job
        val rows = job.rows.toMutableList()
        RandomAccessFile(file, "r").use { input ->
            input.readInt()
            input.readUTF()
            while (input.length() - input.filePointer >= 4) {
                val size = input.readInt()
                if (size <= 0 || size.toLong() > input.length() - input.filePointer - 4) break
                val payload = ByteArray(size).also(input::readFully)
                if (input.readInt() != CRC32().apply { update(payload) }.value.toInt()) break
                try {
                    val properties = Properties().also { it.load(payload.inputStream()) }
                    val index = properties.getProperty("row.index")?.toIntOrNull() ?: break
                    if (index !in rows.indices || properties.getProperty("row.id") != rows[index].id) break
                    rows[index] = JournalCodec.readRow(properties, rows[index])
                } catch (_: IllegalArgumentException) { break }
            }
        }
        return job.withRows(rows)
    }

    private fun logGeneration(file: File): String? {
        if (!file.isFile) return null
        return try {
            RandomAccessFile(file, "r").use { if (it.readInt() == LOG_MAGIC) it.readUTF() else null }
        } catch (_: EOFException) { null }
        catch (_: UTFDataFormatException) { null }
    }

    private fun replace(file: File, write: (FileOutputStream) -> Unit) {
        val temporary = File(directory, "${file.name}.${System.nanoTime()}.tmp")
        try {
            FileOutputStream(temporary).use { write(it); it.fd.sync() }
            try {
                Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
            } catch (_: java.nio.file.AtomicMoveNotSupportedException) {
                Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
        } finally { temporary.delete() }
    }

    fun pending(): List<String> = directory.listFiles().orEmpty()
        .filter { it.extension == "properties" }
        .mapNotNull { file -> load(file.nameWithoutExtension)?.let { job ->
            if (job.rows.isNotEmpty() && job.rows.all { it.status == BatchRowStatus.SUCCESS }) {
                discard(job.id)
                null
            } else job.takeIf { it.rows.isNotEmpty() }?.id
        } }

    @Synchronized
    fun discard(id: String) {
        generations.remove(id)
        journalFile(id).delete()
        logFile(id).delete()
        File(directory, id).deleteRecursively()
    }
}
