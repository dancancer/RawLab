package com.rawlab.android.testing

import android.graphics.Bitmap
import com.rawlab.android.engine.RgbHistogram
import org.junit.Assert.assertEquals

fun assertHistogramMatches(bitmap: Bitmap, actual: RgbHistogram?) {
    val histogram = requireNotNull(actual) { "Accepted exact frame requires its own histogram" }
    assertEquals(bitmap.width, histogram.width)
    assertEquals(bitmap.height, histogram.height)
    val row = IntArray(bitmap.width)
    val expected = LongArray(768)
    for (y in 0 until bitmap.height) {
        bitmap.getPixels(row, 0, bitmap.width, 0, y, bitmap.width, 1)
        for (pixel in row) {
            expected[pixel ushr 16 and 255]++
            expected[256 + (pixel ushr 8 and 255)]++
            expected[512 + (pixel and 255)]++
        }
    }
    for (index in expected.indices) assertEquals("channel ${index / 256}, bin ${index % 256}",
        expected[index], histogram.count(index / 256, index % 256))
}
