package com.rawlab.android.editor.controls

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

internal fun editorUsesSideDock(width: Float, height: Float): Boolean = width >= 600f && width > height
