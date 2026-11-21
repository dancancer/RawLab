package com.rawlab.android.editor

import android.util.Log
import com.rawlab.android.R
import com.rawlab.android.adjustments.AdjustmentTransfer
import com.rawlab.android.analytics.UsageEvent
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.editor.render.isExportCancellation
import com.rawlab.android.editor.storage.EditSaveResult
import com.rawlab.android.editor.storage.EditorEditStore
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.canonicalZeros
import com.rawlab.android.settings.synchronizeHDR
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

private const val PREVIEW_TAG = "com.rawlab.EditorViewModel"

internal class EditorPreviewCoordinator(
    private val mutable: MutableStateFlow<EditorState>,
    private val scope: CoroutineScope,
    private val strings: EditorStrings,
    private val editStore: EditorEditStore,
    private val adjustmentHistory: EditorAdjustmentHistory,
    private val previewCache: EditorPreviewCacheSink,
    private val saveNoticeFadeDelayMs: Long,
    private val recordUsage: (UsageEvent) -> Unit,
    private val isDisposed: () -> Boolean,
    private val isEditorActive: () -> Boolean,
    private val currentActivationRevision: () -> Long,
    private val currentSourceRevision: () -> Long,
    private val currentEditRevision: () -> Long,
    private val currentRenderRevision: () -> Long,
    private val getPreviewLongEdge: () -> Int,
    private val setPreviewLongEdge: (Int) -> Unit,
    private val onIncrementEditRevision: () -> Unit,
    private val onSubmitRender: (Work) -> Long,
    private val onCommitAdjustments: (work: () -> EditSaveResult, completed: (Result<EditSaveResult>) -> Unit) -> Unit,
    private val onRecoverSource: (work: () -> com.rawlab.android.settings.PhotoEditState, completed: (Result<com.rawlab.android.settings.PhotoEditState>) -> Unit) -> Unit,
    private val lookHolder: EditorLookStateHolder,
    private val importRecoveryHolder: EditorImportRecoveryStateHolder,
    private val hslHolder: EditorHslEyedropperStateHolder,
    private val hdrHolder: EditorHdrStateHolder,
    private val exportHolder: EditorExportStateHolder,
    private val processingMigrationHolder: EditorProcessingMigrationStateHolder,
    private val adjustmentTransferHolder: EditorAdjustmentTransferStateHolder,
    private val collectionHolder: EditorCollectionStateHolder,
    private val batchHolder: EditorBatchStateHolder,
    private val draftHolder: EditorDraftStateHolder,
    private val formatFailure: (Throwable) -> String,
    private val onExactPreviewAccepted: () -> Unit = {},
    private val onDetailAccepted: (WorkResult.DetailPreview) -> Unit = { value ->
        mutable.value = mutable.value.copy(detail = value.overlay)
    },
) {
    private var saveNotice: Job? = null

    fun accept(result: Result<WorkResult>) {
        (result.getOrNull() as? WorkResult.DetailPreview)?.let {
            acceptDetailPreview(it)
            return
        }
        hdrHolder.onRenderResult()
        result.fold({ value ->
            when (value) {
                is WorkResult.X3fImportFailure -> importRecoveryHolder.handleX3fFailure(value)
                is WorkResult.UnusableEditImportFailure -> importRecoveryHolder.handleUnusableFailure(value)
                is WorkResult.MissingLook -> importRecoveryHolder.handleMissingLook(value)
                is WorkResult.HslProbe -> hslHolder.accept(value)
                is WorkResult.CameraHDRPreflight -> hdrHolder.onCameraHDRPreflight(value)
                is WorkResult.Preview -> acceptPreview(value)
                is WorkResult.DetailPreview -> acceptDetailPreview(value)
                WorkResult.Export -> exportHolder.onExportCompleted()
                is WorkResult.AutoExposure -> acceptAutoExposure(value)
            }
            fadeSaveNotice()
        }, { error ->
            if (mutable.value.operation == Operation.IMPORT) importRecoveryHolder.clearPendingImport()
            val finished = EditorStateReducer.renderFinished(mutable.value)
            mutable.value = if (isExportCancellation(error)) finished else finished.copy(error = formatFailure(error))
        })
        collectionHolder.releaseDeferred()
        draftHolder.updatePreviewSize(draftHolder.requestedPreviewLongEdge)
    }

    private fun acceptDetailPreview(value: WorkResult.DetailPreview) {
        val current = mutable.value
        val request = value.request
        if (current.photo != request.photo ||
            current.visibleEdits != request.edits ||
            currentSourceRevision() != request.sourceRevision ||
            currentEditRevision() != request.editRevision ||
            !current.controlsEnabled ||
            !current.exact ||
            current.rendering ||
            current.previewResizePending ||
            current.draft?.group == AdjustmentGroup.GEOMETRY
        ) {
            return
        }
        onDetailAccepted(value)
    }

    private fun acceptPreview(value: WorkResult.Preview) {
        val request = value.request
        if (request.draft) {
            val current = mutable.value
            val draft = current.draft ?: return
            val refitted = draftHolder.fitGeometryDraft(draft, value.pair)
            if (refitted != draft) draftHolder.incrementDraftRevision()
            mutable.value = EditorStateReducer.renderFinished(current)
                .copy(draft = refitted, preview = value.pair, exact = !request.interactive, error = null)
            hslHolder.recordAcceptedPreview(request, refitted.project(current.edits), currentSourceRevision(), currentRenderRevision())
            if (!request.interactive && refitted.group != AdjustmentGroup.GEOMETRY) onExactPreviewAccepted()
            return
        }
        val imported = importRecoveryHolder.completePendingImport(request.photo.identity)
        if (request.importing) {
            importRecoveryHolder.releasePreviousPhoto(request.photo)
            adjustmentHistory.acceptSource(request.photo, request.importedRecord)
            collectionHolder.opened(request.photo.identity.value)
        }
        if (imported) recordUsage(UsageEvent.PhotoImported)
        val settings = if (!request.edits.customWb && value.pair.temperature.isFinite()) {
            request.edits.copy(
                temperature = value.pair.temperature.coerceIn(2000f, 50000f),
                tint = if (request.edits.recipeID == null) value.pair.tint.coerceIn(-150f, 150f) else request.edits.tint,
            )
        } else request.edits
        val alreadyDurable = draftHolder.consumeDurableMatch(
            request.photo, currentSourceRevision(), currentRenderRevision(), settings,
        )
        val navigationOnly = draftHolder.consumeNavigationMatch(
            request.photo, currentSourceRevision(), currentRenderRevision(), settings,
        )
        if (settings != mutable.value.edits) onIncrementEditRevision()
        val saved = when {
            navigationOnly -> null
            alreadyDurable -> EditSaveResult(EditSaveState.SAVED)
            request.importing -> if (!editStore.available) editStore.initialResult else
                EditSaveResult(if (request.restored) EditSaveState.RESTORED else EditSaveState.NONE)
            else -> null
        }
        val processingMigration = if (request.importing) {
            runCatching { editStore.processingMigration(request.photo.identity) }.getOrNull()
        } else mutable.value.processingMigration
        mutable.value = EditorStateReducer.renderFinished(mutable.value).copy(
            photo = request.photo,
            edits = settings,
            preview = value.pair,
            exact = !request.interactive,
            error = null,
            saveState = if (request.restored && saved?.state == EditSaveState.SAVED) EditSaveState.RESTORED else saved?.state ?: mutable.value.saveState,
            saveError = if (saved == null) mutable.value.saveError else saved.formatMessage(strings),
            processingMigration = processingMigration,
        )
        hslHolder.recordAcceptedPreview(request, settings, currentSourceRevision(), currentRenderRevision())
        if (!request.interactive) scope.launch {
            runCatching { previewCache.accept(request.photo, request.edits, value.pair.result) }
        }
        lookHolder.includeIndependentRecipeLook(settings)
        if (request.persistOnImport) persist(request.photo, settings) { result ->
            mutable.value = mutable.value.copy(saveState = result.state, saveError = result.formatMessage(strings))
        }
        if (request.importing && mutable.value.draft == null) draftHolder.restoreEditorDraft()
        processingMigrationHolder.startIfNeeded()
        if (!request.interactive) onExactPreviewAccepted()
    }

    private fun acceptAutoExposure(value: WorkResult.AutoExposure) {
        val current = mutable.value
        mutable.value = EditorStateReducer.renderFinished(current)
        if (isEditorActive() && value.request.sourceRevision == currentSourceRevision() &&
            value.request.draftRevision == draftHolder.draftRevision &&
            value.request.activationRevision == currentActivationRevision() &&
            current.photo?.identity == value.request.photo.identity && current.visibleEdits == value.request.edits
        ) {
            if (current.visibleEdits.exposure != value.exposure) edit(current.visibleEdits.copy(exposure = value.exposure))
        }
    }

    fun edit(requested: EditSettings, interactive: Boolean = false, clearProcessingMigration: Boolean = false) {
        val edits = requested.canonicalZeros().synchronizeHDR()
        hslHolder.cancel()
        val current = mutable.value
        if (!current.controlsEnabled) {
            Log.w(PREVIEW_TAG, "edit-dropped method=edit reason=controlsDisabled op=${current.operation}")
            return
        }
        if (current.draft != null) {
            draftHolder.changeDraft(edits, interactive)
            return
        }
        if (adjustmentTransferHolder.quickPreset.value.phase == QuickPresetPhase.PREPARING) {
            adjustmentTransferHolder.cancelQuickPreset()
        }
        if (interactive) {
            val saved = adjustmentHistory.begin(current.photo!!, current.edits, currentSourceRevision())
            if (saved.state == EditSaveState.FAILED) {
                mutable.value = current.copy(saveState = saved.state, saveError = saved.formatMessage(strings))
                return
            }
        } else if (!adjustmentHistory.finish(current.photo!!, currentSourceRevision())) return
        val look = current.looks.firstOrNull { it.id == edits.film }
        if (!edits.isHDREditing && look?.managed == true && !look.available) {
            mutable.value = current.copy(error = strings.text(R.string.look_unavailable))
            return
        }
        if (!edits.denoise.enabled && draftHolder.hasResizePending()) {
            draftHolder.cancelResize()
            setPreviewLongEdge(draftHolder.requestedPreviewLongEdge)
        }
        draftHolder.clearDurablePreview()
        if (edits != current.edits) onIncrementEditRevision()
        if (!interactive && clearProcessingMigration) processingMigrationHolder.scheduleResetClear(currentSourceRevision(), edits)
        else processingMigrationHolder.clearPendingReset()
        mutable.value = current.copy(
            edits = edits, rendering = true, exact = false, error = null, matchingProcessing = false,
            previewResizePending = draftHolder.hasResizePending(),
            hdrCameraDraft = current.hdrCameraDraft?.retainedFor(edits.hdr?.cameraSettings),
        )
        onSubmitRender(
            Work.Preview(
                current.photo!!, edits, interactive, gpuMode(),
                edge = draftHolder.interactiveEdge(getPreviewLongEdge(), interactive),
            ),
        )
        if (!interactive) persist(current.photo, edits, clearProcessingMigration = clearProcessingMigration) { saved ->
            mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.formatMessage(strings))
            fadeSaveNotice()
        }
    }

    fun persist(photo: ImportedPhoto, edits: EditSettings, clearProcessingMigration: Boolean = false, completed: (EditSaveResult) -> Unit) {
        val previousFilm = adjustmentHistory.snapshot().loaded?.settings?.film
        val source = currentSourceRevision()
        val synced = edits.synchronizeHDR()
        val clearsMigration = clearProcessingMigration || processingMigrationHolder.shouldClearOnPersist(source, synced)
        if (!clearsMigration) processingMigrationHolder.clearPendingReset()
        onCommitAdjustments({ adjustmentHistory.commit(photo, synced, clearProcessingMigration = clearsMigration) }) { result ->
            val saved = result.getOrElse { EditSaveResult(EditSaveState.FAILED, it) }
            if (saved.state == EditSaveState.SAVED) {
                processingMigrationHolder.clearPendingReset(source, synced)
                if (clearsMigration && source == currentSourceRevision() && mutable.value.photo?.identity == photo.identity) {
                    mutable.value = mutable.value.copy(processingMigration = null)
                }
                if (source == currentSourceRevision() && mutable.value.photo?.identity == photo.identity &&
                    mutable.value.visibleEdits.film == edits.film && edits.recipeID == null && previousFilm != edits.film
                ) lookHolder.updateRecentLooks(edits.film)
            }
            completed(saved)
            if (saved.state == EditSaveState.SAVED && source == currentSourceRevision()) cacheAcceptedPhotoPreview()
        }
    }

    private fun cacheAcceptedPhotoPreview() {
        val current = mutable.value
        val request = hslHolder.acceptedPreviewRequest() ?: return
        val pair = current.preview ?: return
        if (!current.exact || current.draft != null || request.interactive || current.photo?.identity != request.photo.identity) return
        scope.launch { runCatching { previewCache.accept(request.photo, request.edits, pair.result) } }
    }

    fun retry() {
        if (importRecoveryHolder.retryX3fIfPresent()) return
        if (mutable.value.draft != null) draftHolder.renderDraft(false)
        else if (mutable.value.controlsEnabled) draftHolder.renderCommittedForNavigation()
    }

    fun autoExposure() {
        val current = mutable.value
        if (!current.controlsEnabled || current.preview == null || current.rendering ||
            (current.draft != null && current.draft.group != AdjustmentGroup.EXPOSURE)
        ) {
            if (!current.controlsEnabled) Log.w(PREVIEW_TAG, "edit-dropped method=autoExposure reason=controlsDisabled op=${current.operation}")
            return
        }
        mutable.value = current.copy(rendering = true, error = null)
        onSubmitRender(
            Work.AutoExposure(
                current.photo!!, current.visibleEdits, gpuMode(),
                currentSourceRevision(), draftHolder.draftRevision, currentActivationRevision(),
            ),
        )
    }

    fun retrySave(completed: (Boolean) -> Unit = {}) {
        if (mutable.value.committingAdjustments) return completed(false)
        val photo = mutable.value.photo
        fun accept(saved: EditSaveResult) {
            mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.formatMessage(strings))
            fadeSaveNotice()
            completed(saved.state != EditSaveState.FAILED)
        }
        if (photo != null && adjustmentHistory.snapshot().loaded == null) {
            val edits = mutable.value.edits
            onRecoverSource({ adjustmentHistory.recoverSource(photo) }) { result ->
                result.fold({ record ->
                    if (draftHolder.failedDraftSave && mutable.value.draft != null) {
                        draftHolder.applyDraft(completed)
                        return@fold
                    }
                    if (AdjustmentTransfer.sameAdjustments(edits, photo.defaultEditSettings(), photo.inputKind == PhotoInputKind.RAW)) {
                        processingMigrationHolder.clearPendingReset()
                        val restored = record.settings ?: photo.defaultEditSettings()
                        if (restored != edits) onIncrementEditRevision()
                        mutable.value = mutable.value.copy(edits = restored)
                        lookHolder.includeIndependentRecipeLook(restored)
                        draftHolder.renderCommittedForNavigation()
                        accept(EditSaveResult(if (record.settings == null) EditSaveState.NONE else EditSaveState.RESTORED))
                    } else persist(photo, edits, completed = ::accept)
                }, { accept(EditSaveResult(EditSaveState.FAILED, it, reading = true)) })
            }
        } else if (draftHolder.failedDraftSave && mutable.value.draft != null) draftHolder.applyDraft(completed)
        else if (photo != null) persist(photo, mutable.value.edits, completed = ::accept)
        else onCommitAdjustments(editStore::reopen) {
            accept(it.getOrElse { error -> EditSaveResult(EditSaveState.FAILED, error, reading = true) })
        }
    }

    fun setGpuEnabled(enabled: Boolean) {
        if (mutable.value.committingAdjustments || mutable.value.operation != Operation.NONE) return
        mutable.value = mutable.value.copy(gpuEnabled = enabled)
        if (mutable.value.draft != null) draftHolder.renderDraft(false)
        else if (mutable.value.photo != null) edit(mutable.value.edits)
    }

    fun fadeSaveNotice() {
        saveNotice?.cancel()
        if (mutable.value.saveState !in setOf(EditSaveState.SAVED, EditSaveState.RESTORED)) return
        saveNotice = scope.launch {
            delay(saveNoticeFadeDelayMs)
            if (mutable.value.saveState in setOf(EditSaveState.SAVED, EditSaveState.RESTORED)) {
                mutable.value = mutable.value.copy(saveState = EditSaveState.NONE)
            }
        }
    }

    fun onBackground(setEditorActive: (Boolean) -> Unit) {
        draftHolder.preserveEditorDraft()
        setEditorActive(false)
        collectionHolder.cancelExport()
        if (mutable.value.committingAdjustments) {
            batchHolder.cancelForBackground()
            return
        }
        adjustmentTransferHolder.cancelInteraction()
        batchHolder.cancelForBackground()
        mutable.value.photo?.let { photo ->
            persist(photo, mutable.value.edits) { saved ->
                if (saved.state == EditSaveState.FAILED) {
                    mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.formatMessage(strings))
                }
            }
        }
    }

    private fun gpuMode() = if (mutable.value.gpuEnabled) NativeProcessor.AUTO else NativeProcessor.CPU
}
