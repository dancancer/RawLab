package com.rawlab.android.editor

import org.junit.Assert.*
import org.junit.Test
import java.util.Locale
import java.io.File
import com.rawlab.android.batch.BatchExportState
import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.BatchRowStatus
import com.rawlab.android.batch.BatchSourceSnapshot
import com.rawlab.android.batch.BatchTarget
import com.rawlab.android.editor.controls.AdjustmentHapticGate
import com.rawlab.android.editor.controls.AdjustmentScale
import com.rawlab.android.editor.controls.editorUsesSideDock
import com.rawlab.android.editor.controls.formatCropPercent
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.LensSettings
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.geometry.moveCrop
import com.rawlab.android.geometry.withAspect

class AdjustmentInteractionTest {
    @Test fun negativeZeroInputAndDragProducePositiveZero() {
        val scale = AdjustmentScale(-1f..1f, .01f, 0f)
        assertEquals(0, scale.parse("-0")!!.toRawBits())
        assertEquals(0, scale.quantize(-0.001f).toRawBits())
    }

    @Test fun cropDisplayAndUnchangedInputPreserveTheExactOriginal() {
        val original = 33.333332f
        val scale = AdjustmentScale(0f..100f, .01f, 100f, compactPercent = true)
        assertEquals("33.33", formatCropPercent(original, Locale.US))
        assertEquals(original, scale.parse("33.33", Locale.US, original)!!, 0f)
        assertEquals(original, scale.parse("33,33", Locale.GERMAN, original)!!, 0f)
        assertEquals(33.34f, scale.parse("33.34", Locale.US, original)!!, 0f)
        listOf("33.345", "100.01", "-0.01", "NaN").forEach { assertNull(scale.parse(it, Locale.US, original)) }
        assertEquals("100", formatCropPercent(100f, Locale.US))
    }

    @Test fun lockingCurrentCropKeepsItsPrecisionAndHasOneRatioAuthority() {
        val source = EditSettings(geometry = GeometrySettings(cropX = .1f, cropY = .1f, cropWidth = .7123456f, cropHeight = .6123456f))
        val free = AdjustmentDraft.begin(AdjustmentGroup.GEOMETRY, source, canvasAspect = 1.5f)
        val locked = free.toggleGeometryLock()
        assertEquals(source.geometry, locked.value.geometry)
        assertEquals(source.geometry.cropWidth * 1.5f / source.geometry.cropHeight, locked.geometryAspect!!, 0f)
        val swapped = locked.swapGeometryRatio()
        assertEquals(1f / locked.geometryAspect!!, swapped.geometryAspect!!, .000001f)
        assertNull(locked.toggleGeometryLock().geometryAspect)
        assertNull(locked.selectGeometryRatio(com.rawlab.android.geometry.GeometryRatio.SQUARE, false).geometryLockedRatio)
    }

    @Test fun originalCropRatioFollowsQuarterTurnsWithinTheSameDraft() {
        val original = AdjustmentDraft.begin(AdjustmentGroup.GEOMETRY, EditSettings(), 1.5f, 1.5f)
            .selectGeometryRatio(com.rawlab.android.geometry.GeometryRatio.ORIGINAL, false)
        val rotated = original.update(original.value.copy(geometry = original.value.geometry.rotated(true)))
            .acceptGeometryCanvas(2f / 3f)
        assertEquals(2f / 3f, rotated.geometryAspect!!, .000001f)
        assertEquals(rotated.geometryAspect!!,
            rotated.value.geometry.cropWidth * rotated.geometryCanvasAspect / rotated.value.geometry.cropHeight, .000001f)
        val restored = rotated.update(rotated.value.copy(geometry = rotated.value.geometry.rotated(false)))
            .acceptGeometryCanvas(1.5f)
        assertEquals(1.5f, restored.geometryAspect!!, .000001f)
        val locked = original.toggleGeometryLock().toggleGeometryLock()
        val lockedRotated = locked.update(locked.value.copy(geometry = locked.value.geometry.rotated(true)))
        assertEquals(locked.geometryAspect, lockedRotated.geometryAspect)
    }

    @Test fun exactDraftAcceptsLocaleDecimalWithoutAllowingTrailingGarbage() {
        val scale = AdjustmentScale(-4f..4f, .05f, 0f)
        assertEquals(.5f, scale.parse("0,5", Locale.GERMAN)!!, 0f)
        assertEquals(-.75f, scale.parse("-0,75", Locale.FRENCH)!!, 0f)
        assertNull(scale.parse("0,5junk", Locale.GERMAN))
        assertNull(scale.parse("1,2,3", Locale.GERMAN))
    }

