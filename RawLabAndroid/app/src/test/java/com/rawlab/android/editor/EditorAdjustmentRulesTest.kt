package com.rawlab.android.editor

import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.settings.*
import org.junit.Assert.*
import org.junit.Test

class EditorAdjustmentRulesTest {
    private val rules = EditorAdjustmentRules
    // IDs are read from the packaged catalog instead of maintaining a second recipe list.
    private val recipeId = java.io.File("../../Shared/master-recipes.json").readText()
        .let { Regex("\\\"id\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"").find(it)!!.groupValues[1] }
    private fun context(input: PhotoInputKind = PhotoInputKind.RAW, shot: AsShotWhiteBalance? = null) =
        EditorResetContext(input, EditSettings().effectiveFor(input), shot, setOf(recipeId))
    private fun candidate(scope: EditorResetScope, source: EditSettings, ctx: EditorResetContext = context()) =
        (rules.prepareReset(scope, source, ctx) as EditorResetResult.Ready).candidate

    @Test fun rawCameraWhiteBalanceMetadataDoesNotEnableResetScopes() {
        val ctx = context(shot = AsShotWhiteBalance(5200f, 8f))
        val source = EditSettings()
        for (scope in listOf(EditorResetScope.Tool(8), EditorResetScope.Tool(9),
            EditorResetScope.Group(EditorAdjustmentGroup.COLOR), EditorResetScope.All)) {
            assertFalse(scope.toString(), rules.isModified(scope, source, ctx))
            assertTrue(scope.toString(), rules.prepareReset(scope, source, ctx) is EditorResetResult.NoChange)
        }
        assertEquals(EditSettings(), source)
    }

    @Test fun rawCustomWhiteBalanceModeAndStoredRecipeTintRemainModified() {
        val ctx = context(shot = AsShotWhiteBalance(5200f, 8f))
        val source = EditSettings(customWb = true, temperature = 5200f, tint = 8f)
        for (scope in listOf(EditorResetScope.Tool(8), EditorResetScope.Tool(9),
            EditorResetScope.Group(EditorAdjustmentGroup.COLOR), EditorResetScope.All)) {
            assertTrue(scope.toString(), rules.isModified(scope, source, ctx))
            assertEquals(source.copy(customWb = false), candidate(scope, source, ctx))
        }
        val recipe = EditSettings(recipeID = recipeId, strength = 0f, tint = 18f)
        assertTrue(rules.isModified(EditorResetScope.Tool(8), recipe, ctx))
        assertEquals(recipe.copy(temperature = 5200f, tint = 0f), candidate(EditorResetScope.Tool(8), recipe, ctx))
    }

    @Test fun rasterCameraOnlyDifferencesDoNotEnableAnyResetScope() {
        val ctx = context(PhotoInputKind.RASTER)
        val source = EditSettings(exposureMode = 0, customWb = true, temperature = 4200f, tint = 18f)
        val scopes = listOf(EditorResetScope.Tool(2), EditorResetScope.Tool(8), EditorResetScope.Tool(9),
            EditorResetScope.Group(EditorAdjustmentGroup.LIGHT), EditorResetScope.Group(EditorAdjustmentGroup.COLOR), EditorResetScope.All)
        scopes.forEach { scope ->
            assertFalse(scope.toString(), rules.isModified(scope, source, ctx))
            assertTrue(scope.toString(), rules.prepareReset(scope, source, ctx) is EditorResetResult.NoChange)
        }
        assertEquals(EditSettings(exposureMode = 0, customWb = true, temperature = 4200f, tint = 18f), source)
    }

    @Test fun rasterStillMarksStoredRecipeTintAndDisabledAuxiliaryObjects() {
        val ctx = context(PhotoInputKind.RASTER)
        val recipe = EditSettings(recipeID = recipeId, strength = 0f, tint = 18f)
        for (scope in listOf(EditorResetScope.Tool(8), EditorResetScope.Tool(9), EditorResetScope.Group(EditorAdjustmentGroup.COLOR))) {
            assertTrue(rules.isModified(scope, recipe, ctx))
            assertEquals(0f, candidate(scope, recipe, ctx).tint)
        }
        val source = EditSettings(effects = PhotoEffectsSettings(grainSize = 42f),
            denoise = DenoiseSettings(false, 4f, 5f, 6f), lens = LensSettings(autoCrop = false, manual = true, profileId = "saved"))
        for (group in listOf(EditorAdjustmentGroup.EFFECTS, EditorAdjustmentGroup.DETAIL, EditorAdjustmentGroup.GEOMETRY)) {
            assertTrue(rules.isModified(EditorResetScope.Group(group), source, ctx))
            assertTrue(rules.prepareReset(EditorResetScope.Group(group), source, ctx) is EditorResetResult.Ready)
        }
    }

    @Test fun explicitAsShotOverridesWhiteBalanceDefaultsForWbColorAndAll() {
        val ctx = context(shot = AsShotWhiteBalance(5200f, 8f))
        val source = EditSettings(customWb = true, temperature = 4200f, tint = 18f, exposure = .5f, saturation = .2f)
        val wb = source.copy(customWb = false, temperature = 5200f, tint = 8f)
        assertEquals(wb, candidate(EditorResetScope.Tool(8), source, ctx))
        assertEquals(wb, candidate(EditorResetScope.Tool(9), source, ctx))
        assertEquals(wb.copy(saturation = 0f), candidate(EditorResetScope.Group(EditorAdjustmentGroup.COLOR), source, ctx))
        assertEquals(EditSettings(temperature = 5200f, tint = 8f), candidate(EditorResetScope.All, source, ctx))
        assertFalse(rules.isModified(EditorResetScope.Tool(8), wb, ctx))
        val recipe = source.copy(recipeID = recipeId, strength = 0f)
        assertEquals(recipe.copy(customWb = false, temperature = 5200f, tint = 0f), candidate(EditorResetScope.Tool(8), recipe, ctx))
        assertEquals(EditSettings(temperature = 5200f, tint = 8f), candidate(EditorResetScope.All, recipe, ctx))
    }

    @Test fun missingAsShotPreservesResolvedDefaultsAndDoesNotBlockUnrelatedScopes() {
        val ctx = context().copy(defaults = EditSettings(temperature = 5300f, tint = -6f, exposureMode = 0))
        val source = EditSettings(customWb = true, temperature = 4200f, tint = 18f, exposure = .5f)
        assertEquals(source.copy(customWb = false, temperature = 5300f, tint = -6f), candidate(EditorResetScope.Tool(8), source, ctx))
        assertEquals(ctx.defaults, candidate(EditorResetScope.All, source, ctx))
        assertEquals(source.copy(exposure = 0f, exposureMode = 0), candidate(EditorResetScope.Tool(2), source, ctx))
        val invalid = ctx.copy(asShot = AsShotWhiteBalance(Float.NaN, 8f))
        assertTrue(rules.prepareReset(EditorResetScope.Tool(8), source, invalid) is EditorResetResult.Blocked)
        assertEquals(source.copy(exposure = 0f, exposureMode = 0), candidate(EditorResetScope.Tool(2), source, invalid))
    }

    @Test fun sixGroupsRetainToolIdsAndTintAliasIsNotVisible() {
        assertEquals(listOf("looks", "light", "color", "effects", "detail", "geometry"), EditorAdjustmentGroup.entries.map { it.id })
        val expected = listOf(listOf(0, 15, 1), listOf(2, 3, 4, 5, 6), listOf(8, 7, 14), listOf(12, 13), listOf(11, 10), listOf(17, 16))
        EditorAdjustmentGroup.entries.zip(expected).forEach { (group, tools) ->
            assertEquals(tools, rules.tools(group)); tools.forEach { assertEquals(group, rules.groupFor(it)) }
        }
        assertEquals(EditorAdjustmentGroup.COLOR, rules.groupFor(9))
        assertNull(rules.groupFor(99))
    }

    @Test fun completeDisabledObjectsAndLegacyDenoiseAreResetWithoutTouchingOtherGroups() {
        val source = EditSettings(film = "velvia", exposure = .5f, displayChromaDenoise = 2,
            denoise = DenoiseSettings(false, 4f, 5f, 6f), sharpening = .5f,
            effects = PhotoEffectsSettings(vignetteMidpoint = 25f, grainSize = 41f),
            lens = LensSettings(autoCrop = false, manual = true, profileId = "saved"),
            geometry = GeometrySettings(flipHorizontal = true))
        assertTrue(rules.isModified(EditorResetScope.Group(EditorAdjustmentGroup.EFFECTS), source, context()))
        assertEquals(source.copy(effects = PhotoEffectsSettings()), candidate(EditorResetScope.Group(EditorAdjustmentGroup.EFFECTS), source))
        assertEquals(source.copy(denoise = DenoiseSettings(), sharpening = 0f, displayChromaDenoise = 0), candidate(EditorResetScope.Group(EditorAdjustmentGroup.DETAIL), source))
        assertEquals(source.copy(lens = LensSettings(), geometry = GeometrySettings()), candidate(EditorResetScope.Group(EditorAdjustmentGroup.GEOMETRY), source))
        assertEquals(EditSettings(), candidate(EditorResetScope.All, source))
    }

    @Test fun channelResetPreservesFractionalHslAndOtherFields() {
        val hsl = HslSettings(List(24) { (it + 1) * .5f })
        val source = EditSettings(recipeID = recipeId, strength = 0f, saturation = .2f, hsl = hsl)
        val scope = EditorResetScope.HslChannel(3)
        assertTrue(rules.isModified(scope, source, context()))
        val result = candidate(scope, source)
        assertEquals(source.copy(hsl = HslSettings(List(24) { if (it % 8 == 3) 0f else (it + 1) * .5f })), result)
        assertEquals(source.copy(hsl = HslSettings()), candidate(EditorResetScope.AllHsl, source))
        assertTrue(rules.prepareReset(EditorResetScope.HslChannel(8), source, context()) is EditorResetResult.Blocked)
    }

    @Test fun recipeMaterializationMatchesIndependentJniVectorsAtFourStrengths() {
        val source = EditSettings(recipeID = recipeId, exposure = .75f, highlights = -.25f, shadows = .125f,
            contrast = -.25f, saturation = .125f, toneCurve = .3f, sharpening = .7f,
            hsl = HslSettings(List(24) { if (it == 0) 80f else .5f }), exposureMode = 0)
        val expected = listOf(
            listOf(0f, -0f, 0f, -0f, 0f, 0f, 0f),
            listOf(.375f, -.125f, .0625f, -.125f, .0625f, 40f, .25f),
            listOf(.75f, -.25f, .125f, -.25f, .125f, 80f, .5f),
            listOf(1.5f, -.5f, .25f, -.5f, .25f, 100f, 1f))
        listOf(0f, .5f, 1f, 2f).zip(expected).forEach { (strength, v) ->
            val result = candidate(EditorResetScope.Group(EditorAdjustmentGroup.LOOKS), source.copy(strength = strength))
            assertEquals(EditSettings(exposure = v[0], highlights = v[1], shadows = v[2], contrast = v[3], saturation = v[4],
                toneCurve = .3f, sharpening = .7f, hsl = HslSettings(List(24) { if (it == 0) v[5] else v[6] }), exposureMode = 0), result)
        }
    }

    @Test fun rawRecipeWbUsesNativeHalfAwayRoundingAndRelativeTintClamp() {
        for ((shotTint, expected) in listOf(2.5f to 4f, -2.5f to -2f, 149.5f to 150f, .49999997f to 1f, -.49999997f to 1f)) {
            val source = EditSettings(recipeID = recipeId, strength = .5f, tint = 2f)
            val result = candidate(EditorResetScope.Tool(15), source, context(shot = AsShotWhiteBalance(5000.5f, shotTint)))
            assertTrue(result.customWb); assertEquals(5001f, result.temperature); assertEquals(expected, result.tint)
        }
        val custom = EditSettings(recipeID = recipeId, customWb = true, temperature = 4200f)
        assertTrue(rules.prepareReset(EditorResetScope.Tool(15), custom, context()) is EditorResetResult.Blocked)
        val result = candidate(EditorResetScope.Tool(15), custom, context(shot = AsShotWhiteBalance(5100f, -2.5f)))
        assertEquals(4200f, result.temperature); assertEquals(-3f, result.tint)
    }

    @Test fun unavailableCalibrationOnlyBlocksDependentRawRecipeConversion() {
        val dependent = EditSettings(recipeID = recipeId, tint = 5f)
        assertTrue(rules.prepareReset(EditorResetScope.Tool(15), dependent, context()) is EditorResetResult.Blocked)
        assertTrue(rules.prepareReset(EditorResetScope.Tool(15), dependent, context(shot = AsShotWhiteBalance(Float.NaN, 0f))) is EditorResetResult.Blocked)
        assertEquals(0f, candidate(EditorResetScope.Tool(15), dependent.copy(strength = 0f)).tint)
        assertEquals(dependent.copy(exposure = 0f), candidate(EditorResetScope.Tool(2), dependent.copy(exposure = 1f)))
        assertEquals(dependent.copy(recipeID = null), candidate(EditorResetScope.Tool(15), dependent, context(PhotoInputKind.RASTER)))
    }

    @Test fun outOfRangeOrUnknownRecipeIsBlockedAndLightResetNeverReplaysRecipe() {
        val source = EditSettings(recipeID = recipeId, strength = 2f, exposure = 4f, saturation = .3f)
        assertTrue(rules.prepareReset(EditorResetScope.Tool(15), source, context()) is EditorResetResult.Blocked)
        assertTrue(rules.prepareReset(EditorResetScope.Tool(2), source.copy(recipeID = "missing"), context()) is EditorResetResult.Blocked)
        assertEquals(source.copy(exposure = 0f), candidate(EditorResetScope.Group(EditorAdjustmentGroup.LIGHT), source))
        assertEquals(EditSettings(), candidate(EditorResetScope.All, EditSettings(film = "imported")))
    }

    @Test fun defaultsAreRecipeAwareAndPreparationLeavesTheSourceUnchanged() {
        val ctx = context(shot = AsShotWhiteBalance(5100f, 8f)).copy(defaults = EditSettings(temperature = 5100f, tint = 8f))
        val source = EditSettings(recipeID = recipeId, temperature = 5100f)
        assertFalse(rules.isModified(EditorResetScope.Tool(8), source, ctx))
        assertEquals(ctx.defaults, candidate(EditorResetScope.All, source, ctx))
        val prepared = rules.prepareReset(EditorResetScope.Tool(15), source, ctx) as EditorResetResult.Ready
        assertEquals(EditSettings(recipeID = recipeId, temperature = 5100f), source)
        assertNull(prepared.candidate.recipeID)
        assertTrue(rules.prepareReset(EditorResetScope.Tool(7), EditSettings(), context()) is EditorResetResult.NoChange)
    }

    @Test fun materializationKeepsFloatMultiplicationAndBlocksEachUnrepresentableRange() {
        val source = EditSettings(recipeID = recipeId, strength = .3f, exposure = .7f)
        assertEquals(.21000001f, candidate(EditorResetScope.Tool(15), source).exposure)
        for (invalid in listOf(EditSettings(recipeID = recipeId, strength = 2f, highlights = .75f),
            EditSettings(recipeID = recipeId, strength = 2f, shadows = -.75f),
            EditSettings(recipeID = recipeId, strength = 2f, contrast = .75f),
            EditSettings(recipeID = recipeId, strength = 2f, saturation = -.75f))) {
            assertTrue(rules.prepareReset(EditorResetScope.Tool(15), invalid, context()) is EditorResetResult.Blocked)
        }
    }

    @Test fun legacyCsvLoadsWithoutMigrationAndIndependentCandidateSurvivesEditStore() {
        val directory = java.nio.file.Files.createTempDirectory("editor-reset-csv").toFile()
        try {
            val identity = PhotoIdentity("legacy")
            val encoded = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(identity.value.toByteArray())
            val file = java.io.File(directory, "edits.properties")
            val properties = java.util.Properties().apply {
                setProperty("record.$encoded.values", "1.0,0.5,0.0,0.0,0.0,0.0,0.0,0.0,6500.0,0.0,0.0")
                setProperty("record.$encoded.film", "bmV1dHJhbA")
            }
            file.outputStream().use { properties.store(it, null) }
            val originalBytes = file.readBytes()
            val legacy = EditStore(directory).load(identity)!!
            assertEquals(EditSettings(exposure = .5f, exposureMode = 0), legacy)
            assertArrayEquals(originalBytes, file.readBytes())
            val source = legacy.copy(recipeID = recipeId, strength = .5f, hsl = HslSettings(List(24) { .5f }))
            val independent = candidate(EditorResetScope.Tool(15), source)
            EditStore(directory).save(identity, independent)
            assertEquals(independent, EditStore(directory).load(identity))
            assertEquals(0, independent.exposureMode)
            assertEquals(.25f, independent.hsl.value(0, 0))
        } finally { directory.deleteRecursively() }
    }

    @Test fun historicalRecordsAndCandidatesRoundTripWithoutMigration() {
        val old = SettingsCodec.decode("neutral|1.0|0.5|0.0|0.0|0.0|0.0|0.0|false|6500.0|0.0|0.0")
        assertEquals(0, old.exposureMode)
        val result = candidate(EditorResetScope.Tool(2), old)
        assertEquals(1, result.exposureMode)
        val source = EditSettings(recipeID = recipeId, strength = .5f, hsl = HslSettings(List(24) { .5f }))
        val independent = candidate(EditorResetScope.Tool(15), source)
        assertEquals(.25f, independent.hsl.value(2, 7))
        assertEquals(independent, SettingsCodec.decode(SettingsCodec.encode(independent)))
        assertEquals(old, SettingsCodec.decode(SettingsCodec.encode(old)))
    }
}
