package com.rawlab.android

import androidx.exifinterface.media.ExifInterface
import androidx.exifinterface.media.ExifInterface.*
import java.io.File
import java.util.Locale

/** Metadata shown by the editor without decoding the RAW image. */
internal data class PhotoInfo(
    val fileName: String,
    val captureTime: String? = null,
    val orientationCorrection: String? = null,
    val originalWidth: Int? = null,
    val originalHeight: Int? = null,
    val camera: String? = null,
    val lens: String? = null,
    val shutter: String? = null,
    val aperture: String? = null,
    val iso: String? = null,
    val focalLength: String? = null,
)

internal object PhotoInfoReader {
    fun read(file: File, fileName: String = file.name): PhotoInfo {
        val exif = ExifInterface(file)
        val capture = first(exif, TAG_DATETIME_ORIGINAL, TAG_DATETIME, TAG_DATETIME_DIGITIZED)
        val offset = first(exif, TAG_OFFSET_TIME_ORIGINAL, TAG_OFFSET_TIME, TAG_OFFSET_TIME_DIGITIZED)
        val captureTime = capture?.let { value ->
            if (offset.isNullOrBlank()) value else "$value $offset"
        }
        val storedWidth = positiveInt(exif, TAG_PIXEL_X_DIMENSION, TAG_IMAGE_WIDTH)
        val storedHeight = positiveInt(exif, TAG_PIXEL_Y_DIMENSION, TAG_IMAGE_LENGTH)
        val rotated = exif.rotationDegrees == 90 || exif.rotationDegrees == 270
        val width = if (rotated) storedHeight else storedWidth
        val height = if (rotated) storedWidth else storedHeight
        val make = first(exif, TAG_MAKE)
        val model = first(exif, TAG_MODEL)
        val lensMake = first(exif, TAG_LENS_MAKE)
        val lensModel = first(exif, TAG_LENS_MODEL)
        val exposure = exif.getAttributeDouble(TAG_EXPOSURE_TIME, Double.NaN)
        val fNumber = exif.getAttributeDouble(TAG_F_NUMBER, Double.NaN)
        val focal = exif.getAttributeDouble(TAG_FOCAL_LENGTH, Double.NaN)
        return PhotoInfo(
            fileName = fileName.ifBlank { file.name },
            captureTime = captureTime,
            orientationCorrection = orientation(exif),
            originalWidth = width,
            originalHeight = height,
            camera = joinDistinct(make, model),
            lens = joinDistinct(lensMake, lensModel),
            shutter = ExportMetadata.shutter(exposure),
            aperture = ExportMetadata.aperture(fNumber),
            iso = iso(exif),
            focalLength = if (focal.isFinite() && focal > 0) {
                String.format(Locale.ROOT, "%.1f mm", focal)
            } else null,
        )
    }

    private fun first(exif: ExifInterface, vararg tags: String): String? = tags.asSequence()
        .mapNotNull { exif.getAttribute(it)?.trim()?.takeIf(String::isNotEmpty) }
        .firstOrNull()

    private fun positiveInt(exif: ExifInterface, vararg tags: String): Int? = tags.asSequence()
        .mapNotNull { tag -> exif.getAttributeInt(tag, 0).takeIf { it > 0 } }
        .firstOrNull()

    private fun iso(exif: ExifInterface): String? {
        for (tag in arrayOf(TAG_PHOTOGRAPHIC_SENSITIVITY, TAG_ISO_SPEED)) {
            val value = first(exif, tag) ?: continue
            val number = exif.getAttributeDouble(tag, Double.NaN)
            if (number.isFinite() && number > 0) {
                return if (number % 1 == 0.0) number.toInt().toString() else value
            }
        }
        return null
    }

    private fun joinDistinct(first: String?, second: String?): String? {
        val values = listOfNotNull(first, second).filter { it.isNotBlank() }
        if (values.isEmpty()) return null
        return values.distinctBy { it.lowercase(Locale.ROOT) }.joinToString(" ")
    }

    private fun orientation(exif: ExifInterface): String? {
        val value = exif.getAttributeInt(TAG_ORIENTATION, ORIENTATION_UNDEFINED)
        if (value == ORIENTATION_UNDEFINED) return null
        val degrees = exif.rotationDegrees
        val flipped = exif.isFlipped
        return when {
            flipped && degrees != 0 -> "水平翻转，旋转 ${degrees}°"
            flipped -> "水平翻转"
            degrees != 0 -> "旋转 ${degrees}°"
            value == ORIENTATION_NORMAL -> "无需修正"
            else -> null
        }
    }
}
