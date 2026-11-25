package com.rawlab.android.editor

import com.rawlab.android.adjustments.AdjustmentFailure
import com.rawlab.android.adjustments.AdjustmentField
import com.rawlab.android.adjustments.AdjustmentPayload
import com.rawlab.android.adjustments.AdjustmentScope
import com.rawlab.android.adjustments.AdjustmentTransfer
import com.rawlab.android.adjustments.AdjustmentTransferContext
import com.rawlab.android.adjustments.AdjustmentTransferException
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.editor.storage.EditSaveResult
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.looks.MasterRecipe
import com.rawlab.android.looks.applyRecipe
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HslTargetAvailability
import com.rawlab.android.settings.HslTargetRevision
import com.rawlab.android.settings.HslTargetSample
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.settings.ToneCurveChannel
import com.rawlab.android.settings.ToneCurveMode
import com.rawlab.android.settings.ToneCurveParametric
import com.rawlab.android.settings.ToneCurvePoint
import com.rawlab.android.settings.ToneCurveSettings
import com.rawlab.android.settings.ToneCurveShape
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import kotlin.math.abs

class EditorCurveTargetTest {
    // Smooth monotonic surrogate for Shadows +80 parametric lift: parametric(0.2000) == 0.2860.
    private fun parametricLift(x: Double): Double =
        (x + 0.086 * (1.0 - ((x - 0.2) / 0.8).let { it * it }) * (4.0 * x * (1.0 - x) / 0.64))
            .coerceIn(0.0, 1.0)

