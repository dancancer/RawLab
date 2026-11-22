package com.rawlab.android.editor.inspection

import android.graphics.Bitmap
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import com.rawlab.android.editor.render.PreviewDetailOverlay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

internal object InspectionBitmap {
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
        val rendered by produceState<Bitmap?>(null, source, mode) {
            value = null
            value = withContext(Dispatchers.Default) {
                val w = source.width
                val h = source.height
                if (w <= 0 || h <= 0 || source.isRecycled) return@withContext null
                val argbSrc = if (source.config == Bitmap.Config.ARGB_8888) source else source.copy(Bitmap.Config.ARGB_8888, false)
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
                Bitmap.createBitmap(dstPixels, w, h, Bitmap.Config.ARGB_8888)
            }
        }
        return rendered ?: source
    }
}
