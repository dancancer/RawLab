package com.rawlab.android.editor.render

import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.os.Build
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.rawlab.android.engine.HDRDisplayParameters
import com.rawlab.android.engine.HDRPreviewMode
import com.rawlab.android.engine.NativeHDRBridge
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.nio.ShortBuffer
import kotlin.math.abs

internal fun canRetainBitmap(
    previousWidth: Int,
    previousHeight: Int,
    nextWidth: Int,
    nextHeight: Int,
): Boolean {
    if (previousWidth <= 0 || previousHeight <= 0 || nextWidth <= 0 || nextHeight <= 0) return false
    val prevAspect = previousWidth.toDouble() / previousHeight.toDouble()
    val nextAspect = nextWidth.toDouble() / nextHeight.toDouble()
    return abs(prevAspect - nextAspect) <= 0.02 * maxOf(prevAspect, nextAspect)
}

// sony2fuji_hdr.h 中 sony2fuji_hdr_display_flag 的取值；AbiEnumMirrorTest 对照 ABI fixture 核对。
internal const val SONY2FUJI_HDR_DISPLAY_SDR = 1
internal const val SONY2FUJI_HDR_DISPLAY_FALSE_COLOR = 2
private const val DISPLAY_ROW_BAND = 16

/** Packs the float pair into an extended-range bitmap; it never labels ARGB_8888 as HDR. */
internal object HDRBitmapAdapter {
    @Composable
    fun rememberBitmap(
        frame: HDRPreviewFrame?,
        parameters: HDRDisplayParameters,
        enabled: Boolean,
        resetKey: Any? = null,
    ): Bitmap? {
        var retained by remember(resetKey) { mutableStateOf<Bitmap?>(null) }
        LaunchedEffect(frame, parameters, enabled, resetKey) {
            if (!enabled || frame == null) {
                retained = null
                return@LaunchedEffect
            }
            retained?.let { previous ->
                if (!canRetainBitmap(previous.width, previous.height, frame.width, frame.height)) {
                    retained = null
                }
            }
            retained = withContext(Dispatchers.Default) {
                val context = coroutineContext
                HDRBitmapAdapter.bitmap(frame, parameters) { context.ensureActive() }
            }
        }
        return if (enabled && frame != null) retained else null
    }

    fun bitmap(frame: HDRPreviewFrame, parameters: HDRDisplayParameters, checkCancellation: () -> Unit = {}): Bitmap? {
        if (Build.VERSION.SDK_INT < 26) return null
        val packed = ShortArray(frame.width * frame.height * 4)
        // 线性扩展 sRGB、SDR 平面不夹取：与共享核心的默认显示约定一致，按行段映射以便及时取消。
        val flags = (if (parameters.mode == HDRPreviewMode.SDR) SONY2FUJI_HDR_DISPLAY_SDR else 0) or
            (if (parameters.falseColor) SONY2FUJI_HDR_DISPLAY_FALSE_COLOR else 0)
        var row = 0
        while (row < frame.height) {
            checkCancellation()
            val rows = minOf(DISPLAY_ROW_BAND, frame.height - row)
            if (!NativeHDRBridge.displayRows(frame.hdr, frame.sdr, frame.width, frame.height, row, rows,
                    parameters.safeHeadroom, frame.contentHeadroom, flags, packed)) return null
            row += rows
        }
        return runCatching {
            Bitmap.createBitmap(frame.width, frame.height, Bitmap.Config.RGBA_F16, true,
                ColorSpace.get(ColorSpace.Named.LINEAR_EXTENDED_SRGB)).also { it.copyPixelsFromBuffer(ShortBuffer.wrap(packed)) }
        }.getOrNull()
    }
}
