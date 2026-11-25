package com.rawlab.android.editor.inspection

import android.graphics.Bitmap
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.rawlab.android.editor.render.PreviewDetailOverlay
import java.lang.ref.WeakReference
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.max

internal object InspectionBitmap {
    private const val MAX_CACHE_ENTRIES = 24

    // AndroidBitmap_lockPixels increments Bitmap.generationId even for read-only JNI access
    // (overlay rendering and 3x3 patch sampling). Preview bitmaps are immutable snapshots, so
    // key by identity + dimensions + mode and verify WeakReference=== to prevent hash collisions.
    private data class OverlayCacheKey(
        val identityHash: Int,
        val width: Int,
        val height: Int,
        val mode: InspectionOverlayMode,
    )

    private class OverlayCacheEntry(
        val sourceRef: WeakReference<Bitmap>,
        val rendered: Bitmap,
    )

    private val cacheLock = Any()
    private val overlayCache = object : LinkedHashMap<OverlayCacheKey, OverlayCacheEntry>(MAX_CACHE_ENTRIES, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<OverlayCacheKey, OverlayCacheEntry>?): Boolean =
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
            width = source.width,
            height = source.height,
            mode = mode,
        )

    private fun lookupCache(source: Bitmap, key: OverlayCacheKey): Bitmap? =
        synchronized(cacheLock) {
            val hit = overlayCache[key]
            if (hit == null) {
                null
            } else if (hit.sourceRef.get() !== source || hit.rendered.isRecycled) {
                overlayCache.remove(key)
                null
            } else {
                hit.rendered
            }
        }

    private fun storeCache(source: Bitmap, key: OverlayCacheKey, bitmap: Bitmap) {
        synchronized(cacheLock) {
            overlayCache[key] = OverlayCacheEntry(WeakReference(source), bitmap)
        }
    }

    private val gray50Bitmap: Bitmap by lazy {
        Bitmap.createBitmap(
            intArrayOf(0xff808080.toInt(), 0xff808080.toInt(), 0xff808080.toInt(), 0xff808080.toInt()),
            2, 2, Bitmap.Config.ARGB_8888
        )
    }

    fun sampleBitmap(bitmap: Bitmap?, normX: Float, normY: Float, radiusPx: Int = 1): InspectionColorSample? {
        if (bitmap == null || bitmap.isRecycled || bitmap.width <= 0 || bitmap.height <= 0) return null
        if (!normX.isFinite() || !normY.isFinite()) return null
        val isRgba8 = bitmap.config == Bitmap.Config.ARGB_8888
        val rgba = if (isRgba8) bitmap else bitmap.copy(Bitmap.Config.ARGB_8888, false) ?: return null
        return try {
            val arr = InspectionNative.nativeSampleBitmapPatch(
                rgba, normX.toDouble(), normY.toDouble(), max(0, radiusPx)
            )
            InspectionColorMath.fromNativeArray(arr)
        } finally {
            if (!isRgba8) rgba.recycle()
        }
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
        var localRendered by remember(source, mode) { mutableStateOf<Bitmap?>(null) }
        var lastRendered by remember(mode) { mutableStateOf<Bitmap?>(null) }
        val hit = localRendered?.takeIf { !it.isRecycled } ?: lookupCache(source, key)
        if (hit != null) {
            localRendered = hit
            lastRendered = hit
            return hit
        }
        val rendered by produceState<Bitmap?>(null, source, mode) {
            value = withContext(Dispatchers.Default) {
                coroutineContext.ensureActive()
                val w = source.width
                val h = source.height
                if (w <= 0 || h <= 0 || source.isRecycled) return@withContext null
                val isRgba8 = source.config == Bitmap.Config.ARGB_8888
                val argbSrc = if (isRgba8) source else source.copy(Bitmap.Config.ARGB_8888, false) ?: return@withContext null
                val dst = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                try {
                    if (!InspectionNative.nativeRenderOverlay(argbSrc, dst, mode.ordinal)) {
                        dst.recycle()
                        return@withContext null
                    }
                    storeCache(source, key, dst)
                    dst
                } finally {
                    if (!isRgba8) argbSrc.recycle()
                }
            }
        }
        if (rendered != null && !rendered!!.isRecycled) {
            localRendered = rendered
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
