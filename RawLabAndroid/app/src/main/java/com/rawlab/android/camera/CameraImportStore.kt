package com.rawlab.android.camera

import com.rawlab.android.photo.MediaPhoto
import com.rawlab.android.photo.MediaPhotoAccess
import com.rawlab.android.photo.SystemPhotoStore
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID

internal data class CameraPhoto(val key: String, val name: String, val size: Long, val created: Long) {
    val raw: Boolean get() = name.endsWith(".arw", ignoreCase = true)
}
internal enum class CameraJobStatus { ACTIVE, PAUSED, COMPLETE }
internal enum class CameraMediaProblem { MISSING, CHANGED }
internal data class CameraImportItem(val photo: CameraPhoto, val saved: MediaPhoto? = null,
    val prepared: MediaPhoto? = null, val digest: String? = null, val captureDay: String? = null,
    val duplicate: Boolean = false, val unavailable: MediaPhoto? = null, val problem: CameraMediaProblem? = null)
internal data class CameraImportJob(val id: String, val cameraId: String, val createdAt: Long,
    val items: List<CameraImportItem>, val status: CameraJobStatus = CameraJobStatus.ACTIVE,
    val destination: CameraImportDestination = CameraImportDestination()) {
    val savedCount: Int get() = items.count { it.saved != null }
    val totalBytes: Long get() = items.sumOf { it.photo.size }
    val savedBytes: Long get() = items.filter { it.saved != null }.sumOf { it.photo.size }
}
internal class CameraLocalSourceChanged : IOException("Camera original has changed")

/** 停止与发布准入串行；已经完整接收并准入的文件允许完成发布，不在主线程等磁盘。 */
internal class CameraTransferPermit {
    @Volatile private var cancelled = false
    @Synchronized fun cancel() { cancelled = true }
    fun check() { if (cancelled) throw IOException("Camera transfer stopped") }
    fun <T> publish(block: () -> T): T { synchronized(this) { check() }; return block() }
}

