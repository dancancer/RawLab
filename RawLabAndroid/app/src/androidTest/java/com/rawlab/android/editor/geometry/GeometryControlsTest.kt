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
import com.rawlab.android.RawLabTheme
import com.rawlab.android.testing.openGeometryDimensions
import com.rawlab.android.testing.chooseGeometryMenuItem
import com.rawlab.android.editor.*
import com.rawlab.android.editor.ui.EditorScreen
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.photo.ImportedPhoto
import android.graphics.Bitmap
import android.net.Uri
import java.io.File
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
        var perspective by mutableStateOf(true)
        compose.setContent {
            MaterialTheme {
                Column(Modifier.width(360.dp).verticalScroll(rememberScrollState())) {
                    GeometryControls(draft.value.geometry, true, draft.geometryRatio, draft.geometryPortrait,
                        onRatioChange = { ratio, portrait -> draft = draft.selectGeometryRatio(ratio, portrait) },
                        physicalAspect = draft.geometryAspect, canvasAspect = draft.geometryCanvasAspect,
                        perspective = perspective) { next, _ ->
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
            perspective = false
        }
        for (ratio in GeometryRatio.entries) {
            compose.onNodeWithTag("geometry.ratios").performScrollTo().performClick()
            compose.onNodeWithTag("geometry.ratio-${ratio.name}").performClick()
            compose.runOnIdle {
                assertEquals(ratio, draft.geometryRatio)
                draft.geometryAspect?.let {
                    assertEquals(it, draft.value.geometry.cropWidth * (2f / 3f) / draft.value.geometry.cropHeight, .00001f)
                }
            }
        }
        compose.chooseGeometryMenuItem("geometry.swap-ratio")
        compose.runOnIdle {
            assertFalse(draft.geometryPortrait)
            assertEquals(16f / 9f, draft.geometryAspect!!, .00001f)
        }
    }

    @Test fun compactControlsValidateCropRotateFlipAndReset() {
        var value by mutableStateOf(GeometrySettings())
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val bitmap = Bitmap.createBitmap(60, 90, Bitmap.Config.ARGB_8888)
        fun draft() = AdjustmentDraft.begin(AdjustmentGroup.GEOMETRY, EditSettings()).update(EditSettings(geometry = value))
        compose.setContent {
            RawLabTheme {
                EditorScreen(EditorState(
                    photo = ImportedPhoto(Uri.parse("content://geometry/controls"), "fixture.RAW", File("fixture.RAW")),
                    preview = PreviewPair(bitmap, bitmap, 6500f, 0f), exact = true, draft = draft()),
                    {}, {}, { _, _ -> }, {}, {}, {}, {}, {},
                    onDraftEdit = { next, _ -> value = next.geometry },
                    onPrepareReset = { scope -> EditorResetTransaction.prepare(scope, EditorResetSession(
                        com.rawlab.android.settings.PhotoIdentity("geometry-controls"), "fixture.RAW", 1, 1,
                        EditSettings(), draft(), 0,
                        EditorResetContext(com.rawlab.android.format.PhotoInputKind.RAW, EditSettings(), AsShotWhiteBalance(6500f, 0f)))) },
                    onCommitReset = { value = it.draftCandidate!!.value.geometry; true })
            }
        }
        compose.onNodeWithTag("geometry.rotate-right").performScrollTo().performClick()
        compose.onNodeWithTag("geometry.flip-horizontal").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(1, value.quarterTurns); assertTrue(value.flipHorizontal) }
        compose.openGeometryDimensions()
        compose.onNodeWithTag("adjustment-value-${R.string.geometry_crop_width}").assertIsDisplayed().performClick()
        compose.onNodeWithTag("adjustment-input").performTextReplacement("110")
        compose.onNodeWithTag("adjustment-input-apply").assertIsNotEnabled()
        compose.onNodeWithTag("adjustment-input").performTextReplacement("75")
        compose.onNodeWithTag("adjustment-input-apply").performClick()
        compose.onNodeWithTag("adjustment-value-${R.string.geometry_crop_x}").assertIsDisplayed().performClick()
        compose.onNodeWithTag("adjustment-input").performTextReplacement("20")
        compose.onNodeWithTag("adjustment-input-apply").performClick()
        compose.runOnIdle { assertEquals(.2f, value.cropX); assertEquals(.75f, value.cropWidth) }
        compose.onNodeWithText(context.getString(R.string.confirm)).performClick()
        compose.onNodeWithContentDescription(context.getString(R.string.reset)).performClick()
        compose.onNodeWithTag("editor-reset-tool").performClick()
        compose.runOnIdle { assertEquals(GeometrySettings(), value) }
    }

    @Test fun cropDialogPreservesUnchangedPrecisionAndLinksLockedDimensions() {
        val original = GeometrySettings(cropWidth = .7123456f, cropHeight = .6123456f)
        var draft by mutableStateOf(AdjustmentDraft.begin(AdjustmentGroup.GEOMETRY,
            EditSettings(geometry = original), canvasAspect = 1.5f))
        compose.setContent {
            MaterialTheme {
                Column(Modifier.width(360.dp).verticalScroll(rememberScrollState())) {
                    GeometryControls(draft.value.geometry, true, draft.geometryRatio, draft.geometryPortrait,
                        lockedRatio = draft.geometryLockedRatio, physicalAspect = draft.geometryAspect,
                        canvasAspect = draft.geometryCanvasAspect, onLock = { draft = draft.toggleGeometryLock() },
                        onSwap = { draft = draft.swapGeometryRatio() }) { next, _ ->
                        draft = draft.update(draft.value.copy(geometry = next))
                    }
                }
            }
        }
        compose.openGeometryDimensions()
        fun openWidth() = compose.onNodeWithTag("adjustment-value-${R.string.geometry_crop_width}").assertIsDisplayed().performClick()
        openWidth()
        compose.onNodeWithTag("adjustment-input").assertTextEquals("71.23")
        compose.onNodeWithTag("adjustment-input-apply").performClick()
        compose.runOnIdle { assertEquals(original, draft.value.geometry); assertFalse(draft.changed) }
        compose.onNodeWithText(InstrumentationRegistry.getInstrumentation().targetContext.getString(R.string.confirm)).performClick()
        compose.chooseGeometryMenuItem("geometry.lock-ratio")
        compose.openGeometryDimensions()
        openWidth()
        compose.onNodeWithTag("adjustment-input").performTextReplacement("60.015")
        compose.onNodeWithTag("adjustment-input-apply").assertIsNotEnabled()
        compose.onNodeWithTag("adjustment-input").performTextReplacement("60.01")
        compose.onNodeWithTag("adjustment-input-apply").performClick()
        compose.runOnIdle {
            assertEquals(.6001f, draft.value.geometry.cropWidth, .000001f)
            assertEquals(original.cropWidth * 1.5f / original.cropHeight,
                draft.value.geometry.cropWidth * 1.5f / draft.value.geometry.cropHeight, .000001f)
            assertNotNull(draft.geometryLockedRatio)
        }
        compose.onNodeWithText(InstrumentationRegistry.getInstrumentation().targetContext.getString(R.string.confirm)).performClick()
        compose.chooseGeometryMenuItem("geometry.swap-ratio")
        compose.runOnIdle {
            assertEquals(1f / (original.cropWidth * 1.5f / original.cropHeight), draft.geometryAspect!!, .000001f)
        }
    }
}
