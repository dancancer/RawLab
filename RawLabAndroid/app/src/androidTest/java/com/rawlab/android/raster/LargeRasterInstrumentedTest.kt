package com.rawlab.android.raster

import android.graphics.Bitmap
import android.graphics.Color
import androidx.exifinterface.media.ExifInterface
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class LargeRasterInstrumentedTest {
    @Test
    fun mediumFormatJpegAndPngDecodeAtNativeResolution() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("largeRasterImport") == "true")
        decodeLargeImage(11656, 8742, Bitmap.CompressFormat.JPEG)
        decodeLargeImage(11656, 8742, Bitmap.CompressFormat.JPEG, rotate = true)
        decodeLargeImage(11808, 8754, Bitmap.CompressFormat.PNG)
    }

    private fun decodeLargeImage(width: Int, height: Int, format: Bitmap.CompressFormat, rotate: Boolean = false) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val input = File.createTempFile("large-raster-", if (format == Bitmap.CompressFormat.JPEG) ".jpg" else ".png", context.cacheDir)
        try {
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            try {
                bitmap.eraseColor(Color.rgb(52, 104, 154))
                input.outputStream().use { assertTrue(bitmap.compress(format, 95, it)) }
            } finally { bitmap.recycle() }
            if (rotate) ExifInterface(input).apply {
                setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
                saveAttributes()
            }
            val decoded = RasterImageDecoder.decode(input)
            decoded.use {
                assertEquals(if (rotate) height else width, it.width)
                assertEquals(if (rotate) width else height, it.height)
                assertEquals(width.toLong() * height * 4, it.bitmap.byteCount.toLong())
                for ((x, y) in listOf(0 to 0, it.width / 2 to it.height / 2, it.width - 1 to it.height - 1)) {
                    val pixel = it.bitmap.getPixel(x, y)
                    for ((channel, expected) in listOf(52, 104, 154, 255).withIndex()) {
                        val actual = listOf(Color.red(pixel), Color.green(pixel), Color.blue(pixel), Color.alpha(pixel))[channel]
                        assertTrue("$format $width x $height channel $channel: $actual", kotlin.math.abs(actual - expected) <= 2)
                    }
                }
            }
            assertTrue("Decoded bitmap is released when closed", decoded.bitmap.isRecycled)
        } finally { input.delete() }
    }
}
