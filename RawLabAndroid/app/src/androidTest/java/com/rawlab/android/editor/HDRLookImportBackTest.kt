package com.rawlab.android.editor

import android.graphics.Bitmap
import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.compose.runtime.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import com.rawlab.android.RawLabTheme
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.ui.EditorScreen
import com.rawlab.android.photo.ImportedPhoto
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class HDRLookImportBackTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun backDuringHDRLookImportCancelsTheImport() {
        val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
        var state by mutableStateOf(EditorState(
            photo = ImportedPhoto(Uri.parse("content://rawlab.test/hdr-look-back"), "fixture", File("fixture")),
            preview = PreviewPair(bitmap, bitmap, temperature = 6500f, tint = 0f), exact = true,
            operation = Operation.IMPORT_LOOK, importingHDRLook = true))
        var cancels = 0
        compose.setContent {
            RawLabTheme { EditorScreen(state, {}, {}, { _, _ -> }, {}, {}, {}, {}, {},
                onCancelHDRLookImport = { cancels++; state = state.copy(operation = Operation.NONE, importingHDRLook = false) }) }
        }
        compose.waitForIdle()
        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.runOnIdle {
            assertEquals(1, cancels)
            assertEquals(Operation.NONE, state.operation)
        }
    }
}
