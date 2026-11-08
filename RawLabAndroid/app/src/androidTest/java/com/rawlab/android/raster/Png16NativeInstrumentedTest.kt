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
        assertEquals(16, output.inputStream().use(RasterContainerValidator::inspect).info?.bitDepth)
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

    @Test fun nativeColorConversionMatchesConnectorToOne16BitCodeValue() {
        val srgb = ColorSpace.get(ColorSpace.Named.SRGB)
        val count = 65536
        val pixels = ByteBuffer.allocateDirect(count * 8).order(ByteOrder.LITTLE_ENDIAN)
        val spaces = listOf(ColorSpace.Named.DISPLAY_P3, ColorSpace.Named.ADOBE_RGB,
            ColorSpace.Named.DCI_P3, ColorSpace.Named.BT709, ColorSpace.Named.SMPTE_C,
            ColorSpace.Named.NTSC_1953, ColorSpace.Named.PRO_PHOTO_RGB)
        for (named in spaces) for (neutral in listOf(true, false)) {
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
            NativePng16.convertToSrgb(pixels, source)
            for (i in 0 until count) {
                for (c in 0..2) assertTrue("$named neutral=$neutral sample=$i channel=$c",
                    abs(expected[i * 3 + c] - (pixels.getShort(i * 8 + c * 2).toInt() and 65535)) <= 1)
                assertEquals(65535, pixels.getShort(i * 8 + 6).toInt() and 65535)
            }
        }
    }

    @Test fun optional24MpColorConversionTiming() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("png16Performance") == "true")
        val count = 24_000_000
        val pixels = ByteBuffer.allocateDirect(count * 8).order(ByteOrder.LITTLE_ENDIAN)
        val source = ColorSpace.get(ColorSpace.Named.DISPLAY_P3)
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
        NativePng16.convertToSrgb(pixels, source)
        val newMillis = (System.nanoTime() - newStart) / 1_000_000
        for (i in listOf(0, count / 2, count - 1)) for (c in 0..2)
            assertTrue(abs(expected[c] - (pixels.getShort(i * 8 + c * 2).toInt() and 65535)) <= 1)
        Log.i("RawLabPng16", "24 MP Display P3: Connector=${oldMillis}ms native=${newMillis}ms")
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
