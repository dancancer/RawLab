package com.rawlab.android

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ColorSpace
import android.graphics.Matrix
import android.os.Build
import androidx.exifinterface.media.ExifInterface
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.ByteBuffer
import java.util.zip.DataFormatException
import java.util.zip.Inflater
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.pow

enum class PhotoInputKind { RAW, RASTER }

internal object PhotoFiles {
    fun kind(name: String, mime: String?): PhotoInputKind? {
        val raw = RawFiles.accepts(name, mime)
        val raster = RasterFiles.accepts(name, mime)
        return when {
            raw && raster -> null
            raw -> PhotoInputKind.RAW
            raster -> PhotoInputKind.RASTER
            else -> null
        }
    }

    fun accepts(name: String, mime: String?): Boolean = kind(name, mime) != null
}

internal object RasterFiles {
    private val extensions = setOf("jpg", "jpeg", "png")
    private val mimes = setOf("image/jpeg", "image/png")

    fun accepts(name: String, mime: String?): Boolean =
        name.substringAfterLast('.', "").lowercase() in extensions || mime?.lowercase() in mimes
}

internal data class RasterContainerInfo(
    val format: String,
    val width: Int,
    val height: Int,
    val mayContainAlpha: Boolean,
    val hasColorProfile: Boolean = false,
)

internal data class RasterValidation(val info: RasterContainerInfo?, val error: String? = null) {
    val isValid: Boolean get() = info != null && error == null
}

private object IccProfiles {
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

/** Container checks happen before BitmapFactory is allowed to normalize the source. */
internal object RasterContainerValidator {
    private const val MAX_PIXELS = 64_000_000L
    private val gainMapMarkers = listOf("gainmap", "hdrgm", "hdr-gain-map", "android:gainmap",
        "urn:iso:std:iso:ts:21496", "iso:ts:21496")

    fun inspect(bytes: ByteArray): RasterValidation = inspect(bytes.inputStream())

    fun inspect(input: InputStream): RasterValidation {
        val stream = BufferedInputStream(input)
        return try {
            val prefix = ByteArray(2)
            if (!readFully(stream, prefix, 0, prefix.size)) return invalid("Truncated image")
            when {
                prefix[0] == 137.toByte() && prefix[1] == 80.toByte() -> {
                    val signatureTail = ByteArray(6)
                    if (!readFully(stream, signatureTail, 0, signatureTail.size) ||
                        !signatureTail.contentEquals(byteArrayOf(78, 71, 13, 10, 26, 10))) invalid("Invalid PNG signature")
                    else inspectPng(stream)
                }
                prefix[0] == 0xFF.toByte() && prefix[1] == 0xD8.toByte() -> inspectJpeg(stream)
                else -> invalid("Only JPEG and PNG are supported")
            }
        } catch (_: IOException) {
            invalid("Unable to read image")
        }
    }

