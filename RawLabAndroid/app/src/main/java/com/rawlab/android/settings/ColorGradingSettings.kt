package com.rawlab.android.settings

import kotlin.math.*

enum class ColorGradingZone(val id: String, val title: String) {
    SHADOWS("shadows", "阴影"), MIDTONES("midtones", "中间调"), HIGHLIGHTS("highlights", "高光")
}

data class ColorGradingWheel(val hue: Float = 0f, val saturation: Float = 0f) {
    init { require(valid(hue.toDouble(), saturation.toDouble())) }
    val isDefault get() = hue == 0f && saturation == 0f
    val isIdentity get() = saturation == 0f
    val point get() = (cos(hue.toDouble() * PI / 180) * saturation / 100).toFloat() to
        (sin(hue.toDouble() * PI / 180) * saturation / 100).toFloat()
    fun moving(x: Float, y: Float): ColorGradingWheel {
        if (!x.isFinite() || !y.isFinite()) return this
        val radius = hypot(x.toDouble(), y.toDouble())
        if (radius == 0.0) return copy(saturation = 0f)
        val angle = atan2(y.toDouble(), x.toDouble()) * 180 / PI
        return fromNumbers(if (angle < 0) (angle + 360) % 360 else angle, min(1.0, radius) * 100)
    }
    companion object {
        fun valid(hue: Double, saturation: Double) = hue.isFinite() && hue >= 0 && hue < 360 &&
            saturation.isFinite() && saturation in 0.0..100.0
        fun inputHue(value: Float): Float? = if (value.isFinite() && value in 0f..360f) {
            if (value == 360f) 0f else value.canonicalZero()
        } else null
        fun fromNumbers(hue: Double, saturation: Double): ColorGradingWheel {
            require(valid(hue, saturation))
            // 先检查源 Double，再处理合法值在 Float 边界的舍入环回。
            return ColorGradingWheel(hue.toFloat().let { if (it == 360f) 0f else it.canonicalZero() }, saturation.toFloat().canonicalZero())
        }
    }
}

data class ColorGradingSettings(
    val shadows: ColorGradingWheel = ColorGradingWheel(),
    val midtones: ColorGradingWheel = ColorGradingWheel(),
    val highlights: ColorGradingWheel = ColorGradingWheel(),
) {
    val isDefault get() = ColorGradingZone.entries.all { this[it].isDefault }
    val isIdentity get() = ColorGradingZone.entries.all { this[it].isIdentity }
    val progress get() = ColorGradingZone.entries.maxOf { this[it].saturation } / 100f
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
