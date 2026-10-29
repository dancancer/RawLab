package com.rawlab.android.adjustments

import com.rawlab.android.settings.*
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.format.PhotoInputKind
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File

private typealias F = AdjustmentField
private typealias V = AdjustmentValue

class AdjustmentTransferTest {
    private val context = AdjustmentTransferContext("target", true,
        availableLookIDs = setOf("builtin:provia.cube", "managed-look", "recipe:r"),
        builtinLookIDs = mapOf("provia.cube" to "provia"), cameraTemperature = 4875f, cameraTint = 7f)
    private fun payload(vararg values: Pair<F, V>, recipe: AdjustmentRecipeContext? = null) =
        AdjustmentPayload(AdjustmentSource("source", true, 2, recipe), mapOf(*values))
    private fun prepare(payload: AdjustmentPayload, target: EditSettings = EditSettings(),
        context: AdjustmentTransferContext = this.context) = AdjustmentTransfer.prepare(payload, target, context)
    private fun capture(settings: EditSettings, vararg fields: F) =
        AdjustmentTransfer.capture(AdjustmentScope.Custom(fields.toSet()), settings, context.copy(identifier = "source"))

    @Test fun defaultScopePasteIntoEqualPhotoDoesNotCreateNegativeZeroOrChange() {
        val settings = EditSettings()
        val copied = AdjustmentTransfer.capture(AdjustmentScope.Custom(F.entries.filter { it.group != "geometry" }.toSet()), settings, context)
        val result = prepare(copied, settings)
        assertEquals(settings, result)
        assertEquals(0, result.highlights.toRawBits())
    }

    @Test fun partialCopyFreezesExactHSLAndPreservesOtherFields() {
        val source = EditSettings(exposure = 1.5f, hsl = HslSettings().withValue(0, 0, 12.375f))
        val payload = capture(source, F.EXPOSURE, F.HSL_HUE_RED)
        val target = EditSettings(contrast = .25f, hsl = HslSettings().withValue(1, 0, 23.5f),
            geometry = GeometrySettings(cropWidth = .6f), processing = ProcessingIdentity.LEGACY)
        val result = prepare(payload, target)
        assertEquals(1.5f, result.exposure); assertEquals(.25f, result.contrast)
        assertEquals(12.375f, result.hsl.value(0, 0)); assertEquals(23.5f, result.hsl.value(1, 0))
        assertEquals(target.geometry, result.geometry); assertEquals(target.processing, result.processing)
        assertEquals(result, prepare(payload, result))
        assertEquals(AdjustmentValue.Number(1.5), payload[F.EXPOSURE])
    }

    @Test fun allIncludesGeometryAndModifiedUsesDefaultsWithoutGeometry() {
        val source = EditSettings(exposure = .5f, geometry = GeometrySettings(cropWidth = .5f))
        assertEquals(F.entries.filterNot { it.isHDRRelative }.toSet(), AdjustmentTransfer.capture(AdjustmentScope.All, source, context).fields)
        assertEquals(setOf(F.EXPOSURE), AdjustmentTransfer.capture(AdjustmentScope.Modified, source, context).fields)
        assertThrows(AdjustmentTransferException::class.java) {
            AdjustmentTransfer.capture(AdjustmentScope.Modified, EditSettings(), context)
        }
        assertThrows(AdjustmentTransferException::class.java) {
            AdjustmentTransfer.capture(AdjustmentScope.All, source, context.copy(hasUncommittedDraft = true))
        }
    }

    @Test fun recipeContributionAppliesOnceAndUnselectedRecipeValuesStayEffective() {
        val source = EditSettings(recipeID = "r", strength = .5f, exposure = 1.4f, contrast = .4f)
        val values = capture(source, F.EXPOSURE, F.CONTRAST)
        val target = EditSettings(recipeID = "r", strength = .8f, exposure = -.2f, contrast = -.2f, saturation = .3f)
        val result = prepare(values, target)
        assertEquals(.7f, result.exposure * result.recipeScale, 1e-6f)
        assertEquals(1.2f, 1f + result.contrast * result.recipeScale, 1e-6f)
        assertEquals(target.saturation, result.saturation)
        assertEquals("r", result.recipeID)
        assertEquals(result, prepare(values, result))
    }

