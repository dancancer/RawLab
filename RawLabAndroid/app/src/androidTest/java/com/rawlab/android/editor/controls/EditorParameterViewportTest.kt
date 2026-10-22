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
import com.rawlab.android.R
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
    @Test fun portrait390Normal() = verify(390, 844, 1f)
    @Test fun portrait412Normal() = verify(412, 892, 1f)
    @Test fun portrait390LargeText() = verify(390, 844, 1.6f)
    @Test fun portrait412LargeText() = verify(412, 892, 1.6f)
    @Test fun portrait320LargeText() = verify(320, 720, 1.6f)
    @Test fun portrait360LargeText() = verify(360, 720, 1.6f)
    @Test fun sideLandscapeNormal() = verify(960, 360, 1f, true)
    @Test fun bottomLandscapeNormal() = verify(560, 360, 1f)
    @Test fun bottomLandscapeLargeText() = verify(640, 360, 1.6f)

    @Test fun portrait320LargeGerman() = verify(320, 720, 1.6f, language = "de")
    @Test fun portrait320LargeFrench() = verify(320, 720, 1.6f, language = "fr")
    @Test fun portrait320LargeEnglish() = verify(320, 720, 1.6f, language = "en")
    @Test fun portrait320LargeJapanese() = verify(320, 720, 1.6f, language = "ja")
    @Test fun portrait320LargeSpanish() = verify(320, 720, 1.6f, language = "es")

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
        fun capture(name: String) {
            val directory = File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "parameter-viewport").apply { mkdirs() }
            File(directory, name).outputStream().use { compose.onNodeWithTag("parameter-fixture").captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        val dock = bounds("adjustment-dock")
        val canvas = bounds("editor-canvas")
        assertTrue("$width/$height/$scale uses the expected measured layout", if (side) canvas.right <= dock.left else canvas.bottom <= dock.top)
        assertTrue("Photo retains at least 96dp above the uniformly budgeted panel", canvas.height >= 96f - 1)
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
                android.util.Log.i("RawLabViewportRed", "$language/$width/$height/$scale/tool=$tool photo=$canvas dock=$dock viewport=$viewport")
                assertTrue("$width/$height/$scale/tool=$tool parameter viewport needs a complete 48dp operation row: $viewport", viewport.height >= 48f)
                assertTrue("Group navigation remains outside parameters", !viewport.overlaps(bounds("editor-groups")))
                if (tool == 14) {
                    capture("hsl-top-$language-$width-$height-$scale.png")
                    val axes = listOf(R.string.hsl_hue, R.string.saturation, R.string.hsl_lightness)
                    if (scale == 1f && width < height) {
                        for (axis in axes) {
                            val row = bounds("adjustment-row-$axis")
                            val number = bounds("adjustment-value-$axis")
                            assertTrue("All HSL axes simultaneously fit: $row in $viewport", row.height >= 48f && row.top >= viewport.top - 1 && row.bottom <= viewport.bottom + 1)
                            assertTrue("HSL number retains a complete 48dp touch target", number.height >= 48f)
                            assertTrue("The empty unit has its alignment slot", bounds("adjustment-unit-$axis").width >= 24f)
                        }
                        compose.onNodeWithTag("adjustment-fine").assertIsDisplayed()
                    } else {
                        val number = compose.onNodeWithTag("adjustment-value-${R.string.hsl_lightness}").performScrollTo().assertIsDisplayed()
                        val numberVisible = number.fetchSemanticsNode().boundsInRoot
                        val numberFull = number.getUnclippedBoundsInRoot()
                        assertTrue("Last HSL number is fully reachable", numberVisible.height >= (numberFull.bottom - numberFull.top).value - 1 && numberVisible.height >= 48f)
                        if (width < height) {
                            val row = compose.onNodeWithTag("adjustment-row-${R.string.hsl_lightness}").performScrollTo()
                            val visible = row.fetchSemanticsNode().boundsInRoot
                            val full = row.getUnclippedBoundsInRoot()
                            android.util.Log.i("RawLabWholeRowEvidence", "$language/$width/$height/$scale HSL row=$visible full=$full viewport=$viewport")
                            assertTrue("Large portrait shows the complete last HSL label/value and track", visible.height >= (full.bottom - full.top).value - 1 && visible.height >= 96f - 1)
                        }
                        val last = compose.onAllNodesWithTag("adjustment-slider").onLast().performScrollTo().assertIsDisplayed()
                        val rect = last.fetchSemanticsNode().boundsInRoot
                        assertTrue("Last HSL track fully scrolls into view: $rect in $viewport", rect.height >= 48f && rect.top >= viewport.top - 1 && rect.bottom <= viewport.bottom + 1)
                        capture("hsl-last-$language-$width-$height-$scale.png")
                    }
                }
                if (tool in listOf(17, 16)) {
                    val header = compose.onAllNodesWithTag("adjustment-draft-title", useUnmergedTree = true)
                    if (header.fetchSemanticsNodes().isNotEmpty()) {
                        val title = header.onFirst()
                        val layouts = mutableListOf<TextLayoutResult>()
                        title.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                        val titleBounds = title.fetchSemanticsNode().boundsInRoot
                        assertEquals("Draft header retains its fixed 48dp budget", 48f, titleBounds.height, 1f)
                        assertTrue("Draft title has a real measured layout", layouts.isNotEmpty())
                        for (layout in layouts) {
                            android.util.Log.i("RawLabHeaderEvidence", "$language/$width/$height/$scale title=$titleBounds text=${layout.size} lines=${layout.lineCount}")
                            assertTrue("Draft title is a complete single line with horizontal reach", layout.lineCount == 1 && !layout.didOverflowHeight && !layout.isLineEllipsized(0) && layout.size.height <= 48f)
                        }
                        val scroll = title.fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange]
                        if (scroll.maxValue() > 0f) {
                            title.performSemanticsAction(SemanticsActions.ScrollBy) { it(scroll.maxValue(), 0f) }
                            compose.waitForIdle()
                            assertEquals("Long draft title reaches its natural-width end", scroll.maxValue(), title.fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange].value(), 1f)
                            title.performSemanticsAction(SemanticsActions.ScrollBy) { it(-scroll.maxValue(), 0f) }
                        }
                    }
                    capture("draft-actions-$language-$width-$height-$scale-$tool.png")
                    for (action in listOf("draft.apply", "draft.cancel")) {
                        val node = compose.onNodeWithTag(action).assertIsDisplayed()
                        val actionBounds = node.fetchSemanticsNode().boundsInRoot
                        assertTrue("$action full 48dp touch target", actionBounds.height >= 48f)
                        assertTrue("$action is fixed outside scrolling parameters", !viewport.overlaps(actionBounds))
                        val text = node.fetchSemanticsNode().config[SemanticsProperties.Text].single().text
                        val label = compose.onNode(hasText(text) and hasAnyAncestor(hasTestTag(action)), useUnmergedTree = true)
                        val layouts = mutableListOf<TextLayoutResult>()
                        label.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                        val visible = label.fetchSemanticsNode().boundsInRoot
                        assertTrue("$language/$width/$scale/$action has actual text layout", layouts.isNotEmpty())
                        for (layout in layouts) {
                            android.util.Log.i("RawLabActionTextEvidence", "$language/$width/$height/$scale/$action button=$actionBounds visible=$visible layout=${layout.size} lines=${layout.lineCount} lastBottom=${layout.getLineBottom(layout.lineCount - 1)} overflow=${layout.didOverflowHeight}")
                            assertFalse("$language/$width/$scale/$action complete button text: button=$actionBounds visible=$visible layout=${layout.size} lines=${layout.lineCount} lastBottom=${layout.getLineBottom(layout.lineCount - 1)}", layout.didOverflowHeight)
                            assertTrue("$language/$width/$scale/$action text is not clipped or ellipsized", (0 until layout.lineCount).all {
                                !layout.isLineEllipsized(it) && layout.getLineLeft(it) >= -1 && layout.getLineRight(it) <= visible.width + 1
                            } && visible.height >= layout.size.height - 1)
                        }
                    }
                    if (tool == 17 && scale > 1.3f && width < height) {
                        val row = compose.onNodeWithTag("adjustment-row-${R.string.geometry_crop_height}").performScrollTo()
                        val visible = row.fetchSemanticsNode().boundsInRoot
                        val full = row.getUnclippedBoundsInRoot()
                        android.util.Log.i("RawLabWholeRowEvidence", "$language/$width/$height/$scale geometry row=$visible full=$full viewport=$viewport")
                        assertTrue("Large portrait must show the complete label/value and track together: $visible full=$full viewport=$viewport",
                            visible.height >= (full.bottom - full.top).value - 1 && visible.height >= 96f - 1 && visible.top >= viewport.top - 1 && visible.bottom <= viewport.bottom + 1)
                    }
                    if (tool == 17 && height < width) {
                        val number = compose.onNodeWithTag("adjustment-value-${R.string.geometry_crop_height}").performScrollTo()
                        for (tag in listOf("adjustment-name-${R.string.geometry_crop_height}", "adjustment-value-${R.string.geometry_crop_height}", "adjustment-unit-${R.string.geometry_crop_height}")) {
                            val node = compose.onNodeWithTag(tag)
                            val visible = node.fetchSemanticsNode().boundsInRoot
                            val full = node.getUnclippedBoundsInRoot()
                            android.util.Log.i("RawLabWholeRowEvidence", "$language/$width/$height/$scale geometry label/value $tag visible=$visible full=$full viewport=$viewport")
                            assertTrue("Short window label/value is wholly reachable before scrolling to the track", visible.height >= (full.bottom - full.top).value - 1 && visible.width >= (full.right - full.left).value - 1)
                        }
                        assertTrue("Short window numeric entry retains its full 48dp operation target", number.fetchSemanticsNode().boundsInRoot.height >= 48f - 1)
                        capture("geometry-value-$language-$width-$height-$scale.png")
                    }
                    val last = if (tool == 17) compose.onAllNodesWithTag("adjustment-slider").onLast() else compose.onNodeWithTag("lens.profile")
                    last.performScrollTo().assertIsDisplayed()
                    val control = last.fetchSemanticsNode().boundsInRoot
                    val required = 48f
                    val full = last.getUnclippedBoundsInRoot()
                    assertTrue("Last control is not merely partially clipped into a 48dp viewport", control.height >= (full.bottom - full.top).value - 1 && control.width >= (full.right - full.left).value - 1)
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
