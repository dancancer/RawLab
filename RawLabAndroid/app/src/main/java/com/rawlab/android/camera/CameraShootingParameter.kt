package com.rawlab.android.camera

import com.rawlab.android.camera.protocol.SonyTetherSession
import java.util.Locale

internal enum class CameraShootingParameter(val code: Int) {
    SHUTTER(0xd20d), APERTURE(0x5007), ISO(0xd21e), EV(0x5010),
    WHITE_BALANCE(0x5005), FOCUS(0x500a), FOCUS_AREA(0xd22c), TEMPERATURE(0xd20f)
}

internal data class CameraFocusTap(val u: Float, val v: Float, val x: Int, val y: Int)

internal data class CameraOverlayBox(
    val x: Float,
    val y: Float,
    val width: Float,
    val height: Float,
    val normalizedSquare: Boolean,
)

private fun frameKindCode(kind: SonyTetherSession.LiveViewFrameKind): Int = when (kind) {
    SonyTetherSession.LiveViewFrameKind.FOCUS -> 0
    SonyTetherSession.LiveViewFrameKind.FACE -> 1
    SonyTetherSession.LiveViewFrameKind.TRACKING -> 2
}

internal fun computeFocusOverlayBox(
    frame: SonyTetherSession.LiveViewFocusFrame,
    left: Float,
    top: Float,
    fittedWidth: Float,
    fittedHeight: Float,
): CameraOverlayBox {
    val box = SonyCameraNative.nativeFocusOverlayBox(
        frameKindCode(frame.kind),
        frame.focused,
        frame.cx.toDouble(),
        frame.cy.toDouble(),
        frame.width.toDouble(),
        frame.height.toDouble(),
        left.toDouble(),
        top.toDouble(),
        fittedWidth.toDouble(),
        fittedHeight.toDouble(),
    )
    return CameraOverlayBox(
        x = box[0].toFloat(),
        y = box[1].toFloat(),
        width = box[2].toFloat(),
        height = box[3].toFloat(),
        normalizedSquare = box[4] != 0.0,
    )
}

internal fun normalizedFocusSquareRatio(
    frame: SonyTetherSession.LiveViewFocusFrame,
    imageWidth: Int,
    imageHeight: Int,
): Float? {
    if (imageWidth <= 0 || imageHeight <= 0) return null
    val ratio = SonyCameraNative.nativeNormalizedFocusSquareRatio(
        frameKindCode(frame.kind),
        frame.width.toDouble(),
        frame.height.toDouble(),
        imageWidth.toDouble(),
        imageHeight.toDouble(),
    )
    return if (ratio.isNaN()) null else ratio.toFloat()
}

internal fun computeTapFocusSide(
    fittedWidth: Float,
    fittedHeight: Float,
    minDefaultPx: Float,
    maxDefaultPx: Float,
    minLearnedPx: Float,
    lastSquareRatio: Float? = null,
): Float = SonyCameraNative.nativeTapFocusSide(
    fittedWidth.toDouble(),
    fittedHeight.toDouble(),
    minDefaultPx.toDouble(),
    maxDefaultPx.toDouble(),
    minLearnedPx.toDouble(),
    lastSquareRatio != null && lastSquareRatio.isFinite() && lastSquareRatio > 0f,
    lastSquareRatio?.toDouble() ?: 0.0,
).toFloat()

internal fun mapViewfinderTapToCameraGrid(
    tapX: Float,
    tapY: Float,
    containerWidth: Float,
    containerHeight: Float,
    imageWidth: Int,
    imageHeight: Int,
): CameraFocusTap? {
    val tap = SonyCameraNative.nativeFocusPointFromTap(
        tapX.toDouble(),
        tapY.toDouble(),
        containerWidth.toDouble(),
        containerHeight.toDouble(),
        imageWidth.toDouble(),
        imageHeight.toDouble(),
    ) ?: return null
    return CameraFocusTap(
        u = tap[0].toFloat(),
        v = tap[1].toFloat(),
        x = tap[2].toInt(),
        y = tap[3].toInt(),
    )
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
    0xd22c -> when (value) {
        0x0001L -> "Wide"
        0x0002L -> "Zone"
        0x0003L -> "Center"
        0x0101L -> "Spot S"
        0x0102L -> "Spot M"
        0x0103L -> "Spot L"
        0x0104L -> "Expand Spot"
        0x0201L -> "Tracking: Wide"
        0x0202L -> "Tracking: Zone"
        0x0203L -> "Tracking: Center"
        0x0204L -> "Tracking: Spot S"
        0x0205L -> "Tracking: Spot M"
        0x0206L -> "Tracking: Spot L"
        0x0207L -> "Tracking: Expand Spot"
        else -> String.format(Locale.ROOT, "0x%04X", value)
    }
    0x5005 -> when (value) { 2L -> "AWB"; else -> "0x${value.toString(16).uppercase(Locale.ROOT)}" }
    else -> value.toString()
}
