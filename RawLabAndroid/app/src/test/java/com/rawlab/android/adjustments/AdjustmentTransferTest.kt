package com.rawlab.android.adjustments

import com.rawlab.android.settings.*
import com.rawlab.android.looks.MasterRecipe
import com.rawlab.android.looks.applyRecipe
import org.json.JSONArray
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

    private fun builtinRecipes(): List<MasterRecipe> {
        val rows = JSONArray(resolveSharedPath("Shared/master-recipes.json").readText())
        return (0 until rows.length()).map { MasterRecipe.decode(rows.getJSONObject(it)) }
    }

    @Test fun fullNeutralRawRecipeClearsPreviousRasterTint() {
        val recipe = builtinRecipes().first()
        val raster = context.copy(isRaw = false, availableLookIDs = setOf("recipe:${recipe.id}"))
        val target = EditSettings(exposureMode = 2).applyRecipe(recipe)
        val source = target.copy(tint = 0f)
        val full = AdjustmentTransfer.capture(AdjustmentScope.Custom(F.COMMON), source, context)
        val applied = prepare(full, target, raster)
        assertNotEquals(target, applied); assertEquals(0f, applied.tint)
        assertEquals(AdjustmentValue.Number(0.0), AdjustmentTransferValues.values(applied, raster)[F.TINT])
        assertEquals(applied, prepare(full, applied, raster))
    }

    @Test fun builtinRawRecipesMatchDirectRasterApplication() {
        val recipes = builtinRecipes()
        val raster = context.copy(isRaw = false, availableLookIDs = recipes.map { "recipe:${it.id}" }.toSet(),
            recipeTintDefaults = recipes.associate { it.id to it.tint })
        for (recipe in recipes) for (strength in listOf(0f, .5f, 1f, 2f)) {
            val source = EditSettings().applyRecipe(recipe).copy(strength = strength)
            val direct = EditSettings(exposureMode = 2).applyRecipe(recipe).copy(strength = strength)
            val previous = EditSettings(exposureMode = 2).applyRecipe(recipes.first())
            for (scope in listOf(AdjustmentScope.Custom(F.COMMON), AdjustmentScope.All)) {
                val frozen = AdjustmentPayload.decode(AdjustmentTransfer.capture(scope, source, context).encode())
                val applied = prepare(frozen, previous, raster)
                assertEquals("${recipe.id}, strength $strength", AdjustmentTransferValues.values(direct, raster),
                    AdjustmentTransferValues.values(applied, raster))
                assertEquals(applied, prepare(frozen, applied, raster))
            }
            val partial = AdjustmentTransfer.capture(AdjustmentScope.Custom(F.WHITE_BALANCE), source, context)
            assertThrows(AdjustmentTransferException::class.java) { prepare(partial, previous, raster) }
            val edited = AdjustmentTransfer.capture(AdjustmentScope.Custom(F.COMMON), source.copy(tint = recipe.tint + 1), context)
            assertThrows(AdjustmentTransferException::class.java) { prepare(edited, previous, raster) }
            val fixed = AdjustmentTransfer.capture(AdjustmentScope.Custom(F.COMMON),
                source.copy(customWb = true, temperature = 5400f), context)
            assertThrows(AdjustmentTransferException::class.java) { prepare(fixed, previous, raster) }
        }
    }

    @Test fun neutralRawStandardPasteKeepsRasterWhiteBalanceAndSensorExposure() {
        val raster = context.copy(identifier = "target.jpg", isRaw = false, cameraTemperature = null, cameraTint = null)
        val target = EditSettings(exposureMode = 2)
        for (mode in 0..2) {
            val source = EditSettings(exposureMode = mode, exposure = 1.25f)
            val standard = AdjustmentTransfer.capture(AdjustmentScope.Custom(F.COMMON), source, context)
            val applied = prepare(standard, target, raster)
            assertNotEquals(target, applied); assertEquals(1.25f, applied.exposure)
            assertEquals(AdjustmentValue.Text("none"), AdjustmentTransferValues.values(applied, raster)[F.WHITE_BALANCE_MODE])
            assertFalse(applied.customWb); assertEquals(6500f, applied.temperature); assertEquals(0f, applied.tint)
            assertEquals(2, applied.exposureMode)
            assertEquals(applied, prepare(standard, applied, raster))
            val neutral = AdjustmentTransfer.capture(AdjustmentScope.Custom(F.COMMON), source.copy(exposure = 0f), context)
            assertEquals(target, prepare(neutral, target, raster))
            assertEquals(target, prepare(capture(source, F.EXPOSURE_MODE), target, raster))
        }
        for (field in F.WHITE_BALANCE) {
            assertEquals(target, prepare(capture(EditSettings(), field), target, raster))
        }
        for (strength in listOf(0f, 1f)) {
            val recipe = EditSettings(recipeID = "r", strength = strength, tint = 0f)
            assertEquals(target, prepare(capture(recipe, F.WHITE_BALANCE_MODE, F.TEMPERATURE, F.TINT), target, raster))
            val relative = capture(recipe.copy(tint = 5f), F.TINT)
            val error = assertThrows(AdjustmentTransferException::class.java) { prepare(relative, target, raster) }
            assertEquals(AdjustmentFailure.INCOMPATIBLE, error.reason)
        }
    }

    @Test fun fixedRawWhiteBalanceRejectsRasterAndNonzeroFbddIsIgnoredWithNotice() {
        val raster = context.copy(isRaw = false)
        val fixed = EditSettings(customWb = true, temperature = 5400f, tint = 3.5f)
        for (fields in listOf(F.WHITE_BALANCE, setOf(F.TEMPERATURE), setOf(F.TINT))) {
            val request = AdjustmentTransfer.capture(AdjustmentScope.Custom(fields), fixed, context)
            val error = assertThrows(AdjustmentTransferException::class.java) { prepare(request, context = raster) }
            assertEquals(AdjustmentFailure.INCOMPATIBLE, error.reason)
        }
        // Q3：Android 不建模解马赛克前 FBDD，非 0 值忽略并提示，不再因目标类型拒绝。
        val notices = mutableListOf<AdjustmentTransferNotice>()
        val ignored = prepare(payload(F.RAW_DENOISE to AdjustmentValue.Number(1.0)),
            context = raster.copy(onTransferNotice = { notices.add(it) }))
        assertEquals(EditSettings(), ignored)
        assertEquals(listOf(AdjustmentTransferNotice.RETAINED_TARGET_PROCESSING_VERSION,
            AdjustmentTransferNotice.IGNORED_RAW_DENOISE), notices)
    }

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
        val target = EditSettings(contrast = 1.25f, hsl = HslSettings().withValue(1, 0, 23.5f),
            geometry = GeometrySettings(cropWidth = .6f), processing = ProcessingIdentity.LEGACY)
        val result = prepare(payload, target)
        assertEquals(1.5f, result.exposure); assertEquals(1.25f, result.contrast)
        assertEquals(12.375f, result.hsl.value(0, 0)); assertEquals(23.5f, result.hsl.value(1, 0))
        assertEquals(target.geometry, result.geometry); assertEquals(target.processing, result.processing)
        assertEquals(result, prepare(payload, result))
        assertEquals(AdjustmentValue.Number(1.5), payload[F.EXPOSURE])
    }

    @Test fun allIncludesGeometryAndModifiedUsesDefaultsWithoutGeometry() {
        val source = EditSettings(exposure = .5f, geometry = GeometrySettings(cropWidth = .5f))
        val all = AdjustmentTransfer.capture(AdjustmentScope.All, source, context).fields
        val fixtureAllFieldIDs = scenarioFixtureAllFieldIDs()
        assertEquals(F.entries.filterNot { it.isHDROnly }.toSet(), all)
        assertEquals(fixtureAllFieldIDs.size, all.size)
        assertEquals(fixtureAllFieldIDs, all.map { it.id }.toSet())
        assertEquals(setOf(F.EXPOSURE), AdjustmentTransfer.capture(AdjustmentScope.Modified, source, context).fields)
        assertThrows(AdjustmentTransferException::class.java) {
            AdjustmentTransfer.capture(AdjustmentScope.Modified, EditSettings(), context)
        }
        assertThrows(AdjustmentTransferException::class.java) {
            AdjustmentTransfer.capture(AdjustmentScope.All, source, context.copy(hasUncommittedDraft = true))
        }
    }

    @Test fun recipeContributionAppliesOnceAndUnselectedRecipeValuesStayEffective() {
        val source = EditSettings(recipeID = "r", strength = .5f, exposure = 1.4f, contrast = 1.4f)
        val values = capture(source, F.EXPOSURE, F.CONTRAST)
        val target = EditSettings(recipeID = "r", strength = .8f, exposure = -.2f, contrast = .8f, saturation = 1.3f)
        val result = prepare(values, target)
        assertEquals(.7f, result.exposure * result.recipeScale, 1e-6f)
        assertEquals(1.2f, 1f + (result.contrast - 1f) * result.recipeScale, 1e-6f)
        assertEquals(target.saturation, result.saturation)
        assertEquals("r", result.recipeID)
        assertEquals(result, prepare(values, result))
    }

    // A17/P1-10：带配方的普通来源粘到 HDR 目标时，来源强度必须恰好应用一次并写入 HDR 原生模型
    // （percent 偏移），与 Mac `recipeSourceOnHDR`、Windows `RecipeSourceScalesOnHDRTarget` 的锚点对齐。
    @Test fun recipeSourceStrengthAppliesOnceOnHDR() {
        val hdrTarget = EditSettings().withHDRMode(true, true)
        val hdrContext = context.copy(isRaw = false, defaultExposureMode = 2)
        for (strength in listOf(0.5f, 1.0f)) {
            val source = EditSettings(recipeID = "r", strength = strength, exposure = 1f, contrast = 1.4f)
            val values = capture(source, F.EXPOSURE, F.CONTRAST)
            val applied = prepare(values, hdrTarget, hdrContext).hdr
            requireNotNull(applied) { "strength $strength: HDR target must retain HDR settings" }
            assertEquals(strength, applied.exposure, 1e-6f)
            assertEquals(strength * 40f, applied.contrast, 1e-4f)
        }
    }

    @Test fun selectingStrengthProtectsUnselectedContributionsAndBlocksZeroScaleLoss() {
        val target = EditSettings(recipeID = "r", strength = .5f, exposure = 1f, saturation = 1.4f,
            hsl = HslSettings().withValue(0, 2, 20f))
        val result = prepare(payload(F.STRENGTH to AdjustmentValue.Number(1.0)), target)
        assertEquals(.5f, result.exposure)
        assertEquals(1f + (target.saturation - 1f) * target.recipeScale, 1f + (result.saturation - 1f) * result.recipeScale)
        assertEquals(10f, result.hsl.value(0, 2))
        assertThrows(AdjustmentTransferException::class.java) { prepare(payload(F.STRENGTH to AdjustmentValue.Number(0.0)), target) }
    }

    @Test fun partialRecipeLookBecomesIndependentLUTWithoutReapplyingRecipe() {
        val source = EditSettings(recipeID = "r", strength = .5f, exposure = 2f)
        val target = EditSettings(exposure = -.5f, saturation = 1.3f)
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
        val self = EditSettings(recipeID = "r", strength = .7f, exposure = .23f, contrast = 1.21f,
            hsl = HslSettings().withValue(0, 0, 13.15f))
        assertEquals(self, prepare(AdjustmentTransfer.capture(AdjustmentScope.All, self, context), self))
    }

    @Test fun fullV4RawRecipeAtDoubleStrengthPreservesNonFloatExactContrastAndSaturation() {
        val recipe = AdjustmentRecipeContext("hamada_daylight_v2", 2.0, 4)
        val ctx = context.copy(
            availableLookIDs = setOf("recipe:hamada_daylight_v2"),
            cameraTemperature = 5200f,
            cameraTint = 8f,
        )
        val values = linkedMapOf<F, V>(
            F.LOOK to AdjustmentValue.Object(mapOf("kind" to AdjustmentValue.Text("recipe"), "id" to AdjustmentValue.Text("hamada_daylight_v2"))),
            F.STRENGTH to AdjustmentValue.Number(2.0),
            F.EXPOSURE to AdjustmentValue.Number(0.5),
            F.CONTRAST to AdjustmentValue.Number(0.9),
            F.HIGHLIGHTS to AdjustmentValue.Number(0.125),
            F.SHADOWS to AdjustmentValue.Number(0.25),
            F.SATURATION to AdjustmentValue.Number(0.92),
            F.WHITE_BALANCE_MODE to AdjustmentValue.Text("camera"),
            F.TEMPERATURE to AdjustmentValue.Null,
            F.TINT to AdjustmentValue.Number(5.0),
            F.S_CURVE to AdjustmentValue.Number(0.8),
            F.BLACK_POINT to AdjustmentValue.Number(80.0),
            F.WHITE_POINT to AdjustmentValue.Number(0.0),
            F.VIBRANCE to AdjustmentValue.Number(80.0),
            F.CLARITY to AdjustmentValue.Number(0.0),
            F.DEHAZE to AdjustmentValue.Number(0.0),
            F.CURVE to AdjustmentValue.Object(mapOf("mode" to AdjustmentValue.Text("custom"), "points" to AdjustmentValue.Array(listOf(
                AdjustmentValue.Array(listOf(AdjustmentValue.Number(0.0), AdjustmentValue.Number(0.0))),
                AdjustmentValue.Array(listOf(AdjustmentValue.Number(0.5), AdjustmentValue.Number(0.7))),
                AdjustmentValue.Array(listOf(AdjustmentValue.Number(1.0), AdjustmentValue.Number(1.0))),
            )))),
            F.GRADING_SHADOWS to AdjustmentValue.Object(mapOf("hue" to AdjustmentValue.Number(30.0), "saturation" to AdjustmentValue.Number(80.0), "luminance" to AdjustmentValue.Number(20.0))),
            F.GRADING_MIDTONES to AdjustmentValue.Object(mapOf("hue" to AdjustmentValue.Number(0.0), "saturation" to AdjustmentValue.Number(0.0))),
            F.GRADING_HIGHLIGHTS to AdjustmentValue.Object(mapOf("hue" to AdjustmentValue.Number(0.0), "saturation" to AdjustmentValue.Number(0.0))),
        )
        for (field in F.entries) if (field.hslLocation != null) {
            values[field] = AdjustmentValue.Number(if (field == F.HSL_HUE_RED) 80.0 else 0.0)
        }
        val request = AdjustmentPayload(AdjustmentSource("full-v4-rounding.ARW", true, 3, recipe), values)
        val result = prepare(request, EditSettings(), ctx)
        assertEquals("hamada_daylight_v2", result.recipeID)
        assertEquals(4, result.masterRecipeSettingsVersion)
        assertEquals(2.0f, result.strength)
        assertEquals(0.5f, result.exposure)
        assertEquals(0.9f, result.contrast)
        assertEquals(0.125f, result.highlights)
        assertEquals(0.25f, result.shadows)
        assertEquals(0.92f, result.saturation)
        assertEquals(5.0f, result.tint)
        assertEquals(0.8f, result.toneCurve)
        assertEquals(80.0f, result.blackPoint)
        assertEquals(80.0f, result.vibrance)
        assertEquals(80.0f, result.hsl.value(0, 0))
        assertEquals(result, prepare(request, result, ctx))
    }

    @Test fun fullV4RawRecipePreservesLogicalValuesAcrossAllPercentStrengthsAndStillRejectsOutOfRange() {
        val ctx = context.copy(
            availableLookIDs = setOf("recipe:hamada_daylight_v2"),
            cameraTemperature = 5200f,
            cameraTint = 8f,
        )
        fun fullPayload(strength: Double, overrides: Map<F, V> = emptyMap()): AdjustmentPayload {
            val values = linkedMapOf<F, V>(
                F.LOOK to AdjustmentValue.Object(mapOf("kind" to AdjustmentValue.Text("recipe"), "id" to AdjustmentValue.Text("hamada_daylight_v2"))),
                F.STRENGTH to AdjustmentValue.Number(strength),
                F.EXPOSURE to AdjustmentValue.Number(-0.3),
                F.CONTRAST to AdjustmentValue.Number(0.9),
                F.HIGHLIGHTS to AdjustmentValue.Number(-0.15),
                F.SHADOWS to AdjustmentValue.Number(0.3),
                F.SATURATION to AdjustmentValue.Number(0.92),
                F.WHITE_BALANCE_MODE to AdjustmentValue.Text("camera"),
                F.TEMPERATURE to AdjustmentValue.Null,
                F.TINT to AdjustmentValue.Number(5.1),
                F.S_CURVE to AdjustmentValue.Number(0.3),
                F.BLACK_POINT to AdjustmentValue.Number(-33.3),
                F.WHITE_POINT to AdjustmentValue.Number(15.5),
                F.VIBRANCE to AdjustmentValue.Number(7.1),
                F.CLARITY to AdjustmentValue.Number(-7.1),
                F.DEHAZE to AdjustmentValue.Number(33.3),
                F.CURVE to AdjustmentValue.Object(mapOf("mode" to AdjustmentValue.Text("custom"), "points" to AdjustmentValue.Array(listOf(
                    AdjustmentValue.Array(listOf(AdjustmentValue.Number(0.0), AdjustmentValue.Number(0.0))),
                    AdjustmentValue.Array(listOf(AdjustmentValue.Number(0.5), AdjustmentValue.Number(0.7))),
                    AdjustmentValue.Array(listOf(AdjustmentValue.Number(1.0), AdjustmentValue.Number(1.0))),
                )))),
                F.CURVE_PARAMETRIC to AdjustmentValue.Object(mapOf(
                    "highlights" to AdjustmentValue.Number(25.0),
                    "lights" to AdjustmentValue.Number(0.0),
                    "darks" to AdjustmentValue.Number(0.0),
                    "shadows" to AdjustmentValue.Number(-10.0),
                    "split_shadow" to AdjustmentValue.Number(0.25),
                    "split_midtone" to AdjustmentValue.Number(0.5),
                    "split_highlight" to AdjustmentValue.Number(0.75),
                )),
                F.GRADING_SHADOWS to AdjustmentValue.Object(mapOf("hue" to AdjustmentValue.Number(210.0), "saturation" to AdjustmentValue.Number(33.3), "luminance" to AdjustmentValue.Number(-12.7))),
                F.GRADING_MIDTONES to AdjustmentValue.Object(mapOf("hue" to AdjustmentValue.Number(0.0), "saturation" to AdjustmentValue.Number(0.0))),
                F.GRADING_HIGHLIGHTS to AdjustmentValue.Object(mapOf("hue" to AdjustmentValue.Number(0.0), "saturation" to AdjustmentValue.Number(0.0))),
            )
            for (field in F.entries) if (field.hslLocation != null) {
                values[field] = AdjustmentValue.Number(if (field == F.HSL_HUE_RED) -33.3 else 0.0)
            }
            values.putAll(overrides)
            return AdjustmentPayload(AdjustmentSource("full-v4-grid.ARW", true, 3, AdjustmentRecipeContext("hamada_daylight_v2", strength, 4)), values)
        }

        for (pct in 0..200) {
            val strength = pct / 100.0
            val payload = fullPayload(strength)
            val result = prepare(payload, EditSettings(), ctx)
            assertEquals("strength $strength", strength.toFloat(), result.strength)
            assertEquals("exposure at $strength", -0.3f, result.exposure)
            assertEquals("contrast at $strength", 0.9f, result.contrast)
            assertEquals("highlights at $strength", -0.15f, result.highlights)
            assertEquals("shadows at $strength", 0.3f, result.shadows)
            assertEquals("saturation at $strength", 0.92f, result.saturation)
            assertEquals("tint at $strength", 5.1f, result.tint)
            assertEquals("s_curve at $strength", 0.3f, result.toneCurve)
            assertEquals("black_point at $strength", -33.3f, result.blackPoint)
            assertEquals("white_point at $strength", 15.5f, result.whitePoint)
            assertEquals("vibrance at $strength", 7.1f, result.vibrance)
            assertEquals("clarity at $strength", -7.1f, result.clarity)
            assertEquals("dehaze at $strength", 33.3f, result.dehaze)
            assertEquals("hsl red hue at $strength", -33.3f, result.hsl.value(0, 0))
            assertEquals("grading shadows sat at $strength", 33.3f, result.colorGrading.shadows.saturation)
            assertEquals("grading shadows lum at $strength", -12.7f, result.colorGrading.shadows.luminance)
            assertEquals("curve mid y at $strength", 0.7, result.curve.points[1].y, 0.0)
            assertEquals("parametric highlights at $strength", 25.0, result.curve.parametric.highlights, 0.0)
            assertEquals("idempotent at $strength", result, prepare(payload, result, ctx))
        }

        // Genuine unrepresentable full-recipe requests remain rejected.
        val outOfRangeExposure = assertThrows(AdjustmentTransferException::class.java) {
            prepare(fullPayload(1.0, mapOf(F.EXPOSURE to AdjustmentValue.Number(6.0))), EditSettings(), ctx)
        }
        assertEquals(AdjustmentFailure.UNREPRESENTABLE, outOfRangeExposure.reason)
        val outOfRangeTint = assertThrows(AdjustmentTransferException::class.java) {
            prepare(fullPayload(2.0, mapOf(F.TINT to AdjustmentValue.Number(150.0))), EditSettings(), ctx)
        }
        assertEquals(AdjustmentFailure.UNREPRESENTABLE, outOfRangeTint.reason)
        assertEquals(F.TINT.id, outOfRangeTint.field)
    }

    @Test fun partialRecipeExposurePasteBetweenSameRecipeAndStrengthPreservesLogicalValue() {
        val ctx = context.copy(
            availableLookIDs = setOf("recipe:hamada_daylight_v2"),
            cameraTemperature = 5200f,
            cameraTint = 8f,
        )
        val request = AdjustmentPayload(
            AdjustmentSource("src.ARW", true, 3, AdjustmentRecipeContext("hamada_daylight_v2", 0.3, 4)),
            mapOf(F.EXPOSURE to AdjustmentValue.Number(-1.3)),
        )
        val target = EditSettings(
            recipeID = "hamada_daylight_v2",
            strength = 0.3f,
            masterRecipeSettingsVersion = 4,
            exposure = 0f,
        )
        val result = prepare(request, target, ctx)
        assertEquals("hamada_daylight_v2", result.recipeID)
        assertEquals(0.3f, result.strength)
        assertEquals(-1.3f, result.exposure)
        assertEquals(result, prepare(request, result, ctx))
    }

    @Test fun partialRecipePastesBetweenSameRecipeAndStrengthAcceptAllScaledFamiliesAndKeepGenuineRejections() {
        val ctx = context.copy(
            availableLookIDs = setOf("recipe:hamada_daylight_v2"),
            cameraTemperature = 5200f,
            cameraTint = 8f,
        )
        for (strength in listOf(0.01, 0.09, 0.3, 0.62, 0.7, 1.3, 1.99, 2.0)) {
            val recipe = AdjustmentRecipeContext("hamada_daylight_v2", strength, 4)
            val src = AdjustmentSource("src.ARW", true, 3, recipe)
            val target = EditSettings(recipeID = "hamada_daylight_v2", strength = strength.toFloat(), masterRecipeSettingsVersion = 4)

            val contrast = prepare(AdjustmentPayload(src, mapOf(F.CONTRAST to AdjustmentValue.Number(0.9))), target, ctx)
            assertEquals(AdjustmentTransfer.nativeSourceEffective(0.9, F.CONTRAST, recipe), AdjustmentTransfer.effectiveNumbers(contrast)[F.CONTRAST])

            val hsl = prepare(AdjustmentPayload(src, mapOf(F.HSL_HUE_RED to AdjustmentValue.Number(-33.3))), target, ctx)
            assertEquals(AdjustmentTransfer.nativeSourceEffective(-33.3, F.HSL_HUE_RED, recipe), AdjustmentTransfer.effectiveNumbers(hsl)[F.HSL_HUE_RED])

            val tint = prepare(AdjustmentPayload(src, mapOf(F.TINT to AdjustmentValue.Number(-12.3))), target, ctx)
            assertEquals(8f + (-12.3f) * strength.toFloat(), 8f + tint.tint * tint.strength)

            val wheel = AdjustmentValue.Object(mapOf("hue" to AdjustmentValue.Number(30.0), "saturation" to AdjustmentValue.Number(80.0), "luminance" to AdjustmentValue.Number(20.0)))
            val grading = prepare(AdjustmentPayload(src, mapOf(F.GRADING_SHADOWS to wheel)), target, ctx)
            assertEquals(ColorGradingWheel(30f, 80f, 20f).scaled(strength.toFloat()), grading.renderColorGrading.shadows)

            val curveObj = AdjustmentValue.Object(mapOf("mode" to AdjustmentValue.Text("custom"), "points" to AdjustmentValue.Array(listOf(
                AdjustmentValue.Array(listOf(AdjustmentValue.Number(0.0), AdjustmentValue.Number(0.0))),
                AdjustmentValue.Array(listOf(AdjustmentValue.Number(0.5), AdjustmentValue.Number(1.0))),
                AdjustmentValue.Array(listOf(AdjustmentValue.Number(1.0), AdjustmentValue.Number(1.0))),
            ))))
            val curved = prepare(AdjustmentPayload(src, mapOf(F.CURVE to curveObj)), target, ctx)
            assertEquals(AdjustmentPayload.curve(curveObj).scaled(strength.toFloat()), curved.renderCurve)
        }

        // Genuine rejections stay rejected: out of neutral range, and unreachable Float at target strength 2.0.
        val outOfNeutralRange = AdjustmentPayload(
            AdjustmentSource("src.ARW", true, 3, AdjustmentRecipeContext("hamada_daylight_v2", 1.3, 4)),
            mapOf(F.CONTRAST to AdjustmentValue.Number(0.2)),
        )
        assertEquals(
            AdjustmentFailure.UNREPRESENTABLE,
            assertThrows(AdjustmentTransferException::class.java) { prepare(outOfNeutralRange, EditSettings(), ctx) }.reason,
        )
        val unreachableAt2x = AdjustmentPayload(
            AdjustmentSource("src.ARW", true, 3, AdjustmentRecipeContext("hamada_daylight_v2", 1.0, 4)),
            mapOf(F.CONTRAST to AdjustmentValue.Number(0.2)),
        )
        val target2x = EditSettings(recipeID = "hamada_daylight_v2", strength = 2.0f, masterRecipeSettingsVersion = 4)
        assertEquals(
            AdjustmentFailure.UNREPRESENTABLE,
            assertThrows(AdjustmentTransferException::class.java) { prepare(unreachableAt2x, target2x, ctx) }.reason,
        )
    }

    @Test fun partialRecipePasteAcceptsSliderEndpointsAcrossSameAndCrossStrength() {
        val ctx = context.copy(
            availableLookIDs = setOf("recipe:hamada_daylight_v2"),
            cameraTemperature = 5200f,
            cameraTint = 8f,
        )
        // Exposure endpoints (-5.0, +5.0) at strength 0.97: inversion gives +/-5.0000005f.
        val src97 = AdjustmentSource("src.ARW", true, 3, AdjustmentRecipeContext("hamada_daylight_v2", 0.97, 4))
        val target97 = EditSettings(recipeID = "hamada_daylight_v2", strength = 0.97f, masterRecipeSettingsVersion = 4)
        assertEquals(-5.0f, prepare(AdjustmentPayload(src97, mapOf(F.EXPOSURE to AdjustmentValue.Number(-5.0))), target97, ctx).exposure)
        assertEquals(5.0f, prepare(AdjustmentPayload(src97, mapOf(F.EXPOSURE to AdjustmentValue.Number(5.0))), target97, ctx).exposure)
        // Cross-strength exposure endpoint where inversion overshoots -5.0f.
        val neutralSrc = AdjustmentSource("neutral.ARW", true, 3, null)
        assertEquals(-5.0f, prepare(AdjustmentPayload(neutralSrc, mapOf(F.EXPOSURE to AdjustmentValue.Number(-4.850000381469727))), target97, ctx).exposure)

        // Contrast endpoints (0.0 and 2.0) at low strength 0.09: inversion overshoots legal range by >1 ULP.
        val src09 = AdjustmentSource("src.ARW", true, 3, AdjustmentRecipeContext("hamada_daylight_v2", 0.09, 4))
        val target09 = EditSettings(recipeID = "hamada_daylight_v2", strength = 0.09f, masterRecipeSettingsVersion = 4)
        assertEquals(0.0f, prepare(AdjustmentPayload(src09, mapOf(F.CONTRAST to AdjustmentValue.Number(0.0))), target09, ctx).contrast)
        assertEquals(2.0f, prepare(AdjustmentPayload(src09, mapOf(F.CONTRAST to AdjustmentValue.Number(2.0))), target09, ctx).contrast)
        // Cross-strength contrast endpoints exercising clamping of the inverted candidate back into [0, 2].
        assertEquals(0.0f, prepare(AdjustmentPayload(neutralSrc, mapOf(F.CONTRAST to AdjustmentValue.Number(0.9099999666213989))), target09, ctx).contrast)
        assertEquals(2.0f, prepare(AdjustmentPayload(neutralSrc, mapOf(F.CONTRAST to AdjustmentValue.Number(1.090000033378601))), target09, ctx).contrast)

        // Relative tint endpoints when inversion overshoots +/-150f (by 1 ULP at 0.061 and by >1 ULP at 0.001 with camTint=100).
        val tintCtx0 = ctx.copy(cameraTint = 0f)
        val targetTint061 = EditSettings(recipeID = "hamada_daylight_v2", strength = 0.061f, masterRecipeSettingsVersion = 4)
        val srcTint061 = AdjustmentSource("src.ARW", true, 3, AdjustmentRecipeContext("hamada_daylight_v2", 0.061, 4))
        assertEquals(-150.0f, prepare(AdjustmentPayload(srcTint061, mapOf(F.TINT to AdjustmentValue.Number(-150.0))), targetTint061, tintCtx0).tint)
        assertEquals(-150.0f, prepare(AdjustmentPayload(neutralSrc, mapOf(
            F.WHITE_BALANCE_MODE to AdjustmentValue.Text("temperature"),
            F.TEMPERATURE to AdjustmentValue.Number(5200.0),
            F.TINT to AdjustmentValue.Number(-9.15000057220459),
        )), targetTint061, tintCtx0).tint)
        val tintCtx100 = ctx.copy(cameraTint = 100f)
        val targetTint001 = EditSettings(recipeID = "hamada_daylight_v2", strength = 0.001f, masterRecipeSettingsVersion = 4)
        assertEquals(-150.0f, prepare(AdjustmentPayload(neutralSrc, mapOf(
            F.WHITE_BALANCE_MODE to AdjustmentValue.Text("temperature"),
            F.TEMPERATURE to AdjustmentValue.Number(5200.0),
            F.TINT to AdjustmentValue.Number(99.8499984741211),
        )), targetTint001, tintCtx100).tint)

        // Genuine unrepresentable requests just beyond the representable endpoints remain rejected.
        assertEquals(
            AdjustmentFailure.UNREPRESENTABLE,
            assertThrows(AdjustmentTransferException::class.java) {
                prepare(AdjustmentPayload(neutralSrc, mapOf(F.EXPOSURE to AdjustmentValue.Number(-4.850000858306885))), target97, ctx)
            }.reason,
        )
        assertEquals(
            AdjustmentFailure.UNREPRESENTABLE,
            assertThrows(AdjustmentTransferException::class.java) {
                prepare(AdjustmentPayload(neutralSrc, mapOf(F.CONTRAST to AdjustmentValue.Number(0.9099999070167542))), target09, ctx)
            }.reason,
        )
        assertEquals(
            AdjustmentFailure.UNREPRESENTABLE,
            assertThrows(AdjustmentTransferException::class.java) {
                prepare(AdjustmentPayload(neutralSrc, mapOf(F.CONTRAST to AdjustmentValue.Number(1.0900001525878906))), target09, ctx)
            }.reason,
        )
        assertEquals(
            AdjustmentFailure.UNREPRESENTABLE,
            assertThrows(AdjustmentTransferException::class.java) {
                prepare(AdjustmentPayload(neutralSrc, mapOf(
                    F.WHITE_BALANCE_MODE to AdjustmentValue.Text("temperature"),
                    F.TEMPERATURE to AdjustmentValue.Number(5200.0),
                    F.TINT to AdjustmentValue.Number(-9.150001525878906),
                )), targetTint061, tintCtx0)
            }.reason,
        )
    }

    @Test fun partialRecipePasteInvertsInManyToOneStrengthZeroAndClampRegions() {
        val ctx = context.copy(
            availableLookIDs = setOf("recipe:r"),
            cameraTemperature = 5200f,
            cameraTint = 60f,
        )
        // Guard: strength-0 target writes neutral logical values and reports applied (not unchanged).
        val zeroTarget = EditSettings(
            recipeID = "r",
            strength = 0f,
            masterRecipeSettingsVersion = 4,
            exposure = 2.5f,
            contrast = 1.8f,
            toneCurve = 0.7f,
            vibrance = 60f,
            tint = 45f,
            hsl = HslSettings(List(24) { if (it == 0) -80f else 0f }),
        )
        val zeroRecipe = AdjustmentRecipeContext("r", 0.0, 4)
        val zeroReset = prepare(
            payload(
                F.EXPOSURE to AdjustmentValue.Number(0.0),
                F.CONTRAST to AdjustmentValue.Number(1.0),
                F.S_CURVE to AdjustmentValue.Number(0.0),
                F.VIBRANCE to AdjustmentValue.Number(0.0),
                F.HSL_HUE_RED to AdjustmentValue.Number(0.0),
                F.TINT to AdjustmentValue.Number(0.0),
                recipe = zeroRecipe,
            ),
            zeroTarget,
            ctx,
        )
        assertNotEquals(zeroTarget, zeroReset)
        assertEquals(0f, zeroReset.exposure)
        assertEquals(1f, zeroReset.contrast)
        assertEquals(0f, zeroReset.toneCurve)
        assertEquals(0f, zeroReset.vibrance)
        assertEquals(0f, zeroReset.hsl.value(0, 0))
        assertEquals(0f, zeroReset.tint)

        // Guard: pasting {STRENGTH: 0, EXPOSURE: 0, CONTRAST: 1, TINT: 0} onto a strength-1 target writes neutral values.
        val strengthOneTarget = EditSettings(
            recipeID = "r",
            strength = 1.0f,
            masterRecipeSettingsVersion = 4,
            exposure = 2.5f,
            contrast = 1.8f,
            tint = 35f,
        )
        val toZero = prepare(
            payload(
                F.STRENGTH to AdjustmentValue.Number(0.0),
                F.EXPOSURE to AdjustmentValue.Number(0.0),
                F.CONTRAST to AdjustmentValue.Number(1.0),
                F.TINT to AdjustmentValue.Number(0.0),
                recipe = zeroRecipe,
            ),
            strengthOneTarget,
            ctx,
        )
        assertNotEquals(strengthOneTarget, toZero)
        assertEquals(0f, toZero.strength)
        assertEquals(0f, toZero.exposure)
        assertEquals(1f, toZero.contrast)
        assertEquals(0f, toZero.tint)

        // Guard: no-recipe HSL / vibrance 100 onto a strength-2.0 v4 target stores 50 (not 100).
        val target2x = EditSettings(recipeID = "r", strength = 2.0f, masterRecipeSettingsVersion = 4)
        val fromNoRecipeClamp = prepare(
            payload(
                F.HSL_HUE_RED to AdjustmentValue.Number(100.0),
                F.VIBRANCE to AdjustmentValue.Number(100.0),
            ),
            target2x,
            ctx,
        )
        assertEquals(50.0f, fromNoRecipeClamp.hsl.value(0, 0))
        assertEquals(50.0f, fromNoRecipeClamp.vibrance)

        // Guard: no-recipe tint 150 onto a recipe target with cameraTint 60 stores 90 (not 150).
        val target1x = EditSettings(recipeID = "r", strength = 1.0f, masterRecipeSettingsVersion = 4)
        val tintClamped = prepare(
            payload(
                F.WHITE_BALANCE_MODE to AdjustmentValue.Text("temperature"),
                F.TEMPERATURE to AdjustmentValue.Number(5200.0),
                F.TINT to AdjustmentValue.Number(150.0),
            ),
            target1x,
            ctx,
        )
        assertEquals(90.0f, tintClamped.tint)

        // Guard: same recipe & strength with a clamped source value (HSL = -100 at 1.3) stores -76.92308f.
        val target13 = EditSettings(recipeID = "r", strength = 1.3f, masterRecipeSettingsVersion = 4)
        val sameStrengthClamped = prepare(
            payload(F.HSL_HUE_RED to AdjustmentValue.Number(-100.0), recipe = AdjustmentRecipeContext("r", 1.3, 4)),
            target13,
            ctx,
        )
        assertEquals(-76.92308f, sameStrengthClamped.hsl.value(0, 0))
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

        val rasterCtx = context.copy(isRaw = false, cameraTemperature = null, cameraTint = null)
        val rasterSource = EditSettings(customWb = false, temperature = 5800f, tint = 12f)
        val rasterPayload = AdjustmentTransfer.capture(AdjustmentScope.Custom(F.WHITE_BALANCE), rasterSource, rasterCtx)
        val rasterTarget = prepare(rasterPayload, EditSettings(), rasterCtx)
        assertFalse(rasterTarget.customWb)
        assertEquals(5800f, rasterTarget.temperature)
        assertEquals(12f, rasterTarget.tint)
    }

    @Test fun strengthOnlyPastePreservesCameraWhiteBalanceWithRecipeTint() {
        val wbContext = context.copy(cameraTemperature = 5200f, cameraTint = 8f)
        val target = EditSettings(
            recipeID = "r",
            strength = 0.5f,
            customWb = false,
            temperature = 6500f,
            tint = 10f,
        )
        val beforeRender = requireNotNull(target.resetRenderValues(PhotoInputKind.RAW, 5200f, 8f))
        val pasted = prepare(payload(F.STRENGTH to AdjustmentValue.Number(1.0)), target, wbContext)
        val afterRender = requireNotNull(pasted.resetRenderValues(PhotoInputKind.RAW, 5200f, 8f))

        assertFalse(pasted.customWb)
        assertEquals(6500f, pasted.temperature)
        assertEquals(5.0f, pasted.tint)
        assertEquals(1f, afterRender.core[8])
        assertEquals(5200f, afterRender.core[9])
        assertEquals(13f, afterRender.core[10])
        assertEquals(beforeRender.core[8], afterRender.core[8])
        assertEquals(beforeRender.core[9], afterRender.core[9])
        assertEquals(beforeRender.core[10], afterRender.core[10])

        val values = AdjustmentTransferValues.values(pasted, wbContext)
        assertEquals(AdjustmentValue.Text("camera"), values[F.WHITE_BALANCE_MODE])
        assertEquals(AdjustmentValue.Null, values[F.TEMPERATURE])
        assertEquals(AdjustmentValue.Number(5.0), values[F.TINT])

        // Round-tripping strength back to 0.5 restores the exact original settings.
        val roundTripped = prepare(payload(F.STRENGTH to AdjustmentValue.Number(0.5)), pasted, wbContext)
        assertEquals(target, roundTripped)

        // Explicit fixed temperature matching camera temperature stays fixed.
        val fixedTarget = target.copy(customWb = true, temperature = 5200f)
        val fixedPasted = prepare(payload(F.STRENGTH to AdjustmentValue.Number(1.0)), fixedTarget, wbContext)
        assertTrue(fixedPasted.customWb)
        assertEquals(5200f, fixedPasted.temperature)
        assertEquals(5.0f, fixedPasted.tint)

        // Removing the recipe via neutral look still converts recipe tint to fixed temperature WB.
        val detached = prepare(
            payload(F.LOOK to AdjustmentValue.Object(mapOf("kind" to AdjustmentValue.Text("neutral"), "id" to AdjustmentValue.Null))),
            target,
            wbContext,
        )
        assertTrue(detached.customWb)
        assertEquals(5200f, detached.temperature)
        assertEquals(13f, detached.tint)
    }

    @Test fun nullLegacyDenoiseMapsToTheExistingDisabledPathButUnsupportedRequestsNotify() {
        val original = EditSettings(denoise = DenoiseSettings(true, 10f, 72f, 100f), displayChromaDenoise = 2)
        val result = prepare(payload(F.WAVELET_DENOISE to AdjustmentValue.Null), original)
        assertEquals(DenoiseSettings(), result.denoise); assertEquals(2, result.displayChromaDenoise)
        assertEquals(0, prepare(payload(F.CHROMA_DENOISE to AdjustmentValue.Null), original).displayChromaDenoise)
        // Q3：非 0 的旧降噪键忽略并保持目标原值，同时给一次性提示。
        val rawNotices = mutableListOf<AdjustmentTransferNotice>()
        assertEquals(original, prepare(payload(F.RAW_DENOISE to AdjustmentValue.Number(1.0)), original,
            context.copy(onTransferNotice = { rawNotices.add(it) })))
        assertTrue(rawNotices.contains(AdjustmentTransferNotice.IGNORED_RAW_DENOISE))
        val postNotices = mutableListOf<AdjustmentTransferNotice>()
        assertEquals(EditSettings(), prepare(payload(F.POST_RGB_DENOISE to AdjustmentValue.Number(.2)),
            context = context.copy(onTransferNotice = { postNotices.add(it) })))
        assertTrue(postNotices.contains(AdjustmentTransferNotice.IGNORED_POST_RGB_DENOISE))
        val silent = mutableListOf<AdjustmentTransferNotice>()
        assertEquals(EditSettings(), prepare(payload(F.POST_RGB_DENOISE to AdjustmentValue.Number(0.0)),
            EditSettings(), context.copy(onTransferNotice = { silent.add(it) })))
        assertTrue(silent.none { it.fieldId != null })
    }

    @Test fun effectiveNoticesExcludeSkippedAndFailedTargets() {
        // Q3/S1：提示只随实际应用或确认无关改动的目标产生。
        fun target(id: String, notices: List<AdjustmentTransferNotice>, error: Throwable? = null) =
            PreparedAdjustmentTransfer.Target(id, id, null, null, false, { true }, null, error = error, notices = notices)
        val targets = listOf(
            target("applied", listOf(AdjustmentTransferNotice.IGNORED_RAW_DENOISE)),
            target("skipped", listOf(AdjustmentTransferNotice.IGNORED_POST_RGB_DENOISE)),
            target("failed", listOf(AdjustmentTransferNotice.RETAINED_TARGET_PROCESSING_VERSION)),
            target("errored", listOf(AdjustmentTransferNotice.IGNORED_RAW_DENOISE), error = AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE)))
        val outcomes = listOf(AdjustmentOutcome("applied", AdjustmentStatus.APPLIED),
            AdjustmentOutcome("skipped", AdjustmentStatus.SKIPPED), AdjustmentOutcome("failed", AdjustmentStatus.FAILED))
        assertEquals(listOf(AdjustmentTransferNotice.IGNORED_RAW_DENOISE), effectiveTransferNotices(targets, outcomes))
        assertTrue(effectiveTransferNotices(targets, emptyList()).isEmpty())
    }

    @Test fun processingVersionMismatchReusesTargetVersionAndNotifiesOnce() {
        // Q4：来源与目标处理版本不同不拒绝，沿用目标处理版本并一次性提示。
        val notices = mutableListOf<AdjustmentTransferNotice>()
        val old = AdjustmentPayload(AdjustmentSource("old", true, 1), mapOf(F.EXPOSURE to AdjustmentValue.Number(.42)))
        val applied = prepare(old, context = context.copy(onTransferNotice = { notices.add(it) }))
        assertEquals(.42f, applied.exposure); assertEquals(3, applied.processing.version)
        assertEquals(listOf(AdjustmentTransferNotice.RETAINED_TARGET_PROCESSING_VERSION), notices)
        val silent = mutableListOf<AdjustmentTransferNotice>()
        val current = AdjustmentPayload(AdjustmentSource("same", true, 3), mapOf(F.EXPOSURE to AdjustmentValue.Number(.42)))
        prepare(current, context = context.copy(onTransferNotice = { silent.add(it) }))
        assertTrue(silent.isEmpty())
    }

    @Test fun geometryMergesAtomicallyAndLensRequiresActualTargetValidation() {
        val target = EditSettings(geometry = GeometrySettings(cropX = .6f, cropWidth = .4f))
        assertThrows(AdjustmentTransferException::class.java) { prepare(payload(F.CROP_WIDTH to AdjustmentValue.Number(.8)), target) }
        val merged = prepare(payload(F.CROP_X to AdjustmentValue.Number(.1), F.CROP_WIDTH to AdjustmentValue.Number(.8)), target)
        assertEquals(.1f, merged.geometry.cropX); assertEquals(.8f, merged.geometry.cropWidth)
        for (request in listOf(payload(F.LENS_PROFILE to AdjustmentValue.Text("fixture-profile")),
            payload(F.LENS_AUTO_CROP to AdjustmentValue.Boolean(false)))) {
            prepare(request, context = context.copy(isRaw = false))
        }
        val lens = payload(F.LENS_DISTORTION to AdjustmentValue.Boolean(true))
        assertThrows(AdjustmentTransferException::class.java) { prepare(lens) }
        var validated = false
        val accepted = prepare(lens, context = context.copy(validateLens = { validated = it.distortion }))
        assertTrue(validated); assertTrue(accepted.lens.distortion)
        assertThrows(AdjustmentTransferException::class.java) { prepare(lens, context = context.copy(isRaw = false)) }
        validated = false
        val raster = prepare(lens, context = context.copy(isRaw = false, validateLens = { validated = it.distortion }))
        assertTrue(validated); assertTrue(raster.lens.distortion)
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
        for (endpoint in listOf(-5.0, 5.0)) {
            assertEquals(endpoint.toFloat(), prepare(payload(F.EXPOSURE to AdjustmentValue.Number(endpoint))).exposure)
        }
        assertThrows(AdjustmentTransferException::class.java) { prepare(payload(F.EXPOSURE to AdjustmentValue.Number(5.01))) }
        val raster = EditSettings(exposureMode = 2)
        assertEquals(raster, prepare(payload(F.EXPOSURE_MODE to AdjustmentValue.Text("preview")), raster, context.copy(isRaw = false)))
        assertThrows(AdjustmentTransferException::class.java) {
            prepare(payload(F.LOOK to AdjustmentValue.Object(mapOf("kind" to AdjustmentValue.Text("managed"), "id" to AdjustmentValue.Text("missing")))))
        }
    }

    @Test fun sharedEffectiveVectorsApplyWithTargetNativePrecision() {
        val vectors = JSONObject(resolveSharedFixture("adjustment-transfer-v1.json").readText()).getJSONArray("vectors")
        assertTrue(vectors.length() > 0)
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

    private data class ScenarioDiff(val key: String, val summary: String)
    private data class ScenarioDivergence(val ledgerId: String, val reason: String, val expectedKeys: Set<String>)

    // 显式例外清单：未登记的分歧（或同一场景出现清单外的字段差异）必红；已修复项仍留在此表也必红（棘轮只减不增）。
    private val knownScenarioDivergences = emptyMap<String, ScenarioDivergence>()

    private fun scenarioFixtureAllFieldIDs(): Set<String> {
        val scenarios = JSONObject(resolveSharedFixture("adjustment-transfer-scenarios-v1.json").readText())
            .getJSONArray("scenarios")
        for (index in 0 until scenarios.length()) {
            val scenario = scenarios.getJSONObject(index)
            if (scenario.getString("id") == "raster-all-preserves-raw-scene-wb-lens") {
                return scenario.getJSONObject("payload").getJSONObject("values").keys().asSequence().toSet()
            }
        }
        error("Missing baseline all-scope scenario in adjustment-transfer-scenarios-v1.json")
    }

    @Test fun sharedScenarioFixtures() = runScenarioFixture("adjustment-transfer-scenarios-v1.json")

    @Test fun decimalVectorFixtures() {
        runScenarioFixture("adjustment-transfer-decimals-v1.json", checkKnownDivergences = false)
        val root = JSONObject(resolveSharedFixture("adjustment-transfer-decimals-v1.json").readText())
        val rejectedPayloads = root.getJSONArray("rejected_payloads")
        assertTrue("Decimal rejected payloads must not be empty", rejectedPayloads.length() > 0)
        for (index in 0 until rejectedPayloads.length()) {
            val item = rejectedPayloads.getJSONObject(index)
            val id = item.getString("id")
            val reason = item.getString("reason")
            val payloadJson = item.getJSONObject("payload").toString()
            val error = assertThrows(AdjustmentTransferException::class.java) { AdjustmentPayload.decode(payloadJson) }
            assertEquals("Decimal rejected payload $id: expected $reason", reason, errorReason(error))
        }
    }

    private fun runScenarioFixture(fixtureName: String, checkKnownDivergences: Boolean = true) {
        val root = JSONObject(resolveSharedFixture(fixtureName).readText())
        assertEquals("Scenario fixture version is 1", 1, root.getInt("fixture_version"))
        val scenarios = root.getJSONArray("scenarios")
        assertTrue("Scenario fixture must not be empty", scenarios.length() > 0)
        val recipes = builtinRecipes()
        val recipeTints = recipes.associate { it.id to it.tint }
        val seenIDs = linkedSetOf<String>()
        val evaluatedIDs = linkedSetOf<String>()
        val skippedIDs = linkedSetOf<String>()
        val problems = mutableListOf<String>()

        for (index in 0 until scenarios.length()) {
            val scenario = scenarios.getJSONObject(index)
            val id = scenario.getString("id")
            assertTrue("Unique scenario ID: $id", seenIDs.add(id))
            if (scenario.has("platforms")) {
                val platforms = scenario.getJSONArray("platforms")
                val names = (0 until platforms.length()).map { platforms.getString(it) }.toSet()
                if ("android" !in names) {
                    skippedIDs.add(id)
                    continue
                }
            }
            evaluatedIDs.add(id)
            val diffs = evaluateScenario(id, scenario, recipeTints)
            val actualKeys = diffs.map { it.key }.toSet()
            val summary = diffs.joinToString("; ") { it.summary }
            val known = if (checkKnownDivergences) knownScenarioDivergences[id] else null
            when {
                diffs.isNotEmpty() && known == null ->
                    problems.add("Scenario $id diverged: $summary")
                diffs.isEmpty() && known != null ->
                    problems.add("Scenario $id now matches fixture; remove stale divergence (${known.ledgerId}: ${known.reason})")
                known != null && actualKeys != known.expectedKeys ->
                    problems.add("Scenario $id divergence keys changed (expected=${known.expectedKeys}, actual=$actualKeys): $summary")
                known != null ->
                    println("KNOWN DIVERGENCE [$id] (${known.ledgerId} - ${known.reason}): $summary")
            }
        }

        assertEquals(scenarios.length(), seenIDs.size)
        assertEquals(scenarios.length(), evaluatedIDs.size + skippedIDs.size)
        if (checkKnownDivergences) {
            val unknownRegistered = knownScenarioDivergences.keys - evaluatedIDs
            assertTrue("Registered divergences do not match evaluated scenarios: $unknownRegistered", unknownRegistered.isEmpty())
        }
        if (problems.isNotEmpty()) fail(problems.joinToString("\n"))
    }

    private fun evaluateScenario(id: String, scenario: JSONObject, recipeTints: Map<String, Float>): List<ScenarioDiff> {
        val targetSpec = scenario.getJSONObject("target")
        val kind = targetSpec.getString("kind")
        val asShot = targetSpec.optJSONArray("as_shot_wb")?.let {
            it.getDouble(0).toFloat() to it.getDouble(1).toFloat()
        }
        val lensValid = targetSpec.getBoolean("lens_valid")
        val looksArray = targetSpec.getJSONArray("available_looks")
        val availableLooks = (0 until looksArray.length()).map { looksArray.getString(it) }.toSet()
        val builtins = buildMap {
            for (look in availableLooks) if (look.startsWith("builtin:")) {
                val file = look.removePrefix("builtin:")
                put(file, file.substringBeforeLast('.'))
            }
        }
        val initialSettings = when (kind) {
            "sdr_raw" -> EditSettings()
            "sdr_raster" -> EditSettings(exposureMode = 2)
            "hdr" -> EditSettings().withHDRMode(true, true)
            else -> error("Scenario $id: unsupported target kind $kind")
        }
        val scenarioContext = AdjustmentTransferContext(
            identifier = "scenario-target",
            isRaw = kind == "sdr_raw",
            availableLookIDs = availableLooks,
            builtinLookIDs = builtins,
            cameraTemperature = if (kind == "sdr_raw") asShot?.first else null,
            cameraTint = if (kind == "sdr_raw") asShot?.second else null,
            defaultExposureMode = if (kind == "sdr_raw") 1 else 2,
            validateLens = if (lensValid) ({ }) else null,
            recipeTintDefaults = recipeTints,
        )
        var targetState = initialSettings
        if (targetSpec.has("seed_payload") && !targetSpec.isNull("seed_payload")) {
            val seedPayload = AdjustmentPayload.decode(targetSpec.getJSONObject("seed_payload").toString())
            assertEquals("Scenario $id: seed payload round-trip", seedPayload, AdjustmentPayload.decode(seedPayload.encode()))
            targetState = AdjustmentTransfer.prepare(seedPayload, targetState, scenarioContext.copy(validateLens = {}))
        }

        val payload = AdjustmentPayload.decode(scenario.getJSONObject("payload").toString())
        assertEquals("Scenario $id: payload round-trip", payload, AdjustmentPayload.decode(payload.encode()))
        // S3：收集 prepare 期间的忽略/版本提示，与 fixture 声明按集合比较。
        val notices = mutableListOf<AdjustmentTransferNotice>()
        val expectSpec = scenario.optJSONObject("platform_expect")?.optJSONObject("android")
            ?: scenario.getJSONObject("expect")
        val expectedStatus = expectSpec.getString("status")
        val diffs = mutableListOf<ScenarioDiff>()
        if (expectedStatus == "rejected") {
            val expectedReason = expectSpec.optString("reason").takeIf { expectSpec.has("reason") && !expectSpec.isNull("reason") }
            try {
                val candidate = AdjustmentTransfer.prepare(payload, targetState, scenarioContext)
                val actualStatus = if (candidate == targetState) "unchanged" else "applied"
                diffs.add(ScenarioDiff("status", "status expected=rejected(${expectedReason ?: "any"}), actual=$actualStatus"))
            } catch (error: AdjustmentTransferException) {
                val actualReason = errorReason(error)
                if (expectedReason != null && actualReason != expectedReason) {
                    diffs.add(ScenarioDiff("rejected_reason", "rejected reason expected=$expectedReason, actual=$actualReason (${error.message})"))
                }
            }
            return diffs
        }

        val isUnchangedWithoutValues = expectedStatus == "unchanged" && (!expectSpec.has("values") || expectSpec.isNull("values"))
        val candidate = try {
            AdjustmentTransfer.prepare(payload, targetState, scenarioContext.copy(onTransferNotice = { notices.add(it) }))
        } catch (error: AdjustmentTransferException) {
            val statusKey = if (isUnchangedWithoutValues) "status:rejected:${errorReason(error)}" else "status"
            diffs.add(ScenarioDiff(statusKey, "status expected=$expectedStatus, actual=rejected(${errorReason(error)}: ${error.message})"))
            return diffs
        }
        val actualStatus = if (candidate == targetState) "unchanged" else "applied"
        if (actualStatus != expectedStatus) {
            val statusKey = if (isUnchangedWithoutValues) "status:$actualStatus" else "status"
            diffs.add(ScenarioDiff(statusKey, "status expected=$expectedStatus, actual=$actualStatus"))
        }
        val expectNotices = sequenceOf(expectSpec, scenario.getJSONObject("expect")).mapNotNull { base ->
            base.optJSONObject("notices_by_platform")?.optJSONArray("android")?.let { arr -> (0 until arr.length()).map { arr.getString(it) } }
                ?: base.optJSONArray("notices")?.let { arr -> (0 until arr.length()).map { arr.getString(it) } }
        }.firstOrNull()
        if (expectNotices != null) {
            val actualNotices = notices.map { it.fixtureId }.toSet()
            if (actualNotices != expectNotices.toSet())
                diffs.add(ScenarioDiff("notices", "notices expected=${expectNotices.sorted()}, actual=${actualNotices.sorted()}"))
        }
        if (isUnchangedWithoutValues && actualStatus == "applied") {
            val targetCaptured = AdjustmentTransfer.capture(AdjustmentScope.All, targetState, scenarioContext).values
            val candidateCaptured = AdjustmentTransfer.capture(AdjustmentScope.All, candidate, scenarioContext).values
            val allFields = (targetCaptured.keys + candidateCaptured.keys).sortedBy { it.id }
            for (field in allFields) {
                val before = targetCaptured[field]
                val after = candidateCaptured[field]
                val matches = when {
                    before == null && after == null -> true
                    before == null || after == null -> false
                    else -> matchesValue(after, before)
                }
                if (!matches) {
                    diffs.add(ScenarioDiff("changed:${field.id}", "changed ${field.id} before=${formatValue(before)}, after=${formatValue(after)}"))
                }
            }
        }
        if (expectSpec.has("values") && !expectSpec.isNull("values")) {
            val valuesObj = expectSpec.getJSONObject("values")
            val captured = AdjustmentTransfer.capture(AdjustmentScope.All, candidate, scenarioContext).values
            for (key in valuesObj.keys().asSequence().sorted()) {
                val field = requireNotNull(F.fromID(key)) { "Scenario $id: unknown field $key" }
                val expected = decodeExpectedValue(valuesObj.get(key))
                val actual = captured[field]
                if (!matchesValue(actual, expected)) {
                    diffs.add(ScenarioDiff("value:$key", "value $key expected=${formatValue(expected)}, actual=${formatValue(actual)}"))
                }
            }
        }
        if (expectSpec.has("effective") && !expectSpec.isNull("effective")) {
            val effectiveObj = expectSpec.getJSONObject("effective")
            val actualEffective = AdjustmentTransfer.effectiveNumbers(candidate)
            for (key in effectiveObj.keys().asSequence().sorted()) {
                val field = requireNotNull(F.fromID(key)) { "Scenario $id: unknown effective field $key" }
                val expected = effectiveObj.getDouble(key)
                val actual = actualEffective[field]?.toDouble()
                if (actual == null || kotlin.math.abs(actual - expected) > 1e-6) {
                    diffs.add(ScenarioDiff("effective:$key", "effective $key expected=$expected, actual=$actual"))
                }
            }
        }
        return diffs
    }

    private fun errorReason(error: AdjustmentTransferException): String = when (error.reason) {
        AdjustmentFailure.INVALID_PAYLOAD -> "invalid_payload"
        AdjustmentFailure.INCOMPATIBLE -> "incompatible"
        AdjustmentFailure.UNREPRESENTABLE -> "unrepresentable"
        AdjustmentFailure.MISSING_LOOK -> "missing_look"
        else -> "other(${error.reason})"
    }

    private fun decodeExpectedValue(raw: Any?): V = when (raw) {
        null, JSONObject.NULL -> AdjustmentValue.Null
        is Boolean -> AdjustmentValue.Boolean(raw)
        is Number -> AdjustmentValue.Number(raw.toDouble())
        is String -> AdjustmentValue.Text(raw)
        is JSONObject -> AdjustmentValue.Object(raw.keys().asSequence().associateWith { decodeExpectedValue(raw.get(it)) })
        is JSONArray -> AdjustmentValue.Array((0 until raw.length()).map { decodeExpectedValue(raw.get(it)) })
        else -> error("Unsupported fixture JSON value: $raw")
    }

    private fun matchesValue(actual: V?, expected: V, tolerance: Double = 1e-6): Boolean = when {
        actual == null -> false
        actual is AdjustmentValue.Null && expected is AdjustmentValue.Null -> true
        actual is AdjustmentValue.Boolean && expected is AdjustmentValue.Boolean -> actual.value == expected.value
        actual is AdjustmentValue.Text && expected is AdjustmentValue.Text -> actual.value == expected.value
        actual is AdjustmentValue.Number && expected is AdjustmentValue.Number -> kotlin.math.abs(actual.value - expected.value) <= tolerance
        actual is AdjustmentValue.Array && expected is AdjustmentValue.Array ->
            actual.value.size == expected.value.size &&
                actual.value.zip(expected.value).all { (a, b) -> matchesValue(a, b, tolerance) }
        actual is AdjustmentValue.Object && expected is AdjustmentValue.Object ->
            actual.value.keys == expected.value.keys &&
                expected.value.all { (k, v) -> matchesValue(actual.value[k], v, tolerance) }
        else -> false
    }

    private fun formatValue(value: V?): String = when (value) {
        null -> "<missing>"
        AdjustmentValue.Null -> "null"
        is AdjustmentValue.Boolean -> value.value.toString()
        is AdjustmentValue.Number -> value.value.toString()
        is AdjustmentValue.Text -> "\"${value.value}\""
        is AdjustmentValue.Array -> value.value.joinToString(", ", "[", "]") { formatValue(it) }
        is AdjustmentValue.Object -> value.value.entries.sortedBy { it.key }.joinToString(", ", "{", "}") { "${it.key}:${formatValue(it.value)}" }
    }
}
