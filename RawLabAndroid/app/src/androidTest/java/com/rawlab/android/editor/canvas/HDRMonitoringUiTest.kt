package com.rawlab.android.editor.canvas

import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.os.Build
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import com.rawlab.android.editor.render.HDRBitmapAdapter
import com.rawlab.android.editor.render.HDRPreviewFrame
import com.rawlab.android.engine.HDRDisplayParameters
import com.rawlab.android.engine.HDRDisplayState
import com.rawlab.android.engine.HDRPreviewMode
import com.rawlab.android.engine.HDRStatistics
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

class HDRMonitoringUiTest {
    @get:Rule
    val compose = createComposeRule()

    private fun sampleStatistics(): HDRStatistics {
        val pixels = FloatArray(12) { 1.5f }
        return HDRStatistics.analyze(pixels, 2, 2, 6)
    }

    private fun sampleFrame(width: Int, height: Int, hdrValue: Float): HDRPreviewFrame {
        val count = width * height * 3
        return HDRPreviewFrame(
            width = width,
            height = height,
            hdr = FloatArray(count) { hdrValue },
            sdr = FloatArray(count) { 0.5f },
            contentHeadroom = maxOf(1f, hdrValue),
            sourceHeadroom = 4f,
        )
    }

    @Test
    fun monitoringDistinguishesHardwareUnavailableFromTransientSdrHeadroom() {
        var displayState by mutableStateOf(HDRDisplayState(available = false, headroom = 1f, reason = "No HDR"))
        var previewMode by mutableStateOf(HDRPreviewMode.AUTOMATIC)
        val stats = sampleStatistics()

        compose.setContent {
            MaterialTheme {
                HDRMonitoring(
                    statistics = stats,
                    display = displayState,
                    mode = previewMode,
                    falseColor = false,
                    onMode = { previewMode = it },
                    onFalseColor = {},
                )
            }
        }

        compose.onNodeWithTag("hdr-display-unavailable").assertIsDisplayed()
        compose.onNodeWithTag("hdr-sdr-fallback").assertDoesNotExist()

        compose.runOnIdle {
            displayState = HDRDisplayState(available = true, headroom = 1f, reason = "Display headroom is SDR")
        }
        compose.onNodeWithTag("hdr-display-unavailable").assertDoesNotExist()
        compose.onNodeWithTag("hdr-sdr-fallback").assertIsDisplayed()

        compose.runOnIdle {
            displayState = HDRDisplayState(available = true, headroom = 2.5f, reason = null)
        }
        compose.onNodeWithTag("hdr-display-unavailable").assertDoesNotExist()
        compose.onNodeWithTag("hdr-sdr-fallback").assertDoesNotExist()
    }

    @Test
    fun rememberBitmapRetainsPreviousFp16BitmapDuringSameKeyFrameUpdates() {
        assumeTrue(Build.VERSION.SDK_INT >= 26)
        var frameState by mutableStateOf<HDRPreviewFrame?>(sampleFrame(64, 48, 2.0f))
        var enabledState by mutableStateOf(true)
        var resetKeyState by mutableStateOf<Any>("photo-1")
        val observed = mutableListOf<Bitmap?>()
        var recording = false
        var latestBitmap: Bitmap? = null

        compose.setContent {
            val bitmap = HDRBitmapAdapter.rememberBitmap(
                frame = frameState,
                parameters = HDRDisplayParameters(headroom = 4.0f),
                enabled = enabledState,
                resetKey = resetKeyState,
            )
            SideEffect {
                latestBitmap = bitmap
                if (recording) observed += bitmap
            }
        }

        compose.waitUntil(5_000) { latestBitmap != null }
        val firstBitmap = latestBitmap!!
        assertEquals(Bitmap.Config.RGBA_F16, firstBitmap.config)
        assertEquals(ColorSpace.Named.LINEAR_EXTENDED_SRGB.ordinal, firstBitmap.colorSpace!!.id)

        observed.clear()
        recording = true
        compose.runOnIdle {
            frameState = sampleFrame(128, 96, 3.0f)
        }
        compose.waitUntil(5_000) { latestBitmap != null && latestBitmap !== firstBitmap && latestBitmap!!.width == 128 }
        val secondBitmap = latestBitmap!!
        assertTrue("Expected at least one recorded recomposition", observed.isNotEmpty())
        assertTrue("Expected no null flash during same-photo frame update", observed.all { it != null })

        observed.clear()
        compose.runOnIdle {
            resetKeyState = "photo-2"
        }
        compose.waitUntil(5_000) {
            latestBitmap != null && latestBitmap !== secondBitmap
        }
        assertTrue("Expected at least one recorded recomposition after resetKey change", observed.isNotEmpty())
        assertNull("Expected retained bitmap to clear immediately when resetKey changes", observed.first())

        compose.runOnIdle {
            enabledState = false
        }
        compose.waitForIdle()
        assertNull(latestBitmap)
    }
}
