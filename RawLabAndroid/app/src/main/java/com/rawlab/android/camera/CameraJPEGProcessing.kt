package com.rawlab.android.camera

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.exifinterface.media.ExifInterface
import com.rawlab.android.engine.HDRProcessingException
import com.rawlab.android.engine.NativeHDRBridge
import com.rawlab.android.photo.HDRSourceInfo
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import kotlin.math.max
import kotlin.math.roundToInt

internal data class CameraProcessedFile(val size: Long, val digest: String)

/** Android Bitmap.compress cannot retain a JPEG gain map; callers should publish the source bytes instead. */
internal class CameraJPEGGainMapAdjustmentException(
    val protocol: Int? = null,
    cause: Throwable? = null,
) : IOException("JPEG adjustment would discard HDR gain-map metadata", cause)

internal class CameraJPEGMemoryException(cause: Throwable? = null) :
    IOException("Insufficient memory to adjust camera JPEG", cause)

/** JPEG processing happens only after the source has been downloaded and hashed. */
internal object CameraJPEGProcessing {
    fun process(source: File, destination: File, options: CameraJPEGOptions): CameraProcessedFile =
        processWithProbe(source, destination, options, ::nativeGainMapProbe)

    internal fun processWithProbe(source: File, destination: File, options: CameraJPEGOptions,
        gainMapProbe: (File) -> HDRSourceInfo?): CameraProcessedFile {
        if (!options.isValid) throw IOException("Invalid incremental JPEG options")
        ensureAdjustmentSupported(source, gainMapProbe)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(source.path, bounds)
        if (bounds.outWidth !in 1..65_535 || bounds.outHeight !in 1..65_535)
            throw IOException("Cannot decode camera JPEG")
        val requested = options.longEdge ?: max(bounds.outWidth, bounds.outHeight)
        val scale = minOf(1f, requested.toFloat() / max(bounds.outWidth, bounds.outHeight))
        val targetWidth = (bounds.outWidth * scale).roundToInt().coerceAtLeast(1)
        val targetHeight = (bounds.outHeight * scale).roundToInt().coerceAtLeast(1)
        val sample = sampleSize(bounds.outWidth, bounds.outHeight, requested)
        val runtime = Runtime.getRuntime()
        val available = runtime.maxMemory() - (runtime.totalMemory() - runtime.freeMemory())
        if (requiredBitmapBytes(bounds.outWidth, bounds.outHeight, sample, targetWidth, targetHeight) > available / 2)
            throw CameraJPEGMemoryException()
        val decode = BitmapFactory.Options().apply {
            // Avoid decoding needlessly large source bitmaps while keeping a final
            // exact scale pass for the requested long edge.
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        try {
            val decoded = BitmapFactory.decodeFile(source.path, decode) ?: throw IOException("Cannot decode camera JPEG")
            try {
                val bitmap = if (decoded.width == targetWidth && decoded.height == targetHeight) decoded
                    else Bitmap.createScaledBitmap(decoded, targetWidth, targetHeight, true)
                try {
                    if (bitmap !== decoded) decoded.recycle()
                    destination.parentFile?.mkdirs()
                    FileOutputStream(destination).use { output ->
                        if (!bitmap.compress(Bitmap.CompressFormat.JPEG, options.quality, output))
                            throw IOException("Cannot encode camera JPEG")
                        output.fd.sync()
                    }
                    copyExif(source, destination)
                    return hash(destination)
                } finally { if (bitmap !== decoded) bitmap.recycle() }
            } finally { if (!decoded.isRecycled) decoded.recycle() }
        } catch (error: OutOfMemoryError) { throw CameraJPEGMemoryException(error) }
    }

    internal fun requiredBitmapBytes(width: Int, height: Int, sample: Int, targetWidth: Int, targetHeight: Int): Long {
        val decodedWidth = (width + sample - 1) / sample
        val decodedHeight = (height + sample - 1) / sample
        val decodedPixels = decodedWidth.toLong() * decodedHeight
        val scaledPixels = if (sample == 1 && width == targetWidth && height == targetHeight) 0L
            else targetWidth.toLong() * targetHeight
        return (decodedPixels + scaledPixels) * 4
    }

    internal fun ensureAdjustmentSupported(source: File) =
        ensureAdjustmentSupported(source, ::nativeGainMapProbe)

    internal fun ensureAdjustmentSupported(source: File, gainMapProbe: (File) -> HDRSourceInfo?) {
        val gainMap = try { probeGainMap(source, gainMapProbe) }
        catch (error: HDRProcessingException) {
            throw CameraJPEGGainMapAdjustmentException(cause = error)
        }
        if (gainMap != null) throw CameraJPEGGainMapAdjustmentException(gainMap.protocol)
    }

    /** Check the file signature before invoking the native gain-map probe. */
    internal fun probeGainMap(source: File, gainMapProbe: (File) -> HDRSourceInfo?): HDRSourceInfo? {
        if (!HDRSourceInfo.mayContainGainMap(source)) return null
        return gainMapProbe(source)
    }

    private fun nativeGainMapProbe(source: File): HDRSourceInfo? = NativeHDRBridge.probe(source)

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
