package com.rawlab.android.editor.canvas

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.ceil

data class PhotoViewport(val imageWidth: Float, val imageHeight: Float, val width: Float, val height: Float) {
    val fitScale = min(width / imageWidth, height / imageHeight)
    val minimumScale = min(fitScale, 1f)
    val maximumScale = max(fitScale * 8f, 1f)
    fun isFit(scale: Float) = abs(scale - fitScale) < fitScale * .001f
    fun previewLongEdge(scale: Float, limit: Int = 1600): Int {
        val source = max(imageWidth, imageHeight)
        if (!scale.isFinite() || scale <= 0 || !source.isFinite() || source <= 0) return limit
        return minOf(limit, source.toInt(), max(64, ceil(source * scale / 64).toInt() * 64))
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
