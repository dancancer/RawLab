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
