package com.rawlab.android

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

data class PhotoViewport(val imageWidth: Float, val imageHeight: Float, val width: Float, val height: Float) {
    val fitScale = min(width / imageWidth, height / imageHeight)
    val minimumScale = min(fitScale, 1f)
    val maximumScale = max(fitScale * 8f, 1f)
    fun isFit(scale: Float) = abs(scale - fitScale) < fitScale * .001f
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
        if (previous.isFit(scale)) PhotoZoom(next.fitScale) else constrained(next)

    fun constrained(viewport: PhotoViewport): PhotoZoom {
        val next = scale.coerceIn(viewport.minimumScale, viewport.maximumScale)
        val maxX = max(0f, (viewport.imageWidth * next - viewport.width) / 2)
        val maxY = max(0f, (viewport.imageHeight * next - viewport.height) / 2)
        return PhotoZoom(next, x.coerceIn(-maxX, maxX), y.coerceIn(-maxY, maxY))
    }
}
