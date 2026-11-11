package com.rawlab.android.camera

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import kotlin.math.max
import kotlin.math.roundToInt

internal data class CameraProcessedFile(val size: Long, val digest: String)

/** JPEG processing happens only after the source has been downloaded and hashed. */
internal object CameraJPEGProcessing {
    fun process(source: File, destination: File, options: CameraJPEGOptions): CameraProcessedFile {
        if (!options.isValid) throw IOException("Invalid incremental JPEG options")
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(source.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw IOException("Cannot decode camera JPEG")
        val requested = options.longEdge ?: max(bounds.outWidth, bounds.outHeight)
        val scale = minOf(1f, requested.toFloat() / max(bounds.outWidth, bounds.outHeight))
        val targetWidth = (bounds.outWidth * scale).roundToInt().coerceAtLeast(1)
        val targetHeight = (bounds.outHeight * scale).roundToInt().coerceAtLeast(1)
        val decode = BitmapFactory.Options().apply {
            // Avoid decoding needlessly large source bitmaps while keeping a final
            // exact scale pass for the requested long edge.
            inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight, requested)
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val decoded = BitmapFactory.decodeFile(source.path, decode) ?: throw IOException("Cannot decode camera JPEG")
        val bitmap = if (decoded.width == targetWidth && decoded.height == targetHeight) decoded
            else Bitmap.createScaledBitmap(decoded, targetWidth, targetHeight, true).also { decoded.recycle() }
        try {
            destination.parentFile?.mkdirs()
            FileOutputStream(destination).use { output ->
                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, options.quality, output))
                    throw IOException("Cannot encode camera JPEG")
                output.fd.sync()
            }
            copyExif(source, destination)
            return hash(destination)
        } finally { bitmap.recycle() }
    }

    private fun sampleSize(width: Int, height: Int, longEdge: Int): Int {
        var sample = 1
        while (max(width / sample, height / sample) > longEdge * 2L && sample <= 4096) sample *= 2
        return sample
    }

    private fun copyExif(source: File, destination: File) {
        val input = runCatching { ExifInterface(source) }.getOrNull() ?: return
        val output = runCatching { ExifInterface(destination) }.getOrElse { throw IOException("Cannot open camera JPEG metadata", it) }
        val orientation = input.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        output.setAttribute(ExifInterface.TAG_ORIENTATION,
            (orientation.takeIf { it in 1..8 } ?: ExifInterface.ORIENTATION_NORMAL).toString())
        listOf(
            ExifInterface.TAG_DATETIME_ORIGINAL,
            ExifInterface.TAG_OFFSET_TIME_ORIGINAL,
            ExifInterface.TAG_DATETIME,
            ExifInterface.TAG_OFFSET_TIME,
            ExifInterface.TAG_MAKE,
            ExifInterface.TAG_MODEL,
            ExifInterface.TAG_LENS_MODEL,
        ).forEach { tag -> input.getAttribute(tag)?.let { output.setAttribute(tag, it) } }
        output.saveAttributes()
    }

    private fun hash(file: File): CameraProcessedFile {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return CameraProcessedFile(file.length(), digest.digest().joinToString("") { "%02x".format(it) })
    }
}
