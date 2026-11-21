package com.rawlab.android.raster

import java.io.ByteArrayOutputStream
import java.util.zip.DataFormatException
import java.util.zip.Inflater
import kotlin.math.abs

// ============================================================================
//  ICC 描述文件的读取与识别（容器结构检查与 iCCP 提取，像素色彩转换交由原生 lcms2）
// ============================================================================

internal object IccProfiles {
    const val MAX_PROFILE_BYTES = 16 * 1024 * 1024
    private const val ICC_HEADER_BYTES = 128L
    private const val TAG_TABLE_HEADER_BYTES = 4L
    private const val TAG_ENTRY_BYTES = 12L
    private const val MAX_TAGS = 100L
    private const val MAX_CURVE_SAMPLES = 65_536L
    private const val D50_X = 0.9642
    private const val D50_Y = 1.0
    private const val D50_Z = 0.8249
    private const val D50_TOLERANCE = 0.009
    private val jpegProfileName = "ICC_PROFILE".toByteArray(Charsets.US_ASCII)
    private val lutTagSignatures = setOf(
        "A2B0", "A2B1", "A2B2", "B2A0", "B2A1", "B2A2",
        "D2B0", "D2B1", "D2B2", "D2B3", "B2D0", "B2D1", "B2D2", "B2D3",
    )
    private val forwardLutSignatures = setOf("A2B0", "A2B1", "A2B2", "D2B0", "D2B1", "D2B2", "D2B3")

    private data class IccTag(val signature: String, val offset: Int, val size: Int)

    fun decodePngChunk(chunk: ByteArray): ByteArray? {
        var nameEnd = -1
        for (index in chunk.indices) {
            if (chunk[index] == 0.toByte()) {
                nameEnd = index
                break
            }
        }
        if (nameEnd !in 1..79 || nameEnd + 2 >= chunk.size) return null
        for (index in 0 until nameEnd) {
            val value = chunk[index].toInt() and 0xFF
            if ((value !in 0x20..0x7E && value !in 0xA0..0xFF) ||
                (value == 0x20 && (index == 0 || index == nameEnd - 1 || chunk[index - 1] == 0x20.toByte()))) {
                return null
            }
        }
        if (chunk[nameEnd + 1].toInt() and 0xFF != 0) return null
        return inflateAndValidate(chunk, nameEnd + 2)
    }

    fun validatePngChunk(chunk: ByteArray): Boolean = decodePngChunk(chunk) != null

    fun validateJpegChunks(chunks: Map<Int, ByteArray>, total: Int?): Boolean {
        if (total == null || total !in 1..255 || chunks.size != total) return false
        var profileSize = 0L
        for (sequence in 1..total) {
            val chunk = chunks[sequence] ?: return false
            if (chunk.isEmpty()) return false
            profileSize += chunk.size.toLong()
            if (profileSize > MAX_PROFILE_BYTES) return false
        }
        val profile = ByteArray(profileSize.toInt())
        var offset = 0
        for (sequence in 1..total) {
            val chunk = chunks[sequence] ?: return false
            chunk.copyInto(profile, offset)
            offset += chunk.size
        }
        return validateProfile(profile)
    }

    fun isJpegPrefix(data: ByteArray): Boolean {
        if (data.size < jpegProfileName.size) return false
        for (index in jpegProfileName.indices) if (data[index] != jpegProfileName[index]) return false
        return true
    }

    private fun inflateAndValidate(chunk: ByteArray, compressedOffset: Int): ByteArray? {
        if (compressedOffset !in 0 until chunk.size) return null
        val inflater = Inflater()
        return try {
            inflater.setInput(chunk, compressedOffset, chunk.size - compressedOffset)
            val profile = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (!inflater.finished()) {
                val count = inflater.inflate(buffer)
                if (count > 0) {
                    if (profile.size() > MAX_PROFILE_BYTES - count) return null
                    profile.write(buffer, 0, count)
                    continue
                }
                if (inflater.needsDictionary() || inflater.needsInput()) return null
                return null
            }
            if (inflater.remaining != 0) return null
            profile.toByteArray().takeIf(::validateProfile)
        } catch (_: DataFormatException) {
            null
        } finally {
            inflater.end()
        }
    }