internal class CameraImportStore(private val directory: File, private val temporary: File,
    private val media: MediaPhotoAccess, private val readCaptureDate: (File) -> CameraCaptureDate?) {
    init { directory.mkdirs(); temporary.mkdirs() }

    fun create(cameraId: String, photos: List<CameraPhoto>, destination: CameraImportDestination): CameraImportJob {
        require(photos.isNotEmpty() && photos.size <= 10000)
        require(photos.map { it.key }.distinct().size == photos.size)
        require(photos.all { it.size in 1..SystemPhotoStore.MAX_BYTES })
        return CameraImportJob(UUID.randomUUID().toString(), cameraId, System.currentTimeMillis(),
            photos.map { CameraImportItem(it) }, destination = destination).also(::save)
    }
    fun partial(id: String): File { require(validId(id)); return File(temporary, "$id.part") }

    /** 仅在初始化或已停下的队列中调用，调用方持有队列锁。 */
    fun load(): List<CameraImportJob> {
        temporary.listFiles().orEmpty().filter { it.isFile && it.extension == "part" && validId(it.nameWithoutExtension) }.forEach { it.delete() }
        directory.listFiles().orEmpty().filter { it.isFile && it.extension == "tmp" && validId(it.nameWithoutExtension) }.forEach { it.delete() }
        val jobs = readJobs()
        val referenced = jobs.flatMap { it.items.flatMap { item -> listOfNotNull(item.prepared?.uri, item.saved?.uri) } }.toSet()
        media.cleanupOrphans(referenced)
        return jobs.map { job ->
            val items = job.items.map { item ->
                if (item.saved != null) {
                    val current = runCatching { media.inspect(item.saved.uri) }.getOrNull()
                    when {
                        current == null || current.pending -> item.copy(saved = null, unavailable = item.saved, problem = CameraMediaProblem.MISSING)
                        !validContent(current.uri, item.photo.size, item.digest) -> item.copy(saved = null, unavailable = current, problem = CameraMediaProblem.CHANGED)
                        else -> {
                            media.remember(current.uri, item.photo.size, checkNotNull(item.digest))
                            item.copy(saved = current, problem = null)
                        }
                    }
                } else if (item.prepared != null) {
                    val candidate = media.inspect(item.prepared.uri)
                    if (candidate != null && validContent(candidate.uri, item.photo.size, item.digest)) {
                        media.remember(candidate.uri, item.photo.size, checkNotNull(item.digest))
                        val saved = if (candidate.pending) media.publish(candidate.uri) else candidate
                        item.copy(saved = saved, prepared = null, problem = null)
                    } else {
                        // 外部已经发布/修改的文件不属于待清理数据。
                        if (candidate?.pending == true) media.deletePending(candidate.uri)
                        item.copy(prepared = null, digest = null)
                    }
                } else item
            }
            job.copy(items = items, status = if (items.all { it.saved != null }) CameraJobStatus.COMPLETE else CameraJobStatus.PAUSED).also(::save)
        }
    }

    fun publish(job: CameraImportJob, index: Int, part: File, digest: String, permit: CameraTransferPermit): CameraImportJob {
        permit.check()
        val item = job.items[index]
        if (part.canonicalFile != partial(job.id).canonicalFile || part.length() != item.photo.size ||
            !validDigest(digest) || !validHeader(part, item.photo.raw)) throw IOException("Incomplete camera photo")
        part.inputStream().use { if (contentDigest(it, item.photo.size) { permit.check() } != digest) throw IOException("Camera photo digest mismatch") }
        val capture = readCaptureDate(part)
        return permit.publish {
            val duplicate = readJobs().asSequence().flatMap { it.items.asSequence() }
                .filter { it.digest == digest && it.photo.size == item.photo.size }.mapNotNull { it.saved }
                .distinctBy { it.uri }.mapNotNull { runCatching { media.inspect(it.uri) }.getOrNull() }
                .firstOrNull { !it.pending && validContent(it.uri, item.photo.size, digest) }
            val saved: MediaPhoto
            if (duplicate != null) {
                saved = duplicate
                media.remember(saved.uri, item.photo.size, digest)
            } else {
                val pending = media.createPending(safeName(item.photo.name), job.destination.relativePath(capture),
                    if (item.photo.raw) "image/x-sony-arw" else "image/jpeg", "${job.id}:$index")
                // 先登记系统 URI，写入或发布途中退出时按原记录恢复，不再创建第二张。
                save(job.replacing(index, item.copy(prepared = pending, digest = digest, captureDay = capture?.day)))
                media.write(pending.uri, part)
                if (!validContent(pending.uri, item.photo.size, digest)) throw IOException("Stored camera photo differs")
                media.remember(pending.uri, item.photo.size, digest)
                saved = media.publish(pending.uri)
            }
            val updated = job.replacing(index, item.copy(saved = saved, prepared = null, digest = digest,
                captureDay = capture?.day, duplicate = duplicate != null, problem = null))
            val result = updated.copy(status = if (updated.savedCount == updated.items.size) CameraJobStatus.COMPLETE else CameraJobStatus.ACTIVE)
            save(result)
            part.delete()
            result
        }
    }

    fun savedUris(job: CameraImportJob): List<String> = job.items.mapNotNull { item ->
        item.saved?.let { saved ->
            val current = media.inspect(saved.uri) ?: throw IOException("Camera original is unavailable")
            if (current.pending) throw IOException("Camera original is not published")
            if (!validContent(current.uri, item.photo.size, item.digest)) throw CameraLocalSourceChanged()
            current.uri
        }
    }.distinct()

    @Synchronized fun save(job: CameraImportJob) {
        require(validId(job.id))
        val items = JSONArray()
        job.items.forEach { item -> items.put(JSONObject().put("key", item.photo.key).put("name", item.photo.name)
            .put("size", item.photo.size).put("created", item.photo.created).put("saved", item.saved?.json())
            .put("prepared", item.prepared?.json()).put("digest", item.digest).put("captureDay", item.captureDay)
            .put("duplicate", item.duplicate).put("unavailable", item.unavailable?.json()).put("problem", item.problem?.name)) }
        val json = JSONObject().put("version", 2).put("camera", job.cameraId).put("time", job.createdAt)
            .put("status", job.status.name).put("items", items).put("directory", job.destination.directory)
            .put("grouping", job.destination.grouping.name)
        val part = File(directory, "${job.id}.tmp")
        val target = File(directory, "${job.id}.json")
        try {
            FileOutputStream(part).use { it.write(json.toString().toByteArray()); it.fd.sync() }
            try { Files.move(part.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING) }
            catch (_: AtomicMoveNotSupportedException) { Files.move(part.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING) }
        } finally { part.delete() }
    }

    private fun readJobs(): List<CameraImportJob> = directory.listFiles().orEmpty()
        .filter { it.isFile && it.extension == "json" && validId(it.nameWithoutExtension) }.map { file ->
            if (file.length() > 8L * 1024 * 1024) throw IOException("Camera journal exceeds budget")
            val json = JSONObject(file.readText())
            if (json.getInt("version") != 2) throw IOException("Unsupported camera journal")
            val array = json.getJSONArray("items")
            if (array.length() !in 1..10000) throw IOException("Invalid camera journal items")
            val items = (0 until array.length()).map { index ->
                val item = array.getJSONObject(index)
                val photo = CameraPhoto(item.getString("key"), item.getString("name"), item.getLong("size"), item.getLong("created"))
                if (photo.size !in 1..SystemPhotoStore.MAX_BYTES) throw IOException("Invalid camera photo size")
                val saved = item.optJSONObject("saved")?.mediaPhoto()
                val prepared = item.optJSONObject("prepared")?.mediaPhoto()
                val digest = item.optString("digest").takeIf { it.isNotEmpty() }
                if ((saved != null || prepared != null) && !validDigest(digest)) throw IOException("Invalid camera digest")
                CameraImportItem(photo, saved, prepared, digest, item.optString("captureDay").takeIf { it.isNotEmpty() }, item.optBoolean("duplicate"),
                    item.optJSONObject("unavailable")?.mediaPhoto(), item.optString("problem").takeIf { it.isNotEmpty() }?.let(CameraMediaProblem::valueOf))
            }
            CameraImportJob(file.nameWithoutExtension, json.getString("camera"), json.getLong("time"), items,
                CameraJobStatus.valueOf(json.getString("status")), CameraImportDestination(json.getString("directory"),
                    CameraDirectoryGrouping.valueOf(json.getString("grouping"))))
        }.sortedByDescending { it.createdAt }

    private fun validContent(uri: String, size: Long, digest: String?): Boolean = runCatching {
        validDigest(digest) && media.open(uri).use { contentDigest(it, size) } == digest
    }.getOrDefault(false)

    private fun contentDigest(input: InputStream, expected: Long, check: () -> Unit = {}): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val bytes = ByteArray(64 * 1024); var count = 0L
        while (true) {
            check()
            val read = input.read(bytes); if (read < 0) break
            count += read
            if (count > expected) throw IOException("Camera original size changed")
            digest.update(bytes, 0, read)
        }
        if (count != expected) throw IOException("Camera original size changed")
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
    private fun validHeader(file: File, raw: Boolean): Boolean {
        val bytes = file.inputStream().use { input -> ByteArray(4).also { if (input.read(it) != 4) return false } }
        return if (raw) bytes.contentEquals(byteArrayOf(73, 73, 42, 0)) || bytes.contentEquals(byteArrayOf(77, 77, 0, 42))
        else bytes[0] == (-1).toByte() && bytes[1] == (-40).toByte() && bytes[2] == (-1).toByte()
    }
    private fun safeName(name: String): String {
        val file = name.substringAfterLast('/').substringAfterLast('\\').trim()
        if (file.isBlank() || file.startsWith('.') || file.any { it.isISOControl() || it in ":*?\"<>|" } ||
            file.toByteArray().size > 240) throw IOException("Invalid camera filename")
        return file
    }
    private fun validDigest(value: String?) = value?.matches(Regex("[0-9a-f]{64}")) == true
    private fun validId(id: String) = runCatching { UUID.fromString(id).toString() == id }.getOrDefault(false)
    private fun MediaPhoto.json() = JSONObject().put("uri", uri).put("name", displayName).put("path", relativePath).put("pending", pending)
    private fun JSONObject.mediaPhoto() = MediaPhoto(getString("uri"), getString("name"), getString("path"), getBoolean("pending"))
    private fun CameraImportJob.replacing(index: Int, item: CameraImportItem) = copy(items = items.toMutableList().also { it[index] = item })
}
