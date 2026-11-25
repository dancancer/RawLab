package com.rawlab.android.editor.canvas

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

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
