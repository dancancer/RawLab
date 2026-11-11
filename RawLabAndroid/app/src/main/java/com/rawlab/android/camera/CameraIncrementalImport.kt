package com.rawlab.android.camera

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** Formats accepted by an incremental card import. */
internal enum class CameraImportFormat {
    RAW, JPEG, RAW_AND_JPEG;

    fun includes(photo: CameraPhoto): Boolean = when (this) {
        RAW -> photo.raw
        JPEG -> !photo.raw
        RAW_AND_JPEG -> true
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

/** The boundary is a candidate in an active task and becomes authoritative only when that task completes. */
internal data class CameraImportBoundary(
    val dateMillis: Long,
    val storage: Set<String>,
    val keys: Set<String>,
    val anchors: Set<String>,
    val owner: String,
) {
    val date: Long get() = dateMillis
}

internal data class CameraIncrementalPlan(
    val format: CameraImportFormat,
    val jpeg: CameraJPEGOptions = CameraJPEGOptions(),
    val boundary: CameraImportBoundary? = null,
    val customCutoffMillis: Long? = null,
    val includeUndated: Boolean = false,
    val sessionOwner: String? = null,
) {
    init { require(jpeg.isValid) { "Invalid incremental JPEG options" } }
}

/**
 * Computes the candidate list from one camera listing.  A boundary is deliberately
 * not mutated here: callers persist it with the task and only read it after the
 * task is complete.
 */
internal data class CameraIncrementalScan(
    val assets: List<CameraPhoto>,
    val undatedCount: Int,
    val startMillis: Long,
    val needsCutoffConfirmation: Boolean,
    val nextBoundary: CameraImportBoundary?,
) {
    val start: Long get() = startMillis

    constructor(
        assets: List<CameraPhoto>,
        boundary: CameraImportBoundary?,
        cutoff: Long,
        customCutoff: Long?,
        format: CameraImportFormat,
        includeUndated: Boolean,
        savedKeys: Set<String> = emptySet(),
        sessionOwner: String,
        storage: Set<String> = assets.mapNotNull { it.storageToken }.toSet().ifEmpty {
            if (assets.isEmpty()) emptySet() else setOf("unknown")
        },
    ) : this(
        compute(assets, boundary, cutoff, customCutoff, format, includeUndated, savedKeys, sessionOwner, storage),
    )

    private constructor(result: Result) : this(
        result.assets, result.undatedCount, result.startMillis,
        result.needsCutoffConfirmation, result.nextBoundary,
    )

    private data class Result(
        val assets: List<CameraPhoto>,
        val undatedCount: Int,
        val startMillis: Long,
        val needsCutoffConfirmation: Boolean,
        val nextBoundary: CameraImportBoundary?,
    )

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

        private fun compute(
            assets: List<CameraPhoto>, boundary: CameraImportBoundary?, cutoff: Long,
            customCutoff: Long?, format: CameraImportFormat, includeUndated: Boolean,
            savedKeys: Set<String>, sessionOwner: String, storage: Set<String>,
        ): Result {
            require(assets.size <= MAXIMUM_ASSETS) { "Photo list exceeds limit" }
            require(storage.isNotEmpty() || assets.isEmpty()) { "Camera storage identity is unavailable" }
            val dated = assets.mapNotNull { photo -> photo.captureDateMillis?.let { photo to it } }
            val confirmed = boundary?.takeIf { candidate ->
                candidate.storage == storage &&
                    dated.any { (photo, date) -> date == candidate.dateMillis && candidate.anchors.contains(photo.anchorKey) }
            }
            val start = customCutoff ?: confirmed?.dateMillis ?: cutoff
            val needsConfirmation = boundary != null && confirmed == null && customCutoff == null
            val undated = assets.filter {
                format.includes(it) && it.captureDateMillis == null && it.key !in savedKeys
            }
            if (needsConfirmation) return Result(emptyList(), undated.size, start, true, null)

            val inRange = dated.filter { (_, date) -> date >= start }
            val eligible = inRange.filter { (photo, date) ->
                if (!format.includes(photo) || photo.key in savedKeys) return@filter false
                // 跨会话边界同秒的对象按源文件摘要去重，会话内可直接复用文件编号。
                if (customCutoff == null && confirmed?.owner == sessionOwner && date == confirmed.dateMillis) {
                    photo.key !in confirmed.keys
                } else true
            }.sortedWith(compareBy<Pair<CameraPhoto, Long>> { it.second }.thenBy { it.first.key })
                .map { it.first }
            val selected = eligible + if (includeUndated) undated else emptyList()
            val next = if (selected.isNotEmpty() && (customCutoff == null || confirmed == null)) {
                val latest = inRange.maxOfOrNull { it.second }
                val tail = if (latest == null) emptyList() else inRange.filter { it.second == latest }.map { it.first }
                if (latest != null && tail.isNotEmpty()) CameraImportBoundary(
                    dateMillis = latest,
                    storage = storage,
                    keys = tail.map { it.key }.toSet(),
                    anchors = tail.map { it.anchorKey }.toSet(),
                    owner = sessionOwner,
                ) else null
            } else null
            return Result(selected, undated.size, start, false, next)
        }
    }
}
