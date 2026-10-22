package com.rawlab.android.ui

import androidx.compose.runtime.saveable.SaverScope
import com.rawlab.android.editor.canvas.*
import org.junit.Assert.*
import org.junit.Test

class PhotoCanvasStateSaverTest {
    @Test fun legacyUnmeasuredStateRestoresSplitAndFitWithoutIndexingPastTheList() {
        val restored = PhotoCanvasState.Saver.restore(listOf(.7f))!!
        assertEquals(.7f, restored.split, 0f)
        assertEquals(PhotoViewTransform(), restored.view)
    }

    @Test fun legacyMeasuredStateMigratesPixelZoomAndPanIntoPhotoCoordinates() {
        val restored = PhotoCanvasState.Saver.restore(listOf(.3f, 2400f, 1600f, 1200f, 800f, 1f, 300f, 200f))!!
        assertEquals(.3f, restored.split, 0f)
        assertEquals(2f, restored.view.magnification, .0001f)
        assertEquals(.375f, restored.view.focusX, .0001f)
        assertEquals(.375f, restored.view.focusY, .0001f)
        assertEquals(PhotoZoom(1f, 300f, 200f), restored.zoom)
    }

    @Test fun markedRoundTripPreservesPurePreviewReturnViewportAndSplit() {
        val state = PhotoCanvasState().apply {
            view = PhotoViewTransform(3f, .3f, .6f)
            pureOrigin = PhotoViewTransform(2f, .4f, .4f)
            split = .7f
        }
        val scope = object : SaverScope { override fun canBeSaved(value: Any) = true }
        val saved = with(PhotoCanvasState.Saver) { scope.save(state) }!!
        val restored = PhotoCanvasState.Saver.restore(saved)!!
        assertEquals(state.view, restored.view)
        assertEquals(state.pureOrigin, restored.pureOrigin)
        assertEquals(state.split, restored.split, 0f)
        restored.exitPure()
        assertEquals(PhotoViewTransform(2f, .4f, .4f), restored.view)
    }

    @Test fun unknownAndMalformedSavedStateSafelyRestoresFit() {
        for (saved in listOf(emptyList<Float>(), listOf(17f, 1f),
            listOf(.2f, Float.NaN, 2f, 3f, 4f, 5f, 6f, 7f))) {
            val restored = PhotoCanvasState.Saver.restore(saved)!!
            assertEquals(PhotoViewTransform(), restored.view)
        }
    }
}
