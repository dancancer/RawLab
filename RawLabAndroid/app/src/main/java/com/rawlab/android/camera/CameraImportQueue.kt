package com.rawlab.android.camera

import com.rawlab.android.camera.protocol.CameraMediaSession
import com.rawlab.android.camera.protocol.SonyMobileSession
import java.io.FileOutputStream
import java.io.IOException

internal data class CameraPhotoListing(
    val assets: List<SonyMobileSession.Asset>,
    val limitExceeded: Boolean = false,
)

internal fun sortedCameraPhotos(found: Collection<SonyMobileSession.Asset>): List<CameraPhoto> =
    found.map { it.photo() }
        .sortedWith(compareByDescending<CameraPhoto> { it.created }.thenByDescending { it.name })

internal fun listCameraPhotosBounded(
    session: CameraMediaSession,
    info: SonyMobileSession.Device,
): CameraPhotoListing {
    val (rawAssets, exceeded) = try {
        val listed = session.listPhotos(info)
        listed to (listed.size > CameraMediaSession.MAX_LISTED_PHOTOS)
    } catch (limit: CameraMediaSession.PhotoLimitExceededException) {
        limit.recentAssets to true
    }
    if (!exceeded || rawAssets.size <= CameraMediaSession.MAX_LISTED_PHOTOS) {
        return CameraPhotoListing(rawAssets, exceeded)
    }
    val bounded = rawAssets.sortedWith(
        compareByDescending<SonyMobileSession.Asset> { it.created }.thenByDescending { it.name }
    ).take(CameraMediaSession.MAX_LISTED_PHOTOS)
    return CameraPhotoListing(bounded, limitExceeded = true)
}

internal data class ConnectedCameraImport(
    val session: CameraMediaSession,
    val device: SonyMobileSession.Device,
    val listing: CameraPhotoListing,
)

internal suspend fun openCameraImportSession(
    createMobile: () -> CameraMediaSession,
    createLegacy: () -> CameraMediaSession,
    onOpened: suspend (CameraMediaSession) -> Unit = {},
): ConnectedCameraImport {
    var opened = createMobile()
    try {
        onOpened(opened)
        var info = opened.deviceInfo()
        if (!info.operations.containsAll(listOf(0x923c, 0x923d))) {
            if (!info.operations.containsAll(listOf(0x1002, 0x9201, 0x9202, 0x9209, 0x9212, 0x1004, 0x1007, 0x1008, 0x1009)))
                throw CameraMediaSession.UnsupportedCameraException("Photo import is unavailable in this camera mode")
            opened.close()
            opened = createLegacy()
            onOpened(opened)
            info = opened.deviceInfo()
        }
        opened.openSession()
        val listing = listCameraPhotosBounded(opened, info)
        return ConnectedCameraImport(opened, info, listing)
    } catch (error: Exception) {
        opened.close()
        throw error
    }
}

internal data class CameraSessionQueueResult(
    val job: CameraImportJob,
    val listedAssets: Map<String, SonyMobileSession.Asset>,
    val photoLimitExceeded: Boolean,
    val verifiedImports: Map<String, CameraVerifiedImport>,
    val failure: Throwable? = null,
) {
    val sourceChanged: Boolean get() = failure is CameraImportSourceChanged ||
        failure is CameraMediaSession.PhotoTransferException && failure.kind == CameraMediaSession.FailureKind.SOURCE_CHANGED
    val shouldDisconnect: Boolean get() = failure != null && !sourceChanged
}

