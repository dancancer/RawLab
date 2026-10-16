package com.rawlab.android

import android.content.res.Configuration
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.semantics.SemanticsActions
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.Locale
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class EditorV08ControlsTest {
    @get:Rule val compose = createComposeRule()

    @Test fun signActionKeepsNegativeDraftLocalUntilApplied() {
        var value by mutableFloatStateOf(.35f)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        compose.setContent { RawLabTheme { NumericControl(R.string.exposure, value, -4f..4f, "EV", true,
            { next, _ -> value = next }, { value = 0f }) } }
        compose.onNodeWithText("+0.35 EV").performClick()
        compose.onNodeWithContentDescription(context.getString(R.string.adjustment_toggle_sign)).performClick()
        compose.onNodeWithTag("adjustment-input").assertTextContains("-0.35")
        compose.runOnIdle { assertEquals(.35f, value, 0f) }
        compose.onNodeWithTag("adjustment-input-apply").performClick()
        compose.runOnIdle { assertEquals(-.35f, value, .00001f) }
    }

    @Test fun bundledFilmLabelsDecodeOnAndroid() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val films = Film.all + BundledLooks.load(context)
        assertEquals(40, films.size)
        films.filter { it.file != null }.forEach { film ->
            context.assets.open("films/${film.fileName}").close()
            context.assets.open("artwork/${film.artworkName}.png").use { input ->
                assertNotNull(film.id, android.graphics.BitmapFactory.decodeStream(input, null,
                    android.graphics.BitmapFactory.Options().apply { inSampleSize = 4 }))
            }
        }
    }

    @Test fun invalidExactDraftDoesNotChangeValueAndCancelDiscardsIt() {
        var value by mutableFloatStateOf(.35f)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        compose.setContent { RawLabTheme { NumericControl(R.string.exposure, value, -4f..4f, "EV", true,
            { next, _ -> value = next }, { value = 0f }) } }
        compose.onNodeWithText("+0.35 EV").performClick()
        compose.onNodeWithTag("adjustment-input").performTextReplacement("NaN")
        compose.onNodeWithTag("adjustment-input-apply").assertIsNotEnabled()
        compose.runOnIdle { assertEquals(.35f, value, 0f) }
        compose.onNodeWithTag("adjustment-input").performTextReplacement("0.76")
        compose.onNodeWithText(context.getString(R.string.cancel)).performClick()
        compose.runOnIdle { assertEquals(.35f, value, 0f) }
        compose.onNodeWithText("+0.35 EV").performClick()
        compose.onNodeWithTag("adjustment-input").assertTextContains("+0.35")
        compose.onNodeWithTag("adjustment-input").performTextReplacement("0.76")
        compose.onNodeWithTag("adjustment-input-apply").performClick()
        compose.runOnIdle { assertEquals(.75f, value, .00001f) }
    }

    @Test fun formatRowsWrapAtNarrowWidthInSixLanguagesAndLargeFont() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var language by mutableStateOf("en")
        var selected by mutableStateOf(ExportFormat.JPEG)
        compose.setContent {
            val config = Configuration(context.resources.configuration).apply { setLocale(Locale.forLanguageTag(language)) }
            val density = LocalDensity.current
            CompositionLocalProvider(LocalContext provides context.createConfigurationContext(config),
                LocalDensity provides Density(density.density, 1.6f)) {
                RawLabTheme { Column(Modifier.width(280.dp).verticalScroll(rememberScrollState())) {
                    ExportFormatControls(selected, { selected = it })
                } }
            }
        }
        listOf("en", "zh-Hans", "de", "fr", "ja", "es").forEach { locale ->
            compose.runOnIdle { language = locale }
            compose.onNodeWithTag("export-format-DNG").performScrollTo().performClick().assertIsSelected()
            val localized = context.createConfigurationContext(Configuration(context.resources.configuration).apply {
                setLocale(Locale.forLanguageTag(locale))
            })
            val exports = mapOf("en" to "Export", "zh-Hans" to "导出", "de" to "Exportieren", "fr" to "Exporter", "ja" to "書き出し", "es" to "Exportar")
            assertEquals("The resource locale must really change: requested=$locale actual=${localized.resources.configuration.locales.toLanguageTags()} app=${AppStrings.preference(context)} base=${context.resources.configuration.locales.toLanguageTags()}",
                exports.getValue(locale), localized.getString(R.string.export))
            compose.onNodeWithText(localized.getString(R.string.dng)).assertIsDisplayed()
            val textLayouts = mutableListOf<TextLayoutResult>()
            compose.onNodeWithText(localized.getString(R.string.dng_description), useUnmergedTree = true).performSemanticsAction(SemanticsActions.GetTextLayoutResult) {
                it(textLayouts)
            }
            assertTrue("$locale text must wrap without clipping: ${textLayouts.map { "${it.size}/${it.lineCount}/${it.hasVisualOverflow}" }}",
                textLayouts.isNotEmpty() && textLayouts.none { it.hasVisualOverflow })
            val jpeg = compose.onNodeWithTag("export-format-JPEG").fetchSemanticsNode().boundsInRoot
            val png = compose.onNodeWithTag("export-format-PNG").fetchSemanticsNode().boundsInRoot
            val dng = compose.onNodeWithTag("export-format-DNG").fetchSemanticsNode().boundsInRoot
            assertEquals(jpeg.width, dng.width, 1f)
            assertTrue("$locale rows must not overlap", jpeg.bottom <= png.top && png.bottom <= dng.top)
            compose.runOnIdle { assertEquals(ExportFormat.DNG, selected) }
        }
    }
}

