package com.rawlab.android.engine

import org.junit.Assert.*
import org.junit.Test

class RgbHistogramTest {
    private fun counts() = IntArray(768).apply {
        this[0] = 2; this[64] = 1; this[255] = 3
        this[256] = 3; this[256 + 128] = 1; this[256 + 255] = 2
        this[512] = 4; this[512 + 192] = 1; this[512 + 255] = 1
    }

    @Test fun copiesChannelMajorCountsAndSharesOnePeak() {
        val input = counts()
        val histogram = requireNotNull(RgbHistogram.fromNative(3, 2, input))
        assertEquals(3, histogram.width)
        assertEquals(2, histogram.height)
        assertEquals(4L, histogram.peak)
        for (channel in 0..2) {
            assertEquals(6L, (0..255).sumOf { histogram.count(channel, it) })
            for (bin in 0..255) assertEquals(input[channel * 256 + bin].toLong(), histogram.count(channel, bin))
        }
        input.fill(0)
        assertEquals(3L, histogram.count(0, 255))
        assertEquals(listOf(RgbHistogram.Segment(0f, .5f, 7), RgbHistogram.Segment(.5f, .75f, 6),
            RgbHistogram.Segment(.75f, 1f, 4)), histogram.segments(0))
        assertEquals(listOf(RgbHistogram.Segment(0f, .25f, 7), RgbHistogram.Segment(.25f, .5f, 3),
            RgbHistogram.Segment(.5f, .75f, 1)), histogram.segments(255))
    }

    @Test fun preservesUnsignedCountsAcrossJniBoundary() {
        val input = IntArray(768).apply { for (channel in 0..2) this[channel * 256] = -1 }
        val histogram = requireNotNull(RgbHistogram.fromNative(65535, 65537, input))
        assertEquals(0xffffffffL, histogram.peak)
        for (channel in 0..2) assertEquals(0xffffffffL, histogram.count(channel, 0))
    }

    @Test fun missingMalformedOrDifferentFrameStatisticsStayUnavailable() {
        assertNull(RgbHistogram.fromNative(3, 2, null))
        assertNull(RgbHistogram.fromNative(3, 2, counts().copyOf(767)))
        assertNull(RgbHistogram.fromNative(3, 3, counts()))
        assertNull(RgbHistogram.fromNative(0, 2, counts()))
        assertNull(RgbHistogram.fromNative(-1, 2, counts()))
        assertNull(RgbHistogram.fromNative(Int.MAX_VALUE, Int.MAX_VALUE, counts()))
        assertNull(RgbHistogram.fromNative(3, 2, counts().apply { this[512] = 5 }))
    }
}