    private fun validateProfile(profile: ByteArray): Boolean {
        if (profile.size < 132) return false
        val declaredSize = readU32(profile, 0)
        if (declaredSize < ICC_HEADER_BYTES + TAG_TABLE_HEADER_BYTES ||
            declaredSize > profile.size.toLong() || declaredSize > MAX_PROFILE_BYTES) return false
        val majorVersion = profile[8].toInt() and 0xFF
        if (majorVersion !in 2..4 || readSignature(profile, 12) !in setOf("mntr", "scnr", "prtr", "spac"))
            return false
        val pcs = readSignature(profile, 20)
        if (!hasSignature(profile, 36, "acsp") || !hasSignature(profile, 16, "RGB ") ||
            pcs !in setOf("XYZ ", "Lab ") || !isD50(profile)) return false

        val tagCount = readU32(profile, 128)
        if (tagCount == 0L || tagCount > MAX_TAGS) return false
        val tableEnd = ICC_HEADER_BYTES + TAG_TABLE_HEADER_BYTES + tagCount * TAG_ENTRY_BYTES
        if (tableEnd > declaredSize) return false
        val tags = HashMap<String, IccTag>(tagCount.toInt())
        for (index in 0 until tagCount.toInt()) {
            val entry = 132 + index * TAG_ENTRY_BYTES.toInt()
            val offset = readU32(profile, entry + 4)
            val size = readU32(profile, entry + 8)
            if (size == 0L || offset < tableEnd || offset > declaredSize || size > declaredSize - offset)
                return false
            val tag = IccTag(readSignature(profile, entry), offset.toInt(), size.toInt())
            if (tags.put(tag.signature, tag) != null) return false
        }
        tags["cicp"]?.let { cicp ->
            if (cicp.size < 12 || !hasSignature(profile, cicp.offset, "cicp")) return false
            val primaries = profile[cicp.offset + 8].toInt() and 0xFF
            val transfer = profile[cicp.offset + 9].toInt() and 0xFF
            val matrix = profile[cicp.offset + 10].toInt() and 0xFF
            val fullRange = profile[cicp.offset + 11].toInt() and 0xFF
            if (primaries == 9 || transfer in setOf(8, 16, 18) || matrix != 0 || fullRange != 1) return false
        }
        val mediaWhitePoint = readXyzTag(profile, tags["wtpt"]) ?: return false
        if (mediaWhitePoint.any { it <= 0.0 }) return false
        for ((signature, tag) in tags) {
            if (signature in lutTagSignatures && !validLutTag(profile, signature, tag)) return false
        }
        if (forwardLutSignatures.any(tags::containsKey)) return true
        return pcs == "XYZ " && validateRgbMatrixAndTrc(profile, tags)
    }

    private fun validLutTag(profile: ByteArray, signature: String, tag: IccTag): Boolean {
        if (hasSignature(profile, tag.offset, "mft1")) {
            if (tag.size < 48) return false
            val inCh = profile[tag.offset + 8].toInt() and 0xFF
            val outCh = profile[tag.offset + 9].toInt() and 0xFF
            val grid = profile[tag.offset + 10].toInt() and 0xFF
            if (inCh != 3 || outCh != 3 || grid < 2) return false
            val clut = grid.toLong() * grid * grid * outCh
            return 48L + 256L * inCh + clut + 256L * outCh <= tag.size
        }
        if (hasSignature(profile, tag.offset, "mft2")) {
            if (tag.size < 52) return false
            val inCh = profile[tag.offset + 8].toInt() and 0xFF
            val outCh = profile[tag.offset + 9].toInt() and 0xFF
            val grid = profile[tag.offset + 10].toInt() and 0xFF
            val inEntries = readU16(profile, tag.offset + 48)
            val outEntries = readU16(profile, tag.offset + 50)
            if (inCh != 3 || outCh != 3 || grid < 2 || inEntries !in 2..4096 || outEntries !in 2..4096) return false
            val clut = grid.toLong() * grid * grid * outCh
            return 52L + 2L * (inCh.toLong() * inEntries + clut + outCh.toLong() * outEntries) <= tag.size
        }
        if ((signature.startsWith("A2B") && hasSignature(profile, tag.offset, "mAB ")) ||
            (signature.startsWith("B2A") && hasSignature(profile, tag.offset, "mBA "))) {
            if (tag.size < 32) return false
            val inCh = profile[tag.offset + 8].toInt() and 0xFF
            val outCh = profile[tag.offset + 9].toInt() and 0xFF
            if (inCh != 3 || outCh != 3) return false
            val bCurves = readU32(profile, tag.offset + 12)
            if (bCurves < 32L || bCurves >= tag.size) return false
            for (subOffset in intArrayOf(16, 20, 24, 28)) {
                val off = readU32(profile, tag.offset + subOffset)
                if (off != 0L && (off < 32L || off >= tag.size)) return false
            }
            return true
        }
        if (hasSignature(profile, tag.offset, "mpet")) {
            return tag.size >= 16 && readU16(profile, tag.offset + 8) == 3 && readU16(profile, tag.offset + 10) == 3
        }
        return false
    }

