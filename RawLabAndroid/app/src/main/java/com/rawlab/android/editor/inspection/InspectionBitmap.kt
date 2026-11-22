package com.rawlab.android.editor.inspection

import android.graphics.Bitmap
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.rawlab.android.editor.render.PreviewDetailOverlay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

internal object InspectionBitmap {
    private const val MAX_CACHE_ENTRIES = 24

    private data class OverlayCacheKey(
        val identityHash: Int,
        val generationId: Int,
        val width: Int,
        val height: Int,
        val mode: InspectionOverlayMode,
    )

    private val cacheLock = Any()
    private val overlayCache = object : LinkedHashMap<OverlayCacheKey, Bitmap>(MAX_CACHE_ENTRIES, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<OverlayCacheKey, Bitmap>?): Boolean =
            size > MAX_CACHE_ENTRIES
    }

    fun clearOverlayCache() {
        synchronized(cacheLock) {
            overlayCache.clear()
        }
    }

    private fun cacheKey(source: Bitmap, mode: InspectionOverlayMode): OverlayCacheKey =
        OverlayCacheKey(
            identityHash = System.identityHashCode(source),
            generationId = source.generationId,
            width = source.width,
            height = source.height,
            mode = mode,
        )

    private fun lookupCache(key: OverlayCacheKey): Bitmap? =
        synchronized(cacheLock) {
            val hit = overlayCache[key]
            if (hit != null && hit.isRecycled) {
                overlayCache.remove(key)
                null
            } else {
                hit
            }
        }

    private fun storeCache(key: OverlayCacheKey, bitmap: Bitmap) {
        synchronized(cacheLock) {
            overlayCache[key] = bitmap
        }
    }

    private val gray50Bitmap: Bitmap by lazy {
        Bitmap.createBitmap(intArrayOf(0xff808080.toInt(), 0xff808080.toInt(), 0xff808080.toInt(), 0xff808080.toInt()), 2, 2, Bitmap.Config.ARGB_8888)
    }

    fun sampleBitmap(bitmap: Bitmap?, normX: Float, normY: Float, radiusPx: Int = 1): InspectionColorSample? {
        if (bitmap == null || bitmap.isRecycled || bitmap.width <= 0 || bitmap.height <= 0) return null
        if (!normX.isFinite() || !normY.isFinite()) return null
        val w = bitmap.width
        val h = bitmap.height
        val nx = normX.coerceIn(0f, 1f).toDouble()
        val ny = normY.coerceIn(0f, 1f).toDouble()
        val cx = if (w == 1) 0 else (nx * (w - 1)).roundToInt().coerceIn(0, w - 1)
        val cy = if (h == 1) 0 else (ny * (h - 1)).roundToInt().coerceIn(0, h - 1)
        val r = max(0, radiusPx)
        val x0 = max(0, cx - r)
        val x1 = min(w - 1, cx + r)
        val y0 = max(0, cy - r)
        val y1 = min(h - 1, cy + r)
        val boxW = x1 - x0 + 1
        val boxH = y1 - y0 + 1

        var sumR = 0L
        var sumG = 0L
        var sumB = 0L
        val count = boxW * boxH
        if (bitmap.config == Bitmap.Config.ARGB_8888) {
            val patch = IntArray(count)
            bitmap.getPixels(patch, 0, boxW, x0, y0, boxW, boxH)
            for (c in patch) {
                sumR += (c ushr 16) and 0xff
                sumG += (c ushr 8) and 0xff
                sumB += c and 0xff
            }
        } else {
            for (y in y0..y1) {
                for (x in x0..x1) {
                    val c = bitmap.getPixel(x, y)
                    sumR += (c ushr 16) and 0xff
                    sumG += (c ushr 8) and 0xff
                    sumB += c and 0xff
                }
            }
        }
        return InspectionColorMath.fromRgb(
            (sumR.toDouble() / count).roundToInt().coerceIn(0, 255),
            (sumG.toDouble() / count).roundToInt().coerceIn(0, 255),
            (sumB.toDouble() / count).roundToInt().coerceIn(0, 255)
        )
    }

    fun samplePreview(
        base: Bitmap?,
        detailTiles: List<PreviewDetailOverlay>,
        detailOverlay: PreviewDetailOverlay?,
        useNeutral: Boolean,
        normX: Float,
        normY: Float,
        radiusPx: Int = 1,
    ): InspectionColorSample? {
        for (tile in detailTiles.sortedBy { it.tileKey?.level ?: 0 }) {
            val rect = tile.normalizedRect
            val bmp = if (useNeutral) tile.neutral else tile.result
            if (bmp != null && normX in rect.x0..rect.x1 && normY in rect.y0..rect.y1 &&
                rect.x1 > rect.x0 && rect.y1 > rect.y0
            ) {
                val lx = (normX - rect.x0) / (rect.x1 - rect.x0)
                val ly = (normY - rect.y0) / (rect.y1 - rect.y0)
                return sampleBitmap(bmp, lx, ly, radiusPx)
            }
        }
        if (detailOverlay != null) {
            val rect = detailOverlay.normalizedRect
            val bmp = if (useNeutral) detailOverlay.neutral else detailOverlay.result
            if (bmp != null && normX in rect.x0..rect.x1 && normY in rect.y0..rect.y1 &&
                rect.x1 > rect.x0 && rect.y1 > rect.y0
            ) {
                val lx = (normX - rect.x0) / (rect.x1 - rect.x0)
                val ly = (normY - rect.y0) / (rect.y1 - rect.y0)
                return sampleBitmap(bmp, lx, ly, radiusPx)
            }
        }
        return sampleBitmap(base, normX, normY, radiusPx)
    }

    @Composable
    fun rememberBitmap(source: Bitmap, mode: InspectionOverlayMode): Bitmap {
        if (mode == InspectionOverlayMode.NONE) return source
        if (mode == InspectionOverlayMode.NEUTRAL_GRAY_50) return gray50Bitmap
        val key = cacheKey(source, mode)
        val cached = lookupCache(key)
        var lastRendered by remember(mode) { mutableStateOf<Bitmap?>(null) }
        if (cached != null) {
            lastRendered = cached
            return cached
        }
        val rendered by produceState<Bitmap?>(null, key) {
            value = withContext(Dispatchers.Default) {
                val w = source.width
                val h = source.height
                if (w <= 0 || h <= 0 || source.isRecycled) return@withContext null
                val argbSrc = if (source.config == Bitmap.Config.ARGB_8888) source else source.copy(Bitmap.Config.ARGB_8888, false) ?: return@withContext null
                val srcRow = IntArray(w)
                val dstPixels = IntArray(w * h)
                for (y in 0 until h) {
                    coroutineContext.ensureActive()
                    argbSrc.getPixels(srcRow, 0, w, 0, y, w, 1)
                    val rowOffset = y * w
                    for (x in 0 until w) {
                        val c = srcRow[x]
                        dstPixels[rowOffset + x] = InspectionColorMath.applyOverlayPixel(
                            (c ushr 16) and 0xff,
                            (c ushr 8) and 0xff,
                            c and 0xff,
                            mode
                        )
                    }
                }
                val bmp = Bitmap.createBitmap(dstPixels, w, h, Bitmap.Config.ARGB_8888)
                storeCache(key, bmp)
                bmp
            }
        }
        if (rendered != null) {
            lastRendered = rendered
            return rendered!!
        }
        val fallback = lastRendered?.takeIf {
            !it.isRecycled && it.width > 0 && it.height > 0 && source.width > 0 && source.height > 0 &&
                abs(it.width.toFloat() / it.height - source.width.toFloat() / source.height) < 0.02f
        }
        return fallback ?: source
    }
}
