package com.rawlab.android.photo

/** Source metadata returned by sony2fuji_hdr_probe; the fingerprint is part of HDR identity. */
data class HDRSourceInfo(
    val width: Int,
    val height: Int,
    val orientation: Int,
    val container: Int,
    val protocol: Int,
    val colorDescription: Int,
    val contentHeadroom: Float,
    val headroomKind: Int,
    val fingerprint: ByteArray,
    val cameraStamp: CameraStamp? = null,
    val supportsBayerDevelopment: Boolean = false,
    val cameraProcessingVersion: Int = 3,
) {
    internal constructor(
        width: Int,
        height: Int,
        orientation: Int,
        container: Int,
        protocol: Int,
        colorDescription: Int,
        contentHeadroom: Float,
        headroomKind: Int,
        fingerprint: ByteArray,
        supportsBayerDevelopment: Boolean,
        cameraProcessingVersion: Int,
    ) : this(
        width = width,
        height = height,
        orientation = orientation,
        container = container,
        protocol = protocol,
        colorDescription = colorDescription,
        contentHeadroom = contentHeadroom,
        headroomKind = headroomKind,
        fingerprint = fingerprint,
        cameraStamp = null,
        supportsBayerDevelopment = supportsBayerDevelopment,
        cameraProcessingVersion = cameraProcessingVersion,
    )

    init {
        require(width > 0 && height > 0)
        require(contentHeadroom.isFinite() && ((headroomKind == 0 && contentHeadroom == 0f) ||
            (headroomKind in 1..2 && contentHeadroom >= 1f)))
        require(fingerprint.size == FINGERPRINT_BYTES)
    }

    val isProRAW: Boolean get() = container == CONTAINER_PRORAW
    val isCameraRaw: Boolean get() = container == CONTAINER_CAMERA_RAW || isProRAW
    val isCameraRAW: Boolean get() = isCameraRaw

    data class CameraStamp(val length: Long, val modified: Long)

    companion object {
        const val CONTAINER_CAMERA_RAW = 3
        const val CONTAINER_PRORAW = 4
        const val PRORAW_DECODE_VERSION = 2
        private const val FINGERPRINT_BYTES = 32
        private val extensions = setOf("jpg", "jpeg", "heic", "heif")
        private val mimes = setOf("image/jpeg", "image/heic", "image/heif", "image/heif-sequence")

        fun mayContainGainMap(name: String, mime: String?): Boolean =
            name.substringAfterLast('.', "").lowercase() in extensions || mime?.lowercase() in mimes

        fun mayContainGainMap(file: java.io.File): Boolean = file.inputStream().use { input ->
            val signature = ByteArray(12)
            var size = 0
            while (size < signature.size) {
                val count = input.read(signature, size, signature.size - size)
                if (count < 0) break
                size += count
            }
            size >= 2 && signature[0] == 0xff.toByte() && signature[1] == 0xd8.toByte() ||
                size >= 12 && signature.copyOfRange(4, 8).contentEquals("ftyp".toByteArray(Charsets.US_ASCII))
        }
    }
}
