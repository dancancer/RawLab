package com.rawlab.android.raster

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test

class MpfThumbnailTest {
    @Test fun knownThumbnailsPreserveThePrimaryFrameInEitherByteOrder() {
        for (order in listOf(ByteOrder.LITTLE_ENDIAN, ByteOrder.BIG_ENDIAN)) {
            for (types in listOf(listOf(0x010001), listOf(0x010002), listOf(0x010001, 0x010002))) {
                val result = RasterContainerValidator.inspect(fixture(types, order).bytes)
                assertTrue("$order $types: ${result.error}", result.isValid)
                assertEquals(13, result.info?.width)
                assertEquals(7, result.info?.height)
            }
        }
    }

    @Test fun unknownAuxiliaryGainMapAndStereoImagesRemainUnsupported() {
        for (type in listOf(0, 0x050000, 0x020002))
            assertFalse(RasterContainerValidator.inspect(fixture(listOf(type)).bytes).isValid)
        assertFalse(RasterContainerValidator.inspect(fixture(listOf(0x010002, 0x010002)).bytes).isValid)
        assertFalse(RasterContainerValidator.inspect(fixture(thumbnailWidth = 2000).bytes).isValid)
    }

    @Test fun invalidIndexRangesAndJpegBoundariesAreRejected() {
        val valid = fixture()
        val bad = mutableListOf<ByteArray>()
        fun changedInt(offset: Int, value: Int) = valid.bytes.copyOf().also {
            ByteBuffer.wrap(it).order(ByteOrder.LITTLE_ENDIAN).putInt(offset, value)
        }
        bad += changedInt(40, 1) // NumberOfImages
        bad += changedInt(40, 4)
        bad += changedInt(84, Int.MAX_VALUE) // 缩略图偏移超出文件
        bad += changedInt(84, valid.primaryEnd - 11) // 与主图重叠
        bad += changedInt(64, valid.primaryEnd - 1) // 主图 EOI 不在声明边界
        bad += changedInt(52, Int.MAX_VALUE) // MPEntry 表偏移
        bad += changedInt(56, 50) // baseline 主图不能包含额外属性 IFD
        bad += changedInt(60, 0x20030000) // 主图缺少父图标记
        bad += changedInt(76, 0x00010002) // 缩略图缺少子图标记
        bad += valid.bytes.copyOf().also { it[72] = 1 } // 父图不能依赖自身
        bad += valid.bytes.copyOf().also { it[valid.thumbnailStarts.first()] = 0 }
        bad += valid.bytes.copyOf().also { it[it.lastIndex] = 0 }
        bad += valid.bytes.copyOf(valid.bytes.size - 3)
        bad += valid.bytes.copyOfRange(0, 50)
        for ((index, bytes) in bad.withIndex())
            assertFalse("malformed MPF case $index", RasterContainerValidator.inspect(bytes).isValid)
    }

    @Test fun duplicateMpfAndUnindexedTrailingImagesAreRejected() {
        val valid = fixture().bytes
        val app2 = valid.copyOfRange(2, 92)
        val duplicate = valid.copyOfRange(0, 2) + app2 + valid.copyOfRange(2, valid.size)
        assertFalse(RasterContainerValidator.inspect(duplicate).isValid)
        assertFalse(RasterContainerValidator.inspect(jpeg(13, 7) + jpeg(4, 3)).isValid)
        assertFalse(RasterContainerValidator.inspect(valid + byteArrayOf(0)).isValid)
    }

    @Test fun aSingleDependentThumbnailMustUseTheFirstDependencyField() {
        val swapped = fixture().bytes
        ByteBuffer.wrap(swapped).order(ByteOrder.LITTLE_ENDIAN)
            .putShort(72, 0).putShort(74, 2)
        assertFalse(RasterContainerValidator.inspect(swapped).isValid)
    }

    private data class Fixture(val bytes: ByteArray, val primaryEnd: Int, val thumbnailStarts: List<Int>)

    private fun fixture(types: List<Int> = listOf(0x010002),
                        order: ByteOrder = ByteOrder.LITTLE_ENDIAN, thumbnailWidth: Int = 4): Fixture {
        val primary = jpeg(13, 7)
        val thumbnails = types.map { jpeg(thumbnailWidth, 3) }
        val payload = ByteArray(54 + (types.size + 1) * 16)
        "MPF\u0000".toByteArray().copyInto(payload)
        payload[4] = if (order == ByteOrder.LITTLE_ENDIAN) 'I'.code.toByte() else 'M'.code.toByte()
        payload[5] = payload[4]
        val buffer = ByteBuffer.wrap(payload).order(order)
        buffer.putShort(6, 42); buffer.putInt(8, 8); buffer.putShort(12, 3)
        buffer.putShort(14, 0xb000.toShort()); buffer.putShort(16, 7); buffer.putInt(18, 4)
        "0100".toByteArray().copyInto(payload, 22)
        buffer.putShort(26, 0xb001.toShort()); buffer.putShort(28, 4); buffer.putInt(30, 1)
        buffer.putInt(34, types.size + 1)
        buffer.putShort(38, 0xb002.toShort()); buffer.putShort(40, 7)
        buffer.putInt(42, (types.size + 1) * 16); buffer.putInt(46, 50)
        val primaryEnd = primary.size + payload.size + 4
        buffer.putInt(54, 0xa0030000.toInt()); buffer.putInt(58, primaryEnd); buffer.putShort(66, 2)
        if (types.size == 2) buffer.putShort(68, 3)
        var position = primaryEnd
        val starts = mutableListOf<Int>()
        for ((index, thumbnail) in thumbnails.withIndex()) {
            position += 17
            starts += position
            val entry = 70 + index * 16
            buffer.putInt(entry, 0x40000000 or types[index])
            buffer.putInt(entry + 4, thumbnail.size); buffer.putInt(entry + 8, position - 10)
            position += thumbnail.size
        }
        var result = primary.copyOfRange(0, 2) + segment(0xe2, payload) + primary.copyOfRange(2, primary.size)
        for (thumbnail in thumbnails) result += ByteArray(17) + thumbnail
        return Fixture(result, primaryEnd, starts)
    }

    private fun jpeg(width: Int, height: Int): ByteArray = byteArrayOf(-1, -40) +
        segment(0xc0, byteArrayOf(8, (height shr 8).toByte(), height.toByte(),
            (width shr 8).toByte(), width.toByte(), 3, 1, 17, 0, 2, 17, 0, 3, 17, 0)) +
        segment(0xda, byteArrayOf(3, 1, 0, 2, 0, 3, 0, 0, 63, 0)) + byteArrayOf(1, 2, -1, 0, 3, -1, -39)

    private fun segment(marker: Int, body: ByteArray): ByteArray =
        byteArrayOf(-1, marker.toByte(), ((body.size + 2) shr 8).toByte(), (body.size + 2).toByte()) + body
}
