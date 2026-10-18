package com.rawlab.android.editor.controls

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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import java.io.File
import com.rawlab.android.RawLabTheme
import com.rawlab.android.editor.panels.PhotoEffectsControls
import com.rawlab.android.settings.PhotoEffectsSettings
import com.rawlab.android.testing.LanguageTestRule

class PhotoEffectsControlsTest {
    val compose = createComposeRule()
    @get:Rule val languageAndCompose = org.junit.rules.RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test fun vignetteToolShowsFullParameterSetAndGroupReset() {
        var value by mutableStateOf(PhotoEffectsSettings(
            vignetteAmount = -40f, vignetteMidpoint = 20f, vignetteHighlights = 65f,
            grainAmount = 50f,
        ))
        compose.setContent {
            RawLabTheme {
                Surface(Modifier.width(360.dp).testTag("effects-controls").verticalScroll(rememberScrollState())) {
                    PhotoEffectsControls(value, vignette = true, enabled = true) { next, _ -> value = next }
                }
            }
        }
        compose.onNodeWithText("展开暗角参数").performClick()
        listOf("强度", "中点", "圆度", "羽化", "高光保护").forEach {
            compose.onNodeWithText(it).performScrollTo().assertIsDisplayed()
        }
        capture("vignette")
        compose.onNodeWithContentDescription("重置暗角").performScrollTo().performClick()
        compose.runOnIdle {
            assertEquals(PhotoEffectsSettings().copy(grainAmount = 50f), value)
        }
    }

    @Test fun vignetteStartsWithOnlyIntensityAndRevealsResetWithAdvancedParameters() {
        var value by mutableStateOf(PhotoEffectsSettings(vignetteAmount = -40f, vignetteMidpoint = 20f))
        compose.setContent {
            RawLabTheme {
                Surface(Modifier.width(360.dp).testTag("effects-controls").verticalScroll(rememberScrollState())) {
                    PhotoEffectsControls(value, vignette = true, enabled = true) { next, _ -> value = next }
                }
            }
        }
        compose.onNodeWithText("强度").assertIsDisplayed()
        compose.onNodeWithText("中点").assertDoesNotExist()
        compose.onNodeWithContentDescription("重置暗角").assertDoesNotExist()
        compose.onNodeWithContentDescription("重置此项").assertDoesNotExist()

        compose.onNodeWithText("展开暗角参数").performClick()
        compose.onNodeWithText("中点").assertIsDisplayed()
        compose.onNodeWithContentDescription("重置暗角").assertIsDisplayed()
        compose.onAllNodesWithContentDescription("重置此项").assertCountEquals(5)
    }

    @Test fun grainToolShowsIndependentParameterSet() {
        compose.setContent {
            RawLabTheme {
                Surface(Modifier.width(600.dp).testTag("effects-controls").verticalScroll(rememberScrollState())) {
                    PhotoEffectsControls(PhotoEffectsSettings(), vignette = false, enabled = true) { _, _ -> }
                }
            }
        }
        listOf("强度", "大小", "粗糙度").forEach {
            compose.onNodeWithText(it).performScrollTo().assertIsDisplayed()
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
