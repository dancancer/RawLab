package com.rawlab.android.raster

import android.graphics.ColorSpace
import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

internal object NativePng16 {
    init { System.loadLibrary("rawlab-jni") }

    fun decode(file: File, info: RasterContainerInfo, space: ColorSpace?): DecodedRaster {
        val orientation = runCatching { ExifInterface(file).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1) }
            .getOrDefault(1).takeIf { it in 1..8 } ?: 1
        val pixels = nativeDecode(file.path, info.width, info.height, orientation).order(ByteOrder.LITTLE_ENDIAN)
        try {
            // 平台只用于识别与转换色彩空间；PNG 整数采样不能先经过 ARGB_8888 或 RGBA_F16。
            if (space != null && !space.isSrgb) {
                val connector = ColorSpace.connect(space, ColorSpace.get(ColorSpace.Named.SRGB))
                val rgb = FloatArray(3)
                var offset = 0
                while (offset < pixels.capacity()) {
                    for (c in 0..2) rgb[c] = (pixels.getShort(offset + c * 2).toInt() and 65535) / 65535f
                    connector.transform(rgb)
                    for (c in 0..2) {
                        if (!rgb[c].isFinite()) throw IOException("Image color space is not supported")
                        pixels.putShort(offset + c * 2, (rgb[c].coerceIn(0f, 1f) * 65535).roundToInt().toShort())
                    }
                    offset += 8
                }
            }
            return DecodedRaster(pixels, if (orientation >= 5) info.height else info.width,
                if (orientation >= 5) info.width else info.height)
        } catch (error: Throwable) { release(pixels); throw error }
    }

    fun release(pixels: ByteBuffer) = nativeRelease(pixels)
    private external fun nativeDecode(path: String, width: Int, height: Int, orientation: Int): ByteBuffer
    private external fun nativeRelease(pixels: ByteBuffer)
}
