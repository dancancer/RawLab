package com.rawlab.android.raster

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.ColorSpace
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.CRC32
import java.util.zip.DeflaterOutputStream
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.pow
import com.rawlab.android.engine.NativeFrame

// ============================================================================
//  普通图像测试共用的样张生成、像素比较与 DNG 解析
// ============================================================================

internal const val PROGRESSIVE_JPEG_BASE64 = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMU" +
    "FRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU" +
    "FBQUFBQUFBT/wgARCAACAAIDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAf/xAAUAQEAAAAAAAAAAAAAAAAAAAAG/9oA" +
    "DAMBAAIQAxAAAAG6gcA//8QAFhABAQEAAAAAAAAAAAAAAAAABAYD/9oACAEBAAEFApsBtJ7/xAAZEQABBQAAAAAAAAAAAAAAAAAA" +
    "AQIEM3H/2gAIAQMBAT8Bk3v1T//EABkRAAEFAAAAAAAAAAAAAAAAAAABAgMzcf/aAAgBAgEBPwGe1+qf/8QAGxAAAgIDAQAAAAAA" +
    "AAAAAAAAAQIDBAAFESL/2gAIAQEABj8C1bNXiZmqxEkoOnyM/8QAFhABAQEAAAAAAAAAAAAAAAAAAREA/9oACAEBAAE/IUb8PI2V" +
    "m//aAAwDAQACAAMAAAAQ9//EABcRAAMBAAAAAAAAAAAAAAAAAAABUfD/2gAIAQMBAT8Q1qz/xAAXEQADAQAAAAAAAAAAAAAAAAAA" +
    "AVHw/9oACAECAQE/ENis/8QAFxABAQEBAAAAAAAAAAAAAAAAAREAMf/aAAgBAQABPxBLxVstClVVXt3/2Q=="

internal const val PNG_SIGNATURE_SIZE = 8

internal fun writeCicpPng(file: File, cicp: ByteArray) {
    val header = ByteBuffer.allocate(13).order(ByteOrder.BIG_ENDIAN)
        .putInt(2).putInt(1).put(8).put(2).put(0).put(0).put(0).array()
    val compressed = ByteArrayOutputStream().also { output ->
        DeflaterOutputStream(output).use { stream ->
            stream.write(byteArrayOf(0, 0x33, 0x66, 0x99.toByte(), 0xCC.toByte(), 0x80.toByte(), 0x40))
        }
    }.toByteArray()
    file.writeBytes(byteArrayOf(137.toByte(), 80, 78, 71, 13, 10, 26, 10) +
        makePngChunk("IHDR", header) + makePngChunk("cICP", cicp) +
        makePngChunk("IDAT", compressed) + makePngChunk("IEND", byteArrayOf()))
}

internal fun testRoot(context: android.content.Context, prefix: String): File =
    File(context.cacheDir, "$prefix-${UUID.randomUUID()}").apply { mkdirs() }

internal fun writeBitmap(file: File, bitmap: Bitmap, format: Bitmap.CompressFormat) {
    file.outputStream().use { output -> check(bitmap.compress(format, 100, output)) }
}

internal fun writeGradient(file: File, width: Int, height: Int,
    colorSpace: ColorSpace.Named = ColorSpace.Named.SRGB) {
    val bitmap = gradientBitmap(width, height, colorSpace)
    try {
        writeBitmap(file, bitmap, Bitmap.CompressFormat.PNG)
    } finally {
        bitmap.recycle()
    }
}

internal fun gradientBitmap(width: Int, height: Int, colorSpace: ColorSpace.Named = ColorSpace.Named.SRGB): Bitmap =
    Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888, true, ColorSpace.get(colorSpace)).apply {
        for (y in 0 until height) for (x in 0 until width) {
            setPixel(x, y, gradientPixel(width, height, x, y))
        }
    }

internal fun gradientPixel(width: Int, height: Int, x: Int, y: Int): Int = Color.rgb(
    (x * 255 / (width - 1)).coerceIn(0, 255),
    (y * 255 / (height - 1)).coerceIn(0, 255),
    (x * 37 + y * 53 + 29) % 256,
)

