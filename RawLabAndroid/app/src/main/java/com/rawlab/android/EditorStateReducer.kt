package com.rawlab.android

internal data class EditorMutation(val state: EditorState, val preview: EditSettings?)

internal object EditorStateReducer {
    fun renderFinished(current: EditorState): EditorState = current.copy(
        operation = if (current.operation == Operation.IMPORT_LOOK) Operation.IMPORT_LOOK else Operation.NONE,
        rendering = false,
    )

    fun looksLoaded(current: EditorState, loaded: List<LookChoice>): EditorState {
        val loadedIds = loaded.mapTo(mutableSetOf()) { it.id }
        val pending = current.looks.filter { it.managed && it.id !in loadedIds }
        return current.copy(looks = loaded + pending)
    }

    fun lookImported(current: EditorState, look: ManagedLook): EditorMutation {
        val edits = current.edits.copy(film = look.id)
        val hasPhoto = current.photo != null
        val state = current.copy(
            looks = current.looks.filterNot { it.id == look.id } + LookChoice(look.id, look.name, managed = true),
            edits = edits,
            operation = Operation.NONE,
            rendering = if (hasPhoto) true else current.rendering,
            exact = if (hasPhoto) false else current.exact,
            error = null,
        )
        return EditorMutation(state, edits.takeIf { hasPhoto })
    }

    fun lookRenamed(current: EditorState, look: ManagedLook): EditorMutation {
        val state = current.copy(
            looks = current.looks.map { if (it.id == look.id) LookChoice(look.id, look.name, managed = true) else it },
            operation = Operation.NONE,
            error = null,
        )
        return EditorMutation(state, null)
    }

    fun lookDeleted(current: EditorState, id: String): EditorMutation {
        val selected = current.edits.film == id
        val rerender = selected && current.photo != null
        val edits = if (selected) current.edits.copy(film = "neutral") else current.edits
        val state = current.copy(
            looks = current.looks.filterNot { it.id == id },
            edits = edits,
            operation = Operation.NONE,
            rendering = if (rerender) true else current.rendering,
            exact = if (rerender) false else current.exact,
            error = null,
        )
        return EditorMutation(state, edits.takeIf { rerender })
    }
}
