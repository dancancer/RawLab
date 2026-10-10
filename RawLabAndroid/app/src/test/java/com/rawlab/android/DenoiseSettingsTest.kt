package com.rawlab.android

import org.junit.Assert.*
import org.junit.Test

class DenoiseSettingsTest {
    @Test fun presetsPreserveTextureAndSwitchDoesNotDiscardValues() {
        val initial = EditSettings().denoise
        assertFalse(initial.enabled)
        assertEquals(listOf(0f, 46f, 50f), listOf(initial.luma, initial.chroma, initial.coarse))
        val clean = initial.withPreset(DenoisePreset.CLEAN)
        assertTrue(clean.enabled)
        assertEquals(listOf(10f, 72f, 100f), listOf(clean.luma, clean.chroma, clean.coarse))
        val custom = clean.copy(luma = 25f)
        assertEquals(DenoisePreset.CUSTOM, custom.preset)
        assertEquals(custom, custom.copy(enabled = false).copy(enabled = true))
        assertEquals(initial, EditSettings(denoise = clean).reset().denoise)
    }

    @Test fun invalidStrengthsCannotReachNativeProcessing() {
        for (bad in listOf(-1f, 101f, Float.NaN, Float.POSITIVE_INFINITY)) {
            assertThrows(IllegalArgumentException::class.java) { DenoiseSettings(luma = bad) }
            assertThrows(IllegalArgumentException::class.java) { DenoiseSettings(chroma = bad) }
            assertThrows(IllegalArgumentException::class.java) { DenoiseSettings(coarse = bad) }
        }
    }
}
