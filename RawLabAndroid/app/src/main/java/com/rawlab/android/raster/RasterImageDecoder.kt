package com.rawlab.android.raster

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ColorSpace
import android.graphics.Matrix
import android.os.Build
import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import kotlin.math.min

// ============================================================================
//  普通图像解码：方向、色彩空间与像素上限
// ============================================================================

internal data class DecodedRaster(val width: Int, val height: Int, val pixels: ByteArray)

internal object RasterImageDecoder {
    private const val MAX_PIXELS = 64_000_000L

    fun decode(file: File): DecodedRaster {
        val validation = file.inputStream().use(RasterContainerValidator::inspect)
        val info = validation.info ?: throw IOException(validation.error ?: "Unsupported raster image")
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        // decodeFile returns null for a bounds-only request on some API levels; out* is the contract.
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0)
            throw IOException("Unable to decode image")
        if (bounds.outWidth != info.width || bounds.outHeight != info.height)
            throw IOException("Image dimensions changed during decode")
        if (bounds.outWidth.toLong() * bounds.outHeight > MAX_PIXELS) throw IOException("Image is too large")
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
        try {
            if (bitmap.config != Bitmap.Config.ARGB_8888 || bitmap.width != info.width || bitmap.height != info.height)
                throw IOException("Image is not an 8-bit RGB image")
            if (Build.VERSION.SDK_INT >= 26 && bitmap.colorSpace?.isSrgb != true)
                throw IOException("Image color space is not supported")
            if (Build.VERSION.SDK_INT >= 34 && bitmap.hasGainmap())
                throw IOException("HDR gain maps are not supported")
            if (info.mayContainAlpha && !isOpaque(bitmap)) throw IOException("Transparent PNG is not supported")
            val oriented = orient(bitmap, file)
            try {
                val bytes = ByteArray(oriented.width * oriented.height * 4)
                oriented.copyPixelsToBuffer(ByteBuffer.wrap(bytes))
                return DecodedRaster(oriented.width, oriented.height, bytes)
            } finally { if (oriented !== bitmap) oriented.recycle() }
        } finally { bitmap.recycle() }
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
