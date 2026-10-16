package com.rawlab.android

import java.io.ByteArrayOutputStream
import java.nio.charset.StandardCharsets
import java.util.zip.CRC32
import java.util.zip.Deflater
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RasterIccTest {
    @Test
    fun pngIccpAcceptsStructuredSrgbAndDisplayP3Profiles() {
        val srgb = RasterContainerValidator.inspect(pngWithIccp(syntheticIccProfile(displayP3 = false)))
        val displayP3 = RasterContainerValidator.inspect(pngWithIccp(syntheticIccProfile(displayP3 = true)))

        assertTrue(srgb.isValid)
        assertTrue(srgb.info?.hasColorProfile == true)
        assertTrue(displayP3.isValid)
        assertTrue(displayP3.info?.hasColorProfile == true)
        assertTrue(RasterContainerValidator.inspect(pngWithIccp(syntheticIccProfile(false, curveType = 4))).isValid)
    }

    @Test
    fun pngExplicitSrgbMarkersConflictWithIccProfiles() {
        val png = pngWithIccp(syntheticIccProfile(displayP3 = true))
        val prefix = png.copyOf(png.size - 12)
        for ((type, data) in listOf("cICP" to byteArrayOf(1, 13, 0, 1), "sRGB" to byteArrayOf(0))) {
            assertFalse(RasterContainerValidator.inspect(prefix + pngChunk(type, data) + pngChunk("IEND", byteArrayOf())).isValid)
        }
    }

    @Test
    fun jpegIccProfileRequiresEveryOrderedChunkExactlyOnce() {
        val profile = syntheticIccProfile(displayP3 = true)
        val split = profile.size / 2
        val valid = jpegWithIccChunks(
            listOf(
                iccChunk(1, 2, profile.copyOfRange(0, split)),
                iccChunk(2, 2, profile.copyOfRange(split, profile.size)),
            ),
        )
        assertTrue(RasterContainerValidator.inspect(valid).isValid)

        val missing = jpegWithIccChunks(listOf(iccChunk(1, 2, profile.copyOfRange(0, split))))
        val duplicate = jpegWithIccChunks(
            listOf(
                iccChunk(1, 2, profile.copyOfRange(0, split)),
                iccChunk(1, 2, profile.copyOfRange(split, profile.size)),
            ),
        )
        val inconsistentTotal = jpegWithIccChunks(
            listOf(
                iccChunk(1, 2, profile.copyOfRange(0, split)),
                iccChunk(2, 3, profile.copyOfRange(split, profile.size)),
            ),
        )
        val emptyChunk = jpegWithIccChunks(listOf(iccChunk(1, 1, ByteArray(0))))
        val malformedMarker = jpegWithIccChunks(
            listOf("ICC_PROFILEx".toByteArray(StandardCharsets.US_ASCII) + byteArrayOf(1, 1) + profile),
        )
        assertFalse(RasterContainerValidator.inspect(missing).isValid)
        assertFalse(RasterContainerValidator.inspect(duplicate).isValid)
        assertFalse(RasterContainerValidator.inspect(inconsistentTotal).isValid)
        assertFalse(RasterContainerValidator.inspect(emptyChunk).isValid)
        assertFalse(RasterContainerValidator.inspect(malformedMarker).isValid)
    }

    @Test
    fun malformedPngIccpIsRejectedBeforeDecoderFallback() {
        val profile = syntheticIccProfile(displayP3 = false)
        val badHeader = profile.copyOf().also { it[36] = 'x'.code.toByte() }
        val badLength = profile.copyOf().also { writeU32(it, 0, it.size + 1) }
        val badModel = profile.copyOf().also { it[16] = 'C'.code.toByte() }
        val badPcs = profile.copyOf().also { it[20] = 'L'.code.toByte() }
        val badIlluminant = profile.copyOf().also { writeS32(it, 76, 1.5) }
        val badTagOffset = profile.copyOf().also { writeU32(it, 136, it.size + 1) }
        val incomplete = profile.copyOf().also { it[180] = 'x'.code.toByte() }
        val truncated = pngWithIccp(profile, truncateCompressedProfile = true)
        val badName = pngWithIccp(profile, profileName = " bad")
        val badCompression = pngWithIccp(profile, compressionMethod = 1)

        assertFalse(RasterContainerValidator.inspect(pngWithIccp(badHeader)).isValid)
        assertFalse(RasterContainerValidator.inspect(pngWithIccp(badLength)).isValid)
        assertFalse(RasterContainerValidator.inspect(pngWithIccp(badModel)).isValid)
        assertFalse(RasterContainerValidator.inspect(pngWithIccp(badPcs)).isValid)
        assertFalse(RasterContainerValidator.inspect(pngWithIccp(badIlluminant)).isValid)
        assertFalse(RasterContainerValidator.inspect(pngWithIccp(badTagOffset)).isValid)
        assertFalse(RasterContainerValidator.inspect(pngWithIccp(incomplete)).isValid)
        assertFalse(RasterContainerValidator.inspect(truncated).isValid)
        assertFalse(RasterContainerValidator.inspect(badName).isValid)
        assertFalse(RasterContainerValidator.inspect(badCompression).isValid)
    }

    @Test
    fun pngIccpInflationIsBounded() {
        val oversizedProfile = ByteArray(16 * 1024 * 1024 + 1)
        oversizedProfile[36] = 'a'.code.toByte()
        assertFalse(RasterContainerValidator.inspect(pngWithIccp(oversizedProfile)).isValid)
    }

    @Test
    fun unsupportedIccHeadersAreRejectedBeforePlatformFallback() {
        val profile = syntheticIccProfile(displayP3 = false)
        val badVersion = profile.copyOf().also { writeU32(it, 8, 0x05000000) }
        val deviceLink = profile.copyOf().also { "link".toByteArray(StandardCharsets.US_ASCII).copyInto(it, 12) }
        val badD50 = profile.copyOf().also { writeS32(it, 68, 0.95) }
        for (unsupported in listOf(badVersion, deviceLink, badD50, syntheticIccProfile(false, 94))) {
            assertFalse(RasterContainerValidator.inspect(pngWithIccp(unsupported)).isValid)
        }
    }

    private fun pngWithIccp(
        profile: ByteArray,
        profileName: String = "RawLab ICC",
        compressionMethod: Int = 0,
        truncateCompressedProfile: Boolean = false,
    ): ByteArray {
        var compressed = deflate(profile)
        if (truncateCompressedProfile) compressed = compressed.copyOf(compressed.size - 1)
        val iccp = profileName.toByteArray(StandardCharsets.ISO_8859_1) +
            byteArrayOf(0, compressionMethod.toByte()) + compressed
        val ihdr = ByteArray(13).also {
            writeU32(it, 0, 2)
            writeU32(it, 4, 2)
            it[8] = 8
            it[9] = 2
        }
        return PNG_SIGNATURE + pngChunk("IHDR", ihdr) + pngChunk("iCCP", iccp) + pngChunk("IEND", ByteArray(0))
    }

    private fun jpegWithIccChunks(chunks: List<ByteArray>): ByteArray {
        val output = ByteArrayOutputStream()
        output.write(byteArrayOf(0xFF.toByte(), 0xD8.toByte()))
        chunks.forEach { payload ->
            output.write(byteArrayOf(0xFF.toByte(), 0xE2.toByte()))
            writeU16(output, payload.size + 2)
            output.write(payload)
        }
        val sof = byteArrayOf(
            8, 0, 1, 0, 1, 3,
            1, 0x11, 0,
            2, 0x11, 1,
            3, 0x11, 1,
        )
        output.write(byteArrayOf(0xFF.toByte(), 0xC0.toByte()))
        writeU16(output, sof.size + 2)
        output.write(sof)
        val sos = byteArrayOf(3, 1, 0, 2, 0x11, 3, 0x11, 0)
        output.write(byteArrayOf(0xFF.toByte(), 0xDA.toByte()))
        writeU16(output, sos.size + 2)
        output.write(sos)
        output.write(byteArrayOf(0xFF.toByte(), 0xD9.toByte()))
        return output.toByteArray()
    }

    private fun iccChunk(sequence: Int, total: Int, payload: ByteArray): ByteArray =
        ICC_PROFILE_PREFIX + byteArrayOf(sequence.toByte(), total.toByte()) + payload

    private fun syntheticIccProfile(displayP3: Boolean, extraTags: Int = 0, curveType: Int = 3): ByteArray {
        val tags = listOf(
            Tag("rXYZ", xyzTag(if (displayP3) 0.5151 else 0.4361, if (displayP3) 0.2412 else 0.2225,
                if (displayP3) -0.0011 else 0.0139)),
            Tag("gXYZ", xyzTag(if (displayP3) 0.2920 else 0.3851, if (displayP3) 0.6922 else 0.7169,
                if (displayP3) 0.0419 else 0.0971)),
            Tag("bXYZ", xyzTag(if (displayP3) 0.1571 else 0.1431, if (displayP3) 0.0666 else 0.0606,
                if (displayP3) 0.7841 else 0.7141)),
            Tag("wtpt", xyzTag(0.9642, 1.0, 0.8249)),
            Tag("rTRC", parametricCurveTag(curveType)),
            Tag("gTRC", parametricCurveTag(curveType)),
            Tag("bTRC", parametricCurveTag(curveType)),
        ) + (0 until extraTags).map { Tag("x" + it.toString().padStart(3, '0'), xyzTag(0.5, 0.5, 0.5)) }
        val tableEnd = 132 + tags.size * 12
        val totalSize = tableEnd + tags.sumOf { it.data.size }
        val profile = ByteArray(totalSize)
        writeU32(profile, 0, totalSize)
        writeU32(profile, 8, 0x04300000)
        profile[12] = 'm'.code.toByte(); profile[13] = 'n'.code.toByte()
        profile[14] = 't'.code.toByte(); profile[15] = 'r'.code.toByte()
        profile[16] = 'R'.code.toByte(); profile[17] = 'G'.code.toByte()
        profile[18] = 'B'.code.toByte(); profile[19] = ' '.code.toByte()
        profile[20] = 'X'.code.toByte(); profile[21] = 'Y'.code.toByte()
        profile[22] = 'Z'.code.toByte(); profile[23] = ' '.code.toByte()
        profile[36] = 'a'.code.toByte(); profile[37] = 'c'.code.toByte()
        profile[38] = 's'.code.toByte(); profile[39] = 'p'.code.toByte()
        writeS32(profile, 68, 0.9642)
        writeS32(profile, 72, 1.0)
        writeS32(profile, 76, 0.8249)
        writeU32(profile, 128, tags.size)
        var dataOffset = tableEnd
        tags.forEachIndexed { index, tag ->
            val entry = 132 + index * 12
            tag.signature.toByteArray(StandardCharsets.US_ASCII).copyInto(profile, entry)
            writeU32(profile, entry + 4, dataOffset)
            writeU32(profile, entry + 8, tag.data.size)
            tag.data.copyInto(profile, dataOffset)
            dataOffset += tag.data.size
        }
        return profile
    }

    private fun xyzTag(red: Double, green: Double, blue: Double): ByteArray = ByteArray(20).also {
        it[0] = 'X'.code.toByte(); it[1] = 'Y'.code.toByte(); it[2] = 'Z'.code.toByte(); it[3] = ' '.code.toByte()
        writeS32(it, 8, red)
        writeS32(it, 12, green)
        writeS32(it, 16, blue)
    }

    private fun parametricCurveTag(type: Int): ByteArray = ByteArray(if (type == 4) 40 else 32).also {
        it[0] = 'p'.code.toByte(); it[1] = 'a'.code.toByte(); it[2] = 'r'.code.toByte(); it[3] = 'a'.code.toByte()
        it[9] = type.toByte()
        writeS32(it, 12, 2.4)
        writeS32(it, 16, 0.9478673)
        writeS32(it, 20, 0.0521327)
        writeS32(it, 24, 0.0773994)
        writeS32(it, 28, 0.04045)
    }

    private fun pngChunk(type: String, data: ByteArray): ByteArray {
        val typeBytes = type.toByteArray(StandardCharsets.US_ASCII)
        val output = ByteArrayOutputStream()
        writeU32(output, data.size.toLong())
        output.write(typeBytes)
        output.write(data)
        val crc = CRC32().apply {
            update(typeBytes)
            update(data)
        }.value
        writeU32(output, crc)
        return output.toByteArray()
    }

    private fun deflate(bytes: ByteArray): ByteArray {
        val deflater = Deflater()
        return try {
            deflater.setInput(bytes)
            deflater.finish()
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (!deflater.finished()) output.write(buffer, 0, deflater.deflate(buffer))
            output.toByteArray()
        } finally {
            deflater.end()
        }
    }

    private fun writeU16(output: ByteArrayOutputStream, value: Int) {
        output.write((value ushr 8) and 0xFF)
        output.write(value and 0xFF)
    }

    private fun writeU32(output: ByteArrayOutputStream, value: Long) {
        output.write(((value ushr 24) and 0xFF).toInt())
        output.write(((value ushr 16) and 0xFF).toInt())
        output.write(((value ushr 8) and 0xFF).toInt())
        output.write((value and 0xFF).toInt())
    }

    private fun writeU32(bytes: ByteArray, offset: Int, value: Int) {
        bytes[offset] = (value ushr 24).toByte()
        bytes[offset + 1] = (value ushr 16).toByte()
        bytes[offset + 2] = (value ushr 8).toByte()
        bytes[offset + 3] = value.toByte()
    }

    private fun writeS32(bytes: ByteArray, offset: Int, value: Double) =
        writeU32(bytes, offset, (value * 65536.0).toInt())

    private data class Tag(val signature: String, val data: ByteArray)

    private companion object {
        val PNG_SIGNATURE = byteArrayOf(137.toByte(), 80, 78, 71, 13, 10, 26, 10)
        val ICC_PROFILE_PREFIX = "ICC_PROFILE\u0000".toByteArray(StandardCharsets.US_ASCII)
    }
}
