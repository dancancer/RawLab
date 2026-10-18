package com.rawlab.android.editor

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.assert
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.compose.material3.Surface
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import com.rawlab.android.RawLabTheme
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.ui.EditorScreen
import com.rawlab.android.editor.ui.EditorToolStrip
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.testing.LanguageTestRule

@RunWith(AndroidJUnit4::class)
class EditorToolsTest {
    val compose = createComposeRule()
    @get:Rule val languageAndCompose = org.junit.rules.RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test fun whiteBalanceToolHasOneSelectedAccessibleEntryAndOneChangedIndicator() {
        val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
        val state = EditorState(
            photo = ImportedPhoto(Uri.parse("content://rawlab.test/wb"), "fixture", File("fixture")),
            edits = EditSettings(customWb = true, temperature = 7200f, tint = 15f),
            preview = PreviewPair(bitmap, bitmap, temperature = 6500f, tint = 0f),
        )
        compose.setContent {
            RawLabTheme { Surface { EditorToolStrip(state, selected = 8) {} } }
        }
        compose.onAllNodesWithContentDescription("白平衡").assertCountEquals(1)
        compose.onAllNodesWithContentDescription("色温").assertCountEquals(0)
        compose.onAllNodesWithContentDescription("色调").assertCountEquals(0)
        compose.onNodeWithContentDescription("白平衡").assertIsDisplayed().assertIsSelected()
        compose.onNodeWithContentDescription("白平衡").assert(
            SemanticsMatcher("white balance reports changed") { node ->
                node.config.getOrNull(SemanticsProperties.StateDescription)?.contains("已调整") == true
            }
        )
    }

    @Test fun whiteBalancePanelKeepsBothAxesAndAsShotResetsTheGroup() {
        val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
        var edits by mutableStateOf(EditSettings(customWb = true, temperature = 7200f, tint = 15f))
        compose.setContent {
            RawLabTheme {
                EditorScreen(
                    state = EditorState(
                        photo = ImportedPhoto(Uri.parse("content://rawlab.test/wb-panel"), "fixture", File("fixture")),
                        edits = edits,
                        preview = PreviewPair(bitmap, bitmap, temperature = 6500f, tint = 0f),
                        exact = true,
                    ),
                    onAlbum = {}, onFile = {}, onEdit = { next, _ -> edits = next }, onReset = {}, onRetry = {},
                    onExport = {}, onMessageDismiss = {}, onLicenses = {}, onGpuChange = {},
                )
            }
        }
        compose.onNodeWithContentDescription("全部工具").performClick()
        compose.onNodeWithContentDescription("白平衡").performClick()
        compose.onNodeWithText("色温").assertIsDisplayed()
        compose.onNodeWithText("色调").assertIsDisplayed()
        compose.onNodeWithText("拍摄时设置").performClick()
        compose.runOnIdle {
            assertFalse(edits.customWb)
            assertEquals(6500f, edits.temperature)
            assertEquals(0f, edits.tint)
        }
    }
}
