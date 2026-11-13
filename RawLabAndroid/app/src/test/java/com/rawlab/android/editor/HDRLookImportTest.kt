package com.rawlab.android.editor

import com.rawlab.android.settings.EditSettings
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class HDRLookImportTest {
    private val importing = EditorState(operation = Operation.IMPORT_LOOK, importingHDRLook = true)

    private fun settleInto(state: () -> EditorState, update: (EditorState) -> Unit): (Result<EditSettings>) -> Unit = { outcome ->
        update(EditorStateReducer.hdrLookImportFinished(state(), outcome, "cancelled", "unavailable"))
    }

    @Test fun aRevisionChangeDuringImportReturnsTheOperationAndReportsCancellation() = runBlocking {
        var state = importing
        var editRevision = 0L
        val expected = editRevision
        var settled = 0
        runHDRLookImport({ editRevision += 1; EditSettings() }, { editRevision == expected }) { outcome ->
            settled += 1
            settleInto({ state }, { state = it })(outcome)
        }
        assertEquals(1, settled)
        assertEquals(Operation.NONE, state.operation)
        assertFalse(state.importingHDRLook)
        assertEquals("cancelled", state.message)
        assertNull(state.error)
    }

    @Test fun aFailedImportReturnsTheOperationAndReportsTheLookAsUnavailable() = runBlocking {
        var state = importing
        runHDRLookImport({ throw java.io.IOException("Invalid look") }, { true }, settleInto({ state }, { state = it }))
        assertEquals(Operation.NONE, state.operation)
        assertFalse(state.importingHDRLook)
        assertEquals("unavailable", state.error)
    }

    @Test fun cancellationIsRethrownAfterReturningTheOperation() {
        var state = importing
        val cancelled = CancellationException("Editor closed")
        val failure = assertThrows(CancellationException::class.java) {
            runBlocking { runHDRLookImport({ throw cancelled }, { true }, settleInto({ state }, { state = it })) }
        }
        assertSame(cancelled, failure)
        assertEquals(Operation.NONE, state.operation)
        assertEquals("cancelled", state.message)
    }

    @Test fun aCurrentImportReturnsTheSettingsWithoutReportingFailure() = runBlocking {
        var state = importing
        var imported: EditSettings? = null
        val settings = EditSettings(film = "imported")
        runHDRLookImport({ settings }, { true }) { outcome ->
            imported = outcome.getOrNull()
            settleInto({ state }, { state = it })(outcome)
        }
        assertSame(settings, imported)
        assertEquals(Operation.NONE, state.operation)
        assertNull(state.error)
        assertNull(state.message)
    }

    @Test fun finishingLeavesAnotherOwnersOperationUntouched() {
        val exporting = importing.copy(operation = Operation.EXPORT)
        val finished = EditorStateReducer.hdrLookImportFinished(exporting,
            Result.failure<Unit>(CancellationException()), "cancelled", "unavailable")
        assertEquals(Operation.EXPORT, finished.operation)
        assertFalse(finished.importingHDRLook)
    }
}
