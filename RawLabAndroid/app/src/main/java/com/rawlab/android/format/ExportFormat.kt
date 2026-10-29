package com.rawlab.android.format

enum class ExportFormat(
    val extension: String,
    val mimeType: String,
    val nativeValue: Int,
    val allowsGallery: Boolean,
) {
    JPEG("jpg", "image/jpeg", 0, true),
    HDR_JPEG("jpg", "image/jpeg", -1, true),
    PNG("png", "image/png", 1, true),
    DNG("dng", "image/x-adobe-dng", 4, false),
    ;

    val suffix: String get() = ".${extension}"

    companion object {
        fun available(hdrEditing: Boolean) = entries.filter { it != HDR_JPEG || hdrEditing }
        fun fromNativeValue(value: Int): ExportFormat = values().firstOrNull { it.nativeValue == value }
            ?: throw IllegalArgumentException("Unsupported export format: $value")

        fun fromPersisted(value: String?): ExportFormat = values().firstOrNull {
            it.name.equals(value, ignoreCase = true) || it.extension.equals(value, ignoreCase = true)
        } ?: throw IllegalArgumentException("Unsupported export format: $value")
    }
}
