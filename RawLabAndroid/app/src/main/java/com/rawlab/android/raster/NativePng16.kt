package com.rawlab.android.raster

import android.graphics.ColorSpace
import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs

internal object NativePng16 {
    init { System.loadLibrary("rawlab-jni") }

    fun decode(file: File, info: RasterContainerInfo, space: ColorSpace?): DecodedRaster {
        val orientation = runCatching { ExifInterface(file).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1) }
            .getOrDefault(1).takeIf { it in 1..8 } ?: 1
        val pixels = nativeDecode(file.path, info.width, info.height, orientation).order(ByteOrder.LITTLE_ENDIAN)
        try {
            // 平台只用于识别与转换色彩空间；PNG 整数采样不能先经过 ARGB_8888 或 RGBA_F16。
            if (space != null && !space.isSrgb) {
                convertToSrgb(pixels, space)
            }
            return DecodedRaster(pixels, if (orientation >= 5) info.height else info.width,
                if (orientation >= 5) info.width else info.height)
        } catch (error: Throwable) { release(pixels); throw error }
    }

    internal fun convertToSrgb(pixels: ByteBuffer, space: ColorSpace) {
        val source = space as? ColorSpace.Rgb ?: throw IOException("Image color space is not supported")
        val destination = ColorSpace.get(ColorSpace.Named.SRGB) as ColorSpace.Rgb
        val sameWhite = source.whitePoint.zip(destination.whitePoint).all { (a, b) -> abs(a - b) <= 1e-3f }
        // 与 Connector 的相对色度意图一致：白点不同时先 Bradford 适配到 D50。
        val d50 = floatArrayOf(0.964212f, 1f, 0.825188f)
        val from = if (sameWhite || source.whitePoint.zip(ColorSpace.ILLUMINANT_D50)
                .all { (a, b) -> abs(a - b) <= 1e-3f }) source
            else ColorSpace.adapt(source, d50) as ColorSpace.Rgb
        val to = if (sameWhite) destination else ColorSpace.adapt(destination, d50) as ColorSpace.Rgb
        val forward = from.transform
        val inverse = to.inverseTransform
        val matrix = FloatArray(9) { index ->
            val row = index % 3
            val column = index / 3 * 3
            inverse[row] * forward[column] + inverse[row + 3] * forward[column + 1] +
                inverse[row + 6] * forward[column + 2]
        }
        val decode = source.eotf
        val encode = destination.oetf
        // 每种传递函数只采样一次；逐像素的查表、矩阵和插值在原生缓冲内完成。
        val eotf = FloatArray(65536) { decode.applyAsDouble((it / 65535f).toDouble()).toFloat() }
        val oetf = FloatArray(65536) { encode.applyAsDouble(it / 65535.0).toFloat() }
        if ((eotf.asSequence() + oetf.asSequence() + matrix.asSequence()).any { !it.isFinite() })
            throw IOException("Image color space is not supported")
        nativeConvert(pixels, eotf, matrix, oetf)
    }

    fun release(pixels: ByteBuffer) = nativeRelease(pixels)
    private external fun nativeDecode(path: String, width: Int, height: Int, orientation: Int): ByteBuffer
    private external fun nativeConvert(pixels: ByteBuffer, eotf: FloatArray, matrix: FloatArray, oetf: FloatArray)
    private external fun nativeRelease(pixels: ByteBuffer)
}
