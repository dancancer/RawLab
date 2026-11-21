package com.rawlab.android.camera

import com.rawlab.android.camera.protocol.SonyTetherSession
import java.util.Locale
import kotlin.math.roundToInt

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

internal fun computeFocusOverlayBox(
    frame: SonyTetherSession.LiveViewFocusFrame,
    left: Float,
    top: Float,
    fittedWidth: Float,
    fittedHeight: Float,
): CameraOverlayBox {
    val rawW = frame.width * fittedWidth
    val rawH = frame.height * fittedHeight
    val cx = left + frame.cx * fittedWidth
    val cy = top + frame.cy * fittedHeight
    if (frame.kind != SonyTetherSession.LiveViewFrameKind.FACE && rawW > 0f && rawH > 0f) {
        val aspect = maxOf(rawW, rawH) / minOf(rawW, rawH)
        if (aspect <= 1.35f) {
            val side = (rawW + rawH) / 2f
            return CameraOverlayBox(
                x = cx - side / 2f,
                y = cy - side / 2f,
                width = side,
                height = side,
                normalizedSquare = true,
            )
        }
    }
    return CameraOverlayBox(
        x = cx - rawW / 2f,
        y = cy - rawH / 2f,
        width = rawW,
        height = rawH,
        normalizedSquare = false,
    )
}

internal fun normalizedFocusSquareRatio(
    frame: SonyTetherSession.LiveViewFocusFrame,
    imageWidth: Int,
    imageHeight: Int,
): Float? {
    if (frame.kind == SonyTetherSession.LiveViewFrameKind.FACE || imageWidth <= 0 || imageHeight <= 0) {
        return null
    }
    val iw = imageWidth.toFloat()
    val ih = imageHeight.toFloat()
    val shortEdge = minOf(iw, ih)
    val w = frame.width * (iw / shortEdge)
    val h = frame.height * (ih / shortEdge)
    if (w <= 0f || h <= 0f || maxOf(w, h) / minOf(w, h) > 1.35f) {
        return null
    }
    return (w + h) / 2f
}

internal fun computeTapFocusSide(
    fittedWidth: Float,
    fittedHeight: Float,
    minDefaultPx: Float,
    maxDefaultPx: Float,
    minLearnedPx: Float,
    lastSquareRatio: Float? = null,
): Float {
    val shortEdge = minOf(fittedWidth, fittedHeight)
    if (!shortEdge.isFinite() || shortEdge <= 0f) return minDefaultPx
    if (lastSquareRatio != null && lastSquareRatio.isFinite() && lastSquareRatio > 0f) {
        return (shortEdge * lastSquareRatio).coerceIn(minLearnedPx, maxOf(minLearnedPx, shortEdge * 0.5f))
    }
    return (shortEdge * 0.138f).coerceIn(minDefaultPx, maxOf(minDefaultPx, maxDefaultPx))
}

internal fun mapViewfinderTapToCameraGrid(
    tapX: Float,
    tapY: Float,
    containerWidth: Float,
    containerHeight: Float,
    imageWidth: Int,
    imageHeight: Int,
): CameraFocusTap? {
    if (!tapX.isFinite() || !tapY.isFinite() || !containerWidth.isFinite() || !containerHeight.isFinite() ||
        containerWidth <= 0f || containerHeight <= 0f || imageWidth <= 0 || imageHeight <= 0
    ) {
        return null
    }
    val iw = imageWidth.toFloat()
    val ih = imageHeight.toFloat()
    val scale = minOf(containerWidth / iw, containerHeight / ih)
    val fittedWidth = iw * scale
    val fittedHeight = ih * scale
    val left = (containerWidth - fittedWidth) / 2f
    val top = (containerHeight - fittedHeight) / 2f
    if (tapX < left || tapX > left + fittedWidth || tapY < top || tapY > top + fittedHeight) {
        return null
    }
    val u = ((tapX - left) / fittedWidth).coerceIn(0f, 1f)
    val v = ((tapY - top) / fittedHeight).coerceIn(0f, 1f)
    val x = (u * 640f).roundToInt().coerceIn(0, 639)
    val y = (v * 480f).roundToInt().coerceIn(0, 479)
    return CameraFocusTap(u = u, v = v, x = x, y = y)
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
