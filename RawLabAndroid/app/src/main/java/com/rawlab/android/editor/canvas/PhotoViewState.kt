package com.rawlab.android.editor.canvas

import kotlin.math.max
import kotlin.math.min

enum class ComparisonMode { SIDE_BY_SIDE, WIPE }

/** 工作区会话状态，不属于照片编辑记录。 */
data class PhotoViewOptions(
    val comparisonEnabled: Boolean = false,
    val preferredMode: ComparisonMode = ComparisonMode.SIDE_BY_SIDE,
    val margins: Boolean = true,
    val infoMode: Int = 0,
    val purePreview: Boolean = false,
    val holdingBefore: Boolean = false,
) {
    fun toggleComparison() = copy(comparisonEnabled = !comparisonEnabled, holdingBefore = false)
    fun selectComparison(mode: ComparisonMode) = copy(comparisonEnabled = true, preferredMode = mode, holdingBefore = false)
    fun beginHold(allowed: Boolean) = copy(holdingBefore = allowed && !comparisonEnabled)
    fun cancelHold() = copy(holdingBefore = false)
    fun enterPure(allowed: Boolean) = if (allowed) copy(purePreview = true, holdingBefore = false) else cancelHold()
    fun forNewPhoto() = copy(purePreview = false, holdingBefore = false, infoMode = 0)
}

data class PhotoImageRect(val left: Float, val top: Float, val right: Float, val bottom: Float) {
    val width get() = (right - left).coerceAtLeast(0f)
    val height get() = (bottom - top).coerceAtLeast(0f)
    fun splitX(split: Float) = left + width * split.coerceIn(0f, 1f)
    fun splitAt(x: Float) = if (width > 0f) ((x - left) / width).coerceIn(0f, 1f) else .5f
}

fun photoImageRect(viewport: PhotoViewport, zoom: PhotoZoom): PhotoImageRect {
    val width = viewport.imageWidth * zoom.scale
    val height = viewport.imageHeight * zoom.scale
    val x = (viewport.width - width) / 2f + zoom.x
    val y = (viewport.height - height) / 2f + zoom.y
    return PhotoImageRect(max(0f, x), max(0f, y), min(viewport.width, x + width), min(viewport.height, y + height))
}

fun hslTargetCoordinates(viewport: PhotoViewport, zoom: PhotoZoom, x: Float, y: Float,
    wipeSplit: Float? = null, dividerRadius: Float = 0f): Pair<Float, Float>? {
    if (!x.isFinite() || !y.isFinite() || x !in 0f..viewport.width || y !in 0f..viewport.height) return null
    val visible = photoImageRect(viewport, zoom)
    if (x !in visible.left..visible.right || y !in visible.top..visible.bottom) return null
    if (wipeSplit != null && x <= visible.splitX(wipeSplit) + dividerRadius) return null
    val width = viewport.imageWidth * zoom.scale; val height = viewport.imageHeight * zoom.scale
    if (!width.isFinite() || !height.isFinite() || width <= 0 || height <= 0) return null
    val left = (viewport.width-width)/2 + zoom.x; val top = (viewport.height-height)/2 + zoom.y
    return ((x-left)/width) to ((y-top)/height)
}