internal suspend fun executeCameraSessionQueue(
    store: CameraImportStore,
    opened: CameraMediaSession,
    info: SonyMobileSession.Device,
    initialJob: CameraImportJob,
    listedAssets: Map<String, SonyMobileSession.Asset>,
    incrementalOwner: String,
    allowed: CameraTransferPermit,
    resuming: Boolean = false,
    keepJpegOriginals: Boolean = false,
    onListed: suspend (Map<String, SonyMobileSession.Asset>, Boolean) -> Unit = { _, _ -> },
    onProgress: (String, Long) -> Unit = { _, _ -> },
    onJob: (CameraImportJob) -> Unit = {},
): CameraSessionQueueResult {
    var latest = initialJob
    var currentAssets = listedAssets
    var limitExceeded = false
    var verified = emptyMap<String, CameraVerifiedImport>()
    val outcome = runCatching {
        allowed.check()
        if (resuming) {
            val skippedKeys = initialJob.items.filter { it.skipped }.map { it.photo.key }.toSet()
            val recovered = store.recover(initialJob.id) ?: throw IOException("Camera import task is missing")
            latest = if (skippedKeys.isEmpty()) recovered else recovered.copy(items = recovered.items.map { item ->
                if (item.saved == null && item.photo.key in skippedKeys) item.copy(skipped = true) else item
            })
            onJob(latest)
        }
        if (latest.status == CameraJobStatus.COMPLETE) return@runCatching
        if (latest.items.any { it.problem?.needsOriginalJpeg == true }) {
            if (!keepJpegOriginals) return@runCatching
            latest = latest.keepingPendingJpegOriginals()
            store.save(latest)
            onJob(latest)
        }
        val fresh = if (resuming) {
            val listing = listCameraPhotosBounded(opened, info)
            limitExceeded = listing.limitExceeded
            val current = listing.assets.associateBy { it.key() }
            onListed(current, limitExceeded)
            currentAssets = current
            current
        } else listedAssets
        val observed = fresh.mapValues { it.value.photo() }
        val matches = resumeLocatorMap(latest, observed.values.toList(), incrementalOwner)
        val sameListing = latest.originalListingOwner == incrementalOwner
        if ((!sameListing || latest.incremental == null) &&
            latest.items.any { it.saved == null && !it.skipped && it.photo.key !in matches }) throw CameraImportSourceChanged()
        val pendingKeys = latest.items.filter { it.saved == null && !it.skipped }.map { it.photo.key }.toSet()
        val reconciled = latest.items.map { item ->
            when {
                item.saved != null || item.skipped -> item
                item.photo.key !in matches -> item.copy(problem = CameraMediaProblem.REMOTE_MISSING)
                item.problem == CameraMediaProblem.REMOTE_MISSING -> item.copy(problem = null)
                else -> item
            }
        }
        if (reconciled != latest.items) {
            latest = latest.copy(items = reconciled, status = CameraJobStatus.PAUSED)
            store.save(latest)
            onJob(latest)
        }
        latest = receiveCameraJob(store, latest, allowed, { photo, output ->
            val asset = fresh.getValue(matches.getValue(photo.key).key)
            onProgress(photo.key, 0)
            val reused = try {
                store.copySampledOriginal(latest, photo, output, allowed) { offset, length ->
                    opened.readRange(info, asset, offset, length)
                }
            } catch (error: IOException) {
                allowed.check()
                if (!opened.isOpen || error is CameraMediaSession.PhotoTransferException &&
                    error.kind in setOf(CameraMediaSession.FailureKind.SESSION, CameraMediaSession.FailureKind.SOURCE_CHANGED)) throw error
                null
            }
            reused ?: run {
                // 本地候选读取中途失败也可回落，不能把候选的半份内容混到相机原件前面。
                output.channel.truncate(0); output.channel.position(0)
                opened.download(info, asset, output) { bytes, _ ->
                    allowed.check(); onProgress(photo.key, bytes)
                }
            }
        }, onJob, isSessionAlive = opened::isOpen)
        verified = latest.items.filter { it.saved != null && it.photo.key in pendingKeys }
            .map { CameraVerifiedImport(matches.getValue(it.photo.key), checkNotNull(it.digest), latest.id) }
            .associateBy { it.photo.key }
    }
    if (outcome.isFailure) {
        val inMemoryByKey = latest.items.associateBy { it.photo.key }
        latest = latest.copy(status = CameraJobStatus.PAUSED)
        // 发布中失败可能已经写入 prepared；从持久清单恢复，不能用旧快照覆盖它。
        runCatching { store.load().firstOrNull { it.id == initialJob.id } }.getOrNull()?.let { reloaded ->
            latest = reloaded.copy(items = reloaded.items.map { item ->
                val previous = inMemoryByKey[item.photo.key]
                if (item.saved == null && previous != null) item.copy(error = previous.error, skipped = previous.skipped) else item
            })
        }
    }
    return CameraSessionQueueResult(latest, currentAssets, limitExceeded, verified, outcome.exceptionOrNull())
}

