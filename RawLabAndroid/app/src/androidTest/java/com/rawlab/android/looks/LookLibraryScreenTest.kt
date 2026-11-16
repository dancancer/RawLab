package com.rawlab.android.looks

import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.UUID
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.editor.Operation
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.testing.LanguageTestRule

class LookLibraryScreenTest {
    val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val languageAndCompose = org.junit.rules.RuleChain.outerRule(LanguageTestRule()).around(compose)

    private fun openLooks() {
        compose.onNodeWithTag("editor-groups").performScrollToNode(hasTestTag("editor-group-looks"))
        compose.onNodeWithTag("editor-group-looks").performClick()
        compose.onNodeWithTag("editor-tool-0").performScrollTo().performClick()
        compose.waitUntil(30_000) { compose.activity.model.state.value.draftReady }
    }

    private fun applyLookDraft() {
        compose.waitUntil(30_000) { compose.activity.model.state.value.let { it.draftReady && it.message == null } }
        compose.onNodeWithTag("draft.apply").performClick()
        try {
            compose.waitUntil(30_000) { compose.activity.model.state.value.let { it.draft == null && it.canExport } }
        } catch (failure: androidx.compose.ui.test.ComposeTimeoutException) {
            val state = compose.activity.model.state.value
            throw AssertionError("Look draft did not finish: draft=${state.draft?.group}, changed=${state.draft?.changed}, rendering=${state.rendering}, " +
                "exact=${state.exact}, resize=${state.previewResizePending}, operation=${state.operation}, " +
                "save=${state.saveState}, error=${state.error}, saveError=${state.saveError}, message=${state.message}", failure)
        }
    }

    private fun searchLook(query: String) {
        if (compose.onAllNodesWithTag("looks.search").fetchSemanticsNodes().isEmpty())
            compose.onNodeWithTag("looks.search.open").performScrollTo().performClick()
        compose.onNodeWithTag("looks.search").performScrollTo().performTextReplacement(query)
        compose.onNodeWithTag("looks.search").performImeAction()
    }

    private fun showLook(name: String) {
        compose.onNode(hasScrollToIndexAction() and
            SemanticsMatcher.keyIsDefined(SemanticsProperties.HorizontalScrollAxisRange))
            .performScrollToNode(hasText(name, substring = true))
        compose.onNodeWithText(name, substring = true).assertIsDisplayed()
    }

