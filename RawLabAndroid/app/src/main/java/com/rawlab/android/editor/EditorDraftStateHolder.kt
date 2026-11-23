package com.rawlab.android.editor

import android.util.Log
import com.rawlab.android.editor.render.InteractivePreviewSize
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.storage.EditSaveResult
import com.rawlab.android.geometry.GeometryRatio
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.looks.MasterRecipe
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.synchronizeHDR
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

private const val DRAFT_TAG = "com.rawlab.EditorViewModel"

internal class EditorDraftStateHolder(
    private val mutable: MutableStateFlow<EditorState>,
    private val draftStore: EditorDraftStore,
    private val scope: CoroutineScope,
    private val strings: EditorStrings,
    private val uptimeMillis: () -> Long,
    private val previewResizeDelayMs: Long,
    private val loadMasterRecipes: () -> List<MasterRecipe>,
    private val uncroppedGeometrySize: (PreviewPair, GeometrySettings) -> Pair<Int, Int>,
    private val isDisposed: () -> Boolean,
    private val currentSourceRevision: () -> Long,
    private val currentEditRevision: () -> Long,
    private val currentRenderRevision: () -> Long,
    private val getPreviewLongEdge: () -> Int,
    private val setPreviewLongEdge: (Int) -> Unit,
    private val gpuMode: () -> Int,
    private val isCameraHDRPreflightPending: () -> Boolean,
    private val isQuickPresetPreparing: () -> Boolean,
    private val onCancelQuickPreset: () -> Unit,
    private val onCancelHslTarget: () -> Unit,
    private val onClearHslTarget: (Boolean) -> Unit,
    private val onClearPendingResetMigration: () -> Unit,
    private val onClearDeferredMigrationPreview: () -> Unit,
    private val onIncrementEditRevision: () -> Unit,
    private val onSubmitPreview: (Work.Preview) -> Long,
    private val onPersist: (ImportedPhoto, EditSettings, (EditSaveResult) -> Unit) -> Unit,
    private val onEdit: (EditSettings, Boolean, Boolean) -> Unit,
    private val onCancelWbProbe: () -> Unit = {},
    private val onClearWbProbe: (Boolean) -> Unit = {},
) {
    var draftRevision: Long = 0L
        private set
    var failedDraftSave: Boolean = false
        private set
    private var draftSaveBaseline: Pair<EditSaveState, String?>? = null
    private var durablePreview: EditorDurablePreview? = null
    private var navigationPreview: EditorDurablePreview? = null
    var requestedPreviewLongEdge: Int = 1600
        private set
    private var previewResizeJob: Job? = null
    private val interactivePreviewSize = InteractivePreviewSize()
    private val resetRecipeIds by lazy { loadMasterRecipes().map { it.id }.toSet() }

    fun interactiveEdge(maxEdge: Int, interactive: Boolean): Int =
        interactivePreviewSize.edge(maxEdge, interactive, uptimeMillis())

    fun cancelResize() {
        previewResizeJob?.cancel()
        previewResizeJob = null
    }

    fun hasResizePending(): Boolean = previewResizeJob != null

    fun clearDurableAndNavigationPreview() {
        durablePreview = null
        navigationPreview = null
    }

    fun clearDurablePreview() {
        durablePreview = null
    }

    fun resetForImport() {
        durablePreview = null
        cancelResize()
        setPreviewLongEdge(1600)
        requestedPreviewLongEdge = 1600
    }

    fun consumeDurableMatch(photo: ImportedPhoto, sourceRev: Long, renderRev: Long, settings: EditSettings): Boolean {
        val matched = durablePreview?.matches(photo.identity, photo.file.absolutePath, sourceRev, renderRev, settings) == true
        durablePreview = null
        return matched
    }

    fun consumeNavigationMatch(photo: ImportedPhoto, sourceRev: Long, renderRev: Long, settings: EditSettings): Boolean {
        val matched = navigationPreview?.matches(photo.identity, photo.file.absolutePath, sourceRev, renderRev, settings) == true
        navigationPreview = null
        return matched
    }

    fun updatePreviewSize(edge: Int) {
        var current = mutable.value
        if (isDisposed() || current.photo == null || edge !in 1..1600) return
        if (current.draft != null) {
            if (edge == requestedPreviewLongEdge) return
            requestedPreviewLongEdge = edge
            if (current.draft?.group == AdjustmentGroup.HSL || current.draft?.group == AdjustmentGroup.CURVE) onCancelHslTarget()
            return
        }
        if (edge == requestedPreviewLongEdge && (edge == getPreviewLongEdge() || previewResizeJob != null)) return
        if (isCameraHDRPreflightPending()) {
            requestedPreviewLongEdge = edge
            return
        }
        onCancelHslTarget()
        current = mutable.value
        requestedPreviewLongEdge = edge
        if (!current.controlsEnabled) return
        cancelResize()
        mutable.value = current.copy(previewResizePending = false)
        if (edge == getPreviewLongEdge()) return
        if (!current.edits.denoise.enabled) {
            setPreviewLongEdge(edge)
            renderCommittedForNavigation()
            return
        }
        mutable.value = mutable.value.copy(previewResizePending = true)
        previewResizeJob = scope.launch {
            delay(previewResizeDelayMs)
            previewResizeJob = null
            mutable.value = mutable.value.copy(previewResizePending = false)
            if (!mutable.value.controlsEnabled) return@launch
            setPreviewLongEdge(requestedPreviewLongEdge)
            renderCommittedForNavigation()
        }
    }

    fun beginDraft(group: AdjustmentGroup) {
        if (isQuickPresetPreparing()) onCancelQuickPreset()
        val current = mutable.value
        if (!current.canExport) return
        cancelResize()
        val pair = current.preview ?: return
        draftRevision += 1
        failedDraftSave = false
        draftSaveBaseline = current.saveState to current.saveError
        mutable.value = current.copy(
            draft = AdjustmentDraft.begin(group, current.edits, pair.originalAspect, pair.comparisonWidth / pair.comparisonHeight),
            previewResizePending = false,
            error = null,
        )
        if (group == AdjustmentGroup.GEOMETRY && !current.edits.geometry.isIdentity) renderDraft(false)
    }

    fun changeDraft(edits: EditSettings, interactive: Boolean = false) {
        val current = mutable.value
        val previous = current.draft ?: return
        if (!current.controlsEnabled) {
            Log.w(DRAFT_TAG, "edit-dropped method=changeDraft reason=controlsDisabled op=${current.operation}")
            return
        }
        val next = previous.update(edits, interactive)
        if (next == previous && (interactive || current.exact)) return
        updateDraft(current, next, interactive)
    }

    fun updateDraft(current: EditorState, draft: AdjustmentDraft, interactive: Boolean = false) {
        val next = current.copy(draft = if (interactive) draft else fitGeometryDraft(draft, current.preview))
        draftRevision += 1
        mutable.value = next
        if (draft.group != AdjustmentGroup.GEOMETRY || current.draftRenderEdits() != next.draftRenderEdits()) {
            renderDraft(interactive)
        }
    }

    fun fitGeometryDraft(draft: AdjustmentDraft, pair: PreviewPair?): AdjustmentDraft {
        if (draft.group != AdjustmentGroup.GEOMETRY || pair == null || !pair.renderedGeometry.isIdentity) return draft
        val (width, height) = uncroppedGeometrySize(pair, draft.value.geometry)
        return draft.acceptGeometryCanvas(width.toFloat() / height)
    }

    private fun EditorState.draftRenderEdits(): EditSettings =
        if (draft?.group == AdjustmentGroup.GEOMETRY) visibleEdits.copy(geometry = GeometrySettings()).synchronizeHDR() else visibleEdits

    fun renderDraft(interactive: Boolean) {
        val current = mutable.value
        val photo = current.photo ?: return
        if (current.draft == null) return
        val edits = current.draftRenderEdits()
        mutable.value = current.copy(rendering = true, exact = false, error = null)
        onSubmitPreview(
            Work.Preview(photo, edits, interactive, gpuMode(), edge = interactiveEdge(1600, interactive), draft = true),
        )
    }

    fun undoDraft() = changeDraftHistory { it.undo() }
    fun redoDraft() = changeDraftHistory { it.redo() }

    private fun changeDraftHistory(change: (AdjustmentDraft) -> AdjustmentDraft) {
        val current = mutable.value
        val draft = current.draft ?: return
        if (!current.controlsEnabled) return
        val next = change(draft)
        if (next != draft) updateDraft(current, next)
    }

    fun chooseGeometryRatio(ratio: GeometryRatio, portrait: Boolean) {
        val current = mutable.value
        val draft = current.draft ?: return
        if (!current.controlsEnabled || (ratio != GeometryRatio.FREE && !current.draftReady)) return
        val next = draft.selectGeometryRatio(ratio, portrait)
        if (next == draft) return
        draftRevision += 1
        mutable.value = current.copy(draft = next)
    }

    fun toggleGeometryLock() = updateGeometrySelection { it.toggleGeometryLock() }
    fun swapGeometryRatio() = updateGeometrySelection { it.swapGeometryRatio() }
    fun toggleGeometryGrid() = updateGeometrySelection { it.copy(geometryGrid = !it.geometryGrid) }

    private fun updateGeometrySelection(edit: (AdjustmentDraft) -> AdjustmentDraft) {
        val current = mutable.value
        val draft = current.draft ?: return
        if (!current.controlsEnabled || !current.draftReady || draft.group != AdjustmentGroup.GEOMETRY) return
        val next = edit(draft)
        if (next == draft) return
        draftRevision += 1
        mutable.value = current.copy(draft = next)
    }

    fun applyDraft(completed: (Boolean) -> Unit = {}) {
        val current = mutable.value
        if (isDisposed() || !current.draftReady) return completed(false)
        if (current.draft?.changed != true) {
            discardDraft()
            completed(true)
            return
        }
        val photo = current.photo ?: return completed(false)
        val edits = current.draft!!.project(current.edits)
        cancelResize()
        onClearPendingResetMigration()
        onPersist(photo, edits) { saved ->
            if (saved.state == EditSaveState.FAILED) {
                failedDraftSave = true
                mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.formatMessage(strings))
                completed(false)
            } else {
                failedDraftSave = false
                draftSaveBaseline = null
                if (current.draft.group == AdjustmentGroup.HSL || current.draft.group == AdjustmentGroup.CURVE) onClearHslTarget(true)
                if (current.draft.group == AdjustmentGroup.WHITE_BALANCE) onClearWbProbe(true)
                runCatching { draftStore.clear(photo.identity) }
                onIncrementEditRevision()
                draftRevision += 1
                setPreviewLongEdge(requestedPreviewLongEdge)
                mutable.value = mutable.value.copy(
                    edits = edits, draft = null, rendering = true, exact = false, previewResizePending = false,
                    error = null, saveState = saved.state, saveError = saved.formatMessage(strings),
                )
                val renderRev = onSubmitPreview(Work.Preview(photo, edits, false, gpuMode(), edge = getPreviewLongEdge()))
                durablePreview = EditorDurablePreview(photo.identity, photo.file.absolutePath, currentSourceRevision(), renderRev, edits)
                completed(true)
            }
        }
    }

    fun discardDraft() {
        if (mutable.value.committingAdjustments) return
        val current = mutable.value
        val draft = current.draft ?: return
        if (draft.group == AdjustmentGroup.HSL || draft.group == AdjustmentGroup.CURVE) onClearHslTarget(true)
        if (draft.group == AdjustmentGroup.WHITE_BALANCE) onClearWbProbe(true)
        current.photo?.let { runCatching { draftStore.clear(it.identity) } }
        val saved = draftSaveBaseline.takeIf { failedDraftSave }
        failedDraftSave = false
        draftSaveBaseline = null
        draftRevision += 1
        mutable.value = current.copy(
            draft = null,
            saveState = saved?.first ?: current.saveState,
            saveError = if (saved != null) saved.second else current.saveError,
        )
        val shown = current.draftRenderEdits()
        if (shown == current.edits && current.exact && !current.rendering && current.error == null) {
            updatePreviewSize(requestedPreviewLongEdge)
            return
        }
        renderCommittedForNavigation()
    }

    fun renderCommittedForNavigation() {
        onCancelHslTarget()
        onCancelWbProbe()
        val current = mutable.value
        val photo = current.photo ?: return
        onClearDeferredMigrationPreview()
        setPreviewLongEdge(requestedPreviewLongEdge)
        mutable.value = current.copy(rendering = true, exact = false, error = null)
        val renderRev = onSubmitPreview(Work.Preview(photo, current.edits, false, gpuMode(), edge = getPreviewLongEdge()))
        navigationPreview = EditorDurablePreview(
            photo.identity, photo.file.absolutePath, currentSourceRevision(), renderRev, current.edits,
        )
    }

    fun preserveEditorDraft() {
        val current = mutable.value
        val photo = current.photo ?: return
        val fingerprint = photo.sourceFingerprint ?: return
        val draft = current.draft ?: return
        runCatching { draftStore.save(photo.identity, fingerprint, draft.copy(interacting = false)) }
            .onFailure { mutable.value = mutable.value.copy(message = EditSaveResult(EditSaveState.FAILED, it).formatMessage(strings)) }
    }

    fun restoreEditorDraft() {
        val current = mutable.value
        val photo = current.photo ?: return
        val fingerprint = photo.sourceFingerprint ?: return
        val draft = runCatching { draftStore.load(photo.identity, fingerprint, current.edits) }
            .getOrElse {
                mutable.value = current.copy(message = EditSaveResult(EditSaveState.FAILED, it).formatMessage(strings))
                null
            } ?: return
        draftRevision += 1
        draftSaveBaseline = current.saveState to current.saveError
        mutable.value = current.copy(draft = draft.copy(interacting = false))
        renderDraft(false)
    }

    fun prepareReset(scope: EditorResetScope): EditorResetPreparation {
        val current = mutable.value
        val session = resetSession()
        if (isDisposed() || session == null || !current.controlsEnabled || !current.exact ||
            current.rendering || current.previewResizePending || current.error != null
        ) {
            return EditorResetPreparation(EditorResetResult.Blocked("The current preview is not ready"))
        }
        return EditorResetTransaction.prepare(scope, session)
    }

    fun commitReset(prepared: PreparedEditorReset): Boolean {
        val current = mutable.value
        val session = resetSession() ?: return false
        if (isDisposed() || !current.controlsEnabled || !current.exact || current.rendering ||
            current.previewResizePending || current.error != null || !prepared.matches(session)
        ) return false
        prepared.draftCandidate?.let { next ->
            if (next != current.draft) updateDraft(current, next)
            return next != current.draft
        }
        val previousRequest = currentRenderRevision()
        onEdit(prepared.result.candidate, false, prepared.scope == EditorResetScope.All)
        return currentRenderRevision() != previousRequest
    }

    private fun resetSession(): EditorResetSession? {
        val current = mutable.value
        val photo = current.photo ?: return null
        val shot = current.preview?.takeIf { it.temperature.isFinite() && it.tint.isFinite() }
            ?.let { AsShotWhiteBalance(it.temperature, it.tint) }
        val context = EditorResetContext(photo.inputKind, EditSettings().effectiveFor(photo.inputKind), shot, resetRecipeIds)
        return EditorResetSession(
            photo.identity, photo.file.absolutePath, currentSourceRevision(), currentEditRevision(),
            current.edits, current.draft, draftRevision, context,
        )
    }

    fun incrementDraftRevision() {
        draftRevision += 1
    }
}
