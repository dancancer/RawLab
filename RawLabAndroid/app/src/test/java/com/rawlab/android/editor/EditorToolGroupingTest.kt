package com.rawlab.android.editor

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import com.rawlab.android.R
import com.rawlab.android.editor.ui.editorToolOrder
import com.rawlab.android.editor.ui.editorToolTitles
import com.rawlab.android.editor.ui.whiteBalanceChanged
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.editor.ui.editorToolIcons

class EditorToolGroupingTest {
    @Test fun everyGroupStartsAtItsDesignatedTool() {
        assertEquals(listOf(0, 2, 8, 12, 11, 17), EditorAdjustmentGroup.entries.map(EditorAdjustmentRules::defaultTool))
    }

    @Test fun busyDoesNotHideStoredLegacyAuxiliaryObjectMarkers() {
        val state = EditorState(edits = EditSettings(displayChromaDenoise = 2), rendering = true)
        assertTrue(EditorAdjustmentRules.isModified(EditorResetScope.Tool(11), state.visibleEdits, state.resetContext()))
        assertTrue(EditorAdjustmentRules.isModified(EditorResetScope.Group(EditorAdjustmentGroup.DETAIL), state.visibleEdits, state.resetContext()))
    }

    @Test fun toolsFollowTheSixWorkspaceGroupsWithStableIds() {
        assertEquals(listOf(0, 15, 1, 2, 3, 4, 18, 19, 5, 6, 8, 7, 20, 14, 21, 12, 13, 11, 10, 17, 16), editorToolOrder)
    }

    @Test fun whiteBalanceUsesOneToolEntryWithTheCombinedTitle() {
        assertEquals(1, editorToolOrder.count { it == 8 || it == 9 })
        assertTrue(editorToolOrder.contains(8))
        assertFalse(editorToolOrder.contains(9))
        assertEquals(R.string.white_balance, editorToolTitles[8])
    }

    @Test fun whiteBalanceChangedIndicatorCoversTemperatureAndTint() {
        assertFalse(whiteBalanceChanged(EditSettings(), 6500f, 0f))
        assertTrue(whiteBalanceChanged(EditSettings(customWb = true, temperature = 7000f), 6500f, 0f))
        assertTrue(whiteBalanceChanged(EditSettings(customWb = true, tint = 12f), 6500f, 0f))
    }

    @Test fun whiteBalanceGroupResetRestoresBothAxesWithoutChangingRecipeFormat() {
        val edited = EditSettings(film = "velvia", customWb = true, temperature = 8000f, tint = 22f)
        val reset = edited.resetWhiteBalance(5200f, -3f)
        assertFalse(reset.customWb)
        assertEquals(5200f, reset.temperature)
        assertEquals(-3f, reset.tint)
        assertEquals("velvia", reset.film)

        val recipeReset = edited.copy(recipeID = "recipe").resetWhiteBalance(5200f, -3f)
        assertEquals("recipe", recipeReset.recipeID)
        assertEquals(0f, recipeReset.tint)
    }

    // 工具条上每个可见工具都有自己的图标（“强度”和“HSL”曾共用同一个滑杆图标）
    @Test fun everyVisibleToolHasItsOwnIcon() {
        val icons = editorToolOrder.map { editorToolIcons[it] }
        assertEquals(editorToolOrder.filterIndexed { i, _ -> icons.indexOf(icons[i]) != i }.toString(), icons.size, icons.toSet().size)
    }
}
