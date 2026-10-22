package com.rawlab.android.editor.geometry

import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.unit.dp
import com.rawlab.android.editor.canvas.RgbHistogramOverlay
import com.rawlab.android.editor.canvas.RgbHistogramPlot
import com.rawlab.android.engine.RgbHistogram
import com.rawlab.android.testing.LanguageTestRule
import com.rawlab.android.testing.setChineseContent
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class RgbHistogramViewTest {
    private val compose = createComposeRule()
    @get:Rule val rule = org.junit.rules.RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test fun popupTracksSourceClearsMissingStatisticsAndRestoresVisibility() {
        var histogram by mutableStateOf<RgbHistogram?>(fixture())
        var before by mutableStateOf(false)
        var visible by mutableStateOf(true)
        compose.setChineseContent { MaterialTheme {
            Box(Modifier.fillMaxSize()) { RgbHistogramOverlay(histogram, before, visible) }
        } }
        compose.onNodeWithTag("rgb-histogram-toggle").performClick()
        compose.onNodeWithTag("rgb-histogram-plot").assertIsDisplayed()
        compose.onNodeWithTag("rgb-histogram-source").assertTextEquals("调整后")
        compose.runOnIdle { before = true }
        compose.onNodeWithTag("rgb-histogram-source").assertTextEquals("调整前")
        compose.runOnIdle { visible = false }
        compose.onNodeWithTag("rgb-histogram-popup").assertDoesNotExist()
        compose.onNodeWithTag("rgb-histogram-toggle").assertDoesNotExist()
        compose.runOnIdle { visible = true }
        compose.onNodeWithTag("rgb-histogram-plot").assertIsDisplayed()
        compose.runOnIdle { histogram = null }
        compose.onNodeWithTag("rgb-histogram-plot").assertDoesNotExist()
        compose.onNodeWithText("统计不可用").assertIsDisplayed()
        compose.onNodeWithTag("rgb-histogram-close").performClick()
        compose.onNodeWithTag("rgb-histogram-popup").assertDoesNotExist()
    }

    @Test fun drawingUsesSharedPeakAndActualRgbCmyGrayPixels() {
        compose.setContent { Box(Modifier.width(256.dp).height(100.dp)) {
            RgbHistogramPlot(fixture(), Modifier.fillMaxSize())
        } }
        val image = compose.onNodeWithTag("rgb-histogram-plot").captureToImage().asAndroidBitmap()
        for ((bin, rgb) in listOf(10 to 0xff0000, 20 to 0x00ff00, 30 to 0x0000ff, 40 to 0xffff00,
            50 to 0xff00ff, 60 to 0x00ffff, 70 to 0xbfbfbf)) {
            val actual = image.getPixel(((bin + .5f) / 256 * image.width).toInt(), image.height * 3 / 4)
            for (shift in listOf(16, 8, 0)) assertEquals((rgb shr shift) and 255, (actual shr shift) and 255)
        }
    }

    private fun fixture(): RgbHistogram {
        val bins = IntArray(768)
        for ((bin, mask) in listOf(10 to 1, 20 to 2, 30 to 4, 40 to 3, 50 to 5, 60 to 6, 70 to 7))
            for (channel in 0..2) if (mask and (1 shl channel) != 0) bins[channel * 256 + bin] = 1
        return RgbHistogram.fromNative(4, 1, bins)!!
    }
}
