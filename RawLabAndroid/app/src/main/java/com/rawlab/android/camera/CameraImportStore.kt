package com.rawlab.android.camera

import com.rawlab.android.camera.protocol.SonyMobileSession
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

internal data class CameraPhoto(val key: String, val name: String, val size: Long, val created: Long,
    val resumeIdentity: String? = null, val storageToken: String? = null, val captureTimestamp: Long = created) {
    val raw: Boolean get() = name.endsWith(".arw", ignoreCase = true)
    /** Sony mobile contents uses epoch milliseconds; legacy contents is normalized to the same value in GMT. */
    val captureDateMillis: Long? get() = captureTimestamp.takeIf { it in 946_684_800_000L until 4_102_444_800_000L }
    val anchorKey: String get() = "$storageToken:$name:$size:$captureTimestamp"
    fun matchesSnapshot(observed: CameraPhoto): Boolean =
        key == observed.key && name == observed.name && size == observed.size && created == observed.created &&
            (resumeIdentity == null || resumeIdentity == observed.resumeIdentity) &&
            (storageToken == null || storageToken == observed.storageToken && captureTimestamp == observed.captureTimestamp)
}
internal enum class CameraJobStatus { ACTIVE, PAUSED, COMPLETE }
internal enum class CameraMediaProblem { MISSING, CHANGED, REMOTE_MISSING, HDR_GAIN_MAP }
internal data class CameraImportItem(val photo: CameraPhoto, val saved: MediaPhoto? = null,
    val prepared: MediaPhoto? = null, val digest: String? = null, val captureDay: String? = null,
    val duplicate: Boolean = false, val unavailable: MediaPhoto? = null, val problem: CameraMediaProblem? = null,
    val outputDigest: String? = null, val outputSize: Long? = null, val saveOriginalJpeg: Boolean = false)

// Both import protocols validate Sony's vendor identity before exposing Device.
internal data class CameraHardwareIdentity(val model: String, val serial: String) {
    init { require(model.isNotBlank() && serial.isNotBlank() && serial.any { it != '0' }) }

    companion object {
        fun read(device: SonyMobileSession.Device): CameraHardwareIdentity? {
            val model = device.model.trim()
            val serial = device.serial.trim()
            return if (model.isEmpty() || serial.all { it == '0' }) null
                else CameraHardwareIdentity(model, serial)
        }
    }
}

