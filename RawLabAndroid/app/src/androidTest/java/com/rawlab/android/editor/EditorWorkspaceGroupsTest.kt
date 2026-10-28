package com.rawlab.android.editor

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.geometry.Offset
import com.rawlab.android.editor.controls.HslTargetActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.RawLabTheme
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.ui.EditorScreen
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.*
import com.rawlab.android.testing.LanguageTestRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File

class EditorWorkspaceGroupsTest {
    private val compose = createComposeRule()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(compose)
    private val bitmap = Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888)
    private val photo = ImportedPhoto(Uri.parse("content://workspace/groups"), "fixture", File("fixture"))
    private var state by mutableStateOf(EditorState(photo = photo,
        preview = PreviewPair(bitmap, bitmap, temperature = 5200f, tint = 8f), exact = true))
    private var edits = 0
    private var commits = 0
    private var draftApplies = 0
    private var draftDiscards = 0
    private var draftApplySucceeds = true
    private var delayReady = false
    private var begins = 0
    private var target by mutableStateOf(HslTargetState())
    private var targetBegins = 0
    private var targetEnds = 0
    private val targetMoves = mutableListOf<Float>()
    private fun session() = EditorResetSession(photo.identity, photo.file.absolutePath, 1, 1, state.edits,
        state.draft, 1, state.resetContext())
    private fun show() {
        compose.setContent {
            RawLabTheme { Surface { EditorScreen(state, {}, {}, { next, _ -> edits++; state = state.copy(edits = next) },
                {}, {}, {}, {}, {},
                hslTarget = HslTargetActions(target, enabled = { target = target.copy(enabled = it) },
                    axis = { target = target.copy(axis = it) }, begin = { _, _ -> targetBegins++ },
                    move = { targetMoves += it }, end = { targetEnds++ }),
                onBeginDraft = { group -> begins++; state = state.copy(draft = AdjustmentDraft.begin(group, state.edits)) },
                onDraftEdit = { next, _ -> state = state.copy(draft = state.draft?.update(next)) },
                onApplyDraft = { completed ->
                    if (draftApplySucceeds) { draftApplies++; state = state.copy(edits = state.visibleEdits, draft = null, exact = !delayReady, rendering = delayReady); completed(true) }
                    else completed(false)
                },
                onDiscardDraft = { draftDiscards++; state = state.copy(draft = null) },
                onPrepareReset = { scope -> EditorResetTransaction.prepare(scope, session()) },
                onCommitReset = { prepared ->
                    if (!prepared.matches(session())) false else {
                        commits++
                        state = if (prepared.draftCandidate != null) state.copy(draft = prepared.draftCandidate)
                        else state.copy(edits = prepared.result.candidate)
                        true
                    }
                }) } }
        }
    }
    private fun group(id: String) {
        compose.onNodeWithTag("editor-groups").performScrollToNode(hasTestTag("editor-group-$id"))
        compose.onNodeWithTag("editor-group-$id").performClick()
    }
    private fun tool(id: Int) {
        compose.onNodeWithTag("editor-tools").performScrollToNode(hasTestTag("editor-tool-$id"))
        compose.onNodeWithTag("editor-tool-$id").performClick()
    }
    private fun reset(scope: String) {
        compose.onNodeWithContentDescription("重置调整").performClick()
        compose.onNodeWithTag("editor-reset-$scope").performClick()
    }
    private fun dialog(label: String) = compose.onNode(hasText(label) and hasAnyAncestor(isDialog()))
    private fun capture(name: String) {
        val dir = File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "workspace-groups").apply { mkdirs() }
        File(dir, "$name.png").outputStream().use { compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    @Test fun collapsedHslTargetKeepsCanvasGestureAndExplicitExit() {
        show(); group("color"); tool(14)
        compose.onNodeWithTag("hsl-target").performScrollTo().performClick()
        compose.onNode(hasContentDescription("更多") and hasAnyAncestor(hasTestTag("adjustment-dock"))).performClick()
        compose.onNodeWithText("收起调整栏").performClick()
        compose.onNodeWithTag("hsl-target-canvas").assertIsDisplayed()
        compose.onNodeWithText("目标调整：色相").assertIsDisplayed()
        compose.onNodeWithTag("photo-canvas").performTouchInput {
            down(center); moveBy(Offset(0f, -30f)); up()
        }
        compose.runOnIdle { assertEquals(1, targetBegins); assertTrue(targetMoves.isNotEmpty()); assertEquals(1, targetEnds) }
        compose.onNodeWithTag("hsl-target-exit").performClick()
        compose.onNodeWithTag("hsl-target-canvas").assertDoesNotExist()
        compose.runOnIdle { assertFalse(target.enabled) }
    }

    @Test fun onePanelFineResetsOnlyAfterActualToolOrGroupNavigation() {
        show(); group("color"); tool(14)
        compose.onAllNodesWithTag("adjustment-fine").assertCountEquals(1)
        compose.onNodeWithTag("adjustment-fine").assertIsDisplayed().performClick().assertIsOn()
        compose.onNodeWithTag("hsl-channel-1").performClick()
        compose.onNodeWithTag("adjustment-fine").assertIsOn()
        tool(7)
        compose.onNodeWithTag("adjustment-fine").assertIsOff().performClick().assertIsOn()
        group("light")
        compose.onNodeWithTag("adjustment-fine").assertIsOff()
        compose.runOnIdle { assertEquals(0, edits); assertEquals(0, commits) }
    }

    @Test fun stayingInChangedGeometryRetainsFineWithoutCallbacks() {
        show(); group("geometry")
        compose.runOnIdle { state = state.copy(draft = state.draft!!.update(state.edits.copy(geometry = GeometrySettings(quarterTurns = 1)))) }
        compose.onNodeWithTag("adjustment-fine").assertIsDisplayed().performClick().assertIsOn()
        val draft = state.draft
        group("color"); dialog("继续编辑").performClick()
        compose.onNodeWithTag("editor-tool-17").assertIsSelected()
        compose.onNodeWithTag("adjustment-fine").assertIsOn()
        compose.runOnIdle { assertSame(draft, state.draft); assertEquals(0, edits); assertEquals(0, commits); assertEquals(0, draftApplies); assertEquals(0, draftDiscards) }
    }

    @Test fun anotherSourceWithTheSameHslValueCancelsTheOldDraftBeforeRebinding() {
        state = state.copy(edits = state.edits.copy(hsl = state.edits.hsl.withValue(0, 0, .5f)))
        show(); group("color"); tool(14)
        compose.onNodeWithTag("adjustment-value-${com.rawlab.android.R.string.hsl_hue}").performClick()
        compose.onNodeWithTag("adjustment-input").performTextReplacement("25")
        compose.runOnIdle { state = state.copy(photo = photo.copy(identity = PhotoIdentity("other-source"), file = File("other-fixture"))) }
        compose.onNodeWithTag("adjustment-input").assertDoesNotExist()
        compose.onNodeWithTag("adjustment-value-${com.rawlab.android.R.string.hsl_hue}").assertTextContains("0.5").performClick()
        compose.onNodeWithTag("adjustment-input-apply").performClick()
        compose.runOnIdle { assertEquals(.5f, state.edits.hsl.value(0, 0), 0f); assertEquals(0, edits); assertEquals(0, commits) }
    }

    @Test fun emptyWorkspaceHidesBothNavigationAndAdjustmentPanel() {
        state = EditorState()
        show()
        compose.onNodeWithTag("editor-groups").assertDoesNotExist()
        compose.onNodeWithTag("editor-tools").assertDoesNotExist()
        compose.onNodeWithTag("adjustment-dock").assertDoesNotExist()
        compose.onNodeWithText("选择照片").assertIsDisplayed()
    }

    @Test fun neutralLegacyAllResetKeepsTheSameUnchangedDraftWithNoNavigationEffects() = neutralAll(ProcessingIdentity.LEGACY)
    @Test fun neutralCurrentAllResetKeepsTheSameUnchangedDraftWithNoNavigationEffects() = neutralAll(ProcessingIdentity.CURRENT)
    private fun neutralAll(processing: ProcessingIdentity) {
        state = state.copy(edits = EditSettings(processing = processing))
        show(); group("geometry")
        compose.waitUntil { state.draft != null }
        val original = state.draft
        val initialBegins = begins
        reset("all")
        compose.waitForIdle()
        compose.runOnIdle {
            assertSame(original, state.draft)
            assertEquals(initialBegins, begins)
            assertEquals(0, draftDiscards); assertEquals(0, draftApplies); assertEquals(0, commits); assertEquals(0, edits)
        }
        compose.onNodeWithTag("editor-reset-confirm").assertDoesNotExist()
        compose.onNodeWithTag("editor-tool-17").assertIsSelected()
    }

    @Test fun pendingFullResetFreezesNavigationUntilExactReadyAndRestoresTheOriginalTool() {
        state = state.copy(edits = EditSettings(exposure = .5f))
        delayReady = true
        show(); group("geometry")
        compose.runOnIdle { state = state.copy(draft = state.draft!!.update(state.edits.copy(geometry = GeometrySettings(quarterTurns = 1)))) }
        reset("all"); dialog("应用").performClick()
        compose.onNodeWithTag("editor-reset-confirm").assertDoesNotExist()
        compose.onNodeWithTag("editor-groups").performScrollToNode(hasTestTag("editor-group-light"))
        compose.onNodeWithTag("editor-group-light").assertIsNotEnabled().performClick()
        compose.onNode(hasContentDescription("更多") and hasAnyAncestor(hasTestTag("adjustment-dock"))).assertIsNotEnabled().performClick()
        compose.onNodeWithContentDescription("重置调整").assertIsNotEnabled().performClick()
        compose.onNodeWithTag("editor-tool-17").assertIsSelected()
        compose.runOnIdle { state = state.copy(exact = true, rendering = false) }
        compose.onNodeWithTag("editor-reset-confirm").assertIsDisplayed()
        dialog("取消").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("editor-tool-17").assertIsSelected()
        compose.runOnIdle { assertNotNull(state.draft); assertFalse(state.draft!!.changed); assertEquals(1, draftApplies); assertEquals(0, commits) }
    }

    @Test fun sixGroupsChooseDefaultToolsKeepPanelBoundsAndNeverEdit() {
        show()
        val bounds = compose.onNodeWithTag("adjustment-dock").fetchSemanticsNode().boundsInRoot
        for ((group, tool) in listOf("looks" to 0, "light" to 2, "color" to 8, "effects" to 22, "detail" to 11, "geometry" to 17)) {
            if (group != "looks") group(group)
            compose.onNodeWithTag("editor-tool-$tool").assertIsSelected()
            assertEquals(bounds, compose.onNodeWithTag("adjustment-dock").fetchSemanticsNode().boundsInRoot)
            capture(group)
        }
        group("geometry")
        compose.onNodeWithTag("editor-tools").assertDoesNotExist()
        compose.onNodeWithTag("editor-group-geometry").assertExists()
        group("geometry")
        compose.onNodeWithTag("editor-tool-17").assertIsSelected()
        compose.runOnIdle { assertEquals(0, edits); assertEquals(0, commits); assertEquals(0, draftApplies) }
    }

    @Test fun hslChannelSurvivesNavigationAndResetCancelPreservesFractionalValues() {
        val hsl = HslSettings().withValue(0, 3, .5f).withValue(1, 5, 30f)
        state = state.copy(edits = EditSettings(hsl = hsl, saturation = .2f))
        show(); group("color"); tool(14)
        compose.onNodeWithTag("hsl-channels").performScrollToNode(hasTestTag("hsl-channel-3"))
        compose.onNodeWithTag("hsl-channel-3").performClick().assertIsSelected()
        group("light"); group("color"); tool(14)
        compose.onNodeWithTag("hsl-channel-3").assertIsSelected()
        reset("hsl"); dialog("取消").performClick()
        compose.onNodeWithTag("hsl-channel-3").assertIsSelected()
        compose.runOnIdle { assertEquals(hsl, state.edits.hsl); assertEquals(0, commits) }
        reset("channel")
        compose.runOnIdle {
            assertEquals(1, commits)
            assertEquals(hsl.withValue(0, 3, 0f), state.edits.hsl)
            assertEquals(.2f, state.edits.saturation)
        }
        compose.onNodeWithTag("hsl-channel-3").assertIsSelected()
    }

    @Test fun fullResetDiscardThenCancelRestoresFreshDraftWithoutUndoingDiscard() = fullResetCancel(false)
    @Test fun fullResetApplyThenCancelRestoresFreshDraftWithoutUndoingApply() = fullResetCancel(true)
    private fun fullResetCancel(apply: Boolean) {
        val source = EditSettings(exposure = .5f, processing = ProcessingIdentity.LEGACY)
        state = state.copy(edits = source)
        show(); group("geometry")
        val editedGeometry = GeometrySettings(quarterTurns = 1)
        compose.runOnIdle { state = state.copy(draft = state.draft!!.update(source.copy(geometry = editedGeometry))) }
        reset("all")
        dialog(if (apply) "应用" else "放弃修改").performClick()
        compose.onNodeWithTag("editor-reset-confirm").assertIsDisplayed()
        compose.runOnIdle { assertNull(state.draft) }
        dialog("取消").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("editor-tool-17").assertIsSelected()
        compose.runOnIdle {
            assertNotNull(state.draft); assertFalse(state.draft!!.changed)
            assertEquals(source.copy(geometry = if (apply) editedGeometry else source.geometry), state.edits)
            assertEquals(state.edits, state.draft!!.original)
            assertEquals(if (apply) 1 else 0, draftApplies)
            assertEquals(if (apply) 0 else 1, draftDiscards)
            assertEquals(0, commits)
        }
    }

    @Test fun fullResetStayAndFailedApplyPreserveDraftThenRetryExecutesOnce() {
        val source = EditSettings(exposure = .5f, processing = ProcessingIdentity.LEGACY)
        state = state.copy(edits = source)
        show(); group("geometry")
        compose.runOnIdle { state = state.copy(draft = state.draft!!.update(source.copy(geometry = GeometrySettings(quarterTurns = 1)))) }
        val draft = state.draft
        reset("all"); dialog("继续编辑").performClick()
        compose.runOnIdle { assertEquals(draft, state.draft); draftApplySucceeds = false }
        reset("all"); dialog("应用").performClick()
        compose.runOnIdle { assertEquals(draft, state.draft); assertEquals(0, draftApplies) }
        compose.onNodeWithTag("editor-reset-confirm").assertDoesNotExist()
        compose.runOnIdle { draftApplySucceeds = true }
        dialog("应用").performClick()
        compose.onNodeWithTag("editor-reset-confirm").performClick()
        compose.waitForIdle()
        compose.runOnIdle {
            assertEquals(1, draftApplies); assertEquals(1, commits)
            assertEquals(ProcessingIdentity.LEGACY, state.edits.processing)
            assertEquals(EditSettings(processing = ProcessingIdentity.LEGACY, temperature = 5200f, tint = 8f), state.edits)
            assertNotNull(state.draft); assertFalse(state.draft!!.changed)
        }
    }

    @Test fun recipeToolResetRequiresMaterializationConfirmationAndPreservesOtherGroups() {
        val source = EditSettings(recipeID = "fixture-recipe", strength = .5f, exposure = .75f,
            processing = ProcessingIdentity.LEGACY)
        state = state.copy(edits = source)
        show(); tool(15)
        reset("tool")
        compose.onNodeWithTag("editor-reset-confirm").assertIsDisplayed()
        dialog("取消").performClick()
        compose.runOnIdle { assertEquals(source, state.edits); assertEquals(0, commits) }
        reset("tool")
        compose.onNodeWithTag("editor-reset-confirm").performClick()
        compose.runOnIdle {
            assertEquals(source.copy(recipeID = null, strength = 1f, exposure = .375f), state.edits)
            assertEquals(1, commits)
        }
        compose.onNodeWithTag("editor-tool-15").assertIsSelected()
    }

    @Test fun recipeToolBlockedByMissingCalibrationOffersASeparateAllConfirmation() {
        state = state.copy(edits = EditSettings(recipeID = "fixture-recipe", strength = .5f, tint = 8f),
            preview = PreviewPair(bitmap, bitmap, temperature = Float.NaN, tint = Float.NaN))
        show(); tool(15)
        reset("tool")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        compose.onNodeWithText(context.getString(com.rawlab.android.R.string.editor_reset_missing_wb)).assertIsDisplayed()
        compose.onNodeWithText(context.getString(com.rawlab.android.R.string.editor_reset_all)).performClick()
        compose.onNodeWithTag("editor-reset-confirm").assertIsDisplayed()
        dialog("取消").performClick()
        compose.runOnIdle { assertEquals("fixture-recipe", state.edits.recipeID); assertEquals(0, commits) }
        compose.onNodeWithTag("editor-tool-15").assertIsSelected()
    }

    @Test fun staleConfirmationCannotOverwriteNewProcessingIdentity() {
        state = state.copy(edits = EditSettings(exposure = .5f))
        show(); group("light"); reset("group")
        compose.runOnIdle { state = state.copy(edits = state.edits.copy(processing = ProcessingIdentity.LEGACY)) }
        compose.onNodeWithTag("editor-reset-confirm").performClick()
        compose.runOnIdle { assertEquals(.5f, state.edits.exposure); assertEquals(0, commits) }
        dialog("确定").performClick()
        compose.onNodeWithTag("editor-tool-2").assertIsSelected()
    }
}
