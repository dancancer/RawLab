package com.rawlab.android.camera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraUiPolicyTest {
    @Test
    fun gridColumnsAdaptsToViewportWidth() {
        assertEquals(3, cameraGridColumns(390f))
        assertEquals(3, cameraGridColumns(599f))
        assertEquals(4, cameraGridColumns(600f))
        assertEquals(4, cameraGridColumns(899f))
        assertEquals(5, cameraGridColumns(900f))
    }

    @Test
    fun toggleVisibleSelectionSelectsThenDeselectsOnlyVisibleKeys() {
        val visible = listOf("vis-1", "vis-2")
        val initial = setOf("hidden-a", "vis-1")

        assertFalse(allVisibleSelected(initial, visible))

        val selectedAll = toggleVisibleSelection(initial, visible)
        assertEquals(setOf("hidden-a", "vis-1", "vis-2"), selectedAll)
        assertTrue(allVisibleSelected(selectedAll, visible))

        val deselectedVisible = toggleVisibleSelection(selectedAll, visible)
        assertEquals(setOf("hidden-a"), deselectedVisible)
        assertFalse(allVisibleSelected(deselectedVisible, visible))
    }

    @Test
    fun toggleVisibleSelectionLeavesEmptyVisibleScopeUnchanged() {
        val initial = setOf("hidden-a")
        assertFalse(allVisibleSelected(initial, emptyList()))
        assertEquals(initial, toggleVisibleSelection(initial, emptyList()))
    }

    @Test
    fun previewLoadStateUsesUnavailableOnlyAfterNullResultNotInitialLoading() {
        val resolvedNull = previewLoadState(null)
        assertEquals(CameraPreviewLoadState.Unavailable, resolvedNull)
        assertNotEquals(CameraPreviewLoadState.Loading, resolvedNull)
    }
}
