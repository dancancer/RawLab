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
import com.rawlab.android.testing.localizedTestConfiguration
import com.rawlab.android.testing.workbenchTool
import com.rawlab.android.testing.selectWorkbenchGroup
import com.rawlab.android.testing.openWorkbenchTool
import com.rawlab.android.testing.openGeometryDimensions
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File

class EditorParameterViewportTest {
    private val compose = createComposeRule()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule("system")).around(compose)

    @Test fun portrait320Normal() = verify(320, 720, 1f)
    @Test fun portrait360Normal() = verify(360, 720, 1f)
    @Test fun portrait390Normal() = verify(390, 844, 1f)
    @Test fun portrait412Normal() = verify(412, 892, 1f)
    @Test fun sideLandscapeNormal() = verify(960, 360, 1f, true)
    @Test fun bottomLandscapeNormal() = verify(560, 360, 1f)

    private fun verify(width: Int, height: Int, scale: Float, side: Boolean = false, language: String = "zh-Hans") {
        val bitmap = Bitmap.createBitmap(60, 90, Bitmap.Config.ARGB_8888)
        var state by mutableStateOf(EditorState(photo = ImportedPhoto(Uri.parse("content://layout/parameters"), "fixture", File("fixture")),
            preview = PreviewPair(bitmap, bitmap, 5200f, 8f), exact = true))
        compose.setContent {
            val base = LocalContext.current
            val config = localizedTestConfiguration(LocalConfiguration.current, language, scale)
            val localized = base.createConfigurationContext(config)
            check(localized.resources.configuration.locales[0].language == Locale.forLanguageTag(language).language)
            CompositionLocalProvider(LocalDensity provides Density(1f, scale), LocalContext provides localized, LocalConfiguration provides config) {
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
        fun capture(name: String) {
            val directory = File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "parameter-viewport").apply { mkdirs() }
            File(directory, name).outputStream().use { compose.onNodeWithTag("parameter-fixture").captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        fun wholeTarget(tag: String, viewport: Rect? = null, density: Float = 1f) {
            val node = compose.onNodeWithTag(tag).assertIsDisplayed()
            val clipped = node.fetchSemanticsNode().boundsInRoot
            val full = node.getUnclippedBoundsInRoot()
            assertTrue("$width/$height/$scale/$language/$tag whole touch target: $clipped vs $full",
                clipped.width >= (full.right - full.left).value * density - 1 &&
                    clipped.height >= (full.bottom - full.top).value * density - 1 && clipped.height >= 48f * density - 1)
            if (viewport != null) assertTrue("$tag is wholly reachable inside $viewport: $clipped",
                clipped.top >= viewport.top - 1 && clipped.bottom <= viewport.bottom + 1)
        }
        fun label(node: SemanticsNodeInteraction, name: String) {
            val layouts = mutableListOf<TextLayoutResult>()
            node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
            val visible = node.fetchSemanticsNode().boundsInRoot
            assertTrue("Label has a real measured layout: $name", layouts.isNotEmpty())
            for (layout in layouts) {
                val widest = (0 until layout.lineCount).maxOf { layout.getLineRight(it) - layout.getLineLeft(it) }
                assertFalse("$name must not truncate height", layout.didOverflowHeight)
                assertTrue("$language/$width/$height/$scale/$name complete text: $visible ${layout.size}",
                    (0 until layout.lineCount).all { !layout.isLineEllipsized(it) } &&
                        visible.width >= widest - 1 && visible.height >= layout.size.height - 1)
            }
        }
        val initialDock = bounds("adjustment-dock")
        val navigation = bounds("editor-groups")
        var openedSideDock: Rect? = null
        for ((group, tools) in listOf("looks" to listOf(0, 15), "light" to listOf(2, 3, 4, 5, 6),
            "color" to listOf(8, 7, 14), "effects" to listOf(12, 13), "detail" to listOf(11, 10), "geometry" to listOf(17, 16))) {
            for (tool in tools) {
                val entry = compose.workbenchTool(tool)
                assertEquals("Group navigation stays anchored in the grid", navigation, bounds("editor-groups"))
                compose.onNodeWithTag("editor-group-$group").assertIsSelected()
                val title = entry.fetchSemanticsNode().config[SemanticsProperties.ContentDescription].single()
                for (tag in listOf("editor-tool-label-$tool", "editor-group-label-$group"))
                    label(compose.onNodeWithTag(tag, useUnmergedTree = true), tag)
                for (tag in listOf("editor-tool-$tool", "editor-group-$group")) wholeTarget(tag)
                if (group == "looks") compose.onNodeWithTag("editor-tool-1").assertDoesNotExist()
                entry.performClick()
                compose.onNodeWithTag("editor-tools").assertDoesNotExist()
                compose.onNodeWithTag("editor-groups").assertDoesNotExist()
                val dock = bounds("adjustment-dock")
                val canvas = bounds("editor-canvas")
                assertTrue("$width/$height/$scale uses the expected measured layout", if (side) canvas.right <= dock.left else canvas.bottom <= dock.top)
                assertTrue("Photo retains at least 96dp above the content-sized panel", canvas.height >= 96f - 1)
                if (side) {
                    assertEquals("Side panel fills the photo height", canvas.height, dock.height, 1f)
                    assertEquals(canvas.top, dock.top, 1f)
                    openedSideDock?.let { assertEquals("Side panel remains fixed across open tools", it, dock) }
                    openedSideDock = dock
                }
                val viewport = bounds("editor-parameters")
                assertTrue("$width/$height/$scale/tool=$tool needs a complete 48dp operation row: $viewport", viewport.height >= 48f - 1)
                val footerTitle = compose.onNode(hasText(title) and hasAnyAncestor(hasTestTag("adjustment-dock")) and
                    !hasAnyAncestor(hasTestTag("editor-parameters")), useUnmergedTree = true)
                label(footerTitle.assertIsDisplayed(), "draft title $title")
                val footer = listOf("draft.apply", "draft.cancel").associateWith { bounds(it) }
                for ((action, description) in listOf("draft.apply" to R.string.adjustment_apply, "draft.cancel" to R.string.cancel)) {
                    val node = compose.onNodeWithTag(action).assertHasClickAction()
                    node.assertContentDescriptionEquals(
                        InstrumentationRegistry.getInstrumentation().targetContext.createConfigurationContext(
                            localizedTestConfiguration(InstrumentationRegistry.getInstrumentation().targetContext.resources.configuration, language)).getString(description))
                    wholeTarget(action)
                    assertTrue("$action has a full 48dp width", bounds(action).width >= 48f - 1)
                    assertFalse("$action remains outside scrolling parameters", viewport.overlaps(bounds(action)))
                }
                if (tool in listOf(0, 15)) {
                    for (part in listOf("name", "value", "unit"))
                        compose.onNodeWithTag("adjustment-$part-${R.string.strength}").performScrollTo().assertIsDisplayed()
                    wholeTarget("adjustment-value-${R.string.strength}", viewport)
                    compose.onNode(hasTestTag("adjustment-slider") and hasAnyAncestor(hasTestTag("adjustment-row-${R.string.strength}")))
                        .performScrollTo().assertIsDisplayed()
                }
                if (tool == 14) {
                    capture("hsl-top-$language-$width-$height-$scale.png")
                    for (axis in listOf(R.string.hsl_hue, R.string.saturation, R.string.hsl_lightness)) {
                        compose.onNodeWithTag("adjustment-value-$axis").performScrollTo()
                        wholeTarget("adjustment-value-$axis", viewport)
                        compose.onNodeWithTag("adjustment-unit-$axis").assertDoesNotExist()
                        label(compose.onNodeWithTag("adjustment-name-$axis", useUnmergedTree = true), "HSL axis $axis")
                        val track = compose.onNode(hasTestTag("adjustment-slider") and hasAnyAncestor(hasTestTag("adjustment-row-$axis")))
                            .performScrollTo().assertIsDisplayed()
                        val trackBounds = track.fetchSemanticsNode().boundsInRoot
                        assertTrue("Every HSL ruler is fully reachable", trackBounds.height >= 48f - 1 &&
                            trackBounds.top >= viewport.top - 1 && trackBounds.bottom <= viewport.bottom + 1)
                    }
                    if (width < height) {
                        val row = compose.onNodeWithTag("adjustment-row-${R.string.hsl_lightness}").performScrollTo()
                        val visible = row.fetchSemanticsNode().boundsInRoot
                        val full = row.getUnclippedBoundsInRoot()
                        assertTrue("Portrait exposes the complete HSL label/value and track: $visible / $full",
                            visible.height >= (full.bottom - full.top).value - 1 && visible.height >= (if (scale > 1.3f) 96f else 48f) - 1)
                    }
                    capture("hsl-last-$language-$width-$height-$scale.png")
                }
                if (tool == 17) {
                    compose.onNodeWithTag("geometry.ratios").performScrollTo()
                    wholeTarget("geometry.ratios", viewport)
                    compose.openGeometryDimensions()
                    val dialog = compose.onNode(isDialog()).fetchSemanticsNode().boundsInRoot
                    for (axis in listOf(R.string.geometry_crop_x, R.string.geometry_crop_y, R.string.geometry_crop_width, R.string.geometry_crop_height)) {
                        for (part in listOf("name", "value", "unit")) {
                            val node = compose.onNodeWithTag("adjustment-$part-$axis", useUnmergedTree = true).assertIsDisplayed()
                            val textNode = if (part == "value") compose.onNode(
                                hasAnyAncestor(hasTestTag("adjustment-value-$axis")) and
                                    SemanticsMatcher.keyIsDefined(SemanticsActions.GetTextLayoutResult), useUnmergedTree = true) else node
                            label(textNode, "crop $part $axis")
                        }
                        wholeTarget("adjustment-value-$axis", dialog, compose.density.density)
                        val row = compose.onNodeWithTag("adjustment-row-$axis")
                        val visible = row.fetchSemanticsNode().boundsInRoot
                        val full = row.getUnclippedBoundsInRoot()
                        assertTrue("Crop dimensions keep their complete label/value row", visible.height >= (full.bottom - full.top).value * compose.density.density - 1)
                    }
                    compose.onAllNodes(isDialog()).assertCountEquals(1)
                    // Dialog 使用宿主窗口的语言、密度与尺寸；实际旋转/大字覆盖由原生运行时类负责。
                    compose.onNodeWithText(com.rawlab.android.i18n.AppStrings.text(R.string.confirm))
                        .assertIsDisplayed().assertHasClickAction().performClick()
                    capture("draft-actions-$language-$width-$height-$scale-$tool.png")
                }
                if (tool == 16) {
                    compose.onNodeWithTag("lens.profile").performScrollTo()
                    wholeTarget("lens.profile", viewport)
                    assertEquals("Scrolling the last lens control does not move the dock", dock, bounds("adjustment-dock"))
                    capture("$language-$width-$height-$scale-$tool.png")
                }
                footer.forEach { (action, position) -> assertEquals("$action remains fixed while parameters scroll", position, bounds(action)) }
                compose.onNodeWithTag("draft.cancel").performClick()
                compose.onNodeWithTag("editor-parameters").assertDoesNotExist()
                compose.onNodeWithTag("draft.apply").assertDoesNotExist()
                compose.onNodeWithTag("editor-group-$group").assertIsSelected()
                assertEquals("Cancel restores anchored grid navigation", navigation, bounds("editor-groups"))
                assertEquals("Cancel restores the home dock", initialDock, bounds("adjustment-dock"))
            }
        }
        val home = bounds("adjustment-dock")
        repeat(2) {
            compose.selectWorkbenchGroup("geometry")
            compose.onNodeWithTag("editor-parameters").assertDoesNotExist()
            compose.onNodeWithTag("editor-tools").assertDoesNotExist()
            assertEquals("Selecting the current group is idempotent", home, bounds("adjustment-dock"))
        }
        compose.openWorkbenchTool(17)
        compose.onNodeWithTag("draft.cancel").performClick()
        assertEquals(home, bounds("adjustment-dock"))
    }
}
