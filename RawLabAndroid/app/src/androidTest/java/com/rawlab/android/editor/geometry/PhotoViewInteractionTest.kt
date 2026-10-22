package com.rawlab.android.editor.geometry

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.*
import androidx.compose.ui.semantics.SemanticsProperties
import com.rawlab.android.R
import androidx.compose.ui.test.junit4.createComposeRule
import com.rawlab.android.editor.EditorState
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.ui.EditorScreen
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.testing.LanguageTestRule
import com.rawlab.android.testing.setChineseContent
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File

class PhotoViewInteractionTest {
    private val compose = createComposeRule()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(compose)
    private fun editor() {
        val neutral = Bitmap.createBitmap(600, 400, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
        val after = Bitmap.createBitmap(600, 400, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.RED) }
        val state = EditorState(photo = ImportedPhoto(Uri.parse("content://view/a"), "photo-a", File("a")),
            preview = PreviewPair(neutral, after, 6500f, 0f), exact = true)
        compose.setChineseContent { MaterialTheme { EditorScreen(state, {}, {}, { _, _ -> error("Viewing must never edit") }, {}, {}, {}, {}, {}) } }
    }

    @Test fun singleTapAndBackRestoreTheSameToolAndFineState() {
        editor()
        compose.onNodeWithTag("editor-groups").performScrollToNode(hasTestTag("editor-group-color"))
        compose.onNodeWithTag("editor-group-color").performClick()
        compose.onNodeWithTag("editor-tools").performScrollToNode(hasTestTag("editor-tool-14"))
        compose.onNodeWithTag("editor-tool-14").performClick()
        compose.onNodeWithTag("adjustment-fine").performClick().assertIsOn()
        val lastAxis = compose.onNodeWithTag("adjustment-value-${R.string.hsl_lightness}").performScrollTo()
        val scrollPosition = lastAxis.fetchSemanticsNode().boundsInRoot
        val canvas = compose.onNodeWithTag("photo-canvas")
        canvas.performTouchInput { doubleClick(center); swipeLeft() }
        val originalView = canvas.fetchSemanticsNode().config[SemanticsProperties.StateDescription]
        canvas.performTouchInput { click(center) }
        compose.waitUntil(3_000) { compose.onAllNodesWithTag("adjustment-dock").fetchSemanticsNodes().isEmpty() }
        compose.onNodeWithTag("adjustment-dock").assertDoesNotExist()
        androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK)
        compose.waitUntil(3_000) { compose.onAllNodesWithTag("adjustment-dock").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("adjustment-fine").assertIsOn()
        compose.onNodeWithTag("editor-tool-14").assertIsSelected()
        assertEquals("Pure preview keeps parameter scroll", scrollPosition, lastAxis.fetchSemanticsNode().boundsInRoot)
        canvas.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, originalView))
    }

    @Test fun doubleTapAndPanDoNotEnterPurePreview() {
        editor()
        val canvas = compose.onNodeWithTag("photo-canvas")
        canvas.performTouchInput { doubleClick(center) }
        compose.onNodeWithTag("adjustment-dock").assertIsDisplayed()
        canvas.performTouchInput { swipeLeft() }
        compose.onNodeWithTag("adjustment-dock").assertIsDisplayed()
    }

    @Test fun comparisonCanCloseDirectlyAndReopenThePreferredWipe() {
        editor()
        compose.onNodeWithContentDescription("开启对比").performClick()
        compose.onNodeWithTag("comparison-before").assertIsDisplayed()
        compose.onNodeWithTag("comparison-mode").performClick()
        compose.onNodeWithText("分割线").performClick()
        compose.onNodeWithTag("comparison-wipe").assertIsDisplayed()
        compose.onNodeWithContentDescription("关闭对比").performClick()
        compose.onNodeWithTag("comparison-wipe").assertDoesNotExist()
        compose.onNodeWithContentDescription("开启对比").performClick()
        compose.onNodeWithTag("comparison-wipe").assertIsDisplayed()
    }

    @Test fun geometryDraftKeepsCropGestureAndBlocksViewingActions() {
        val bitmap = Bitmap.createBitmap(600, 400, Bitmap.Config.ARGB_8888)
        val edits = com.rawlab.android.settings.EditSettings(geometry = com.rawlab.android.geometry.GeometrySettings(.1f, .1f, .8f, .8f))
        var state by mutableStateOf(EditorState(photo = ImportedPhoto(Uri.parse("content://view/crop"), "crop", File("crop")),
            edits = edits, preview = PreviewPair(bitmap, bitmap, 6500f, 0f), exact = true,
            draft = com.rawlab.android.editor.AdjustmentDraft.begin(com.rawlab.android.editor.AdjustmentGroup.GEOMETRY, edits)))
        compose.setChineseContent { MaterialTheme { EditorScreen(state, {}, {}, { _, _ -> error("Crop cannot commit") }, {}, {}, {}, {}, {},
            onDraftEdit = { next, _ -> state = state.copy(draft = state.draft!!.update(next)) }) } }
        compose.onNodeWithContentDescription("开启对比").assertIsNotEnabled()
        compose.onNodeWithTag("photo-canvas").assertDoesNotExist()
        compose.onNodeWithTag("geometry.canvas").performTouchInput { swipe(center, Offset(centerX + 50f, centerY), 400) }
        compose.runOnIdle { assertTrue(state.draft!!.changed); assertEquals(edits, state.edits) }
        compose.onNodeWithTag("adjustment-dock").assertIsDisplayed()
        compose.onNodeWithTag("comparison-before").assertDoesNotExist()
    }

    @Test fun longPressReleaseDoesNotDispatchTheSingleTap() {
        editor()
        compose.onNodeWithTag("photo-canvas").performTouchInput { longClick(center, 800) }
        compose.onNodeWithTag("adjustment-dock").assertIsDisplayed()
        compose.onNodeWithTag("comparison-before").assertDoesNotExist()
    }
}
