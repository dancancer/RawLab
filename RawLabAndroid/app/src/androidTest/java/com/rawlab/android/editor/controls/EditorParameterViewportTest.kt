package com.rawlab.android.editor.controls

import android.content.res.Configuration
import java.util.Locale
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.RawLabTheme
import com.rawlab.android.editor.*
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.ui.EditorScreen
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.testing.LanguageTestRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File

class EditorParameterViewportTest {
    private val compose = createComposeRule()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test fun portrait320Normal() = verify(320, 720, 1f)
    @Test fun portrait360Normal() = verify(360, 720, 1f)
    @Test fun portrait320LargeText() = verify(320, 720, 1.6f)
    @Test fun portrait360LargeText() = verify(360, 720, 1.6f)
    @Test fun sideLandscapeNormal() = verify(960, 360, 1f, true)
    @Test fun bottomLandscapeNormal() = verify(560, 360, 1f)
    @Test fun bottomLandscapeLargeText() = verify(640, 360, 1.6f)

    @Test fun bottomLandscapeLongLabels() = verify(640, 360, 1.6f, language = "de")
    @Test fun bottomLandscapeFrench() = verify(640, 360, 1.6f, language = "fr")
    @Test fun bottomLandscapeEnglish() = verify(640, 360, 1.6f, language = "en")
    @Test fun bottomLandscapeJapanese() = verify(640, 360, 1.6f, language = "ja")
    @Test fun bottomLandscapeSpanish() = verify(640, 360, 1.6f, language = "es")

