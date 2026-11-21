package com.rawlab.android.editor.canvas

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

data class NormalizedRect(val x0: Float, val y0: Float, val x1: Float, val y1: Float) {
    val width: Float get() = x1 - x0
    val height: Float get() = y1 - y0
}

data class DetailTileKey(val level: Int, val col: Int, val row: Int)

data class DetailTileSpec(
    val key: DetailTileKey,
    val rect: NormalizedRect,
    val maxOutputLongEdge: Int,
)

data class ViewportRoiRequest(
    val visibleRect: NormalizedRect,
    val overscanRect: NormalizedRect,
    val zoomScale: Float,
    val baseScale: Float,
    val maxOutputLongEdge: Int,
)

internal fun detailTileLevel(zoomScale: Float, baseScale: Float): Int? {
    if (!zoomScale.isFinite() || !baseScale.isFinite() || zoomScale <= 0f || min(1f, zoomScale) <= baseScale * 1.05f) {
        return null
    }
    val threshold = baseScale * 1.05f
    val skipLevel1Threshold = baseScale * 1.35f
    return when {
        zoomScale >= 0.65f -> 0
        zoomScale >= 0.325f && 0.5f > skipLevel1Threshold -> 1
        0.25f > threshold -> 2
        0.5f > skipLevel1Threshold -> 1
        else -> 0
    }
}

private fun makeDetailTileSpec(
    level: Int,
    col: Int,
    row: Int,
    nativeSpan: Int,
    levelScale: Float,
    tileSize: Int,
    fullNativeWidth: Int,
    fullNativeHeight: Int,
): DetailTileSpec? {
    val px0 = col * nativeSpan
    val px1 = min(fullNativeWidth, px0 + nativeSpan)
    val py0 = row * nativeSpan
    val py1 = min(fullNativeHeight, py0 + nativeSpan)
    if (px1 <= px0 || py1 <= py0) return null
    val rect = NormalizedRect(
        x0 = px0.toFloat() / fullNativeWidth,
        y0 = py0.toFloat() / fullNativeHeight,
        x1 = px1.toFloat() / fullNativeWidth,
        y1 = py1.toFloat() / fullNativeHeight,
    )
    val longSpan = max(px1 - px0, py1 - py0)
    val edge = min(tileSize, max(1, (longSpan * levelScale).roundToInt()))
    return DetailTileSpec(DetailTileKey(level, col, row), rect, edge)
}

internal fun detailTileSpecs(
    visibleRect: NormalizedRect,
    fullNativeWidth: Int,
    fullNativeHeight: Int,
    zoomScale: Float,
    baseScale: Float,
    tileSize: Int = 1024,
    overscanRing: Int = 0,
): List<DetailTileSpec> {
    val level = detailTileLevel(zoomScale, baseScale) ?: return emptyList()
    if (tileSize <= 0 || fullNativeWidth <= 0 || fullNativeHeight <= 0 ||
        visibleRect.width <= 0f || visibleRect.height <= 0f) {
        return emptyList()
    }
    val levelScale = 1f / (1 shl level)
    val nativeSpan = tileSize shl level
    val vx0 = floor(visibleRect.x0 * fullNativeWidth).toInt().coerceIn(0, fullNativeWidth - 1)
    val vy0 = floor(visibleRect.y0 * fullNativeHeight).toInt().coerceIn(0, fullNativeHeight - 1)
    val vx1 = ceil(visibleRect.x1 * fullNativeWidth).toInt().coerceIn(vx0 + 1, fullNativeWidth)
    val vy1 = ceil(visibleRect.y1 * fullNativeHeight).toInt().coerceIn(vy0 + 1, fullNativeHeight)

    val maxCol = (fullNativeWidth - 1) / nativeSpan
    val maxRow = (fullNativeHeight - 1) / nativeSpan
    val colMin = max(0, vx0 / nativeSpan)
    val colMax = min(maxCol, max(0, (vx1 - 1) / nativeSpan))
    val rowMin = max(0, vy0 / nativeSpan)
    val rowMax = min(maxRow, max(0, (vy1 - 1) / nativeSpan))

    val cx = (visibleRect.x0 + visibleRect.x1) * 0.5f
    val cy = (visibleRect.y0 + visibleRect.y1) * 0.5f

    val visibleSpecs = ArrayList<DetailTileSpec>((colMax - colMin + 1) * (rowMax - rowMin + 1))
    for (row in rowMin..rowMax) {
        for (col in colMin..colMax) {
            makeDetailTileSpec(level, col, row, nativeSpan, levelScale, tileSize, fullNativeWidth, fullNativeHeight)
                ?.let { visibleSpecs += it }
        }
    }
    visibleSpecs.sortBy { spec ->
        val dx = (spec.rect.x0 + spec.rect.x1) * 0.5f - cx
        val dy = (spec.rect.y0 + spec.rect.y1) * 0.5f - cy
        dx * dx + dy * dy
    }
    if (overscanRing <= 0) return visibleSpecs

    val seen = visibleSpecs.mapTo(HashSet(visibleSpecs.size)) { it.key }
    val oColMin = max(0, colMin - overscanRing)
    val oColMax = min(maxCol, colMax + overscanRing)
    val oRowMin = max(0, rowMin - overscanRing)
    val oRowMax = min(maxRow, rowMax + overscanRing)
    val overscanSpecs = ArrayList<DetailTileSpec>()
    for (row in oRowMin..oRowMax) {
        for (col in oColMin..oColMax) {
            val key = DetailTileKey(level, col, row)
            if (key in seen) continue
            makeDetailTileSpec(level, col, row, nativeSpan, levelScale, tileSize, fullNativeWidth, fullNativeHeight)
                ?.let { overscanSpecs += it }
        }
    }
    overscanSpecs.sortBy { spec ->
        val dx = (spec.rect.x0 + spec.rect.x1) * 0.5f - cx
        val dy = (spec.rect.y0 + spec.rect.y1) * 0.5f - cy
        dx * dx + dy * dy
    }
    return visibleSpecs + overscanSpecs
}

