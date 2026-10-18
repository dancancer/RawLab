package com.rawlab.android.editor.geometry

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import com.rawlab.android.R
import com.rawlab.android.editor.AdjustmentDraft
import com.rawlab.android.editor.AdjustmentGroup
import com.rawlab.android.geometry.GeometryRatio
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.settings.EditSettings

class GeometryControlsTest {
    @get:Rule val compose = createComposeRule()

    @Test fun perspectiveAndCompleteRatiosUseTheGenericDraft() {
        var draft by mutableStateOf(AdjustmentDraft.begin(AdjustmentGroup.GEOMETRY, EditSettings(), 2f / 3f, 2f / 3f))
        compose.setContent {
            MaterialTheme {
                Column(Modifier.width(360.dp).verticalScroll(rememberScrollState())) {
                    GeometryControls(draft.value.geometry, true, draft.geometryRatio, draft.geometryPortrait,
                        onRatioChange = { ratio, portrait -> draft = draft.selectGeometryRatio(ratio, portrait) }) { next, _ ->
                        draft = draft.update(draft.value.copy(geometry = next))
                    }
                }
            }
        }
        for ((label, input) in listOf(R.string.geometry_perspective_horizontal to "25", R.string.geometry_perspective_vertical to "-40")) {
            compose.onNodeWithTag("adjustment-value-$label").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-input").performTextReplacement(input)
            compose.onNodeWithTag("adjustment-input-apply").performClick()
        }
        compose.runOnIdle {
            assertEquals(.25f, draft.value.geometry.perspectiveHorizontal, 0f)
            assertEquals(-.4f, draft.value.geometry.perspectiveVertical, 0f)
        }
        compose.onNodeWithTag("geometry.ratios").performScrollTo()
        for (ratio in GeometryRatio.entries) {
            compose.onNodeWithTag("geometry.ratios").performScrollToNode(hasTestTag("geometry.ratio-${ratio.name}"))
            compose.onNodeWithTag("geometry.ratio-${ratio.name}").performClick().assertIsSelected()
            compose.runOnIdle {
                assertEquals(ratio, draft.geometryRatio)
                draft.geometryAspect?.let {
                    assertEquals(it, draft.value.geometry.cropWidth * (2f / 3f) / draft.value.geometry.cropHeight, .00001f)
                }
            }
        }
        compose.onNodeWithTag("geometry.ratios").performScrollToNode(hasTestTag("geometry.swap-ratio"))
        compose.onNodeWithTag("geometry.swap-ratio").performClick()
        compose.runOnIdle {
            assertFalse(draft.geometryPortrait)
            assertEquals(16f / 9f, draft.geometryAspect!!, .00001f)
        }
    }

    @Test fun compactControlsValidateCropRotateFlipAndReset() {
        var value by mutableStateOf(GeometrySettings())
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        compose.setContent {
            MaterialTheme {
                Column(Modifier.width(360.dp).verticalScroll(rememberScrollState())) {
                    GeometryControls(value, true) { next, _ -> value = next }
                }
            }
        }
        compose.onNodeWithTag("geometry.rotate-right").performScrollTo().performClick()
        compose.onNodeWithTag("geometry.flip-horizontal").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(1, value.quarterTurns); assertTrue(value.flipHorizontal) }
        compose.onNodeWithTag("adjustment-value-${R.string.geometry_crop_width}").performScrollTo().performClick()
        compose.onNodeWithTag("adjustment-input").performTextReplacement("110")
        compose.onNodeWithTag("adjustment-input-apply").assertIsNotEnabled()
        compose.onNodeWithTag("adjustment-input").performTextReplacement("75")
        compose.onNodeWithTag("adjustment-input-apply").performClick()
        compose.onNodeWithTag("adjustment-value-${R.string.geometry_crop_x}").performScrollTo().performClick()
        compose.onNodeWithTag("adjustment-input").performTextReplacement("20")
        compose.onNodeWithTag("adjustment-input-apply").performClick()
        compose.runOnIdle { assertEquals(.2f, value.cropX); assertEquals(.75f, value.cropWidth) }
        compose.onNodeWithContentDescription(context.getString(R.string.geometry_reset)).performScrollTo().performClick()
        compose.runOnIdle { assertEquals(GeometrySettings(), value) }
    }
}
