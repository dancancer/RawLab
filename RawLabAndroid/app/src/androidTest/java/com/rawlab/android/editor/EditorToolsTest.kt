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
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.onAllNodesWithText
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
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.graphics.asAndroidBitmap
import org.junit.Assert.assertTrue

@RunWith(AndroidJUnit4::class)
class EditorToolsTest {
    val compose = createComposeRule()
    @get:Rule val languageAndCompose = org.junit.rules.RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test fun atmosphereToolsEditIndependentlyAndKeepRoundedOriginalPrecision() {
        val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
        var edits by mutableStateOf(EditSettings(clarity = 37.251234f, dehaze = -42.5f))
        var commits = 0
        compose.setContent { RawLabTheme {
            EditorScreen(state = EditorState(
                photo = ImportedPhoto(Uri.parse("content://rawlab.test/atmosphere"), "fixture", File("fixture")),
                edits = edits, preview = PreviewPair(bitmap, bitmap, temperature = 6500f, tint = 0f), exact = true),
                onAlbum = {}, onFile = {}, onEdit = { next, dragging -> edits = next; if (!dragging) commits++ }, onRetry = {},
                onExport = {}, onMessageDismiss = {}, onLicenses = {}, onGpuChange = {})
        } }
        compose.onNodeWithTag("editor-group-effects").performClick()
        compose.onNodeWithTag("editor-tool-22").assertIsSelected()
        compose.onNodeWithTag("adjustment-value-${com.rawlab.android.R.string.clarity}").assertTextContains("37.25").performClick()
        compose.onNodeWithTag("adjustment-input-apply").performClick()
        compose.runOnIdle { assertEquals(37.251234f, edits.clarity); assertEquals(0, commits) }
        compose.onNodeWithTag("editor-tool-23").performClick()
        compose.onNodeWithTag("adjustment-value-${com.rawlab.android.R.string.dehaze}").assertTextContains("-42.5").performClick()
        compose.onNodeWithTag("adjustment-input").performTextReplacement("-25")
        compose.onNodeWithTag("adjustment-input-apply").performClick()
        compose.runOnIdle { assertEquals(-25f, edits.dehaze); assertEquals(37.251234f, edits.clarity); assertEquals(1, commits) }
        compose.onNodeWithTag("editor-tool-22").performClick()
        compose.onNodeWithTag("adjustment-value-${com.rawlab.android.R.string.clarity}").performClick()
        compose.onNodeWithTag("adjustment-input").performTextReplacement("-30")
        compose.onNodeWithTag("adjustment-input-apply").performClick()
        compose.runOnIdle { assertEquals(-30f, edits.clarity); assertEquals(-25f, edits.dehaze); assertEquals(2, commits) }
    }

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
                    onAlbum = {}, onFile = {}, onEdit = { next, _ -> edits = next }, onRetry = {},
                    onExport = {}, onMessageDismiss = {}, onLicenses = {}, onGpuChange = {},
                    onPrepareReset = { scope -> EditorResetTransaction.prepare(scope, EditorResetSession(
                        com.rawlab.android.settings.PhotoIdentity("fixture"), "fixture", 1, 1, edits, null, 0,
                        EditorResetContext(com.rawlab.android.format.PhotoInputKind.RAW, EditSettings(), AsShotWhiteBalance(6500f, 0f)))) },
                    onCommitReset = { prepared -> edits = prepared.result.candidate; true },
                )
            }
        }
        compose.onNodeWithContentDescription("全部工具").performClick()
        compose.onNodeWithContentDescription("白平衡").performClick()
        compose.onNodeWithText("色温").assertIsDisplayed()
        compose.onNodeWithText("色调").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("拍摄时设置").performClick()
        compose.runOnIdle {
            assertFalse(edits.customWb)
            assertEquals(6500f, edits.temperature)
            assertEquals(0f, edits.tint)
        }
    }

    // “更多”菜单每一项都带前置图标：文字落在同一列，不出现缩进不一的条目
    @Test fun moreMenuItemsShareOneTextColumn() {
        compose.setContent {
            RawLabTheme {
                EditorScreen(state = EditorState(), onAlbum = {}, onFile = {}, onEdit = { _, _ -> }, onRetry = {},
                    onExport = {}, onMessageDismiss = {}, onLicenses = {}, onGpuChange = {}, updateVersion = "9.9.9")
            }
        }
        compose.onNodeWithContentDescription("更多").performClick()
        val lefts = listOf("从文件导入", "批量导出", "设置", "开源许可", "关于 RawLab", "查看更新").associateWith { label ->
            compose.onAllNodesWithText(label, useUnmergedTree = true).fetchSemanticsNodes().last().boundsInRoot.left
        }
        assertEquals(lefts.toString(), 1, lefts.values.distinct().size)
    }

    // 面板重置保留可见入口；单参数重置通过语义动作提供，避免每行常驻按钮。
    @Test fun headerResetRemainsVisibleAndParameterResetIsASemanticAction() {
        val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
        compose.setContent {
            RawLabTheme {
                EditorScreen(
                    state = EditorState(
                        photo = ImportedPhoto(Uri.parse("content://rawlab.test/reset"), "fixture", File("fixture")),
                        edits = EditSettings(exposure = .5f),
                        preview = PreviewPair(bitmap, bitmap, temperature = 6500f, tint = 0f),
                        exact = true,
                    ),
                    onAlbum = {}, onFile = {}, onEdit = { _, _ -> }, onRetry = {},
                    onExport = {}, onMessageDismiss = {}, onLicenses = {}, onGpuChange = {},
                )
            }
        }
        compose.onNodeWithTag("editor-group-light").performClick()
        compose.onNodeWithContentDescription("重置调整").assertIsDisplayed()
        compose.onAllNodesWithContentDescription("重置此项").assertCountEquals(0)
        val actions = compose.onNodeWithTag("adjustment-slider").fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsActions.CustomActions]
        assertEquals(listOf("重置此项"), actions.map { it.label })
    }

    // 与 Mac、iOS 一致：“已调整”标记是工具名下方单独的小圆点，在圆圈外面；没调整时透明但仍占位，切换时工具条不跳动
    @Test fun changedMarkerSitsBelowTheTitleOutsideTheRing() {
        val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
        val state = EditorState(
            photo = ImportedPhoto(Uri.parse("content://rawlab.test/marker"), "fixture", File("fixture")),
            edits = EditSettings(exposure = .5f),
            preview = PreviewPair(bitmap, bitmap, temperature = 6500f, tint = 0f),
        )
        compose.setContent { RawLabTheme { Surface { EditorToolStrip(state, selected = 2, tools = EditorAdjustmentRules.tools(EditorAdjustmentGroup.LIGHT)) {} } } }
        fun bounds(tag: String) = compose.onNodeWithTag(tag, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        val ring = bounds("editor-tool-ring-2")
        val marker = bounds("editor-tool-marker-2")
        val title = compose.onAllNodesWithText("曝光", useUnmergedTree = true).fetchSemanticsNodes().single().boundsInRoot
        assertTrue("marker $marker must be below the title $title", marker.top >= title.bottom)
        assertTrue("marker $marker must be outside the ring $ring", marker.top >= ring.bottom)
        assertEquals("unchanged tools keep the marker slot", bounds("editor-tool-2").height, bounds("editor-tool-3").height)
        assertEquals(bounds("editor-tool-marker-2").height, bounds("editor-tool-marker-3").height)
    }
}
