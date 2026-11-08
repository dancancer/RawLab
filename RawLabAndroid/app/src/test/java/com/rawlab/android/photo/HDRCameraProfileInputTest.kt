package com.rawlab.android.photo

import java.io.IOException
import org.junit.Assert.*
import org.junit.Test
import java.io.InputStream
import java.io.OutputStream

class HDRCameraProfileInputTest {
    private class GeneratedInput(private val size: Long) : InputStream() {
        var consumed = 0L
        override fun read(): Int = if (consumed < size) { consumed++; 0 } else -1
        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            if (consumed == size) return -1
            val count = minOf(length.toLong(), size - consumed).toInt()
            consumed += count
            return count
        }
    }
    private class CountingOutput : OutputStream() {
        var size = 0L
        override fun write(value: Int) { size++ }
        override fun write(buffer: ByteArray, offset: Int, length: Int) { size += length }
    }

    @Test fun sourceLimitMatchesTheNativeDcpReader() {
        assertEquals(128L * 1024 * 1024, maximumHDRCameraProfileBytes)
    }

    @Test fun knownSizesAreCheckedBeforeOpeningTheInputStream() {
        checkHDRCameraProfileSize(null)
        checkHDRCameraProfileSize(1)
        checkHDRCameraProfileSize(maximumHDRCameraProfileBytes)
        for (size in listOf(0L, maximumHDRCameraProfileBytes + 1, Long.MAX_VALUE)) {
            assertThrows(IOException::class.java) { checkHDRCameraProfileSize(size) }
        }
    }

    @Test fun anExactLimitInputIsAcceptedWithoutBufferingTheWholeFile() {
        val output = CountingOutput()
        copyHDRCameraProfileSource(GeneratedInput(maximumHDRCameraProfileBytes), output)
        assertEquals(maximumHDRCameraProfileBytes, output.size)
    }

    @Test fun anUnknownLengthOversizedInputStopsBeforeWritingPastTheLimit() {
        val input = GeneratedInput(maximumHDRCameraProfileBytes * 2)
        val output = CountingOutput()
        assertThrows(IOException::class.java) { copyHDRCameraProfileSource(input, output) }
        assertTrue(output.size <= maximumHDRCameraProfileBytes)
        assertEquals(maximumHDRCameraProfileBytes + 1, input.consumed)
    }

    @Test fun anEmptyInputIsRejectedBeforeProbing() {
        assertThrows(IOException::class.java) {
            copyHDRCameraProfileSource(GeneratedInput(0), CountingOutput())
        }
    }
}
