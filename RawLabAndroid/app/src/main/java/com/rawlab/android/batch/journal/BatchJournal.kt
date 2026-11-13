package com.rawlab.android.batch.journal

import android.util.Log
import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.BatchRowStatus
import com.rawlab.android.settings.ProcessingIdentity
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.io.UTFDataFormatException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.Properties
import java.util.TimeZone
import java.util.UUID
import java.util.zip.CRC32
import org.json.JSONObject

// ============================================================================
//  批量任务日志：快照、增量记录与恢复
// ============================================================================

class BatchJournal(private val directory: File) {
    private companion object {
        const val LOG_MAGIC = 0x52424a33
        const val LOG_TAG = "RawLabBatch"
    }
    private val generations = mutableMapOf<String, String>()

    /** 最近一次隔离移出的文件/目录名，供调用方与诊断核验。 */
    @Volatile
    var lastQuarantinedPaths: List<String> = emptyList()
        private set

    init { if (!directory.exists() && !directory.mkdirs()) throw IOException("Cannot create batch journal") }

    private fun journalFile(id: String) = File(directory, "$id.properties")
    private fun logFile(id: String) = File(directory, "$id.rows")

    fun contains(id: String): Boolean = journalFile(id).isFile

    private fun isUnsupportedFuture(snapshotBytes: ByteArray): Boolean {
        return try {
            val properties = Properties().also { it.load(snapshotBytes.inputStream()) }
            val version = properties.getProperty("journal.version")?.toIntOrNull()
            if (version != null && version > JournalCodec.VERSION) return true
            // 已处理版本与冻结设置里的未来版本同样是「可识别但更新」，不得当坏文件隔离。
            if (isFutureSettings(properties.getProperty("source.settings"))) return true
            val count = properties.getProperty("row.count")?.toIntOrNull()?.coerceAtMost(10_000) ?: 0
            (0 until count).any { index ->
                val prefix = "row.$index."
                (properties.getProperty(prefix + "frozen.version")?.toIntOrNull() ?: 0) > 1 ||
                    (properties.getProperty(prefix + "frozen.settingsVersion")?.toIntOrNull() ?: 0) > 1 ||
                    isFutureSettings(properties.getProperty(prefix + "frozen.settings"))
            }
        } catch (_: Exception) {
            false
        }
    }

    /** 「读得到但认识不了」与「版本比本端新」的区分：只在版本号高于本端当前值时判定为未来版本。 */
    private fun isFutureSettings(value: String?): Boolean {
        if (value == null) return false
        if (!value.startsWith("v2:")) {
            // 旧管道格式：processing 标识是第 54 字段；解析不出数字的按损坏处理。
            val fields = value.split('|')
            val parts = fields.getOrNull(53)?.split(',') ?: return false
            val version = parts.getOrNull(1)?.toIntOrNull() ?: return false
            return parts.getOrNull(0) == "rawlab" && version > ProcessingIdentity.CURRENT.version
        }
        return try {
            val root = JSONObject(value.removePrefix("v2:"))
            if (root.optInt("version", 2) > 2) return true
            val settings = root.optJSONObject("settings") ?: return false
            val processing = settings.optJSONObject("processing")
            if (processing != null && processing.optString("family") == "rawlab" &&
                processing.optInt("version") > ProcessingIdentity.CURRENT.version) return true
            if (settings.optInt("masterRecipeSettingsVersion", 3) > 4) return true
            val hdr = settings.optJSONObject("hdr")
            hdr != null && (hdr.optInt("hdr_processing_version") > 8 || hdr.optInt("record_version") > 9 ||
                (hdr.optJSONObject("camera_development")?.optInt("version") ?: 0) > 1)
        } catch (_: Exception) {
            false
        }
    }

    @Synchronized
    fun save(job: BatchJob) {
        // 旧实例不得覆盖另一个版本已经保存的新格式。
        if (contains(job.id)) {
            try {
                load(job.id)
            } catch (error: Exception) {
                // 读 I/O 与未来版本原样传播、不动原文件；只有「读得到但坏了」才隔离。
                if (error !is CorruptBatchJournalEntry) throw error
                quarantine(job.id, error)
            }
        }
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
        val snapshotFile = journalFile(id)
        if (!snapshotFile.isFile) return null
        // 「读不了」≠「坏了」：先把整份字节读进内存，读 I/O 失败原样上抛且不动原文件；
        // 只有内存字节的解析/版本判定才走损坏隔离与未来版本拒绝（对齐 Mac readJob）。
        val snapshotBytes = snapshotFile.readBytes()
        val log = logFile(id)
        val logBytes = if (log.isFile) log.readBytes() else null
        return try {
            val properties = Properties().also { it.load(snapshotBytes.inputStream()) }
            val snapshot = JournalCodec.readSnapshot(id, properties)
            val replayed = replay(snapshot, properties.getProperty("journal.generation"), logBytes)
            replayed.withRows(replayed.rows.map { row ->
                row.copy(status = when (row.status) {
                    BatchRowStatus.PROCESSING -> BatchRowStatus.PENDING
                    BatchRowStatus.PUBLISHING -> BatchRowStatus.NEEDS_CONFIRMATION
                    else -> row.status
                })
            })
        } catch (error: Exception) {
            if (isUnsupportedFuture(snapshotBytes)) throw error
            throw CorruptBatchJournalEntry(id, error)
        }
    }

