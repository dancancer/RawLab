package com.rawlab.android.analytics

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import com.rawlab.android.editor.PendingPhotoImport
import com.rawlab.android.editor.ui.filmSelectionChanged
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity

class EditorUsageBoundaryTest {
    @Test
    fun missingLookKeepsImportUntilAUsablePreview() {
        val tracker = PendingPhotoImport()
        val identity = PhotoIdentity("content://photo/missing-look")

        tracker.begin(identity)
        assertTrue(tracker.complete(identity))
        assertFalse(tracker.complete(identity))
    }

    @Test
    fun newImportAndCancelReplacePendingImport() {
        val tracker = PendingPhotoImport()
        val first = PhotoIdentity("content://photo/first")
        val second = PhotoIdentity("content://photo/second")

        tracker.begin(first)
        tracker.begin(second)
        assertFalse(tracker.complete(first))
        assertTrue(tracker.complete(second))
        tracker.begin(first)
        tracker.clear()
        assertFalse(tracker.complete(first))
    }

    @Test
    fun selectingNeutralClearsARecipeAndCountsAsFilmSelection() {
        assertTrue(filmSelectionChanged(EditSettings(recipeID = "recipe"), "neutral"))
        assertFalse(filmSelectionChanged(EditSettings(), "neutral"))
        assertTrue(filmSelectionChanged(EditSettings(), "velvia"))
    }
}
