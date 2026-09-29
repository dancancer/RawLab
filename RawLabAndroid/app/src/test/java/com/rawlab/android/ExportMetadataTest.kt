package com.rawlab.android

import org.junit.Assert.*
import org.junit.Test
import java.util.Locale

class ExportMetadataTest {
    @Test fun apertureUsesOneDecimalRegardlessOfLocale() {
        val previous = Locale.getDefault()
        try {
            Locale.setDefault(Locale.GERMANY)
            assertEquals("5.6", ExportMetadata.aperture(5.63))
            assertEquals("8.0", ExportMetadata.aperture(8.0))
        } finally { Locale.setDefault(previous) }
    }

    @Test fun shutterUsesExactReciprocalWithoutChangingOtherExposures() {
        for (denominator in listOf(25, 60, 200, 8000)) {
            assertEquals("1/$denominator", ExportMetadata.shutter(1.0 / denominator))
        }
        assertEquals("0.3", ExportMetadata.shutter(.3))
        assertEquals("2.5", ExportMetadata.shutter(2.5))
        assertEquals("1.0", ExportMetadata.shutter(1.0))
    }

    @Test fun missingOrInvalidExposureIsNotInvented() {
        for (value in listOf(0.0, -1.0, Double.NaN, Double.POSITIVE_INFINITY)) {
            assertNull(ExportMetadata.aperture(value))
            assertNull(ExportMetadata.shutter(value))
        }
    }
}
