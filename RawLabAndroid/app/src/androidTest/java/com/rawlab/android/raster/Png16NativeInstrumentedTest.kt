package com.rawlab.android.raster

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.ColorSpace
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.EditSettings
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.DeflaterOutputStream
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.roundToInt
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class Png16NativeInstrumentedTest {
    @Test fun untaggedInteger16PngKeepsSrgbSamples() = withDirectory { root ->
        val input = File(root, "untagged.png")
        write16(input, intArrayOf(0x1234, 0x5678, 0x7a01), colorChunk = byteArrayOf())
        RasterImageDecoder.decode(input).use { decoded ->
            val pixels = decoded.pixels as ByteBuffer
            assertEquals(0x1234, pixels.getShort(0).toInt() and 65535)
            assertEquals(0x5678, pixels.getShort(2).toInt() and 65535)
            assertEquals(0x7a01, pixels.getShort(4).toInt() and 65535)
        }
    }

    @Test fun lowBitsSurviveJniExposureExportAndReimport() = withDirectory { root ->
        val input = File(root, "source.png")
        val output = File(root, "export.png")
        val rgb = intArrayOf(0x27b6, 0x27b6, 0x27b6, 0x27b7, 0x27b7, 0x27b7)
        write16(input, rgb)
        RasterImageDecoder.decode(input).use { decoded ->
            assertEquals(2, decoded.pixelFormat)
            val pixels = decoded.pixels as ByteBuffer
            assertTrue(pixels.isDirect)
            assertEquals(0x27b6, pixels.getShort(0).toInt() and 65535)
            assertEquals(0x27b7, pixels.getShort(8).toInt() and 65535)
            assertEquals(65535, pixels.getShort(6).toInt() and 65535)
        }
        NativeProcessor(NativeProcessor.CPU).use { processor ->
            val frame = processor.preview(input, null, EditSettings(exposure = 1f), 1600, false, PhotoInputKind.RASTER)
            val bitmap = frame.bitmap()
            try {
                assertEquals(57, Color.red(bitmap.getPixel(0, 0)))
                assertEquals(58, Color.red(bitmap.getPixel(1, 0)))
            } finally { bitmap.recycle() }
            assertTrue(processor.autoExposure(input, EditSettings(), PhotoInputKind.RASTER).isFinite())
            assertEquals(2, processor.previewCompatibility(input, PhotoInputKind.RASTER, null, null).width)
            processor.export(input, null, EditSettings(), output, ExportFormat.PNG, null, PhotoInputKind.RASTER)
        }
        assertEquals(16, RasterContainerValidator.inspect(output).info?.bitDepth)
        RasterImageDecoder.decode(output).use { decoded ->
            val pixels = decoded.pixels as ByteBuffer
            for (i in rgb.indices) {
                val offset = (i / 3) * 8 + (i % 3) * 2
                assertTrue("Export retained 16-bit sample $i", abs(rgb[i] - (pixels.getShort(offset).toInt() and 65535)) <= 1)
            }
            assertTrue(pixels.getShort(0) != pixels.getShort(8))
            decoded.close()
            assertThrows(IllegalStateException::class.java) { decoded.pixels }
        }
    }

    @Test fun orientationAndOpacityAreCheckedAtSixteenBitPrecision() = withDirectory { root ->
        val input = File(root, "oriented.png")
        write16(input, intArrayOf(0x1234, 0x5678, 0x7a01, 0x1235, 0x5679, 0x7a02))
        ExifInterface(input).apply {
            setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
            saveAttributes()
        }
        RasterImageDecoder.decode(input).use { decoded ->
            assertEquals(1, decoded.width); assertEquals(2, decoded.height)
            val pixels = decoded.pixels as ByteBuffer
            assertEquals(0x1234, pixels.getShort(0).toInt() and 65535)
            assertEquals(0x1235, pixels.getShort(8).toInt() and 65535)
        }
        val alpha = File(root, "alpha.png")
        write16(alpha, intArrayOf(0x1234, 0x5678, 0x7a01, 0x1235, 0x5679, 0x7a02), alpha = 65534)
        assertThrows(IOException::class.java) { RasterImageDecoder.decode(alpha).close() }
    }

    @Test fun taggedRgbUsesTheSameSrgbConversionAsEightBitImages() = withDirectory { root ->
        for (space in listOf(ColorSpace.Named.DISPLAY_P3, ColorSpace.Named.ADOBE_RGB)) {
            val reference = gradientBitmap(2, 2, space)
            try {
                val eight = File(root, "$space-8.png")
                writeBitmap(eight, reference, Bitmap.CompressFormat.PNG)
                val source = eight.readBytes()
                var offset = 8
                var profile = byteArrayOf()
                while (offset < source.size) {
                    val length = ByteBuffer.wrap(source, offset, 4).int
                    if (source.copyOfRange(offset + 4, offset + 8).toString(Charsets.US_ASCII) == "iCCP")
                        profile = source.copyOfRange(offset, offset + length + 12)
                    offset += length + 12
                }
                assertTrue("Fixture must carry ICC", profile.isNotEmpty())
                val samples = IntArray(12)
                for (y in 0..1) for (x in 0..1) {
                    val color = reference.getColor(x, y)
                    val i = (y * 2 + x) * 3
                    samples[i] = (color.red() * 65535).roundToInt()
                    samples[i + 1] = (color.green() * 65535).roundToInt()
                    samples[i + 2] = (color.blue() * 65535).roundToInt()
                }
                val input = File(root, "$space-16.png")
                write16(input, samples, height = 2, colorChunk = profile)
                RasterImageDecoder.decode(eight).use { decoded8 ->
                    RasterImageDecoder.decode(input).use { decoded16 ->
                        val pixels = decoded16.pixels as ByteBuffer
                        for (y in 0..1) for (x in 0..1) {
                            val start = (y * 2 + x) * 8
                            val channels = IntArray(3) { c ->
                                ((pixels.getShort(start + c * 2).toInt() and 65535) * 255f / 65535).roundToInt()
                            }
                            val value = Color.rgb(channels[0], channels[1], channels[2])
                            assertPixelClose(decoded8.bitmap.getPixel(x, y), value, 2, "$space conversion")
                        }
                    }
                }
            } finally { reference.recycle() }
        }
    }

    @Test fun a2b0LutIccPng16ConvertsToSrgbMatchingDesktopDisplayImage() = withDirectory { root ->
        val icc = pureA2b0LutIccProfile()
        val iccpPayload = "RawLab A2B0".toByteArray(Charsets.US_ASCII) + byteArrayOf(0, 0) +
            ByteArrayOutputStream().also { out -> DeflaterOutputStream(out).use { it.write(icc) } }.toByteArray()
        val samples = intArrayOf(
            32768, 49152, 24576,
            49152, 32768, 24576,
            24576, 32768, 49152,
            32768, 32768, 32768,
            0, 0, 0,
            65535, 65535, 65535,
        )
        val expectedLcms = intArrayOf(
            27504, 50054, 20652, 65535,
            52339, 32080, 22822, 65535,
            22051, 33320, 50861, 65535,
            33015, 33023, 33027, 65535,
            0, 0, 0, 65535,
            65533, 65534, 65535, 65535,
        )
        val expectedDesktopDisplayImage = intArrayOf(
            27507, 50054, 20652, 65535,
            52340, 32079, 22824, 65535,
            22045, 33322, 50861, 65535,
            33020, 33021, 33028, 65535,
            0, 0, 0, 65535,
            65533, 65534, 65535, 65535,
        )
        val input = File(root, "a2b0-lut-16.png")
        val exported = File(root, "a2b0-exported-16.png")
        write16(input, samples, height = 3, colorChunk = makePngChunk("iCCP", iccpPayload))

        val inspection = RasterContainerValidator.inspect(input)
        assertTrue("Pure A2B0 LUT PNG16 must pass container inspection", inspection.isValid)
        assertEquals(16, inspection.info?.bitDepth)
        assertTrue(inspection.info?.iccProfile?.contentEquals(icc) == true)

        RasterImageDecoder.decode(input).use { decoded ->
            assertEquals(2, decoded.width)
            assertEquals(3, decoded.height)
            assertEquals(2, decoded.pixelFormat)
            val pixels = decoded.pixels as ByteBuffer
            for (i in expectedLcms.indices) {
                val actual = pixels.getShort(i * 2).toInt() and 65535
                assertTrue("lcms2 sample $i actual=$actual expected=${expectedLcms[i]}",
                    abs(actual - expectedLcms[i]) <= 1)
                assertTrue("desktop display_image sample $i actual=$actual desktop=${expectedDesktopDisplayImage[i]}",
                    abs(actual - expectedDesktopDisplayImage[i]) <= 6)
            }
        }

        NativeProcessor(NativeProcessor.CPU).use { processor ->
            val preview = processor.preview(input, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
            assertEquals(2, preview.width)
            assertEquals(3, preview.height)
            assertEquals(0, processor.export(input, null, EditSettings(), exported, ExportFormat.PNG, null, PhotoInputKind.RASTER))
        }
        RasterImageDecoder.decode(exported).use { reimported ->
            val pixels = reimported.pixels as ByteBuffer
            for (i in expectedLcms.indices) {
                val actual = pixels.getShort(i * 2).toInt() and 65535
                assertTrue("Exported PNG16 sample $i actual=$actual expected=${expectedLcms[i]}",
                    abs(actual - expectedLcms[i]) <= 1)
            }
        }
    }

    @Test fun nativeColorConversionMatchesConnectorWithinIccFixedPointPrecision() {
        val srgb = ColorSpace.get(ColorSpace.Named.SRGB)
        val count = 65536
        val pixels = ByteBuffer.allocateDirect(count * 8).order(ByteOrder.LITTLE_ENDIAN)
        val spaces = listOf(ColorSpace.Named.DISPLAY_P3, ColorSpace.Named.ADOBE_RGB,
            ColorSpace.Named.DCI_P3, ColorSpace.Named.BT709, ColorSpace.Named.SMPTE_C,
            ColorSpace.Named.NTSC_1953, ColorSpace.Named.PRO_PHOTO_RGB)
        for (named in spaces) {
            val icc = iccBytesFor(named)
            for (neutral in listOf(true, false)) {
                val source = ColorSpace.get(named)
                val connector = ColorSpace.connect(source, srgb)
                val expected = IntArray(count * 3)
                for (i in 0 until count) {
                    val rgb = intArrayOf(i, if (neutral) i else (i * 251 + 17) and 65535,
                        if (neutral) i else (i * 97 + 127) and 65535)
                    for (c in 0..2) pixels.putShort(i * 8 + c * 2, rgb[c].toShort())
                    pixels.putShort(i * 8 + 6, 65535.toShort())
                    val converted = connector.transform(FloatArray(3) { rgb[it] / 65535f })
                    for (c in 0..2) expected[i * 3 + c] = (converted[c].coerceIn(0f, 1f) * 65535).roundToInt()
                }
                NativePng16.convertToSrgb(pixels, icc)
                for (i in 0 until count) {
                    for (c in 0..2) {
                        val actual = pixels.getShort(i * 8 + c * 2).toInt() and 65535
                        // ICC s15Fixed16 matrix/TRC tags quantize float32 ColorSpace constants by ~20 LSB (<0.1 in 8-bit).
                        assertTrue("$named neutral=$neutral sample=$i channel=$c actual=$actual expected=${expected[i * 3 + c]}",
                            abs(expected[i * 3 + c] - actual) <= 48)
                    }
                    assertEquals(65535, pixels.getShort(i * 8 + 6).toInt() and 65535)
                }
            }
        }
    }

    @Test fun optional24MpColorConversionTiming() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("png16Performance") == "true")
        val count = 24_000_000
        val pixels = ByteBuffer.allocateDirect(count * 8).order(ByteOrder.LITTLE_ENDIAN)
        val source = ColorSpace.get(ColorSpace.Named.DISPLAY_P3)
        val icc = iccBytesFor(ColorSpace.Named.DISPLAY_P3)
        val connector = ColorSpace.connect(source, ColorSpace.get(ColorSpace.Named.SRGB))
        fun fill() {
            for (i in 0 until count) {
                pixels.putShort(i * 8, 0x1234.toShort())
                pixels.putShort(i * 8 + 2, 0x5678.toShort())
                pixels.putShort(i * 8 + 4, 0x7a01.toShort())
                pixels.putShort(i * 8 + 6, 65535.toShort())
            }
        }
        fill()
        val rgb = FloatArray(3)
        val oldStart = System.nanoTime()
        for (i in 0 until count) {
            for (c in 0..2) rgb[c] = (pixels.getShort(i * 8 + c * 2).toInt() and 65535) / 65535f
            connector.transform(rgb)
            for (c in 0..2) pixels.putShort(i * 8 + c * 2,
                (rgb[c].coerceIn(0f, 1f) * 65535).roundToInt().toShort())
        }
        val oldMillis = (System.nanoTime() - oldStart) / 1_000_000
        val expected = IntArray(3) { pixels.getShort(it * 2).toInt() and 65535 }
        fill()
        val newStart = System.nanoTime()
        NativePng16.convertToSrgb(pixels, icc)
        val newMillis = (System.nanoTime() - newStart) / 1_000_000
        for (i in listOf(0, count / 2, count - 1)) for (c in 0..2)
            assertTrue(abs(expected[c] - (pixels.getShort(i * 8 + c * 2).toInt() and 65535)) <= 32)
        Log.i("RawLabPng16", "24 MP Display P3: Connector=${oldMillis}ms lcms2=${newMillis}ms")
    }

    private fun iccBytesFor(space: ColorSpace.Named): ByteArray {
        val bitmap = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888, false, ColorSpace.get(space))
        val png = ByteArrayOutputStream().also { out ->
            try { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) }
            finally { bitmap.recycle() }
        }.toByteArray()
        var offset = 8
        while (offset + 12 <= png.size) {
            val length = ByteBuffer.wrap(png, offset, 4).int
            if (png.copyOfRange(offset + 4, offset + 8).toString(Charsets.US_ASCII) == "iCCP") {
                return checkNotNull(IccProfiles.decodePngChunk(png.copyOfRange(offset + 8, offset + 8 + length)))
            }
            offset += length + 12
        }
        error("Expected iCCP chunk for $space")
    }

    private fun pureA2b0LutIccProfile(): ByteArray {
        fun putBe16(out: ByteArrayOutputStream, v: Int) { out.write((v ushr 8) and 0xFF); out.write(v and 0xFF) }
        fun putBe32(out: ByteArrayOutputStream, v: Int) {
            out.write((v ushr 24) and 0xFF); out.write((v ushr 16) and 0xFF)
            out.write((v ushr 8) and 0xFF); out.write(v and 0xFF)
        }
        fun putS15Fixed16(out: ByteArrayOutputStream, v: Double) = putBe32(out, (v * 65536.0).roundToInt())
        fun mft2(forward: Boolean): ByteArray = ByteArrayOutputStream().also { t ->
            val grid = 9; val entries = 256
            t.write("mft2".toByteArray(Charsets.US_ASCII))
            t.write(byteArrayOf(0, 0, 0, 0, 3, 3, grid.toByte(), 0))
            for (r in 0..2) for (c in 0..2) putS15Fixed16(t, if (r == c) 1.0 else 0.0)
            putBe16(t, entries); putBe16(t, entries)
            for (ch in 0..2) for (i in 0 until entries) {
                val y = if (forward) ((i / 255.0).pow(2.2) * 65535.0).roundToInt() else i * 257
                putBe16(t, y)
            }
            for (ri in 0 until grid) for (gi in 0 until grid) for (bi in 0 until grid) {
                val rf = ri / (grid - 1.0); val gf = gi / (grid - 1.0); val bf = bi / (grid - 1.0)
                if (forward) {
                    val x = 0.515102 * rf + 0.291965 * gf + 0.157153 * bf
                    val y = 0.241182 * rf + 0.692237 * gf + 0.066582 * bf
                    val z = max(0.0, -0.001049 * rf + 0.041882 * gf + 0.784378 * bf)
                    putBe16(t, (x * 32768.0).roundToInt().coerceIn(0, 65535))
                    putBe16(t, (y * 32768.0).roundToInt().coerceIn(0, 65535))
                    putBe16(t, (z * 32768.0).roundToInt().coerceIn(0, 65535))
                } else {
                    putBe16(t, (rf * 65535.0).roundToInt())
                    putBe16(t, (gf * 65535.0).roundToInt())
                    putBe16(t, (bf * 65535.0).roundToInt())
                }
            }
            for (ch in 0..2) for (i in 0 until entries) putBe16(t, i * 257)
        }.toByteArray()

        val name = "RawLab A2B0 P3".toByteArray(Charsets.US_ASCII) + byteArrayOf(0)
        val desc = ByteArrayOutputStream().also {
            it.write("desc".toByteArray(Charsets.US_ASCII)); putBe32(it, 0); putBe32(it, name.size)
            it.write(name); it.write(ByteArray(79))
        }.toByteArray()
        val cprt = "text\u0000\u0000\u0000\u0000RawLab\u0000".toByteArray(Charsets.US_ASCII)
        val wtpt = ByteArrayOutputStream().also {
            it.write("XYZ ".toByteArray(Charsets.US_ASCII)); putBe32(it, 0)
            putS15Fixed16(it, 0.9642029); putS15Fixed16(it, 1.0); putS15Fixed16(it, 0.8249054)
        }.toByteArray()
        val tags = listOf("desc" to desc, "cprt" to cprt, "wtpt" to wtpt, "A2B0" to mft2(true), "B2A0" to mft2(false))
        val body = ByteArrayOutputStream()
        val header = ByteBuffer.allocate(132 + tags.size * 12).order(ByteOrder.BIG_ENDIAN)
        header.put(8, 2); header.put(9, 0x40)
        for ((off, sig) in listOf(12 to "mntr", 16 to "RGB ", 20 to "XYZ ", 36 to "acsp")) {
            header.position(off); header.put(sig.toByteArray(Charsets.US_ASCII))
        }
        header.position(68); header.put(wtpt, 8, 12)
        header.putInt(128, tags.size)
        val tableEnd = 132 + tags.size * 12
        tags.forEachIndexed { index, (sig, data) ->
            while ((tableEnd + body.size()) % 4 != 0) body.write(0)
            val offset = tableEnd + body.size()
            val entry = 132 + index * 12
            header.position(entry); header.put(sig.toByteArray(Charsets.US_ASCII))
            header.putInt(entry + 4, offset); header.putInt(entry + 8, data.size)
            body.write(data)
        }
        val total = tableEnd + body.size()
        header.putInt(0, total)
        return header.array() + body.toByteArray()
    }

    private fun write16(file: File, rgb: IntArray, height: Int = 1, alpha: Int? = null,
        colorChunk: ByteArray = makePngChunk("sRGB", byteArrayOf(0))) {
        val width = rgb.size / 3 / height
        val header = ByteBuffer.allocate(13).putInt(width).putInt(height).put(16)
            .put(if (alpha == null) 2.toByte() else 6.toByte()).put(0).put(0).put(0).array()
        val compressed = ByteArrayOutputStream().also { bytes ->
            DeflaterOutputStream(bytes).use { stream ->
                for (y in 0 until height) {
                    stream.write(0)
                    for (x in 0 until width) {
                        for (c in 0..2) {
                            val value = rgb[(y * width + x) * 3 + c]
                            stream.write(value ushr 8); stream.write(value and 255)
                        }
                        if (alpha != null) { stream.write(alpha ushr 8); stream.write(alpha and 255) }
                    }
                }
            }
        }.toByteArray()
        file.writeBytes(byteArrayOf(137.toByte(), 80, 78, 71, 13, 10, 26, 10) + makePngChunk("IHDR", header) +
            colorChunk + makePngChunk("IDAT", compressed) + makePngChunk("IEND", byteArrayOf()))
    }

    private fun withDirectory(action: (File) -> Unit) {
        val root = testRoot(InstrumentationRegistry.getInstrumentation().targetContext, "png16-native")
        try { action(root) } finally { root.deleteRecursively() }
    }
}
