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

    @Test fun photoEffectsUseCanonicalDefaultsAndKeepAuxiliaryValuesWhenAmountIsZero() {
        val initial = PhotoEffectsSettings()
        assertEquals(listOf(0f, 50f, 0f, 50f, 0f, 0f, 25f, 50f), listOf(
            initial.vignetteAmount, initial.vignetteMidpoint, initial.vignetteRoundness,
            initial.vignetteFeather, initial.vignetteHighlights, initial.grainAmount,
            initial.grainSize, initial.grainRoughness))

        val changed = initial
            .withEffect(PhotoEffectParameter.VIGNETTE_AMOUNT, -40f)
            .withEffect(PhotoEffectParameter.VIGNETTE_MIDPOINT, 20f)
            .withEffect(PhotoEffectParameter.GRAIN_AMOUNT, 65f)
            .withEffect(PhotoEffectParameter.GRAIN_SIZE, 70f)
        val disabled = changed.withEffect(PhotoEffectParameter.VIGNETTE_AMOUNT, 0f)
        assertEquals(0f, disabled.vignetteAmount)
        assertEquals(20f, disabled.vignetteMidpoint)
        assertEquals(65f, disabled.grainAmount)
        assertEquals(70f, disabled.grainSize)
    }

    @Test fun photoEffectsClampFiniteValuesAndResetByGroup() {
        val changed = PhotoEffectsSettings()
            .withEffect(PhotoEffectParameter.VIGNETTE_AMOUNT, -1000f)
            .withEffect(PhotoEffectParameter.VIGNETTE_ROUNDNESS, 1000f)
            .withEffect(PhotoEffectParameter.VIGNETTE_MIDPOINT, 1000f)
            .withEffect(PhotoEffectParameter.GRAIN_AMOUNT, 1000f)
        assertEquals(-100f, changed.vignetteAmount)
        assertEquals(100f, changed.vignetteRoundness)
        assertEquals(100f, changed.vignetteMidpoint)
        assertEquals(100f, changed.grainAmount)
        assertEquals(1f, PhotoEffectsSettings().withEffect(PhotoEffectParameter.GRAIN_SIZE, .5f).grainSize)
        assertEquals(-1f, PhotoEffectsSettings().withEffect(PhotoEffectParameter.VIGNETTE_AMOUNT, -.5f).vignetteAmount)
        assertEquals(changed, changed.withEffect(PhotoEffectParameter.GRAIN_SIZE, Float.NaN))

        val vignetteReset = changed.resetEffects(vignette = true)
        assertEquals(PhotoEffectsSettings().copy(grainAmount = 100f), vignetteReset)
        assertFalse(vignetteReset.isEffectDefault(vignette = false))
        assertTrue(vignetteReset.isEffectDefault(vignette = true))
        assertThrows(IllegalArgumentException::class.java) { PhotoEffectsSettings(vignetteAmount = Float.NaN) }
        assertThrows(IllegalArgumentException::class.java) { PhotoEffectsSettings(grainRoughness = 101f) }
    }

    @Test fun displayChromaDenoiseIsIndependentAndBounded() {
        assertEquals(0, EditSettings().displayChromaDenoise)
        assertEquals(2, EditSettings(displayChromaDenoise = 2).displayChromaDenoise)
        for (bad in listOf(-1, 3)) {
            assertThrows(IllegalArgumentException::class.java) { EditSettings(displayChromaDenoise = bad) }
        }
        val settings = EditSettings(denoise = DenoiseSettings(chroma = 72f), displayChromaDenoise = 1)
        assertEquals(72f, settings.denoise.chroma)
        assertEquals(1, settings.displayChromaDenoise)
    }
}
