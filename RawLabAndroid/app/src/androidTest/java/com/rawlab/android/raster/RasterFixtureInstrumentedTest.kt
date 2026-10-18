package com.rawlab.android.raster

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.ColorSpace
import android.util.Base64
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
import java.util.zip.DeflaterOutputStream
import kotlin.math.roundToInt
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.EditSettings

// ============================================================================
//  普通图像样张：渐进式 JPEG、广色域与损坏的 ICC、RAW 与普通图像来回切换
// ============================================================================

@RunWith(AndroidJUnit4::class)
class RasterFixtureInstrumentedTest {
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