internal fun assertPixelClose(expected: Int, actual: Int, tolerance: Int, message: String) {
    assertTrue(
        message,
        max(
            abs(Color.red(expected) - Color.red(actual)),
            max(abs(Color.green(expected) - Color.green(actual)), abs(Color.blue(expected) - Color.blue(actual))),
        ) <= tolerance,
    )
}

internal fun changedPixels(left: NativeFrame, right: NativeFrame, threshold: Int): Int {
    assertEquals(left.width, right.width)
    assertEquals(left.height, right.height)
    val a = left.bitmap()
    val b = right.bitmap()
    return try {
        var changed = 0
        for (y in 0 until a.height) for (x in 0 until a.width) {
            val first = a.getPixel(x, y)
            val second = b.getPixel(x, y)
            val delta = max(
                abs(Color.red(first) - Color.red(second)),
                max(abs(Color.green(first) - Color.green(second)), abs(Color.blue(first) - Color.blue(second))),
            )
            if (delta > threshold) changed++
        }
        changed
    } finally {
        a.recycle()
        b.recycle()
    }
}

internal fun assertFramesClose(expected: NativeFrame, actual: NativeFrame, tolerance: Int) {
    assertEquals(expected.width, actual.width)
    assertEquals(expected.height, actual.height)
    val expectedBitmap = expected.bitmap()
    val actualBitmap = actual.bitmap()
    try {
        for (y in 0 until expectedBitmap.height) for (x in 0 until expectedBitmap.width) {
            val first = expectedBitmap.getPixel(x, y)
            val second = actualBitmap.getPixel(x, y)
            assertTrue(
                "pixel mismatch at ($x,$y)",
                max(
                    abs(Color.red(first) - Color.red(second)),
                    max(abs(Color.green(first) - Color.green(second)), abs(Color.blue(first) - Color.blue(second))),
                ) <= tolerance,
            )
        }
    } finally {
        expectedBitmap.recycle()
        actualBitmap.recycle()
    }
}

internal fun assertFrameMatchesBitmap(frame: NativeFrame, bitmap: Bitmap, tolerance: Int) {
    val expected = frame.bitmap()
    try {
        assertEquals(expected.width, bitmap.width)
        assertEquals(expected.height, bitmap.height)
        for (y in 0 until expected.height) for (x in 0 until expected.width) {
            val first = expected.getPixel(x, y)
            val second = bitmap.getPixel(x, y)
            assertTrue(
                "preview/final pixel mismatch at ($x,$y)",
                max(
                    abs(Color.red(first) - Color.red(second)),
                    max(abs(Color.green(first) - Color.green(second)), abs(Color.blue(first) - Color.blue(second))),
                ) <= tolerance,
            )
        }
    } finally {
        expected.recycle()
    }
}

internal data class ParsedDng(
    val magic: Int,
    val width: Int,
    val height: Int,
    val bitsPerSample: Int,
    val compression: Int,
    val samplesPerPixel: Int,
    val photometric: Int,
    val sampleFormat: LongArray,
    val pixels: FloatArray,
)

internal class TiffReader(private val bytes: ByteArray) {
    private val order = when {
        bytes.size >= 2 && bytes[0] == 'I'.code.toByte() && bytes[1] == 'I'.code.toByte() -> ByteOrder.LITTLE_ENDIAN
        bytes.size >= 2 && bytes[0] == 'M'.code.toByte() && bytes[1] == 'M'.code.toByte() -> ByteOrder.BIG_ENDIAN
        else -> throw AssertionError("invalid TIFF byte order")
    }

    fun u16(offset: Int): Int = ByteBuffer.wrap(bytes, offset, 2).order(order).short.toInt() and 0xFFFF

    fun u32(offset: Int): Long = ByteBuffer.wrap(bytes, offset, 4).order(order).int.toLong() and 0xFFFFFFFFL

    fun float(offset: Int): Float = Float.fromBits(ByteBuffer.wrap(bytes, offset, 4).order(order).int)

