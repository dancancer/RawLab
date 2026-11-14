package com.rawlab.android.camera

import com.rawlab.android.camera.protocol.CameraMediaSession
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
    val rebasedBatches: Int = 0, val truncatedListing: Boolean = false) {
    val observedPhotos: List<CameraPhoto> get() = baseline + batches.drop(rebasedBatches).flatMap { it.photos }
}

internal sealed interface CameraTetherObservationMode {
    data object Full : CameraTetherObservationMode
    data class Incremental(val afterCursor: Long? = null) : CameraTetherObservationMode
}

/** 只记录发现与预留任务；原件和发布结果由 CameraImportStore 持有。调用方共用同一存储锁。 */
internal class CameraTetherJournal(private val directory: File) {
    init { directory.mkdirs() }

    fun create(cameraId: String, profileId: String, baseline: List<CameraPhoto>, destination: CameraImportDestination,
        hardwareIdentity: CameraHardwareIdentity? = null, truncatedListing: Boolean = false): CameraTetherRun =
        CameraTetherRun(UUID.randomUUID().toString(), cameraId, profileId, System.currentTimeMillis(), baseline, destination,
            hardwareIdentity = hardwareIdentity, truncatedListing = truncatedListing).also(::save)

    fun reserve(run: CameraTetherRun, observed: List<CameraPhoto>,
        mode: CameraTetherObservationMode = CameraTetherObservationMode.Full): Pair<CameraTetherRun, CameraTetherBatch?> {
        val current = checkedObservation(run, observed, mode)
        if (run.status != CameraTetherStatus.ACTIVE) throw IOException("Tether run is not active")
        val known = run.observedPhotos.map { it.key }.toSet()
        val added = current.values.filter { it.key !in known }.take(BATCH_SIZE)
        if (added.isEmpty()) return run to null
        val batch = CameraTetherBatch(UUID.randomUUID().toString(), added)
        val updated = run.copy(batches = run.batches + batch)
        save(updated)
        return updated to batch
    }

    /** 元数据只用于定位候选。队列在保存基线前核对已登记原件的字节；续接后旧连接未确认的快门结果需到机身核对，不再继承。 */
    fun rebase(run: CameraTetherRun, observed: List<CameraPhoto>): CameraTetherRun {
        validate(run)
        val current = checkedListing(observed)
        val listed = current.values.groupBy { it.resumeMetadataKey }
        // 会话只承诺最近 10000 个对象（trimRecentAssets 按 created/name 降序保留）：满窗口列表才允许更早的基线对象缺席；
        // 候选存在但不匹配或有歧义一律拒绝，已登记批次的原件无论新旧都必须仍在卡上。窗口标记按新快照刷新。
        val windowed = current.size >= MAX_PHOTOS
        val floor = if (windowed) current.values.minWith(windowOrder) else null
        val reserved = run.batches.drop(run.rebasedBatches).flatMap { it.photos }.map { it.key }.toSet()
        val matched = run.observedPhotos.mapNotNull { photo ->
            val match = listed[photo.resumeMetadataKey]?.singleOrNull { photo.matchesResumeMetadata(it) }
            when {
                match != null -> match.key
                listed.containsKey(photo.resumeMetadataKey) -> throw CameraTetherSourceException()
                photo.key in reserved || floor == null || windowOrder.compare(photo, floor) >= 0 -> throw CameraTetherSourceException()
                else -> null
            }
        }
        if (matched.toSet().size != matched.size) throw CameraTetherSourceException()
        return run.copy(baseline = current.values.toList(), rebasedBatches = run.batches.size,
            status = CameraTetherStatus.ACTIVE, shutterRequestedAt = null, truncatedListing = windowed)
    }

    /**
     * 全量观测要求历史照片全部仍在当前列表且元数据一致；增量轮询只拉取游标之后的尾部页或新增句柄，
     * 因此游标之前的历史照片本就不会出现在 `observed` 中，改按增量语义守住同一安全边界：
     * 1. 新协议（`afterCursor != null`）要求所有 `created > afterCursor` 的尾部锚点仍在本次返回中且快照一致，
     *    换卡、格式化或删改尾部对象会因尾部锚点缺失/不一致立即报 `CameraTetherSourceException`。
     * 2. 旧协议已由传输层先经 `0x1007` 一次性核实全部历史照片句柄仍在卡上，再仅对新增句柄查 `0x1008`。
     * 3. 任何重现的历史 `key` 或被复用的相机对象槽位（`mobile:content:file` / `legacy:storage:handle`）
     *    若与已记录快照不一致，立即拒绝，不会把被覆写/重用的槽位当成新照片；并校验总对象数不超上限。
     */
    private fun checkedObservation(run: CameraTetherRun, observed: List<CameraPhoto>, mode: CameraTetherObservationMode): Map<String, CameraPhoto> {
        validate(run)
        val current = checkedListing(observed)
        val knownByKey = run.observedPhotos.associateBy { it.key }
        if (!run.truncatedListing && knownByKey.size + current.keys.count { it !in knownByKey } > MAX_PHOTOS)
            throw CameraMediaSession.PhotoLimitExceededException("Too many camera objects")
        when (mode) {
            is CameraTetherObservationMode.Full -> {
                // 满窗口列表按 trimRecentAssets 的下界放行更早的基线对象缺席；窗口未成形时缺席仍是来源变化（含快照不一致）。
                val floor = if (current.size >= MAX_PHOTOS) current.values.minWith(windowOrder) else null
                if (run.observedPhotos.any { photo -> current[photo.key]?.let { !photo.matchesSnapshot(it) } == true ||
                        current[photo.key] == null && (floor == null || windowOrder.compare(photo, floor) >= 0) })
                    throw CameraTetherSourceException()
            }
            is CameraTetherObservationMode.Incremental -> {
                if (mode.afterCursor != null && run.observedPhotos.any { it.created > mode.afterCursor && current[it.key]?.let(it::matchesSnapshot) != true })
                    throw CameraTetherSourceException()
                val knownBySlot = mutableMapOf<String, CameraPhoto>()
                for (known in run.observedPhotos) known.objectSlotKey()?.let { knownBySlot.putIfAbsent(it, known) }
                for (photo in current.values) {
                    knownByKey[photo.key]?.let { if (!it.matchesSnapshot(photo)) throw CameraTetherSourceException() }
                    photo.objectSlotKey()?.let { slot -> knownBySlot[slot]?.let { if (!it.matchesSnapshot(photo)) throw CameraTetherSourceException() } }
                }
            }
        }
        return current
    }

