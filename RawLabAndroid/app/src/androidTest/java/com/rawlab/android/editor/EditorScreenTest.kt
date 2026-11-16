package com.rawlab.android.editor

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
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.journal.BatchJournal
import com.rawlab.android.batch.BatchPhase
import com.rawlab.android.batch.BatchSourceSnapshot
import com.rawlab.android.batch.BatchTarget
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.settings.DenoiseSettings
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HslSettings
import com.rawlab.android.settings.LensSettings
import com.rawlab.android.settings.PhotoEffectsSettings
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.testing.openWorkbenchTool
import com.rawlab.android.testing.returnToWorkbench
import com.rawlab.android.testing.LanguageTestRule

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
        compose.runOnUiThread { model.edit(model.state.value.edits.copy(film = "velvia", strength = 1f, exposure = .5f)) }
        compose.activityRule.scenario.recreate()
        compose.activityRule.scenario.onActivity { model = it.model }
        compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
        assertNull(model.state.value.error)
        assertEquals("velvia", model.state.value.edits.film)
        // 显式写入 strength=1f 基准：同身份缓存文件的上一轮持久化值会随导入恢复，须保证草稿隔离断言的基线确定。
        assertEquals(1f, model.state.value.edits.strength)
        compose.openWorkbenchTool(0)
        compose.waitUntil(120_000) { model.state.value.let { it.draftReady || it.error != null } }
        assertNull(model.state.value.error)
        compose.onNodeWithTag("adjustment-slider").performScrollTo().performSemanticsAction(SemanticsActions.SetProgress) { it(200f) }
        compose.waitUntil(180_000) { model.state.value.visibleEdits.strength == 2f || model.state.value.error != null }
        // LOOK draft 隔离契约：draftReady 后的标尺 SetProgress 经 projectLook 投影进草稿，visibleEdits 反映草稿值而提交态 edits 保值。
        val afterSlider = model.state.value
        assertEquals(2f, afterSlider.visibleEdits.strength)
        assertEquals(1f, afterSlider.edits.strength)
        assertNull(afterSlider.error)
        // 点击前须再次等 draftReady：SetProgress 触发草稿预览重渲（rendering=true），applyDraft 在非 ready 时直接 no-op。
        compose.waitUntil(120_000) { model.state.value.let { it.draftReady || it.error != null } }
        assertNull(model.state.value.error)
        compose.onNodeWithTag("draft.apply").performClick()
        // apply 完成（draft 清空）或失败（saveState=FAILED 令 canExport 恒假）都要退出等待，避免盲等 180s。
        compose.waitUntil(180_000) { model.state.value.let { it.canExport || it.error != null || it.saveState == EditSaveState.FAILED || it.draft == null } }
        val afterApply = model.state.value
        assertNull(afterApply.error)
        assertNull("apply left state save=${afterApply.saveState} draft=${afterApply.draft?.group} rendering=${afterApply.rendering} exact=${afterApply.exact}", afterApply.draft)
        assertEquals("apply left state save=${afterApply.saveState}", 2f, afterApply.edits.strength)
        compose.openWorkbenchTool(2)
        compose.waitUntil(120_000) { model.state.value.let { it.draftReady || it.error != null } }
        assertNull(model.state.value.error)
        compose.onNodeWithContentDescription("开启对比").performClick()
        compose.onNodeWithTag("comparison-mode").performClick()
        compose.onNodeWithText(compose.activity.getString(R.string.editor_compare_wipe)).performClick()
        compose.onNodeWithTag("comparison-wipe").assertExists().performSemanticsAction(SemanticsActions.SetProgress) { it(.3f) }
        compose.onNodeWithTag("draft.cancel").performClick()
        compose.onNodeWithText("色温").assertDoesNotExist()
        compose.onNodeWithTag("adjustment-slider").assertDoesNotExist()
        capture("editor-collapsed.png")
        compose.openWorkbenchTool(8)
        compose.onNode(hasTestTag("adjustment-slider") and hasContentDescription("色温")).performScrollTo().assertIsDisplayed()
        compose.onNode(hasTestTag("adjustment-slider") and hasContentDescription("色调")).performScrollTo().assertIsDisplayed()
        capture("editor-tint.png")
        compose.openWorkbenchTool(0)
        compose.waitForIdle()
        capture("editor-comparison.png")
        compose.returnToWorkbench()
        val empty = File(instrumentation.targetContext.cacheDir, "empty-test.dng").apply { writeBytes(byteArrayOf()) }
        compose.runOnUiThread { model.importPhoto(Uri.fromFile(empty)) }
        compose.waitUntil(10_000) { model.state.value.error != null || model.state.value.photo != original }
        assertNotNull(model.state.value.error)
        compose.waitUntil(30_000) { model.state.value.operation == Operation.NONE }
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

    @Test fun externalApplyAndDiscardDraftCollapseToolPanelWithoutReopening() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val source = File(context.cacheDir, "external-draft-close-${System.nanoTime()}.jpg")
        val bitmap = Bitmap.createBitmap(300, 200, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.GRAY) }
        source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }
        bitmap.recycle()
        val model = compose.activity.model
        fun waitReady() {
            compose.waitUntil(30_000) { model.state.value.let { it.canExport || it.error != null } }
            assertNull(model.state.value.error)
            compose.waitForIdle()
            assertTrue(model.state.value.canExport)
            assertNull(model.state.value.draft)
        }
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            waitReady()

            compose.runOnUiThread {
                model.beginDraft(AdjustmentGroup.GEOMETRY)
                model.changeDraft(model.state.value.visibleEdits.copy(
                    geometry = com.rawlab.android.geometry.GeometrySettings(quarterTurns = 1)))
            }
            compose.waitUntil(30_000) { model.state.value.draftReady || model.state.value.error != null }
            assertNull(model.state.value.error)
            compose.onNodeWithTag("workspace-more").assertIsDisplayed()

            compose.runOnUiThread { model.applyDraft { assertTrue(it) } }
            waitReady()
            compose.onNodeWithTag("workspace-more").assertDoesNotExist()
            compose.onNodeWithTag("editor-groups").assertIsDisplayed()

            compose.runOnUiThread {
                model.beginDraft(AdjustmentGroup.GEOMETRY)
                model.changeDraft(model.state.value.visibleEdits.copy(
                    geometry = model.state.value.visibleEdits.geometry.copy(quarterTurns = 2)))
            }
            compose.waitUntil(30_000) { model.state.value.draftReady || model.state.value.error != null }
            assertNull(model.state.value.error)
            compose.onNodeWithTag("workspace-more").assertIsDisplayed()

            compose.runOnUiThread { model.discardDraft() }
            waitReady()
            compose.onNodeWithTag("workspace-more").assertDoesNotExist()
            compose.onNodeWithTag("editor-groups").assertIsDisplayed()
        } finally {
            compose.runOnUiThread { model.discardDraft() }
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
