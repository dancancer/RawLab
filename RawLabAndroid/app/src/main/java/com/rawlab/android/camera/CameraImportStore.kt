package com.rawlab.android.camera

import com.rawlab.android.io.replaceFileAtomically
import com.rawlab.android.camera.protocol.SonyMobileSession
import com.rawlab.android.photo.MediaPhoto
import com.rawlab.android.photo.MediaPhotoAccess
import com.rawlab.android.photo.MediaPhotoStat
import com.rawlab.android.photo.SystemPhotoStore
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
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
internal enum class CameraMediaProblem {
    MISSING, CHANGED, REMOTE_MISSING, HDR_GAIN_MAP, JPEG_MEMORY;

    val needsOriginalJpeg: Boolean get() = this == HDR_GAIN_MAP || this == JPEG_MEMORY
}
internal data class CameraImportItem(val photo: CameraPhoto, val saved: MediaPhoto? = null,
    val prepared: MediaPhoto? = null, val digest: String? = null, val captureDay: String? = null,
    val duplicate: Boolean = false, val unavailable: MediaPhoto? = null, val problem: CameraMediaProblem? = null,
    val outputDigest: String? = null, val outputSize: Long? = null, val saveOriginalJpeg: Boolean = false,
    val error: String? = null, val skipped: Boolean = false,
    /** 内容校验通过那一刻媒体文件的 stat 指纹（"$size:$modifiedAt"）；下次加载指纹未变即跳过整文件摘要。 */
    val savedStat: String? = null) {
    val hasFailure: Boolean get() = saved == null && !skipped && (error != null || problem != null)
    val canSkip: Boolean get() = saved == null && !skipped && unavailable == null &&
        (error != null || problem == CameraMediaProblem.REMOTE_MISSING)
}

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
    val hardwareIdentity: CameraHardwareIdentity? = null, val listingOwner: String? = null,
    val jpeg: CameraJPEGOptions? = null) {
    val originalListingOwner: String? get() = listingOwner ?: incremental?.sessionOwner
    val savedCount: Int get() = items.count { it.saved != null }
    val failedCount: Int get() = items.count { it.hasFailure }
    val skippedCount: Int get() = items.count { it.skipped }
    val pendingCount: Int get() = items.count { it.saved == null && !it.skipped && !it.hasFailure }
    val totalBytes: Long get() = items.sumOf { it.photo.size }
    val savedBytes: Long get() = items.filter { it.saved != null }.sumOf { it.photo.size }
    val effectiveJpeg: CameraJPEGOptions?
        get() = (jpeg ?: incremental?.jpeg)?.takeIf { it.adjust }

    fun matchesCamera(connectionId: String?, device: CameraHardwareIdentity?): Boolean =
        if (hardwareIdentity == null) cameraId == connectionId else hardwareIdentity == device

    fun jpegOptions(item: CameraImportItem): CameraJPEGOptions? =
        effectiveJpeg?.takeIf { !item.photo.raw && !item.saveOriginalJpeg }

    fun keepingPendingJpegOriginals(): CameraImportJob = copy(items = items.map { item ->
        if (item.photo.raw || item.saved != null || item.skipped) item
        else item.copy(saveOriginalJpeg = true, problem = item.problem.takeUnless { it?.needsOriginalJpeg == true })
    })

    fun withSafeIncrementalCheckpoints(): CameraImportJob {
        val plan = incremental ?: return this
        if (plan.checkpoints.isEmpty()) return this
        val safeCheckpoints = buildMap {
            plan.checkpoints.forEach { (kind, planned) ->
                val prefix = items.asSequence()
                    .filter { CameraImportFormat.kindOf(it.photo) == kind && it.photo.captureDateMillis != null }
                    .takeWhile { it.saved != null }
                    .map { it.photo }
                    .toList()
                CameraImportBoundary.latest(prefix, planned.storage, planned.owner)?.let { put(kind, it) }
            }
        }
        return copy(incremental = plan.copy(checkpoints = safeCheckpoints))
    }
}
internal class CameraPhotoImportException(message: String, cause: Throwable? = null) : IOException(message, cause)
internal class CameraLocalSourceChanged : IOException("Camera original has changed")
internal class CameraImportSourceChanged : IOException("Camera originals cannot be verified")

