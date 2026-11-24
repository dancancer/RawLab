package com.rawlab.android.settings

import com.rawlab.android.adjustments.*
import com.rawlab.android.editor.*
import com.rawlab.android.format.PhotoInputKind
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ToneCurveSettingsTest {
    private val curve = ToneCurveSettings.identity.inserting(.25, .125).inserting(.75, .875)

    @Test fun independentChannelsSurviveStorageTransferAndRefinement() {
        val channels = ToneCurveSettings().replacing(ToneCurveChannel.RED, curve.master)
            .replacing(ToneCurveChannel.BLUE, curve.master)
        assertFalse(channels.isDefault)
        assertFalse(channels.isIdentity)
        assertEquals(ToneCurveSettings(), ToneCurveSettings.decode(JSONObject("{\"mode\":\"legacy\",\"points\":[]}")))
        val source = EditSettings(curve = channels)
        val hdr = HDRSettings().withTone(HDRToneSettings(curve = channels))
        assertEquals(8, hdr.processingVersion); assertEquals(9, hdr.recordVersion)
        assertEquals(hdr, SettingsCodec.decode(SettingsCodec.encode(EditSettings(hdr = hdr))).hdr)
        assertTrue(hdr.reset().toneSettings.curve.channels.isDefault)
        assertEquals(source, SettingsCodec.decode(SettingsCodec.encode(source)))
        val context = AdjustmentTransferContext("channels", false)
        val payload = AdjustmentTransfer.capture(AdjustmentScope.Custom(setOf(AdjustmentField.CURVE)), source, context)
        assertEquals(channels, AdjustmentTransfer.prepare(AdjustmentPayload.decode(payload.encode()), EditSettings(), context).curve)
        val scaled = channels.scaled(.5)
        assertTrue(scaled.master.isDefault)
        assertTrue(scaled.channels.green.isDefault)
        assertEquals(.1875, scaled.channels.red.points[1].y, 0.0)
        assertEquals(channels, channels.inserting(.3, .3))
        val nested = channels.json()
        nested.getJSONObject("channels").getJSONObject("red").put("channels", JSONObject())
        assertThrows(Exception::class.java) { ToneCurveSettings.decode(nested) }
    }

    @Test fun pointsAreImmutableOrderedAndBounded() {
        val points = mutableListOf(ToneCurvePoint(0.0, 0.0), ToneCurvePoint(1.0, 1.0))
        val frozen = ToneCurveSettings(ToneCurveMode.CUSTOM, points)
        points[1] = ToneCurvePoint(.5, .5)
        assertEquals(ToneCurveSettings.identity, frozen)
        assertTrue(curve.isEndpoint(0) && curve.isEndpoint(3) && curve.canMoveX(0) && curve.canMoveX(3) && curve.canMoveY(0) && curve.canMoveY(3))
        assertFalse(curve.isInterior(0) || curve.isInterior(3))
        val movedBlack = curve.moving(0, .2, .1)
        assertEquals(ToneCurvePoint(.2, .1), movedBlack.points[0])
        val clampedBlack = curve.moving(0, .5, .5)
        assertTrue(clampedBlack.points[0].x < curve.points[1].x)
        assertEquals(curve.points[1].y, clampedBlack.points[0].y, 0.0)
        val movedWhite = curve.moving(3, .8, .9)
        assertEquals(ToneCurvePoint(.8, .9), movedWhite.points[3])
        val clampedWhite = curve.moving(3, .2, .2)
        assertTrue(clampedWhite.points[3].x > curve.points[2].x)
        assertEquals(curve.points[2].y, clampedWhite.points[3].y, 0.0)
        assertEquals(curve, curve.removing(0))
        assertEquals(curve, curve.removing(3))
        val moved = curve.moving(1, 1.0, 1.0)
        assertTrue(moved.points[1].x < moved.points[2].x)
        assertEquals(.875, moved.points[1].y, 0.0)
        assertEquals(curve, curve.inserting(.25, .4))
        assertEquals(3, curve.removing(1).points.size)
        assertThrows(IllegalArgumentException::class.java) { ToneCurveSettings(ToneCurveMode.LEGACY, frozen.points) }
        assertThrows(IllegalArgumentException::class.java) { ToneCurveSettings(ToneCurveMode.CUSTOM,
            listOf(ToneCurvePoint(0.0, 0.0), ToneCurvePoint(.5, .6), ToneCurvePoint(.6, .5), ToneCurvePoint(1.0, 1.0))) }
    }

    @Test fun storageRetainsInactiveLegacyAndDoubleCoordinates() {
        val precise = curve.moving(1, .250000000000001, .125000000000001)
        val source = EditSettings(toneCurve = .65f, curve = precise)
        assertEquals(source, SettingsCodec.decode(SettingsCodec.encode(source)))
        assertEquals(0f, source.renderToneCurve)
        val old = JSONObject(SettingsCodec.encode(source).removePrefix("v3:"))
        old.getJSONObject("settings").remove("curve")
        val restored = SettingsCodec.decode("v3:$old")
        assertTrue(restored.curve.isDefault); assertEquals(.65f, restored.renderToneCurve)
        for (bad in listOf("""{"mode":"custom","points":[[0,0],[1,1,2]]}""",
            """{"mode":"custom","points":[[0,0],[0.5,0.6],[0.5,0.8],[1,1]]}""",
            """{"mode":"custom","points":[[0,0],[1,1]],"future":0}""")) {
            old.getJSONObject("settings").put("curve", JSONObject(bad))
            assertThrows(Exception::class.java) { SettingsCodec.decode("v3:$old") }
        }
    }

    @Test fun transferKeepsModeAndScalarIndependentlySelectable() {
        val context = AdjustmentTransferContext("curve", false)
        val source = EditSettings(toneCurve = .65f, curve = curve)
        val all = AdjustmentTransfer.capture(AdjustmentScope.Modified, source, context)
        assertEquals(setOf(AdjustmentField.S_CURVE, AdjustmentField.CURVE), all.fields)
        val target = EditSettings(toneCurve = -.25f)
        val partial = AdjustmentTransfer.capture(AdjustmentScope.Custom(setOf(AdjustmentField.CURVE)), source, context)
        val restored = AdjustmentTransfer.prepare(AdjustmentPayload.decode(partial.encode()), target, context)
        assertEquals(curve, restored.curve); assertEquals(-.25f, restored.toneCurve)
        val legacy = AdjustmentTransfer.capture(AdjustmentScope.Custom(setOf(AdjustmentField.S_CURVE)), source, context)
        assertEquals(curve, AdjustmentTransfer.prepare(legacy, restored, context).curve)
        assertEquals(.65f, AdjustmentTransfer.prepare(legacy, restored, context).toneCurve)
    }

    @Test fun recipeStrengthDoesNotChangeCurveAndResetIncludesMode() {
        val source = EditSettings(toneCurve = .65f, curve = curve)
        for (strength in listOf(0f, .5f, 1f, 2f)) {
            val recipe = source.copy(recipeID = "r", strength = strength)
            assertEquals(curve, recipe.curve); assertEquals(0f, recipe.renderToneCurve)
        }
        val context = EditorResetContext(PhotoInputKind.RASTER, EditSettings())
        for (scope in listOf(EditorResetScope.Tool(6), EditorResetScope.Group(EditorAdjustmentGroup.LIGHT))) {
            assertTrue(EditorAdjustmentRules.isModified(scope, source, context))
            val reset = EditorAdjustmentRules.prepareReset(scope, source, context) as EditorResetResult.Ready
            assertTrue(reset.candidate.curve.isDefault); assertEquals(0f, reset.candidate.toneCurve)
        }
        assertTrue(ToneCurveSettings.identity.isIdentity)
        assertFalse(ToneCurveSettings.identity.isDefault)
    }

    @Test fun unpinnedEndpointXYAndParametricCurveRoundTripThroughStorageHDRAndTransfer() {
        val unpinned = ToneCurveShape(ToneCurveMode.CUSTOM, listOf(ToneCurvePoint(0.12, 0.08), ToneCurvePoint(0.5, 0.55), ToneCurvePoint(0.88, 0.91)))
        assertEquals(0.12, unpinned.points.first().x, 0.0)
        assertEquals(0.08, unpinned.points.first().y, 0.0)
        assertEquals(0.88, unpinned.points.last().x, 0.0)
        assertEquals(0.91, unpinned.points.last().y, 0.0)
        assertThrows(IllegalArgumentException::class.java) {
            ToneCurveShape(ToneCurveMode.CUSTOM, listOf(ToneCurvePoint(-0.05, 0.0), ToneCurvePoint(1.0, 1.0)))
        }
        assertThrows(IllegalArgumentException::class.java) {
            ToneCurveParametric(splitShadow = 0.45, splitMidtone = 0.46)
        }
        assertThrows(IllegalArgumentException::class.java) {
            ToneCurveParametric.decode(JSONObject("""{"highlights":10.0}"""))
        }
        assertFalse(ToneCurveSettings.identity.inserting(0.5, 0.6).hasV2Extensions)
        assertTrue(ToneCurveSettings(ToneCurveMode.CUSTOM, listOf(ToneCurvePoint(0.0, 0.2), ToneCurvePoint(1.0, 1.0))).hasV2Extensions)
        assertTrue(ToneCurveSettings(ToneCurveMode.CUSTOM, listOf(ToneCurvePoint(0.1, 0.0), ToneCurvePoint(1.0, 1.0))).hasV2Extensions)
        assertTrue(ToneCurveSettings(channels = ToneCurveChannels(
            red = ToneCurveShape(ToneCurveMode.CUSTOM, listOf(ToneCurvePoint(0.0, 0.0), ToneCurvePoint(1.0, 0.9))),
        )).hasV2Extensions)
        assertTrue(ToneCurveSettings(channels = ToneCurveChannels(
            red = ToneCurveShape(ToneCurveMode.CUSTOM, listOf(ToneCurvePoint(0.1, 0.0), ToneCurvePoint(0.9, 1.0))),
        )).hasV2Extensions)
        val diagInset = ToneCurveSettings(ToneCurveMode.CUSTOM, listOf(ToneCurvePoint(0.1, 0.1), ToneCurvePoint(0.9, 0.9)))
        assertFalse(diagInset.isIdentity)
        assertTrue(diagInset.progress > 0.0)
        val insertedOutside = diagInset.inserting(0.05, 0.05).inserting(0.95, 0.95)
        assertEquals(ToneCurvePoint(0.05, 0.05), insertedOutside.points.first())
        assertEquals(ToneCurvePoint(0.95, 0.95), insertedOutside.points.last())
        val xOnlyHdr = HDRSettings().withTone(HDRToneSettings(curve = ToneCurveSettings(ToneCurveMode.CUSTOM, listOf(ToneCurvePoint(0.15, 0.0), ToneCurvePoint(0.85, 1.0)))))
        assertEquals(10, xOnlyHdr.processingVersion); assertEquals(11, xOnlyHdr.recordVersion)
        assertEquals(xOnlyHdr, SettingsCodec.decode(SettingsCodec.encode(EditSettings(hdr = xOnlyHdr))).hdr)
        // 已发布的 v9 只放开端点 y：端点 y 内移仍保持 v9，端点 x 内移才升到 v10。
        val yOnlyHdr = HDRSettings().withTone(HDRToneSettings(curve = ToneCurveSettings(ToneCurveMode.CUSTOM, listOf(ToneCurvePoint(0.0, 0.1), ToneCurvePoint(1.0, 0.9)))))
        assertEquals(9, yOnlyHdr.processingVersion); assertEquals(10, yOnlyHdr.recordVersion)
        val freeXHalf = ToneCurveSettings(ToneCurveMode.CUSTOM, unpinned.points).scaled(0.5)
        assertEquals(0.06, freeXHalf.points[0].x, 1e-12)
        assertEquals(0.04, freeXHalf.points[0].y, 1e-12)
        assertEquals(0.94, freeXHalf.points[2].x, 1e-12)
        assertEquals(0.955, freeXHalf.points[2].y, 1e-12)
        val param = ToneCurveParametric(highlights = -18.0, lights = 12.0, darks = -8.0, shadows = 24.0,
            splitShadow = 0.2, splitMidtone = 0.52, splitHighlight = 0.8)
        val v2Curve = ToneCurveSettings(ToneCurveMode.CUSTOM, unpinned.points, applyToLuminosity = true, parametric = param)
        assertTrue(v2Curve.hasV2Extensions)
        val source = EditSettings(curve = v2Curve)
        assertEquals(source, SettingsCodec.decode(SettingsCodec.encode(source)))
        val hdr = HDRSettings().withTone(HDRToneSettings(curve = v2Curve))
        assertEquals(10, hdr.processingVersion); assertEquals(11, hdr.recordVersion)
        assertEquals(hdr, SettingsCodec.decode(SettingsCodec.encode(EditSettings(hdr = hdr))).hdr)
        val context = AdjustmentTransferContext("v2curve", false)
        val payload = AdjustmentTransfer.capture(
            AdjustmentScope.Custom(setOf(AdjustmentField.CURVE, AdjustmentField.CURVE_APPLY_TO_LUMINOSITY, AdjustmentField.CURVE_PARAMETRIC)),
            source, context,
        )
        assertEquals(v2Curve, AdjustmentTransfer.prepare(AdjustmentPayload.decode(payload.encode()), EditSettings(), context).curve)
        val refinedSource = EditSettings(curve = ToneCurveSettings(ToneCurveMode.CUSTOM, unpinned.points))
        val refinedPayload = AdjustmentTransfer.capture(AdjustmentScope.Custom(setOf(AdjustmentField.CURVE)), refinedSource, context)
        val refinedTarget = EditSettings(recipeID = "r", strength = 0.5f, masterRecipeSettingsVersion = 4)
        val preparedRefined = AdjustmentTransfer.prepare(AdjustmentPayload.decode(refinedPayload.encode()), refinedTarget, context)
        assertEquals(0.24, preparedRefined.curve.points[0].x, 1e-12)
        assertEquals(0.16, preparedRefined.curve.points[0].y, 1e-12)
        val crossing = ToneCurveSettings(ToneCurveMode.CUSTOM, listOf(ToneCurvePoint(0.4, 0.2), ToneCurvePoint(0.7, 0.9))).scaled(2.0)
        assertTrue(crossing.points[0].x < crossing.points[1].x)
    }

    @Test fun curveTargetInteractionAcceptsNearGraySwitchesLegacyAndCancelsCleanly() {
        val rev = HslTargetRevision(1L, 2L)
        val interaction = CurveTargetInteraction()
        val sampled = listOf(ToneCurvePoint(0.0, 0.0), ToneCurvePoint(0.5, 0.5), ToneCurvePoint(1.0, 1.0))
        val token = interaction.begin(ToneCurveSettings(), ToneCurveChannel.RGB, rev, sampled)
        val graySample = HslTargetSample(rev, HslTargetAvailability.NEAR_GRAY, listOf(0.4f, 0.4f, 0.4f), emptyList(), preview = false)
        val accepted = interaction.accept(graySample, token, rev)
        assertNotNull(accepted)
        assertEquals(ToneCurveMode.CUSTOM, accepted!!.mode)
        assertEquals(3, accepted.points.size)
        val dragged = interaction.move(20f)
        assertNotNull(dragged)
        assertEquals(0.5, dragged!!.points[1].y, 1e-6)
        assertEquals(ToneCurveSettings(), interaction.cancel())
    }
}
