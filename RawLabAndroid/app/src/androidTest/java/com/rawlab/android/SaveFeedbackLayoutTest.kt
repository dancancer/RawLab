package com.rawlab.android

import android.content.res.Configuration
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.Locale
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class SaveFeedbackLayoutTest {
    val compose = createComposeRule()
    @get:Rule val isolated = org.junit.rules.RuleChain.outerRule(ForegroundTestRule()).around(compose)

    @Test fun saveFeedbackKeepsCanvasDockToolsAndSlidersStable() = verifySaveFeedback(listOf("en", "zh-Hans", "de", "fr", "ja", "es"))

    @Test fun saveFeedbackKeepsLayoutInChinese() = verifySaveFeedback(listOf("zh-Hans"))

    private fun verifySaveFeedback(languages: List<String>) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val bitmap = Bitmap.createBitmap(600, 900, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.DKGRAY) }
        var editor by mutableStateOf(EditorState(photo = ImportedPhoto(Uri.parse("content://rawlab.test/save-layout"),
            "save-layout.jpg", File("save-layout.jpg")), preview = PreviewPair(bitmap, bitmap, 6500f, 0f)))
        var viewport by mutableStateOf(360 to 720)
        var language by mutableStateOf("en")
        var fontScale by mutableFloatStateOf(1f)
        var retries = 0
        val visualFailures = mutableListOf<String>()
        val savedTexts = mapOf("en" to "Adjustments saved", "zh-Hans" to "调整已保存", "de" to "Anpassungen gespeichert",
            "fr" to "Réglages enregistrés", "ja" to "調整を保存しました", "es" to "Ajustes guardados")
        compose.setContent {
            val config = Configuration(context.resources.configuration).apply { setLocale(Locale.forLanguageTag(language)) }
            val localized = context.createConfigurationContext(config)
            CompositionLocalProvider(LocalContext provides localized, LocalConfiguration provides config,
                LocalDensity provides Density(1f, fontScale)) {
                Box(Modifier.size(viewport.first.dp, viewport.second.dp)
                    .consumeWindowInsets(WindowInsets.safeDrawing).testTag("save-layout-fixture")) {
                    RawLabTheme {
                        key(viewport, language, fontScale) {
                            EditorScreen(editor, {}, {}, { _, _ -> }, {}, {}, {}, {}, {}, {}, onSaveRetry = { retries++ })
                        }
                    }
                }
            }
        }
        for (size in listOf(360 to 720, 960 to 600)) {
            for (locale in languages) {
                for (scale in if (locale == "en") listOf(1f, 1.6f) else listOf(1.6f)) {
                    compose.runOnIdle { viewport = size; language = locale; fontScale = scale; editor = editor.copy(saveState = EditSaveState.NONE) }
                    val localized = context.createConfigurationContext(Configuration(context.resources.configuration).apply {
                        setLocale(Locale.forLanguageTag(locale))
                    })
                    assertEquals("The resource locale must really change: requested=$locale actual=${localized.resources.configuration.locales.toLanguageTags()} app=${AppStrings.preference(context)} base=${context.resources.configuration.locales.toLanguageTags()}",
                        savedTexts.getValue(locale), localized.getString(R.string.edit_saved))
                    val fixture = compose.onNodeWithTag("save-layout-fixture").fetchSemanticsNode().boundsInRoot
                    assertEquals("The requested viewport must really be measured", size.first.toFloat(), fixture.width, 1f)
                    assertEquals(size.second.toFloat(), fixture.height, 1f)
                    compose.onNodeWithTag("editor-tools").performScrollToNode(hasTestTag("editor-tool-2"))
                    compose.onNodeWithTag("editor-tool-2").performClick()
                    compose.onNodeWithTag("adjustment-slider").performScrollTo()
                    compose.onNodeWithContentDescription(localized.getString(R.string.compare)).performClick()
                    compose.onNodeWithTag("photo-info-button").performClick()
                    compose.waitUntil(5_000) { compose.onAllNodesWithTag("photo-info-panel").fetchSemanticsNodes().isNotEmpty() }
                    for (expanded in listOf(true, false)) {
                        val tags = listOf("editor-canvas", "photo-canvas", "adjustment-dock") +
                            if (expanded) listOf("editor-tools", "adjustment-slider") else emptyList()
                        val before = tags.associateWith { compose.onNodeWithTag(it).fetchSemanticsNode().boundsInRoot }
                        val canvasBounds = before.getValue("editor-canvas")
                        val dockBounds = before.getValue("adjustment-dock")
                        if (size.first > size.second) {
                            assertTrue("The side-dock branch must be reached", canvasBounds.right <= dockBounds.left)
                            assertEquals(340f, dockBounds.width, 1f)
                        } else assertTrue("The bottom-dock branch must be reached", canvasBounds.bottom <= dockBounds.top)
                        for (save in listOf(EditSaveState.SAVED, EditSaveState.RESTORED, EditSaveState.FAILED, EditSaveState.NONE)) {
                            compose.runOnIdle { editor = editor.copy(saveState = save) }
                            before.forEach { (tag, bounds) ->
                                assertBounds("$size/$locale/$scale/$expanded/$save/$tag", bounds,
                                    compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot)
                            }
                            if (save == EditSaveState.NONE) compose.onNodeWithTag("edit-save-notice").assertDoesNotExist()
                            else {
                                compose.onNodeWithTag("edit-save-notice").assertIsDisplayed()
                                val text = localized.getString(when (save) {
                                    EditSaveState.SAVED -> R.string.edit_saved
                                    EditSaveState.RESTORED -> R.string.edit_restored
                                    else -> R.string.edit_unsaved
                                })
                                val layouts = mutableListOf<TextLayoutResult>()
                                (if (save == EditSaveState.FAILED) compose.onNodeWithTag("edit-save-retry") else compose.onNodeWithText(text))
                                    .assert(SemanticsMatcher.expectValue(SemanticsProperties.LiveRegion, LiveRegionMode.Polite))
                                compose.onNodeWithText(text, useUnmergedTree = true).assertIsDisplayed()
                                    .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                                // SimpleTextNode 的 paragraph 可保留父约束宽度；裁切要检查实际行边界。
                                if (layouts.isEmpty() || layouts.any { layout -> layout.didOverflowHeight || (save != EditSaveState.FAILED && layout.lineCount > 3) ||
                                    (0 until layout.lineCount).any { line -> layout.isLineEllipsized(line) ||
                                        layout.getLineLeft(line) < -1f || layout.getLineRight(line) > layout.size.width + 1f } }) {
                                    visualFailures += "$size/$locale/$scale/$expanded/$save clipped: ${layouts.map { "${it.size}/${it.lineCount}" }}"
                                }
                                val notice = compose.onNodeWithTag("edit-save-notice").fetchSemanticsNode().boundsInRoot
                                val canvas = before.getValue("editor-canvas")
                                if (!canvas.contains(notice.topLeft) || notice.right > canvas.right || notice.bottom > canvas.bottom)
                                    visualFailures += "$size/$locale/$scale/$expanded/$save outside canvas"
                                for (other in listOf(compose.onNodeWithTag("photo-info-panel"),
                                    compose.onNodeWithText(localized.getString(R.string.neutral)),
                                    compose.onNodeWithText(localized.getString(R.string.result)))) {
                                    if (notice.overlaps(other.fetchSemanticsNode().boundsInRoot))
                                        visualFailures += "$size/$locale/$scale/$expanded/$save overlaps photo information or comparison labels"
                                }
                                if (save == EditSaveState.FAILED) {
                                    val previous = retries
                                    compose.onNodeWithTag("edit-save-retry").assertHasClickAction()
                                        .assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Button))
                                        .performTouchInput { click() }
                                    compose.runOnIdle { assertEquals(previous + 1, retries) }
                                }
                                if (expanded && save in listOf(EditSaveState.SAVED, EditSaveState.FAILED) &&
                                    ((size.first == 360 && locale == "en" && scale == 1f) || (size.first == 960 && locale == "de"))) {
                                    capture("${size.first}-$locale-$save.png")
                                }
                            }
                        }
                        if (expanded) compose.onNodeWithContentDescription(localized.getString(R.string.collapse_adjustments)).performClick()
                        else compose.onNodeWithTag("editor-tools").assertDoesNotExist()
                    }
                }
            }
        }
        compose.runOnIdle { viewport = 360 to 600; editor = editor.copy(saveState = EditSaveState.SAVED) }
        compose.onNodeWithTag("photo-info-button").performClick().performClick()
        val panel = compose.onNodeWithTag("photo-info-panel").assertIsDisplayed()
        val notice = compose.onNodeWithTag("edit-save-notice").fetchSemanticsNode().boundsInRoot
        assertFalse("Capture information must not overlap feedback without comparison", panel.fetchSemanticsNode().boundsInRoot.overlaps(notice))
        val scroll = panel.fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange]
        assertTrue("The capture-information scroll branch must really be reached", scroll.maxValue() > 0)
        val beforeScroll = scroll.value()
        panel.performTouchInput { swipeUp() }
        compose.runOnIdle { assertTrue("Capture information must remain reachable by touch", scroll.value() > beforeScroll) }
        for (group in listOf(AdjustmentGroup.LENS, AdjustmentGroup.GEOMETRY)) {
            for (save in listOf(EditSaveState.SAVED, EditSaveState.RESTORED, EditSaveState.FAILED)) {
                compose.runOnIdle { editor = editor.copy(saveState = save, draft = AdjustmentDraft.begin(group, editor.edits)) }
                compose.onNodeWithTag("edit-save-notice").assertDoesNotExist()
            }
        }
        compose.runOnIdle { editor = editor.copy(draft = null, preview = null) }
        compose.onNodeWithTag("edit-save-notice").assertIsDisplayed()
        val previous = retries
        compose.onNodeWithTag("edit-save-retry").performTouchInput { click() }
        compose.runOnIdle { assertEquals(previous + 1, retries) }
        compose.runOnIdle { editor = editor.copy(saveState = EditSaveState.NONE) }
        compose.onNodeWithTag("edit-save-notice").assertDoesNotExist()
        compose.onNodeWithTag("editor-canvas").assertExists()
        assertTrue(visualFailures.joinToString("\n"), visualFailures.isEmpty())
    }

    private fun assertBounds(label: String, expected: Rect, actual: Rect) {
        assertEquals("$label left", expected.left, actual.left, 1f)
        assertEquals("$label top", expected.top, actual.top, 1f)
        assertEquals("$label right", expected.right, actual.right, 1f)
        assertEquals("$label bottom", expected.bottom, actual.bottom, 1f)
    }

    private fun capture(name: String) {
        val directory = File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "save-status-layout").apply { mkdirs() }
        val image = compose.onNodeWithTag("save-layout-fixture").captureToImage().asAndroidBitmap()
        File(directory, name).outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        image.recycle()
    }
}