internal fun detailOverlayCovers(
    normalizedRect: NormalizedRect,
    pixelWidth: Int,
    pixelHeight: Int,
    fullNativeWidth: Int,
    fullNativeHeight: Int,
    visibleRect: NormalizedRect,
    requiredZoomScale: Float,
    maxOutputLongEdge: Int = 0,
): Boolean {
    val tolerance = 0.0005f
    if (normalizedRect.x0 > visibleRect.x0 + tolerance ||
        normalizedRect.y0 > visibleRect.y0 + tolerance ||
        normalizedRect.x1 < visibleRect.x1 - tolerance ||
        normalizedRect.y1 < visibleRect.y1 - tolerance ||
        normalizedRect.width <= 0f ||
        pixelWidth <= 0 || pixelHeight <= 0 ||
        fullNativeWidth <= 0 || fullNativeHeight <= 0
    ) {
        return false
    }
    val tileDensity = pixelWidth.toFloat() / (normalizedRect.width * fullNativeWidth.toFloat())
    val nativeW = normalizedRect.width * fullNativeWidth.toFloat()
    val nativeH = normalizedRect.height * fullNativeHeight.toFloat()
    val maxAchievable = if (maxOutputLongEdge > 0) {
        min(1f, maxOutputLongEdge.toFloat() / max(1f, max(nativeW, nativeH)))
    } else 1f
    val neededDensity = minOf(1f, requiredZoomScale, maxAchievable)
    return tileDensity >= neededDensity * 0.9f
}

data class PhotoViewport(val imageWidth: Float, val imageHeight: Float, val width: Float, val height: Float) {
    val fitScale = min(width / imageWidth, height / imageHeight)
    val minimumScale = min(fitScale, 1f)
    val maximumScale = max(fitScale * 8f, 4f)
    fun isFit(scale: Float) = abs(scale - fitScale) < fitScale * .001f
    fun previewLongEdge(scale: Float, limit: Int = 1600): Int {
        val source = max(imageWidth, imageHeight)
        if (!scale.isFinite() || scale <= 0 || !source.isFinite() || source <= 0) return limit
        return minOf(limit, source.toInt(), max(64, ceil(source * scale / 64).toInt() * 64))
    }

