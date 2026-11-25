package com.rawlab.android.editor.render

import com.rawlab.android.editor.canvas.DetailTileKey
import com.rawlab.android.editor.canvas.DetailTileSpec
import com.rawlab.android.editor.canvas.NormalizedRect
import com.rawlab.android.editor.canvas.ViewportTilePlanner

internal const val DEFAULT_DETAIL_TILE_MAX_BYTES = 64L * 1024L * 1024L
internal const val DEFAULT_DETAIL_TILE_MAX_COUNT = 24
internal const val DEFAULT_HDR_DETAIL_MAX_COUNT = 4

internal class ViewportTileCache(
    val byteBudget: Long = DEFAULT_DETAIL_TILE_MAX_BYTES,
    val maxCount: Int = DEFAULT_DETAIL_TILE_MAX_COUNT,
    val hdrMaxCount: Int = DEFAULT_HDR_DETAIL_MAX_COUNT,
) {
    private val tiles = HashMap<DetailTileKey, PreviewDetailOverlay>(32)
    private val lru = ArrayList<DetailTileKey>(32)
    private val hdrCache = ArrayList<PreviewDetailOverlay>(hdrMaxCount)

    var totalBytes: Long = 0L
        private set
    var sourceRevision: Long = -1L
        private set
    var editRevision: Long = -1L
        private set

    val count: Int
        get() = tiles.size

    fun peek(key: DetailTileKey): PreviewDetailOverlay? = tiles[key]

    fun syncRevision(sourceRev: Long, editRev: Long): Boolean {
        if (sourceRevision == sourceRev && editRevision == editRev) return false
        tiles.clear()
        lru.clear()
        totalBytes = 0L
        hdrCache.clear()
        sourceRevision = sourceRev
        editRevision = editRev
        return true
    }

    fun touch(orderedSpecs: List<DetailTileSpec>) {
        // 逆序访问以保证中心可见瓦片留在 LRU 尾部（最后被淘汰）。
        for (spec in orderedSpecs.asReversed()) {
            val key = spec.key
            if (tiles.containsKey(key)) {
                lru.remove(key)
                lru.add(key)
            }
        }
    }

    fun store(
        overlay: PreviewDetailOverlay,
        visibleKeys: Set<DetailTileKey>,
        desiredKeys: Set<DetailTileKey>,
    ): List<DetailTileKey> {
        syncRevision(overlay.sourceRevision, overlay.editRevision)
        val key = overlay.tileKey ?: return emptyList()
        tiles.remove(key)?.let { old ->
            totalBytes = (totalBytes - tileBytes(old)).coerceAtLeast(0L)
            lru.remove(key)
        }
        tiles[key] = overlay
        lru.add(key)
        totalBytes += tileBytes(overlay)

        val evicted = ArrayList<DetailTileKey>()
        while ((totalBytes > byteBudget || tiles.size > maxCount) && lru.isNotEmpty()) {
            val victimKey = lru.firstOrNull { it !in desiredKeys }
                ?: lru.firstOrNull { it !in visibleKeys }
                ?: break
            lru.remove(victimKey)
            val removed = tiles.remove(victimKey) ?: break
            totalBytes = (totalBytes - tileBytes(removed)).coerceAtLeast(0L)
            evicted += victimKey
        }
        return evicted
    }

    fun activeTiles(
        allSpecs: List<DetailTileSpec>,
        visibleSpecs: List<DetailTileSpec>,
    ): List<PreviewDetailOverlay> {
        if (tiles.isEmpty()) return emptyList()
        val selected = HashMap<DetailTileKey, PreviewDetailOverlay>(allSpecs.size)
        for (spec in allSpecs) {
            tiles[spec.key]?.let { selected[spec.key] = it }
        }
        val uncachedVisible = visibleSpecs.filter { it.key !in selected }
        if (uncachedVisible.isNotEmpty()) {
            val targetLevel = visibleSpecs.firstOrNull()?.key?.level ?: 0
            for ((key, tile) in tiles) {
                if (key.level > targetLevel && key !in selected) {
                    if (uncachedVisible.any { rectsIntersect(it.rect, tile.normalizedRect) }) {
                        selected[key] = tile
                    }
                }
            }
        }
        return sortedTiles(selected.values)
    }

    fun sortedCachedTiles(): List<PreviewDetailOverlay> = sortedTiles(tiles.values)

    fun storeHdr(overlay: PreviewDetailOverlay) {
        syncRevision(overlay.sourceRevision, overlay.editRevision)
        hdrCache.removeAll { it.normalizedRect == overlay.normalizedRect && it.pixelWidth == overlay.pixelWidth }
        hdrCache.add(overlay)
        while (hdrCache.size > hdrMaxCount) {
            hdrCache.removeAt(0)
        }
    }

    fun findHdrHit(
        sourceRev: Long,
        editRev: Long,
        visibleRect: NormalizedRect,
        zoomScale: Float,
        edgeLimit: Int,
        tilePlanner: ViewportTilePlanner,
    ): PreviewDetailOverlay? {
        val hitIdx = hdrCache.indexOfLast {
            it.sourceRevision == sourceRev &&
                it.editRevision == editRev &&
                tilePlanner.detailOverlayCovers(
                    it.normalizedRect,
                    it.pixelWidth,
                    it.pixelHeight,
                    it.fullNativeWidth,
                    it.fullNativeHeight,
                    visibleRect,
                    zoomScale,
                    edgeLimit,
                )
        }
        if (hitIdx < 0) return null
        val hit = hdrCache.removeAt(hitIdx)
        hdrCache.add(hit)
        return hit
    }

    fun hasHdrCoverage(
        sourceRev: Long,
        editRev: Long,
        visibleRect: NormalizedRect,
        zoomScale: Float,
        edgeLimit: Int,
        tilePlanner: ViewportTilePlanner,
    ): Boolean = hdrCache.any {
        it.sourceRevision == sourceRev &&
            it.editRevision == editRev &&
            tilePlanner.detailOverlayCovers(
                it.normalizedRect,
                it.pixelWidth,
                it.pixelHeight,
                it.fullNativeWidth,
                it.fullNativeHeight,
                visibleRect,
                zoomScale,
                edgeLimit,
            )
    }

    fun reclaimMemory() {
        tiles.clear()
        lru.clear()
        totalBytes = 0L
        hdrCache.clear()
        sourceRevision = -1L
        editRevision = -1L
    }

    companion object {
        fun tileBytes(overlay: PreviewDetailOverlay): Long {
            val single = overlay.pixelWidth.toLong().coerceAtLeast(1L) *
                overlay.pixelHeight.toLong().coerceAtLeast(1L) * 4L
            return if (overlay.neutral != null && overlay.neutral !== overlay.result) single * 2L else single
        }

        fun estimatedTileBytes(spec: DetailTileSpec, includeNeutral: Boolean): Long {
            val edge = spec.maxOutputLongEdge.toLong().coerceAtLeast(1L)
            val single = edge * edge * 4L
            return if (includeNeutral) single * 2L else single
        }

        fun sortedTiles(values: Collection<PreviewDetailOverlay>): List<PreviewDetailOverlay> =
            values.sortedWith(
                compareByDescending<PreviewDetailOverlay> { it.tileKey?.level ?: 0 }
                    .thenBy { it.tileKey?.row ?: 0 }
                    .thenBy { it.tileKey?.col ?: 0 },
            )

        private fun rectsIntersect(a: NormalizedRect, b: NormalizedRect): Boolean =
            a.x0 < b.x1 && a.x1 > b.x0 && a.y0 < b.y1 && a.y1 > b.y0
    }
}
