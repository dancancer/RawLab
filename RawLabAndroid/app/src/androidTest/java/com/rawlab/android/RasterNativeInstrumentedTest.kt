package com.rawlab.android

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.ColorSpace
import android.util.Base64
import androidx.exifinterface.media.ExifInterface
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.zip.CRC32
import java.util.zip.DeflaterOutputStream
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.roundToInt

@RunWith(AndroidJUnit4::class)
class RasterNativeInstrumentedTest {
    @Test
    fun neutralRasterPreservesPixelsOrientationAndFullResolutionExport() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = testRoot(context, "raster-native")
        val input = File(root, "source.png")
        val jpeg = File(root, "source.jpg")
        val output = File(root, "output.png")
        val bitmap = Bitmap.createBitmap(2, 1, Bitmap.Config.ARGB_8888).apply {
            setPixel(0, 0, 0xFFFF0000.toInt())
            setPixel(1, 0, 0xFF0000FF.toInt())
        }
        writeBitmap(input, bitmap, Bitmap.CompressFormat.PNG)
        bitmap.recycle()
        ExifInterface(input).apply {
            setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
            saveAttributes()
        }
        val jpegBitmap = Bitmap.createBitmap(3, 2, Bitmap.Config.ARGB_8888).apply { eraseColor(0xFF336699.toInt()) }
        writeBitmap(jpeg, jpegBitmap, Bitmap.CompressFormat.JPEG)
        jpegBitmap.recycle()
        try {
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                val preview = processor.preview(input, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
                assertEquals(1, preview.width)
                assertEquals(2, preview.height)
                assertEquals(0, preview.backend)
                val oriented = preview.bitmap()
                try {
                    assertEquals(0xFFFF0000.toInt(), oriented.getPixel(0, 0))
                    assertEquals(0xFF0000FF.toInt(), oriented.getPixel(0, 1))
                } finally {
                    oriented.recycle()
                }
                val jpegPreview = processor.preview(jpeg, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
                assertEquals(3, jpegPreview.width)
                assertEquals(2, jpegPreview.height)
                assertEquals(0, processor.export(input, null, EditSettings(), output, ExportFormat.PNG, null, PhotoInputKind.RASTER))
            }
            val exported = checkNotNull(BitmapFactory.decodeFile(output.path))
            try {
                assertEquals(1, exported.width)
                assertEquals(2, exported.height)
            } finally {
                exported.recycle()
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun masterRecipeIdentityAndStrengthChangeRasterPixels() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = testRoot(context, "raster-recipe")
        val input = File(root, "source.png")
        writeGradient(input, 19, 13)
        try {
            PhotoStorage(context).use { storage ->
                val recipe = MasterRecipe.load(context).firstOrNull()
                assertNotNull(recipe)
                val actualRecipe = checkNotNull(recipe)
                assertTrue(actualRecipe.id.isNotBlank())
                val settings = EditSettings().applyRecipe(actualRecipe)
                assertEquals(actualRecipe.id, settings.recipeID)
                val look = checkNotNull(storage.lookPath(settings))
                NativeProcessor(NativeProcessor.CPU).use { processor ->
                    val neutral = processor.preview(input, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
                    val strengthFrames = listOf(0f, 1f, 2f).map { strength ->
                        processor.preview(input, look, settings.copy(strength = strength), 1600, false, PhotoInputKind.RASTER)
                    }
                    assertFramesClose(neutral, strengthFrames[0], 2)
                    assertTrue(
                        "strength 1 must change pixels from strength 0",
                        changedPixels(strengthFrames[0], strengthFrames[1], 3) > 8,
                    )
                    assertTrue(
                        "strength 2 must change pixels from strength 1",
                        changedPixels(strengthFrames[1], strengthFrames[2], 3) > 8,
                    )
                    assertTrue(
                        "a real master recipe must change pixels at strength 1",
                        changedPixels(neutral, strengthFrames[1], 3) > 8,
                    )
                }
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun rasterForceGpuModeIsRejected() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = testRoot(context, "raster-force-gpu")
        val input = File(root, "source.png")
        writeGradient(input, 9, 7)
        try {
            NativeProcessor(NativeProcessor.FORCE).use { processor ->
                assertThrows(IOException::class.java) {
                    processor.preview(input, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
                }
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun rasterStagesMatchFinalPngAndNativeExportDoesNotReusePreview() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = testRoot(context, "raster-final")
        val smallInput = File(root, "small.png")
        val smallOutput = File(root, "small-final.png")
        val fullInput = File(root, "full.png")
        val fullOutput = File(root, "full-final.png")
        writeGradient(smallInput, 18, 14)
        writeGradient(fullInput, 47, 31)
        val settings = EditSettings(
            exposure = 0.55f,
            highlights = -0.25f,
            shadows = 0.3f,
            contrast = 0.28f,
            toneCurve = 0.2f,
            saturation = 0.22f,
            sharpening = 0.35f,
            denoise = DenoiseSettings(enabled = true, luma = 8f, chroma = 64f, coarse = 72f),
            displayChromaDenoise = 1,
            effects = PhotoEffectsSettings(
                vignetteAmount = -42f,
                vignetteMidpoint = 48f,
                vignetteRoundness = 20f,
                vignetteFeather = 64f,
                vignetteHighlights = 18f,
                grainAmount = 22f,
                grainSize = 35f,
                grainRoughness = 62f,
            ),
            hsl = HslSettings()
                .withValue(0, 0, 34f)
                .withValue(1, 2, -28f)
                .withValue(2, 4, 24f),
            geometry = GeometrySettings(
                cropX = 0.1f,
                cropY = 0.1f,
                cropWidth = 0.8f,
                cropHeight = 0.8f,
                quarterTurns = 1,
            ),
        )
        try {
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                val probe = processor.preview(smallInput, null, settings, 1600, false, PhotoInputKind.RASTER)
                val preview = processor.preview(smallInput, null, settings,
                    max(probe.geometryWidth, probe.geometryHeight), false, PhotoInputKind.RASTER)
                processor.export(smallInput, null, settings, smallOutput, ExportFormat.PNG, null, PhotoInputKind.RASTER)
                val finalPng = checkNotNull(BitmapFactory.decodeFile(smallOutput.path))
                try {
                    assertEquals(preview.width, finalPng.width)
                    assertEquals(preview.height, finalPng.height)
                    assertFrameMatchesBitmap(preview, finalPng, 5)
                } finally {
                    finalPng.recycle()
                }

                val reduced = processor.preview(fullInput, null, EditSettings(), 9, false, PhotoInputKind.RASTER)
                assertTrue(max(reduced.width, reduced.height) <= 9)
                processor.export(fullInput, null, EditSettings(), fullOutput, ExportFormat.PNG, null, PhotoInputKind.RASTER)
                val nativePng = checkNotNull(BitmapFactory.decodeFile(fullOutput.path))
                try {
                    assertEquals(47, nativePng.width)
                    assertEquals(31, nativePng.height)
                    assertTrue(nativePng.width > reduced.width || nativePng.height > reduced.height)
                } finally {
                    nativePng.recycle()
                }
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun rasterFinalDngHasTiffFloatPixelsAndGeometryAndMatchesPngAppearance() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = testRoot(context, "raster-dng")
        val input = File(root, "source.png")
        val png = File(root, "final.png")
        val dng = File(root, "final.dng")
        writeGradient(input, 16, 12)
        val settings = EditSettings(
            exposure = 0.35f,
            saturation = 0.12f,
            geometry = GeometrySettings(cropX = 0.2f, cropY = 0.15f, cropWidth = 0.65f, cropHeight = 0.7f, quarterTurns = 1),
        )
        try {
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                val preview = processor.preview(input, null, settings, 1600, false, PhotoInputKind.RASTER)
                processor.export(input, null, settings, png, ExportFormat.PNG, null, PhotoInputKind.RASTER)
                processor.export(input, null, settings, dng, ExportFormat.DNG, null, PhotoInputKind.RASTER)
                val renderedPng = checkNotNull(BitmapFactory.decodeFile(png.path))
                try {
                    val renderedDng = parseRenderedDng(dng.readBytes())
                    assertEquals(42, renderedDng.magic)
                    assertEquals(preview.geometryWidth, renderedDng.width)
                    assertEquals(preview.geometryHeight, renderedDng.height)
                    assertEquals(renderedPng.width, renderedDng.width)
                    assertEquals(renderedPng.height, renderedDng.height)
                    assertEquals(32, renderedDng.bitsPerSample)
                    assertEquals(1, renderedDng.compression)
                    assertEquals(3, renderedDng.samplesPerPixel)
                    assertEquals(34892, renderedDng.photometric)
                    assertTrue(renderedDng.sampleFormat.all { it == 3L })
                    assertDngAppearanceMatchesPng(renderedDng, renderedPng)
                } finally {
                    renderedPng.recycle()
                }
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun progressiveJpegIsAValidRasterFixture() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = testRoot(context, "raster-progressive-jpeg")
        val input = File(root, "progressive.jpg")
        input.writeBytes(Base64.decode(PROGRESSIVE_JPEG_BASE64, Base64.DEFAULT))
        try {
            assertTrue("fixture must contain SOF2", input.readBytes().containsJpegMarker(0xC2))
            val info = input.inputStream().use(RasterContainerValidator::inspect)
            assertTrue(info.error ?: "progressive JPEG was rejected", info.isValid)
            assertEquals(2, checkNotNull(info.info).width)
            assertEquals(2, checkNotNull(info.info).height)
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                val frame = processor.preview(input, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
                assertEquals(2, frame.width)
                assertEquals(2, frame.height)
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun validDisplayP3AndAdobeRgbFixturesAreAccepted() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = testRoot(context, "raster-color-profile")
        val fixtures = listOf(
            "display-p3.png" to ColorSpace.Named.DISPLAY_P3,
            "adobe-rgb.png" to ColorSpace.Named.ADOBE_RGB,
        )
        try {
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                for ((name, colorSpace) in fixtures) {
                    val input = File(root, name)
                    // setPixel(int) accepts an sRGB packed color and converts it into the
                    // bitmap's color space. Keep that exact bitmap as the reference source.
                    val referenceBitmap = gradientBitmap(11, 7, colorSpace)
                    try {
                        writeBitmap(input, referenceBitmap, Bitmap.CompressFormat.PNG)
                        val info = input.inputStream().use(RasterContainerValidator::inspect)
                        assertTrue("$name must carry a valid ICC profile", info.isValid && info.info?.hasColorProfile == true)
                        val frame = processor.preview(input, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
                        val rendered = frame.bitmap()
                        try {
                            assertEquals(11, frame.width)
                            assertEquals(7, frame.height)
                            for ((x, y) in listOf(3 to 2, 7 to 4)) {
                                val converted = referenceBitmap.getColor(x, y).convert(ColorSpace.get(ColorSpace.Named.SRGB))
                                val expected = Color.rgb(
                                    (converted.red() * 255f).roundToInt().coerceIn(0, 255),
                                    (converted.green() * 255f).roundToInt().coerceIn(0, 255),
                                    (converted.blue() * 255f).roundToInt().coerceIn(0, 255),
                                )
                                assertPixelClose(expected, rendered.getPixel(x, y), 8,
                                    "$name preview pixel was not converted to sRGB at ($x,$y)")
                            }
                        } finally {
                            rendered.recycle()
                        }
                    } finally {
                        referenceBitmap.recycle()
                    }
                }
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun malformedIccProfileIsRejectedBeforeNativeRasterProcessing() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = testRoot(context, "raster-bad-icc")
        val input = File(root, "bad-icc.png")
        val valid = ByteArrayOutputStream().also { output ->
            val bitmap = gradientBitmap(9, 6, ColorSpace.Named.DISPLAY_P3)
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
            bitmap.recycle()
        }.toByteArray()
        input.writeBytes(replaceIccChunkWithInvalidProfile(valid))
        try {
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                assertThrows(IOException::class.java) {
                    processor.preview(input, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
                }
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun unsupportedIccCannotFallBackToSrgb() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = testRoot(context, "raster-unsupported-icc")
        val input = File(root, "unsupported-icc.png")
        writeGradient(input, 9, 6, ColorSpace.Named.DISPLAY_P3)
        val compressed = ByteArrayOutputStream().also { bytes ->
            DeflaterOutputStream(bytes).use { it.write(incompleteRgbProfile()) }
        }.toByteArray()
        val payload = "RawLabUnsupported".toByteArray(Charsets.US_ASCII) + byteArrayOf(0, 0) + compressed
        input.writeBytes(replaceIccChunkWithInvalidProfile(input.readBytes(), payload))
        try {
            assertNotNull("PNG pixels must still be decodable by the platform", BitmapFactory.decodeFile(input.path)?.also { it.recycle() })
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                assertThrows(IOException::class.java) {
                    processor.preview(input, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
                }
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun rawRasterRawSwitchRetainsRawPixels() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val root = testRoot(instrumentation.targetContext, "raster-raw-switch")
        val raw = File(root, "source.RAW")
        val raster = File(root, "source.png")
        instrumentation.context.assets.open("sample.RAW").use { source ->
            raw.outputStream().use { source.copyTo(it) }
        }
        writeGradient(raster, 11, 7)
        try {
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                val before = processor.preview(raw, null, EditSettings(), 160, true, PhotoInputKind.RAW)
                val display = processor.preview(raster, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
                val bitmap = display.bitmap()
                try { assertPixelClose(gradientPixel(11, 7, 3, 2), bitmap.getPixel(3, 2), 1, "neutral display pixels") }
                finally { bitmap.recycle() }
                val after = processor.preview(raw, null, EditSettings(), 160, true, PhotoInputKind.RAW)
                assertFramesClose(before, after, 0)
            }
        } finally {
            root.deleteRecursively()
        }
    }
}

private const val PROGRESSIVE_JPEG_BASE64 = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMU" +
    "FRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU" +
    "FBQUFBQUFBT/wgARCAACAAIDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAf/xAAUAQEAAAAAAAAAAAAAAAAAAAAG/9oA" +
    "DAMBAAIQAxAAAAG6gcA//8QAFhABAQEAAAAAAAAAAAAAAAAABAYD/9oACAEBAAEFApsBtJ7/xAAZEQABBQAAAAAAAAAAAAAAAAAA" +
    "AQIEM3H/2gAIAQMBAT8Bk3v1T//EABkRAAEFAAAAAAAAAAAAAAAAAAABAgMzcf/aAAgBAgEBPwGe1+qf/8QAGxAAAgIDAQAAAAAA" +
    "AAAAAAAAAQIDBAAFESL/2gAIAQEABj8C1bNXiZmqxEkoOnyM/8QAFhABAQEAAAAAAAAAAAAAAAAAAREA/9oACAEBAAE/IUb8PI2V" +
    "m//aAAwDAQACAAMAAAAQ9//EABcRAAMBAAAAAAAAAAAAAAAAAAABUfD/2gAIAQMBAT8Q1qz/xAAXEQADAQAAAAAAAAAAAAAAAAAA" +
    "AVHw/9oACAECAQE/ENis/8QAFxABAQEBAAAAAAAAAAAAAAAAAREAMf/aAAgBAQABPxBLxVstClVVXt3/2Q=="

private const val PNG_SIGNATURE_SIZE = 8

private fun testRoot(context: android.content.Context, prefix: String): File =
    File(context.cacheDir, "$prefix-${UUID.randomUUID()}").apply { mkdirs() }

private fun writeBitmap(file: File, bitmap: Bitmap, format: Bitmap.CompressFormat) {
    file.outputStream().use { output -> check(bitmap.compress(format, 100, output)) }
}

private fun writeGradient(file: File, width: Int, height: Int,
    colorSpace: ColorSpace.Named = ColorSpace.Named.SRGB) {
    val bitmap = gradientBitmap(width, height, colorSpace)
    try {
        writeBitmap(file, bitmap, Bitmap.CompressFormat.PNG)
    } finally {
        bitmap.recycle()
    }
}

private fun gradientBitmap(width: Int, height: Int, colorSpace: ColorSpace.Named = ColorSpace.Named.SRGB): Bitmap =
    Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888, true, ColorSpace.get(colorSpace)).apply {
        for (y in 0 until height) for (x in 0 until width) {
            setPixel(x, y, gradientPixel(width, height, x, y))
        }
    }

private fun gradientPixel(width: Int, height: Int, x: Int, y: Int): Int = Color.rgb(
    (x * 255 / (width - 1)).coerceIn(0, 255),
    (y * 255 / (height - 1)).coerceIn(0, 255),
    (x * 37 + y * 53 + 29) % 256,
)

private fun assertPixelClose(expected: Int, actual: Int, tolerance: Int, message: String) {
    assertTrue(
        message,
        max(
            abs(Color.red(expected) - Color.red(actual)),
            max(abs(Color.green(expected) - Color.green(actual)), abs(Color.blue(expected) - Color.blue(actual))),
        ) <= tolerance,
    )
}

private fun changedPixels(left: NativeFrame, right: NativeFrame, threshold: Int): Int {
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

private fun assertFramesClose(expected: NativeFrame, actual: NativeFrame, tolerance: Int) {
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

private fun assertFrameMatchesBitmap(frame: NativeFrame, bitmap: Bitmap, tolerance: Int) {
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

private data class ParsedDng(
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

private class TiffReader(private val bytes: ByteArray) {
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

private fun parseRenderedDng(bytes: ByteArray): ParsedDng {
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

private fun assertDngAppearanceMatchesPng(dng: ParsedDng, png: Bitmap) {
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

private fun inverseSrgb(value: Float): Float =
    if (value <= 0.04045f) value / 12.92f else ((value + 0.055f) / 1.055f).pow(2.4f)

private fun ByteArray.containsJpegMarker(marker: Int): Boolean {
    for (index in 0 until size - 1) if ((this[index].toInt() and 0xFF) == 0xFF &&
        (this[index + 1].toInt() and 0xFF) == marker) return true
    return false
}

private fun replaceIccChunkWithInvalidProfile(png: ByteArray, badProfile: ByteArray =
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

private fun incompleteRgbProfile(): ByteArray = ByteArray(164).also { bytes ->
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

private fun replacePngChunk(png: ByteArray, offset: Int, oldLength: Int, type: String, data: ByteArray): ByteArray {
    val replacement = makePngChunk(type, data)
    val oldEnd = offset + 12 + oldLength
    return ByteArrayOutputStream(png.size - (oldEnd - offset) + replacement.size).also {
        it.write(png, 0, offset)
        it.write(replacement)
        it.write(png, oldEnd, png.size - oldEnd)
    }.toByteArray()
}

private fun makePngChunk(type: String, data: ByteArray): ByteArray {
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

private fun ByteArray.readBeInt(offset: Int): Int =
    ((this[offset].toInt() and 0xFF) shl 24) or
        ((this[offset + 1].toInt() and 0xFF) shl 16) or
        ((this[offset + 2].toInt() and 0xFF) shl 8) or
        (this[offset + 3].toInt() and 0xFF)

private fun Int.toBeBytes(): ByteArray = byteArrayOf(
    (this ushr 24).toByte(), (this ushr 16).toByte(), (this ushr 8).toByte(), toByte(),
)
