package com.rawlab.android.editor.render

import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.os.Build
import com.rawlab.android.engine.HDRDisplayMath
import com.rawlab.android.engine.HDRDisplayParameters
import java.nio.ShortBuffer
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.ensureActive

/** Packs the float pair into an extended-range bitmap; it never labels ARGB_8888 as HDR. */
internal object HDRBitmapAdapter {
    @Composable
    fun rememberBitmap(frame: HDRPreviewFrame?, parameters: HDRDisplayParameters, enabled: Boolean): Bitmap? {
        val bitmap by produceState<Bitmap?>(null, frame, parameters, enabled) {
            value = null
            if (enabled && frame != null) value = withContext(Dispatchers.Default) {
                val context=coroutineContext
                HDRBitmapAdapter.bitmap(frame, parameters) { context.ensureActive() }
            }
        }
        return bitmap
    }
    fun bitmap(frame: HDRPreviewFrame, parameters: HDRDisplayParameters, checkCancellation: () -> Unit = {}): Bitmap? {
        if (Build.VERSION.SDK_INT < 26) return null
        var source = 0
        var output = 0
        val packed = ShortArray(frame.width * frame.height * 4)
        val color = FloatArray(3)
        val rgba = FloatArray(4)
        for (pixel in 0 until frame.width * frame.height) {
            if(pixel%frame.width==0)checkCancellation()
            HDRDisplayMath.pixelInto(frame.hdr, frame.sdr, source, frame.contentHeadroom, parameters, color)
            rgba[0] = color[0]; rgba[1] = color[1]; rgba[2] = color[2]; rgba[3] = 1f
            if (!HDRDisplayMath.packHalfInto(rgba, packed, output)) return null
            source += 3; output += 4
        }
        return runCatching {
            Bitmap.createBitmap(frame.width, frame.height, Bitmap.Config.RGBA_F16, true,
                ColorSpace.get(ColorSpace.Named.LINEAR_EXTENDED_SRGB)).also { it.copyPixelsFromBuffer(ShortBuffer.wrap(packed)) }
        }.getOrNull()
    }
}
