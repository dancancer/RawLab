package com.rawlab.android.editor

import android.content.res.Configuration
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.R
import com.rawlab.android.RawLabTheme
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.ui.EditorScreen
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.testing.LanguageTestRule
import com.rawlab.android.testing.ForegroundTestRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File
import java.util.Locale

class EditorCompactLayoutTest {
    private val compose = createComposeRule()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(ForegroundTestRule()).around(compose)
    private var state by mutableStateOf(EditorState(
        photo = ImportedPhoto(Uri.parse("content://rawlab.test/compact-layout"), "layout.dng", File("layout.dng")),
        preview = Bitmap.createBitmap(12, 16, Bitmap.Config.ARGB_8888).let {
            PreviewPair(it, it, temperature = 5200f, tint = 8f)
        }, exact = true))

    private fun show(width: Int = 360, height: Int = 780, scale: Float = 1f, language: String = "zh-Hans") {
        compose.setContent {
            val base = LocalContext.current
            val config = Configuration(LocalConfiguration.current).apply {
                setLocale(Locale.forLanguageTag(language)); fontScale = scale
            }
            CompositionLocalProvider(LocalDensity provides Density(1f, scale),
                LocalContext provides base.createConfigurationContext(config), LocalConfiguration provides config) {
                Box(Modifier.size(width.dp, height.dp).consumeWindowInsets(WindowInsets.safeDrawing).testTag("layout-fixture")) {
                    RawLabTheme {
                        EditorScreen(state, {}, {}, { edits, _ -> state = state.copy(edits = edits) }, {}, {}, {}, {}, {},
                            onBeginDraft = { state = state.copy(draft = AdjustmentDraft.begin(it, state.edits)) },
                            onDiscardDraft = { state = state.copy(draft = null) })
                    }
                }
            }
        }
    }

    private fun bounds(tag: String) = compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot
    private fun group(id: String) {
        compose.onNodeWithTag("editor-groups").performScrollToNode(hasTestTag("editor-group-$id"))
        compose.onNodeWithTag("editor-group-$id").performClick()
    }
    private fun tool(id: Int) {
        compose.onNodeWithTag("editor-tools").performScrollToNode(hasTestTag("editor-tool-$id"))
        compose.onNodeWithTag("editor-tool-$id").performClick()
    }
    private fun capture(name: String) {
        val dir = File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "compact-layout").apply { mkdirs() }
        File(dir, "$name.png").outputStream().use {
            compose.onNodeWithTag("layout-fixture").captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }

    @Test fun phoneToolsUseTheFullRowAboveFineActions() {
        show(); group("light")
        capture("phone-tools")
        val dock = bounds("adjustment-dock")
        val tools = bounds("editor-tools")
        val fine = bounds("adjustment-fine")
        assertEquals("Tool navigation uses the available panel width", dock.width, tools.width, 1f)
        assertTrue("Fine control does not consume tool navigation width", fine.top >= tools.bottom)
        for (id in listOf(2, 3, 4)) compose.onNodeWithTag("editor-tool-$id").assertIsDisplayed()
        compose.onNodeWithTag("adjustment-fine").performClick().assertIsSelected()
        tool(3)
        compose.onNodeWithTag("adjustment-fine").assertIsNotSelected()
    }

    @Test fun fineModeIsACompactButtonGroupedWithReset() {
        show(); group("light")
        val fine = compose.onNodeWithTag("adjustment-fine")
        val fineBounds = fine.fetchSemanticsNode().boundsInRoot
        val reset = compose.onNode(hasContentDescription("重置调整") and
            hasAnyAncestor(hasTestTag("adjustment-dock"))).fetchSemanticsNode().boundsInRoot
        assertTrue("Fine mode belongs next to reset in the trailing action group", reset.left - fineBounds.right in 0f..12f)
        assertEquals("Fine and reset share one action row", reset.center.y, fineBounds.center.y, 1f)
        assertTrue("Fine mode retains a full-width touch target", fineBounds.width >= 48f)
        fine.assertIsNotSelected()
        // Material 的紧凑 chip 视觉高度为 32dp；实际命中区域应向上下扩展到 48dp。
        compose.onNodeWithTag("layout-fixture").performTouchInput {
            click(Offset(fineBounds.center.x, fineBounds.center.y - 23f))
        }
        fine.assertIsSelected()
        compose.onNodeWithTag("layout-fixture").performTouchInput {
            click(Offset(fineBounds.center.x, fineBounds.center.y + 23f))
        }
        fine.assertIsNotSelected()
        compose.runOnIdle { assertEquals(0f, state.edits.exposure, 0f) }
    }