internal data class CameraImportJob(val id: String, val cameraId: String, val createdAt: Long,
    val items: List<CameraImportItem>, val status: CameraJobStatus = CameraJobStatus.ACTIVE,
    val destination: CameraImportDestination = CameraImportDestination(),
    val incremental: CameraIncrementalPlan? = null, val committed: Boolean = false,
    val hardwareIdentity: CameraHardwareIdentity? = null) {
    val savedCount: Int get() = items.count { it.saved != null }
    val totalBytes: Long get() = items.sumOf { it.photo.size }
    val savedBytes: Long get() = items.filter { it.saved != null }.sumOf { it.photo.size }

    fun matchesCamera(connectionId: String?, device: CameraHardwareIdentity?): Boolean =
        if (hardwareIdentity == null) cameraId == connectionId else hardwareIdentity == device

    fun matchesPendingPhotos(observed: Map<String, CameraPhoto>): Boolean = items.all { item ->
        item.saved != null || observed[item.photo.key]?.let(item.photo::matchesSnapshot) == true
    }

    fun jpegOptions(item: CameraImportItem): CameraJPEGOptions? =
        incremental?.jpeg?.takeIf { it.adjust && !item.photo.raw && !item.saveOriginalJpeg }

    fun keepingPendingJpegOriginals(): CameraImportJob = copy(items = items.map { item ->
        if (item.photo.raw || item.saved != null) item
        else item.copy(saveOriginalJpeg = true, problem = item.problem.takeUnless { it == CameraMediaProblem.HDR_GAIN_MAP })
    })
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
    private var processJpeg: (File, File, CameraJPEGOptions) -> CameraProcessedFile = CameraJPEGProcessing::process
    private var verifyJpeg: (File) -> Unit = CameraJPEGProcessing::ensureAdjustmentSupported

    constructor(directory: File, temporary: File, media: MediaPhotoAccess,
        readCaptureDate: (File) -> CameraCaptureDate?,
        processJpeg: (File, File, CameraJPEGOptions) -> CameraProcessedFile,
        verifyJpeg: (File) -> Unit = {}) : this(directory, temporary, media, readCaptureDate) {
        this.processJpeg = processJpeg
        this.verifyJpeg = verifyJpeg
    }

    init { directory.mkdirs(); temporary.mkdirs() }

    fun create(cameraId: String, photos: List<CameraPhoto>, destination: CameraImportDestination,
        id: String = UUID.randomUUID().toString(), incremental: CameraIncrementalPlan? = null,
        hardwareIdentity: CameraHardwareIdentity? = null): CameraImportJob {
        require(validId(id))
        require(photos.isNotEmpty() && photos.size <= 10000)
        require(photos.map { it.key }.distinct().size == photos.size)
        require(photos.all { it.size in 1..SystemPhotoStore.MAX_BYTES })
        incremental?.let { plan ->
            require(plan.jpeg.isValid)
            require(photos.all(plan.format::includes))
        }
        readJobs().firstOrNull { it.id == id }?.let { existing ->
            if (existing.cameraId != cameraId || existing.hardwareIdentity != hardwareIdentity ||
                existing.destination != destination || existing.incremental != incremental || existing.items.size != photos.size ||
                existing.items.zip(photos).any { (stored, current) -> !stored.photo.matchesSnapshot(current) })
                throw IOException("Reserved camera job identity changed")
            return existing
        }
        return CameraImportJob(id, cameraId, System.currentTimeMillis(),
            photos.map { CameraImportItem(it) }, destination = destination, incremental = incremental,
            hardwareIdentity = hardwareIdentity).also(::save)
    }
    fun partial(id: String): File { require(validId(id)); return File(temporary, "$id.part") }

    /** 仅在初始化或已停下的队列中调用，调用方持有队列锁。 */
    fun load(): List<CameraImportJob> {
        cleanupLoadArtifacts()
        val jobs = readJobs().map(::migrateLegacyBoundary)
        val referenced = jobs.flatMap { it.items.flatMap { item -> listOfNotNull(item.prepared?.uri, item.saved?.uri) } }.toSet()
        media.cleanupOrphans(referenced)
        return jobs.map(::recoverJob)
    }

    /** Revalidates one resumable job without recovering unrelated jobs or cleaning their media. */
    fun recover(id: String): CameraImportJob? {
        require(validId(id))
        temporary.listFiles().orEmpty().filter { it.isFile &&
            ((it.name == "$id.part") || (it.name.startsWith("$id-") && it.name.endsWith(".jpeg-part"))) }
            .forEach { it.delete() }
        File(directory, "$id.tmp").delete()
        val journal = File(directory, "$id.json")
        return if (journal.isFile) recoverJob(migrateLegacyBoundary(readJob(journal))) else null
    }

    /** Resume-specific spelling used by the import queue. */
    fun recoverForResume(id: String): CameraImportJob? = recover(id)

    private fun cleanupLoadArtifacts() {
        temporary.listFiles().orEmpty().filter { it.isFile && it.extension == "part" && validId(it.nameWithoutExtension) }
            .forEach { it.delete() }
        temporary.listFiles().orEmpty().filter { it.isFile && it.name.endsWith(".jpeg-part") }.forEach { it.delete() }
        directory.listFiles().orEmpty().filter { it.isFile && it.extension == "tmp" && validId(it.nameWithoutExtension) }
            .forEach { it.delete() }
    }

    private fun recoverJob(job: CameraImportJob): CameraImportJob {
        val items = job.items.map { item ->
            if (item.saved != null) {
                val current = runCatching { media.inspect(item.saved.uri) }.getOrNull()
                val expectedSize = item.outputSize ?: item.photo.size
                val expectedDigest = item.outputDigest ?: item.digest
                when {
                    current == null || current.pending -> item.copy(saved = null, unavailable = item.saved, problem = CameraMediaProblem.MISSING)
                    !validContent(current.uri, expectedSize, expectedDigest) -> item.copy(saved = null, unavailable = current, problem = CameraMediaProblem.CHANGED)
                    else -> {
                        media.remember(current.uri, expectedSize, checkNotNull(expectedDigest))
                        item.copy(saved = current, problem = null)
                    }
                }
            } else if (item.prepared != null) {
                val expectedSize = item.outputSize ?: item.photo.size
                val expectedDigest = item.outputDigest ?: item.digest
                val candidate = media.inspect(item.prepared.uri)
                if (candidate != null && validContent(candidate.uri, expectedSize, expectedDigest)) {
                    media.remember(candidate.uri, expectedSize, checkNotNull(expectedDigest))
                    val saved = if (candidate.pending) media.publish(candidate.uri) else candidate
                    item.copy(saved = saved, prepared = null, problem = null)
                } else {
                    // 外部已经发布/修改的文件不属于待清理数据。
                    if (candidate?.pending == true) media.deletePending(candidate.uri)
                    item.copy(prepared = null, digest = null)
                }
            } else item
        }
        val complete = items.all { it.saved != null }
        val recovered = job.copy(items = items, status = if (complete) CameraJobStatus.COMPLETE else CameraJobStatus.PAUSED,
            committed = job.committed || complete)
        return migrateLegacyBoundary(recovered).also(::save)
    }

    fun publish(job: CameraImportJob, index: Int, part: File, digest: String, permit: CameraTransferPermit): CameraImportJob {
        permit.check()
        val item = job.items[index]
        if (part.canonicalFile != partial(job.id).canonicalFile || part.length() != item.photo.size ||
            !validDigest(digest) || !validHeader(part, item.photo.raw)) throw IOException("Incomplete camera photo")
        part.inputStream().use { if (contentDigest(it, item.photo.size) { permit.check() } != digest) throw IOException("Camera photo digest mismatch") }
        val capture = readCaptureDate(part)
        val jpegOptions = job.jpegOptions(item)
        return permit.publish {
            val duplicate = readJobs().asSequence().flatMap { existingJob ->
                existingJob.items.asSequence().map { existingJob to it }
            }.filter { (existingJob, existing) ->
                existing.digest == digest && existing.photo.size == item.photo.size &&
                    existing.saved != null && existingJob.jpegOptions(existing) == jpegOptions
            }.mapNotNull { (_, existing) ->
                    val saved = existing.saved ?: return@mapNotNull null
                    val expectedSize = existing.outputSize ?: existing.photo.size
                    val expectedDigest = existing.outputDigest ?: existing.digest
                    runCatching { media.inspect(saved.uri) }.getOrNull()?.let { candidate ->
                        candidate.takeIf { !it.pending && validContent(it.uri, expectedSize, expectedDigest) }
                            ?.let { it to existing }
                    }
                }.firstOrNull()
            val saved: MediaPhoto
            var outputDigest = digest
            var outputSize = item.photo.size
            var outputPart = part
            if (duplicate != null) {
                // An older app may have cached an adjusted JPEG without its gain map.
                if (jpegOptions != null) verifyJpeg(part)
                val (photo, source) = duplicate
                saved = photo
                outputDigest = source.outputDigest ?: digest
                outputSize = source.outputSize ?: item.photo.size
                media.remember(saved.uri, outputSize, outputDigest)
            } else {
                if (jpegOptions != null) {
                    outputPart = File(temporary, "${job.id}-$index.jpeg-part")
                    outputPart.delete()
                    val processed = try { processJpeg(part, outputPart, jpegOptions) }
                    catch (error: Throwable) { outputPart.delete(); throw error }
                    outputDigest = processed.digest
                    outputSize = processed.size
                }
                val pending = media.createPending(safeName(item.photo.name), job.destination.relativePath(capture),
                    if (item.photo.raw) "image/x-sony-arw" else "image/jpeg", "${job.id}:$index")
                // 先登记系统 URI，写入或发布途中退出时按原记录恢复，不再创建第二张。
                save(job.replacing(index, item.copy(prepared = pending, digest = digest, outputDigest = outputDigest,
                    outputSize = outputSize, captureDay = capture?.day)))
                media.write(pending.uri, outputPart)
                if (!validContent(pending.uri, outputSize, outputDigest)) throw IOException("Stored camera photo differs")
                media.remember(pending.uri, outputSize, outputDigest)
                saved = media.publish(pending.uri)
            }
            val updated = job.replacing(index, item.copy(saved = saved, prepared = null, digest = digest,
                outputDigest = outputDigest, outputSize = outputSize, captureDay = capture?.day,
                duplicate = duplicate != null, problem = null))
            val complete = updated.savedCount == updated.items.size
            val result = migrateLegacyBoundary(updated.copy(status = if (complete) CameraJobStatus.COMPLETE else CameraJobStatus.ACTIVE,
                committed = job.committed || complete))
            save(result)
            part.delete()
            if (outputPart != part) outputPart.delete()
            result
        }
    }

    fun savedUris(job: CameraImportJob): List<String> = job.items.mapNotNull { item ->
        item.saved?.let { saved ->
            val current = media.inspect(saved.uri) ?: throw IOException("Camera original is unavailable")
            if (current.pending) throw IOException("Camera original is not published")
            if (!validContent(current.uri, item.outputSize ?: item.photo.size, item.outputDigest ?: item.digest))
                throw CameraLocalSourceChanged()
            current.uri
        }
    }.distinct()

    @Synchronized fun save(job: CameraImportJob) {
        require(validId(job.id))
        val items = JSONArray()
        job.items.forEach { item -> items.put(JSONObject().put("key", item.photo.key).put("name", item.photo.name)
            .put("size", item.photo.size).put("created", item.photo.created).put("storage", item.photo.storageToken)
            .put("captureTimestamp", item.photo.captureTimestamp.takeIf { it != item.photo.created })
            .put("resumeIdentity", item.photo.resumeIdentity)
            .put("saved", item.saved?.json())
            .put("prepared", item.prepared?.json()).put("digest", item.digest).put("captureDay", item.captureDay)
            .put("duplicate", item.duplicate).put("unavailable", item.unavailable?.json()).put("problem", item.problem?.name)
            .put("saveOriginalJpeg", item.saveOriginalJpeg.takeIf { it })
            .put("outputDigest", item.outputDigest).put("outputSize", item.outputSize)) }
        val json = JSONObject().put("version", 2).put("camera", job.cameraId).put("time", job.createdAt)
            .put("status", job.status.name).put("items", items).put("directory", job.destination.directory)
            .put("grouping", job.destination.grouping.name).put("incremental", job.incremental?.json())
            .put("committed", job.committed)
        job.hardwareIdentity?.let { json.put("hardwareIdentity", JSONObject().put("model", it.model).put("serial", it.serial)) }
        val part = File(directory, "${job.id}.tmp")
        val target = File(directory, "${job.id}.json")
        try {
            FileOutputStream(part).use { it.write(json.toString().toByteArray()); it.fd.sync() }
            try { Files.move(part.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING) }
            catch (_: AtomicMoveNotSupportedException) { Files.move(part.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING) }
        } finally { part.delete() }
    }

    private fun readJobs(): List<CameraImportJob> = directory.listFiles().orEmpty()
        .filter { it.isFile && it.extension == "json" && validId(it.nameWithoutExtension) }
        .map(::readJob).sortedByDescending { it.createdAt }

    private fun readJob(file: File): CameraImportJob {
        if (file.length() > 8L * 1024 * 1024) throw IOException("Camera journal exceeds budget")
        val json = JSONObject(file.readText())
        if (json.getInt("version") != 2) throw IOException("Unsupported camera journal")
        val array = json.getJSONArray("items")
        if (array.length() !in 1..10000) throw IOException("Invalid camera journal items")
        val items = (0 until array.length()).map { index ->
            val item = array.getJSONObject(index)
            val created = item.getLong("created")
            val photo = CameraPhoto(item.getString("key"), item.getString("name"), item.getLong("size"), created,
                resumeIdentity = item.optString("resumeIdentity").takeIf { it.isNotEmpty() },
                storageToken = item.optString("storage").takeIf { it.isNotEmpty() },
                captureTimestamp = item.optLong("captureTimestamp", created))
            if (photo.size !in 1..SystemPhotoStore.MAX_BYTES) throw IOException("Invalid camera photo size")
            val saved = item.optJSONObject("saved")?.mediaPhoto()
            val prepared = item.optJSONObject("prepared")?.mediaPhoto()
            val digest = item.optString("digest").takeIf { it.isNotEmpty() }
            if ((saved != null || prepared != null) && !validDigest(digest)) throw IOException("Invalid camera digest")
            val outputDigest = item.optString("outputDigest").takeIf { it.isNotEmpty() }
            val outputSize = item.optLongOrNull("outputSize")
            if (outputDigest != null && !validDigest(outputDigest)) throw IOException("Invalid camera output digest")
            if (outputDigest != null && outputSize !in 1..SystemPhotoStore.MAX_BYTES) throw IOException("Invalid camera output size")
            CameraImportItem(photo, saved, prepared, digest, item.optString("captureDay").takeIf { it.isNotEmpty() }, item.optBoolean("duplicate"),
                item.optJSONObject("unavailable")?.mediaPhoto(), item.optString("problem").takeIf { it.isNotEmpty() }?.let(CameraMediaProblem::valueOf),
                outputDigest, outputSize, saveOriginalJpeg = item.optBoolean("saveOriginalJpeg"))
        }
        val hardware = json.optJSONObject("hardwareIdentity")?.let {
            CameraHardwareIdentity(it.getString("model"), it.getString("serial"))
        }
        return CameraImportJob(file.nameWithoutExtension, json.getString("camera"), json.getLong("time"), items,
            CameraJobStatus.valueOf(json.getString("status")), CameraImportDestination(json.getString("directory"),
                CameraDirectoryGrouping.valueOf(json.getString("grouping"))), json.optJSONObject("incremental")?.incrementalPlan(),
            json.optBoolean("committed", json.getString("status") == CameraJobStatus.COMPLETE.name), hardware)
    }

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
    private fun migrateLegacyBoundary(job: CameraImportJob): CameraImportJob {
        val plan = job.incremental ?: return job
        val legacy = plan.boundary ?: return job
        if (!job.committed) return job
        // Legacy global dates and keys may have come from a format that was never saved.
        val saved = job.items.filter { it.saved != null || it.unavailable != null }.map { it.photo }
        val checkpoints = buildMap {
            saved.groupBy { CameraImportFormat.kindOf(it) }.forEach { (kind, photos) ->
                CameraImportBoundary.latest(photos, legacy.storage, legacy.owner)?.let { put(kind, it) }
            }
        }
        return job.copy(incremental = plan.copy(boundary = null, checkpoints = checkpoints))
    }

    private fun MediaPhoto.json() = JSONObject().put("uri", uri).put("name", displayName).put("path", relativePath).put("pending", pending)
    private fun JSONObject.mediaPhoto() = MediaPhoto(getString("uri"), getString("name"), getString("path"), getBoolean("pending"))
    private fun JSONObject.optLongOrNull(name: String): Long? = if (has(name) && !isNull(name)) optLong(name) else null
    private fun CameraIncrementalPlan.json(): JSONObject = JSONObject().put("format", format.name)
        .put("jpeg", jpeg.json()).put("boundary", boundary?.json())
        .put("checkpoints", JSONObject().also { objectValue -> checkpoints.forEach { (kind, value) -> objectValue.put(kind.name, value.json()) } })
        .put("customCutoff", customCutoffMillis).put("includeUndated", includeUndated).put("sessionOwner", sessionOwner)
    private fun CameraJPEGOptions.json() = JSONObject().put("adjust", adjust).put("longEdge", longEdge).put("quality", quality)
    private fun CameraImportBoundary.json() = JSONObject().put("date", dateMillis).put("storage", JSONArray(storage.toList()))
        .put("keys", JSONArray(keys.toList())).put("anchors", JSONArray(anchors.toList())).put("owner", owner)
    private fun JSONObject.incrementalPlan(): CameraIncrementalPlan {
        val format = CameraImportFormat.valueOf(getString("format"))
        val jpegObject = optJSONObject("jpeg")
        val jpeg = if (jpegObject == null) CameraJPEGOptions() else CameraJPEGOptions(
            jpegObject.optBoolean("adjust"), jpegObject.optInt("longEdge").takeIf { jpegObject.has("longEdge") && !jpegObject.isNull("longEdge") },
            jpegObject.optInt("quality", 90))
        val boundary = optJSONObject("boundary")?.boundaryCheckpoint()
        val checkpoints = buildMap {
            val value = optJSONObject("checkpoints")
            CameraImportFormat.RAW_AND_JPEG.kinds.forEach { kind -> value?.optJSONObject(kind.name)?.let {
                put(kind, it.boundaryCheckpoint())
            } }
        }
        return CameraIncrementalPlan(format, jpeg, boundary, optLongOrNull("customCutoff"), optBoolean("includeUndated"),
            optString("sessionOwner").takeIf { it.isNotEmpty() }, checkpoints)
    }
    private fun JSONObject.boundaryCheckpoint(): CameraImportBoundary = CameraImportBoundary(getLong("date"),
        getJSONArray("storage").stringSet(), getJSONArray("keys").stringSet(),
        getJSONArray("anchors").stringSet(), getString("owner"))
    private fun JSONArray.stringSet(): Set<String> = (0 until length()).map { getString(it) }.toSet()
    private fun CameraImportJob.replacing(index: Int, item: CameraImportItem) = copy(items = items.toMutableList().also { it[index] = item })
}
