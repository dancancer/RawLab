package com.rawlab.android

import android.net.TestUri
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class GeometryEditorStateTest {
    private val committedGeometry = GeometrySettings(.1f, .2f, .7f, .6f, 1, true, false, 5f, .2f, -.3f)
    private val committedEdits = EditSettings(film = "velvia", geometry = committedGeometry, exposureMode = 2)
    private val photo = ImportedPhoto(TestUri.value, "photo.raw", File("photo.raw"))

    private fun baseline() = EditorState(
        photo = photo,
        edits = committedEdits,
        preview = null,
        exact = true,
        saveState = EditSaveState.SAVED,
        message = "Saved edits",
    )

    private fun draft() = baseline().copy(
        geometryDraft = committedGeometry,
        geometryPreviewReady = true,
        geometryCanvasAspect = 1.5f,
        exact = false,
    )

    @Test fun cropOnlyChangeUpdatesDraftWithoutPreviewOrCommittedSaveChanges() {
        val current = draft()
        val crop = committedGeometry.copy(cropX = .2f, cropY = .1f, cropWidth = .5f, cropHeight = .8f)

        val mutation = EditorStateReducer.geometryChanged(current, crop)

        assertNull(mutation.preview)
        assertEquals(current.copy(geometryDraft = crop), mutation.state)
        assertSame(committedEdits, mutation.state.edits)
        assertEquals(EditSaveState.SAVED, mutation.state.saveState)
        assertEquals("Saved edits", mutation.state.message)
        assertFalse(mutation.state.rendering)
    }

    @Test fun eachTransformRequestsUncroppedPreviewWithoutCommittingDraft() {
        val current = draft()
        val changedCrop = committedGeometry.copy(cropX = .2f, cropY = .1f, cropWidth = .5f, cropHeight = .8f)
        val transforms = listOf(
            changedCrop.copy(quarterTurns = 2),
            changedCrop.copy(flipHorizontal = false),
            changedCrop.copy(flipVertical = true),
            changedCrop.copy(straightenDegrees = -8f),
            changedCrop.copy(perspectiveHorizontal = -.4f),
            changedCrop.copy(perspectiveVertical = .4f),
        )

        for (value in transforms) {
            val mutation = EditorStateReducer.geometryChanged(current, value)

            assertEquals(current.copy(geometryDraft = value, geometryPreviewReady = false, rendering = true), mutation.state)
            assertSame(committedEdits, mutation.state.edits)
            assertEquals(current.saveState, mutation.state.saveState)
            assertEquals(committedEdits.copy(geometry = value.uncropped()), mutation.preview)
            assertEquals(0f, mutation.preview!!.geometry.cropX)
            assertEquals(0f, mutation.preview.geometry.cropY)
            assertEquals(1f, mutation.preview.geometry.cropWidth)
            assertEquals(1f, mutation.preview.geometry.cropHeight)
        }
    }

    @Test fun resetToIdentityChangesOnlyDraftAndRequestsIdentityCanvas() {
        val current = draft()

        val mutation = EditorStateReducer.geometryChanged(current, GeometrySettings())

        assertEquals(current.copy(geometryDraft = GeometrySettings(), geometryPreviewReady = false, rendering = true), mutation.state)
        assertSame(committedEdits, mutation.state.edits)
        assertEquals(current.saveState, mutation.state.saveState)
        assertEquals(committedEdits.copy(geometry = GeometrySettings()), mutation.preview)
        assertTrue(mutation.state.geometryDraft!!.isIdentity)
        assertFalse(mutation.state.edits.geometry.isIdentity)
    }

    @Test fun applyCommitsCompleteCroppedDraftAndRequestsReplacementRender() {
        val geometry = committedGeometry.copy(cropX = .2f, cropY = .1f, cropWidth = .5f, cropHeight = .8f,
            quarterTurns = 3, flipVertical = true, straightenDegrees = -7f)
        val current = draft().copy(geometryDraft = geometry, error = "Earlier preview failed")

        val mutation = EditorStateReducer.geometryApplied(current)

        val expectedEdits = committedEdits.copy(geometry = geometry)
        assertEquals(expectedEdits, mutation.state.edits)
        assertEquals(expectedEdits, mutation.preview)
        assertEquals(geometry, mutation.preview!!.geometry)
        assertNotEquals(geometry.uncropped(), mutation.preview.geometry)
        assertNull(mutation.state.geometryDraft)
        assertFalse(mutation.state.geometryPreviewReady)
        assertTrue(mutation.state.rendering)
        assertFalse(mutation.state.exact)
        assertNull(mutation.state.error)
        assertEquals(current.saveState, mutation.state.saveState)
        assertEquals(photo, mutation.state.photo)
    }

    @Test fun applyingUnchangedDraftStillRequestsCroppedReplacementRender() {
        val current = draft()

        val mutation = EditorStateReducer.geometryApplied(current)

        assertEquals(committedEdits, mutation.preview)
        assertEquals(committedGeometry, mutation.preview!!.geometry)
        assertEquals(committedEdits, mutation.state.edits)
        assertNull(mutation.state.geometryDraft)
        assertFalse(mutation.state.geometryPreviewReady)
        assertTrue(mutation.state.rendering)
        assertFalse(mutation.state.exact)
    }

    @Test fun cancelAfterCropAndTransformRestoresBaselinePreviewAndReadiness() {
        val baseline = baseline().copy(error = "Baseline message")
        val entered = baseline.copy(geometryDraft = committedGeometry, geometryPreviewReady = true, exact = false)
        val crop = committedGeometry.copy(cropX = .2f, cropY = .1f, cropWidth = .5f, cropHeight = .8f)
        val cropped = EditorStateReducer.geometryChanged(entered, crop).state
        val transformed = EditorStateReducer.geometryChanged(cropped, crop.copy(quarterTurns = 2)).state
        val current = transformed.copy(rendering = true, previewResizePending = true, error = "Draft preview failed")

        val cancelled = EditorStateReducer.geometryCancelled(current, baseline)

        assertSame(committedEdits, cancelled.edits)
        assertEquals(committedGeometry, cancelled.edits.geometry)
        assertEquals(baseline.preview, cancelled.preview)
        assertEquals(baseline.exact, cancelled.exact)
        assertEquals(baseline.error, cancelled.error)
        assertEquals(baseline.saveState, cancelled.saveState)
        assertEquals(baseline.message, cancelled.message)
        assertEquals(photo, cancelled.photo)
        assertNull(cancelled.geometryDraft)
        assertFalse(cancelled.geometryPreviewReady)
        assertFalse(cancelled.rendering)
        assertFalse(cancelled.previewResizePending)
    }


    @Test fun applyWithoutMatchingTransformPreviewLeavesDraftAndCommittedEditsUntouched() {
        for (current in listOf(draft().copy(rendering = true), draft().copy(geometryPreviewReady = false),
            draft().copy(geometryCanvasAspect = null))) {
            val applied = EditorStateReducer.geometryApplied(current)
            assertSame(current, applied.state)
            assertNull(applied.preview)
            assertSame(committedEdits, applied.state.edits)
            assertFalse(current.canApplyGeometry)
        }
    }

    @Test fun lockedCropRefitsBeforeApplyWithoutGrowingAfterQuarterRotation() {
        val crop = GeometrySettings(cropX = .3f, cropY = .2f, cropWidth = .4f, cropHeight = .6f)
        val current = draft().copy(geometryDraft = crop, geometryAspect = 1f)
        val pending = EditorStateReducer.geometryChanged(current, crop.rotated(true)).state
        assertFalse(pending.geometryPreviewReady)
        assertTrue(pending.rendering)
        assertNull(EditorStateReducer.geometryApplied(pending).preview)
        val accepted = EditorStateReducer.geometryPreviewAccepted(pending, 2f / 3f)
        val refitted = accepted.geometryDraft!!
        assertEquals(.6f, refitted.cropWidth, .000001f)
        assertEquals(.4f, refitted.cropHeight, .000001f)
        assertEquals(.24f, refitted.cropWidth * refitted.cropHeight, .000001f)
        assertEquals(.5f, refitted.cropX + refitted.cropWidth / 2f, .000001f)
        assertEquals(.5f, refitted.cropY + refitted.cropHeight / 2f, .000001f)
        assertEquals(1f, refitted.cropWidth / refitted.cropHeight * accepted.geometryCanvasAspect!!, .000001f)
        assertTrue(accepted.canApplyGeometry)
        assertEquals(refitted, EditorStateReducer.geometryApplied(accepted).preview!!.geometry)
    }

    @Test fun canvasChangesPreserveSizeWhileExplicitPresetSelectionMaximizesIt() {
        val crop = GeometrySettings(cropX = .3f, cropY = .2f, cropWidth = .4f, cropHeight = .6f)
        val current = draft().copy(geometryDraft = crop, geometryAspect = 1f)
        val accepted = EditorStateReducer.geometryPreviewAccepted(current.copy(rendering = true,
            geometryPreviewReady = false), 1.35f)
        assertEquals(.24f, accepted.geometryDraft!!.cropWidth * accepted.geometryDraft.cropHeight, .000001f)
        val selected = EditorStateReducer.geometryPresetSelected(accepted, 1f)
        assertTrue(selected.geometryDraft!!.cropWidth * selected.geometryDraft.cropHeight > .7f)
        val pending = selected.copy(rendering = true, geometryPreviewReady = false)
        assertSame(pending, EditorStateReducer.geometryPresetSelected(pending, 1.5f))
        val free = EditorStateReducer.geometryPresetSelected(accepted, null)
        assertNull(free.geometryAspect)
        assertEquals(accepted.geometryDraft, free.geometryDraft)
    }

    @Test fun geometryChangesAndApplyWithoutActiveDraftAreNoOps() {
        val current = baseline()

        val changed = EditorStateReducer.geometryChanged(current, GeometrySettings())
        val applied = EditorStateReducer.geometryApplied(current)

        assertSame(current, changed.state)
        assertNull(changed.preview)
        assertSame(current, applied.state)
        assertNull(applied.preview)
    }
}