    fun checkedOffset(offset: Long, count: Int): Int {
        require(offset in 0..Int.MAX_VALUE)
        val start = offset.toInt()
        require(count >= 0 && start <= bytes.size - count)
        return start
    }
}

internal fun parseRenderedDng(bytes: ByteArray): ParsedDng {
    val reader = TiffReader(bytes)
    val magic = reader.u16(2)
    require(magic == 42) { "not classic TIFF" }
    val ifd = reader.checkedOffset(reader.u32(4), 2)
    val entries = reader.u16(ifd)
    val fields = mutableMapOf<Int, Pair<Int, LongArray>>()
    fun typeSize(type: Int): Int = when (type) {
        1, 2, 6, 7 -> 1
        3, 8 -> 2
        4, 9, 11 -> 4
        5, 10, 12 -> 8
        else -> throw AssertionError("unsupported TIFF field type $type")
    }
    fun readValues(type: Int, count: Int, entry: Int): LongArray {
        val size = typeSize(type)
        val total = Math.multiplyExact(size, count)
        val offset = if (total <= 4) entry + 8 else reader.checkedOffset(reader.u32(entry + 8), total)
        return when (type) {
            3 -> LongArray(count) { reader.u16(offset + it * 2).toLong() }
            4 -> LongArray(count) { reader.u32(offset + it * 4) }
            else -> throw AssertionError("unexpected TIFF test field type $type")
        }
    }
    for (index in 0 until entries) {
        val entry = ifd + 2 + index * 12
        val tag = reader.u16(entry)
        val type = reader.u16(entry + 2)
        val count = reader.u32(entry + 4).toInt()
        if (tag in setOf(256, 257, 258, 259, 262, 273, 277, 278, 279, 339))
            fields[tag] = type to readValues(type, count, entry)
    }
    fun values(tag: Int): LongArray = fields[tag]?.second ?: throw AssertionError("missing TIFF tag $tag")
    val width = values(256).single().toInt()
    val height = values(257).single().toInt()
    val bits = values(258)
    require(bits.isNotEmpty() && bits.all { it == 32L })
    val compression = values(259).single().toInt()
    val stripOffsets = values(273)
    val rowsPerStrip = values(278).single().toInt()
    val stripByteCounts = values(279)
    require(width > 0 && height > 0 && rowsPerStrip == 64 && compression == 1)
    require(stripOffsets.size == stripByteCounts.size)
    require(stripOffsets.size == 1)
    val samplesPerPixel = values(277).single().toInt()
    val pixels = FloatArray(width * height * samplesPerPixel)
    var destination = 0
    for (strip in stripOffsets.indices) {
        val offset = reader.checkedOffset(stripOffsets[strip], stripByteCounts[strip].toInt())
        val byteCount = stripByteCounts[strip].toInt()
        require(byteCount % 4 == 0)
        repeat(byteCount / 4) {
            require(destination < pixels.size)
            pixels[destination++] = reader.float(offset + it * 4)
        }
    }
    require(destination == pixels.size)
    return ParsedDng(
        magic = magic,
        width = width,
        height = height,
        bitsPerSample = bits.first().toInt(),
        compression = compression,
        samplesPerPixel = samplesPerPixel,
        photometric = values(262).single().toInt(),
        sampleFormat = values(339),
        pixels = pixels,
    )
}

internal fun assertDngAppearanceMatchesPng(dng: ParsedDng, png: Bitmap) {
    for (y in 0 until png.height) for (x in 0 until png.width) {
        val pixel = png.getPixel(x, y)
        val index = (y * png.width + x) * 3
        val expected = floatArrayOf(
            inverseSrgb(Color.red(pixel) / 255f),
            inverseSrgb(Color.green(pixel) / 255f),
            inverseSrgb(Color.blue(pixel) / 255f),
        )
        for (channel in 0..2) {
            val actual = dng.pixels[index + channel]
            assertTrue("DNG pixel is not finite", actual.isFinite())
            assertTrue("DNG pixel is negative", actual >= 0f)
            assertEquals(expected[channel], actual, 0.035f)
        }
    }
}

