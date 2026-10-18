package com.rawlab.android.raster

import java.io.ByteArrayOutputStream
import java.util.zip.DataFormatException
import java.util.zip.Inflater
import kotlin.math.abs
import kotlin.math.pow

// ============================================================================
//  ICC 描述文件的读取与识别（只供容器检查使用）
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

    private data class IccTag(val signature: String, val offset: Int, val size: Int)

    private data class TrcDescriptor(
        val kind: Int,
        val parameters: List<Int> = emptyList(),
        val samples: IntArray? = null,
    )

    fun validatePngChunk(chunk: ByteArray): Boolean {
        var nameEnd = -1
        for (index in chunk.indices) {
            if (chunk[index] == 0.toByte()) {
                nameEnd = index
                break
            }
        }
        if (nameEnd !in 1..79 || nameEnd + 2 >= chunk.size) return false
        for (index in 0 until nameEnd) {
            val value = chunk[index].toInt() and 0xFF
            if ((value !in 0x20..0x7E && value !in 0xA0..0xFF) ||
                (value == 0x20 && (index == 0 || index == nameEnd - 1 || chunk[index - 1] == 0x20.toByte()))) {
                return false
            }
        }
        if (chunk[nameEnd + 1].toInt() and 0xFF != 0) return false
        return inflateAndValidate(chunk, nameEnd + 2)
    }

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

    private fun inflateAndValidate(chunk: ByteArray, compressedOffset: Int): Boolean {
        if (compressedOffset !in 0 until chunk.size) return false
        val inflater = Inflater()
        return try {
            inflater.setInput(chunk, compressedOffset, chunk.size - compressedOffset)
            val profile = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (!inflater.finished()) {
                val count = inflater.inflate(buffer)
                if (count > 0) {
                    if (profile.size() > MAX_PROFILE_BYTES - count) return false
                    profile.write(buffer, 0, count)
                    continue
                }
                if (inflater.needsDictionary() || inflater.needsInput()) return false
                return false
            }
            if (inflater.remaining != 0) return false
            validateProfile(profile.toByteArray())
        } catch (_: DataFormatException) {
            false
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
        if (!hasSignature(profile, 36, "acsp") || !hasSignature(profile, 16, "RGB ") ||
            !hasSignature(profile, 20, "XYZ ") || !isD50(profile)) return false

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
        return validateRgbMatrixAndTrc(profile, tags)
    }

    private fun validateRgbMatrixAndTrc(profile: ByteArray, tags: Map<String, IccTag>): Boolean {
        val mediaWhitePoint = readXyzTag(profile, tags["wtpt"]) ?: return false
        if (mediaWhitePoint.any { it <= 0.0 }) return false
        val red = readXyzTag(profile, tags["rXYZ"]) ?: return false
        val green = readXyzTag(profile, tags["gXYZ"]) ?: return false
        val blue = readXyzTag(profile, tags["bXYZ"]) ?: return false
        if (red.all { abs(it) < 1.0e-8 } || green.all { abs(it) < 1.0e-8 } ||
            blue.all { abs(it) < 1.0e-8 }) return false
        val determinant = red[0] * (green[1] * blue[2] - green[2] * blue[1]) -
            green[0] * (red[1] * blue[2] - red[2] * blue[1]) +
            blue[0] * (red[1] * green[2] - red[2] * green[1])
        if (!determinant.isFinite() || determinant <= 1.0e-6) return false

        val redTrc = readTrcTag(profile, tags["rTRC"]) ?: return false
        val greenTrc = readTrcTag(profile, tags["gTRC"]) ?: return false
        val blueTrc = readTrcTag(profile, tags["bTRC"]) ?: return false
        return equivalentTrc(redTrc, greenTrc) && equivalentTrc(redTrc, blueTrc)
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

    private fun readTrcTag(profile: ByteArray, tag: IccTag?): TrcDescriptor? {
        if (tag == null || tag.size < 12) return null
        return when {
            hasSignature(profile, tag.offset, "curv") -> readCurveTag(profile, tag)
            hasSignature(profile, tag.offset, "para") -> readParametricTag(profile, tag)
            else -> null
        }
    }

    private fun readCurveTag(profile: ByteArray, tag: IccTag): TrcDescriptor? {
        val count = readU32(profile, tag.offset + 8)
        if (count == 0L) return TrcDescriptor(kind = 0)
        if (count > MAX_CURVE_SAMPLES || count > (tag.size - 12L) / 2L) return null
        if (count == 1L) {
            val gamma = readU16(profile, tag.offset + 12)
            if (gamma == 0 || gamma > 0x1000) return null
            return TrcDescriptor(kind = 1, parameters = listOf(gamma))
        }
        val samples = IntArray(count.toInt())
        var previous = -1
        for (index in samples.indices) {
            val sample = readU16(profile, tag.offset + 12 + index * 2)
            if (sample < previous) return null
            samples[index] = sample
            previous = sample
        }
        return TrcDescriptor(kind = 2, samples = samples)
    }

    private fun readParametricTag(profile: ByteArray, tag: IccTag): TrcDescriptor? {
        val functionType = readU16(profile, tag.offset + 8)
        val parameterCount = when (functionType) {
            0 -> 1
            1 -> 3
            2 -> 4
            3 -> 5
            4 -> 7
            else -> return null
        }
        if (tag.size < 12L + parameterCount * 4L) return null
        val parameters = IntArray(parameterCount)
        for (index in parameters.indices) {
            val raw = readS32(profile, tag.offset + 12 + index * 4)
            val value = raw / 65536.0
            if (raw == Int.MIN_VALUE || !value.isFinite() || abs(value) > 64.0) return null
            parameters[index] = raw
        }
        val values = parameters.map { it / 65536.0 }
        if (values[0] <= 0.0 || (functionType != 0 && values[1] <= 0.0) ||
            !validParametricRange(functionType, values)) return null
        return TrcDescriptor(kind = 3 + functionType, parameters = parameters.toList())
    }

    private fun validParametricRange(functionType: Int, parameters: List<Double>): Boolean {
        val gamma = parameters[0]
        val a = if (functionType == 0) 1.0 else parameters[1]
        val b = if (functionType == 0) 0.0 else parameters[2]
        val c = when (functionType) {
            0, 1 -> 0.0
            else -> parameters[3]
        }
        val d = if (functionType >= 3) parameters[4] else 0.0
        val e = if (functionType == 4) parameters[5] else 0.0
        val f = if (functionType == 4) parameters[6] else 0.0
        if (functionType >= 3 && (d < 0.0 || d > 1.0)) return false
        var previous = -1.0
        for (x in doubleArrayOf(0.0, 0.25, 0.5, 0.75, 1.0)) {
            val value = when (functionType) {
                0 -> x.pow(gamma)
                1 -> if (x >= -b / a) (a * x + b).coerceAtLeast(0.0).pow(gamma) else 0.0
                2 -> if (x >= -b / a) (a * x + b).coerceAtLeast(0.0).pow(gamma) + c else c
                else -> if (x >= d) (a * x + b).coerceAtLeast(0.0).pow(gamma) + e else c * x + f
            }
            if (!value.isFinite() || value < -1.0e-4 || value > 1.0001 || value + 1.0e-9 < previous)
                return false
            previous = value
        }
        return true
    }

    private fun equivalentTrc(first: TrcDescriptor, second: TrcDescriptor): Boolean {
        if (first.kind != second.kind || first.parameters != second.parameters) return false
        return when {
            first.samples == null && second.samples == null -> true
            first.samples == null || second.samples == null -> false
            else -> first.samples.contentEquals(second.samples)
        }
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
