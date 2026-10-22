package com.rawlab.android.raster

import java.io.BufferedInputStream
import java.io.IOException
import java.io.InputStream

// ============================================================================
//  普通图像的容器检查：解码前先核对尺寸、格式与色彩描述
// ============================================================================

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

/** Container checks happen before BitmapFactory is allowed to normalize the source. */
internal object RasterContainerValidator {
    const val MAX_PIXELS = 128_000_000L
    private val gainMapMarkers = listOf("gainmap", "hdrgm", "hdr-gain-map", "android:gainmap",
        "urn:iso:std:iso:ts:21496", "iso:ts:21496")

    fun inspect(bytes: ByteArray): RasterValidation = inspect(bytes.inputStream())

    fun inspect(input: InputStream): RasterValidation {
        val stream = RasterStream(BufferedInputStream(input))
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
            if (type.contentEquals("sRGB".toByteArray()) && length != 1 ||
                type.contentEquals("cICP".toByteArray()) && length != 4)
                return invalid("Invalid PNG color metadata")
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
                type.contentEquals("sRGB".toByteArray()) -> {
                    if (data == null || (data[0].toInt() and 0xFF) !in 0..3)
                        return invalid("Invalid PNG sRGB rendering intent")
                    hasSrgbProfile = true
                }
                type.contentEquals("cICP".toByteArray()) -> {
                    if (data == null || !data.contentEquals(byteArrayOf(1, 13, 0, 1)))
                        return invalid("PNG color metadata is not supported")
                    hasSrgbProfile = true
                }
                type.contentEquals("iCCP".toByteArray()) -> {
                    if (hasIccProfile || data == null || !IccProfiles.validatePngChunk(data))
                        return invalid("Invalid PNG ICC profile")
                    hasIccProfile = true
                }
                type.contentEquals("gAMA".toByteArray()) || type.contentEquals("cHRM".toByteArray()) ->
                    hasUnresolvedColorMetadata = true
                type.contentEquals("mDCv".toByteArray()) ||
                    type.contentEquals("mDCV".toByteArray()) ||
                    type.contentEquals("cLLi".toByteArray()) -> return invalid("HDR PNG color metadata is not supported")
            }
            if (data != null && containsGainMapMarker(data)) return invalid("HDR gain maps are not supported")
            if (type.contentEquals("IEND".toByteArray())) {
                if (length != 0) return invalid("Invalid PNG end marker")
                sawIend = true
            }
        }
        if (stream.read() >= 0) return invalid("Trailing PNG data is not supported")
        if (hasTransparencyChunk) return invalid("Transparent PNG is not supported")
        if (hasSrgbProfile && hasIccProfile) return invalid("PNG has conflicting color profiles")
        if (hasUnresolvedColorMetadata && !hasSrgbProfile && !hasIccProfile)
            return invalid("PNG color metadata is not supported")
        return RasterValidation(RasterContainerInfo("PNG", width, height, colorType == 6, hasIccProfile))
    }

    private fun inspectJpeg(stream: RasterStream): RasterValidation {
        var marker = nextJpegMarker(stream)
        var frame: RasterContainerInfo? = null
        var iccTotal: Int? = null
        val iccChunks = mutableMapOf<Int, ByteArray>()
        var sawScan = false
        var mpf: List<JpegRange>? = null
        while (marker != null) {
            if (marker == 0xD9) {
                if (!sawScan || (mpf?.let { !MpfThumbnails.validateTail(stream, it) } ?: (stream.read() >= 0)))
                    return invalid("Invalid JPEG frame")
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
            if (marker == 0xE2 && body != null && body.size >= 4 && body.copyOfRange(0, 4).contentEquals("MPF\u0000".toByteArray())) {
                if (mpf != null) return invalid("Multiple MPF indexes are not supported")
                mpf = MpfThumbnails.parse(body, stream.position - body.size + 4)
                    ?: return invalid("Unsupported or invalid MPF images")
            }
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
            type.contentEquals("iCCP".toByteArray()) || type.contentEquals("sRGB".toByteArray()) ||
            type.contentEquals("cICP".toByteArray())

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
