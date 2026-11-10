package com.rawlab.android.engine

import androidx.exifinterface.media.ExifInterface
import java.io.File

internal data class DisplayLensMetadata(
    val cameraMake: String = "", val cameraModel: String = "", val lensMake: String = "", val lensModel: String = "",
    val focalLength: Float = 0f, val aperture: Float = 0f, val cropFactor: Float = 0f, val sourceOrientation: Int = 1,
) {
    val names get() = arrayOf(cameraMake, cameraModel, lensMake, lensModel)
    val numbers get() = floatArrayOf(focalLength, aperture, cropFactor)
    companion object {
        fun read(file: File): DisplayLensMetadata {
            val exif = runCatching { ExifInterface(file) }.getOrNull() ?: return DisplayLensMetadata()
            fun name(tag: String, limit: Int) = exif.getAttribute(tag).orEmpty().trim().take(limit)
            fun number(tag: String) = exif.getAttributeDouble(tag, 0.0).toFloat().takeIf { it.isFinite() && it > 0 } ?: 0f
            return DisplayLensMetadata(name(ExifInterface.TAG_MAKE, 127), name(ExifInterface.TAG_MODEL, 127),
                name(ExifInterface.TAG_LENS_MAKE, 127), name(ExifInterface.TAG_LENS_MODEL, 255),
                number(ExifInterface.TAG_FOCAL_LENGTH), number(ExifInterface.TAG_F_NUMBER),
                sourceOrientation = exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, 1).takeIf { it in 1..8 } ?: 1)
        }
    }
}
