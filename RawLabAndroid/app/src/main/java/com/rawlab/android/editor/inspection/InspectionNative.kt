package com.rawlab.android.editor.inspection

import android.graphics.Bitmap

internal object InspectionNative {
    init {
        System.loadLibrary("rawlab-jni")
    }

    @JvmStatic
    external fun nativeInferSourceSize(
        outputWidth: Int,
        outputHeight: Int,
        cropX: Float,
        cropY: Float,
        cropWidth: Float,
        cropHeight: Float,
        quarterTurns: Int,
        flipHorizontal: Boolean,
        flipVertical: Boolean,
        straightenDegrees: Float,
        perspectiveHorizontal: Float,
        perspectiveVertical: Float,
    ): IntArray?

    @JvmStatic
    external fun nativeOutputNormToSourceNorm(
        sourceWidth: Int,
        sourceHeight: Int,
        cropX: Float,
        cropY: Float,
        cropWidth: Float,
        cropHeight: Float,
        quarterTurns: Int,
        flipHorizontal: Boolean,
        flipVertical: Boolean,
        straightenDegrees: Float,
        perspectiveHorizontal: Float,
        perspectiveVertical: Float,
        outX: Double,
        outY: Double,
    ): FloatArray?

    @JvmStatic
    external fun nativeSourceNormToOutputNorm(
        sourceWidth: Int,
        sourceHeight: Int,
        cropX: Float,
        cropY: Float,
        cropWidth: Float,
        cropHeight: Float,
        quarterTurns: Int,
        flipHorizontal: Boolean,
        flipVertical: Boolean,
        straightenDegrees: Float,
        perspectiveHorizontal: Float,
        perspectiveVertical: Float,
        srcX: Double,
        srcY: Double,
    ): FloatArray?

    @JvmStatic
    external fun nativeColorFromRgb(r: Int, g: Int, b: Int): DoubleArray?

    @JvmStatic
    external fun nativeSampleBitmapPatch(
        bitmap: Bitmap,
        normX: Double,
        normY: Double,
        radiusPx: Int,
    ): DoubleArray?

    @JvmStatic
    external fun nativeOverlayPixel(r: Int, g: Int, b: Int, mode: Int): Int

    @JvmStatic
    external fun nativeRenderOverlay(
        srcBitmap: Bitmap,
        dstBitmap: Bitmap,
        mode: Int,
    ): Boolean

    @JvmStatic
    external fun nativePointColorPreviewSwatch(
        srcHue: Float,
        srcSaturation: Float,
        srcLuminance: Float,
        hueShift: Float,
        saturationShift: Float,
        luminanceShift: Float,
    ): FloatArray?
}
