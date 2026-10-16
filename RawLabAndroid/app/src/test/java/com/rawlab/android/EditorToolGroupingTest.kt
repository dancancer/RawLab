package com.rawlab.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EditorToolGroupingTest {
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
}