    private fun replay(job: BatchJob, generation: String?, logBytes: ByteArray?): BatchJob {
        if (generation == null || logBytes == null || logHeader(logBytes) != generation) return job
        val rows = job.rows.toMutableList()
        val log = LogReader(logBytes)
        log.readInt()
        log.readString()
        while (log.remaining >= 4) {
            val size = log.readInt()
            if (size <= 0 || size > log.remaining - 4) break
            val payload = log.readBytes(size)
            if (log.readInt() != CRC32().apply { update(payload) }.value.toInt()) break
            try {
                val properties = Properties().also { it.load(payload.inputStream()) }
                val index = properties.getProperty("row.index")?.toIntOrNull() ?: break
                if (index !in rows.indices || properties.getProperty("row.id") != rows[index].id) break
                rows[index] = JournalCodec.readRow(properties, rows[index])
            } catch (_: IllegalArgumentException) { break }
        }
        return job.withRows(rows)
    }

    private fun logHeader(bytes: ByteArray): String? = try {
        val log = LogReader(bytes)
        if (log.readInt() != LOG_MAGIC) null else log.readString()
    } catch (_: EOFException) {
        null
    }

    private fun logGeneration(file: File): String? {
        if (!file.isFile) return null
        return try {
            RandomAccessFile(file, "r").use { if (it.readInt() == LOG_MAGIC) it.readUTF() else null }
        } catch (_: EOFException) { null }
        catch (_: UTFDataFormatException) { null }
    }

    /** 行日志的内存游标：按 writeInt/writeUTF 布局精确前进，长度取自 2 字节前缀，不受编码差异影响。 */
    private class LogReader(bytes: ByteArray) {
        private val stream = DataInputStream(ByteArrayInputStream(bytes))
        var remaining = bytes.size
            private set
        fun readInt(): Int { val value = stream.readInt(); remaining -= 4; return value }
        fun readString(): String {
            val length = stream.readUnsignedShort()
            val raw = ByteArray(length).also(stream::readFully)
            remaining -= 2 + length
            return String(raw, Charsets.UTF_8)
        }
        fun readBytes(count: Int): ByteArray {
            val value = ByteArray(count).also(stream::readFully)
            remaining -= count
            return value
        }
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

    private fun timestamp(): String = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }.format(Date())

    /**
     * 把损坏的快照、行日志与任务目录改名移出扫描路径。
     * 改名失败必须抛出：坏文件留在原位时 save 的原子写会直接覆盖它，破坏「改名可逆可查」。
     * 返回并记录被移出的名字，便于日志与调用方核验（Should-1 可见性）。
     */
    @Synchronized
    fun quarantine(id: String, error: Exception? = null): List<String> {
        generations.remove(id)
        val ts = timestamp()
        val moved = mutableListOf<String>()
        fun uniqueTarget(name: String): File {
            var target = File(directory, "$name.corrupt-$ts")
            var suffix = 1
            while (target.exists()) {
                target = File(directory, "$name.corrupt-$ts-$suffix")
                suffix++
            }
            return target
        }
        fun isolateFile(file: File) {
            if (!file.isFile) return
            val target = uniqueTarget(file.name)
            // renameTo 只返回 Boolean，失败不抛：必须自行检查，否则原坏文件会被静默覆盖。
            if (!file.renameTo(target)) throw IOException("Cannot isolate batch journal entry ${file.name}")
            moved += target.name
        }
        isolateFile(journalFile(id))
        isolateFile(logFile(id))
        val jobDir = File(directory, id)
        if (jobDir.isDirectory) {
            val targetDir = uniqueTarget(id)
            if (!jobDir.renameTo(targetDir)) throw IOException("Cannot isolate batch job directory $id")
            moved += targetDir.name
        }
        lastQuarantinedPaths = moved
        if (moved.isNotEmpty()) {
            Log.w(LOG_TAG, "Quarantined batch journal $id -> " + moved.joinToString(", ") +
                (error?.let { " (cause: ${it.message ?: it.javaClass.simpleName})" } ?: ""))
        }
        return moved
    }

    fun pending(): List<String> = directory.listFiles().orEmpty()
        .filter { it.extension == "properties" }
        .mapNotNull { file ->
            val id = file.nameWithoutExtension
            try {
                load(id)?.let { job ->
                    if (job.rows.isNotEmpty() && job.rows.all { it.status == BatchRowStatus.SUCCESS }) {
                        discard(job.id)
                        null
                    } else job.takeIf { it.rows.isNotEmpty() }?.id
                }
            } catch (error: Exception) {
                // 读 I/O 与未来版本原样传播；只有「读得到但坏了」才隔离并继续扫描其余待办。
                if (error !is CorruptBatchJournalEntry) throw error
                quarantine(id, error)
                null
            }
        }

    @Synchronized
    fun discard(id: String) {
        generations.remove(id)
        journalFile(id).delete()
        logFile(id).delete()
        File(directory, id).deleteRecursively()
    }
}

/**
 * 「读得到但坏了」的专属标记：调用方只对这类异常做损坏隔离；
 * 读 I/O 失败与未来版本必须原样传播，不动、不覆盖原文件（对齐 Mac/iOS/Windows 边界）。
 */
private class CorruptBatchJournalEntry(id: String, cause: Exception) :
    Exception("Corrupt batch journal $id (${cause.message ?: cause.javaClass.simpleName})", cause)
