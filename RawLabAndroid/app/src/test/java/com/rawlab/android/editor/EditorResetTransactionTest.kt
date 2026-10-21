package com.rawlab.android.editor

import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.LensSettings
import com.rawlab.android.settings.PhotoIdentity
import org.junit.Assert.*
import org.junit.Test

class EditorResetTransactionTest {
    private val original = EditSettings(exposure = .5f, geometry = GeometrySettings(quarterTurns = 1),
        lens = LensSettings(autoCrop = false))
    private fun session(draft: AdjustmentDraft? = null) = EditorResetSession(
        PhotoIdentity("content://photo/a"), "/private/source-a.RAW", 3, 5, original, draft, 7,
        EditorResetContext(PhotoInputKind.RAW, EditSettings(), AsShotWhiteBalance(5200f, 8f), setOf("recipe")))

    @Test fun preparedResetRejectsChangedSourceRevisionEditSnapshotDraftAndContext() {
        val initial = session()
        val prepared = EditorResetTransaction.prepare(EditorResetScope.Tool(2), initial).prepared!!
        assertTrue(prepared.matches(initial))
        val newer = listOf(
            initial.copy(identity = PhotoIdentity("content://photo/b")),
            initial.copy(sourcePath = "/private/source-b.RAW"),
            initial.copy(sourceRevision = 4), initial.copy(editRevision = 6),
            initial.copy(edits = original.copy(temperature = 5300f)),
            initial.copy(draftRevision = 8),
            initial.copy(draft = AdjustmentDraft.begin(AdjustmentGroup.GEOMETRY, original)),
            initial.copy(context = initial.context.copy(asShot = AsShotWhiteBalance(5300f, 8f))),
            initial.copy(context = initial.context.copy(knownRecipeIds = setOf("other"))))
        newer.forEach { assertFalse(it.toString(), prepared.matches(it)) }
        assertEquals(0f, prepared.result.candidate.exposure, 0f)
        assertEquals(original.geometry, prepared.result.candidate.geometry)
        assertEquals(original.lens, prepared.result.candidate.lens)
    }

    @Test fun preparedContextDoesNotAliasMutableRecipeCatalog() {
        val recipes = mutableSetOf("recipe")
        val initial = session().let { it.copy(context = it.context.copy(knownRecipeIds = recipes)) }
        val prepared = EditorResetTransaction.prepare(EditorResetScope.Tool(2), initial).prepared!!
        recipes += "new-recipe"
        assertFalse(prepared.matches(initial))
        assertEquals(setOf("recipe"), prepared.session.context.knownRecipeIds)
    }

    @Test fun geometryGroupResetProjectsBothFieldsWithoutChangingCommittedAndKeepsSingleKindUpdates() {
        for (group in AdjustmentGroup.entries) {
            val draft = AdjustmentDraft.begin(group, original)
            val initial = session(draft)
            val prepared = EditorResetTransaction.prepare(EditorResetScope.Group(EditorAdjustmentGroup.GEOMETRY), initial).prepared!!
            val reset = prepared.draftCandidate!!
            assertEquals(original, initial.edits)
            assertTrue(reset.changed)
            assertEquals(GeometrySettings(), reset.project(original).geometry)
            assertEquals(LensSettings(), reset.project(original).lens)
            assertEquals(.5f, reset.project(original).exposure, 0f)
            val single = draft.update(original.copy(geometry = GeometrySettings(), lens = LensSettings()))
            if (group == AdjustmentGroup.GEOMETRY) assertEquals(original.lens, single.project(original).lens)
            else assertEquals(original.geometry, single.project(original).geometry)
            val edited = reset.update(original)
            if (group == AdjustmentGroup.GEOMETRY) assertEquals(LensSettings(), edited.project(original).lens)
            else assertEquals(GeometrySettings(), edited.project(original).geometry)
            assertEquals(original, draft.project(original))
        }
    }

    @Test fun unchangedAndBlockedResetsProduceNoCommitAndUnrelatedScopeCannotResolveDraft() {
        assertNull(EditorResetTransaction.prepare(EditorResetScope.Tool(3), session()).prepared)
        val draft = session(AdjustmentDraft.begin(AdjustmentGroup.GEOMETRY, original))
        assertTrue(EditorResetTransaction.prepare(EditorResetScope.All, draft).result is EditorResetResult.Blocked)
        assertTrue(EditorResetTransaction.prepare(EditorResetScope.Tool(2), draft).result is EditorResetResult.Blocked)
        assertTrue(EditorResetTransaction.prepare(EditorResetScope.Tool(16), draft).result is EditorResetResult.Blocked)
        assertTrue(EditorResetTransaction.prepare(EditorResetScope.Group(EditorAdjustmentGroup.GEOMETRY), session()).result is EditorResetResult.Blocked)
    }

    @Test fun durableReceiptSkipsOnlyTheExactSourceRequestAndResolvedSettings() {
        val initial = session()
        val receipt = EditorDurablePreview(initial.identity, initial.sourcePath, initial.sourceRevision, 19, original)
        assertTrue(receipt.matches(initial.identity, initial.sourcePath, 3, 19, original))
        assertFalse(receipt.matches(initial.identity, initial.sourcePath, 3, 20, original))
        assertFalse(receipt.matches(initial.identity, initial.sourcePath, 4, 19, original))
        assertFalse(receipt.matches(PhotoIdentity("content://photo/b"), initial.sourcePath, 3, 19, original))
        assertFalse(receipt.matches(initial.identity, "/other.RAW", 3, 19, original))
        assertFalse("Real WB metadata must still persist", receipt.matches(initial.identity, initial.sourcePath, 3, 19,
            original.copy(temperature = 5200f, tint = 8f)))
    }
}
