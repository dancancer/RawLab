package com.rawlab.android.editor

import android.util.Log
import com.rawlab.android.R
import com.rawlab.android.adjustments.AdjustmentTransfer
import com.rawlab.android.analytics.UsageEvent
import com.rawlab.android.editor.render.ViewportRenderEngine
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.editor.render.isExportCancellation
import com.rawlab.android.editor.storage.EditSaveResult
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.canonicalZeros
import com.rawlab.android.settings.synchronizeHDR
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private const val PREVIEW_TAG = "com.rawlab.EditorViewModel"

internal class EditorPreviewCoordinator(
    private val session: EditorDocumentSession,
    private val viewport: ViewportRenderEngine,
) {
    private val mutable get() = session.mutable
    private val scope get() = session.scope
    private val strings get() = session.strings
    private val editStore get() = session.editStore
    private val adjustmentHistory get() = session.adjustmentHistory
    private val previewCache get() = session.previewCache
    private val saveNoticeFadeDelayMs get() = session.dependencies.saveNoticeFadeDelayMs
    private val recordUsage get() = session.dependencies.recordUsage

    private var saveNotice: Job? = null

    fun accept(result: Result<WorkResult>) {
        (result.getOrNull() as? WorkResult.DetailPreview)?.let {
            acceptDetailPreview(it)
            return
        }
        session.actions.onRenderResultForHdr()
        result.fold({ value ->
            when (value) {
                is WorkResult.X3fImportFailure -> {
                    com.rawlab.android.diagnostics.DiagnosticRegistry.peek()?.recordError(
                        operation = "import",
                        stage = "x3fImportFailure",
                        error = value.error,
                    )
                    session.actions.handleX3fFailure(value)
                }
                is WorkResult.UnusableEditImportFailure -> {
                    com.rawlab.android.diagnostics.DiagnosticRegistry.peek()?.recordError(
                        operation = "import",
                        stage = "unusableEditRecord",
                        error = value.error,
                    )
                    session.actions.handleUnusableFailure(value)
                }
                is WorkResult.MissingLook -> {
                    com.rawlab.android.diagnostics.DiagnosticRegistry.peek()?.recordBreadcrumb(
                        level = "warn",
                        category = "look",
                        stage = "missingLook",
                        message = "Referenced look is unavailable on import",
                    )
                    session.actions.handleMissingLook(value)
                }
                is WorkResult.HslProbe -> session.actions.acceptHslProbe(value)
                is WorkResult.WbProbe -> session.actions.acceptWbProbe(value)
                is WorkResult.CameraHDRPreflight -> session.actions.onCameraHDRPreflight(value)
                is WorkResult.Preview -> acceptPreview(value)
                is WorkResult.DetailPreview -> acceptDetailPreview(value)
                WorkResult.Export -> session.actions.onExportCompleted()
                is WorkResult.AutoExposure -> acceptAutoExposure(value)
            }
            fadeSaveNotice()
        }, { error ->
            if (mutable.value.operation == Operation.IMPORT) session.actions.clearPendingImport()
            val finished = EditorStateReducer.renderFinished(mutable.value)
            mutable.value = if (isExportCancellation(error)) finished else finished.copy(error = session.failure(error))
        })
        session.actions.releaseDeferredCollections()
        session.actions.updatePreviewSize(session.actions.requestedPreviewLongEdge())
    }

    private fun acceptDetailPreview(value: WorkResult.DetailPreview) {
        val current = mutable.value
        val request = value.request
        if (current.photo != request.photo ||
            current.visibleEdits != request.edits ||
            session.sourceRevision != request.sourceRevision ||
            session.editRevision != request.editRevision ||
            !current.controlsEnabled ||
            !current.exact ||
            current.rendering ||
            current.previewResizePending ||
            current.draft?.group == AdjustmentGroup.GEOMETRY
        ) {
            return
        }
        viewport.handleDetailAccepted(value)
    }

    private fun acceptPreview(value: WorkResult.Preview) {
        val request = value.request
        if (request.draft) {
            val current = mutable.value
            val draft = current.draft ?: return
            val refitted = session.actions.fitGeometryDraft(draft, value.pair)
            if (refitted != draft) session.actions.incrementDraftRevision()
            mutable.value = EditorStateReducer.renderFinished(current)
                .copy(draft = refitted, preview = value.pair, exact = !request.interactive, error = null)
            val projected = refitted.project(current.edits)
            session.actions.recordHslAcceptedPreview(request, projected, session.sourceRevision, session.currentRevision)
            session.actions.recordWbAcceptedPreview(request, projected, session.sourceRevision, session.currentRevision)
            session.emit(EditorSessionEvent.PreviewAccepted(request, projected, session.sourceRevision, session.currentRevision))
            if (!request.interactive && refitted.group != AdjustmentGroup.GEOMETRY) viewport.scheduleDetailIfNeeded()
            return
        }
        val imported = session.actions.completePendingImport(request.photo.identity)
        if (request.importing) {
            session.actions.releasePreviousPhoto(request.photo)
            adjustmentHistory.acceptSource(request.photo, request.importedRecord, repairWritePending = request.repairWriteError != null)
            session.actions.collectionOpened(request.photo.identity.value)
        }
        if (imported) {
            recordUsage(UsageEvent.PhotoImported)
            com.rawlab.android.diagnostics.DiagnosticRegistry.peek()?.recordBreadcrumb(
                category = "import",
                stage = "photoImported",
                message = "Photo imported and initial preview delivered",
                context = mapOf(
                    "extension" to request.photo.file.extension,
                    "hdr" to request.edits.isHDREditing.toString(),
                ),
            )
        }
        val settings = if (!request.edits.customWb && value.pair.temperature.isFinite()) {
            request.edits.copy(
                temperature = value.pair.temperature.coerceIn(2000f, 50000f),
                tint = if (request.edits.recipeID == null) value.pair.tint.coerceIn(-150f, 150f) else request.edits.tint,
            )
        } else request.edits
        val alreadyDurable = session.actions.consumeDurableMatch(
            request.photo, session.sourceRevision, session.currentRevision, settings,
        )
        val navigationOnly = session.actions.consumeNavigationMatch(
            request.photo, session.sourceRevision, session.currentRevision, settings,
        )
        if (settings != mutable.value.edits) session.incrementEditRevision()
        val saved = when {
            navigationOnly -> null
            alreadyDurable -> EditSaveResult(EditSaveState.SAVED)
            request.importing -> when {
                !editStore.available -> editStore.initialResult
                request.repairWriteError != null -> EditSaveResult(EditSaveState.FAILED, request.repairWriteError)
                else -> EditSaveResult(if (request.restored) EditSaveState.RESTORED else EditSaveState.NONE)
            }
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
        session.actions.recordHslAcceptedPreview(request, settings, session.sourceRevision, session.currentRevision)
        session.actions.recordWbAcceptedPreview(request, settings, session.sourceRevision, session.currentRevision)
        session.emit(EditorSessionEvent.PreviewAccepted(request, settings, session.sourceRevision, session.currentRevision))
        if (!request.interactive) scope.launch {
            runCatching { previewCache.accept(request.photo, request.edits, value.pair.result) }
        }
        session.actions.includeIndependentRecipeLook(settings)
        if (request.persistOnImport) persist(request.photo, settings) { result ->
            mutable.value = mutable.value.copy(saveState = result.state, saveError = result.formatMessage(strings))
        }
        if (request.importing && mutable.value.draft == null) session.actions.restoreEditorDraft()
        if (request.repairWriteError == null) session.actions.startMigrationIfNeeded()
        if (!request.interactive) {
            com.rawlab.android.diagnostics.DiagnosticRegistry.peek()?.recordBreadcrumb(
                category = "preview",
                stage = "exactPreviewRendered",
                message = "Exact preview rendered",
                context = mapOf(
                    "width" to value.pair.result.width.toString(),
                    "height" to value.pair.result.height.toString(),
                    "gpuMode" to request.gpuMode.toString(),
                    "hdr" to request.edits.isHDREditing.toString(),
                ),
            )
            viewport.scheduleDetailIfNeeded()
        }
    }

    private fun acceptAutoExposure(value: WorkResult.AutoExposure) {
        val current = mutable.value
        mutable.value = EditorStateReducer.renderFinished(current)
        if (session.editorActive && value.request.sourceRevision == session.sourceRevision &&
            value.request.draftRevision == session.actions.draftRevision() &&
            value.request.activationRevision == session.activationRevision &&
            current.photo?.identity == value.request.photo.identity && current.visibleEdits == value.request.edits
        ) {
            if (current.visibleEdits.exposure != value.exposure) edit(current.visibleEdits.copy(exposure = value.exposure))
        }
    }

    fun edit(requested: EditSettings, interactive: Boolean = false, clearProcessingMigration: Boolean = false) {
        val edits = requested.canonicalZeros().synchronizeHDR()
        session.actions.cancelHslTarget()
        session.actions.cancelWbProbe()
        val current = mutable.value
        if (!current.controlsEnabled) {
            Log.w(PREVIEW_TAG, "edit-dropped method=edit reason=controlsDisabled op=${current.operation}")
            return
        }
        if (current.draft != null) {
            session.actions.changeDraft(edits, interactive)
            return
        }
        if (session.actions.isQuickPresetPreparing()) {
            session.actions.cancelQuickPreset()
        }
        if (interactive) {
            val saved = adjustmentHistory.begin(current.photo!!, current.edits, session.sourceRevision)
            if (saved.state == EditSaveState.FAILED) {
                mutable.value = current.copy(saveState = saved.state, saveError = saved.formatMessage(strings))
                return
            }
        } else if (!adjustmentHistory.finish(current.photo!!, session.sourceRevision)) return
        val look = current.looks.firstOrNull { it.id == edits.film }
        if (!edits.isHDREditing && look?.managed == true && !look.available) {
            mutable.value = current.copy(error = strings.text(R.string.look_unavailable))
            return
        }
        if (!edits.denoise.enabled && session.actions.hasPreviewResizePending()) {
            session.actions.cancelPreviewResize()
            session.previewLongEdge = session.actions.requestedPreviewLongEdge()
        }
        session.actions.clearDurablePreview()
        if (edits != current.edits) session.incrementEditRevision()
        if (!interactive && clearProcessingMigration) session.actions.scheduleResetClear(session.sourceRevision, edits)
        else session.actions.clearPendingResetMigration(null, null)
        mutable.value = current.copy(
            edits = edits, rendering = true, exact = false, error = null, matchingProcessing = false,
            previewResizePending = session.actions.hasPreviewResizePending(),
            hdrCameraDraft = current.hdrCameraDraft?.retainedFor(edits.hdr?.cameraSettings),
        )
        viewport.submitPreview(
            Work.Preview(
                current.photo!!, edits, interactive, session.gpuMode(),
                edge = session.actions.interactiveEdge(session.previewLongEdge, interactive),
            ),
        )
        if (!interactive) persist(current.photo, edits, clearProcessingMigration = clearProcessingMigration) { saved ->
            mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.formatMessage(strings))
            fadeSaveNotice()
        }
    }

    fun persist(photo: ImportedPhoto, edits: EditSettings, clearProcessingMigration: Boolean = false, completed: (EditSaveResult) -> Unit) {
        val previousFilm = adjustmentHistory.snapshot().loaded?.settings?.film
        val source = session.sourceRevision
        val synced = edits.synchronizeHDR()
        val clearsMigration = clearProcessingMigration || session.actions.shouldClearMigrationOnPersist(source, synced)
        if (!clearsMigration) session.actions.clearPendingResetMigration(null, null)
        session.commitAdjustments({ adjustmentHistory.commit(photo, synced, clearProcessingMigration = clearsMigration) }, false) { result ->
            val saved = result.getOrElse { EditSaveResult(EditSaveState.FAILED, it) }
            if (saved.state == EditSaveState.SAVED) {
                session.actions.clearPendingResetMigration(source, synced)
                if (clearsMigration && source == session.sourceRevision && mutable.value.photo?.identity == photo.identity) {
                    mutable.value = mutable.value.copy(processingMigration = null)
                }
                if (source == session.sourceRevision && mutable.value.photo?.identity == photo.identity &&
                    mutable.value.visibleEdits.film == edits.film && edits.recipeID == null && previousFilm != edits.film
                ) session.actions.updateRecentLooks(edits.film)
            }
            completed(saved)
            if (saved.state == EditSaveState.SAVED && source == session.sourceRevision) cacheAcceptedPhotoPreview()
        }
    }

    private fun cacheAcceptedPhotoPreview() {
        val current = mutable.value
        val request = session.actions.acceptedHslPreviewRequest() ?: return
        val pair = current.preview ?: return
        if (!current.exact || current.draft != null || request.interactive || current.photo?.identity != request.photo.identity) return
        scope.launch { runCatching { previewCache.accept(request.photo, request.edits, pair.result) } }
    }

    fun retry() {
        if (session.actions.retryX3fIfPresent()) return
        if (mutable.value.draft != null) session.actions.renderDraft(false)
        else if (mutable.value.controlsEnabled) session.actions.renderCommittedForNavigation()
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
        viewport.submitPreview(
            Work.AutoExposure(
                current.photo!!, current.visibleEdits, session.gpuMode(),
                session.sourceRevision, session.actions.draftRevision(), session.activationRevision,
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
            session.commitAdjustments({ adjustmentHistory.recoverSource(photo) }, false) { result ->
                result.fold({ openRepair ->
                    val record = openRepair.state
                    if (session.actions.failedDraftSave() && mutable.value.draft != null) {
                        session.actions.applyDraft(completed)
                        return@fold
                    }
                    if (AdjustmentTransfer.sameAdjustments(edits, photo.defaultEditSettings(), photo.inputKind == PhotoInputKind.RAW)) {
                        session.actions.clearPendingResetMigration(null, null)
                        val restored = record.settings ?: photo.defaultEditSettings()
                        if (restored != edits) session.incrementEditRevision()
                        mutable.value = mutable.value.copy(edits = restored)
                        session.actions.includeIndependentRecipeLook(restored)
                        session.actions.renderCommittedForNavigation()
                        val outcome = openRepair.writeError?.let { EditSaveResult(EditSaveState.FAILED, it) }
                            ?: EditSaveResult(if (record.settings == null) EditSaveState.NONE else EditSaveState.RESTORED)
                        accept(outcome)
                    } else persist(photo, edits, completed = ::accept)
                }, { accept(EditSaveResult(EditSaveState.FAILED, it, reading = true)) })
            }
        } else if (session.actions.failedDraftSave() && mutable.value.draft != null) session.actions.applyDraft(completed)
        else if (photo != null) persist(photo, mutable.value.edits, completed = ::accept)
        else session.commitAdjustments(editStore::reopen, false) {
            accept(it.getOrElse { error -> EditSaveResult(EditSaveState.FAILED, error, reading = true) })
        }
    }

    fun setGpuEnabled(enabled: Boolean) {
        if (mutable.value.committingAdjustments || mutable.value.operation != Operation.NONE) return
        mutable.value = mutable.value.copy(gpuEnabled = enabled)
        if (mutable.value.draft != null) session.actions.renderDraft(false)
        else if (mutable.value.photo != null) edit(mutable.value.edits)
    }

    fun fadeSaveNotice() {
        saveNotice?.cancel()
        if (mutable.value.saveState !in setOf(EditSaveState.SAVED, EditSaveState.RESTORED)) return
        session.emit(EditorSessionEvent.FadeSaveNoticeRequested)
        saveNotice = scope.launch {
            delay(saveNoticeFadeDelayMs)
            if (mutable.value.saveState in setOf(EditSaveState.SAVED, EditSaveState.RESTORED)) {
                mutable.value = mutable.value.copy(saveState = EditSaveState.NONE)
            }
        }
    }

    fun onBackground() {
        session.actions.preserveEditorDraft()
        session.actions.setEditorActive(false)
        session.emit(EditorSessionEvent.BackgroundRequested(active = false))
        session.actions.cancelCollectionExport()
        if (mutable.value.committingAdjustments) {
            session.actions.cancelBatchForBackground()
            return
        }
        session.actions.cancelAdjustmentInteraction()
        session.actions.cancelBatchForBackground()
        mutable.value.photo?.let { photo ->
            persist(photo, mutable.value.edits) { saved ->
                if (saved.state == EditSaveState.FAILED) {
                    mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.formatMessage(strings))
                }
            }
        }
    }
}
