package com.rawlab.android

import org.junit.Assert.*
import org.junit.Test

class GeometryCropMathTest {
    private val tolerance = .000001f

    @Test fun ratioChoicesUsePhysicalLandscapeAndPortraitAspects() {
        assertNull(GeometryRatio.FREE.ratio(1.5f, false))
        assertNull(GeometryRatio.FREE.ratio(1.5f, true))
        assertEquals(1.5f, GeometryRatio.ORIGINAL.ratio(2f / 3f, false)!!, tolerance)
        assertEquals(2f / 3f, GeometryRatio.ORIGINAL.ratio(1.5f, true)!!, tolerance)
        assertEquals(1f, GeometryRatio.SQUARE.ratio(1.5f, true)!!, tolerance)
        assertEquals(1.5f, GeometryRatio.THREE_TWO.ratio(1f, false)!!, tolerance)
        assertEquals(3f / 4f, GeometryRatio.FOUR_THREE.ratio(1f, true)!!, tolerance)
        assertEquals(16f / 9f, GeometryRatio.SIXTEEN_NINE.ratio(1f, false)!!, tolerance)
    }

    @Test fun presetConvertsPhysicalRatioToNormalizedCanvasDimensions() {
        val square = GeometryCropMath.preset(GeometrySettings(), 1f, 1.5f)
        assertCrop(square, 1f / 6f, 0f, 2f / 3f, 1f)
        assertPhysicalRatio(square, 1.5f, 1f)
        val landscape = GeometryCropMath.preset(GeometrySettings(), 1.5f, 2f / 3f)
        assertCrop(landscape, 0f, 5f / 18f, 1f, 4f / 9f)
        assertPhysicalRatio(landscape, 2f / 3f, 1.5f)
    }

    @Test fun changingPresetsUsesFullCanvasWithoutCumulativeShrink() {
        val start = GeometrySettings(.35f, .35f, .3f, .3f)
        val wide = GeometryCropMath.preset(start, 16f / 9f, 1.5f)
        val square = GeometryCropMath.preset(wide, 1f, 1.5f)
        val wideAgain = GeometryCropMath.preset(square, 16f / 9f, 1.5f)
        assertCrop(square, 1f / 6f, 0f, 2f / 3f, 1f)
        assertCrop(wideAgain, wide.cropX, wide.cropY, wide.cropWidth, wide.cropHeight)
        assertEquals(GeometryCropMath.preset(GeometrySettings(), 1f, 1.5f), square)
    }

    @Test fun presetsKeepMovedCenterAndExpandToCanvasBounds() {
        val start = GeometrySettings(.1f, .2f, .4f, .4f)
        val square = GeometryCropMath.preset(start, 1f, 1f)
        assertCrop(square, 0f, .1f, .6f, .6f)
        val landscape = GeometryCropMath.preset(square, 2f, 1f)
        assertCrop(landscape, 0f, .25f, .6f, .3f)
        val squareAgain = GeometryCropMath.preset(landscape, 1f, 1f)
        assertCrop(squareAgain, square.cropX, square.cropY, square.cropWidth, square.cropHeight)
    }

    @Test fun freeSelectionKeepsCropAndUncroppedKeepsOtherTransforms() {
        val start = GeometrySettings(.1f, .2f, .6f, .5f, 3, true, true, 7f, .3f, -.4f)
        assertEquals(start, GeometryCropMath.preset(start, null, 1.5f))
        assertEquals(start.copy(cropX = 0f, cropY = 0f, cropWidth = 1f, cropHeight = 1f), start.uncropped())
        assertEquals("2", start.uncropped().encode().substringBefore(','))
    }

    @Test fun movementPreservesDimensionsAndClampsEachCanvasEdge() {
        val start = GeometrySettings(.2f, .3f, .4f, .5f)
        assertCrop(GeometryCropMath.move(start, .1f, -.1f), .3f, .2f, .4f, .5f)
        assertCrop(GeometryCropMath.move(start, -2f, -2f), 0f, 0f, .4f, .5f)
        assertCrop(GeometryCropMath.move(start, 2f, 2f), .6f, .5f, .4f, .5f)
    }

    @Test fun movementUsesGestureBaselineInsteadOfAccumulatingDeltas() {
        val start = GeometrySettings(.2f, .3f, .4f, .5f)
        GeometryCropMath.move(start, .1f, -.1f)
        assertCrop(GeometryCropMath.move(start, .2f, -.2f), .4f, .1f, .4f, .5f)
    }

