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
import com.rawlab.android.testing.localizedTestContext
import com.rawlab.android.testing.localizedTestConfiguration
import com.rawlab.android.testing.openWorkbenchTool
import com.rawlab.android.testing.selectWorkbenchGroup
import com.rawlab.android.testing.openWorkbenchMore
import com.rawlab.android.testing.toggleWorkbenchFine
import com.rawlab.android.testing.dismissWorkbenchMenu
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
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule("system")).around(ForegroundTestRule()).around(compose)
    private var state by mutableStateOf(EditorState(
        photo = ImportedPhoto(Uri.parse("content://rawlab.test/compact-layout"), "layout.dng", File("layout.dng")),
        preview = Bitmap.createBitmap(12, 16, Bitmap.Config.ARGB_8888).let {
            PreviewPair(it, it, temperature = 5200f, tint = 8f)
        }, exact = true))

    private fun show(width: Int = 360, height: Int = 780, scale: Float = 1f, language: String = "zh-Hans") {
        compose.setContent {
            val base = LocalContext.current
            val config = localizedTestConfiguration(LocalConfiguration.current, language, scale)
            val localized = localizedTestContext(base, language, scale)
            check(localized.resources.configuration.locales[0].language == Locale.forLanguageTag(language).language)
            CompositionLocalProvider(LocalDensity provides Density(1f, scale),
                LocalContext provides localized, LocalConfiguration provides config) {
                Box(Modifier.size(width.dp, height.dp).consumeWindowInsets(WindowInsets.safeDrawing).testTag("layout-fixture")) {
                    RawLabTheme {
                        EditorScreen(state, {}, {}, { edits, dragging -> state = state.copy(draft = state.draft!!.update(edits, dragging)) }, {}, {}, {}, {}, {},
                            onBeginDraft = { state = state.copy(draft = AdjustmentDraft.begin(it, state.edits)) },
                            onDiscardDraft = { state = state.copy(draft = null) })
                    }
                }
            }
        }
    }

    private fun bounds(tag: String) = compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot
    private fun group(id: String) = compose.openWorkbenchTool(when (id) {
        "light" -> 2
        "color" -> 8
        "geometry" -> 17
        else -> error("Unknown fixture group $id")
    })
    private fun tool(id: Int) = compose.openWorkbenchTool(id)
    private fun capture(name: String) {
        val dir = File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "compact-layout").apply { mkdirs() }
        File(dir, "$name.png").outputStream().use {
            compose.onNodeWithTag("layout-fixture").captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }

    @Test fun phoneToolsUseTheFullRowAboveFineActions() {
        show(); compose.selectWorkbenchGroup("light")
        capture("phone-tools")
        val dock = bounds("adjustment-dock")
        for (id in listOf(2, 5, 3, 4)) compose.onNodeWithTag("editor-tool-$id").assertIsDisplayed()
        val first = bounds("editor-tool-2")
        val last = bounds("editor-tool-4")
        assertEquals("The grid uses the full panel row inside its 8dp insets", dock.width - 16f, last.right - first.left, 1f)
        compose.onNodeWithTag("adjustment-fine").assertDoesNotExist()
        tool(2); compose.toggleWorkbenchFine()
        compose.openWorkbenchMore()
        compose.onNodeWithTag("adjustment-fine").assertIsSelected()
        compose.dismissWorkbenchMenu()
        tool(3); compose.openWorkbenchMore()
        compose.onNodeWithTag("adjustment-fine").assertIsNotSelected()
        compose.dismissWorkbenchMenu()
    }

    @Test fun fineModeIsACompactButtonGroupedWithReset() {
        show(); group("light")
        val more = bounds("workspace-more")
        val reset = compose.onNodeWithContentDescription("重置调整").fetchSemanticsNode().boundsInRoot
        assertTrue("Fine mode is reached from the same workspace action group as reset", more.left >= reset.right)
        assertEquals("More and reset share the workspace action row", reset.center.y, more.center.y, 1f)
        compose.openWorkbenchMore()
        val fine = compose.onNodeWithTag("adjustment-fine")
        val fineBounds = fine.fetchSemanticsNode().boundsInRoot
        assertTrue("Fine mode retains a full-width touch target", fineBounds.width >= 48f)
        assertTrue("The menu item exposes the complete 48dp touch height", fineBounds.height >= 48f)
        fine.assertIsNotSelected().performTouchInput { click(Offset(centerX, 1f)) }
        compose.openWorkbenchMore()
        compose.onNodeWithTag("adjustment-fine").assertIsSelected().performTouchInput { click(Offset(centerX, height - 1f)) }
        compose.openWorkbenchMore()
        compose.onNodeWithTag("adjustment-fine").assertIsNotSelected()
        compose.dismissWorkbenchMenu()
        compose.runOnIdle { assertEquals(0f, state.visibleEdits.exposure, 0f); assertEquals(0f, state.edits.exposure, 0f) }
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
            compose.runOnIdle { state = state.copy(draft = state.draft!!.update(state.visibleEdits.copy(exposure = value))) }
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
        compose.runOnIdle { assertEquals(.2f, state.visibleEdits.exposure, .0001f) }
        assertEquals(before, bounds("adjustment-slider"))
        ruler.performTouchInput { moveBy(Offset(32f, 0f)) }
        compose.waitForIdle()
        compose.runOnIdle { assertEquals(.4f, state.visibleEdits.exposure, .0001f) }
        assertEquals(before, bounds("adjustment-slider"))
        ruler.performTouchInput { up() }
        compose.runOnIdle { assertEquals(.4f, state.visibleEdits.exposure, .0001f) }
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
        compose.runOnIdle { assertNotEquals(0f, state.visibleEdits.exposure) }
        assertEquals("Adjusting a value does not move the panel", dock, bounds("adjustment-dock"))
    }

    @Test fun wideWindowKeepsAFullHeightSidePanel() {
        show(960, 600); group("light"); tool(3)
        val dock = bounds("adjustment-dock")
        val photo = bounds("editor-canvas")
        assertTrue(photo.right <= dock.left)
        assertEquals(photo.height, dock.height, 1f)
        compose.openWorkbenchMore()
        compose.onNodeWithTag("adjustment-fine").assertIsDisplayed()
        compose.dismissWorkbenchMenu()
        capture("wide-side-panel")
    }
}
