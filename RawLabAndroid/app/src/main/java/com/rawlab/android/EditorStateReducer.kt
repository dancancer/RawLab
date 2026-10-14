package com.rawlab.android

internal data class EditorMutation(val state: EditorState, val preview: EditSettings?)

internal object EditorStateReducer {
    fun geometryChanged(current: EditorState, value: GeometrySettings): EditorMutation {
        val previous = current.geometryDraft ?: return EditorMutation(current, null)
        val render = if (previous.uncropped() != value.uncropped()) current.edits.copy(geometry = value.uncropped()) else null
        return EditorMutation(current.copy(geometryDraft = value,
            geometryPreviewReady = if (render == null) current.geometryPreviewReady else false,
            rendering = current.rendering || render != null), render)
    }

    fun geometryPresetSelected(current: EditorState, physicalAspect: Float?): EditorState {
        if (!current.canApplyGeometry) return current
        return current.copy(geometryAspect = physicalAspect,
            geometryDraft = GeometryCropMath.preset(current.geometryDraft!!, physicalAspect, current.geometryCanvasAspect!!))
    }

    fun geometryPreviewAccepted(current: EditorState, canvasAspect: Float): EditorState {
        val draft = current.geometryDraft ?: return current
        val refitted = if (current.geometryCanvasAspect != canvasAspect)
            GeometryCropMath.refit(draft, current.geometryAspect, canvasAspect) else draft
        return renderFinished(current).copy(geometryDraft = refitted, geometryCanvasAspect = canvasAspect,
            geometryPreviewReady = true)
    }

    fun geometryApplied(current: EditorState): EditorMutation {
        if (!current.canApplyGeometry) return EditorMutation(current, null)
        val draft = current.geometryDraft ?: return EditorMutation(current, null)
        val edits = current.edits.copy(geometry = draft)
        return EditorMutation(current.copy(edits = edits, geometryDraft = null, geometryPreviewReady = false,
            geometryAspect = null, geometryCanvasAspect = null, rendering = true, exact = false, error = null), edits)
    }

    fun geometryCancelled(current: EditorState, baseline: EditorState): EditorState = current.copy(
        geometryDraft = null, geometryPreviewReady = false, geometryAspect = null, geometryCanvasAspect = null,
        preview = baseline.preview,
        exact = baseline.exact, rendering = false, previewResizePending = false, error = baseline.error)


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
        val edits = current.edits.selectFilm(look.id, current.preview?.tint)
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
