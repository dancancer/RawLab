package com.rawlab.android

import android.graphics.Bitmap
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import androidx.compose.foundation.layout.width
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import java.io.File

class PhotoEffectsControlsTest {
    @get:Rule val compose = createComposeRule()

    @Test fun vignetteToolShowsFullParameterSetAndGroupReset() {
        var value by mutableStateOf(PhotoEffectsSettings(
            vignetteAmount = -40f, vignetteMidpoint = 20f, vignetteHighlights = 65f,
            grainAmount = 50f,
        ))
        compose.setContent {
            RawLabTheme {
                Surface(Modifier.width(360.dp).testTag("effects-controls")) {
                    PhotoEffectsControls(value, vignette = true, enabled = true) { next, _ -> value = next }
                }
            }
        }
        listOf("强度", "中点", "圆度", "羽化", "高光保护").forEach {
            compose.onNodeWithText(it).assertIsDisplayed()
        }
        capture("vignette")
        compose.onNodeWithContentDescription("重置暗角").performClick()
        compose.runOnIdle {
            assertEquals(PhotoEffectsSettings().copy(grainAmount = 50f), value)
        }
    }

    @Test fun grainToolShowsIndependentParameterSet() {
        compose.setContent {
            RawLabTheme {
                Surface(Modifier.width(600.dp).testTag("effects-controls")) {
                    PhotoEffectsControls(PhotoEffectsSettings(), vignette = false, enabled = true) { _, _ -> }
                }
            }
        }
        listOf("强度", "大小", "粗糙度").forEach {
            compose.onNodeWithText(it).assertIsDisplayed()
        }
        compose.onNodeWithText("高光保护").assertDoesNotExist()
        capture("grain")
    }

    private fun capture(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val directory = requireNotNull(instrumentation.targetContext.getExternalFilesDir("effects-screenshots"))
        val bitmap = compose.onNodeWithTag("effects-controls").captureToImage().asAndroidBitmap()
        File(directory, "$name.png").outputStream().use {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }
}
