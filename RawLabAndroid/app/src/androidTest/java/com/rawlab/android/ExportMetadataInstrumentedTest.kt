package com.rawlab.android

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import androidx.exifinterface.media.ExifInterface
import androidx.exifinterface.media.ExifInterface.*
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.File

class ExportMetadataInstrumentedTest {
    @Test fun jpegAndPngKeepCaptureMetadataWithoutChangingPixelsOrSource() {
        val directory = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir
        val input = File(directory, "metadata-source.input")
        writeImage(input, Bitmap.CompressFormat.JPEG, 80, 40)
        val source = ExifInterface(input)
        val expected = mapOf(
            TAG_MAKE to "SONY", TAG_MODEL to "ILCE-7CM2", TAG_LENS_MODEL to "Test lens",
            TAG_DATETIME_ORIGINAL to "2025:06:02 11:53:00", TAG_OFFSET_TIME_ORIGINAL to "+08:00",
            TAG_PHOTOGRAPHIC_SENSITIVITY to "100", TAG_RECOMMENDED_EXPOSURE_INDEX to "100",
        )
        expected.forEach { (tag, value) -> source.setAttribute(tag, value) }
        source.setAttribute(TAG_F_NUMBER, "5.63")
        source.setAttribute(TAG_EXPOSURE_TIME, "1/200")
        source.setAttribute(TAG_ORIENTATION, ORIENTATION_ROTATE_90.toString())
        source.setAttribute(TAG_PIXEL_X_DIMENSION, "80")
        source.setAttribute(TAG_PIXEL_Y_DIMENSION, "40")
        source.setAttribute(TAG_MAKER_NOTE, "Do not copy RAW vendor offsets")
        source.setLatLong(7.88, 98.39)
        source.setAltitude(12.5)
        source.saveAttributes()
        val original = input.readBytes()
        try {
            for ((extension, format) in listOf("jpg" to Bitmap.CompressFormat.JPEG, "png" to Bitmap.CompressFormat.PNG)) {
                val output = File(directory, "metadata-output.$extension")
                try {
                    writeImage(output, format, 32, 24)
                    val pixels = BitmapFactory.decodeFile(output.path)
                    val pngData = if (extension == "png") pngImageData(output) else null
                    ExportMetadata.preserve(input, output)
                    val result = ExifInterface(output)
                    expected.forEach { (tag, value) -> assertEquals(tag, value, result.getAttribute(tag)) }
                    assertEquals(5.6, result.getAttributeDouble(TAG_F_NUMBER, 0.0), .000001)
                    assertEquals(1.0 / 200, result.getAttributeDouble(TAG_EXPOSURE_TIME, 0.0), .000001)
                    assertArrayEquals(doubleArrayOf(7.88, 98.39), result.latLong, .000001)
                    assertEquals(12.5, result.getAltitude(0.0), .000001)
                    assertEquals(ORIENTATION_NORMAL, result.getAttributeInt(TAG_ORIENTATION, 0))
                    assertEquals(32, result.getAttributeInt(TAG_PIXEL_X_DIMENSION, 0))
                    assertEquals(24, result.getAttributeInt(TAG_PIXEL_Y_DIMENSION, 0))
                    assertEquals(1, result.getAttributeInt(TAG_COLOR_SPACE, 0))
                    assertNull(result.getAttribute(TAG_MAKER_NOTE))
                    assertFalse(result.hasThumbnail())
                    val after = BitmapFactory.decodeFile(output.path)
                    assertTrue("$extension pixels must not change", pixels.sameAs(after))
                    pixels.recycle()
                    after.recycle()
                    if (pngData != null) assertArrayEquals(pngData, pngImageData(output))
                    assertArrayEquals(original, input.readBytes())
                } finally { output.delete() }
            }
        } finally { input.delete() }
    }

    @Test fun missingCaptureTagsRemainMissingAndSourceCannotBeOverwritten() {
        val directory = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir
        val input = File(directory, "metadata-empty.input")
        val output = File(directory, "metadata-empty.jpg")
        try {
            writeImage(input, Bitmap.CompressFormat.JPEG, 32, 24)
            writeImage(output, Bitmap.CompressFormat.JPEG, 32, 24)
            ExportMetadata.preserve(input, output)
            val result = ExifInterface(output)
            assertNull(result.getAttribute(TAG_F_NUMBER))
            assertNull(result.getAttribute(TAG_EXPOSURE_TIME))
            assertNull(result.latLong)
            assertThrows(IllegalArgumentException::class.java) { ExportMetadata.preserve(input, input) }
        } finally { input.delete(); output.delete() }
    }

    private fun writeImage(file: File, format: Bitmap.CompressFormat, width: Int, height: Int) {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.rgb(24, 130, 215))
        try { file.outputStream().use { assertTrue(bitmap.compress(format, 95, it)) } }
        finally { bitmap.recycle() }
    }

    private fun pngImageData(file: File): ByteArray {
        val result = ByteArrayOutputStream()
        DataInputStream(file.inputStream()).use { input ->
            input.readLong()
            while (true) {
                val size = input.readInt()
                val type = ByteArray(4).also(input::readFully).toString(Charsets.US_ASCII)
                val data = ByteArray(size).also(input::readFully)
                input.readInt()
                if (type == "IHDR" || type == "IDAT") result.write(data)
                if (type == "IEND") break
            }
        }
        return result.toByteArray()
    }
}
