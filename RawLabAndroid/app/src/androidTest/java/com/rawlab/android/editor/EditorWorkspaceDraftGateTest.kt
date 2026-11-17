package com.rawlab.android.editor

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.editor.render.RenderQueue
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.settings.EditStore
import com.rawlab.android.testing.ForegroundTestRule
import com.rawlab.android.testing.openWorkbenchTool
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Real controls, production callbacks/model/store; no fabricated EditorState or timing sleeps. */
class EditorWorkspaceDraftGateTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rules: RuleChain = RuleChain.outerRule(ForegroundTestRule()).around(compose)

    @Suppress("UNCHECKED_CAST")
    private fun queue(model: EditorViewModel) = EditorViewModel::class.java.getDeclaredField("queue")
        .apply { isAccessible = true }.get(model) as RenderQueue<Work, WorkResult>

    private fun block(model: EditorViewModel): CountDownLatch {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        queue(model).performAfterPending {
            entered.countDown()
            check(release.await(45, TimeUnit.SECONDS)) { "render barrier timed out" }
        }
        assertTrue("render barrier entered", entered.await(10, TimeUnit.SECONDS))
        return release
    }

    @Test fun navigationWindowCannotCommitAndDraftRenderingStillAcceptsEdits() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val source = File(context.cacheDir, "workspace-gate-${UUID.randomUUID()}.png")
        Bitmap.createBitmap(80, 60, Bitmap.Config.ARGB_8888).let { bitmap ->
            bitmap.eraseColor(0xff777777.toInt())
            source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
        val store = EditStore(File(context.filesDir, "edits"))
        val model = compose.activity.model
        var release: CountDownLatch? = null
        try {
            compose.runOnIdle { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            compose.waitUntil(30_000) { model.state.value.canExport }
            val photo = requireNotNull(model.state.value.photo)
            val baseline = model.state.value.edits
            val saved = store.readState(photo.identity)
            compose.openWorkbenchTool(5)
            compose.waitUntil(10_000) { model.state.value.draft?.group == AdjustmentGroup.CONTRAST }
            compose.onNodeWithTag("adjustment-slider").performScrollTo()
                .performSemanticsAction(SemanticsActions.SetProgress) { it(30f) }
            compose.waitUntil(30_000) { model.state.value.draftReady }
            assertTrue(model.state.value.draft!!.changed)
            release = block(model)
            InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
            compose.onNodeWithText(compose.activity.getString(R.string.adjustment_discard)).performClick()
            compose.openWorkbenchTool(2)
            val ruler = compose.onNodeWithTag("adjustment-slider").performScrollTo()
            compose.runOnIdle {
                val state = model.state.value
                assertNull(state.draft)
                assertTrue(state.rendering)
                assertTrue(state.controlsEnabled)
                assertFalse(state.canExport)
                assertEquals(baseline, state.edits)
            }
            // Exercise the actual touch target before asserting disabled, so the old build
            // fails on committed state/store behavior rather than only a visual property.
            ruler.performTouchInput { swipe(center, centerRight - androidx.compose.ui.geometry.Offset(30f, 0f), 250) }
            compose.waitUntil(10_000) { !model.state.value.committingAdjustments }
            compose.runOnIdle {
                assertEquals("pending workspace must not persist (model=${model.state.value.edits})", saved, store.readState(photo.identity))
                assertEquals("pending workspace must not write committed edits", baseline, model.state.value.edits)
            }
            ruler.assertIsNotEnabled()
            compose.onNodeWithTag("adjustment-value-${R.string.exposure}").assertIsNotEnabled()
            release.countDown(); release = null
            compose.waitUntil(30_000) { model.state.value.draft?.group == AdjustmentGroup.EXPOSURE && model.state.value.draftReady }

            release = block(model)
            ruler.assertIsEnabled().performSemanticsAction(SemanticsActions.SetProgress) { it(.5f) }
            compose.runOnIdle { assertTrue(model.state.value.rendering); assertFalse(model.state.value.canExport) }
            ruler.assertIsEnabled().performSemanticsAction(SemanticsActions.SetProgress) { it(1f) }
            compose.runOnIdle {
                assertEquals(1f, model.state.value.visibleEdits.exposure, 0f)
                assertEquals(baseline, model.state.value.edits)
                assertEquals(saved, store.readState(photo.identity))
            }
            compose.onNodeWithTag("draft.cancel").performClick()
            compose.runOnIdle {
                assertNull(model.state.value.draft)
                assertEquals(baseline, model.state.value.edits)
                assertEquals("Cancel must not save", saved, store.readState(photo.identity))
            }
            release.countDown(); release = null
            compose.waitUntil(30_000) { model.state.value.canExport }
            compose.openWorkbenchTool(2)
            compose.waitUntil(10_000) { model.state.value.draft?.group == AdjustmentGroup.EXPOSURE }
            compose.onNodeWithTag("adjustment-slider").performScrollTo()
                .performSemanticsAction(SemanticsActions.SetProgress) { it(.75f) }
            compose.waitUntil(30_000) { model.state.value.draftReady }
            assertEquals("before Apply the disk baseline is unchanged", saved, store.readState(photo.identity))
            compose.onNodeWithTag("draft.apply").performClick()
            compose.waitUntil(30_000) { model.state.value.draft == null && !model.state.value.committingAdjustments }
            compose.runOnIdle {
                assertEquals(.75f, model.state.value.edits.exposure, 0f)
                assertEquals(.75f, requireNotNull(store.readState(photo.identity).settings).exposure, 0f)
                assertNotEquals(saved, store.readState(photo.identity))
            }
            compose.waitUntil(30_000) { model.state.value.canExport }
            // Quick presets own their direct-commit workflow, not a tool workspace draft.
            compose.onNodeWithTag("editor-group-looks").performScrollTo().performClick()
            compose.openWorkbenchTool(0)
            compose.waitUntil(10_000) { model.state.value.draft?.group == AdjustmentGroup.LOOK }
            compose.onNodeWithTag("workspace-more").performClick()
            compose.onNodeWithTag("workspace-presets").performClick()
            compose.waitUntil(10_000) { model.quickPreset.value.visible }
            compose.onNodeWithTag("preset.quick.manage").assertIsDisplayed().assertIsEnabled()
            InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
            compose.waitUntil(10_000) { !model.quickPreset.value.visible }
            compose.onNodeWithTag("draft.cancel").performClick()
        } finally {
            release?.countDown()
            compose.runOnIdle { model.state.value.photo?.let { store.reset(it.identity) } }
            source.delete()
        }
    }
}
