package com.rawlab.android.camera

import java.time.Instant
import java.time.ZoneId

internal enum class CameraImportFormat {
    RAW, JPEG, RAW_AND_JPEG;

    val kinds: List<CameraImportFormat>
        get() = if (this == RAW_AND_JPEG) listOf(RAW, JPEG) else listOf(this)

    fun includes(photo: CameraPhoto): Boolean = this == RAW_AND_JPEG || this == kindOf(photo)

    companion object {
        fun kindOf(photo: CameraPhoto): CameraImportFormat = if (photo.raw) RAW else JPEG
    }
}

internal data class CameraJPEGOptions(
    val adjust: Boolean = false,
    val longEdge: Int? = null,
    val quality: Int = 90,
) {
    val isValid: Boolean
        get() = quality in 1..100 && (longEdge == null || longEdge in 1..65_535)
}

internal data class CameraImportBoundary(
    val dateMillis: Long,
    val storage: Set<String>,
    val keys: Set<String>,
    val anchors: Set<String>,
    val owner: String,
) {
    companion object {
        fun latest(photos: List<CameraPhoto>, storage: Set<String>, owner: String): CameraImportBoundary? {
            val date = photos.mapNotNull { it.captureDateMillis }.maxOrNull() ?: return null
            val tail = photos.filter { it.captureDateMillis == date }
            return CameraImportBoundary(date, storage, tail.map { it.key }.toSet(), tail.map { it.anchorKey }.toSet(), owner)
        }
    }
}

internal data class CameraIncrementalPlan(
    val format: CameraImportFormat,
    val jpeg: CameraJPEGOptions = CameraJPEGOptions(),
    /** Older journals recorded one boundary for both formats. */
    val boundary: CameraImportBoundary? = null,
    val customCutoffMillis: Long? = null,
    val includeUndated: Boolean = false,
    val sessionOwner: String? = null,
    val checkpoints: Map<CameraImportFormat, CameraImportBoundary> = emptyMap(),
) {
    init { require(jpeg.isValid) { "Invalid incremental JPEG options" } }
}

internal class CameraIncrementalScan(
    listing: List<CameraPhoto>,
    checkpoints: Map<CameraImportFormat, CameraImportBoundary>,
    cutoff: Long,
    customCutoff: Long?,
    format: CameraImportFormat,
    includeUndated: Boolean,
    savedKeys: Set<String> = emptySet(),
    sessionOwner: String,
) {
    val assets: List<CameraPhoto>
    val undatedCount: Int
    val startMillis: Long
    val needsCutoffConfirmation: Boolean
    val nextCheckpoints: Map<CameraImportFormat, CameraImportBoundary>

    init {
        require(listing.size <= MAXIMUM_ASSETS) { "Photo list exceeds limit" }
        val storage = listing.map { it.storageToken ?: "unknown" }.toSet()
        val dated = listing.mapNotNull { photo -> photo.captureDateMillis?.let { photo to it } }
        val confirmed = checkpoints.filter { (kind, checkpoint) ->
            // Slot and file metadata cannot prove the card stayed the same across connections.
            checkpoint.owner == sessionOwner && checkpoint.storage == storage && dated.any { (photo, date) ->
                CameraImportFormat.kindOf(photo) == kind && date == checkpoint.dateMillis && photo.anchorKey in checkpoint.anchors
            }
        }
        val starts = format.kinds.associateWith { customCutoff ?: confirmed[it]?.dateMillis ?: cutoff }
        startMillis = starts.values.min()
        needsCutoffConfirmation = customCutoff == null && format.kinds.any { it in checkpoints && it !in confirmed }
        val undated = listing.filter { format.includes(it) && it.captureDateMillis == null && it.key !in savedKeys }
        undatedCount = undated.size
        if (needsCutoffConfirmation) {
            assets = emptyList()
            nextCheckpoints = emptyMap()
        } else {
            val eligible = dated.filter { (photo, date) ->
                val kind = CameraImportFormat.kindOf(photo)
                val start = starts[kind] ?: return@filter false
                if (date < start || photo.key in savedKeys) return@filter false
                val checkpoint = confirmed[kind]
                customCutoff != null || checkpoint == null || date != checkpoint.dateMillis ||
                    photo.key !in checkpoint.keys
            }.sortedWith(compareBy<Pair<CameraPhoto, Long>> { it.second }.thenBy { it.first.key }).map { it.first }
            assets = eligible + if (includeUndated) undated else emptyList()
            nextCheckpoints = buildMap {
                eligible.groupBy { CameraImportFormat.kindOf(it) }.forEach { (kind, photos) ->
                    if (customCutoff == null || kind !in confirmed) {
                        CameraImportBoundary.latest(photos, storage, sessionOwner)?.let { put(kind, it) }
                    }
                }
            }
        }
    }

    companion object {
        const val MAXIMUM_ASSETS = 10_000

        fun defaultCutoffMillis(
            nowMillis: Long = System.currentTimeMillis(),
            zone: ZoneId = ZoneId.systemDefault(),
            wallClockZone: ZoneId = zone,
        ): Long = Instant.ofEpochMilli(nowMillis).atZone(zone).toLocalDate()
            .atStartOfDay(wallClockZone).toInstant().toEpochMilli()

        fun day(epochMillis: Long): String = Instant.ofEpochMilli(epochMillis)
            .atZone(ZoneId.of("UTC")).toLocalDate().toString()
    }
}

