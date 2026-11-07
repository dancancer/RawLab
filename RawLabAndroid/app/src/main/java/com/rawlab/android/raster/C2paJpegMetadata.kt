package com.rawlab.android.raster

/** 只识别 C2PA 容器及其续片，不把内容凭证里的文字或缩略图当成主图的 HDR 元数据。 */
internal class C2paJpegMetadata {
    private var instance = -1
    private var sequence = 0L
    private var boxLength = 0L
    private var received = 0L
    val isComplete: Boolean get() = received == boxLength

    fun accept(body: ByteArray): Boolean {
        if (body.size < 17 || body[0] != 0x4a.toByte() || body[1] != 0x50.toByte() ||
            !matches(body, 12, "jumb".toByteArray())) return false
        val id = ((body[2].toInt() and 255) shl 8) or (body[3].toInt() and 255)
        val part = number(body, 4)
        val length = number(body, 8)
        if (part == 1L) {
            if (!isComplete || body.size < 46 || length < 38 ||
                !matches(body, 20, "jumd".toByteArray())) return false
            val descriptionLength = number(body, 16)
            val uuid = byteArrayOf(0x63, 0x32, 0x70, 0x61, 0, 0x11, 0, 0x10,
                0x80.toByte(), 0, 0, 0xaa.toByte(), 0, 0x38, 0x9b.toByte(), 0x71)
            if (descriptionLength < 30 || descriptionLength > length - 8 ||
                descriptionLength > body.size - 16 || !matches(body, 24, uuid) ||
                body[40].toInt() and 2 == 0 || !matches(body, 41, byteArrayOf(99, 50, 112, 97, 0))) return false
            instance = id
            sequence = part
            boxLength = length
            received = (body.size - 8).toLong()
        } else {
            // JPEG XT 在每个续片重复 LBox/TBox；只有已确认 c2pa 的同一实例能续接。
            if (isComplete || id != instance || part != sequence + 1 || length != boxLength) return false
            sequence = part
            received += body.size - 16
        }
        return received <= boxLength
    }

    private fun matches(body: ByteArray, offset: Int, value: ByteArray): Boolean =
        offset + value.size <= body.size && value.indices.all { body[offset + it] == value[it] }

    private fun number(body: ByteArray, offset: Int): Long =
        (0..3).fold(0L) { value, index -> (value shl 8) or (body[offset + index].toLong() and 255) }
}
