package com.rawlab.android.raster

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ColorSpace
import android.graphics.Matrix
import android.graphics.ImageDecoder
import android.os.Build
import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.io.IOException
import kotlin.math.min

// ============================================================================
//  普通图像解码：方向、色彩空间与像素上限
// ============================================================================

internal class DecodedRaster(val bitmap: Bitmap) : AutoCloseable {
    val width: Int get() = bitmap.width
    val height: Int get() = bitmap.height
    override fun close() = bitmap.recycle()
}

internal object RasterImageDecoder {
    fun decode(file: File): DecodedRaster {
        val heif=file.inputStream().use { input ->
            val header=ByteArray(12);input.read(header)==header.size && header.copyOfRange(4,8).contentEquals("ftyp".toByteArray(Charsets.US_ASCII))
        }
        if (heif) return decodeHEIF(file)
        val validation = file.inputStream().use(RasterContainerValidator::inspect)
        val info = validation.info ?: throw IOException(validation.error ?: "Unsupported raster image")
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        // decodeFile returns null for a bounds-only request on some API levels; out* is the contract.
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0)
            throw IOException("Unable to decode image")
        if (bounds.outWidth != info.width || bounds.outHeight != info.height)
            throw IOException("Image dimensions changed during decode")
        if (bounds.outWidth.toLong() * bounds.outHeight > RasterContainerValidator.MAX_PIXELS) throw IOException("Image is too large")
        if (info.hasColorProfile && bounds.outColorSpace == null)
            throw IOException("Image color space is not supported")
        if (Build.VERSION.SDK_INT >= 26 && !isSupportedSdrColorSpace(bounds.outColorSpace))
            throw IOException("Image color space is not supported")
        val options = BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inScaled = false
            if (Build.VERSION.SDK_INT >= 26) inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB)
        }
        val bitmap = BitmapFactory.decodeFile(file.path, options) ?: throw IOException("Unable to decode image")
        var oriented: Bitmap? = null
        try {
            if (bitmap.config != Bitmap.Config.ARGB_8888 || bitmap.width != info.width || bitmap.height != info.height)
                throw IOException("Image is not an 8-bit RGB image")
            if (Build.VERSION.SDK_INT >= 26 && bitmap.colorSpace?.isSrgb != true)
                throw IOException("Image color space is not supported")
            if (Build.VERSION.SDK_INT >= 34 && bitmap.hasGainmap())
                throw IOException("HDR gain maps are not supported")
            if (info.mayContainAlpha && !isOpaque(bitmap)) throw IOException("Transparent PNG is not supported")
            oriented = orient(bitmap, file)
            // 像素保留在 Bitmap 的原生内存，由 JNI 在处理期间锁定；不复制到受 Java 堆限制的整图数组。
            return DecodedRaster(oriented)
        } catch (error: Throwable) {
            oriented?.recycle()
            throw error
        } finally { if (oriented !== bitmap) bitmap.recycle() }
    }

    private fun decodeHEIF(file: File): DecodedRaster {
        // 只有原生探测确认 NOT_HDR 后才允许平台解码器处理普通 HEIF。
        if (com.rawlab.android.engine.NativeHDRBridge.probe(file) != null)
            throw IOException("HDR sources require the HDR decoder")
        if (Build.VERSION.SDK_INT < 28) throw IOException("SDR HEIF requires Android 9 or later")
        val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
            if (info.size.width.toLong() * info.size.height > RasterContainerValidator.MAX_PIXELS)
                throw IOException("Image is too large")
            if (!isSupportedSdrColorSpace(info.colorSpace)) throw IOException("Image color space is not supported")
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
            decoder.setOnPartialImageListener { false }
        }
        try {
            if (bitmap.config != Bitmap.Config.ARGB_8888 || bitmap.colorSpace?.isSrgb != true ||
                (Build.VERSION.SDK_INT >= 34 && bitmap.hasGainmap()) || !isOpaque(bitmap))
                throw IOException("Unsupported HEIF pixels")
            // ImageDecoder 已应用容器方向，不能再次应用 EXIF。
            return DecodedRaster(bitmap)
        } catch (error: Throwable) { bitmap.recycle(); throw error }
    }

    private fun isOpaque(bitmap: Bitmap): Boolean {
        val row = IntArray(min(bitmap.width, 4096))
        var y = 0
        while (y < bitmap.height) {
            var x = 0
            while (x < bitmap.width) {
                val count = min(row.size, bitmap.width - x)
                bitmap.getPixels(row, 0, count, x, y, count, 1)
                for (i in 0 until count) if (row[i] ushr 24 != 0xFF) return false
                x += count
            }
            y++
        }
        return true
    }

    private fun orient(bitmap: Bitmap, file: File): Bitmap {
        val exif = runCatching { ExifInterface(file) }.getOrNull() ?: return bitmap
        val rotation = exif.rotationDegrees
        val flipped = exif.isFlipped
        if (!flipped && rotation == 0) return bitmap
        val matrix = Matrix().apply {
            if (flipped) postScale(-1f, 1f)
            if (rotation != 0) postRotate(rotation.toFloat())
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
            ?: throw IOException("Unable to apply image orientation")
    }

    private fun isSupportedSdrColorSpace(space: ColorSpace?): Boolean {
        if (space == null || space.isSrgb) return true // Untagged RGB assumes sRGB.
        if (space.model != ColorSpace.Model.RGB) return false
        val name = space.name.lowercase()
        if (name.contains("pq") || name.contains("hlg") || name.contains("extended") ||
            name.contains("linear") || name.contains("bt2020")) return false
        return listOf("display p3", "dci-p3", "adobe rgb", "bt.709", "bt709", "smpte c",
            "ntsc", "prophoto").any(name::contains)
    }
}
