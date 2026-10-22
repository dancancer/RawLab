package com.rawlab.android.editor

import com.rawlab.android.editor.controls.AdjustmentScale
import com.rawlab.android.editor.controls.formatAdjustment
import com.rawlab.android.editor.controls.editorDockLayout
import org.junit.Assert.*
import org.junit.Test
import java.util.Locale

class ParameterInputContractTest {
    @Test fun legalOffGridValuesAreDisplayedWithoutRoundingToTheNewInteractionGrid() {
        assertEquals("0.5", formatAdjustment(.5f, 1f))
        assertEquals("12.34", formatAdjustment(12.34f, 1f))
        assertEquals("5237", formatAdjustment(5237f, 10f))
        assertEquals("0.00001", formatAdjustment(.00001f, .05f))
    }

    @Test fun originalValueExceptionAppliesToEveryParameterAndEquivalentNumericText() {
        val hsl = AdjustmentScale(-100f..100f, 1f, 0f)
        assertEquals(.5f, hsl.parse("0.5", current = .5f)!!, 0f)
        assertEquals(.5f, hsl.parse("0,50", Locale.GERMAN, .5f)!!, 0f)
        val exposure = AdjustmentScale(-4f..4f, .05f, 0f)
        assertEquals(.1234f, exposure.parse("0.12340", current = .1234f)!!, 0f)
    }

    @Test fun newOffGridTextIsRejectedInsteadOfSilentlySnapping() {
        assertNull(AdjustmentScale(-100f..100f, 1f, 0f).parse("0.5", current = 0f))
        assertNull(AdjustmentScale(-4f..4f, .05f, 0f).parse("0.36", current = 0f))
        assertNull(AdjustmentScale(-4f..4f, .05f, 0f).parse("0.45000002", current = 0f))
        assertNull(AdjustmentScale(2000f..50000f, 10f, 5237f, true).parse("5503", current = 5237f))
        assertEquals(1f, AdjustmentScale(-100f..100f, 1f, 0f).parse("1", current = .5f)!!, 0f)
    }

    @Test fun standardPortraitReservesThreeAxesAndPhotoWithoutChangingForTool() {
        val layout = editorDockLayout(652f, 1f, false, true)
        assertFalse(layout.compactNavigation)
        assertTrue(layout.height >= 48f + 88f * 2 + 65f + 240f)
        assertTrue(652f - layout.height >= 96f)
    }

    @Test fun largePortraitKeepsFullNavigationAndScrollsParametersWithinOneWindowBudget() {
        val layout = editorDockLayout(652f, 1.6f, false, true)
        assertFalse("A standard narrow portrait must not split long labels into tiny inline viewports", layout.compactNavigation)
        assertTrue(layout.height >= 48f + 102.4f * 2 + 65f + 144f)
        assertTrue(652f - layout.height >= 96f)
    }

    @Test fun defaultAndCurrentFillUseTheSameMonotonicCoordinateIncludingKelvin() {
        assertEquals(0f, AdjustmentScale(0f..0f, .1f, 0f).fraction(0f), 0f)
        val tint = AdjustmentScale(-150f..150f, 1f, 30f)
        assertEquals(.6f, tint.fraction(30f), .00001f)
        assertTrue(tint.fraction(-60f) < tint.fraction(tint.default))
        assertTrue(tint.fraction(90f) > tint.fraction(tint.default))
        val kelvin = AdjustmentScale(2000f..50000f, 10f, 5237f, true)
        assertEquals(0f, kelvin.fraction(2000f), 0f)
        assertEquals(1f, kelvin.fraction(50000f), 0f)
        assertTrue(kelvin.fraction(3000f) < kelvin.fraction(kelvin.default))
        assertTrue(kelvin.fraction(8000f) > kelvin.fraction(kelvin.default))
    }

    @Test fun invalidOriginalTextStillCannotBypassFiniteOrRangeChecks() {
        val scale = AdjustmentScale(-100f..100f, 1f, 0f)
        listOf("", "NaN", "Infinity", "101", "-100.1", "1junk").forEach { assertNull(it, scale.parse(it, current = .5f)) }
    }
}