    @Test fun everyFreeCornerKeepsItsOppositeAnchor() {
        val start = GeometrySettings(.2f, .3f, .4f, .5f)
        for (corner in GeometryCropCorner.values()) {
            val resized = GeometryCropMath.resize(start, corner, .05f, .03f, null, 1.5f)
            assertAnchor(start, resized, corner)
            assertEquals(if (isLeft(corner)) .35f else .45f, resized.cropWidth, tolerance)
            assertEquals(if (isTop(corner)) .47f else .53f, resized.cropHeight, tolerance)
        }
    }

    @Test fun freeResizeClampsToBoundsAndMinimumWithoutCrossingAnchor() {
        val start = GeometrySettings(.2f, .3f, .4f, .5f)
        val largest = GeometryCropMath.resize(start, GeometryCropCorner.TOP_LEFT, -2f, -2f, null, 1f)
        assertCrop(largest, 0f, 0f, .6f, .8f)
        val smallest = GeometryCropMath.resize(start, GeometryCropCorner.TOP_LEFT, 2f, 2f, null, 1f)
        assertCrop(smallest, .56f, .76f, .04f, .04f)
        assertAnchor(start, smallest, GeometryCropCorner.TOP_LEFT)
        val bottomRight = GeometryCropMath.resize(start, GeometryCropCorner.BOTTOM_RIGHT, 2f, 2f, null, 1f)
        assertCrop(bottomRight, .2f, .3f, .8f, .7f)
    }

    @Test fun ratioResizeUsesPhysicalCanvasCoordinates() {
        val start = GeometrySettings(.2f, .3f, .4f, .4f)
        val resized = GeometryCropMath.resize(start, GeometryCropCorner.BOTTOM_RIGHT, .2f, .1f, 1.5f, 1.5f)
        val expectedHeight = (1.5f * .6f * 1.5f + .5f) / (1.5f * 1.5f + 1f)
        assertCrop(resized, .2f, .3f, expectedHeight, expectedHeight)
        assertPhysicalRatio(resized, 1.5f, 1.5f)
    }

    @Test fun everyRatioCornerKeepsAnchorAndRatioWhenClamped() {
        val start = GeometrySettings(.2f, .3f, .4f, .4f)
        for (corner in GeometryCropCorner.values()) {
            val resized = GeometryCropMath.resize(start, corner,
                if (isLeft(corner)) -2f else 2f,
                if (isTop(corner)) -2f else 2f,
                1f, 1.5f)
            assertAnchor(start, resized, corner)
            assertPhysicalRatio(resized, 1.5f, 1f)
            assertInBounds(resized)
        }
    }

    @Test fun ratioMinimumKeepsBothEdgesAboveMinimumAndPhysicalRatio() {
        val start = GeometrySettings(.2f, .3f, .4f, .4f)
        val portrait = GeometryCropMath.resize(start, GeometryCropCorner.BOTTOM_RIGHT, -2f, -2f, .5f, 2f)
        assertCrop(portrait, .2f, .3f, .04f, .16f)
        assertPhysicalRatio(portrait, 2f, .5f)
        val landscape = GeometryCropMath.resize(start, GeometryCropCorner.BOTTOM_RIGHT, -2f, -2f, 2f, .5f)
        assertCrop(landscape, .2f, .3f, .16f, .04f)
        assertPhysicalRatio(landscape, .5f, 2f)
    }

    @Test fun resizingFromBaselinePreservesTransformsAndDoesNotAccumulate() {
        val start = GeometrySettings(.2f, .3f, .4f, .4f, 2, true, false, -5f, .2f, -.1f)
        GeometryCropMath.resize(start, GeometryCropCorner.BOTTOM_RIGHT, .05f, .05f, null, 1f)
        val resized = GeometryCropMath.resize(start, GeometryCropCorner.BOTTOM_RIGHT, .1f, .1f, null, 1f)
        assertEquals(start.copy(cropWidth = .5f, cropHeight = .5f), resized)
    }

    @Test fun invalidGestureAndAspectInputsAreRejected() {
        val start = GeometrySettings()
        assertThrows(IllegalArgumentException::class.java) { GeometryCropMath.move(start, Float.NaN, 0f) }
        assertThrows(IllegalArgumentException::class.java) {
            GeometryCropMath.resize(start, GeometryCropCorner.TOP_LEFT, 0f, Float.POSITIVE_INFINITY, null, 1f)
        }
        for (aspect in listOf(0f, -1f, Float.NaN, Float.POSITIVE_INFINITY)) {
            assertThrows(IllegalArgumentException::class.java) { GeometryCropMath.preset(start, 1f, aspect) }
            assertThrows(IllegalArgumentException::class.java) { GeometryCropMath.preset(start, aspect, 1f) }
        }
    }