    private fun validateRgbMatrixAndTrc(profile: ByteArray, tags: Map<String, IccTag>): Boolean {
        val red = readXyzTag(profile, tags["rXYZ"]) ?: return false
        val green = readXyzTag(profile, tags["gXYZ"]) ?: return false
        val blue = readXyzTag(profile, tags["bXYZ"]) ?: return false
        if (red.all { abs(it) < 1.0e-8 } || green.all { abs(it) < 1.0e-8 } ||
            blue.all { abs(it) < 1.0e-8 }) return false
        val determinant = red[0] * (green[1] * blue[2] - green[2] * blue[1]) -
            green[0] * (red[1] * blue[2] - red[2] * blue[1]) +
            blue[0] * (red[1] * green[2] - red[2] * green[1])
        if (!determinant.isFinite() || determinant <= 1.0e-6) return false
        return validTrcTag(profile, tags["rTRC"]) &&
            validTrcTag(profile, tags["gTRC"]) &&
            validTrcTag(profile, tags["bTRC"])
    }

    private fun readXyzTag(profile: ByteArray, tag: IccTag?): DoubleArray? {
        if (tag == null || tag.size != 20 || !hasSignature(profile, tag.offset, "XYZ ")) return null
        val result = doubleArrayOf(
            readS15Fixed16(profile, tag.offset + 8),
            readS15Fixed16(profile, tag.offset + 12),
            readS15Fixed16(profile, tag.offset + 16),
        )
        if (result.any { !it.isFinite() || abs(it) > 16.0 }) return null
        return result
    }

    private fun validTrcTag(profile: ByteArray, tag: IccTag?): Boolean {
        if (tag == null || tag.size < 12) return false
        if (hasSignature(profile, tag.offset, "curv")) {
            val count = readU32(profile, tag.offset + 8)
            if (count == 0L) return true
            if (count > MAX_CURVE_SAMPLES || count > (tag.size - 12L) / 2L) return false
            return count != 1L || readU16(profile, tag.offset + 12) in 1..0x1000
        }
        if (!hasSignature(profile, tag.offset, "para")) return false
        val functionType = readU16(profile, tag.offset + 8)
        val parameterCount = when (functionType) {
            0 -> 1
            1 -> 3
            2 -> 4
            3 -> 5
            4 -> 7
            else -> return false
        }
        if (tag.size < 12L + parameterCount * 4L) return false
        for (index in 0 until parameterCount) {
            val raw = readS32(profile, tag.offset + 12 + index * 4)
            val value = raw / 65536.0
            if (raw == Int.MIN_VALUE || !value.isFinite() || abs(value) > 64.0) return false
            if ((index == 0 || (functionType != 0 && index == 1)) && value <= 0.0) return false
            if (functionType >= 3 && index == 4 && (value < 0.0 || value > 1.0)) return false
        }
        return true
    }

    private fun isD50(profile: ByteArray): Boolean {
        val illuminant = doubleArrayOf(
            readS15Fixed16(profile, 68),
            readS15Fixed16(profile, 72),
            readS15Fixed16(profile, 76),
        )
        return illuminant.all { it.isFinite() && it > 0.0 } &&
            abs(illuminant[0] - D50_X) <= D50_TOLERANCE &&
            abs(illuminant[1] - D50_Y) <= D50_TOLERANCE &&
            abs(illuminant[2] - D50_Z) <= D50_TOLERANCE
    }

    private fun hasSignature(bytes: ByteArray, offset: Int, signature: String): Boolean {
        val expected = signature.toByteArray(Charsets.US_ASCII)
        return offset >= 0 && offset + expected.size <= bytes.size &&
            bytes.copyOfRange(offset, offset + expected.size).contentEquals(expected)
    }

    private fun readSignature(bytes: ByteArray, offset: Int): String =
        String(bytes, offset, 4, Charsets.US_ASCII)

    private fun readU16(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 0xFF) shl 8) or (bytes[offset + 1].toInt() and 0xFF)

    private fun readS32(bytes: ByteArray, offset: Int): Int = readU32(bytes, offset).toInt()

    private fun readS15Fixed16(bytes: ByteArray, offset: Int): Double = readS32(bytes, offset) / 65536.0

    private fun readU32(bytes: ByteArray, offset: Int): Long =
        ((bytes[offset].toLong() and 0xFF) shl 24) or ((bytes[offset + 1].toLong() and 0xFF) shl 16) or
            ((bytes[offset + 2].toLong() and 0xFF) shl 8) or (bytes[offset + 3].toLong() and 0xFF)
}