    private fun inspectPng(stream: InputStream): RasterValidation {
        val header = ByteArray(13)
        val lengthBytes = ByteArray(4)
        if (!readFully(stream, lengthBytes, 0, lengthBytes.size)) return invalid("Truncated PNG")
        val type = ByteArray(4)
        if (readInt(lengthBytes) != 13 || !readFully(stream, type, 0, type.size) ||
            !type.contentEquals("IHDR".toByteArray()) || !readFully(stream, header, 0, header.size))
            return invalid("Invalid PNG header")
        val headerCrc = ByteArray(4)
        if (!readFully(stream, headerCrc, 0, headerCrc.size)) return invalid("Truncated PNG")
        val width = readInt(header, 0)
        val height = readInt(header, 4)
        val depth = header[8].toInt() and 0xFF
        val colorType = header[9].toInt() and 0xFF
        if (width <= 0 || height <= 0 || width.toLong() * height > MAX_PIXELS) return invalid("Image is too large")
        if (depth != 8 || colorType !in setOf(2, 6)) return invalid("PNG must be opaque 8-bit RGB")
        var sawIend = false
        var hasTransparencyChunk = false
        var hasSrgbProfile = false
        var hasIccProfile = false
        var hasUnresolvedColorMetadata = false
        while (!sawIend) {
            val chunkHeader = ByteArray(8)
            if (!readFully(stream, chunkHeader, 0, chunkHeader.size)) return invalid("Truncated PNG")
            val length = readInt(chunkHeader, 0)
            if (length < 0 || length > 64 * 1024 * 1024) return invalid("Invalid PNG chunk")
            val type = chunkHeader.copyOfRange(4, 8)
            if (type.contentEquals("iCCP".toByteArray()) && length > IccProfiles.MAX_PROFILE_BYTES)
                return invalid("PNG ICC profile is too large")
            val data = if (isMetadataChunk(type) || type.contentEquals("acTL".toByteArray()) ||
                type.contentEquals("tRNS".toByteArray())) ByteArray(length) else null
            if (data != null && !readFully(stream, data, 0, length)) return invalid("Truncated PNG")
            else if (data == null && !skipFully(stream, length)) return invalid("Truncated PNG")
            val crc = ByteArray(4)
            if (!readFully(stream, crc, 0, crc.size)) return invalid("Truncated PNG")
            if (type.contentEquals("acTL".toByteArray())) return invalid("Animated PNG is not supported")
            if (type.contentEquals("tRNS".toByteArray())) hasTransparencyChunk = true
            when {
                type.contentEquals("sRGB".toByteArray()) -> hasSrgbProfile = true
                type.contentEquals("iCCP".toByteArray()) -> {
                    if (hasIccProfile || data == null || !IccProfiles.validatePngChunk(data))
                        return invalid("Invalid PNG ICC profile")
                    hasIccProfile = true
                }
                type.contentEquals("gAMA".toByteArray()) || type.contentEquals("cHRM".toByteArray()) ->
                    hasUnresolvedColorMetadata = true
                type.contentEquals("cICP".toByteArray()) || type.contentEquals("mDCv".toByteArray()) ||
                    type.contentEquals("mDCV".toByteArray()) ||
                    type.contentEquals("cLLi".toByteArray()) -> return invalid("HDR PNG color metadata is not supported")
            }
            if (data != null && containsGainMapMarker(data)) return invalid("HDR gain maps are not supported")
            if (type.contentEquals("IEND".toByteArray())) sawIend = true
        }
        if (hasTransparencyChunk) return invalid("Transparent PNG is not supported")
        if (hasSrgbProfile && hasIccProfile) return invalid("PNG has conflicting color profiles")
        if (hasUnresolvedColorMetadata && !hasSrgbProfile && !hasIccProfile)
            return invalid("PNG color metadata is not supported")
        return RasterValidation(RasterContainerInfo("PNG", width, height, colorType == 6, hasIccProfile))
    }

