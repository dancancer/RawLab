package com.rawlab.android.camera

import java.util.Locale

internal enum class CameraShootingParameter(val code: Int) {
    SHUTTER(0xd20d), APERTURE(0x5007), ISO(0xd21e), EV(0x5010),
    WHITE_BALANCE(0x5005), FOCUS(0x500a), TEMPERATURE(0xd20f)
}

/** 保留相机枚举中的完整 raw 值；显示换算不参与写入。 */
internal fun formatCameraParameter(code: Int, value: Long, auto: String = "Auto"): String = when (code) {
    0xd20d -> {
        val numerator = value ushr 16 and 0xffff
        val denominator = value and 0xffff
        when {
            value == 0L -> "Bulb"
            denominator == 0L -> "0x${value.toString(16).uppercase(Locale.ROOT)}"
            numerator % denominator == 0L -> "${numerator / denominator} s"
            else -> "$numerator/$denominator s"
        }
    }
    0x5007 -> "f/" + String.format(Locale.ROOT, "%.1f", value / 100.0)
    0xd21e, 0xd226 -> {
        val sensitivity = value and 0xffffff
        val base = if (sensitivity == 0xffffffL) auto else sensitivity.toString()
        base + when (val mode = value ushr 24) {
            0L -> ""
            1L -> " · MFNR"
            2L -> " · MFNR+"
            else -> ""
        }
    }
    0x5010 -> String.format(Locale.ROOT, if (value > 0) "+%.1f EV" else "%.1f EV", value / 1000.0)
    0xd20f -> "$value K"
    0x500a -> when (value) {
        1L -> "MF"; 2L -> "AF"; 0x8004L -> "AF-C"; 0x8005L -> "AF-A"; 0x8006L -> "DMF"; 0x8008L -> "AF-D"
        else -> "0x${value.toString(16).uppercase(Locale.ROOT)}"
    }
    0x5005 -> when (value) { 2L -> "AWB"; else -> "0x${value.toString(16).uppercase(Locale.ROOT)}" }
    else -> value.toString()
}
