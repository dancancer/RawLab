package com.rawlab.android

import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** Ratios describe physical image width / height, before normalization to the canvas. */
enum class GeometryRatio {
    FREE, ORIGINAL, SQUARE, THREE_TWO, FOUR_THREE, SIXTEEN_NINE;

    fun ratio(originalAspect: Float, portrait: Boolean): Float? {
        if (this == FREE) return null
        val landscape = when (this) {
            ORIGINAL -> {
                require(originalAspect.isFinite() && originalAspect > 0f)
                max(originalAspect, 1f / originalAspect)
            }
            SQUARE -> 1f
            THREE_TWO -> 3f / 2f
            FOUR_THREE -> 4f / 3f
            SIXTEEN_NINE -> 16f / 9f
            FREE -> error("Free crop has no fixed ratio")
        }
        return if (portrait) 1f / landscape else landscape
    }
}

enum class GeometryCropCorner { TOP_LEFT, TOP_RIGHT, BOTTOM_LEFT, BOTTOM_RIGHT }

fun GeometrySettings.uncropped(): GeometrySettings =
    copy(cropX = 0f, cropY = 0f, cropWidth = 1f, cropHeight = 1f)

/** All gesture deltas are normalized to the full transformed canvas. */
object GeometryCropMath {
    const val MIN_EDGE = .04f

    /** A preset grows from the full canvas around the current center, avoiding cumulative shrink. */
    fun preset(value: GeometrySettings, physicalAspect: Float?, canvasAspect: Float): GeometrySettings {
        val normalizedAspect = normalizedAspect(physicalAspect, canvasAspect) ?: return value
        val centerX = value.cropX.toDouble() + value.cropWidth / 2.0
        val centerY = value.cropY.toDouble() + value.cropHeight / 2.0
        val availableWidth = 2.0 * min(centerX, 1.0 - centerX)
        val availableHeight = 2.0 * min(centerY, 1.0 - centerY)
        val height = min(availableHeight, availableWidth / normalizedAspect)
        val width = height * normalizedAspect
        return value.copy(
            cropX = (centerX - width / 2.0).toFloat().coerceAtLeast(0f),
            cropY = (centerY - height / 2.0).toFloat().coerceAtLeast(0f),
            cropWidth = width.toFloat(),
            cropHeight = height.toFloat(),
        )
    }

    /** Refit an existing crop after a canvas change without enlarging its selected area. */
    fun refit(value: GeometrySettings, physicalAspect: Float?, canvasAspect: Float): GeometrySettings {
        val normalizedAspect = normalizedAspect(physicalAspect, canvasAspect) ?: return value
        val centerX = value.cropX.toDouble() + value.cropWidth / 2.0
        val centerY = value.cropY.toDouble() + value.cropHeight / 2.0
        val area = value.cropWidth.toDouble() * value.cropHeight
        val width = sqrt(area * normalizedAspect)
        val height = sqrt(area / normalizedAspect)
        val availableWidth = 2.0 * min(centerX, 1.0 - centerX)
        val availableHeight = 2.0 * min(centerY, 1.0 - centerY)
        val fit = min(1.0, min(availableWidth / width, availableHeight / height))
        val fittedWidth = width * fit
        val fittedHeight = height * fit
        return value.copy(
            cropX = (centerX - fittedWidth / 2.0).toFloat().coerceAtLeast(0f),
            cropY = (centerY - fittedHeight / 2.0).toFloat().coerceAtLeast(0f),
            cropWidth = fittedWidth.toFloat(),
            cropHeight = fittedHeight.toFloat(),
        )
    }

    fun move(baseline: GeometrySettings, dxNormalized: Float, dyNormalized: Float): GeometrySettings {
        require(dxNormalized.isFinite() && dyNormalized.isFinite())
        return baseline.copy(
            cropX = (baseline.cropX + dxNormalized).coerceIn(0f, 1f - baseline.cropWidth),
            cropY = (baseline.cropY + dyNormalized).coerceIn(0f, 1f - baseline.cropHeight),
        )
    }

    /** Resize from a fixed gesture baseline; the opposite corner remains anchored. */
    fun resize(
        baseline: GeometrySettings,
        corner: GeometryCropCorner,
        dx: Float,
        dy: Float,
        physicalAspect: Float?,
        canvasAspect: Float,
    ): GeometrySettings {
        require(dx.isFinite() && dy.isFinite())
        val normalizedAspect = normalizedAspect(physicalAspect, canvasAspect)
        val left = corner == GeometryCropCorner.TOP_LEFT || corner == GeometryCropCorner.BOTTOM_LEFT
        val top = corner == GeometryCropCorner.TOP_LEFT || corner == GeometryCropCorner.TOP_RIGHT
        val signX = if (left) -1.0 else 1.0
        val signY = if (top) -1.0 else 1.0
        val anchorX = baseline.cropX.toDouble() + if (left) baseline.cropWidth.toDouble() else 0.0
        val anchorY = baseline.cropY.toDouble() + if (top) baseline.cropHeight.toDouble() else 0.0
        val maximumWidth = if (left) anchorX else 1.0 - anchorX
        val maximumHeight = if (top) anchorY else 1.0 - anchorY
        val desiredWidth = baseline.cropWidth + signX * dx
        val desiredHeight = baseline.cropHeight + signY * dy
        val width: Double
        val height: Double
        if (normalizedAspect == null) {
            width = desiredWidth.coerceIn(min(MIN_EDGE.toDouble(), maximumWidth), maximumWidth)
            height = desiredHeight.coerceIn(min(MIN_EDGE.toDouble(), maximumHeight), maximumHeight)
        } else {
            // Project the dragged corner onto the ratio line in physical canvas coordinates.
            val ratio = physicalAspect!!.toDouble()
            val projectedHeight = (ratio * desiredWidth * canvasAspect + desiredHeight) / (ratio * ratio + 1.0)
            val maximum = min(maximumHeight, maximumWidth / normalizedAspect)
            val minimum = max(MIN_EDGE.toDouble(), MIN_EDGE / normalizedAspect)
            // A legacy crop or extreme ratio may leave less room than MIN_EDGE at its fixed anchor.
            height = projectedHeight.coerceIn(min(minimum, maximum), maximum)
            width = height * normalizedAspect
        }
        return baseline.copy(
            cropX = (if (left) anchorX - width else anchorX).toFloat().coerceAtLeast(0f),
            cropY = (if (top) anchorY - height else anchorY).toFloat().coerceAtLeast(0f),
            cropWidth = width.toFloat(),
            cropHeight = height.toFloat(),
        )
    }

    private fun normalizedAspect(physicalAspect: Float?, canvasAspect: Float): Double? {
        require(canvasAspect.isFinite() && canvasAspect > 0f)
        if (physicalAspect == null) return null
        require(physicalAspect.isFinite() && physicalAspect > 0f)
        return physicalAspect.toDouble() / canvasAspect
    }
}
