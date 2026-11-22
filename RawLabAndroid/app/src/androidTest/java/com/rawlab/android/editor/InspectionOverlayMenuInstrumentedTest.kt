package com.rawlab.android.editor

import android.graphics.Bitmap
import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasParent
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import com.rawlab.android.RawLabTheme
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.ui.EditorScreen
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import java.io.File
import org.junit.Rule
import org.junit.Test

class InspectionOverlayMenuInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun workspaceOverlaySubmenuOpensAndSelectsOverlayWhileToolIsOpen() {
        val bitmap = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888)
        val edits = EditSettings()
        val state = EditorState(
            photo = ImportedPhoto(Uri.parse("content://rawlab.test/inspection-menu"), "fixture", File("fixture")),
            preview = PreviewPair(bitmap, bitmap, temperature = 6500f, tint = 0f),
            exact = true,
            edits = edits,
            draft = AdjustmentDraft(AdjustmentGroup.EXPOSURE, edits, edits),
        )
        compose.setContent {
            RawLabTheme {
                EditorScreen(
                    state = state,
                    onAlbum = {},
                    onFile = {},
                    onEdit = { _, _ -> },
                    onRetry = {},
                    onExport = {},
                    onMessageDismiss = {},
                    onLicenses = {},
                    onGpuChange = {},
                )
            }
        }
        compose.waitForIdle()
        compose.onNode(hasParent(hasTestTag("workspace-more")) and hasClickAction()).performClick()
        compose.onNodeWithTag("inspection-gray50-menu").assertIsDisplayed()
        compose.onNodeWithTag("inspection-overlay-menu").assertIsDisplayed().performClick()
        compose.onNodeWithTag("inspection-overlay-item-sketch_luminance").assertIsDisplayed().performClick()
        compose.onNodeWithTag("inspection-overlay-pill").assertIsDisplayed()
        compose.onNodeWithTag("workspace-more").assertIsDisplayed()
    }
}