    @Test fun selectingStrengthProtectsUnselectedContributionsAndBlocksZeroScaleLoss() {
        val target = EditSettings(recipeID = "r", strength = .5f, exposure = 1f, saturation = .4f,
            hsl = HslSettings().withValue(0, 2, 20f))
        val result = prepare(payload(F.STRENGTH to AdjustmentValue.Number(1.0)), target)
        assertEquals(.5f, result.exposure)
        assertEquals(1f + target.saturation * target.recipeScale, 1f + result.saturation * result.recipeScale)
        assertEquals(10f, result.hsl.value(0, 2))
        assertThrows(AdjustmentTransferException::class.java) { prepare(payload(F.STRENGTH to AdjustmentValue.Number(0.0)), target) }
    }

    @Test fun partialRecipeLookBecomesIndependentLUTWithoutReapplyingRecipe() {
        val source = EditSettings(recipeID = "r", strength = .5f, exposure = 2f)
        val target = EditSettings(exposure = -.5f, saturation = .3f)
        val result = prepare(capture(source, F.LOOK), target)
        assertNull(result.recipeID); assertEquals("recipe-lut:r", result.film)
        assertEquals(target.exposure, result.exposure); assertEquals(target.saturation, result.saturation)
    }

    @Test fun fullCurrentAndLegacyRecipesPreserveEffectiveHSL() {
        val source = EditSettings(recipeID = "r", strength = .5f, exposure = 1.4f,
            hsl = HslSettings().withValue(0, 0, 37.25f))
        val current = AdjustmentTransfer.capture(AdjustmentScope.All, source, context)
        val result = prepare(current)
        assertEquals("r", result.recipeID); assertEquals(source.hsl, result.hsl)
        val legacy = AdjustmentPayload(current.source.copy(recipe = current.source.recipe!!.copy(settingsVersion = 2)), current.values)
        val legacyResult = prepare(legacy)
        assertEquals(37.25f, legacyResult.renderHsl.value(0, 0))
        assertEquals("r", legacyResult.recipeID)
        val self = EditSettings(recipeID = "r", strength = .7f, exposure = .23f, contrast = .21f,
            hsl = HslSettings().withValue(0, 0, 13.15f))
        assertEquals(self, prepare(AdjustmentTransfer.capture(AdjustmentScope.All, self, context), self))
    }

    @Test fun whiteBalanceUsesTargetCalibrationAndFixedValuesRemainFixed() {
        val source = EditSettings(recipeID = "r", strength = .5f, tint = 12f)
        val relative = capture(source, F.WHITE_BALANCE_MODE, F.TEMPERATURE, F.TINT)
        val result = prepare(relative)
        assertTrue(result.customWb); assertEquals(4875f, result.temperature); assertEquals(13f, result.tint)
        assertThrows(AdjustmentTransferException::class.java) {
            prepare(relative, context = context.copy(cameraTemperature = null, cameraTint = null))
        }
        val fixed = prepare(capture(EditSettings(customWb = true, temperature = 4200f, tint = 12.1f),
            F.WHITE_BALANCE_MODE, F.TEMPERATURE, F.TINT))
        assertEquals(4200f, fixed.temperature); assertEquals(12.1f, fixed.tint)
        assertThrows(AdjustmentTransferException::class.java) { prepare(payload(F.TEMPERATURE to AdjustmentValue.Number(4200.0))) }
    }

    @Test fun nullLegacyDenoiseMapsToTheExistingDisabledPathButUnsupportedRequestsBlock() {
        val original = EditSettings(denoise = DenoiseSettings(true, 10f, 72f, 100f), displayChromaDenoise = 2)
        val result = prepare(payload(F.WAVELET_DENOISE to AdjustmentValue.Null), original)
        assertEquals(DenoiseSettings(), result.denoise); assertEquals(2, result.displayChromaDenoise)
        assertEquals(0, prepare(payload(F.CHROMA_DENOISE to AdjustmentValue.Null), original).displayChromaDenoise)
        assertThrows(AdjustmentTransferException::class.java) { prepare(payload(F.RAW_DENOISE to AdjustmentValue.Number(1.0))) }
        assertThrows(AdjustmentTransferException::class.java) { prepare(payload(F.POST_RGB_DENOISE to AdjustmentValue.Number(.2))) }
        assertEquals(EditSettings(), prepare(payload(F.POST_RGB_DENOISE to AdjustmentValue.Number(0.0))))
    }

