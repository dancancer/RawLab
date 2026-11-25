package com.rawlab.android.editor

import com.rawlab.android.editor.inspection.InspectionAnchor
import com.rawlab.android.editor.inspection.InspectionColorSample
import com.rawlab.android.editor.inspection.InspectionOverlayMode
import com.rawlab.android.editor.inspection.InspectionSessionState
import com.rawlab.android.engine.toCanonicalRecipeJson
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.settings.EditSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InspectionSuiteTest {
    @Test
    fun colorSampleFormattingMatchesContract() {
        val sample = InspectionColorSample(
            r = 255,
            g = 128,
            b = 0,
            hueDeg = 30.1,
            saturationPct = 100.0,
            brightnessPct = 100.0,
            luminance = 0.568,
        )
        assertEquals("255 128 0", sample.rgbText)
        assertEquals("30° 100% 100%", sample.hsbText)
    }

    @Test
    fun anchorsMax4AndOverlaysAndZeroRecipePollution() {
        var session = InspectionSessionState()
        for (i in 1..4) {
            session = session.pinAnchor(0.1f * i, 0.5f)
        }
        assertEquals(InspectionAnchor.MAX_COUNT, session.anchors.size)
        assertFalse(session.canPinMore)
        val capped = session.pinAnchor(0.9f, 0.9f)
        assertEquals(4, capped.anchors.size)

        session = session.selectOverlay(InspectionOverlayMode.WARM_COOL_BW)
        session = session.toggleNeutralGray50()
        assertEquals(InspectionOverlayMode.NEUTRAL_GRAY_50, session.overlay)
        session = session.toggleNeutralGray50()
        assertEquals(InspectionOverlayMode.WARM_COOL_BW, session.overlay)

        // Zero EditSettings / CanonicalEditRecipe pollution
        val edits = EditSettings(
            exposure = 0.4f,
            contrast = 1.25f,
            geometry = GeometrySettings(0.1f, 0.1f, 0.8f, 0.8f, quarterTurns = 1)
        )
        val baseRecipe = edits.toCanonicalRecipeJson(isRaster = false)
        for (mode in InspectionOverlayMode.entries) {
            session = session.selectOverlay(mode)
            assertEquals(baseRecipe, edits.toCanonicalRecipeJson(isRaster = false))
        }

        session = session.resetForNewSource()
        assertTrue(session.anchors.isEmpty())
        assertEquals(InspectionOverlayMode.NONE, session.overlay)
    }

    @Test
    fun sessionStateSaveRestorePreservesAnchorsOverlayAndSelectionAcrossRotation() {
        var session = InspectionSessionState(monitorEnabled = true, liveOutputX = 0.25f, liveOutputY = 0.75f)
        session = session.pinAnchor(0.12f, 0.34f)
        session = session.pinAnchor(0.56f, 0.78f)
        session = session.selectOverlay(InspectionOverlayMode.SKIN_HUE_AMPLIFICATION)
        session = session.toggleNeutralGray50()

        val saved = session.saveToList()
        val restored = InspectionSessionState.restoreFromList(saved)

        assertEquals(session, restored)
        assertTrue(restored.monitorEnabled)
        assertEquals(0.25f, restored.liveOutputX ?: -1f, 1e-6f)
        assertEquals(0.75f, restored.liveOutputY ?: -1f, 1e-6f)
        assertEquals(2, restored.anchors.size)
        assertEquals(2L, restored.selectedAnchorId)
        assertEquals(InspectionOverlayMode.NEUTRAL_GRAY_50, restored.overlay)
        assertEquals(InspectionOverlayMode.SKIN_HUE_AMPLIFICATION, restored.lastNonGrayOverlay)
        assertEquals(3L, restored.nextAnchorId)
    }

    @Test
    fun dismissOverlayRestoresPreviousNonGrayOverlayBeforeClearing() {
        var session = InspectionSessionState()
            .selectOverlay(InspectionOverlayMode.WARM_COOL_BW)
            .toggleNeutralGray50()
        assertEquals(InspectionOverlayMode.NEUTRAL_GRAY_50, session.overlay)

        session = session.dismissOverlay()
        assertEquals(InspectionOverlayMode.WARM_COOL_BW, session.overlay)

        session = session.dismissOverlay()
        assertEquals(InspectionOverlayMode.NONE, session.overlay)
        assertEquals(InspectionOverlayMode.NONE, session.lastNonGrayOverlay)
    }
}