    private fun inspectJpeg(stream: InputStream): RasterValidation {
        var marker = nextJpegMarker(stream)
        var frame: RasterContainerInfo? = null
        var iccTotal: Int? = null
        val iccChunks = mutableMapOf<Int, ByteArray>()
        var sawScan = false
        while (marker != null) {
            if (marker == 0xD9) {
                if (!sawScan || stream.read() >= 0) return invalid("Invalid JPEG frame")
                if (iccTotal != null && !IccProfiles.validateJpegChunks(iccChunks, iccTotal))
                    return invalid("Invalid JPEG ICC profile")
                return frame?.copy(hasColorProfile = iccTotal != null)?.let(::RasterValidation)
                    ?: invalid("Invalid JPEG frame")
            }
            if (marker == 0xDA) {
                val lengthBytes = ByteArray(2)
                if (!readFully(stream, lengthBytes, 0, 2)) return invalid("Truncated JPEG")
                val length = ((lengthBytes[0].toInt() and 0xFF) shl 8) or (lengthBytes[1].toInt() and 0xFF)
                if (frame == null || length < 2 || !skipFully(stream, length - 2)) return invalid("Truncated JPEG")
                marker = nextJpegScanMarker(stream) ?: return invalid("Truncated JPEG")
                sawScan = true
                continue
            }
            if (marker in 0xD0..0xD7 || marker == 0x01) {
                marker = nextJpegMarker(stream)
                continue
            }
            val lengthBytes = ByteArray(2)
            if (!readFully(stream, lengthBytes, 0, 2)) return invalid("Truncated JPEG")
            val length = ((lengthBytes[0].toInt() and 0xFF) shl 8) or (lengthBytes[1].toInt() and 0xFF)
            if (length < 2) return invalid("Invalid JPEG segment")
            val bodyLength = length - 2
            val isFrame = marker in setOf(0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF)
            val body = if (isFrame || marker in 0xE0..0xEF) ByteArray(bodyLength) else null
            if (body != null && !readFully(stream, body, 0, bodyLength)) return invalid("Truncated JPEG")
            else if (body == null && !skipFully(stream, bodyLength)) return invalid("Truncated JPEG")
            if (body != null && containsGainMapMarker(body)) return invalid("HDR gain maps are not supported")
            if (marker == 0xE2 && body != null && body.size >= 4 && body.copyOfRange(0, 4).contentEquals("MPF\u0000".toByteArray()))
                return invalid("Multi-picture JPEG is not supported")
            if (marker == 0xE2 && body != null && IccProfiles.isJpegPrefix(body)) {
                if (body.size < 14 || body[11] != 0.toByte()) return invalid("Invalid JPEG ICC profile")
                val sequence = body[12].toInt() and 0xFF
                val total = body[13].toInt() and 0xFF
                if (total == 0 || sequence == 0 || sequence > total ||
                    (iccTotal != null && iccTotal != total)) return invalid("Invalid JPEG ICC profile")
                iccTotal = total
                if (iccChunks.put(sequence, body.copyOfRange(14, body.size)) != null)
                    return invalid("Invalid JPEG ICC profile")
                if (iccChunks.values.sumOf { it.size.toLong() } > IccProfiles.MAX_PROFILE_BYTES)
                    return invalid("JPEG ICC profile is too large")
            }
            if (marker == 0xEB) return invalid("Unsupported JPEG metadata")
            if (isFrame) {
                if (frame != null || body == null || body.size < 6) return invalid("Multiple JPEG frames are not supported")
                val depth = body[0].toInt() and 0xFF
                val height = ((body[1].toInt() and 0xFF) shl 8) or (body[2].toInt() and 0xFF)
                val width = ((body[3].toInt() and 0xFF) shl 8) or (body[4].toInt() and 0xFF)
                val components = body[5].toInt() and 0xFF
                if (depth != 8 || components != 3) return invalid("JPEG must be 8-bit RGB")
                if (width <= 0 || height <= 0 || width.toLong() * height > MAX_PIXELS) return invalid("Image is too large")
                frame = RasterContainerInfo("JPEG", width, height, false)
            }
            marker = nextJpegMarker(stream)
        }
        return invalid("Truncated JPEG")
    }

    private fun nextJpegScanMarker(stream: InputStream): Int? {
        while (true) {
            val value = stream.read()
            if (value < 0) return null
            if (value != 0xFF) {
                continue
            }
            var marker = stream.read()
            while (marker == 0xFF) marker = stream.read()
            if (marker < 0) return null
            if (marker == 0 || marker in 0xD0..0xD7) continue
            return marker
        }
    }

    private fun nextJpegMarker(stream: InputStream): Int? {
        var value: Int
        do {
            value = stream.read()
            if (value < 0) return null
        } while (value != 0xFF)
        do {
            value = stream.read()
            if (value < 0) return null
        } while (value == 0xFF)
        if (value == 0) return nextJpegMarker(stream)
        return value
    }

    private fun isMetadataChunk(type: ByteArray): Boolean =
        type.contentEquals("iTXt".toByteArray()) || type.contentEquals("tEXt".toByteArray()) ||
            type.contentEquals("zTXt".toByteArray()) || type.contentEquals("eXIf".toByteArray()) ||
            type.contentEquals("iCCP".toByteArray())

    private fun containsGainMapMarker(data: ByteArray): Boolean {
        val text = data.toString(Charsets.ISO_8859_1).lowercase()
        return gainMapMarkers.any(text::contains)
    }

    private fun invalid(message: String) = RasterValidation(null, message)

    private fun readInt(bytes: ByteArray, offset: Int = 0): Int =
        ((bytes[offset].toInt() and 0xFF) shl 24) or ((bytes[offset + 1].toInt() and 0xFF) shl 16) or
            ((bytes[offset + 2].toInt() and 0xFF) shl 8) or (bytes[offset + 3].toInt() and 0xFF)

    private fun readFully(input: InputStream, bytes: ByteArray, offset: Int, length: Int): Boolean {
        var done = 0
        while (done < length) {
            val count = input.read(bytes, offset + done, length - done)
            if (count < 0) return false
            done += count
        }
        return true
    }