internal fun inverseSrgb(value: Float): Float =
    if (value <= 0.04045f) value / 12.92f else ((value + 0.055f) / 1.055f).pow(2.4f)

internal fun ByteArray.containsJpegMarker(marker: Int): Boolean {
    for (index in 0 until size - 1) if ((this[index].toInt() and 0xFF) == 0xFF &&
        (this[index + 1].toInt() and 0xFF) == marker) return true
    return false
}

internal fun replaceIccChunkWithInvalidProfile(png: ByteArray, badProfile: ByteArray =
    "RawLabBad".toByteArray(Charsets.US_ASCII) + byteArrayOf(0, 0, 1, 2, 3)): ByteArray {
    require(png.size >= PNG_SIGNATURE_SIZE && png.copyOfRange(0, PNG_SIGNATURE_SIZE).contentEquals(byteArrayOf(
        137.toByte(), 80, 78, 71, 13, 10, 26, 10,
    )))
    var offset = PNG_SIGNATURE_SIZE
    var iendOffset = -1
    while (offset + 12 <= png.size) {
        val length = png.readBeInt(offset)
        require(length >= 0 && offset <= png.size - 12 - length)
        val type = png.copyOfRange(offset + 4, offset + 8).toString(Charsets.US_ASCII)
        if (type == "IEND") iendOffset = offset
        if (type == "iCCP") return replacePngChunk(png, offset, length, type, badProfile)
        offset += 12 + length
    }
    require(iendOffset >= 0) { "profile fixture did not contain IEND" }
    val chunk = makePngChunk("iCCP", badProfile)
    return ByteArrayOutputStream(png.size + chunk.size).also {
        it.write(png, 0, iendOffset)
        it.write(chunk)
        it.write(png, iendOffset, png.size - iendOffset)
    }.toByteArray()
}

internal fun incompleteRgbProfile(): ByteArray = ByteArray(164).also { bytes ->
    val data = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
    data.putInt(0, bytes.size)
    data.putInt(8, 0x04300000)
    for ((offset, signature) in listOf(12 to "mntr", 16 to "RGB ", 20 to "XYZ ", 36 to "acsp",
        132 to "wtpt", 144 to "XYZ ")) {
        signature.toByteArray(Charsets.US_ASCII).copyInto(bytes, offset)
    }
    for (offset in listOf(68, 152)) {
        data.putInt(offset, 0x0000F6D6)
        data.putInt(offset + 4, 0x00010000)
        data.putInt(offset + 8, 0x0000D32D)
    }
    data.putInt(128, 1)
    data.putInt(136, 144)
    data.putInt(140, 20)
}

internal fun replacePngChunk(png: ByteArray, offset: Int, oldLength: Int, type: String, data: ByteArray): ByteArray {
    val replacement = makePngChunk(type, data)
    val oldEnd = offset + 12 + oldLength
    return ByteArrayOutputStream(png.size - (oldEnd - offset) + replacement.size).also {
        it.write(png, 0, offset)
        it.write(replacement)
        it.write(png, oldEnd, png.size - oldEnd)
    }.toByteArray()
}

internal fun makePngChunk(type: String, data: ByteArray): ByteArray {
    require(type.length == 4)
    val typeBytes = type.toByteArray(Charsets.US_ASCII)
    val crc = CRC32().apply {
        update(typeBytes)
        update(data)
    }
    return ByteArrayOutputStream(12 + data.size).also {
        it.write(data.size.toBeBytes())
        it.write(typeBytes)
        it.write(data)
        it.write(crc.value.toInt().toBeBytes())
    }.toByteArray()
}

internal fun ByteArray.readBeInt(offset: Int): Int =
    ((this[offset].toInt() and 0xFF) shl 24) or
        ((this[offset + 1].toInt() and 0xFF) shl 16) or
        ((this[offset + 2].toInt() and 0xFF) shl 8) or
        (this[offset + 3].toInt() and 0xFF)

internal fun Int.toBeBytes(): ByteArray = byteArrayOf(
    (this ushr 24).toByte(), (this ushr 16).toByte(), (this ushr 8).toByte(), toByte(),
)