class EditorV08DraftTest {
    val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rule = org.junit.rules.RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test fun nativeLayoutKeepsPhotoAndControlsSeparateAndExposesDraftActions() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val source = File(context.cacheDir, "v08-layout-${System.nanoTime()}.ARW")
        instrumentation.context.assets.open("sample.RAW").use { input -> source.outputStream().use { input.copyTo(it) } }
        val model = compose.activity.model
        fun ready() = compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
        fun capture(name: String) {
            val dir = File(context.getExternalFilesDir(null), "v08-layout").apply { mkdirs() }
            compose.waitForIdle()
            val bitmap = instrumentation.uiAutomation.takeScreenshot()
            File(dir, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        try {
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            ready()
            assertNull(model.state.value.error)
            compose.waitUntil(10_000) { compose.onAllNodesWithTag("film-artwork-provia", useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty() }
            capture("film")
            compose.onNodeWithTag("editor-tools").performScrollToNode(hasTestTag("editor-tool-2"))
            compose.onNodeWithTag("editor-tool-2").performClick()
            val photo = compose.onNodeWithTag("photo-canvas").fetchSemanticsNode().boundsInRoot
            val ruler = compose.onNodeWithTag("adjustment-slider").fetchSemanticsNode().boundsInRoot
            val configuration = compose.activity.resources.configuration
            if (configuration.screenWidthDp <= configuration.screenHeightDp) assertTrue(photo.bottom <= ruler.top)
            else assertTrue(photo.right <= ruler.left)
            capture("exposure")
            compose.onNodeWithContentDescription("全部工具").performClick()
            compose.onNodeWithTag("editor-tool-17").performScrollTo().performClick()
            compose.waitUntil(30_000) { model.state.value.draft != null && model.state.value.canApplyDraft }
            compose.onNodeWithTag("editor-tool-17").assertIsDisplayed()
            compose.onNodeWithTag("draft.cancel").assertIsDisplayed()
            compose.onNodeWithTag("draft.apply").assertIsDisplayed()
            compose.onNodeWithTag("geometry.rotate-right").performScrollTo().performClick()
            compose.waitUntil(180_000) { model.state.value.canApplyDraft }
            capture("geometry")
            compose.onNodeWithTag("draft.cancel").performClick()
            ready()
            compose.onNodeWithContentDescription("导出").performClick()
            compose.onNodeWithTag("export-format-DNG").performScrollTo().performClick()
            compose.onNodeWithText("保存到相册").assertDoesNotExist()
            capture("dng")
        } finally { source.delete() }
    }

    @Test fun geometryAndLensDraftsDoNotSaveUntilAppliedAndSurviveRecreation() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val source = File(context.cacheDir, "v08-${System.nanoTime()}.ARW")
        instrumentation.context.assets.open("sample.RAW").use { input -> source.outputStream().use { input.copyTo(it) } }
        var model = compose.activity.model
        fun ready() = compose.waitUntil(180_000) { !model.state.value.rendering && model.state.value.exact }
        try {
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            ready()
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(film = "velvia", exposure = .5f)) }
            ready()
            val original = model.state.value.edits
            val photo = requireNotNull(model.state.value.photo)
            fun stored() = EditStore(File(context.filesDir, "edits")).load(photo.identity)
            compose.runOnUiThread {
                model.beginDraft(AdjustmentGroup.GEOMETRY)
                model.changeDraft(original.copy(geometry = GeometrySettings(cropWidth = .75f)))
            }
            assertEquals(original, stored())
            assertEquals(original, model.state.value.edits)
            assertEquals(.75f, model.state.value.visibleEdits.geometry.cropWidth, 0f)
            compose.runOnUiThread {
                assertFalse(model.beginExport())
                model.beginBatch()
                model.importLooks(listOf(Uri.parse("file:///missing.cube")))
                model.renameLook("missing", "Renamed")
                model.deleteLook("missing")
                assertEquals(Operation.NONE, model.state.value.operation)
                model.resumeBatch(BatchJob(BatchSourceSnapshot(photo.identity, photo.file, original), emptyList()))
            }
            assertNull(model.batch.value)
            compose.activityRule.scenario.recreate()
            compose.activityRule.scenario.onActivity { model = it.model }
            assertEquals(.75f, model.state.value.draft!!.value.geometry.cropWidth, 0f)
            compose.runOnUiThread { model.changeDraft(model.state.value.visibleEdits.copy(geometry = GeometrySettings(quarterTurns = 1)), true) }
            compose.runOnUiThread { model.discardDraft() }
            ready()
            assertEquals(original, model.state.value.edits)
            assertEquals(original, stored())
            compose.runOnUiThread {
                model.beginDraft(AdjustmentGroup.GEOMETRY)
                model.changeDraft(original.copy(geometry = GeometrySettings(cropWidth = .75f)))
                model.applyDraft()
            }
            ready()
            val applied = model.state.value.edits
            assertEquals(.75f, applied.geometry.cropWidth, 0f)
            assertEquals(.5f, applied.exposure, 0f)
            assertEquals(applied, stored())
            compose.runOnUiThread {
                model.beginDraft(AdjustmentGroup.LENS)
                model.changeDraft(applied.copy(lens = LensSettings(autoCrop = false)))
            }
            ready()
            assertEquals(applied, stored())
            compose.runOnUiThread { model.discardDraft() }
            ready()
            assertEquals(applied, model.state.value.edits)
        } finally { source.delete() }
    }
}
