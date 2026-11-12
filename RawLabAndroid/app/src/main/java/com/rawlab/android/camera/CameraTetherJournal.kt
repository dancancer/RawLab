package com.rawlab.android.camera

import com.rawlab.android.photo.SystemPhotoStore
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

internal enum class CameraTetherStatus { ACTIVE, PAUSED, ENDED }
internal data class CameraTetherBatch(val id: String, val photos: List<CameraPhoto>)
internal data class CameraTetherRun(val id: String, val cameraId: String, val profileId: String, val createdAt: Long,
    val baseline: List<CameraPhoto>, val destination: CameraImportDestination,
    val batches: List<CameraTetherBatch> = emptyList(), val status: CameraTetherStatus = CameraTetherStatus.ACTIVE,
    val shutterRequestedAt: Long? = null, val hardwareIdentity: CameraHardwareIdentity? = null,
    val rebasedBatches: Int = 0) {
    val observedPhotos: List<CameraPhoto> get() = baseline + batches.drop(rebasedBatches).flatMap { it.photos }
}

/** 只记录发现与预留任务；原件和发布结果由 CameraImportStore 持有。调用方共用同一存储锁。 */
internal class CameraTetherJournal(private val directory: File) {
    init { directory.mkdirs() }

    fun create(cameraId: String, profileId: String, baseline: List<CameraPhoto>, destination: CameraImportDestination,
        hardwareIdentity: CameraHardwareIdentity? = null): CameraTetherRun =
        CameraTetherRun(UUID.randomUUID().toString(), cameraId, profileId, System.currentTimeMillis(), baseline, destination,
            hardwareIdentity = hardwareIdentity).also(::save)

    fun reserve(run: CameraTetherRun, observed: List<CameraPhoto>): Pair<CameraTetherRun, CameraTetherBatch?> {
        val current = checkedObservation(run, observed)
        if (run.status != CameraTetherStatus.ACTIVE) throw IOException("Tether run is not active")
        val known = run.observedPhotos.map { it.key }.toSet()
        val added = current.values.filter { it.key !in known }.take(BATCH_SIZE)
        if (added.isEmpty()) return run to null
        val batch = CameraTetherBatch(UUID.randomUUID().toString(), added)
        val updated = run.copy(batches = run.batches + batch)
        save(updated)
        return updated to batch
    }

    /** 元数据只用于定位候选。队列在保存基线前核对已登记原件的字节。 */
    fun rebase(run: CameraTetherRun, observed: List<CameraPhoto>): CameraTetherRun {
        validate(run)
        val current = checkedListing(observed)
        val listed = current.values.groupBy { it.resumeMetadataKey }
        val matched = run.observedPhotos.map { photo ->
            listed[photo.resumeMetadataKey]?.singleOrNull { photo.matchesResumeMetadata(it) }?.key
                ?: throw CameraTetherSourceException()
        }
        if (matched.toSet().size != matched.size) throw CameraTetherSourceException()
        return run.copy(baseline = current.values.toList(), rebasedBatches = run.batches.size, status = CameraTetherStatus.ACTIVE)
    }

    private fun checkedObservation(run: CameraTetherRun, observed: List<CameraPhoto>): Map<String, CameraPhoto> {
        validate(run)
        val current = checkedListing(observed)
        if (run.observedPhotos.any { current[it.key]?.let(it::matchesSnapshot) != true }) throw CameraTetherSourceException()
        return current
    }

    private fun checkedListing(observed: List<CameraPhoto>): Map<String, CameraPhoto> {
        val current = linkedMapOf<String, CameraPhoto>()
        // 完整校验后再截取批次，不能把批次之后的身份冲突推迟到下一次轮询。
        observed.forEach { photo ->
            validatePhoto(photo)
            val previous = current.putIfAbsent(photo.key, photo)
            if (previous != null && previous != photo) throw IOException("Camera object metadata changed")
            if (current.size > MAX_PHOTOS) throw IOException("Too many camera objects")
        }
        return current
    }

    fun load(): List<CameraTetherRun> = directory.listFiles().orEmpty().filter { it.isFile && it.extension == "json" }.map { file ->
        try {
            if (!validId(file.nameWithoutExtension) || file.length() > MAX_BYTES) throw IOException("Invalid tether journal file")
            val json = JSONObject(file.readText())
            if (json.getInt("version") != 1) throw IOException("Unsupported tether journal version")
            val batches = json.getJSONArray("batches")
            if (batches.length() > MAX_PHOTOS) throw IOException("Too many tether batches")
            val run = CameraTetherRun(file.nameWithoutExtension, json.getString("camera"), json.getString("profile"), json.getLong("time"),
                readPhotos(json.getJSONArray("baseline")), CameraImportDestination(json.getString("directory"),
                    CameraDirectoryGrouping.valueOf(json.getString("grouping"))),
                (0 until batches.length()).map { index -> batches.getJSONObject(index).let { batch ->
                    CameraTetherBatch(batch.getString("id"), readPhotos(batch.getJSONArray("photos")))
                } }, CameraTetherStatus.valueOf(json.getString("status")),
                if (json.has("shutterRequestedAt")) json.getLong("shutterRequestedAt") else null,
                json.optJSONObject("hardwareIdentity")?.let { CameraHardwareIdentity(it.getString("model"), it.getString("serial")) },
                json.optInt("rebasedBatches"))
            validate(run)
            if (run.status == CameraTetherStatus.ACTIVE) run.copy(status = CameraTetherStatus.PAUSED).also(::save) else run
        } catch (error: IOException) { throw error }
        catch (error: Exception) { throw IOException("Invalid tether journal", error) }
    }.sortedByDescending { it.createdAt }

