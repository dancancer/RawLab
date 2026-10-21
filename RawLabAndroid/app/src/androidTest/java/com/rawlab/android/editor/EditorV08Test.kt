package com.rawlab.android.editor

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
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.RawLabTheme
import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.BatchSourceSnapshot
import com.rawlab.android.editor.controls.NumericControl
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.looks.BundledLooks
import com.rawlab.android.looks.filmStripItems
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.Film
import com.rawlab.android.settings.LensSettings
import com.rawlab.android.settings.LookChoice
import com.rawlab.android.testing.LanguageTestRule
import com.rawlab.android.ui.ExportFormatControls

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
        val items = filmStripItems(films.map { LookChoice(it.id, it.name, false) }, films)
        assertEquals("neutral", items.first().look.id)
        assertEquals(Film.all.drop(1).map { it.id }, items.drop(1).take(10).map { it.look.id })
        val kodak = items.drop(11).take(24)
        assertTrue(kodak.all { it.look.id.startsWith("RawLab_look_") ||
            it.look.id == "EKTAR_100_Phuket_v2_Strong_FLog2_FGamut_65" })
        assertTrue(items.takeLast(5).all { it.look.id.startsWith("RawLab_camera_") })
        assertEquals(listOf(11, 35), items.indices.filter { items[it].startsGroup })
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

    @Test fun failedDraftSaveKeepsCommittedDraftAndRecordUntilRetry() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val source = File(context.cacheDir, "draft-save-${System.nanoTime()}.RAW")
        val record = File(context.filesDir, "edits/edits.properties")
        val backup = File(context.cacheDir, "draft-record-${System.nanoTime()}.properties")
        val model = compose.activity.model
        fun ready() {
            compose.waitUntil(180_000) { model.state.value.error != null ||
                model.state.value.exact && !model.state.value.rendering }
            assertNull(model.state.value.error)
        }
        instrumentation.context.assets.open("sample.RAW").use { input -> source.outputStream().use { input.copyTo(it) } }
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            ready()
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = .5f)) }
            ready()
            val original = model.state.value.edits
            val identity = model.state.value.photo!!.identity
            val before = record.readBytes()
            compose.runOnUiThread {
                model.beginDraft(AdjustmentGroup.GEOMETRY)
                model.changeDraft(original.copy(geometry = GeometrySettings(cropWidth = .75f)))
            }
            ready()
            val draft = model.state.value.draft
            assertTrue(model.state.value.canApplyDraft)
            assertTrue(record.renameTo(backup))
            assertTrue(record.mkdir())
            File(record, "occupied").writeText("keep")
            compose.runOnUiThread { assertFalse(model.applyDraft()) }
            assertEquals("Failed save must keep committed edits", original, model.state.value.edits)
            assertEquals("Failed save must keep the same draft", draft, model.state.value.draft)
            assertEquals(EditSaveState.FAILED, model.state.value.saveState)
            assertArrayEquals(before, backup.readBytes())
            assertTrue(record.deleteRecursively())
            assertTrue(backup.renameTo(record))
            assertEquals(original, EditStore(record.parentFile!!).load(identity))
            compose.runOnUiThread { model.retrySave() }
            ready()
            assertNull(model.state.value.draft)
            assertEquals(.75f, model.state.value.edits.geometry.cropWidth, 0f)
            assertEquals(model.state.value.edits, EditStore(record.parentFile!!).load(identity))
        } finally {
            if (backup.exists()) { record.deleteRecursively(); backup.renameTo(record) }
            source.delete()
        }
    }

    @Test fun failedApplyAndLeaveKeepsDestinationUntilSaveSucceeds() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val source = File(context.cacheDir, "draft-leave-${System.nanoTime()}.RAW")
        val record = File(context.filesDir, "edits/edits.properties")
        val backup = File(context.cacheDir, "leave-record-${System.nanoTime()}.properties")
        val model = compose.activity.model
        fun ready() {
            compose.waitUntil(180_000) { model.state.value.error != null || model.state.value.canExport }
            assertNull(model.state.value.error)
        }
        instrumentation.context.assets.open("sample.RAW").use { input -> source.outputStream().use { input.copyTo(it) } }
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            ready()
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = .5f)) }
            ready()
            val original = model.state.value.edits
            val identity = model.state.value.photo!!.identity
            compose.onNodeWithContentDescription(context.getString(R.string.all_tools)).performClick()
            compose.onNodeWithTag("editor-tool-17").performScrollTo().performClick()
            compose.waitUntil(180_000) { model.state.value.draftReady }
            compose.onNodeWithTag("draft.apply").assertIsNotEnabled()
            compose.runOnUiThread { model.changeDraft(model.state.value.visibleEdits.copy(geometry = GeometrySettings(cropWidth = .75f))) }
            compose.waitUntil(180_000) { model.state.value.canApplyDraft }
            val draft = model.state.value.draft
            assertTrue(record.renameTo(backup))
            assertTrue(record.mkdir())
            File(record, "occupied").writeText("keep")
            compose.waitForIdle()
            compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
            compose.onNode(hasText(context.getString(R.string.adjustment_apply)) and hasAnyAncestor(isDialog())).performClick()
            assertEquals(original, model.state.value.edits)
            assertEquals(draft, model.state.value.draft)
            compose.onNodeWithText(context.getString(R.string.adjustment_leave)).assertIsDisplayed()
            compose.onNodeWithText(model.state.value.saveError!!).assertIsDisplayed()
            assertTrue(record.deleteRecursively())
            assertTrue(backup.renameTo(record))
            assertEquals(original, EditStore(record.parentFile!!).load(identity))
            compose.onNode(hasText(context.getString(R.string.adjustment_apply)) and hasAnyAncestor(isDialog())).performClick()
            ready()
            compose.onNodeWithText(context.getString(R.string.adjustment_leave)).assertDoesNotExist()
            compose.onNodeWithTag("draft.apply").assertDoesNotExist()
            compose.onNodeWithTag("editor-tool-2").assertIsSelected()
            compose.onNodeWithTag("exposure.auto").performScrollTo().assertIsDisplayed()
            assertNull(model.state.value.draft)
            assertEquals(.75f, model.state.value.edits.geometry.cropWidth, 0f)
            assertEquals(model.state.value.edits, EditStore(record.parentFile!!).load(identity))
            // 成功目的地保持普通工具；不能在 canExport 恢复后重新创建几何草稿。
            compose.waitForIdle()
            assertNull(model.state.value.draft)
        } finally {
            if (backup.exists()) { record.deleteRecursively(); backup.renameTo(record) }
            source.delete()
        }
    }

    @Test fun inPlaceApplyRetryAndDiscardReturnToExposureOnlyAfterSuccess() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val source = File(context.cacheDir, "draft-in-place-${System.nanoTime()}.RAW")
        val record = File(context.filesDir, "edits/edits.properties")
        val backup = File(context.cacheDir, "in-place-record-${System.nanoTime()}.properties")
        val model = compose.activity.model
        fun ready() {
            compose.waitUntil(180_000) { model.state.value.error != null || model.state.value.canExport }
            assertNull(model.state.value.error)
        }
        fun select(id: Int) {
            compose.onNodeWithContentDescription(context.getString(R.string.all_tools)).performClick()
            compose.onNodeWithTag("editor-tool-$id").performScrollTo().performClick()
            compose.waitUntil(180_000) { model.state.value.draftReady }
        }
        instrumentation.context.assets.open("sample.RAW").use { input -> source.outputStream().use { input.copyTo(it) } }
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            ready()
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = .5f)) }
            ready()
            val original = model.state.value.edits
            select(17)
            compose.runOnUiThread { model.changeDraft(model.state.value.visibleEdits.copy(geometry = GeometrySettings(cropWidth = .75f))) }
            compose.waitUntil(180_000) { model.state.value.canApplyDraft }
            assertTrue(record.renameTo(backup))
            assertTrue(record.mkdir())
            File(record, "occupied").writeText("keep")
            compose.onNodeWithTag("draft.apply").performClick()
            assertEquals(original, model.state.value.edits)
            assertNotNull(model.state.value.draft)
            compose.onNodeWithTag("draft.apply").assertIsDisplayed()
            compose.onNodeWithTag("edit-save-retry").assertIsDisplayed()
            compose.onNodeWithTag("exposure.auto").assertDoesNotExist()
            assertTrue(record.deleteRecursively())
            assertTrue(backup.renameTo(record))
            compose.onNodeWithTag("edit-save-retry").performClick()
            ready()
            compose.onNodeWithTag("editor-tool-2").assertIsSelected()
            compose.onNodeWithTag("exposure.auto").performScrollTo().assertIsDisplayed()
            assertNull(model.state.value.draft)
            select(16)
            compose.onNodeWithTag("draft.cancel").performClick()
            ready()
            compose.onNodeWithTag("editor-tool-2").assertIsSelected()
            compose.onNodeWithTag("exposure.auto").performScrollTo().assertIsDisplayed()
            assertNull(model.state.value.draft)
        } finally {
            if (backup.exists()) { record.deleteRecursively(); backup.renameTo(record) }
            source.delete()
        }
    }

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
            compose.waitUntil(30_000) { model.state.value.draftReady }
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
