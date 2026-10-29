package com.rawlab.android.photo

import java.nio.ByteBuffer
import java.nio.ByteOrder

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
) {
    init {
        require(width > 0 && height > 0)
        require(contentHeadroom.isFinite() && ((headroomKind == 0 && contentHeadroom == 0f) ||
            (headroomKind in 1..2 && contentHeadroom >= 1f)))
        require(fingerprint.size == FINGERPRINT_BYTES)
    }

    companion object {
        private const val BYTES = 64
        private const val FINGERPRINT_BYTES = 32
        private val extensions = setOf("jpg", "jpeg", "heic", "heif")
        private val mimes = setOf("image/jpeg", "image/heic", "image/heif", "image/heif-sequence")

        fun decode(bytes: ByteArray): HDRSourceInfo {
            require(bytes.size == BYTES) { "Invalid HDR source metadata" }
            val input = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            val fingerprint = ByteArray(FINGERPRINT_BYTES)
            return HDRSourceInfo(input.int, input.int, input.int, input.int, input.int, input.int,
                input.float, input.int, fingerprint.also(input::get))
        }

        fun mayContainGainMap(name: String, mime: String?): Boolean =
            name.substringAfterLast('.', "").lowercase() in extensions || mime?.lowercase() in mimes

        fun mayContainGainMap(file: java.io.File): Boolean = file.inputStream().use { input ->
            val signature=ByteArray(12);var size=0
            while(size<signature.size) { val count=input.read(signature,size,signature.size-size);if(count<0)break;size+=count }
            size>=2 && signature[0]==0xff.toByte() && signature[1]==0xd8.toByte() ||
                size>=12 && signature.copyOfRange(4,8).contentEquals("ftyp".toByteArray(Charsets.US_ASCII))
        }
    }
}