    @Test fun scalarPanelReturnsUnusedSpaceToPhoto() {
        show(); group("light"); tool(3)
        capture("scalar")
        val parameters = bounds("editor-parameters")
        val row = bounds("adjustment-row-${R.string.highlights}")
        assertTrue("A scalar panel has no empty filler below its actual controls", parameters.height <= row.height + 16f)
        val scalarPhoto = bounds("editor-canvas")
        val scalarDock = bounds("adjustment-dock")
        group("color"); tool(14)
        assertTrue("Complex tools can use a larger panel", bounds("adjustment-dock").height > scalarDock.height)
        assertTrue("The scalar panel gives the recovered height to the photo", scalarPhoto.height > bounds("editor-canvas").height)
        compose.onNodeWithTag("adjustment-value-${R.string.hsl_lightness}").performScrollTo().assertIsDisplayed()
        group("light"); tool(3)
        assertEquals("Returning to a tool restores its compact geometry", scalarDock, bounds("adjustment-dock"))
    }

    @Test fun phoneRulerUsesFullContentWidth() = verifyRulerWidth(360, 780)

    @Test fun narrowPhoneRulerUsesFullContentWidth() = verifyRulerWidth(320, 720)

    @Test fun sidePanelRulerUsesFullContentWidth() = verifyRulerWidth(960, 600)

    @Test fun portraitTabletRulerUsesFullContentWidth() = verifyRulerWidth(800, 1280)

    @Test fun tabletReadoutChangesKeepRulerAndNumberFramesStable() {
        show(800, 1280); group("light")
        val ruler = bounds("adjustment-slider")
        val number = bounds("adjustment-value-${R.string.exposure}")
        for (value in listOf(-3.95f, -.5f, 0f, .05f, .5f, 3.95f, 4f)) {
            compose.runOnIdle { state = state.copy(edits = state.edits.copy(exposure = value)) }
            assertEquals("Value $value must not move or resize the ruler", ruler, bounds("adjustment-slider"))
            assertEquals("Value $value must keep the readout slot stable", number, bounds("adjustment-value-${R.string.exposure}"))
        }
        capture("tablet-stable-readout")
    }

    @Test fun tabletContinuousDragStaysAlignedAcrossLiveReadoutChanges() {
        show(800, 1280); group("light")
        val ruler = compose.onNodeWithTag("adjustment-slider")
        val before = bounds("adjustment-slider")
        ruler.performTouchInput { down(center); moveBy(Offset(32f, 0f)) }
        compose.waitForIdle()
        compose.runOnIdle { assertEquals(.2f, state.edits.exposure, .0001f) }
        assertEquals(before, bounds("adjustment-slider"))
        ruler.performTouchInput { moveBy(Offset(32f, 0f)) }
        compose.waitForIdle()
        compose.runOnIdle { assertEquals(.4f, state.edits.exposure, .0001f) }
        assertEquals(before, bounds("adjustment-slider"))
        ruler.performTouchInput { up() }
        compose.runOnIdle { assertEquals(.4f, state.edits.exposure, .0001f) }
    }

    private fun verifyRulerWidth(width: Int, height: Int) {
        show(width, height); group("light")
        val dock = bounds("adjustment-dock")
        val ruler = bounds("adjustment-slider")
        val name = bounds("adjustment-name-${R.string.exposure}")
        capture("ruler-$width-$height")
        assertTrue("Narrow-panel rulers use the full width inside the 12dp insets: $ruler in $dock",
            ruler.width >= dock.width - 25f)
        assertTrue("Label and value sit above the ruler", ruler.top >= name.bottom)
        compose.onNodeWithTag("adjustment-slider").performTouchInput {
            down(center); moveBy(Offset(-64f, 0f)); up()
        }
        compose.runOnIdle { assertNotEquals(0f, state.edits.exposure) }
        assertEquals("Adjusting a value does not move the panel", dock, bounds("adjustment-dock"))
    }

    @Test fun shortLargeTextKeepsDraftActionsAndNavigationOutsideScrolling() {
        show(640, 360, 1.6f, "de"); group("geometry")
        val groups = bounds("editor-groups")
        val cancel = bounds("draft.cancel")
        val apply = bounds("draft.apply")
        compose.onAllNodesWithTag("adjustment-slider").onLast().performScrollTo().assertIsDisplayed()
        capture("short-large-draft")
        assertEquals(groups, bounds("editor-groups"))
        assertEquals(cancel, bounds("draft.cancel"))
        assertEquals(apply, bounds("draft.apply"))
        assertTrue("Photo remains available in a short window", bounds("editor-canvas").height >= 95f)
        assertTrue("Draft actions retain touch targets", cancel.height >= 48f && apply.height >= 48f)
        assertFalse("Draft actions remain outside the parameter viewport", bounds("editor-parameters").overlaps(cancel))
    }

    @Test fun wideWindowKeepsAFullHeightSidePanel() {
        show(960, 600); group("light"); tool(3)
        val dock = bounds("adjustment-dock")
        val photo = bounds("editor-canvas")
        assertTrue(photo.right <= dock.left)
        assertEquals(photo.height, dock.height, 1f)
        compose.onNodeWithTag("adjustment-fine").assertIsDisplayed()
        capture("wide-side-panel")
    }
}