    private fun assertCrop(actual: GeometrySettings, x: Float, y: Float, width: Float, height: Float) {
        assertEquals(x, actual.cropX, tolerance)
        assertEquals(y, actual.cropY, tolerance)
        assertEquals(width, actual.cropWidth, tolerance)
        assertEquals(height, actual.cropHeight, tolerance)
        assertInBounds(actual)
    }

    private fun assertInBounds(value: GeometrySettings) {
        assertTrue(value.cropX >= 0f && value.cropY >= 0f)
        assertTrue(value.cropWidth > 0f && value.cropHeight > 0f)
        assertTrue(value.cropX + value.cropWidth <= 1f + tolerance)
        assertTrue(value.cropY + value.cropHeight <= 1f + tolerance)
    }

    private fun assertPhysicalRatio(value: GeometrySettings, canvasAspect: Float, physicalAspect: Float) {
        assertEquals(physicalAspect, value.cropWidth * canvasAspect / value.cropHeight, tolerance)
    }

    private fun assertAnchor(before: GeometrySettings, after: GeometrySettings, corner: GeometryCropCorner) {
        assertEquals(before.cropX + if (isLeft(corner)) before.cropWidth else 0f,
            after.cropX + if (isLeft(corner)) after.cropWidth else 0f, tolerance)
        assertEquals(before.cropY + if (isTop(corner)) before.cropHeight else 0f,
            after.cropY + if (isTop(corner)) after.cropHeight else 0f, tolerance)
    }

    private fun isLeft(corner: GeometryCropCorner) =
        corner == GeometryCropCorner.TOP_LEFT || corner == GeometryCropCorner.BOTTOM_LEFT

    private fun isTop(corner: GeometryCropCorner) =
        corner == GeometryCropCorner.TOP_LEFT || corner == GeometryCropCorner.TOP_RIGHT
    @Test fun refitRetainsResizedSquareAreaAndCenterAcrossQuarterRotation() {
        val crop = GeometrySettings(cropX = .3f, cropY = .2f, cropWidth = .4f, cropHeight = .6f)
        val refitted = GeometryCropMath.refit(crop.rotated(true), 1f, 2f / 3f)
        assertEquals(.6f, refitted.cropWidth, .000001f)
        assertEquals(.4f, refitted.cropHeight, .000001f)
        assertEquals(.24f, refitted.cropWidth * refitted.cropHeight, .000001f)
        assertEquals(.5f, refitted.cropX + refitted.cropWidth / 2f, .000001f)
        assertEquals(.5f, refitted.cropY + refitted.cropHeight / 2f, .000001f)
        assertEquals(1, refitted.quarterTurns)
    }

    @Test fun repeatedCanvasRefitsDoNotMaximizeOrAccumulateSizeChanges() {
        val crop = GeometrySettings(cropX = .3f, cropY = .2f, cropWidth = .4f, cropHeight = .6f)
        val corrected = GeometryCropMath.refit(crop.copy(straightenDegrees = 3f), 1f, 1.35f)
        assertEquals(.24f, corrected.cropWidth * corrected.cropHeight, .000001f)
        assertEquals(1f, corrected.cropWidth / corrected.cropHeight * 1.35f, .000001f)
        val restored = GeometryCropMath.refit(corrected, 1f, 1.5f)
        assertEquals(crop.cropWidth, restored.cropWidth, .000001f)
        assertEquals(crop.cropHeight, restored.cropHeight, .000001f)
        assertEquals(crop.cropX, restored.cropX, .000001f)
        assertEquals(crop.cropY, restored.cropY, .000001f)
        assertEquals(3f, restored.straightenDegrees)
        assertTrue(GeometryCropMath.preset(crop, 1f, 1.5f).cropWidth > restored.cropWidth)
    }

    @Test fun refitScalesDownOnlyWhenStableCenterCannotFitTheNewShape() {
        val crop = GeometrySettings(cropX = .05f, cropY = 0f, cropWidth = .2f, cropHeight = .3f)
        val refitted = GeometryCropMath.refit(crop, 1f, .5f)
        assertEquals(.3f, refitted.cropWidth, .000001f)
        assertEquals(.15f, refitted.cropHeight, .000001f)
        assertTrue(refitted.cropWidth * refitted.cropHeight <= crop.cropWidth * crop.cropHeight)
        assertEquals(.15f, refitted.cropX + refitted.cropWidth / 2f, .000001f)
        assertEquals(.15f, refitted.cropY + refitted.cropHeight / 2f, .000001f)
    }

    @Test fun refittingFreeCropKeepsExactBoundsAndTransforms() {
        val crop = GeometrySettings(cropX = .2f, cropY = .1f, cropWidth = .4f, cropHeight = .6f,
            quarterTurns = 2, flipHorizontal = true, straightenDegrees = 4f)
        assertSame(crop, GeometryCropMath.refit(crop, null, 2f / 3f))
    }

}