/** 停止与发布准入串行；已经完整接收并准入的文件允许完成发布，不在主线程等磁盘。 */
internal class CameraTransferPermit {
    @Volatile private var cancelled = false
    @Synchronized fun cancel() { cancelled = true }
    fun check() { if (cancelled) throw IOException("Camera transfer stopped") }
    fun <T> publish(block: () -> T): T { synchronized(this) { check() }; return block() }
}

internal class CameraImportStore(private val directory: File, private val temporary: File,
    private val media: MediaPhotoAccess, private val readCaptureDate: (File) -> CameraCaptureDate?) {
    private var processJpeg: (File, File, CameraJPEGOptions) -> CameraProcessedFile =
        { _, _, _ -> throw IOException("Camera JPEG processing is not configured") }
    private var verifyJpeg: (File) -> Unit = CameraJPEGProcessing::ensureAdjustmentSupported

    constructor(directory: File, temporary: File, media: MediaPhotoAccess,
        readCaptureDate: (File) -> CameraCaptureDate?,
        processJpeg: (File, File, CameraJPEGOptions) -> CameraProcessedFile,
        verifyJpeg: (File) -> Unit = {}) : this(directory, temporary, media, readCaptureDate) {
        this.processJpeg = processJpeg
        this.verifyJpeg = verifyJpeg
    }

    init { directory.mkdirs(); temporary.mkdirs() }

    /**
     * 写放大账目（测试观察钩子，contentDigestCount 同纪律，撤修复必红）：
     * directoryScans = 全目录枚举+逐文件解析次数；journalRewrites = `<id>.json` 全量快照重写次数；
     * walAppends = `<id>.wal` 行级锚追加次数（每次 1 个短行 + 1 次 fsync）。
     * 稳态每张的 fsync 次数 = journalRewrites + walAppends（每写一处 sync 一次）+ media.write 一次；
     * `.part` 下载尾部的 fd.sync 已移除：拷入 MediaStore 并校验前崩溃本就整张重下，`.part` 耐久性不在锚链上。
     */
    @Volatile internal var directoryScans = 0
        private set
    @Volatile internal var journalRewrites = 0
        private set
    @Volatile internal var walAppends = 0
        private set

    /** 进程内增量账本：目录内全部任务的最新状态（save/append 在保存锁内维护，等价此前每次重读磁盘的视野）。 */
    private val journals = LinkedHashMap<String, CameraImportJob>()
    /** 每任务快照与锚行共用的单调写序号：只存 store（锁内推进），不进入任务数据，避免把易变序号带进任务相等性。 */
    private val sequences = mutableMapOf<String, Long>()

    /** 发布去重与抽样复用共用的内存视野（排序与 readJobs 一致：createdAt 降序）。 */
    @Synchronized private fun ledgerJobs(): List<CameraImportJob> = journals.values.sortedByDescending { it.createdAt }

    private fun walFile(id: String) = File(directory, "$id.wal")

    /** 崩溃留下的坏 `.wal` 不该无限膨胀：超预算即按坏日志隔离（与坏快照同纪律，文件原样保留）。 */
    private val maxWalBytes = 8L shl 20

    /** 快照与锚行共用一把序号：store 锁内单调推进；load/recover 从盘上两份文件的最大值重新起算。 */
    private fun nextWalSeq(id: String): Long = (sequences[id] ?: 0L) + 1

    /** 快照+锚的行级合并视图（只读，不恢复、不落盘）：供门禁与调试取待发布 URI。 */
    internal fun mergedView(jobId: String): CameraImportJob? {
        val journal = File(directory, "$jobId.json")
        return if (journal.isFile) replayWal(readJob(journal), journal) else null
    }

    fun create(cameraId: String, photos: List<CameraPhoto>, destination: CameraImportDestination,
        id: String = UUID.randomUUID().toString(), incremental: CameraIncrementalPlan? = null,
        hardwareIdentity: CameraHardwareIdentity? = null, listingOwner: String? = null,
        jpeg: CameraJPEGOptions? = null): CameraImportJob {
        require(validId(id))
        require(photos.isNotEmpty() && photos.size <= 10000)
        require(photos.map { it.key }.distinct().size == photos.size)
        require(photos.all { it.size in 1..SystemPhotoStore.MAX_BYTES })
        val manualJpeg = if (incremental == null) jpeg?.takeIf { it.adjust } else null
        manualJpeg?.let { require(it.isValid) { "Invalid camera JPEG options" } }
        incremental?.let { plan ->
            require(plan.jpeg.isValid)
            require(photos.all(plan.format::includes))
        }
        // 只核对本任务的日志：读不出时报错而不是覆盖，也不受其它日志影响。
        File(directory, "$id.json").takeIf { it.isFile }?.let { replayWal(readJob(it), it) }?.let { existing ->
            if (existing.cameraId != cameraId || existing.hardwareIdentity != hardwareIdentity ||
                existing.destination != destination || existing.incremental != incremental ||
                existing.jpeg != manualJpeg ||
                existing.listingOwner != listingOwner || existing.items.size != photos.size ||
                existing.items.zip(photos).any { (stored, current) -> !stored.photo.matchesSnapshot(current) })
                throw IOException("Reserved camera job identity changed")
            return existing
        }
        return CameraImportJob(id, cameraId, System.currentTimeMillis(),
            photos.map { CameraImportItem(it) }, destination = destination, incremental = incremental,
            hardwareIdentity = hardwareIdentity, listingOwner = listingOwner, jpeg = manualJpeg).also(::save)
    }
    fun partial(id: String): File { require(validId(id)); return File(temporary, "$id.part") }

    /** 仅在初始化或已停下的队列中调用，调用方持有队列锁。 */
    fun load(): List<CameraImportJob> {
        cleanupLoadArtifacts()
        val unreadable = mutableSetOf<String>()
        val jobs = readJobs(unreadable).map(::migrateLegacyBoundary)
        unreadableJobIds = unreadable
        synchronized(this) { journals.clear(); jobs.forEach { journals[it.id] = it } }
        // 读不出的日志可能引用待发布媒体，存在时不能据此判定孤儿。
        if (unreadable.isEmpty()) {
            val referenced = jobs.flatMap { it.items.flatMap { item -> listOfNotNull(item.prepared?.uri, item.saved?.uri) } }.toSet()
            media.cleanupOrphans(referenced)
        }
        return jobs.map(::recoverJob)
    }

    /** 最近一次 load 中无法读取的任务日志；文件原样保留，不参与恢复和孤儿清理。 */
    @Volatile var unreadableJobIds: Set<String> = emptySet()
        private set

    /** 用户确认放弃一条坏日志：删除隔离文件，其待发布媒体由下一次 load 的孤儿清理回收。 */
    fun discardUnreadableJob(id: String): Boolean {
        if (id !in unreadableJobIds || !validId(id)) return false
        val file = File(directory, "$id.json")
        if (file.exists() && !file.delete()) return false // 删除失败保留隔离标记，可再次尝试。
        walFile(id).delete()
        unreadableJobIds = unreadableJobIds - id
        return true
    }

    /** Revalidates one resumable job without recovering unrelated jobs or cleaning their media. */
    fun recover(id: String): CameraImportJob? {
        require(validId(id))
        temporary.listFiles().orEmpty().filter { it.isFile &&
            ((it.name == "$id.part") || (it.name.startsWith("$id-") && it.name.endsWith(".jpeg-part"))) }
            .forEach { it.delete() }
        File(directory, "$id.tmp").delete()
        val journal = File(directory, "$id.json")
        return if (journal.isFile) recoverJob(migrateLegacyBoundary(replayWal(readJob(journal), journal))) else null
    }

    /** Resume-specific spelling used by the import queue. */
    fun recoverForResume(id: String): CameraImportJob? = recover(id)

    private fun cleanupLoadArtifacts() {
        temporary.listFiles().orEmpty().filter { it.isFile && it.extension == "part" && validId(it.nameWithoutExtension) }
            .forEach { it.delete() }
        temporary.listFiles().orEmpty().filter { it.isFile && it.name.endsWith(".jpeg-part") }.forEach { it.delete() }
        directory.listFiles().orEmpty().filter { it.isFile && it.extension == "tmp" && validId(it.nameWithoutExtension) }
            .forEach { it.delete() }
        // WAL 是随快照截断的锚日志；只回收没有对应快照的孤儿 WAL（快照必在 WAL 之前存在）。
        directory.listFiles().orEmpty().filter { it.isFile && it.extension == "wal" && validId(it.nameWithoutExtension) &&
            !File(directory, "${it.nameWithoutExtension}.json").isFile }.forEach { it.delete() }
    }

    private fun recoverJob(job: CameraImportJob): CameraImportJob {
        val items = job.items.map { item ->
            if (item.saved != null) {
                val current = runCatching { media.inspect(item.saved.uri) }.getOrNull()
                val expectedSize = item.outputSize ?: item.photo.size
                val expectedDigest = item.outputDigest ?: item.digest
                if (current == null || current.pending) {
                    item.copy(saved = null, unavailable = item.saved, problem = CameraMediaProblem.MISSING, savedStat = null, prepared = null)
                } else {
                    // stat 指纹（size＋mtime）优先；首次、指纹缺失或变化才做整文件内容摘要（A1）。
                    // 信任前提：指纹与记录值一致且指纹 size 等于预期校验 size，防止 size 漂移时误信旧 digest。
                    val stat = mediaStat(current.uri)
                    if (stat != null && stat.size == expectedSize && stat.fingerprint() == item.savedStat && validDigest(expectedDigest)) {
                        media.remember(current.uri, expectedSize, checkNotNull(expectedDigest))
                        item.copy(saved = current, problem = null, prepared = null)
                    } else if (!validContent(current.uri, expectedSize, expectedDigest)) {
                        item.copy(saved = null, unavailable = current, problem = CameraMediaProblem.CHANGED, savedStat = null, prepared = null)
                    } else {
                        media.remember(current.uri, expectedSize, checkNotNull(expectedDigest))
                        item.copy(saved = current, problem = null, savedStat = stat?.fingerprint(), prepared = null)
                    }
                }
            } else if (item.prepared != null) {
                val expectedSize = item.outputSize ?: item.photo.size
                val expectedDigest = item.outputDigest ?: item.digest
                val candidate = media.inspect(item.prepared.uri)
                if (candidate != null && validContent(candidate.uri, expectedSize, expectedDigest)) {
                    media.remember(candidate.uri, expectedSize, checkNotNull(expectedDigest))
                    val saved = if (candidate.pending) media.publish(candidate.uri) else candidate
                    // MediaProvider 到 publish（IS_PENDING=0）才扫描定稿元数据，指纹只能在发布后采集。
                    item.copy(saved = saved, prepared = null, problem = null, savedStat = publishedFingerprint(saved.uri, expectedSize))
                } else {
                    // 外部已经发布/修改的文件不属于待清理数据。
                    if (candidate?.pending == true) media.deletePending(candidate.uri)
                    item.copy(prepared = null)
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
        if (part.canonicalFile != partial(job.id).canonicalFile) throw IOException("Incomplete camera photo")
        if (part.length() != item.photo.size || !validDigest(digest) || !validHeader(part, item.photo.raw))
            throw CameraPhotoImportException("Incomplete camera photo")
        // 下载路径（SonyMobileSession/SonyTetherSession.download 逐块 write+update，copySampledOriginal 复用
        // 已校验来源）对写入句柄与 SHA-256 同步消费同一字节流并含头校验；上方已复核 .partial 尺寸与文件头，
        // 直接采信流式摘要，不再整读重算（与 iOS complete() 同构）。
        if (item.digest != null && item.digest != digest) throw CameraImportSourceChanged()
        val targetName = safeName(item.photo.name)
        val capture = readCaptureDate(part)
        val jpegOptions = job.jpegOptions(item)
        return permit.publish {
            val duplicate = ledgerJobs().asSequence().flatMap { existingJob ->
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
            var savedStat: String? = null
            if (duplicate != null) {
                // An older app may have cached an adjusted JPEG without its gain map.
                if (jpegOptions != null) verifyJpeg(part)
                val (photo, source) = duplicate
                saved = photo
                outputDigest = source.outputDigest ?: digest
                outputSize = source.outputSize ?: item.photo.size
                // 复用媒体刚通过 validContent 复检且已发布：采集当前指纹，避免沿用空或过期的来源指纹。
                savedStat = publishedFingerprint(photo.uri, outputSize)
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
                val pending = media.createPending(targetName, job.destination.relativePath(capture),
                    if (item.photo.raw) "image/x-sony-arw" else "image/jpeg", "${job.id}:$index")
                // 先登记系统 URI（WAL 行级锚，短行 fsync）：写入或发布途中退出时按原记录恢复，不再创建第二张。
                appendWalAnchor(job.replacing(index, item.copy(prepared = pending, digest = digest, outputDigest = outputDigest,
                    outputSize = outputSize, captureDay = capture?.day)), JSONObject().put("i", index).put("prepared", pending.json())
                    .put("digest", digest).put("outputDigest", outputDigest).put("outputSize", outputSize)
                    .put("captureDay", capture?.day))
                media.write(pending.uri, outputPart)
                // 写入字节与 outputPart 同源、摘要已知（outputDigest）：stat 元数据已定稿则以指纹 size 复核，
                // 未定稿（IS_PENDING=1 时 MediaProvider 不给 SIZE/DATE_MODIFIED）信任 ContentResolver 写入
                // （copyTo+fd.sync，截断即抛错）；发布后的 publishedFingerprint 仍按 size 复核兜底。
                val pendingStat = mediaStat(pending.uri)
                if (pendingStat != null && pendingStat.size != outputSize) throw IOException("Stored camera photo differs")
                media.remember(pending.uri, outputSize, outputDigest)
                saved = media.publish(pending.uri)
                // MediaProvider 到 publish（IS_PENDING=0）才扫描定稿 SIZE/DATE_MODIFIED，指纹只能在发布后采集；
                // 元数据 size 与预期校验大小不符即弃用，下次加载回落整文件摘要。
                savedStat = publishedFingerprint(pending.uri, outputSize)
            }
            val updated = job.replacing(index, item.copy(saved = saved, prepared = null, digest = digest,
                outputDigest = outputDigest, outputSize = outputSize, captureDay = capture?.day,
                duplicate = duplicate != null, problem = null, error = null, skipped = false, savedStat = savedStat))
            val complete = updated.savedCount == updated.items.size
            val result = migrateLegacyBoundary(updated.copy(status = if (complete) CameraJobStatus.COMPLETE else CameraJobStatus.ACTIVE,
                committed = job.committed || complete))
            // 稳态每张终态只追加一行短 WAL；整份快照只在任务完成点重写（任务结束合并一次），
            // 暂停/暂停恢复等状态迁移仍由调用方 store.save 落快照并截断 WAL。
            if (complete) save(result)
            else appendWalAnchor(result, itemJson(result.items[index]).put("i", index))
            part.delete()
            if (outputPart != part) outputPart.delete()
            result
        }
    }

    /** 三段抽样只用于跳过无线重复下载；候选校验走 savedStat 指纹快路径（recoverJob 同惯例），
     * 指纹缺失或变化才回落本地完整 SHA-256。 */
    fun copySampledOriginal(job: CameraImportJob, photo: CameraPhoto, output: FileOutputStream,
        permit: CameraTransferPermit, readRange: (Long, Int) -> ByteArray?): String? {
        val chunk = 64 shl 10
        if (photo.size < chunk * 3L || photo.captureDateMillis == null ||
            job.jpegOptions(CameraImportItem(photo)) != null) return null
        val candidates = ledgerJobs().filter { it.matchesCamera(job.cameraId, job.hardwareIdentity) }
            .flatMap { previous -> previous.items.filter { item ->
                item.saved != null && validDigest(item.digest) && previous.jpegOptions(item) == null &&
                    item.photo.matchesResumeMetadata(photo) && (item.outputSize ?: item.photo.size) == photo.size &&
                    (item.outputDigest ?: item.digest) == item.digest
            } }
            .filter { item ->
                val saved = checkNotNull(item.saved)
                // savedStat 指纹命中即复用候选（recoverJob 同惯例），只有指纹缺失/变化才整算候选内容。
                runCatching { media.inspect(saved.uri)?.pending == false &&
                    (fingerprintVerified(saved.uri, photo.size, item.digest, item.savedStat) ||
                        validContent(saved.uri, photo.size, item.digest)) }.getOrDefault(false)
            }
        // 同一稳定身份有不同内容时无法证明该复用哪份，必须重新下载。
        if (candidates.map { it.digest }.distinct().size != 1) return null
        val source = candidates.last()
        val uri = checkNotNull(source.saved).uri
        for (offset in listOf(0L, (photo.size - chunk) / 2, photo.size - chunk)) {
            permit.check()
            val remote = readRange(offset, chunk) ?: return null
            if (remote.size != chunk) return null
            val local = ByteArray(chunk)
            media.open(uri).use { input ->
                var remaining = offset
                while (remaining > 0) {
                    permit.check()
                    val skipped = input.skip(remaining)
                    if (skipped > 0) remaining -= skipped
                    else if (input.read() < 0) return null else remaining--
                }
                java.io.DataInputStream(input).readFully(local)
            }
            if (!remote.contentEquals(local)) return null
        }
        media.open(uri).use { input ->
            val buffer = ByteArray(64 shl 10)
            while (true) {
                permit.check()
                val count = input.read(buffer)
                if (count < 0) break
                output.write(buffer, 0, count)
            }
        }
        return source.digest
    }

    fun savedUris(job: CameraImportJob): List<String> {
        val items = job.items.toMutableList()
        val uris = job.items.mapIndexedNotNull { index, item ->
            item.saved?.let { saved ->
                val current = media.inspect(saved.uri) ?: throw IOException("Camera original is unavailable")
                if (current.pending) throw IOException("Camera original is not published")
                if (!validContent(current.uri, item.outputSize ?: item.photo.size, item.outputDigest ?: item.digest)) {
                    // 强校验抓到同指纹改写（stat 抓不到的篡改）：清掉该条指纹并落盘，
                    // 下一次 load 走整文件校验，条目得以自愈翻转为 CHANGED（openSaved 的刷新依赖此语义）。
                    items[index] = item.copy(savedStat = null)
                    save(job.copy(items = items.toList()))
                    throw CameraLocalSourceChanged()
                }
                current.uri
            }
        }
        return uris.distinct()
    }

    @Synchronized fun save(job: CameraImportJob) {
        require(validId(job.id))
        val items = JSONArray()
        job.items.forEach { items.put(itemJson(it)) }
        val next = nextWalSeq(job.id)
        val json = JSONObject().put("version", 2).put("seq", next).put("camera", job.cameraId).put("time", job.createdAt)
            .put("status", job.status.name).put("items", items).put("directory", job.destination.directory)
            .put("grouping", job.destination.grouping.name).put("incremental", job.incremental?.json())
            .put("jpeg", job.jpeg?.json())
            .put("committed", job.committed).put("listingOwner", job.listingOwner)
        job.hardwareIdentity?.let { json.put("hardwareIdentity", JSONObject().put("model", it.model).put("serial", it.serial)) }
        val part = File(directory, "${job.id}.tmp")
        val target = File(directory, "${job.id}.json")
        try {
            FileOutputStream(part).use { it.write(json.toString().toByteArray()); it.fd.sync() }
            replaceFileAtomically(part, target)
        } finally { part.delete() }
        journalRewrites++
        journals[job.id] = job
        sequences[job.id] = next
        // 快照携带写序号后截断 WAL；快照落盘与截断之间崩溃时，旧锚行 seq 必小于快照 seq，重放按序跳过而非覆盖。
        walFile(job.id).delete()
    }

    /** 追加单行锚到 `<id>.wal` 并对短行 fsync，同步刷新内存账本。崩溃留下的半行在重放处丢弃，其 pending 媒体由 cleanupOrphans 回收。 */
    @Synchronized private fun appendWalAnchor(job: CameraImportJob, line: JSONObject) {
        require(validId(job.id))
        val next = nextWalSeq(job.id)
        line.put("seq", next)
        FileOutputStream(walFile(job.id), true).use {
            it.write(line.toString().toByteArray())
            it.write('\n'.code)
            it.fd.sync()
        }
        walAppends++
        sequences[job.id] = next
        journals[job.id] = job
    }

    /** 把 `<id>.wal` 中晚于快照序号的行级锚折叠进快照；首个坏行/半行即停（append-only 尾部语义）。
     *  快照落盘与 WAL 截断之间崩溃留下的旧行（seq ≤ 快照 seq）被跳过，不会把旧条目盖回新快照。
     *  读异常与超预算抛出，由 readJobs 的单文件 try 复用坏日志隔离，不能静默当空 WAL
     *  （否则只登记在锚日志里的 pending 媒体会被 cleanupOrphans 误删）。 */
    private fun replayWal(job: CameraImportJob, journal: File): CameraImportJob {
        val wal = File(journal.parentFile, "${job.id}.wal")
        if (!wal.isFile) return job.also { sequences[job.id] = maxOf(sequences[job.id] ?: 0L,
            runCatching { JSONObject(journal.readText()).optLong("seq", 0L) }.getOrDefault(0L)) }
        if (wal.length() > maxWalBytes) throw IOException("Camera journal anchor log too large")
        val items = job.items.toMutableList()
        var seq = runCatching { JSONObject(journal.readText()).optLong("seq", 0L) }.getOrDefault(0L)
        var applied = seq
        for (line in wal.readLines()) {
            val record = runCatching { JSONObject(line) }.getOrNull() ?: break
            val lineSeq = record.optLong("seq", 0L)
            if (lineSeq <= seq) continue
            val index = record.optInt("i", -1)
            if (index !in items.indices) break
            val folded = runCatching {
                if (record.has("saved")) itemFromJson(record)
                else items[index].copy(prepared = record.getJSONObject("prepared").mediaPhoto(),
                    digest = record.optString("digest").takeIf { it.isNotEmpty() },
                    outputDigest = record.optString("outputDigest").takeIf { it.isNotEmpty() },
                    outputSize = record.optLongOrNull("outputSize"),
                    captureDay = record.optString("captureDay").takeIf { it.isNotEmpty() })
            }
            if (folded.isFailure) break
            items[index] = folded.getOrThrow()
            applied = lineSeq
        }
        sequences[job.id] = maxOf(sequences[job.id] ?: 0L, applied)
        return job.copy(items = items)
    }

    /** 逐个解析；单个日志读不出时跳过并记下，不影响其它任务。 */
    private fun readJobs(unreadable: MutableSet<String>? = null): List<CameraImportJob> {
        directoryScans++
        return directory.listFiles().orEmpty()
        .filter { it.isFile && it.extension == "json" && validId(it.nameWithoutExtension) }
        .mapNotNull { file ->
            try { replayWal(readJob(file), file) }
            catch (_: Exception) { unreadable?.add(file.nameWithoutExtension); null }
        }.sortedByDescending { it.createdAt }
    }

    private fun readJob(file: File): CameraImportJob {
        if (file.length() > 8L * 1024 * 1024) throw IOException("Camera journal exceeds budget")
        val json = JSONObject(file.readText())
        if (json.getInt("version") != 2) throw IOException("Unsupported camera journal")
        val array = json.getJSONArray("items")
        if (array.length() !in 1..10000) throw IOException("Invalid camera journal items")
        val items = (0 until array.length()).map { itemFromJson(array.getJSONObject(it)) }
        val hardware = json.optJSONObject("hardwareIdentity")?.let {
            CameraHardwareIdentity(it.getString("model"), it.getString("serial"))
        }
        return CameraImportJob(file.nameWithoutExtension, json.getString("camera"), json.getLong("time"), items,
            CameraJobStatus.valueOf(json.getString("status")), CameraImportDestination(json.getString("directory"),
                CameraDirectoryGrouping.valueOf(json.getString("grouping"))), json.optJSONObject("incremental")?.incrementalPlan(),
            json.optBoolean("committed", json.getString("status") == CameraJobStatus.COMPLETE.name), hardware,
            json.optString("listingOwner").takeIf { it.isNotEmpty() },
            jpeg = json.optJSONObject("jpeg")?.jpegOptions())
    }

    private fun itemFromJson(item: JSONObject): CameraImportItem {
        val created = item.getLong("created")
        val photo = CameraPhoto(item.getString("key"), item.getString("name"), item.getLong("size"), created,
            resumeIdentity = item.optString("resumeIdentity").takeIf { it.isNotEmpty() },
            storageToken = item.optString("storage").takeIf { it.isNotEmpty() },
            captureTimestamp = item.optLong("captureTimestamp", created))
        if (photo.size !in 1..SystemPhotoStore.MAX_BYTES) throw IOException("Invalid camera photo size")
        val saved = item.optJSONObject("saved")?.mediaPhoto()
        val prepared = item.optJSONObject("prepared")?.mediaPhoto()
        val digest = item.optString("digest").takeIf { it.isNotEmpty() }
        if ((digest != null || saved != null || prepared != null) && !validDigest(digest)) throw IOException("Invalid camera digest")
        val outputDigest = item.optString("outputDigest").takeIf { it.isNotEmpty() }
        val outputSize = item.optLongOrNull("outputSize")
        if (outputDigest != null && !validDigest(outputDigest)) throw IOException("Invalid camera output digest")
        if (outputDigest != null && outputSize !in 1..SystemPhotoStore.MAX_BYTES) throw IOException("Invalid camera output size")
        return CameraImportItem(photo, saved, prepared, digest, item.optString("captureDay").takeIf { it.isNotEmpty() }, item.optBoolean("duplicate"),
            item.optJSONObject("unavailable")?.mediaPhoto(), item.optString("problem").takeIf { it.isNotEmpty() }?.let(CameraMediaProblem::valueOf),
            outputDigest, outputSize, saveOriginalJpeg = item.optBoolean("saveOriginalJpeg"),
            savedStat = item.optString("savedStat").takeIf { it.isNotEmpty() })
    }

    private fun itemJson(item: CameraImportItem) = JSONObject().put("key", item.photo.key).put("name", item.photo.name)
        .put("size", item.photo.size).put("created", item.photo.created).put("storage", item.photo.storageToken)
        .put("captureTimestamp", item.photo.captureTimestamp.takeIf { it != item.photo.created })
        .put("resumeIdentity", item.photo.resumeIdentity)
        .put("saved", item.saved?.json())
        .put("prepared", item.prepared?.json()).put("digest", item.digest).put("captureDay", item.captureDay)
        .put("duplicate", item.duplicate).put("unavailable", item.unavailable?.json()).put("problem", item.problem?.name)
        .put("saveOriginalJpeg", item.saveOriginalJpeg.takeIf { it })
        .put("outputDigest", item.outputDigest).put("outputSize", item.outputSize).put("savedStat", item.savedStat)

    private fun validContent(uri: String, size: Long, digest: String?): Boolean = runCatching {
        validDigest(digest) && media.open(uri).use { contentDigest(it, size) } == digest
    }.getOrDefault(false)

    /** 媒体库元数据 stat（size/mtime 均有效才可用）；MediaStore 未定稿或给不出元数据时为 null，调用方回落内容摘要。 */
    private fun mediaStat(uri: String): MediaPhotoStat? = runCatching {
        media.stat(uri)?.takeIf { it.size > 0 && it.modifiedAt > 0 }
    }.getOrNull()

    /** 已发布（IS_PENDING=0）媒体的当前指纹；size 与预期校验大小不符即不可信，返回 null 回落整文件摘要。 */
    private fun publishedFingerprint(uri: String, expectedSize: Long): String? =
        mediaStat(uri)?.takeIf { it.size == expectedSize }?.fingerprint()

    /** recoverJob 的 stat 指纹快路径惯例：指纹与记录一致、指纹 size 等于预期校验 size 且摘要有效才放行（并登记摘要）。 */
    private fun fingerprintVerified(uri: String, expectedSize: Long, expectedDigest: String?, savedStat: String?): Boolean {
        val digest = expectedDigest?.takeIf(::validDigest) ?: return false
        if (savedStat == null) return false
        val stat = mediaStat(uri) ?: return false
        if (stat.size != expectedSize || stat.fingerprint() != savedStat) return false
        media.remember(uri, expectedSize, digest)
        return true
    }

    /** 整文件摘要账目（测试观察钩子）：`contentDigest` 真实计算入口计数；指纹快路径命中不增加，撤掉复用必红。 */
    @Volatile
    internal var contentDigestCount = 0
        private set

    private fun contentDigest(input: InputStream, expected: Long, check: () -> Unit = {}): String {
        contentDigestCount++
        val digest = MessageDigest.getInstance("SHA-256")
        val bytes = ByteArray(64 * 1024); var count = 0L
        while (true) {
            check()
            val read = input.read(bytes); if (read < 0) break
            count += read
            if (count > expected) throw CameraPhotoImportException("Camera original size changed")
            digest.update(bytes, 0, read)
        }
        if (count != expected) throw CameraPhotoImportException("Camera original size changed")
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
            file.toByteArray().size > 240) throw CameraPhotoImportException("Invalid camera filename")
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
    private fun JSONObject.jpegOptions(): CameraJPEGOptions = CameraJPEGOptions(
        optBoolean("adjust"),
        optInt("longEdge").takeIf { has("longEdge") && !isNull("longEdge") },
        optInt("quality", 90),
    )
    private fun JSONObject.incrementalPlan(): CameraIncrementalPlan {
        val format = CameraImportFormat.valueOf(getString("format"))
        val jpeg = optJSONObject("jpeg")?.jpegOptions() ?: CameraJPEGOptions()
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
