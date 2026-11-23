package com.rawlab.android.editor

import com.rawlab.android.editor.inspection.InspectionAnchor
import com.rawlab.android.editor.inspection.InspectionColorMath
import com.rawlab.android.editor.inspection.InspectionGeometryMapper
import com.rawlab.android.editor.inspection.InspectionOverlayMode
import com.rawlab.android.editor.inspection.InspectionSessionState
import com.rawlab.android.engine.toCanonicalRecipeJson
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.settings.EditSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InspectionSuiteTest {
    @Test
    fun rgbToHsbAndRec709LuminanceAndPatchSamplingMatchContract() {
        val red = InspectionColorMath.fromRgb(255, 0, 0)
        assertEquals(0.0, red.hueDeg, 0.01)
        assertEquals(100.0, red.saturationPct, 0.01)
        assertEquals(100.0, red.brightnessPct, 0.01)
        assertEquals(0.2126, red.luminance, 1e-4)

        val green = InspectionColorMath.fromRgb(0, 255, 0)
        assertEquals(120.0, green.hueDeg, 0.01)
        assertEquals(0.7152, green.luminance, 1e-4)

        val blue = InspectionColorMath.fromRgb(0, 0, 255)
        assertEquals(240.0, blue.hueDeg, 0.01)
        assertEquals(0.0722, blue.luminance, 1e-4)

        val gray = InspectionColorMath.fromRgb(128, 128, 128)
        assertEquals(0.0, gray.saturationPct, 0.01)
        assertEquals(128.0 / 255.0, gray.luminance, 1e-4)

        val pixels = IntArray(4 * 4) { idx ->
            val x = idx % 4
            if (x < 2) (0xff shl 24) or (100 shl 16) or (100 shl 8) or 100
            else (0xff shl 24) or (200 shl 16) or (100 shl 8) or 50
        }
        val corner = InspectionColorMath.sampleArgbPatch(pixels, 4, 4, 0f, 0f, radiusPx = 0)
        assertNotNull(corner)
        assertEquals(100, corner!!.r)

        val straddle = InspectionColorMath.sampleArgbPatch(pixels, 4, 4, 1f / 3f, 0.5f, radiusPx = 1)
        assertNotNull(straddle)
        assertEquals(133, straddle!!.r)
    }

    @Test
    fun geometryMapperRoundTripsAndDetectsOutOfCrop() {
        val srcW = 4000
        val srcH = 3000
        val cases = listOf(
            GeometrySettings(),
            GeometrySettings(quarterTurns = 1),
            GeometrySettings(quarterTurns = 2, flipHorizontal = true),
            GeometrySettings(quarterTurns = 3, flipVertical = true),
            GeometrySettings(0.1f, 0.2f, 0.6f, 0.5f, 1, true, false, 7.5f, 0.35f, -0.25f),
            GeometrySettings(0.15f, 0.1f, 0.7f, 0.75f, 0, false, true, -12.0f, -0.4f, 0.5f),
        )
        for (geom in cases) {
            for ((ox, oy) in listOf(0.5f to 0.5f, 0.35f to 0.6f, 0.68f to 0.42f)) {
                val src = InspectionGeometryMapper.outputNormToSourceNorm(ox, oy, srcW, srcH, geom)
                assertNotNull(src)
                val back = InspectionGeometryMapper.sourceNormToOutputNorm(src!!.first, src.second, srcW, srcH, geom)
                assertNotNull(back)
                assertEquals(ox, back!!.first, 1e-4f)
                assertEquals(oy, back.second, 1e-4f)
            }
        }
        val cropped = GeometrySettings(0.25f, 0.25f, 0.5f, 0.5f)
        assertNull(InspectionGeometryMapper.sourceNormToOutputNorm(0.1f, 0.1f, srcW, srcH, cropped))
        assertNotNull(InspectionGeometryMapper.sourceNormToOutputNorm(0.5f, 0.5f, srcW, srcH, cropped))
    }

    @Test
    fun anchorsMax4AndFiveOverlaysAndZeroRecipePollution() {
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

        val dark = InspectionColorMath.applyOverlayPixel(80, 80, 80, InspectionOverlayMode.SKETCH_LUMINANCE)
        val bright = InspectionColorMath.applyOverlayPixel(180, 180, 180, InspectionOverlayMode.SKETCH_LUMINANCE)
        assertTrue((dark and 0xff) < 80 && (bright and 0xff) > 180)

        val warm = InspectionColorMath.applyOverlayPixel(180, 140, 60, InspectionOverlayMode.WARM_COOL_BW)
        val cool = InspectionColorMath.applyOverlayPixel(60, 140, 220, InspectionOverlayMode.WARM_COOL_BW)
        assertTrue(((warm ushr 16) and 0xff) > ((cool ushr 16) and 0xff))

        val clip = InspectionColorMath.applyOverlayPixel(255, 100, 100, InspectionOverlayMode.OVERSATURATION_HEATMAP)
        assertEquals(255, (clip ushr 16) and 0xff)
        assertTrue((clip and 0xff) > 100)

        val redSkin = InspectionColorMath.applyOverlayPixel(210, 130, 120, InspectionOverlayMode.SKIN_HUE_AMPLIFICATION)
        val yellowSkin = InspectionColorMath.applyOverlayPixel(210, 195, 120, InspectionOverlayMode.SKIN_HUE_AMPLIFICATION)
        assertTrue(((yellowSkin ushr 8) and 0xff) > ((redSkin ushr 8) and 0xff))

        val gray50 = InspectionColorMath.applyOverlayPixel(20, 200, 250, InspectionOverlayMode.NEUTRAL_GRAY_50)
        assertEquals(0xff808080.toInt(), gray50)

        val src = intArrayOf(0xffd28278.toInt(), 0xff3c8cdc.toInt())
        val dst = IntArray(2)
        InspectionColorMath.applyOverlayArgb(src, dst, InspectionOverlayMode.NONE)
        assertEquals(src[0], dst[0])
        assertEquals(src[1], dst[1])

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
}