    private fun CameraPhoto.objectSlotKey(): String? {
        val identity = resumeIdentity ?: return null
        val parts = identity.split(':', limit = 4)
        return if (parts.size >= 3 && (parts[0] == "mobile" || parts[0] == "legacy")) "${parts[0]}:${parts[1]}:${parts[2]}" else null
    }

    private fun checkedListing(observed: List<CameraPhoto>): Map<String, CameraPhoto> {
        val current = linkedMapOf<String, CameraPhoto>()
        // 完整校验后再截取批次，不能把批次之后的身份冲突推迟到下一次轮询。
        observed.forEach { photo ->
            validatePhoto(photo)
            val previous = current.putIfAbsent(photo.key, photo)
            if (previous != null && previous != photo) throw CameraTetherSourceException()
            if (current.size > MAX_PHOTOS) throw CameraMediaSession.PhotoLimitExceededException("Too many camera objects")
        }
        return current
    }

    /** 逐个解析；读不出的记录原样保留并跳过，不影响其它联机记录。写回失败仍向上报告。 */
    fun load(): List<CameraTetherRun> = directory.listFiles().orEmpty().filter { it.isFile && it.extension == "json" }.mapNotNull { file ->
        val run = try {
            if (!validId(file.nameWithoutExtension) || file.length() > MAX_BYTES) throw IOException("Invalid tether journal file")
            val json = JSONObject(file.readText())
            if (json.getInt("version") != 1) throw IOException("Unsupported tether journal version")
            val batches = json.getJSONArray("batches")
            if (batches.length() > MAX_PHOTOS) throw IOException("Too many tether batches")
            CameraTetherRun(file.nameWithoutExtension, json.getString("camera"), json.getString("profile"), json.getLong("time"),
                readPhotos(json.getJSONArray("baseline")), CameraImportDestination(json.getString("directory"),
                    CameraDirectoryGrouping.valueOf(json.getString("grouping"))),
                (0 until batches.length()).map { index -> batches.getJSONObject(index).let { batch ->
                    CameraTetherBatch(batch.getString("id"), readPhotos(batch.getJSONArray("photos")))
                } }, CameraTetherStatus.valueOf(json.getString("status")),
                if (json.has("shutterRequestedAt")) json.getLong("shutterRequestedAt") else null,
                json.optJSONObject("hardwareIdentity")?.let { CameraHardwareIdentity(it.getString("model"), it.getString("serial")) },
                json.optInt("rebasedBatches"), json.optBoolean("truncated")).also(::validate)
        } catch (_: Exception) { return@mapNotNull null }
        if (run.status == CameraTetherStatus.ACTIVE) run.copy(status = CameraTetherStatus.PAUSED).also(::save) else run
    }.sortedByDescending { it.createdAt }

    @Synchronized fun save(run: CameraTetherRun) {
        validate(run)
        val batches = JSONArray()
        run.batches.forEach { batches.put(JSONObject().put("id", it.id).put("photos", photosJson(it.photos))) }
        val json = JSONObject().put("version", 1).put("camera", run.cameraId).put("profile", run.profileId).put("time", run.createdAt)
            .put("status", run.status.name).put("directory", run.destination.directory).put("grouping", run.destination.grouping.name)
            .put("baseline", photosJson(run.baseline)).put("batches", batches).put("shutterRequestedAt", run.shutterRequestedAt)
            .put("rebasedBatches", run.rebasedBatches.takeIf { it != 0 }).also { if (run.truncatedListing) it.put("truncated", true) }
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
        if ((!run.truncatedListing && (photos.size > MAX_PHOTOS || run.batches.sumOf { it.photos.size } > MAX_PHOTOS)) ||
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
        private val windowOrder = compareBy<CameraPhoto>({ it.created }, { it.name })
        private const val MAX_PHOTOS = 10000
        private const val MAX_BYTES = 8 * 1024 * 1024
    }
}
