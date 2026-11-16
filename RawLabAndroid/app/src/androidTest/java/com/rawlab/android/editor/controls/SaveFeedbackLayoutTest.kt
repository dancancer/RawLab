package com.rawlab.android.editor.controls

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
import com.rawlab.android.R
import com.rawlab.android.RawLabTheme
import com.rawlab.android.editor.AdjustmentDraft
import com.rawlab.android.editor.AdjustmentGroup
import com.rawlab.android.editor.EditSaveState
import com.rawlab.android.editor.EditorState
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.ui.EditorScreen
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.testing.ForegroundTestRule
import com.rawlab.android.testing.localizedTestContext
import com.rawlab.android.testing.localizedTestConfiguration
import com.rawlab.android.testing.openWorkbenchTool
import com.rawlab.android.testing.cycleWorkbenchPhotoInfo

class SaveFeedbackLayoutTest {
    val compose = createComposeRule()
    @get:Rule val isolated = org.junit.rules.RuleChain.outerRule(ForegroundTestRule()).around(compose)

    @Test fun saveFeedbackKeepsCanvasDockToolsAndSlidersStable() = verifySaveFeedback(listOf("en", "zh-Hans", "de", "fr", "ja", "es"))

    @Test fun saveFeedbackKeepsLayoutInChinese() = verifySaveFeedback(listOf("zh-Hans"))

    @Test fun saveFailureDetailsKeepLayoutAndRetryInChineseAndEnglish() = verifySaveFeedback(listOf("zh-Hans", "en"), true)

