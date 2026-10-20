package com.rawlab.android.raster

import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal class RasterStream(private val source: InputStream) : InputStream() {
    var position = 0L
        private set

    override fun read(): Int = source.read().also { if (it >= 0) position++ }
    override fun read(bytes: ByteArray, offset: Int, length: Int): Int =
        source.read(bytes, offset, length).also { if (it > 0) position += it }
    override fun skip(length: Long): Long = source.skip(length).also { position += it }
}

internal data class JpegRange(val start: Long, val end: Long, val thumbnailType: Int = 0)

/** 只放行基线主图和已知大缩略图，未知辅助图不能丢失其 HDR 或多视角含义。 */
internal object MpfThumbnails {
    fun parse(payload: ByteArray, tiffBase: Long): List<JpegRange>? {
        if (payload.size < 12 || !payload.copyOfRange(0, 4).contentEquals("MPF\u0000".toByteArray())) return null
        val data = payload.copyOfRange(4, payload.size)
        val order = when {
            data[0] == 'I'.code.toByte() && data[1] == 'I'.code.toByte() -> ByteOrder.LITTLE_ENDIAN
            data[0] == 'M'.code.toByte() && data[1] == 'M'.code.toByte() -> ByteOrder.BIG_ENDIAN
            else -> return null
        }
        val buffer = ByteBuffer.wrap(data).order(order)
        fun word(offset: Int) = buffer.getShort(offset).toInt() and 0xffff
        fun number(offset: Int) = buffer.getInt(offset).toLong() and 0xffffffffL
        if (word(2) != 42) return null
        val directory = number(4)
        if (directory < 8 || directory > data.size - 2) return null
        val count = word(directory.toInt())
        val directoryEnd = directory + 2 + count * 12L + 4
        if (directoryEnd > data.size) return null
        if (number(directoryEnd.toInt() - 4) != 0L) return null
        var version = false
        var images = 0L
        var entriesOffset = 0L
        var entriesSize = 0L
        repeat(count) { index ->
            val entry = directory.toInt() + 2 + index * 12
            val type = word(entry + 2)
            val values = number(entry + 4)
            val value = number(entry + 8)
            when (word(entry)) {
                0xb000 -> {
                    if (version || type != 7 || values != 4L ||
                        !data.copyOfRange(entry + 8, entry + 12).contentEquals("0100".toByteArray())) return null
                    version = true
                }
                0xb001 -> {
                    if (images != 0L || type != 4 || values != 1L || value !in 2L..3L) return null
                    images = value
                }
                0xb002 -> {
                    if (entriesSize != 0L || type != 7 || values == 0L) return null
                    entriesSize = values
                    entriesOffset = value
                }
            }
        }
        if (!version || images == 0L || entriesSize != images * 16 || entriesOffset < directoryEnd ||
            entriesOffset > data.size || entriesSize > data.size - entriesOffset) return null
        val ranges = mutableListOf<JpegRange>()
        val thumbnailClasses = mutableSetOf<Long>()
        repeat(images.toInt()) { index ->
            val entry = entriesOffset.toInt() + index * 16
            val attributes = number(entry)
            val type = attributes and 0xffffff
            val length = number(entry + 4)
            val offset = number(entry + 8)
            val start = if (index == 0) 0 else tiffBase + offset
            if ((if (index == 0) attributes != 0xa0030000L || offset != 0L
                else (type != 0x010001L && type != 0x010002L) || attributes != (0x40000000L or type)) ||
                word(entry + 12) > images || word(entry + 14) > images || length < 4 || start < 0 ||
                start > Long.MAX_VALUE - length || (index == 0 && length < tiffBase + data.size)) return null
            val dependencies = listOf(word(entry + 12), word(entry + 14))
            if (index == 0) {
                val valid = if (images == 2L) dependencies == listOf(2, 0)
                    else dependencies.sorted() == listOf(2, 3)
                if (!valid) return null
            } else if (dependencies.any { it != 0 } || !thumbnailClasses.add(type)) return null
            val range = JpegRange(start, start + length, if (index == 0) 0 else type.toInt())
            if (ranges.any { range.start < it.end && it.start < range.end }) return null
            ranges += range
        }
        return ranges
    }

    fun validateTail(stream: RasterStream, ranges: List<JpegRange>): Boolean {
        if (stream.position != ranges.first().end) return false
        for (range in ranges.drop(1).sortedBy { it.start }) {
            if (!skipTo(stream, range.start) || stream.read() != 0xff || stream.read() != 0xd8 ||
                !validateThumbnailHeader(stream, range) ||
                !skipTo(stream, range.end - 2) || stream.read() != 0xff || stream.read() != 0xd9) return false
        }
        return stream.read() == -1
    }

    private fun validateThumbnailHeader(stream: RasterStream, range: JpegRange): Boolean {
        fun word(): Int {
            val high = stream.read()
            val low = stream.read()
            return if (high < 0 || low < 0) -1 else (high shl 8) or low
        }
        while (stream.position + 4 <= range.end - 2) {
            if (stream.read() != 0xff) return false
            var marker = stream.read()
            while (marker == 0xff && stream.position < range.end - 2) marker = stream.read()
            if (marker <= 0 || marker in listOf(0xda, 0xd9, 0xd8)) return false
            if (marker == 1 || marker in 0xd0..0xd7) continue
            if (stream.position + 2 > range.end - 2) return false
            val length = word()
            val end = stream.position + length - 2
            if (length < 2 || end > range.end - 2) return false
            if (marker in 0xc0..0xcf && marker !in listOf(0xc4, 0xc8, 0xcc)) {
                if (marker !in listOf(0xc0, 0xc1, 0xc2) || length != 17 || stream.read() != 8) return false
                val height = word()
                val width = word()
                val longEdge = if (range.thumbnailType == 0x010001) 640 else 1920
                val shortEdge = if (range.thumbnailType == 0x010001) 480 else 1080
                return stream.read() == 3 && width > 0 && height > 0 &&
                    maxOf(width, height) <= longEdge && minOf(width, height) <= shortEdge
            }
            if (!skipTo(stream, end)) return false
        }
        return false
    }

    private fun skipTo(stream: RasterStream, position: Long): Boolean {
        if (position < stream.position) return false
        while (stream.position < position) {
            if (stream.skip(position - stream.position) == 0L && stream.read() < 0) return false
        }
        return true
    }
}
