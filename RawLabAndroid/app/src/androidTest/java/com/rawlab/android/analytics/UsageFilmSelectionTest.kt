package com.rawlab.android.analytics

import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import java.io.File
import com.rawlab.android.RawLabTheme
import com.rawlab.android.editor.EditorState
import com.rawlab.android.editor.AdjustmentDraft
import com.rawlab.android.editor.AdjustmentGroup
import com.rawlab.android.settings.EditSettings
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
                        draft = AdjustmentDraft.begin(AdjustmentGroup.LOOK, EditSettings()),
                    ),
                    onAlbum = {}, onFile = {}, onEdit = { _, _ -> edits++ },
                    onRetry = {}, onExport = {}, onFilmSelected = { events++ },
                    onSelectFilm = { edits++; true },
                    onMessageDismiss = {}, onLicenses = {}, onGpuChange = {},
                )
            }
        }
        compose.onNodeWithText("Missing look").assertExists()
        compose.onNodeWithTag("looks.search.open").assertIsEnabled().performClick()
        compose.onNodeWithTag("looks.search").performTextReplacement("Missing look")
        compose.onNode(hasText("Missing look") and !hasSetTextAction()).assertIsNotEnabled().performTouchInput { click() }
        compose.runOnIdle {
            assertEquals(0, edits)
            assertEquals(0, events)
        }
    }
}
