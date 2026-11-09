package com.rawlab.android.camera

import androidx.exifinterface.media.ExifInterface
import java.io.File

internal object CameraCaptureDateReader {
    fun read(file: File): CameraCaptureDate? = runCatching {
        val exif = ExifInterface(file)
        // 通用 DateTime 可能是修改时间，不能用来为缺少拍摄时间的原片补日期。
        CameraCaptureDate.parse(exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL),
            exif.getAttribute(ExifInterface.TAG_OFFSET_TIME_ORIGINAL))
    }.getOrNull()
}
