package com.rawlab.android.editor

import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.LookChoice
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.looks.ManagedLook
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.looks.LUTCompatibility
import android.net.Uri

data class PendingLookCompatibility(val uri: Uri, val name: String, val draft: LUTCompatibility)

// ============================================================================
//  编辑器的界面状态：当前照片、参数、预览与进行中的操作
// ============================================================================

enum class Operation { NONE, IMPORT, IMPORT_LOOK, PICK_EXPORT, EXPORT }
enum class EditSaveState { NONE, RESTORED, SAVED, FAILED }

internal class PendingPhotoImport {
    private var identity: PhotoIdentity? = null

    fun begin(identity: PhotoIdentity) { this.identity = identity }
    fun clear() { identity = null }
    fun complete(identity: PhotoIdentity): Boolean {
        if (this.identity != identity) return false
        this.identity = null
        return true
    }
}


data class EditorState(
    val photo: ImportedPhoto? = null,
    val edits: EditSettings = EditSettings(),
    val looks: List<LookChoice> = LookChoice.builtIns,
    val preview: PreviewPair? = null,
    val operation: Operation = Operation.NONE,
    val rendering: Boolean = false,
    val previewResizePending: Boolean = false,
    val exact: Boolean = false,
    val error: String? = null,
    val saveState: EditSaveState = EditSaveState.NONE,
    val saveError: String? = null,
    val message: String? = null,
    val lookImportReport: String? = null,
    val pendingLookCompatibility: List<PendingLookCompatibility> = emptyList(),
    val lookCompatibilityPreparing: Boolean = false,
    val gpuEnabled: Boolean = true,
    val draft: AdjustmentDraft? = null,
    val adjustmentRevision: Long = 0,
    val committingAdjustments: Boolean = false,
) {
    val canExport get() = photo != null && preview != null && exact && !rendering && !previewResizePending &&
        operation == Operation.NONE && !committingAdjustments && draft == null && saveState != EditSaveState.FAILED
    val controlsEnabled get() = photo != null && operation == Operation.NONE && !committingAdjustments
    val visibleEdits get() = draft?.project(edits) ?: edits
    val draftReady get() = draft != null && controlsEnabled && exact && !rendering && !previewResizePending && error == null
    val canApplyDraft get() = draftReady && draft?.changed == true
}

// 纯状态转换：渲染结束、外观加载/导入/改名/删除后的界面状态
internal data class EditorMutation(val state: EditorState, val preview: EditSettings?, val blockedRecipeSelection: Boolean = false)

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
        val selected = try { current.edits.selectFilm(look.id, current.preview?.tint,
            current.preview?.temperature, current.photo?.inputKind ?: PhotoInputKind.RAW) }
            catch (_: IllegalArgumentException) { null }
        val edits = selected ?: current.edits
        val hasPhoto = current.photo != null
        val state = current.copy(
            looks = current.looks.filterNot { it.id == look.id } + LookChoice(look.id, look.name, managed = true, appearanceUnverified = look.appearanceUnverified, compatibilityMode = look.compatibilityMode),
            edits = edits,
            operation = Operation.NONE,
            rendering = if (selected != null && hasPhoto) true else current.rendering,
            exact = if (selected != null && hasPhoto) false else current.exact,
            error = if (selected == null) current.error else null,
        )
        return EditorMutation(state, selected?.takeIf { hasPhoto }, blockedRecipeSelection = selected == null)
    }

    fun lookRenamed(current: EditorState, look: ManagedLook): EditorMutation {
        val state = current.copy(
            looks = current.looks.map { if (it.id == look.id) LookChoice(look.id, look.name, managed = true, appearanceUnverified = look.appearanceUnverified, compatibilityMode = look.compatibilityMode) else it },
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

/** 界面查询不触发保存或渲染；忙状态只影响动作可用性。 */
internal fun EditorState.resetContext(): EditorResetContext = EditorResetContext(
    photo?.inputKind ?: com.rawlab.android.format.PhotoInputKind.RAW,
    EditSettings(),
    preview?.takeIf { it.temperature.isFinite() && it.tint.isFinite() }
        ?.let { AsShotWhiteBalance(it.temperature, it.tint) },
    edits.recipeID?.let(::setOf) ?: emptySet(),
)