    private fun verifySaveFeedback(languages: List<String>, failureDetails: Boolean = false) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val bitmap = Bitmap.createBitmap(600, 900, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.DKGRAY) }
        var editor by mutableStateOf(EditorState(photo = ImportedPhoto(Uri.parse("content://rawlab.test/save-layout"),
            "save-layout.jpg", File("save-layout.jpg")), preview = PreviewPair(bitmap, bitmap, 6500f, 0f), exact = true))
        var viewport by mutableStateOf(360 to 720)
        var language by mutableStateOf("en")
        var fontScale by mutableFloatStateOf(1f)
        var retries = 0
        var draftRetries = 0
        val visualFailures = mutableListOf<String>()
        val savedTexts = mapOf("en" to "Adjustments Saved", "zh-Hans" to "调整已保存", "de" to "Anpassungen gespeichert",
            "fr" to "Réglages enregistrés", "ja" to "調整を保存しました", "es" to "Ajustes guardados")
        compose.setContent {
            val config = localizedTestConfiguration(context.resources.configuration, language, fontScale)
            val localized = localizedTestContext(context, language, config.fontScale)
            CompositionLocalProvider(LocalContext provides localized, LocalConfiguration provides config,
                LocalDensity provides Density(1f, fontScale)) {
                Box(Modifier.size(viewport.first.dp, viewport.second.dp)
                    .consumeWindowInsets(WindowInsets.safeDrawing).testTag("save-layout-fixture")) {
                    RawLabTheme {
                        key(viewport, language, fontScale) {
                            EditorScreen(editor, {}, {}, { _, _ -> }, {}, {}, {}, {}, {}, onSaveRetry = { retries++ },
                                onApplyDraft = { complete -> draftRetries++; complete(false) },
                                onBeginDraft = { editor = editor.copy(draft = AdjustmentDraft.begin(it, editor.edits)) },
                                onDiscardDraft = { editor = editor.copy(draft = null) })
                        }
                    }
                }
            }
        }
        for (size in listOf(320 to 720, 360 to 720, 960 to 600)) {
            for (locale in languages) {
                val scale = 1f
                run {
                    compose.runOnIdle { viewport = size; language = locale; fontScale = scale; editor = editor.copy(saveState = EditSaveState.NONE, draft = null) }
                    val localized = context.createConfigurationContext(localizedTestConfiguration(context.resources.configuration, locale, scale))
                    assertEquals("The resource locale must really change: requested=$locale actual=${localized.resources.configuration.locales.toLanguageTags()} app=${AppStrings.preference(context)} base=${context.resources.configuration.locales.toLanguageTags()}",
                        savedTexts.getValue(locale), localized.getString(R.string.edit_saved))
                    val fixture = compose.onNodeWithTag("save-layout-fixture").fetchSemanticsNode().boundsInRoot
                    assertEquals("The requested viewport must really be measured", size.first.toFloat(), fixture.width, 1f)
                    assertEquals(size.second.toFloat(), fixture.height, 1f)
                    compose.openWorkbenchTool(2)
                    compose.onNodeWithTag("adjustment-slider").performScrollTo()
                    compose.onNodeWithContentDescription(localized.getString(R.string.editor_compare_enable)).performClick()
                    compose.cycleWorkbenchPhotoInfo(AppStrings.text(R.string.editor_photo_info))
                    compose.waitUntil(5_000) { compose.onAllNodesWithTag("photo-info-panel").fetchSemanticsNodes().isNotEmpty() }
                    for (expanded in listOf(true, false)) {
                        val tags = listOf("editor-canvas", "photo-canvas", "adjustment-dock") +
                            if (expanded) listOf("editor-parameters", "adjustment-slider", "draft.apply", "draft.cancel") else listOf("editor-groups", "editor-tool-2")
                        val before = tags.associateWith { compose.onNodeWithTag(it).fetchSemanticsNode().boundsInRoot }
                        val canvasBounds = before.getValue("editor-canvas")
                        val dockBounds = before.getValue("adjustment-dock")
                        if (size.first > size.second && scale == 1f && locale == "zh-Hans") {
                            assertTrue("Six measured Chinese labels fit the side dock", canvasBounds.right <= dockBounds.left)
                            assertEquals(336f, dockBounds.width, 1f)
                        } else if (scale >= 1.3f || size.first <= size.second) {
                            assertTrue("Narrow and accessibility layouts use the bottom dock", canvasBounds.bottom <= dockBounds.top)
                        } else {
                            assertTrue("Measured-label fallback must keep photo and controls separate",
                                canvasBounds.right <= dockBounds.left || canvasBounds.bottom <= dockBounds.top)
                        }
                        for (save in listOf(EditSaveState.SAVED, EditSaveState.RESTORED, EditSaveState.FAILED, EditSaveState.NONE)) {
                            val detail = if (failureDetails && save == EditSaveState.FAILED)
                                localized.getString(R.string.edit_unsaved_detail, "edits.properties: permission denied") else null
                            compose.runOnIdle { editor = editor.copy(saveState = save, saveError = detail) }
                            before.forEach { (tag, bounds) ->
                                assertBounds("$size/$locale/$scale/$expanded/$save/$tag", bounds,
                                    compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot)
                            }
                            if (save == EditSaveState.NONE || expanded && save != EditSaveState.FAILED) compose.onNodeWithTag("edit-save-notice").assertDoesNotExist()
                            else {
                                compose.onNodeWithTag("edit-save-notice").assertIsDisplayed()
                                val text = detail ?: localized.getString(when (save) {
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
                                for ((who, other) in listOf("photo information" to compose.onNodeWithTag("photo-info-panel"),
                                    "comparison label" to compose.onNodeWithText(localized.getString(R.string.editor_compare_before)),
                                    "result label" to compose.onNodeWithText(localized.getString(R.string.result)))) {
                                    val otherBounds = other.fetchSemanticsNode().boundsInRoot
                                    if (notice.overlaps(otherBounds))
                                        visualFailures += "$size/$locale/$scale/$expanded/$save overlaps $who: notice=$notice other=$otherBounds"
                                }
                                if (save == EditSaveState.FAILED) {
                                    val previous = retries
                                    val previousDraft = draftRetries
                                    compose.onNodeWithTag("edit-save-retry").assertHasClickAction()
                                        .assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Button))
                                        .performTouchInput { click() }
                                    compose.runOnIdle {
                                        assertEquals(previous + if (expanded) 0 else 1, retries)
                                        assertEquals(previousDraft + if (expanded) 1 else 0, draftRetries)
                                    }
                                }
                                if (expanded && save in listOf(EditSaveState.SAVED, EditSaveState.FAILED) &&
                                    ((size.first in listOf(320, 360) && locale in listOf("zh-Hans", "en")) || (size.first == 960 && locale in listOf("en", "zh-Hans")))) {
                                    capture("${size.first}-$locale-$scale-$save.png")
                                }
                            }
                        }
                        if (expanded) compose.onNodeWithTag("draft.cancel").performClick()
                        else compose.onNodeWithTag("editor-tools").assertDoesNotExist()
                    }
                }
            }
        }
        compose.runOnIdle { viewport = 360 to 600; editor = editor.copy(saveState = EditSaveState.SAVED) }
        val infoLabel = AppStrings.text(R.string.editor_photo_info)
        compose.cycleWorkbenchPhotoInfo(infoLabel)
        compose.cycleWorkbenchPhotoInfo(infoLabel)
        val panel = compose.onNodeWithTag("photo-info-panel").assertIsDisplayed()
        val notice = compose.onNodeWithTag("edit-save-notice").fetchSemanticsNode().boundsInRoot
        val infoBounds = panel.fetchSemanticsNode().boundsInRoot
        assertFalse("Capture information overlaps feedback: language=$language font=$fontScale panel=$infoBounds notice=$notice", infoBounds.overlaps(notice))
        val infoResources = localizedTestContext(context, language, fontScale).resources
        for (title in listOf(R.string.info_filename, R.string.info_camera, R.string.info_lens,
            R.string.info_shutter, R.string.info_aperture, R.string.info_iso, R.string.info_focal_length)) {
            val field = compose.onNode(hasText(infoResources.getString(title), substring = true) and hasAnyAncestor(hasTestTag("photo-info-panel"))).assertIsDisplayed()
            val visible = field.fetchSemanticsNode().boundsInRoot
            val full = field.getUnclippedBoundsInRoot()
            assertTrue("Capture information keeps every complete field reachable: $title $visible / $full",
                visible.height >= (full.bottom - full.top).value - 1 && visible.width >= (full.right - full.left).value - 1)
            val canvas = compose.onNodeWithTag("editor-canvas").fetchSemanticsNode().boundsInRoot
            assertTrue("Capture information fits the actual photo viewport", visible.top >= canvas.top - 1 && visible.bottom <= canvas.bottom + 1)
        }
        for (group in listOf(AdjustmentGroup.LENS, AdjustmentGroup.GEOMETRY)) {
            compose.runOnIdle { editor = editor.copy(saveState = EditSaveState.NONE, draft = AdjustmentDraft.begin(group, editor.edits)) }
            val draftBounds = compose.onNodeWithTag("adjustment-dock").fetchSemanticsNode().boundsInRoot
            for (save in listOf(EditSaveState.SAVED, EditSaveState.RESTORED, EditSaveState.FAILED)) {
                compose.runOnIdle { editor = editor.copy(saveState = save) }
                if (save == EditSaveState.FAILED) {
                    compose.onNodeWithTag("edit-save-notice").assertIsDisplayed()
                    compose.onNodeWithTag("edit-save-retry").assertIsDisplayed().assertHasClickAction()
                } else compose.onNodeWithTag("edit-save-notice").assertDoesNotExist()
                assertBounds("draft/$group/$save", draftBounds, compose.onNodeWithTag("adjustment-dock").fetchSemanticsNode().boundsInRoot)
            }
        }
        compose.runOnIdle { editor = editor.copy(draft = null, preview = null) }
        compose.onNodeWithTag("edit-save-notice").assertIsDisplayed()
        val previous = retries
        compose.onNodeWithTag("edit-save-retry").performTouchInput { click() }
        compose.runOnIdle { assertEquals(previous + 1, retries) }
        compose.runOnIdle { editor = editor.copy(saveState = EditSaveState.NONE, draft = null) }
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