    @Test fun batchImportReportScrollsAndCanBeDismissed() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val failures = (1..18).map { index ->
            File(context.cacheDir, "Batch-FLog2C-long-unsupported-look-$index.cube").apply { writeText("invalid") }
        }
        try {
            compose.runOnUiThread { compose.activity.model.importLooks(failures.map(Uri::fromFile)) }
            compose.waitUntil(15_000) { compose.activity.model.state.value.lookImportReport != null }
            compose.onNodeWithText("导入结果").assertIsDisplayed()
            compose.onNodeWithText("确定").assertIsDisplayed().assertIsEnabled()
            compose.onNodeWithText("Batch-FLog2C-long-unsupported-look-18.cube", substring = true)
                .performTouchInput { swipeUp() }
            val shape = if (context.resources.configuration.screenWidthDp >= 600) "tablet" else "phone"
            val screenshots = requireNotNull(context.getExternalFilesDir("look-screenshots"))
            File(screenshots, "$shape-batch-import.png").outputStream().use {
                instrumentation.uiAutomation.takeScreenshot().compress(Bitmap.CompressFormat.PNG, 100, it)
            }
            compose.onNodeWithText("确定").performClick()
            compose.waitUntil { compose.activity.model.state.value.lookImportReport == null }
            compose.onNodeWithText("导入结果").assertDoesNotExist()
        } finally {
            failures.forEach { it.delete() }
            compose.runOnUiThread { compose.activity.model.dismissLookImportReport() }
        }
    }

    @Test fun importedLookCanBeRenamedAndRemovedAfterOriginalIsDeleted() = verifyManagedLook("zh-Hans")

    @Test fun importedLookCanBeRenamedAndRemovedInEnglish() = verifyManagedLook("en")

    @Test fun searchAndRecentKeepTheAppliedLookAndFixedImportAction() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val token = UUID.randomUUID().toString().take(8)
        val photo = File(context.cacheDir, "browse-$token.png")
        val source = File(context.cacheDir, "Été-$token.cube")
        val bitmap = Bitmap.createBitmap(96, 64, Bitmap.Config.ARGB_8888).apply { eraseColor(0xff779988.toInt()) }
        photo.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
        val bundled = context.assets.list("films")!!.first { it.endsWith(".cube") }
        context.assets.open("films/$bundled").use { input -> source.outputStream().use(input::copyTo) }
        var lookId: String? = null
        try {
            compose.runOnUiThread { compose.activity.model.importPhoto(Uri.fromFile(photo)) }
            compose.waitUntil(30_000) { compose.activity.model.state.value.canExport }
            openLooks()
            val recentBefore = compose.activity.model.state.value.recentLookIds
            compose.runOnUiThread { compose.activity.model.importLook(Uri.fromFile(source)) }
            compose.waitUntil(30_000) { compose.activity.model.state.value.let { it.draftReady && it.looks.any { look -> look.name == source.name } } }
            lookId = compose.activity.model.state.value.visibleEdits.film
            assertEquals(recentBefore, compose.activity.model.state.value.recentLookIds)
            applyLookDraft(); openLooks()
            assertEquals(lookId, compose.activity.model.state.value.recentLookIds.first())
            val saved = compose.activity.model.state.value.edits
            compose.onNodeWithTag("looks.search").assertDoesNotExist()
            compose.onNodeWithTag("looks.search.open").performScrollTo().performClick()
            compose.onNodeWithTag("looks.search").performScrollTo().performTextReplacement("ETE")
            compose.onNodeWithTag("looks.search").performImeAction()
            showLook(source.name)
            compose.onNodeWithTag("looks.search").performTextReplacement("no matching look")
            compose.onNodeWithTag("looks.search").performImeAction()
            compose.onNodeWithTag("looks.empty").performScrollTo().assertIsDisplayed()
            assertEquals(saved, compose.activity.model.state.value.edits)
            compose.onNodeWithTag("looks.import").performScrollTo().assertIsDisplayed().assertIsEnabled()
            compose.onNodeWithTag("looks.search.clear").performClick()
            compose.onNodeWithTag("looks.search").assertDoesNotExist()
            compose.onNodeWithTag("looks.category").performScrollTo().performClick()
            compose.onNodeWithTag("looks.category.RECENT").performClick()
            showLook(source.name)
            compose.waitUntil(10_000) { compose.activity.model.state.value.message == null }
            compose.onNodeWithText(source.name, substring = true).performScrollTo().assertIsDisplayed()
            val screenshots = requireNotNull(context.getExternalFilesDir("look-browser"))
            File(screenshots, "recent-${context.resources.configuration.screenWidthDp}.png").outputStream().use {
                instrumentation.uiAutomation.takeScreenshot().compress(Bitmap.CompressFormat.PNG, 100, it)
            }
            compose.onNodeWithTag("looks.search.open").performScrollTo().performClick()
            compose.onNodeWithTag("looks.search").performTextReplacement("ETE")
            compose.onNodeWithTag("looks.search").performImeAction()
            compose.runOnUiThread { compose.activity.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
            compose.waitUntil(10_000) { context.resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE }
            compose.onNodeWithTag("looks.search").performScrollTo().assertIsDisplayed()
            compose.onNodeWithTag("looks.search").assertTextContains("ETE")
            compose.onNodeWithTag("looks.search.close").performClick()
            compose.onNodeWithTag("looks.search").assertDoesNotExist()
            compose.onNodeWithTag("looks.import").assertIsDisplayed().assertIsEnabled()
            assertEquals(saved, compose.activity.model.state.value.edits)
            instrumentation.uiAutomation.waitForIdle(750, 5_000)
            File(screenshots, "recent-landscape.png").outputStream().use {
                instrumentation.uiAutomation.takeScreenshot().compress(Bitmap.CompressFormat.PNG, 100, it)
            }
            compose.runOnUiThread {
                val model = compose.activity.model
                model.changeDraft(model.state.value.visibleEdits.copy(strength = .75f), false)
            }
            compose.waitUntil(30_000) { compose.activity.model.state.value.draftReady }
            searchLook(token)
            fun requestDelete() {
                compose.onNode(hasContentDescription(context.getString(R.string.more)) and hasAnyAncestor(hasScrollToIndexAction())).performClick()
                compose.onNodeWithText(context.getString(R.string.delete_look)).performClick()
                compose.onNode(hasText(context.getString(R.string.confirm)) and hasAnyAncestor(isDialog())).performClick()
            }
            requestDelete()
            compose.onNode(hasText(context.getString(R.string.adjustment_continue)) and hasAnyAncestor(isDialog())).performClick()
            assertTrue(compose.activity.model.state.value.looks.any { it.id == lookId })
            assertTrue(compose.activity.model.state.value.draft!!.changed)
            requestDelete()
            compose.onNode(hasText(context.getString(R.string.adjustment_discard)) and hasAnyAncestor(isDialog())).performClick()
            compose.waitUntil(30_000) { compose.activity.model.state.value.looks.none { it.id == lookId } }
            assertTrue(lookId !in compose.activity.model.state.value.recentLookIds)
        } finally {
            compose.runOnUiThread { compose.activity.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED }
            lookId?.let { id -> compose.runOnUiThread { if (compose.activity.model.state.value.looks.any { it.id == id }) compose.activity.model.deleteLook(id) } }
            source.delete(); photo.delete()
        }
    }

    private fun verifyManagedLook(language: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        compose.runOnUiThread { AppStrings.setPreference(context, language) }
        if (Build.VERSION.SDK_INT < 33) compose.activityRule.scenario.recreate()
        compose.waitUntil(10_000) {
            runCatching { compose.activity.resources.configuration.locales[0].language == java.util.Locale.forLanguageTag(language).language }.getOrDefault(false)
        }
        fun text(id: Int) = AppStrings.text(id)
        val token = UUID.randomUUID().toString().take(8)
        val raw = File(context.cacheDir, "screen-$token.arw")
        val source = File(context.cacheDir, "Transferred-$token.cube")
        val exported = File(context.cacheDir, "export-$token.jpg")
        var lookId: String? = null
        try {
            instrumentation.context.assets.open("sample.RAW").use { input ->
                raw.outputStream().use { input.copyTo(it) }
            }
            val bundled = context.assets.list("films")!!.first { it.endsWith(".cube") }
            context.assets.open("films/$bundled").use { input ->
                source.outputStream().use { input.copyTo(it) }
            }
            compose.runOnUiThread { compose.activity.model.importPhoto(Uri.fromFile(raw)) }
            compose.waitUntil(30_000) { compose.activity.model.state.value.canExport }
            openLooks()
            compose.onNodeWithContentDescription(text(R.string.import_look)).assertIsDisplayed().assertIsEnabled()
            compose.runOnUiThread { compose.activity.model.importLook(Uri.fromFile(source)) }
            compose.waitUntil(30_000) {
                compose.activity.model.state.value.let { state ->
                    state.draftReady && state.looks.any { it.name == source.name }
                }
            }
            lookId = compose.activity.model.state.value.visibleEdits.film
            applyLookDraft(); openLooks()
            assertTrue(source.delete())
            searchLook(token)
            compose.onNodeWithText(source.name, substring = true).assertExists()
            compose.onNode(hasContentDescription(text(R.string.more)) and hasAnyAncestor(hasScrollToIndexAction())).performClick()
            compose.onNodeWithText(text(R.string.rename_look)).performClick()
            compose.onNode(hasSetTextAction() and hasAnyAncestor(isDialog())).performTextReplacement("Transferred Look $token")
            compose.onNodeWithText(text(R.string.confirm)).performClick()
            compose.waitUntil(10_000) {
                compose.activity.model.state.value.looks.any { it.id == lookId && it.name == "Transferred Look $token" }
            }
            compose.waitUntil(30_000) { compose.activity.model.state.value.draft == null }
            compose.waitUntil(30_000) { compose.activity.model.state.value.canExport }
            val exportReady = java.util.concurrent.atomic.AtomicReference<Boolean?>(null)
            compose.runOnUiThread { compose.activity.model.beginExport { exportReady.set(it) } }
            compose.waitUntil(30_000) { exportReady.get() != null }
            assertTrue(exportReady.get() == true)
            compose.runOnUiThread { compose.activity.model.export(Uri.fromFile(exported), ExportFormat.JPEG) }
            compose.waitUntil(30_000) { compose.activity.model.state.value.operation == Operation.NONE }
            assertTrue(exported.length() > 0)
            compose.runOnUiThread { compose.activity.model.dismissMessage() }
            compose.waitForIdle()
            val shape = if (context.resources.configuration.screenWidthDp >= 600) "tablet" else "phone"
            val screenshots = requireNotNull(context.getExternalFilesDir("look-screenshots"))
            File(screenshots, "$shape-$language-managed-look.png").outputStream().use {
                compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
            }
            compose.activityRule.scenario.recreate()
            compose.waitForIdle()
            openLooks()
            searchLook(token)
            compose.onNodeWithText("Transferred Look $token", substring = true).assertExists()
            compose.onNode(hasContentDescription(text(R.string.more)) and hasAnyAncestor(hasScrollToIndexAction())).performClick()
            compose.onNodeWithText(text(R.string.delete_look)).performClick()
            compose.onNodeWithText(AppStrings.format(R.string.remove_look_confirmation,"Transferred Look $token")).assertIsDisplayed()
            File(screenshots, "$shape-$language-remove-look.png").outputStream().use {
                instrumentation.uiAutomation.takeScreenshot().compress(Bitmap.CompressFormat.PNG, 100, it)
            }
            compose.onNodeWithText(text(R.string.confirm)).performClick()
            compose.waitUntil(30_000) {
                compose.activity.model.state.value.let { state -> state.canExport && state.looks.none { it.id == lookId } }
            }
            assertEquals("neutral", compose.activity.model.state.value.edits.film)
        } finally {
            lookId?.let { id ->
                compose.runOnUiThread {
                    if (compose.activity.model.state.value.looks.any { it.id == id }) compose.activity.model.deleteLook(id)
                }
            }
            source.delete()
            raw.delete()
            exported.delete()
        }
    }
}