    private fun skipFully(input: InputStream, length: Int): Boolean {
        var remaining = length.toLong()
        while (remaining > 0) {
            val skipped = input.skip(remaining)
            if (skipped > 0) remaining -= skipped
            else if (input.read() >= 0) remaining-- else return false
        }
        return true
    }
}

internal data class DecodedRaster(val width: Int, val height: Int, val pixels: ByteArray)

internal object RasterImageDecoder {
    private const val MAX_PIXELS = 64_000_000L

    fun decode(file: File): DecodedRaster {
        val validation = file.inputStream().use(RasterContainerValidator::inspect)
        val info = validation.info ?: throw IOException(validation.error ?: "Unsupported raster image")
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        // decodeFile returns null for a bounds-only request on some API levels; out* is the contract.
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0)
            throw IOException("Unable to decode image")
        if (bounds.outWidth != info.width || bounds.outHeight != info.height)
            throw IOException("Image dimensions changed during decode")
        if (bounds.outWidth.toLong() * bounds.outHeight > MAX_PIXELS) throw IOException("Image is too large")
        if (info.hasColorProfile && bounds.outColorSpace == null)
            throw IOException("Image color space is not supported")
        if (Build.VERSION.SDK_INT >= 26 && !isSupportedSdrColorSpace(bounds.outColorSpace))
            throw IOException("Image color space is not supported")
        val options = BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inScaled = false
            if (Build.VERSION.SDK_INT >= 26) inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB)
        }
        val bitmap = BitmapFactory.decodeFile(file.path, options) ?: throw IOException("Unable to decode image")
        try {
            if (bitmap.config != Bitmap.Config.ARGB_8888 || bitmap.width != info.width || bitmap.height != info.height)
                throw IOException("Image is not an 8-bit RGB image")
            if (Build.VERSION.SDK_INT >= 26 && bitmap.colorSpace?.isSrgb != true)
                throw IOException("Image color space is not supported")
            if (Build.VERSION.SDK_INT >= 34 && bitmap.hasGainmap())
                throw IOException("HDR gain maps are not supported")
            if (info.mayContainAlpha && !isOpaque(bitmap)) throw IOException("Transparent PNG is not supported")
            val oriented = orient(bitmap, file)
            try {
                val bytes = ByteArray(oriented.width * oriented.height * 4)
                oriented.copyPixelsToBuffer(ByteBuffer.wrap(bytes))
                return DecodedRaster(oriented.width, oriented.height, bytes)
            } finally { if (oriented !== bitmap) oriented.recycle() }
        } finally { bitmap.recycle() }
    }

    private fun isOpaque(bitmap: Bitmap): Boolean {
        val row = IntArray(min(bitmap.width, 4096))
        var y = 0
        while (y < bitmap.height) {
            var x = 0
            while (x < bitmap.width) {
                val count = min(row.size, bitmap.width - x)
                bitmap.getPixels(row, 0, count, x, y, count, 1)
                for (i in 0 until count) if (row[i] ushr 24 != 0xFF) return false
                x += count
            }
            y++
        }
        return true
    }

    private fun orient(bitmap: Bitmap, file: File): Bitmap {
        val exif = runCatching { ExifInterface(file) }.getOrNull() ?: return bitmap
        val rotation = exif.rotationDegrees
        val flipped = exif.isFlipped
        if (!flipped && rotation == 0) return bitmap
        val matrix = Matrix().apply {
            if (flipped) postScale(-1f, 1f)
            if (rotation != 0) postRotate(rotation.toFloat())
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
            ?: throw IOException("Unable to apply image orientation")
    }

    private fun isSupportedSdrColorSpace(space: ColorSpace?): Boolean {
        if (space == null || space.isSrgb) return true // Untagged RGB assumes sRGB.
        if (space.model != ColorSpace.Model.RGB) return false
        val name = space.name.lowercase()
        if (name.contains("pq") || name.contains("hlg") || name.contains("extended") ||
            name.contains("linear") || name.contains("bt2020")) return false
        return listOf("display p3", "dci-p3", "adobe rgb", "bt.709", "bt709", "smpte c",
            "ntsc", "prophoto").any(name::contains)
    }
}
