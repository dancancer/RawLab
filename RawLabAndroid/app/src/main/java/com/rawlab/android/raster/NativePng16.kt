package com.rawlab.android.raster

import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal object NativePng16 {
    init { System.loadLibrary("rawlab-jni") }

    fun decode(file: File, info: RasterContainerInfo): DecodedRaster {
        val orientation = runCatching { ExifInterface(file).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1) }
            .getOrDefault(1).takeIf { it in 1..8 } ?: 1
        val pixels = nativeDecode(file.path, info.width, info.height, orientation).order(ByteOrder.LITTLE_ENDIAN)
        try {
            if (info.iccProfile != null) {
                convertToSrgb(pixels, info.iccProfile)
            }
            return DecodedRaster(pixels, if (orientation >= 5) info.height else info.width,
                if (orientation >= 5) info.width else info.height)
        } catch (error: Throwable) { release(pixels); throw error }
    }

    internal fun convertToSrgb(pixels: ByteBuffer, iccProfile: ByteArray) {
        nativeConvert(pixels, iccProfile)
    }

    fun release(pixels: ByteBuffer) = nativeRelease(pixels)
    private external fun nativeDecode(path: String, width: Int, height: Int, orientation: Int): ByteBuffer
    private external fun nativeConvert(pixels: ByteBuffer, iccProfile: ByteArray)
    private external fun nativeRelease(pixels: ByteBuffer)
}
