package com.rawlab.android.editor

import android.net.TestUri
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import java.io.File
import org.junit.Assert.*
import org.junit.Test

class DraftReadinessTest {
    private val settings = EditSettings()
    private val ready = EditorState(photo = ImportedPhoto(TestUri.value, "a.RAW", File("a.RAW")),
        edits = settings, exact = true, draft = AdjustmentDraft.begin(AdjustmentGroup.GEOMETRY, settings))

    @Test fun unchangedDraftCannotApplyAndChangedDraftKeepsExactRenderResizeAndErrorGuards() {
        assertTrue("First crop and ratio input remains enabled", ready.draftReady)
        assertFalse("Unchanged draft cannot create a save", ready.canApplyDraft)
        val changed = ready.copy(draft = ready.draft!!.update(settings.copy(geometry = settings.geometry.copy(cropWidth = .75f))))
        assertTrue(changed.canApplyDraft)
        assertFalse(changed.copy(exact = false).canApplyDraft)
        assertFalse(changed.copy(rendering = true).canApplyDraft)
        assertFalse(changed.copy(previewResizePending = true).canApplyDraft)
        assertFalse(changed.copy(error = "render failed").canApplyDraft)
        assertTrue("Save failure remains retryable", changed.copy(saveState = EditSaveState.FAILED).canApplyDraft)
    }
}
