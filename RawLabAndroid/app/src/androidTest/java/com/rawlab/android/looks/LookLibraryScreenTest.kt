package com.rawlab.android.looks

import android.graphics.Bitmap
import android.net.Uri
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
            compose.onNodeWithTag("editor-groups").performScrollToNode(hasTestTag("editor-group-looks"))
            val looksGroup = compose.onNodeWithTag("editor-group-looks")
            if (looksGroup.fetchSemanticsNode().config[SemanticsProperties.Selected] != true) looksGroup.performClick()
            compose.onNodeWithTag("editor-tools").performScrollToNode(hasTestTag("editor-tool-0"))
            compose.onNodeWithTag("editor-tool-0").performClick()
            compose.runOnUiThread { compose.activity.model.importLook(Uri.fromFile(source)) }
            compose.waitUntil(30_000) { compose.activity.model.state.value.let { it.canExport && it.looks.any { look -> look.name == source.name } } }
            lookId = compose.activity.model.state.value.edits.film
            assertEquals(lookId, compose.activity.model.state.value.recentLookIds.first())
            val saved = compose.activity.model.state.value.edits
            compose.onNodeWithTag("looks.search").performScrollTo().performTextReplacement("ETE")
            compose.onNodeWithTag("looks.search").performImeAction()
            compose.onNodeWithText(source.name).assertExists()
            compose.onNodeWithTag("looks.search").performTextReplacement("no matching look")
            compose.onNodeWithTag("looks.search").performImeAction()
            compose.onNodeWithTag("looks.empty").performScrollTo().assertIsDisplayed()
            assertEquals(saved, compose.activity.model.state.value.edits)
            compose.onNodeWithTag("looks.import").performScrollTo().assertIsDisplayed().assertIsEnabled()
            compose.onNodeWithTag("looks.search").performTextClearance()
            compose.onNodeWithTag("looks.search").performImeAction()
            compose.onNodeWithTag("looks.category").performScrollTo().performClick()
            compose.onNodeWithTag("looks.category.RECENT").performClick()
            compose.onNodeWithText(source.name).assertExists()
            compose.waitUntil(10_000) { compose.activity.model.state.value.message == null }
            compose.onNodeWithText(source.name).performScrollTo().assertIsDisplayed()
            val screenshots = requireNotNull(context.getExternalFilesDir("look-browser"))
            File(screenshots, "recent-${context.resources.configuration.screenWidthDp}.png").outputStream().use {
                instrumentation.uiAutomation.takeScreenshot().compress(Bitmap.CompressFormat.PNG, 100, it)
            }
            compose.runOnUiThread { compose.activity.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
            compose.waitUntil(10_000) { context.resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE }
            compose.onNodeWithTag("looks.search").performScrollTo().assertIsDisplayed()
            compose.onNodeWithTag("looks.import").assertIsDisplayed().assertIsEnabled()
            assertEquals(saved, compose.activity.model.state.value.edits)
            instrumentation.uiAutomation.waitForIdle(750, 5_000)
            File(screenshots, "recent-landscape.png").outputStream().use {
                instrumentation.uiAutomation.takeScreenshot().compress(Bitmap.CompressFormat.PNG, 100, it)
            }
            compose.runOnUiThread { compose.activity.model.deleteLook(lookId!!) }
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
        compose.activityRule.scenario.recreate()
        compose.waitForIdle()
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
            compose.onNodeWithContentDescription(text(R.string.import_look)).assertIsDisplayed().assertIsEnabled()
            compose.runOnUiThread { compose.activity.model.importLook(Uri.fromFile(source)) }
            compose.waitUntil(30_000) {
                compose.activity.model.state.value.let { state ->
                    state.canExport && state.looks.any { it.name == source.name }
                }
            }
            lookId = compose.activity.model.state.value.edits.film
            assertTrue(source.delete())
            // 工具栏也是横向列表（v0.8 起排在胶片条之前）：按“不是工具栏”找胶片条
            val strip = compose.onNode(hasScrollToIndexAction() and !hasTestTag("editor-tools") and
                SemanticsMatcher.keyIsDefined(SemanticsProperties.HorizontalScrollAxisRange))
            strip.performScrollToNode(hasText(source.name))
            compose.onNode(hasContentDescription(text(R.string.more)) and hasAnyAncestor(hasScrollToIndexAction())).performClick()
            compose.onNodeWithText(text(R.string.rename_look)).performClick()
            compose.onNode(hasSetTextAction()).performTextReplacement("Transferred Look $token")
            compose.onNodeWithText(text(R.string.confirm)).performClick()
            compose.waitUntil(10_000) {
                compose.activity.model.state.value.looks.any { it.id == lookId && it.name == "Transferred Look $token" }
            }
            compose.runOnUiThread {
                compose.activity.model.beginExport { assertTrue(it) }
                compose.activity.model.export(Uri.fromFile(exported), ExportFormat.JPEG)
            }
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
            strip.performScrollToNode(hasText("Transferred Look $token"))
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
