package com.rawlab.android.analytics

import android.net.Uri
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.click
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import java.io.File
import com.rawlab.android.RawLabTheme
import com.rawlab.android.editor.EditorState
import com.rawlab.android.editor.ui.EditorScreen
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.LookChoice

class UsageFilmSelectionTest {
    @get:Rule val compose = createComposeRule()

    @Test fun missingCustomLookCannotProduceASelectionEvent() {
        var edits = 0
        var events = 0
        compose.setContent {
            RawLabTheme {
                EditorScreen(
                    state = EditorState(
                        photo = ImportedPhoto(Uri.parse("content://fixture/photo"), "Fixture", File("unused")),
                        looks = listOf(LookChoice("missing", "Missing look", managed = true, available = false)),
                    ),
                    onAlbum = {}, onFile = {}, onEdit = { _, _ -> edits++ }, onReset = {},
                    onRetry = {}, onExport = {}, onFilmSelected = { events++ },
                    onMessageDismiss = {}, onLicenses = {}, onGpuChange = {},
                )
            }
        }
        compose.onNodeWithText("Missing look").assertIsNotEnabled().performTouchInput { click() }
        compose.runOnIdle {
            assertEquals(0, edits)
            assertEquals(0, events)
        }
    }
}