    @Synchronized fun save(run: CameraTetherRun) {
        validate(run)
        val batches = JSONArray()
        run.batches.forEach { batches.put(JSONObject().put("id", it.id).put("photos", photosJson(it.photos))) }
        val json = JSONObject().put("version", 1).put("camera", run.cameraId).put("profile", run.profileId).put("time", run.createdAt)
            .put("status", run.status.name).put("directory", run.destination.directory).put("grouping", run.destination.grouping.name)
            .put("baseline", photosJson(run.baseline)).put("batches", batches).put("shutterRequestedAt", run.shutterRequestedAt)
            .put("rebasedBatches", run.rebasedBatches.takeIf { it != 0 })
        run.hardwareIdentity?.let { json.put("hardwareIdentity", JSONObject().put("model", it.model).put("serial", it.serial)) }
        val bytes = json.toString().toByteArray()
        if (bytes.size > MAX_BYTES) throw IOException("Tether journal exceeds budget")
        val part = File(directory, "${run.id}.tmp")
        val target = File(directory, "${run.id}.json")
        try {
            FileOutputStream(part).use { it.write(bytes); it.fd.sync() }
            try { Files.move(part.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING) }
            catch (_: AtomicMoveNotSupportedException) { Files.move(part.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING) }
        } finally { part.delete() }
    }

    private fun validate(run: CameraTetherRun) {
        if (!validId(run.id) || run.cameraId.isBlank() || run.cameraId.length > 512 || run.profileId.isBlank() || run.profileId.length > 128 || run.createdAt < 0 ||
            run.shutterRequestedAt?.let { it < 0 } == true || run.rebasedBatches !in 0..run.batches.size)
            throw IOException("Invalid tether run identity")
        val ids = mutableSetOf<String>()
        run.batches.forEach { batch ->
            if (!validId(batch.id) || !ids.add(batch.id) || batch.photos.size !in 1..BATCH_SIZE) throw IOException("Invalid tether batch")
            batch.photos.forEach(::validatePhoto)
        }
        val photos = run.observedPhotos
        if (photos.size > MAX_PHOTOS || run.batches.sumOf { it.photos.size } > MAX_PHOTOS ||
            photos.map { it.key }.distinct().size != photos.size) throw IOException("Invalid tether object identities")
        run.baseline.forEach(::validatePhoto)
    }

    private fun validatePhoto(photo: CameraPhoto) {
        if (photo.key.isBlank() || photo.key.length > 1024 || photo.size !in 1..SystemPhotoStore.MAX_BYTES ||
            photo.name.isBlank() || photo.name.startsWith('.') || photo.name.toByteArray().size > 240 ||
            photo.name.any { it.isISOControl() || it in "/\\:*?\"<>|" }) throw IOException("Invalid tether photo")
    }

    private fun photosJson(photos: List<CameraPhoto>) = JSONArray().also { array ->
        photos.forEach { photo -> array.put(JSONObject().put("key", photo.key).put("name", photo.name)
            .put("size", photo.size).put("created", photo.created).put("resumeIdentity", photo.resumeIdentity)
            .put("storage", photo.storageToken).put("captureTimestamp", photo.captureTimestamp.takeIf { it != photo.created })) }
    }
    private fun readPhotos(array: JSONArray): List<CameraPhoto> {
        if (array.length() > MAX_PHOTOS) throw IOException("Too many tether photos")
        return (0 until array.length()).map { index -> array.getJSONObject(index).let {
            val created = it.getLong("created")
            CameraPhoto(it.getString("key"), it.getString("name"), it.getLong("size"), created,
                it.optString("resumeIdentity").takeIf(String::isNotEmpty), it.optString("storage").takeIf(String::isNotEmpty),
                it.optLong("captureTimestamp", created))
        } }
    }
    private fun validId(id: String) = runCatching { UUID.fromString(id).toString() == id }.getOrDefault(false)

    companion object {
        const val BATCH_SIZE = 16
        private const val MAX_PHOTOS = 10000
        private const val MAX_BYTES = 8 * 1024 * 1024
    }
}
