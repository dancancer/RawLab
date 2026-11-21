package com.rawlab.android.export

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.editor.Operation
import com.rawlab.android.editor.SingleExportStep
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.testing.ForegroundTestRule
import com.rawlab.android.testing.LanguageTestRule
import com.rawlab.android.testing.waitUntilEditorReady
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File
import java.util.UUID

class SingleExportStepInstrumentedTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(ForegroundTestRule()).around(compose)

    @Test fun exportSheetSurvivesActivityRecreationAndDestinationPickReturn() {
        var activity = compose.activity
        var model = activity.model
        val source = File(activity.cacheDir, "export-step-${UUID.randomUUID()}.png").also { file ->
            Bitmap.createBitmap(96, 64, Bitmap.Config.ARGB_8888).let { bitmap ->
                bitmap.eraseColor(0xFF336699.toInt())
                file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                bitmap.recycle()
            }
        }
        try {
            compose.runOnUiThread {
                model.setGpuEnabled(false)
                model.importPhoto(Uri.fromFile(source))
            }
            compose.waitUntilEditorReady(model)

            compose.onNodeWithContentDescription(activity.getString(R.string.export)).assertIsEnabled().performClick()
            compose.waitUntil(10_000) {
                compose.onAllNodesWithTag("export-format-JPEG").fetchSemanticsNodes().isNotEmpty()
            }
            assertEquals(Operation.PICK_EXPORT, model.state.value.operation)
            assertEquals(SingleExportStep.OPTIONS, model.state.value.exportStep)
            assertTrue(model.state.value.exportOptionsVisible)

            compose.onNodeWithTag("export-format-PNG").performScrollTo().performClick().assertIsSelected()

            compose.activityRule.scenario.recreate()
            compose.activityRule.scenario.onActivity {
                activity = it
                model = it.model
            }
            assertEquals(Operation.PICK_EXPORT, model.state.value.operation)
            assertEquals(SingleExportStep.OPTIONS, model.state.value.exportStep)
            assertTrue(model.state.value.exportOptionsVisible)
            compose.onNodeWithTag("export-format-JPEG").assertIsDisplayed()
            compose.onNodeWithTag("export-format-PNG").assertIsSelected()

            compose.runOnUiThread { model.beginExportDestinationPick() }
            compose.waitUntil(10_000) {
                compose.onAllNodesWithTag("export-format-JPEG").fetchSemanticsNodes().isEmpty()
            }
            assertEquals(Operation.PICK_EXPORT, model.state.value.operation)
            assertEquals(SingleExportStep.PICKING_DESTINATION, model.state.value.exportStep)
            assertFalse(model.state.value.exportOptionsVisible)

            compose.activityRule.scenario.recreate()
            compose.activityRule.scenario.onActivity {
                activity = it
                model = it.model
            }
            assertEquals(Operation.PICK_EXPORT, model.state.value.operation)
            assertEquals(SingleExportStep.PICKING_DESTINATION, model.state.value.exportStep)
            assertFalse(model.state.value.exportOptionsVisible)
            compose.onNodeWithTag("export-format-JPEG").assertDoesNotExist()

            compose.runOnUiThread { model.returnToExportOptions() }
            compose.waitUntil(10_000) {
                compose.onAllNodesWithTag("export-format-JPEG").fetchSemanticsNodes().isNotEmpty()
            }
            assertEquals(Operation.PICK_EXPORT, model.state.value.operation)
            assertEquals(SingleExportStep.OPTIONS, model.state.value.exportStep)
            assertTrue(model.state.value.exportOptionsVisible)
            compose.onNodeWithTag("export-format-PNG").assertIsSelected()

            compose.onNodeWithText(activity.getString(R.string.cancel)).performClick()
            compose.waitUntil(10_000) { model.state.value.operation == Operation.NONE }
            assertEquals(SingleExportStep.NONE, model.state.value.exportStep)
            assertFalse(model.state.value.exportOptionsVisible)
            compose.onNodeWithTag("export-format-JPEG").assertDoesNotExist()
        } finally {
            EditStore(File(activity.filesDir, "edits")).reset(PhotoIdentity(Uri.fromFile(source).toString()))
            source.delete()
        }
    }
}