    @Test
    fun curveTargetClickWithActiveParametricPlacesPointAtParametricXWithZeroJump() {
        EditorViewModelTestHarness().use { harness ->
            val (file, uri) = harness.createTempPhoto("curve-target.raw")
            val photo = ImportedPhoto(
                uri,
                file.name,
                file,
                PhotoIdentity("photo-1"),
                PhotoInputKind.RAW,
            )
            val curve = ToneCurveSettings(
                mode = ToneCurveMode.CUSTOM,
                points = ToneCurveShape.identity.inserting(0.5, 0.5).points,
                parametric = ToneCurveParametric(shadows = 80.0),
            )
            val baseEdits = EditSettings(curve = curve)
            val previewPair = TestBitmaps.pair(800, 600)
            val session = EditorDocumentSession(harness.createDependencies(), harness.scope).apply {
                mutable.value = EditorState(
                    photo = photo,
                    edits = baseEdits,
                    preview = previewPair,
                    exact = true,
                    draft = AdjustmentDraft.begin(AdjustmentGroup.CURVE, baseEdits, 4f / 3f, 4f / 3f),
                )
                incrementSourceRevision()
                updateCurrentRevision(1L)
            }
            val revision = HslTargetRevision(1L, 1L)
            val previewWork = Work.Preview(photo, baseEdits, interactive = false, gpuMode = 0, edge = 800, draft = true)
            var submittedProbe: Work.HslProbe? = null
            var parametricCalls = 0
            session.actions.submitRender = { work -> submittedProbe = work as Work.HslProbe; 2L }
            session.actions.changeDraft = { next, interactive ->
                session.mutable.value = session.mutable.value.copy(draft = session.mutable.value.draft?.update(next, interactive))
            }

            val holder = EditorHslEyedropperStateHolder(
                session = session,
                sampleCurve = { settings, channel ->
                    // Sample combined curve pointCurve(parametric(x)) when RGB parametric is active.
                    val shape = settings.shape(channel)
                    (0..256).map { i ->
                        val x = i / 256.0
                        val afterParam = if (channel == ToneCurveChannel.RGB && !settings.parametric.isIdentity) {
                            parametricLift(x)
                        } else {
                            x
                        }
                        // Identity point curve [0, 0.5, 1] maps afterParam -> afterParam.
                        require(shape.points.all { abs(it.x - it.y) < 1e-12 })
                        ToneCurvePoint(x, afterParam)
                    }
                },
                sampleParametric = { _, x ->
                    parametricCalls += 1
                    parametricLift(x)
                },
            )
            holder.recordAcceptedPreview(previewWork, baseEdits, 1L, 1L)
            holder.setEnabled(true)

            // Click on a shadow pixel whose post-parametric output luminance is 0.2860 (xIn == 0.2000).
            val yOut = parametricLift(0.2)
            assertEquals(0.286, yOut, 1e-6)
            holder.begin(0.4f, 0.6f)
            val probe = requireNotNull(submittedProbe)
            val sample = HslTargetSample(
                revision = revision,
                availability = HslTargetAvailability.AVAILABLE,
                rgb = listOf(yOut.toFloat(), yOut.toFloat(), yOut.toFloat()),
                weights = listOf(1f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
                preview = true,
            )
            holder.accept(WorkResult.HslProbe(probe, sample))

            assertTrue("Expected sampleParametric to be invoked for active RGB parametric curve", parametricCalls > 0)
            val updatedCurve = session.mutable.value.visibleEdits.curve
            assertEquals(4, updatedCurve.points.size)
            val inserted = updatedCurve.points[1]
            // Point must land at (parametric(0.2), yOut) == (0.286, 0.286) with zero jump on click!
            assertEquals(yOut, inserted.x, 1e-3)
            assertEquals(yOut, inserted.y, 1e-3)
            assertEquals("Zero curve distortion on click before drag", inserted.x, inserted.y, 1e-3)

            // Dragging on Red channel must NOT apply RGB parametricEvaluator.
            val redCallsBefore = parametricCalls
            holder.setCurveChannel(ToneCurveChannel.RED)
            holder.begin(0.4f, 0.6f)
            val redProbe = requireNotNull(submittedProbe)
            holder.accept(
                WorkResult.HslProbe(
                    redProbe,
                    HslTargetSample(
                        revision = revision,
                        availability = HslTargetAvailability.AVAILABLE,
                        rgb = listOf(0.25f, 0.5f, 0.5f),
                        weights = listOf(1f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
                        preview = true,
                    ),
                ),
            )
            assertEquals(redCallsBefore, parametricCalls)
        }
    }

    @Test
    fun draftStateHolderCancelsAndClearsCurveTargetInteraction() {
        EditorViewModelTestHarness().use { harness ->
            val (file, uri) = harness.createTempPhoto("curve-draft.raw")
            val photo = ImportedPhoto(uri, file.name, file, PhotoIdentity("curve-draft"), PhotoInputKind.RAW)
            val curveEdits = EditSettings(curve = ToneCurveSettings.identity.inserting(0.5, 0.6))
            val session = EditorDocumentSession(
                harness.createDependencies(previewResizeDelayMs = 10L),
                harness.scope,
            ).apply {
                mutable.value = EditorState(
                    photo = photo,
                    edits = EditSettings(),
                    preview = TestBitmaps.pair(800, 600),
                    exact = true,
                )
                incrementSourceRevision()
                incrementEditRevision()
                updateCurrentRevision(1L)
            }
            var cancelCalls = 0
            var clearDisableCalls = 0
            session.actions.cancelHslTarget = { cancelCalls += 1 }
            session.actions.clearHslTarget = { disable -> if (disable) clearDisableCalls += 1 }
            session.actions.submitRender = { 2L }
            session.actions.persist = { _, _, _, completed -> completed(EditSaveResult(EditSaveState.SAVED)) }

            val holder = EditorDraftStateHolder(session)

            holder.beginDraft(AdjustmentGroup.CURVE)
            holder.updatePreviewSize(800)
            assertEquals("updatePreviewSize during CURVE draft should cancel target interaction", 1, cancelCalls)

            holder.changeDraft(curveEdits, false)
            session.mutable.value = session.mutable.value.copy(exact = true, rendering = false)
            var applied = false
            holder.applyDraft { applied = it }
            assertTrue(applied)
            assertEquals("applyDraft on CURVE draft should clear(disable=true) target interaction", 1, clearDisableCalls)

            session.mutable.value = session.mutable.value.copy(exact = true, rendering = false)
            holder.beginDraft(AdjustmentGroup.CURVE)
            holder.changeDraft(EditSettings(curve = ToneCurveSettings.identity.inserting(0.5, 0.7)), false)
            holder.discardDraft()
            assertEquals("discardDraft on CURVE draft should clear(disable=true) target interaction", 2, clearDisableCalls)
        }
    }

    @Test
    fun zeroStrengthRecipeRefinementReportsCurveParametricField() {
        val recipe = MasterRecipe.decode(JSONObject(File("../../Shared/fixtures/master-recipe-v4.json").readText()))
        val context = AdjustmentTransferContext("source", true, setOf("recipe:${recipe.id}"), cameraTemperature = 5200f, cameraTint = 10f)
        val source = EditSettings(
            curve = ToneCurveSettings(
                mode = ToneCurveMode.CUSTOM,
                points = ToneCurveShape.identity.points,
                parametric = ToneCurveParametric(shadows = 40.0),
            ),
        )
        val target = EditSettings().applyRecipe(recipe).copy(strength = 0f)
        val payload = AdjustmentTransfer.capture(
            AdjustmentScope.Custom(setOf(AdjustmentField.CURVE, AdjustmentField.CURVE_PARAMETRIC)),
            source,
            context,
        )
        val thrown = assertThrows(AdjustmentTransferException::class.java) {
            AdjustmentTransfer.prepare(payload, target, context)
        }
        assertEquals(AdjustmentFailure.UNREPRESENTABLE, thrown.reason)
        assertEquals(AdjustmentField.CURVE_PARAMETRIC.id, thrown.field)
    }
}