/** A remapped locator is only a download candidate. The store checks its bytes before publishing. */
internal fun resumeLocatorMap(job: CameraImportJob, current: List<CameraPhoto>, sessionOwner: String?): Map<String, CameraPhoto> {
    val sameSession = sessionOwner != null && job.originalListingOwner == sessionOwner
    val identity: (CameraPhoto) -> String = if (sameSession) CameraPhoto::key else CameraPhoto::resumeMetadataKey
    val stored = job.items.groupBy { identity(it.photo) }
    val listed = current.groupBy(identity)
    return buildMap {
        for ((key, items) in stored) {
            val photo = listed[key]?.singleOrNull() ?: continue
            val item = items.singleOrNull() ?: continue
            if (sameSession) {
                if (!item.photo.matchesSnapshot(photo)) continue
            } else {
                if (!item.photo.matchesResumeMetadata(photo)) continue
                // 尚无摘要的队尾只用完整的稳定元数据定位；旧日志缺字段时仍需来源凭据。
                if (item.digest == null && (item.photo.storageToken == null || item.photo.captureDateMillis == null)) continue
            }
            put(item.photo.key, photo)
        }
    }
}

internal val CameraPhoto.resumeMetadataKey: String get() = "$name:$size:$created"

internal fun CameraPhoto.matchesResumeMetadata(observed: CameraPhoto): Boolean =
    resumeMetadataKey == observed.resumeMetadataKey &&
        (storageToken == null || storageToken == observed.storageToken && captureTimestamp == observed.captureTimestamp) &&
        (legacyMetadataWithoutHandle == null || legacyMetadataWithoutHandle == observed.legacyMetadataWithoutHandle)

private val CameraPhoto.legacyMetadataWithoutHandle: String?
    get() {
        // Legacy resume identity is legacy:storage:handle:format:size:name:created:modified.
        val parts = resumeIdentity?.split(':', limit = 4) ?: return null
        return if (parts.size == 4 && parts[0] == "legacy") "${parts[1]}:${parts[3]}" else null
    }

/** The newest committed plan that advanced each format supplies its checkpoint. */
internal fun committedIncrementalCheckpoints(jobs: List<CameraImportJob>): Map<CameraImportFormat, CameraImportBoundary> = buildMap {
    jobs.filter { it.committed }.sortedByDescending { it.createdAt }.forEach { job ->
        job.incremental?.checkpoints?.forEach { (kind, checkpoint) -> putIfAbsent(kind, checkpoint) }
    }
}
