package com.rawlab.android.editor.controls

import kotlin.math.abs
import kotlin.math.round
import java.math.BigDecimal
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
        return parseAdjustmentNumber(text, locale)?.takeIf { it.isFinite() && it in range }
            ?.takeIf { it == current || BigDecimal(it.toString()).remainder(BigDecimal(step.toString())).signum() == 0 }
    }

    fun fraction(value: Float): Float {
        val width = position(range.endInclusive) - position(range.start)
        return if (width <= 0f) 0f else ((position(value) - position(range.start)) / width).coerceIn(0f, 1f)
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

internal fun editorUsesSideDock(width: Float, height: Float, fontScale: Float = 1f,
    requiredGroupWidth: Float = 0f, dockWidth: Float = 320f): Boolean =
    width >= 600f && width > height && fontScale < 1.3f && requiredGroupWidth <= dockWidth

internal data class EditorDockLayout(val height: Float, val compactNavigation: Boolean)

internal fun editorDockLayout(availableHeight: Float, fontScale: Float, sideDock: Boolean, expanded: Boolean): EditorDockLayout {
    val strip = 88f + 24f * (fontScale - 1f).coerceAtLeast(0f)
    // 唯一 fine 行、单行八色和三条48dp轴统一预留；工具、草稿状态不参与预算。
    val parameterHeight = if (fontScale > 1.3f) 144f else 240f
    val regular = 48f + strip * 2f + 65f + parameterHeight
    // 底部面板至少留96dp照片；短窗依靠原compact导航及参数内部滚动保留完整触点。
    val maximum = if (sideDock) availableHeight else (availableHeight - 96f).coerceAtLeast(0f)
    val compact = maximum < regular
    return EditorDockLayout(if (sideDock) availableHeight else if (!expanded) {
        if (compact) 48f else 160f * fontScale
    } else regular.coerceAtMost(maximum), compact)
}

internal fun parseAdjustmentNumber(text: String, locale: Locale): Float? {
    val input = text.trim()
    val position = ParsePosition(0)
    val localized = NumberFormat.getNumberInstance(locale).apply { isGroupingUsed = false }.parse(input, position)
        ?.takeIf { position.index == input.length }?.toFloat()
    return input.toFloatOrNull() ?: localized
}
