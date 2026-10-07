package com.rawlab.android

import android.net.TestUri
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class EditorStateReducerTest {
    @Test
    fun finishingEarlierRenderDoesNotEndLookMutation() {
        val current = EditorState(operation = Operation.IMPORT_LOOK, rendering = true)
        val finished = EditorStateReducer.renderFinished(current)
        assertEquals(Operation.IMPORT_LOOK, finished.operation)
        assertFalse(finished.rendering)
        assertEquals(Operation.NONE, EditorStateReducer.renderFinished(
            current.copy(operation = Operation.IMPORT)).operation)
    }

    private val imported = ManagedLook(
        id = "user-look",
        name = "User look",
        originalName = "user.cube",
        format = LookFormat.CUBE,
        version = 0,
        relativePath = "user-look.cube",
    )

    @Test
    fun staleStartupLoadDoesNotDropLookSelectedByAnEarlierImport() {
        val current = EditorState(
            edits = EditSettings(film = imported.id),
            looks = LookChoice.builtIns + LookChoice(imported.id, imported.name, managed = true),
        )

        val state = EditorStateReducer.looksLoaded(current, LookChoice.builtIns)

        assertTrue(state.looks.any { it.id == imported.id })
        assertEquals(imported.id, state.edits.film)
    }

    @Test
    fun importedLookDuringPhotoPreviewKeepsPhotoAndRequestsExactReplacement() {
        val photo = ImportedPhoto(TestUri.value, "photo.raw", File("photo.raw"))
        val current = EditorState(photo = photo, rendering = true, exact = false)

        val mutation = EditorStateReducer.lookImported(current, imported)

        assertEquals(photo, mutation.state.photo)
        assertEquals(imported.id, mutation.state.edits.film)
        assertTrue(mutation.state.rendering)
        assertFalse(mutation.state.exact)
        assertEquals(imported.id, mutation.preview?.film)
    }

    @Test
    fun renameDuringPreviewPreservesPendingRenderState() {
        val photo = ImportedPhoto(TestUri.value, "photo.raw", File("photo.raw"))
        val current = EditorState(
            photo = photo,
            edits = EditSettings(film = imported.id),
            looks = LookChoice.builtIns + LookChoice(imported.id, imported.name, managed = true),
            rendering = true,
            exact = false,
        )

        val mutation = EditorStateReducer.lookRenamed(current, imported.copy(name = "Renamed"))

        assertEquals("Renamed", mutation.state.looks.first { it.id == imported.id }.name)
        assertTrue(mutation.state.rendering)
        assertFalse(mutation.state.exact)
        assertEquals(null, mutation.preview)
    }

    @Test
    fun deletingSelectedLookDuringPreviewFallsBackToNeutralAndRequestsReplacement() {
        val photo = ImportedPhoto(TestUri.value, "photo.raw", File("photo.raw"))
        val current = EditorState(
            photo = photo,
            edits = EditSettings(film = imported.id),
            looks = LookChoice.builtIns + LookChoice(imported.id, imported.name, managed = true),
            rendering = true,
            exact = false,
        )

        val mutation = EditorStateReducer.lookDeleted(current, imported.id)

        assertFalse(mutation.state.looks.any { it.id == imported.id })
        assertEquals("neutral", mutation.state.edits.film)
        assertTrue(mutation.state.rendering)
        assertFalse(mutation.state.exact)
        assertNotNull(mutation.preview)
        assertEquals("neutral", mutation.preview?.film)
    }
}