    private fun verify(width: Int, height: Int, scale: Float, side: Boolean = false, language: String = "zh-Hans") {
        val bitmap = Bitmap.createBitmap(60, 90, Bitmap.Config.ARGB_8888)
        var state by mutableStateOf(EditorState(photo = ImportedPhoto(Uri.parse("content://layout/parameters"), "fixture", File("fixture")),
            preview = PreviewPair(bitmap, bitmap, 5200f, 8f), exact = true))
        compose.setContent {
            val base = LocalContext.current
            val config = Configuration(LocalConfiguration.current).apply { setLocale(Locale.forLanguageTag(language)); fontScale = scale }
            CompositionLocalProvider(LocalDensity provides Density(1f, scale), LocalContext provides base.createConfigurationContext(config), LocalConfiguration provides config) {
                Box(Modifier.size(width.dp, height.dp).consumeWindowInsets(WindowInsets.safeDrawing).testTag("parameter-fixture")) {
                    RawLabTheme {
                        EditorScreen(state, {}, {}, { _, _ -> }, {}, {}, {}, {}, {},
                            onBeginDraft = { state = state.copy(draft = AdjustmentDraft.begin(it, state.edits)) },
                            onDiscardDraft = { state = state.copy(draft = null) })
                    }
                }
            }
        }
        fun bounds(tag: String) = compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot
        fun group(id: String) {
            val target = compose.onNodeWithTag("editor-group-$id")
            if (compose.onNodeWithTag("editor-groups").fetchSemanticsNode().config.contains(SemanticsProperties.HorizontalScrollAxisRange))
                compose.onNodeWithTag("editor-groups").performScrollToNode(hasTestTag("editor-group-$id"))
            target.performClick()
        }
        val dock = bounds("adjustment-dock")
        val canvas = bounds("editor-canvas")
        assertTrue("$width/$height/$scale uses the expected measured layout", if (side) canvas.right <= dock.left else canvas.bottom <= dock.top)
        assertTrue("The photo keeps the existing 30% content-height floor", canvas.height >= (canvas.height + dock.height) * .3f - 2)
        for ((group, tools) in listOf("looks" to listOf(0, 15, 1), "light" to listOf(2, 3, 4, 5, 6),
            "color" to listOf(8, 7, 14), "effects" to listOf(12, 13), "detail" to listOf(11, 10), "geometry" to listOf(17, 16))) {
            if (group != "looks") group(group)
            for (tool in tools) {
                compose.onNodeWithTag("editor-tools").performScrollToNode(hasTestTag("editor-tool-$tool"))
                compose.onNodeWithTag("editor-tool-$tool").performClick()
                assertEquals("Tool $tool does not move the dock", dock, bounds("adjustment-dock"))
                assertEquals("Tool $tool does not move the photo", canvas, bounds("editor-canvas"))
                val ring = compose.onNodeWithTag("editor-tool-ring-$tool", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                assertEquals("Ordinary tool rings stay 48dp", 48f, ring.height, 1f)
                for (tag in listOf("editor-tool-label-$tool", "editor-group-label-$group")) {
                    val layouts = mutableListOf<TextLayoutResult>()
                    val label = compose.onNodeWithTag(tag, useUnmergedTree = true)
                    label.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                    assertTrue("Label has a real measured layout: $tag", layouts.isNotEmpty())
                    val visible = label.fetchSemanticsNode().boundsInRoot
                    // SimpleTextNode 可报告 didOverflowWidth=true，即便24px文字框的实际行边界仅22.5px；核对真实行及裁切矩形。
                    for (layout in layouts) {
                        val widest = (0 until layout.lineCount).maxOf { layout.getLineRight(it) - layout.getLineLeft(it) }
                        assertFalse("$tag must not truncate height", layout.didOverflowHeight)
                        assertTrue("$width/$height/$scale/$tag complete label: $visible layout=${layout.size} lines=${layout.lineCount}",
                            (0 until layout.lineCount).all { !layout.isLineEllipsized(it) && layout.getLineLeft(it) >= -1 && layout.getLineRight(it) <= layout.size.width + 1 } &&
                                visible.width >= widest - 1 && visible.height >= layout.size.height - 1)
                    }
                }
                val groupRing = compose.onNodeWithTag("editor-group-ring-$group", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                val glyph = compose.onNodeWithTag("editor-group-icon-$group", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                assertEquals(if (side) 24f else 48f, groupRing.width, 1f)
                assertEquals(if (side) 24f else 48f, groupRing.height, 1f)
                assertEquals(24f, glyph.width, 1f); assertEquals(24f, glyph.height, 1f)
                for (tag in listOf("editor-tool-$tool", "editor-group-$group")) {
                    val node = compose.onNodeWithTag(tag)
                    val clipped = node.fetchSemanticsNode().boundsInRoot
                    val full = node.getUnclippedBoundsInRoot()
                    assertTrue("$width/$height/$scale/$language/$tag whole touch target: $clipped vs $full", clipped.width >= (full.right - full.left).value - 1 && clipped.height >= (full.bottom - full.top).value - 1 && clipped.height >= 48f)
                    android.util.Log.i("RawLabNavigationEvidence", "$width/$height/$scale/$language/$tag item=$clipped full=$full groupViewport=${bounds("editor-groups")} toolsViewport=${bounds("editor-tools")} groupRing=$groupRing toolRing=$ring glyph=$glyph")
                }
                val viewport = bounds("editor-parameters")
                android.util.Log.i("RawLabViewportRed", "$width/$height/$scale/tool=$tool photo=$canvas dock=$dock viewport=$viewport")
                assertTrue("$width/$height/$scale/tool=$tool parameter viewport needs a complete 48dp operation row: $viewport", viewport.height >= 48f)
                assertTrue("Group navigation remains outside parameters", !viewport.overlaps(bounds("editor-groups")))
                if (tool in listOf(17, 16)) {
                    for (action in listOf("draft.apply", "draft.cancel")) {
                        val node = compose.onNodeWithTag(action).assertIsDisplayed()
                        val actionBounds = node.fetchSemanticsNode().boundsInRoot
                        assertTrue("$action full 48dp touch target", actionBounds.height >= 48f)
                        assertTrue("$action is fixed outside scrolling parameters", !viewport.overlaps(actionBounds))
                    }
                    val last = if (tool == 17) compose.onAllNodesWithTag("adjustment-slider").onLast() else compose.onNodeWithTag("lens.profile")
                    last.performScrollTo().assertIsDisplayed()
                    val control = last.fetchSemanticsNode().boundsInRoot
                    val required = if (tool == 17) 80f else 48f
                    assertTrue("$width/$height/$scale/tool=$tool last control must be fully visible: $control in $viewport", control.height >= required - 1 && control.top >= viewport.top - 1 && control.bottom <= viewport.bottom + 1)
                    assertEquals(dock, bounds("adjustment-dock"))
                    val directory = File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "parameter-viewport").apply { mkdirs() }
                    File(directory, "$language-$width-$height-$scale-$tool.png").outputStream().use {
                        compose.onNodeWithTag("parameter-fixture").captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
                    }
                }
            }
        }
        group("geometry")
        compose.onNodeWithTag("editor-tools").assertDoesNotExist()
        compose.onNodeWithTag("editor-group-geometry").assertIsDisplayed()
        group("geometry")
        assertEquals(dock, bounds("adjustment-dock"))
    }
}
