package com.rawlab.android

import android.graphics.BitmapFactory
import androidx.exifinterface.media.ExifInterface
import androidx.exifinterface.media.ExifInterface.*
import java.io.File
import java.util.Locale
import kotlin.math.abs
import kotlin.math.round

internal object ExportMetadata {
    // Only capture metadata belongs on rendered pixels, not RAW layout or preview thumbnails.
    private val captureTags = listOf(
        TAG_MAKE, TAG_MODEL, TAG_ARTIST, TAG_COPYRIGHT, TAG_IMAGE_DESCRIPTION,
        TAG_DATETIME, TAG_DATETIME_ORIGINAL, TAG_DATETIME_DIGITIZED,
        TAG_SUBSEC_TIME, TAG_SUBSEC_TIME_ORIGINAL, TAG_SUBSEC_TIME_DIGITIZED,
        TAG_OFFSET_TIME, TAG_OFFSET_TIME_ORIGINAL, TAG_OFFSET_TIME_DIGITIZED,
        TAG_CAMERA_OWNER_NAME, TAG_BODY_SERIAL_NUMBER,
        TAG_LENS_MAKE, TAG_LENS_MODEL, TAG_LENS_SPECIFICATION, TAG_LENS_SERIAL_NUMBER,
        TAG_EXPOSURE_TIME, TAG_F_NUMBER, TAG_EXPOSURE_PROGRAM,
        TAG_PHOTOGRAPHIC_SENSITIVITY, TAG_SENSITIVITY_TYPE,
        TAG_STANDARD_OUTPUT_SENSITIVITY, TAG_RECOMMENDED_EXPOSURE_INDEX, TAG_ISO_SPEED,
        TAG_SHUTTER_SPEED_VALUE, TAG_APERTURE_VALUE, TAG_BRIGHTNESS_VALUE,
        TAG_EXPOSURE_BIAS_VALUE, TAG_MAX_APERTURE_VALUE, TAG_SUBJECT_DISTANCE,
        TAG_METERING_MODE, TAG_LIGHT_SOURCE, TAG_FLASH, TAG_FOCAL_LENGTH,
        TAG_FOCAL_LENGTH_IN_35MM_FILM, TAG_EXPOSURE_MODE, TAG_WHITE_BALANCE,
        TAG_DIGITAL_ZOOM_RATIO, TAG_SCENE_CAPTURE_TYPE, TAG_GAIN_CONTROL,
        TAG_CONTRAST, TAG_SATURATION, TAG_SHARPNESS, TAG_SUBJECT_DISTANCE_RANGE,
        TAG_USER_COMMENT, TAG_IMAGE_UNIQUE_ID,
        TAG_GPS_VERSION_ID, TAG_GPS_LATITUDE_REF, TAG_GPS_LATITUDE,
        TAG_GPS_LONGITUDE_REF, TAG_GPS_LONGITUDE, TAG_GPS_ALTITUDE_REF, TAG_GPS_ALTITUDE,
        TAG_GPS_TIMESTAMP, TAG_GPS_DATESTAMP, TAG_GPS_SATELLITES, TAG_GPS_STATUS,
        TAG_GPS_MEASURE_MODE, TAG_GPS_DOP, TAG_GPS_SPEED_REF, TAG_GPS_SPEED,
        TAG_GPS_TRACK_REF, TAG_GPS_TRACK, TAG_GPS_IMG_DIRECTION_REF, TAG_GPS_IMG_DIRECTION,
        TAG_GPS_MAP_DATUM, TAG_GPS_PROCESSING_METHOD, TAG_GPS_AREA_INFORMATION,
        TAG_GPS_DIFFERENTIAL, TAG_GPS_H_POSITIONING_ERROR,
    )

    fun preserve(input: File, output: File) {
        require(input.canonicalPath != output.canonicalPath)
        val source = ExifInterface(input)
        val destination = ExifInterface(output)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(output.path, bounds)
        check(bounds.outWidth > 0 && bounds.outHeight > 0) { "Cannot read exported image dimensions" }
        for (tag in captureTags) {
            source.getAttribute(tag)?.let { destination.setAttribute(tag, it) }
        }
        aperture(source.getAttributeDouble(TAG_F_NUMBER, Double.NaN))?.let {
            destination.setAttribute(TAG_F_NUMBER, it)
        }
        shutter(source.getAttributeDouble(TAG_EXPOSURE_TIME, Double.NaN))?.let {
            destination.setAttribute(TAG_EXPOSURE_TIME, it)
        }
        destination.setAttribute(TAG_ORIENTATION, ORIENTATION_NORMAL.toString())
        destination.setAttribute(TAG_IMAGE_WIDTH, bounds.outWidth.toString())
        destination.setAttribute(TAG_IMAGE_LENGTH, bounds.outHeight.toString())
        destination.setAttribute(TAG_PIXEL_X_DIMENSION, bounds.outWidth.toString())
        destination.setAttribute(TAG_PIXEL_Y_DIMENSION, bounds.outHeight.toString())
        destination.setAttribute(TAG_COLOR_SPACE, "1")
        destination.setAttribute(TAG_SOFTWARE, "RawLab")
        destination.saveAttributes()
    }

    internal fun aperture(value: Double): String? =
        if (value.isFinite() && value > 0) String.format(Locale.ROOT, "%.1f", value) else null

    internal fun shutter(seconds: Double): String? {
        if (!seconds.isFinite() || seconds <= 0) return null
        if (seconds < 1) {
            val denominator = round(1 / seconds)
            if (denominator <= Int.MAX_VALUE && abs(seconds * denominator - 1) < 1e-6) {
                return "1/${denominator.toInt()}"
            }
        }
        return seconds.toString()
    }
}
