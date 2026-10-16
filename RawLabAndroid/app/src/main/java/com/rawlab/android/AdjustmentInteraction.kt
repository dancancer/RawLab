package com.rawlab.android

import kotlin.math.abs
import kotlin.math.round
import java.text.NumberFormat
import java.text.ParsePosition
import java.util.Locale

internal class AdjustmentHapticGate {
    private var next = 0L
    fun accept(now: Long): Boolean {
        if (now < next) return false
        next = now + 125L
        return true
    }
}

internal data class AdjustmentScale(
    val range: ClosedFloatingPointRange<Float>,
    val step: Float,
    val default: Float,
    val reciprocal: Boolean = false,
) {
    fun quantize(value: Float): Float = (round(value / step) * step).coerceIn(range)

    fun parse(text: String, locale: Locale = Locale.ROOT, current: Float? = null): Float? {
        val input = text.trim()
        val position = ParsePosition(0)
        val localized = NumberFormat.getNumberInstance(locale).apply { isGroupingUsed = false }.parse(input, position)
            ?.takeIf { position.index == input.length }?.toFloat()
        return (input.toFloatOrNull() ?: localized)?.takeIf { it.isFinite() && it in range }
            ?.let { if (reciprocal && (it == default || it == current)) it else quantize(it) }
    }

    fun position(value: Float): Float = if (reciprocal) -1f / value else value
    fun fromPosition(value: Float): Float = if (reciprocal) {
        if (value >= -1f / range.endInclusive) range.endInclusive
        else (-1f / value).coerceIn(range)
    } else value.coerceIn(range)

    val rulerStep: Float get() = if (reciprocal) 1f / 240000f else step
    fun drag(start: Float, pixels: Float, fine: Boolean): Float = quantize(fromPosition(
        position(start) - pixels / 8f * rulerStep * if (fine) .25f else 1f))

    fun sweep(value: Float): Float {
        val distance = value - default
        val available = if (distance > 0f) range.endInclusive - default else default - range.start
        return if (abs(distance) < .000001f || available <= 0f) 0f
        else (distance / available).coerceIn(-1f, 1f) * 270f
    }
}

enum class AdjustmentGroup { GEOMETRY, LENS }

data class AdjustmentDraft(
    val group: AdjustmentGroup,
    val original: EditSettings,
    val value: EditSettings,
    val geometryRatio: GeometryRatio = GeometryRatio.FREE,
    val geometryPortrait: Boolean = false,
    val geometryOriginalAspect: Float = 1f,
    val geometryCanvasAspect: Float = 1f,
) {
    val geometryAspect: Float? get() = geometryRatio.ratio(geometryOriginalAspect, geometryPortrait)
    val changed: Boolean get() = project(original) != original
    fun project(settings: EditSettings): EditSettings = when (group) {
        AdjustmentGroup.GEOMETRY -> settings.copy(geometry = value.geometry)
        AdjustmentGroup.LENS -> settings.copy(lens = value.lens)
    }
    fun update(settings: EditSettings): AdjustmentDraft {
        val next = when (group) {
            AdjustmentGroup.GEOMETRY -> value.copy(geometry = settings.geometry)
            AdjustmentGroup.LENS -> value.copy(lens = settings.lens)
        }
        val resized = next.geometry.cropWidth != value.geometry.cropWidth || next.geometry.cropHeight != value.geometry.cropHeight
        val breaksRatio = geometryAspect?.let { ratio ->
            abs(next.geometry.cropWidth * geometryCanvasAspect / next.geometry.cropHeight - ratio) > .0001f
        } ?: false
        return copy(value = next, geometryRatio = if (resized && breaksRatio) GeometryRatio.FREE else geometryRatio)
    }
    fun reset() = update(EditSettings()).copy(geometryRatio = GeometryRatio.FREE)

    fun selectGeometryRatio(ratio: GeometryRatio, portrait: Boolean): AdjustmentDraft {
        if (group != AdjustmentGroup.GEOMETRY) return this
        val next = copy(geometryRatio = ratio, geometryPortrait = portrait)
        return next.copy(value = value.copy(geometry = GeometryCropMath.preset(value.geometry, next.geometryAspect, geometryCanvasAspect)))
    }

    fun acceptGeometryCanvas(canvasAspect: Float): AdjustmentDraft {
        if (group != AdjustmentGroup.GEOMETRY || canvasAspect == geometryCanvasAspect) return this
        return copy(geometryCanvasAspect = canvasAspect,
            value = value.copy(geometry = GeometryCropMath.refit(value.geometry, geometryAspect, canvasAspect)))
    }

    companion object {
        fun begin(group: AdjustmentGroup, settings: EditSettings, originalAspect: Float = 1f, canvasAspect: Float = 1f) =
            AdjustmentDraft(group, settings, settings,
                geometryPortrait = (originalAspect < 1f) != (settings.geometry.quarterTurns % 2 == 1),
                geometryOriginalAspect = originalAspect, geometryCanvasAspect = canvasAspect)
    }
}

internal fun editorUsesSideDock(width: Float, height: Float): Boolean = width >= 600f && width > height

internal fun GeometrySettings.uncropped() = copy(cropX = 0f, cropY = 0f, cropWidth = 1f, cropHeight = 1f)

internal fun GeometrySettings.moveCrop(dx: Float, dy: Float) = GeometryCropMath.move(this, dx, dy)

internal fun GeometrySettings.withAspect(physicalAspect: Float, canvasAspect: Float) =
    GeometryCropMath.preset(this, physicalAspect, canvasAspect)
