package com.rawlab.android

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasScrollToIndexAction
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.onLast
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.test.platform.app.InstrumentationRegistry
import android.net.Uri
import android.graphics.Bitmap
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class EditorScreenTest {
    val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val languageAndCompose = org.junit.rules.RuleChain.outerRule(LanguageTestRule()).around(compose)
    @Test fun emptyEditorOffersImportButCannotExport() {
        compose.onNodeWithText("选择照片").assertIsDisplayed()
        compose.onNodeWithText("从文件导入").assertIsDisplayed()
        compose.onNodeWithContentDescription("导出").assertIsNotEnabled()
        capture("empty-editor.png")
    }

    @Test fun importedPhotoSurvivesRotationAndFailedImport() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val source = File(instrumentation.targetContext.cacheDir, "editor-test.ARW")
        instrumentation.context.assets.open("sample.RAW").use { from -> source.outputStream().use { from.copyTo(it) } }
        var model = compose.activity.model
        compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
        compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
        assertNull(model.state.value.error)
        assertTrue(model.state.value.canExport)
        compose.onNode(SemanticsMatcher("render timing label") { node ->
            node.config.getOrNull(SemanticsProperties.Text)?.any { Regex("(?:GPU|CPU).*ms").matches(it.text) } == true
        }).assertDoesNotExist()
        val original = model.state.value.photo
        compose.runOnUiThread { model.edit(model.state.value.edits.copy(film = "velvia", exposure = .5f)) }
        compose.activityRule.scenario.recreate()
        compose.activityRule.scenario.onActivity { model = it.model }
        compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
        assertNull(model.state.value.error)
        assertEquals("velvia", model.state.value.edits.film)
        compose.onNodeWithText("强度").performClick()
        compose.onNodeWithTag("adjustment-slider").performSemanticsAction(SemanticsActions.SetProgress) { it(200f) }
        compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
        assertEquals(2f, model.state.value.edits.strength)
        assertNull(model.state.value.error)
        compose.onNodeWithContentDescription("对比").performClick()
        compose.onNodeWithTag("comparison-wipe").assertExists().performSemanticsAction(SemanticsActions.SetProgress) { it(.3f) }
        compose.onNodeWithContentDescription("收起调整").performClick()
        compose.onNodeWithText("色温").assertDoesNotExist()
        compose.onNodeWithTag("adjustment-slider").assertDoesNotExist()
        capture("editor-collapsed.png")
        compose.onNodeWithContentDescription("展开调整").performClick()
        val adjustments = compose.onAllNodes(hasScrollToIndexAction() and
            SemanticsMatcher.keyIsDefined(SemanticsProperties.HorizontalScrollAxisRange)).onLast()
        // 色温与色调自 e2edc19 起同在“白平衡”分组：先选中分组，两条轴各自的滑杆都要可见
        adjustments.performScrollToNode(hasContentDescription("白平衡"))
        compose.onNodeWithContentDescription("白平衡").performClick()
        compose.onNode(hasTestTag("adjustment-slider") and hasContentDescription("色温")).performScrollTo().assertIsDisplayed()
        compose.onNode(hasTestTag("adjustment-slider") and hasContentDescription("色调")).performScrollTo().assertIsDisplayed()
        capture("editor-tint.png")
        adjustments.performScrollToNode(hasText("胶片"))
        compose.onNodeWithText("胶片").performClick()
        compose.waitForIdle()
        capture("editor-comparison.png")
        val empty = File(instrumentation.targetContext.cacheDir, "empty-test.dng").apply { writeBytes(byteArrayOf()) }
        compose.runOnUiThread { model.importPhoto(Uri.fromFile(empty)) }
        compose.waitUntil(10_000) { model.state.value.operation == Operation.NONE }
        assertNotNull(model.state.value.error)
        assertEquals(original, model.state.value.photo)
        assertTrue(model.state.value.canExport)
        val savedEdits = model.state.value.edits
        compose.runOnUiThread { AppStrings.setPreference(compose.activity, "de") }
        if (android.os.Build.VERSION.SDK_INT < 33) compose.activityRule.scenario.recreate()
        compose.waitUntil(10_000) { compose.activity.resources.configuration.locales[0].language == "de" }
        compose.activityRule.scenario.onActivity { model = it.model }
        compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
        assertEquals(savedEdits, model.state.value.edits)
        assertEquals(original, model.state.value.photo)
        assertEquals("de", AppStrings.preference(compose.activity))
        compose.onNodeWithContentDescription("Exportieren").assertIsDisplayed()
        source.delete()
        empty.delete()
    }

    @Test fun sixLocaleSwitchesKeepLensDngBatchSnapshotOnTheCurrentActivity() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val source = File(context.cacheDir, "editor-locale-${System.nanoTime()}.ARW")
        instrumentation.context.assets.open("sample.RAW").use { from -> source.outputStream().use { from.copyTo(it) } }
        var activity = compose.activity
        var model = activity.model
        val expected = EditSettings(
            film = "velvia", strength = 1.35f, exposure = -.75f, highlights = .25f, shadows = -.2f,
            contrast = .4f, toneCurve = -.15f, saturation = .3f, customWb = true, temperature = 4200f,
            tint = 12f, denoise = DenoiseSettings(true, 10f, 72f, 100f), sharpening = .65f,
            effects = PhotoEffectsSettings(vignetteAmount = -40f, grainAmount = 65f),
            displayChromaDenoise = 2, exposureMode = 2,
            hsl = HslSettings().withValue(1, 0, -60f),
            lens = LensSettings(true, true, false, true, "fixture-profile"),
        )
        val batchID = "locale-batch-${System.nanoTime()}"
        val destination = "content://com.rawlab.test/tree/locale-destination"
        try {
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
            assertNull(model.state.value.error)
            compose.runOnUiThread { model.edit(expected) }
            compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
            assertNull(model.state.value.error)
            assertEquals(expected, model.state.value.edits)

            val photo = requireNotNull(model.state.value.photo)
            val job = BatchJob(
                source = BatchSourceSnapshot(photo.identity, photo.file, expected, photo.name),
                targets = listOf(BatchTarget(PhotoIdentity("$batchID-target"), photo.file, photo.name, photo.uri.toString())),
                id = batchID,
                outputFormat = ExportFormat.DNG,
                destination = destination,
            )
            compose.runOnUiThread { model.resumeBatch(job) }
            compose.waitUntil(30_000) { model.batch.value?.state?.value?.phase == BatchPhase.CANCELLED }

            fun assertLiveSnapshot() {
                assertEquals(expected, model.state.value.edits)
                val currentJob = requireNotNull(model.batch.value).state.value.job
                assertEquals(batchID, currentJob.id)
                assertEquals(ExportFormat.DNG, currentJob.outputFormat)
                assertEquals(destination, currentJob.destination)
                assertEquals(expected, currentJob.source.settings)
            }
            assertLiveSnapshot()

            listOf("zh-Hans", "en", "de", "fr", "ja", "es").forEach { language ->
                val previousActivity = activity
                val preferenceChanged = AppStrings.preference(previousActivity) != language
                compose.runOnUiThread { AppStrings.setPreference(previousActivity, language) }
                var localeRecreated = false
                if (android.os.Build.VERSION.SDK_INT >= 33 && preferenceChanged) {
                    try {
                        compose.waitUntil(15_000) { compose.activity !== previousActivity }
                        localeRecreated = true
                    } catch (_: AssertionError) {
                        // Some API 33 images do not recreate when the selected locale is unchanged.
                    }
                }
                if (!localeRecreated) compose.activityRule.scenario.recreate()
                compose.activityRule.scenario.onActivity { activity = it; model = it.model }
                assertNotSame(previousActivity, activity)
                compose.waitUntil(180_000) { model.state.value.edits == expected && model.batch.value != null }
                assertLiveSnapshot()
            }
        } finally {
            runCatching { compose.runOnUiThread { model.closeBatch() } }
            BatchJournal(File(context.filesDir, "RawLab/BatchJobs")).discard(batchID)
            source.delete()
        }
    }

    private fun capture(name: String) {
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val output = File(instrumentation.targetContext.getExternalFilesDir(null), name)
        output.outputStream().use { compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
