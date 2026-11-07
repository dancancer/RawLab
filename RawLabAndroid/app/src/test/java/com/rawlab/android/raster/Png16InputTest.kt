package com.rawlab.android.raster

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.zip.CRC32
import java.util.zip.DeflaterOutputStream
import org.junit.Assert.*
import org.junit.Test

class Png16InputTest {
    @Test fun exportedOpaqueRgb16PngIsAccepted() {
        val result = RasterContainerValidator.inspect(rgb16Png())
        assertTrue(result.error, result.isValid)
        assertEquals(2, result.info?.width)
        assertEquals(1, result.info?.height)
        assertEquals(16, result.info?.bitDepth)
    }

    private fun rgb16Png(): ByteArray {
        val header = ByteBuffer.allocate(13).putInt(2).putInt(1)
            .put(16).put(2).put(0).put(0).put(0).array()
        val pixels = byteArrayOf(0, 0x12, 0x34, 0x56, 0x78, 0x7a, 0x01,
            0x12, 0x35, 0x56, 0x79, 0x7a, 0x02)
        val compressed = ByteArrayOutputStream().also { bytes ->
            DeflaterOutputStream(bytes).use { it.write(pixels) }
        }.toByteArray()
        return byteArrayOf(137.toByte(), 80, 78, 71, 13, 10, 26, 10) +
            chunk("IHDR", header) + chunk("sRGB", byteArrayOf(0)) +
            chunk("IDAT", compressed) + chunk("IEND", byteArrayOf())
    }

    private fun chunk(type: String, data: ByteArray): ByteArray {
        val body = type.toByteArray() + data
        val crc = CRC32().apply { update(body) }.value.toInt()
        return ByteBuffer.allocate(4).putInt(data.size).array() + body + ByteBuffer.allocate(4).putInt(crc).array()
    }
}
