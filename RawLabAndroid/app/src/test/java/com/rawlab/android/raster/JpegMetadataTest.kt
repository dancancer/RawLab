package com.rawlab.android.raster

import java.io.InputStream
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test

class JpegMetadataTest {
    @Test fun motionPhotoMp4AndSamsungSeftTailsAreIgnored() {
        for (tail in listOf(byteArrayOf(0, 0, 0, 24) + "ftypmp42".toByteArray(),
            "SEFT".toByteArray() + byteArrayOf(0, 1, 2), byteArrayOf(-1), byteArrayOf(-1, 0))) {
            val result = RasterContainerValidator.inspect(jpeg() + tail)
            assertTrue(result.error, result.isValid)
        }
    }

    @Test fun onlyAnImmediateJpegSignatureIsRejectedAfterEoi() {
        assertFalse(RasterContainerValidator.inspect(jpeg() + jpeg()).isValid)
        assertTrue(RasterContainerValidator.inspect(jpeg() + byteArrayOf(0) + jpeg()).isValid)
    }

    @Test fun validationDoesNotReadTheMotionVideo() {
        val header = jpeg() + byteArrayOf(0, 0)
        val stream = object : InputStream() {
            var count = 0
            override fun read(): Int {
                check(count < header.size) { "Video tail was read" }
                return header[count++].toInt() and 0xff
            }
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                val remaining = header.size - count
                check(remaining > 0) { "Video tail was read" }
                val size = minOf(length, remaining)
                header.copyInto(bytes, offset, count, count + size)
                count += size
                return size
            }
        }
        assertTrue(RasterContainerValidator.inspect(stream).isValid)
    }

    @Test fun c2paJumbfIsAcceptedWithoutInterpretingItsAssertionsAsImageMetadata() {
        val body = c2paBox("c2pa", "gainmap provenance".toByteArray())
        assertTrue(RasterContainerValidator.inspect(jpeg(segment(0xeb, packet(1, body)))).isValid)
    }

    @Test fun c2paContinuationMustMatchTheRegisteredBoxAndSequence() {
        val box = c2paBox("c2pa", ByteArray(80))
        val first = segment(0xeb, packet(1, box.copyOfRange(0, 48)))
        val rest = segment(0xeb, packet(2, box.copyOfRange(0, 8) + box.copyOfRange(48, box.size)))
        assertTrue(RasterContainerValidator.inspect(jpeg(first + rest)).isValid)
        assertFalse(RasterContainerValidator.inspect(jpeg(first)).isValid)
        assertFalse(RasterContainerValidator.inspect(jpeg(rest)).isValid)
        assertFalse(RasterContainerValidator.inspect(jpeg(first + rest + rest)).isValid)
        val wrongInstance = rest.copyOf().also { it[7] = 2 }
        assertFalse(RasterContainerValidator.inspect(jpeg(first + wrongInstance)).isValid)
        val wrongType = rest.copyOf().also { it[16] = 'x'.code.toByte() }
        assertFalse(RasterContainerValidator.inspect(jpeg(first + wrongType)).isValid)
        val wrongLength = rest.copyOf().also { it[15] = 0 }
        assertFalse(RasterContainerValidator.inspect(jpeg(first + wrongLength)).isValid)
    }

    @Test fun jpegXtAndOtherApp11MetadataRemainUnsupported() {
        for (body in listOf("JPEG XT c2pa".toByteArray(), packet(1, c2paBox("hdr ")),
            packet(1, c2paBox("c2pa").also { it[19] = 0 }),
            packet(1, c2paBox("c2pa")).copyOf(30))) {
            assertFalse(RasterContainerValidator.inspect(jpeg(segment(0xeb, body))).isValid)
        }
        val c2pa = segment(0xeb, packet(1, c2paBox("c2pa")))
        assertFalse(RasterContainerValidator.inspect(jpeg(c2pa + segment(0xeb, "JPEG XT".toByteArray()))).isValid)
    }

    private fun packet(sequence: Int, body: ByteArray): ByteArray =
        byteArrayOf(0x4a, 0x50, 0, 1) + ByteBuffer.allocate(4).putInt(sequence).array() + body

    private fun c2paBox(label: String, content: ByteArray = byteArrayOf()): ByteArray {
        val uuid = byteArrayOf(0x63, 0x32, 0x70, 0x61, 0, 0x11, 0, 0x10,
            0x80.toByte(), 0, 0, 0xaa.toByte(), 0, 0x38, 0x9b.toByte(), 0x71)
        return box("jumb", box("jumd", uuid + byteArrayOf(3) + label.toByteArray() + byteArrayOf(0)) + content)
    }

    private fun box(type: String, body: ByteArray): ByteArray =
        ByteBuffer.allocate(4).putInt(body.size + 8).array() + type.toByteArray() + body

    private fun jpeg(metadata: ByteArray = byteArrayOf()): ByteArray = byteArrayOf(-1, -40) + metadata +
        segment(0xc0, byteArrayOf(8, 0, 1, 0, 1, 3, 1, 17, 0, 2, 17, 0, 3, 17, 0)) +
        segment(0xda, byteArrayOf(3, 1, 0, 2, 0, 3, 0, 0, 63, 0)) + byteArrayOf(1, -1, -39)

    private fun segment(marker: Int, body: ByteArray): ByteArray =
        byteArrayOf(-1, marker.toByte(), ((body.size + 2) shr 8).toByte(), (body.size + 2).toByte()) + body
}
