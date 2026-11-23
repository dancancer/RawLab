package com.rawlab.android.settings

import com.rawlab.android.adjustments.AdjustmentFieldSpec
import kotlin.math.*

enum class ColorGradingZone(val id: String, val title: String) {
    SHADOWS("shadows", "阴影"), MIDTONES("midtones", "中间调"), HIGHLIGHTS("highlights", "高光")
}

data class ColorGradingWheel(val hue: Float = 0f, val saturation: Float = 0f, val luminance: Float = 0f) {
    init { require(valid(hue.toDouble(), saturation.toDouble(), luminance.toDouble())) }
    val isDefault get() = hue == 0f && saturation == 0f && luminance == 0f
    val isIdentity get() = saturation == 0f && luminance == 0f
    val point get() = (cos(hue.toDouble() * PI / 180) * saturation / 100).toFloat() to
        (sin(hue.toDouble() * PI / 180) * saturation / 100).toFloat()
    fun moving(x: Float, y: Float): ColorGradingWheel {
        if (!x.isFinite() || !y.isFinite()) return this
        val radius = hypot(x.toDouble(), y.toDouble())
        if (radius == 0.0) return copy(saturation = 0f)
        val angle = atan2(y.toDouble(), x.toDouble()) * 180 / PI
        val moved = fromNumbers(if (angle < 0) (angle + 360) % 360 else angle, min(1.0, radius) * 100, luminance.toDouble())
        return moved
    }
    fun withLuminance(value: Float): ColorGradingWheel {
        if (!value.isFinite()) return this
        val sub = AdjustmentFieldSpec.SubFields.ColorGradingWheel
        return copy(luminance = value.coerceIn(sub.luminanceMin.toFloat(), sub.luminanceMax.toFloat()).canonicalZero())
    }
    fun scaled(strength: Float): ColorGradingWheel {
        val sub = AdjustmentFieldSpec.SubFields.ColorGradingWheel
        return copy(
            saturation = (saturation * strength).coerceIn(0f, 100f).canonicalZero(),
            luminance = (luminance * strength).coerceIn(sub.luminanceMin.toFloat(), sub.luminanceMax.toFloat()).canonicalZero(),
        )
    }
    companion object {
        fun valid(hue: Double, saturation: Double, luminance: Double = 0.0): Boolean {
            val sub = AdjustmentFieldSpec.SubFields.ColorGradingWheel
            return hue.isFinite() && hue >= sub.hueMin && hue < sub.hueMax &&
                saturation.isFinite() && saturation in sub.saturationMin..sub.saturationMax &&
                luminance.isFinite() && luminance in sub.luminanceMin..sub.luminanceMax
        }
        fun inputHue(value: Float): Float? = if (value.isFinite() && value in 0f..360f) {
            if (value == 360f) 0f else value.canonicalZero()
        } else null
        fun fromNumbers(hue: Double, saturation: Double, luminance: Double = 0.0): ColorGradingWheel {
            require(valid(hue, saturation, luminance))
            // 先检查源 Double，再处理合法值在 Float 边界的舍入环回。
            return ColorGradingWheel(
                hue.toFloat().let { if (it == 360f) 0f else it.canonicalZero() },
                saturation.toFloat().canonicalZero(),
                luminance.toFloat().canonicalZero(),
            )
        }
    }
}

data class ColorGradingSettings(
    val shadows: ColorGradingWheel = ColorGradingWheel(),
    val midtones: ColorGradingWheel = ColorGradingWheel(),
    val highlights: ColorGradingWheel = ColorGradingWheel(),
    val global: ColorGradingWheel = ColorGradingWheel(),
    val blending: Float = 50f,
    val balance: Float = 0f,
) {
    init {
        require(blending.isFinite() && blending in 0f..100f && balance.isFinite() && balance in -100f..100f)
    }
    val isDefault get() = ColorGradingZone.entries.all { this[it].isDefault } &&
        global.isDefault && blending == 50f && balance == 0f
    val isIdentity get() = ColorGradingZone.entries.all { this[it].isIdentity } && global.isIdentity
    val hasV2Extensions get() = ColorGradingZone.entries.any { this[it].luminance != 0f } ||
        !global.isDefault || blending != 50f || balance != 0f
    val progress get() = maxOf(
        ColorGradingZone.entries.maxOf { maxOf(this[it].saturation, abs(this[it].luminance)) },
        maxOf(global.saturation, abs(global.luminance)),
    ) / 100f
    fun scaled(strength: Float) = ColorGradingZone.entries.fold(
        copy(global = global.scaled(strength))
    ) { result, zone ->
        result.with(zone, this[zone].scaled(strength))
    }
    operator fun get(zone: ColorGradingZone) = when (zone) {
        ColorGradingZone.SHADOWS -> shadows; ColorGradingZone.MIDTONES -> midtones; ColorGradingZone.HIGHLIGHTS -> highlights
    }
    fun with(zone: ColorGradingZone, wheel: ColorGradingWheel) = when (zone) {
        ColorGradingZone.SHADOWS -> copy(shadows = wheel)
        ColorGradingZone.MIDTONES -> copy(midtones = wheel)
        ColorGradingZone.HIGHLIGHTS -> copy(highlights = wheel)
    }
}

data class ColorGradingDrag(val initial: ColorGradingWheel, val x: Float, val y: Float, val fine: Boolean) {
    fun value(nextX: Float, nextY: Float): ColorGradingWheel {
        if (!fine) return initial.moving(nextX, nextY)
        if (nextX == x && nextY == y) return initial
        return initial.moving(initial.point.first + (nextX - x) * .25f, initial.point.second + (nextY - y) * .25f)
    }
}
