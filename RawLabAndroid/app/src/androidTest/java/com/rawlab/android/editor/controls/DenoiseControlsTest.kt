package com.rawlab.android.editor.controls

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
import com.rawlab.android.settings.DenoisePreset
import com.rawlab.android.settings.DenoiseSettings
import com.rawlab.android.testing.LanguageTestRule
import com.rawlab.android.testing.setChineseContent

class DenoiseControlsTest {
    val compose = createComposeRule()
    @get:Rule val languageAndCompose = org.junit.rules.RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test fun presetsAndDisablePreserveValuesInCompactLayout() {
        var value by mutableStateOf(DenoiseSettings())
        compose.setChineseContent {
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

    // 标题与开关之间要留出间隔，不能贴在一起
    @Test fun titleKeepsAGapBeforeTheSwitch() {
        compose.setChineseContent {
            MaterialTheme { Box(Modifier.width(360.dp)) { DenoiseControls(DenoiseSettings(), true) { _, _ -> } } }
        }
        val title = compose.onNodeWithText("降噪", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        val switch = compose.onNode(isToggleable()).fetchSemanticsNode().boundsInRoot
        val gap = with(compose.density) { (switch.left - title.right).toDp() }
        assertTrue("gap=$gap", gap >= 8.dp)
    }

    // 整组重置要说清楚是“重置降噪”，不能和三条参数各自的“重置此项”同名
    @Test fun groupResetIsNamedAfterTheGroup() {
        compose.setChineseContent {
            MaterialTheme { Box(Modifier.width(360.dp)) { DenoiseControls(DenoiseSettings(), true) { _, _ -> } } }
        }
        compose.onNodeWithContentDescription("重置降噪").assertExists()
        compose.onAllNodesWithContentDescription("重置此项").assertCountEquals(3)
    }
}