internal fun skipFailedCameraItems(store: CameraImportStore, job: CameraImportJob): CameraImportJob {
    if (job.status == CameraJobStatus.COMPLETE || job.items.none { it.canSkip }) return job
    val skippedItems = job.items.map { item -> if (item.canSkip) item.copy(skipped = true) else item }
    val allSettled = skippedItems.all { it.saved != null || it.skipped }
    val base = job.copy(items = skippedItems, status = CameraJobStatus.PAUSED)
    val updated = if (allSettled) base.withSafeIncrementalCheckpoints().copy(committed = true) else base
    store.save(updated)
    return updated
}

internal fun isPerPhotoImportFailure(error: IOException, isSessionAlive: () -> Boolean): Boolean = when (error) {
    is CameraMediaSession.PhotoTransferException -> error.kind == CameraMediaSession.FailureKind.ITEM && isSessionAlive()
    is CameraPhotoImportException -> isSessionAlive()
    else -> false
}

/** 调用方持有存储锁；两种相机入口共用同一下载、校验和发布顺序。 */
internal fun receiveCameraJob(store: CameraImportStore, job: CameraImportJob, permit: CameraTransferPermit,
    download: (CameraPhoto, FileOutputStream) -> String, onJob: (CameraImportJob) -> Unit = {},
    continueOnPhotoError: Boolean = true, isSessionAlive: () -> Boolean = { true }): CameraImportJob {
    if (job.status == CameraJobStatus.COMPLETE) return job
    permit.check()
    var latest = job.copy(status = CameraJobStatus.ACTIVE)
    store.save(latest)
    for (index in latest.items.indices) {
        val item = latest.items[index]
        if (item.saved != null || item.skipped || item.problem == CameraMediaProblem.REMOTE_MISSING) continue
        permit.check()
        val part = store.partial(job.id)
        try {
            var downloadedDigest: String? = null
            try {
                val digest = FileOutputStream(part).use { output ->
                    val result = download(item.photo, output)
                    output.fd.sync()
                    result
                }
                downloadedDigest = digest
                permit.check()
                latest = store.publish(latest, index, part, digest, permit)
                onJob(latest)
            } catch (error: IOException) {
                permit.check()
                if (error is CameraJPEGGainMapAdjustmentException || error is CameraJPEGMemoryException) {
                    val problem = if (error is CameraJPEGGainMapAdjustmentException) CameraMediaProblem.HDR_GAIN_MAP
                    else CameraMediaProblem.JPEG_MEMORY
                    val items = latest.items.toMutableList()
                    items[index] = item.copy(digest = downloadedDigest, problem = problem, error = null)
                    return latest.copy(items = items, status = CameraJobStatus.PAUSED).also(store::save)
                }
                if (continueOnPhotoError && isPerPhotoImportFailure(error, isSessionAlive)) {
                    val items = latest.items.toMutableList()
                    items[index] = item.copy(error = error.message ?: error.javaClass.simpleName)
                    latest = latest.copy(items = items)
                    store.save(latest)
                    onJob(latest)
                    continue
                }
                throw error
            }
        } finally { part.delete() }
    }
    val finished = latest.items.all { it.saved != null }
    val settledWithSkips = !finished && latest.items.any { it.skipped } && latest.items.all { it.saved != null || it.skipped }
    val base = if (settledWithSkips) latest.withSafeIncrementalCheckpoints() else latest
    val result = base.copy(status = if (finished) CameraJobStatus.COMPLETE else CameraJobStatus.PAUSED,
        committed = base.committed || finished || settledWithSkips)
    if (result != latest) store.save(result)
    return result
}