    @Test fun geometryMergesAtomicallyAndLensRequiresActualTargetValidation() {
        val target = EditSettings(geometry = GeometrySettings(cropX = .6f, cropWidth = .4f))
        assertThrows(AdjustmentTransferException::class.java) { prepare(payload(F.CROP_WIDTH to AdjustmentValue.Number(.8)), target) }
        val merged = prepare(payload(F.CROP_X to AdjustmentValue.Number(.1), F.CROP_WIDTH to AdjustmentValue.Number(.8)), target)
        assertEquals(.1f, merged.geometry.cropX); assertEquals(.8f, merged.geometry.cropWidth)
        for (request in listOf(payload(F.LENS_PROFILE to AdjustmentValue.Text("fixture-profile")),
            payload(F.LENS_AUTO_CROP to AdjustmentValue.Boolean(false)))) {
            assertThrows(AdjustmentTransferException::class.java) { prepare(request, context = context.copy(isRaw = false)) }
        }
        val lens = payload(F.LENS_DISTORTION to AdjustmentValue.Boolean(true))
        assertThrows(AdjustmentTransferException::class.java) { prepare(lens) }
        var validated = false
        val accepted = prepare(lens, context = context.copy(validateLens = { validated = it.distortion }))
        assertTrue(validated); assertTrue(accepted.lens.distortion)
        assertThrows(AdjustmentTransferException::class.java) { prepare(lens, context = context.copy(isRaw = false)) }
    }

    @Test fun manualLensWithoutProfilePreservesSelectionAndRejectsEnabledRequests() {
        val source = EditSettings(lens = LensSettings(manual = true))
        for (scope in listOf(AdjustmentScope.All, AdjustmentScope.Custom(setOf(F.LENS_PROFILE)))) {
            val copied = AdjustmentTransfer.capture(scope, source, context)
            assertEquals(AdjustmentValue.Text(source.lens.coreProfileId), copied[F.LENS_PROFILE])
            val restored = AdjustmentPayload.decode(copied.encode())
            assertEquals(copied, restored)
            val applied = prepare(restored)
            assertTrue(applied.lens.manual); assertNull(applied.lens.profileId)
        }
        val standard = AdjustmentTransfer.capture(AdjustmentScope.Custom(F.COMMON), source, context)
        assertTrue(standard.fields.none { it in F.LENS })
        val enabled = capture(source.copy(lens = LensSettings(distortion = true, manual = true)), F.LENS_DISTORTION, F.LENS_PROFILE)
        var validated = false
        assertThrows(AdjustmentTransferException::class.java) { prepare(enabled, context = context.copy(validateLens = { validated = true })) }
        assertFalse(validated)
    }

    @Test fun fractionalEffectsBypassUIQuantizationAndRawRequestsRejectRaster() {
        val result = prepare(payload(F.GRAIN_AMOUNT to AdjustmentValue.Number(12.375), F.VIGNETTE_MIDPOINT to AdjustmentValue.Number(32.25)))
        assertEquals(12.375f, result.effects.grainAmount); assertEquals(32.25f, result.effects.vignetteMidpoint)
        assertThrows(AdjustmentTransferException::class.java) { prepare(payload(F.EXPOSURE to AdjustmentValue.Number(5.0))) }
        assertThrows(AdjustmentTransferException::class.java) {
            prepare(payload(F.EXPOSURE_MODE to AdjustmentValue.Text("preview")), context = context.copy(isRaw = false))
        }
        assertThrows(AdjustmentTransferException::class.java) {
            prepare(payload(F.LOOK to AdjustmentValue.Object(mapOf("kind" to AdjustmentValue.Text("managed"), "id" to AdjustmentValue.Text("missing")))))
        }
    }

    @Test fun sharedEffectiveVectorsApplyWithTargetNativePrecision() {
        val vectors = JSONObject(File("../../Shared/fixtures/adjustment-transfer-v1.json").readText()).getJSONArray("vectors")
        for (index in 0 until vectors.length()) {
            val vector = vectors.getJSONObject(index)
            if (!vector.has("neutral_effective")) continue
            val payload = AdjustmentPayload.decode(vector.getJSONObject("payload").toString())
            val result = prepare(payload)
            val actual = AdjustmentTransfer.effectiveNumbers(result)
            val expected = vector.getJSONObject("neutral_effective")
            for (id in expected.keys()) assertEquals(vector.getString("id") + ":" + id,
                expected.getDouble(id).toFloat(), actual[AdjustmentField.fromID(id)]!!, 1e-6f)
        }
    }
}
