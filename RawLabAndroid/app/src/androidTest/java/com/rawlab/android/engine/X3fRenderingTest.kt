package com.rawlab.android.engine

import android.graphics.BitmapFactory
import androidx.exifinterface.media.ExifInterface
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HslTargetAvailability
import com.rawlab.android.settings.HslTargetRevision
import com.rawlab.android.settings.LensSettings
import com.rawlab.android.settings.X3fMode
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class X3fRenderingTest {
    @Test fun realX3fModesRelativeWhiteBalanceAndExports() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val directory = File(context.cacheDir, "x3f-native-${System.nanoTime()}").apply { mkdirs() }
        val input = File(directory, "source.X3F")
        val bytes = instrumentation.context.assets.open("sample.X3F").use { it.readBytes() }
        input.writeBytes(bytes)
        val storage = PhotoStorage(context)
        try {
            NativeProcessor(NativeProcessor.CPU, storage.lensDatabase()).use { processor ->
                assertTrue(NativeProcessor.nativeX3fAvailable())
                val normal = EditSettings()
                val legacy = normal.copy(x3fMode = X3fMode.LEGACY)
                val a = processor.preview(input, null, normal, 384, false)
                val b = processor.preview(input, null, legacy, 384, false)
                val c = processor.preview(input, null, normal, 384, false)
                assertFalse(a.pixels.contentEquals(b.pixels)); assertArrayEquals(a.pixels, c.pixels)
                assertEquals(6500f, a.temperature); assertEquals(0f, a.tint)
                val custom = normal.copy(exposure = .5f, customWb = true, temperature = 4800f, tint = 12f)
                assertFalse(a.pixels.contentEquals(processor.preview(input, null, custom, 384, false).pixels))
                assertTrue(processor.autoExposure(input, normal).isFinite())
                val sample = processor.sampleHsl(input, null, normal, 384, false,
                    com.rawlab.android.format.PhotoInputKind.RAW, HslTargetRevision(1, 1), .5f, .5f)
                assertNotEquals(HslTargetAvailability.FAILED, sample.availability)
                for (format in listOf(ExportFormat.JPEG, ExportFormat.PNG)) {
                    val output = File(directory, if (format == ExportFormat.PNG) "edited.png" else "edited.jpg")
                    processor.export(input, null, custom, output, format, 512)
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeFile(output.path, bounds)
                    assertEquals(512, maxOf(bounds.outWidth, bounds.outHeight))
                    assertEquals(ExifInterface.ORIENTATION_NORMAL, ExifInterface(output).getAttributeInt(ExifInterface.TAG_ORIENTATION, -1))
                    if (format == ExportFormat.PNG) assertEquals(16, output.readBytes()[24].toInt())
                }
                val dng = File(directory, "edited.dng")
                processor.export(input, null, custom, dng, ExportFormat.DNG, 512)
                assertTrue(dng.length() > 1024)
                val failure = assertThrows(Exception::class.java) {
                    processor.preview(input, null, normal.copy(lens = LensSettings(distortion = true)), 128, false)
                }
                assertTrue(failure.message.orEmpty().contains("lens"))
                assertArrayEquals(b.pixels, processor.preview(input, null, legacy, 384, false).pixels)
            }
            assertArrayEquals(bytes, input.readBytes())
        } finally { storage.close(); directory.deleteRecursively() }
    }
}