    @Test fun batchProgressCountsOnlyConfirmedSuccessAndReportsUnknownSeparately() {
        val source = BatchSourceSnapshot(PhotoIdentity("source"), File("source.raw"), EditSettings())
        val targets = (1..8).map { BatchTarget(PhotoIdentity("$it"), File("$it.raw"), "$it.raw") }
        val job = BatchJob(source, targets).let { initial -> initial.withRows(initial.rows.mapIndexed { index, row ->
            row.copy(status = when (index) { 0, 1 -> BatchRowStatus.SUCCESS; 2 -> BatchRowStatus.NEEDS_CONFIRMATION; else -> BatchRowStatus.PENDING })
        }) }
        val state = BatchExportState(job)
        assertEquals(2, state.successCount)
        assertEquals(1, state.confirmationCount)
        assertEquals(5, state.unfinishedCount)
        assertEquals(.25f, state.completionFraction, 0f)
    }
    @Test fun hapticBudgetIsSharedAcrossConsecutiveInputs() {
        val gate = AdjustmentHapticGate()
        assertTrue(gate.accept(1000))
        assertFalse(gate.accept(1124))
        assertTrue(gate.accept(1125))
        assertFalse(gate.accept(1200))
    }
    @Test fun exactDraftRejectsInvalidValuesAndKeepsCameraKelvinOffGrid() {
        val exposure = AdjustmentScale(-4f..4f, .05f, 0f)
        listOf("", "NaN", "Infinity", "4.1", "-4.01").forEach { assertNull(exposure.parse(it)) }
        assertNull(exposure.parse("0.36"))
        val kelvin = AdjustmentScale(2000f..50000f, 10f, 5237f, reciprocal = true)
        assertEquals(5237f, kelvin.parse("5237", current = 5237f)!!, 0f)
        assertEquals(5437f, kelvin.parse("5437", Locale.ROOT, 5437f)!!, 0f)
        assertNull(kelvin.parse("5503"))
    }

    @Test fun fixedTrackIndicatorFollowsFingerAndFineUsesQuarterSensitivity() {
        val exposure = AdjustmentScale(-4f..4f, .05f, 0f)
        assertEquals(.5f, exposure.drag(0f, 80f, false), .00001f)
        assertEquals(-.5f, exposure.drag(0f, -80f, false), .00001f)
        assertEquals(.1f, exposure.drag(0f, 64f, true), .00001f)
        assertEquals(4f, exposure.drag(0f, 10000f, false), 0f)
        assertEquals(-4f, exposure.drag(0f, -10000f, false), 0f)
        val kelvin = AdjustmentScale(2000f..50000f, 10f, 5237f, reciprocal = true)
        assertTrue(kelvin.drag(5237f, 80f, false) > 5237f)
        assertTrue(kelvin.drag(5237f, -80f, false) < 5237f)
    }

    @Test fun signedArcUsesSeparateDistanceFromCameraDefault() {
        val scale = AdjustmentScale(-150f..150f, 1f, 30f)
        assertEquals(0f, scale.sweep(30f), 0f)
        assertEquals(270f, scale.sweep(150f), 0f)
        assertEquals(-270f, scale.sweep(-150f), 0f)
        assertEquals(135f, scale.sweep(90f), 0f)
        assertEquals(-135f, scale.sweep(-60f), 0f)
    }

    @Test fun geometryDraftOnlyProjectsItsGroupAndCancelLeavesSourceUntouched() {
        val source = EditSettings(film = "velvia", exposure = .75f, lens = LensSettings(tca = true))
        val draft = AdjustmentDraft.begin(AdjustmentGroup.GEOMETRY, source)
            .update(source.copy(geometry = GeometrySettings(quarterTurns = 1), exposure = 2f))
        assertTrue(draft.changed)
        assertEquals(.75f, draft.project(source).exposure, 0f)
        assertEquals(source.lens, draft.project(source).lens)
        assertEquals(1, draft.project(source).geometry.quarterTurns)
        assertEquals(GeometrySettings(), source.geometry)
        assertFalse(draft.reset().changed)
    }

    @Test fun cropMovementAndAspectAlwaysStayInsideTransformedCanvas() {
        val crop = GeometrySettings(cropX = .2f, cropY = .1f, cropWidth = .7f, cropHeight = .8f)
        val moved = crop.moveCrop(.8f, -.8f)
        assertEquals(.3f, moved.cropX, .00001f)
        assertEquals(0f, moved.cropY, 0f)
        val square = crop.withAspect(1f, 4f / 3f)
        assertEquals(1f, square.cropWidth * (4f / 3f) / square.cropHeight, .0001f)
        assertTrue(square.cropX + square.cropWidth <= 1.000001f)
        assertTrue(square.cropY + square.cropHeight <= 1.000001f)
    }

    @Test fun sideDockFallsBackForLargeTextAndScrollsLongNavigationLabels() {
        assertFalse(editorUsesSideDock(1280f, 800f, fontScale = 1.3f))
        assertTrue(editorUsesSideDock(1280f, 800f))
    }

    @Test fun portraitTabletNeverUsesLandscapeInspector() {
        assertFalse(editorUsesSideDock(800f, 1280f))
        assertFalse(editorUsesSideDock(360f, 800f))
        assertTrue(editorUsesSideDock(1280f, 800f))
        assertTrue(editorUsesSideDock(892f, 412f))
    }
}