    fun visibleNormalizedRect(zoom: PhotoZoom): NormalizedRect? {
        if (width <= 0f || height <= 0f || imageWidth <= 0f || imageHeight <= 0f ||
            !zoom.scale.isFinite() || zoom.scale <= 0f) {
            return null
        }
        val photoWidth = imageWidth * zoom.scale
        val photoHeight = imageHeight * zoom.scale
        val x0 = (0.5f - (zoom.x + width / 2f) / photoWidth).coerceIn(0f, 1f)
        val x1 = (0.5f - (zoom.x - width / 2f) / photoWidth).coerceIn(x0, 1f)
        val y0 = (0.5f - (zoom.y + height / 2f) / photoHeight).coerceIn(0f, 1f)
        val y1 = (0.5f - (zoom.y - height / 2f) / photoHeight).coerceIn(y0, 1f)
        if (x1 <= x0 || y1 <= y0) return null
        return NormalizedRect(x0, y0, x1, y1)
    }

    fun detailRequest(
        zoom: PhotoZoom,
        baseLongEdge: Int,
        maxOutputLongEdge: Int = 2048,
        active: Boolean = false,
    ): ViewportRoiRequest? {
        val pixelEdge = max(imageWidth, imageHeight)
        if (baseLongEdge <= 0 || pixelEdge <= baseLongEdge || maxOutputLongEdge <= 0) return null
        val baseScale = min(1f, baseLongEdge.toFloat() / pixelEdge)
        val threshold = if (active) baseScale * 0.85f else baseScale * 1.05f
        if (min(1f, zoom.scale) <= threshold) return null
        val visible = visibleNormalizedRect(zoom) ?: return null
        val padX = visible.width * 0.1f
        val padY = visible.height * 0.1f
        val x0 = max(0f, visible.x0 - padX)
        val y0 = max(0f, visible.y0 - padY)
        val x1 = min(1f, visible.x1 + padX)
        val y1 = min(1f, visible.y1 + padY)
        if (x1 <= x0 || y1 <= y0) return null
        return ViewportRoiRequest(
            visibleRect = visible,
            overscanRect = NormalizedRect(x0, y0, x1, y1),
            zoomScale = zoom.scale,
            baseScale = baseScale,
            maxOutputLongEdge = maxOutputLongEdge,
        )
    }
}

data class PhotoZoom(val scale: Float, val x: Float = 0f, val y: Float = 0f) {
    fun transform(viewport: PhotoViewport, factor: Float, panX: Float, panY: Float,
        focusX: Float, focusY: Float): PhotoZoom {
        val next = (scale * factor).coerceIn(viewport.minimumScale, viewport.maximumScale)
        val ratio = next / scale
        val anchorX = focusX - viewport.width / 2
        val anchorY = focusY - viewport.height / 2
        return PhotoZoom(next, anchorX - (anchorX - x) * ratio + panX,
            anchorY - (anchorY - y) * ratio + panY).constrained(viewport)
    }

    fun doubleTap(viewport: PhotoViewport, x: Float, y: Float): PhotoZoom =
        if (viewport.isFit(scale)) transform(viewport, 1f / scale, 0f, 0f, x, y)
        else PhotoZoom(viewport.fitScale)

    fun resize(previous: PhotoViewport, next: PhotoViewport): PhotoZoom =
        PhotoViewTransform.from(this, previous).project(next)

    fun constrained(viewport: PhotoViewport): PhotoZoom {
        val next = scale.coerceIn(viewport.minimumScale, viewport.maximumScale)
        val maxX = max(0f, (viewport.imageWidth * next - viewport.width) / 2)
        val maxY = max(0f, (viewport.imageHeight * next - viewport.height) / 2)
        return PhotoZoom(next, x.coerceIn(-maxX, maxX), y.coerceIn(-maxY, maxY))
    }
}

/** 一份照片焦点可投影到不同大小的 pane，不能复用屏幕像素 pan。 */
data class PhotoViewTransform(val magnification: Float = 1f, val focusX: Float = .5f, val focusY: Float = .5f) {
    fun project(viewport: PhotoViewport): PhotoZoom {
        val scale = (viewport.fitScale * magnification).coerceIn(viewport.minimumScale, viewport.maximumScale)
        return PhotoZoom(scale, (.5f - focusX) * viewport.imageWidth * scale,
            (.5f - focusY) * viewport.imageHeight * scale).constrained(viewport)
    }

    companion object {
        fun from(zoom: PhotoZoom, viewport: PhotoViewport) = PhotoViewTransform(zoom.scale / viewport.fitScale,
            .5f - zoom.x / (viewport.imageWidth * zoom.scale), .5f - zoom.y / (viewport.imageHeight * zoom.scale))
    }
}
