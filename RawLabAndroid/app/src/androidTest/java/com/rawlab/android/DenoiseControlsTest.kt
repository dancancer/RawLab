package com.rawlab.android

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class DenoiseControlsTest {
    @get:Rule val compose = createComposeRule()

    @Test fun presetsAndDisablePreserveValuesInCompactLayout() {
        var value by mutableStateOf(DenoiseSettings())
        compose.setContent {
            MaterialTheme {
                Box(Modifier.width(360.dp)) { DenoiseControls(value, true) { next, _ -> value = next } }
            }
        }
        compose.onNodeWithText("细节优先").performClick()
        compose.onNodeWithText("去噪优先").performClick()
        compose.runOnIdle { assertEquals(DenoiseSettings().withPreset(DenoisePreset.CLEAN), value) }
        listOf("亮度降噪", "色彩降噪", "粗色斑抑制").forEach { compose.onNodeWithText(it).assertIsDisplayed() }
        compose.onNode(isToggleable()).performClick()
        compose.runOnIdle {
            assertFalse(value.enabled)
            assertEquals(72f, value.chroma)
            assertEquals(100f, value.coarse)
        }
        compose.onNode(isToggleable()).performClick()
        val image = compose.onRoot().captureToImage().asAndroidBitmap()
        val directory = InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null)
        File(directory, "denoise-controls-compact.png").outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
