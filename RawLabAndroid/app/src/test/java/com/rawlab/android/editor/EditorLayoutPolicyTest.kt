package com.rawlab.android.editor

import com.rawlab.android.editor.controls.EDITOR_SIDE_DOCK_WIDTH
import com.rawlab.android.editor.controls.editorDockLayout
import com.rawlab.android.editor.controls.editorGridColumns
import com.rawlab.android.editor.controls.editorGridHeight
import com.rawlab.android.editor.controls.editorHomeDockHeight
import com.rawlab.android.editor.controls.editorUsesSideDock
import org.junit.Assert.*
import org.junit.Test

class EditorLayoutPolicyTest {
    @Test fun sideDockRequiresWideLandscapeAndNonAccessibilityFontScale() {
        assertFalse(editorUsesSideDock(320f, 720f, 1f))
        assertFalse(editorUsesSideDock(360f, 720f, 1f))
        assertFalse(editorUsesSideDock(412f, 892f, 1f))
        assertFalse(editorUsesSideDock(800f, 1280f, 1f))
        assertFalse(editorUsesSideDock(560f, 360f, 1f))
        assertTrue(editorUsesSideDock(960f, 360f, 1f))
        assertTrue(editorUsesSideDock(960f, 600f, 1f))
        assertFalse(editorUsesSideDock(960f, 600f, 1.3f))
        assertFalse(editorUsesSideDock(960f, 600f, 1.5f))
        assertEquals(336f, EDITOR_SIDE_DOCK_WIDTH, 0f)
    }

    @Test fun bottomDockReservesAtLeastMinimumCanvasHeightAndEnablesCompactNavWhenTight() {
        val portrait = editorDockLayout(availableHeight = 715f, fontScale = 1f, sideDock = false, expanded = true)
        assertEquals(332f, portrait.height, 0f)
        assertFalse(portrait.compactNavigation)

        val shortLandscape = editorDockLayout(availableHeight = 355f, fontScale = 1f, sideDock = false, expanded = true)
        assertEquals(259f, shortLandscape.height, 0f)
        assertTrue(355f - shortLandscape.height >= 96f)
        assertTrue(shortLandscape.compactNavigation)

        val collapsed = editorDockLayout(availableHeight = 715f, fontScale = 1.5f, sideDock = false, expanded = false)
        assertEquals(72f, collapsed.height, 0f)

        val side = editorDockLayout(availableHeight = 596f, fontScale = 1f, sideDock = true, expanded = true)
        assertEquals(596f, side.height, 0f)
        assertFalse(side.compactNavigation)
    }

    @Test fun gridColumnsAndHomeHeightsAdaptForAccessibilityFontScale() {
        assertEquals(4, editorGridColumns(1f))
        assertEquals(4, editorGridColumns(1.3f))
        assertEquals(3, editorGridColumns(1.35f))
        assertEquals(116f, editorGridHeight(1f), 0f)
        assertEquals(148f, editorGridHeight(1.35f), 0f)
        assertEquals(164f, editorHomeDockHeight(1f), 0f)
        assertEquals(196f, editorHomeDockHeight(1.35f), 0f)
    }
}
