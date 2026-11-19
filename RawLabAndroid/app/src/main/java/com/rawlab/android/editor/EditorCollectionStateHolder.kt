package com.rawlab.android.editor

import android.net.Uri
import com.rawlab.android.adjustments.AdjustmentFailure
import com.rawlab.android.adjustments.AdjustmentHistoryTransaction
import com.rawlab.android.adjustments.AdjustmentPayload
import com.rawlab.android.adjustments.AdjustmentScope
import com.rawlab.android.adjustments.AdjustmentStatus
import com.rawlab.android.adjustments.AdjustmentTransfer
import com.rawlab.android.adjustments.AdjustmentTransferException
import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.CollectionExportReview
import com.rawlab.android.editor.storage.EditSaveResult
import com.rawlab.android.editor.storage.EditorEditStore
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.AdjustmentNotReadyException
import com.rawlab.android.settings.EditSettings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import java.io.File
import java.util.UUID

internal class EditorCollectionStateHolder(
    storage: PhotoStorage,
    scope: CoroutineScope,
    journalRoot: File,
    private val mutable: MutableStateFlow<EditorState>,
    private val editStore: EditorEditStore,
    private val adjustmentHistory: EditorAdjustmentHistory,
    private val strings: EditorStrings,
    private val isDisposed: () -> Boolean,
    private val currentSourceRevision: () -> Long,
    private val hasActivePreparations: () -> Boolean,
    private val ownsFailedImportRecovery: (File) -> Boolean,
    private val adjustmentTargetIsCurrent: (String, EditorAdjustmentHistory.Snapshot) -> Boolean,
    private val hasActiveBatch: () -> Boolean,
    private val retainBatch: (BatchJob) -> Unit,
    private val resumeBatchJob: (BatchJob, Boolean) -> Unit,
    private val releaseEditorRasterForBatch: ((Boolean) -> Unit) -> Unit,
    private val onCommitAdjustments: (work: () -> Unit, completed: (Result<Unit>) -> Unit) -> Unit,
    private val onImportPhoto: (Uri, (Boolean) -> Unit) -> Unit,
    private val onCapturePresetAdjustments: (AdjustmentScope, (Result<AdjustmentPayload>) -> Unit) -> Unit,
    private val onCancelAdjustmentInteraction: () -> Unit,
    private val onEdit: (EditSettings, Boolean) -> Unit,
    private val onApplyDraft: ((Boolean) -> Unit) -> Unit,
    private val onDiscardDraft: () -> Unit,
    private val onRetrySave: ((Boolean) -> Unit) -> Unit,
    private val onClearPendingResetMigration: () -> Unit,
    private val onIncrementEditRevision: () -> Unit,
    private val onIncludeIndependentRecipeLook: (EditSettings) -> Unit,
    private val onRenderCommittedForNavigation: () -> Unit,
) {
    val collections = EditorCollections(
        storage,
        scope,
        journalRoot,
        editStore::readState,
        { adjustmentHistory.session?.editGeneration(it) ?: 0L },
        ::captureActiveValidation,
        awaitPendingEdits = { mutable.first { !it.committingAdjustments } },
        canRelease = { photo ->
            mutable.value.photo?.file != photo.file &&
                !ownsFailedImportRecovery(photo.file) &&
                mutable.value.operation != Operation.IMPORT &&
                !hasActivePreparations() &&
                !mutable.value.committingAdjustments
        },
    )
    val state = collections.state
    private val mutableExport = MutableStateFlow(CollectionExportFlow())
    val export = mutableExport.asStateFlow()
    @Volatile private var exportGeneration = UUID.randomUUID()

    fun close(onReleased: () -> Unit) = collections.close(onReleased)
    fun photo(id: String) = collections.photo(id)
    fun owns(file: File) = collections.owns(file)
    fun releaseDeferred() = collections.releaseDeferred()
    fun opened(id: String) = collections.opened(id)
    fun synchronized(id: UUID, changed: Boolean) = collections.synchronized(id, changed)
    fun validate(target: com.rawlab.android.batch.BatchTarget) = collections.validate(target)

    fun addPhotos(uris: List<Uri>) = collections.add(uris, mutable.value.photo)
    fun retainCurrent() { mutable.value.photo?.let { collections.add(listOf(it.uri), it) } }
    fun selectPhoto(id: String, selected: Boolean) = collections.select(id, selected)
    fun selectAll(selected: Boolean) = collections.selectAll(selected)
    fun removePhoto(id: String) = collections.remove(id)
    fun refresh() = collections.refresh()
    fun supportsHDRExport(skipping: Set<String> = emptySet()) =
        state.value.supportsHDRExport(editStore::readState, skipping)

    fun draftFailure(id: String): String? {
        val current = mutable.value
        val photo = current.photo?.takeIf { it.identity.value == id } ?: return null
        val history = adjustmentHistory.snapshot()
        if (!adjustmentTargetIsCurrent(id, history)) return current.saveError ?: "Apply, discard or skip this photo's draft"
        val record = history.loaded
        return if (record == null || !AdjustmentTransfer.sameAdjustments(
                record.settings ?: photo.defaultEditSettings(),
                current.edits,
                photo.inputKind == PhotoInputKind.RAW,
            )
        ) "Apply, discard or skip this photo's draft" else null
    }

    private fun captureActiveValidation(): (String) -> Unit {
        val current = mutable.value
        val photo = current.photo ?: return {}
        val history = adjustmentHistory.snapshot()
        val captured = runCatching {
            check(adjustmentTargetIsCurrent(photo.identity.value, history)) {
                current.saveError ?: "Apply, discard or skip this photo's draft"
            }
            history.committedValidation(photo, current.edits)
        }
        return { id ->
            if (id == photo.identity.value) {
                val latest = mutable.value
                check(
                    latest.photo?.identity == photo.identity &&
                        latest.edits == current.edits &&
                        latest.draft == null &&
                        latest.operation == Operation.NONE &&
                        !latest.committingAdjustments,
                ) { "Apply, discard or skip this photo's draft" }
                captured.getOrThrow()()
            }
        }
    }

    fun resolveDraft(apply: Boolean, completed: (Boolean) -> Unit = {}) {
        if (mutable.value.committingAdjustments) return completed(false)
        val history = adjustmentHistory.snapshot()
        if (apply) {
            if (history.interacting) {
                onEdit(mutable.value.edits, false)
                return completed(false)
            }
            mutable.value.draft?.let { draft ->
                if (draft.changed) {
                    onApplyDraft(completed)
                    return
                }
                onDiscardDraft()
                completed(true)
                return
            }
            onRetrySave(completed)
        } else {
            val loaded = history.loaded
            if (mutable.value.photo != null && loaded == null) {
                val unavailable = EditSaveResult(EditSaveState.FAILED, AdjustmentNotReadyException(), reading = true)
                mutable.value = mutable.value.copy(saveState = unavailable.state, saveError = unavailable.formatMessage(strings))
                completed(false)
                return
            }
            onClearPendingResetMigration()
            onCancelAdjustmentInteraction()
            mutable.value.draft?.let { onDiscardDraft() }
            val current = mutable.value
            val photo = current.photo
            val restored = if (photo == null) null else loaded?.settings ?: photo.defaultEditSettings()
            if (photo != null && restored != null && current.edits != restored) {
                onIncrementEditRevision()
                mutable.value = current.copy(
                    edits = restored,
                    draft = null,
                    saveState = EditSaveState.SAVED,
                    saveError = null,
                    error = null,
                    adjustmentRevision = current.adjustmentRevision + 1,
                )
                onIncludeIndependentRecipeLook(restored)
                onRenderCommittedForNavigation()
            } else if (photo != null && current.saveState == EditSaveState.FAILED) {
                mutable.value = current.copy(
                    saveState = if (loaded?.settings == null) EditSaveState.NONE else EditSaveState.SAVED,
                    saveError = null,
                    adjustmentRevision = current.adjustmentRevision + 1,
                )
            }
            completed(photo != null)
        }
    }

    fun editPhoto(id: String, completed: (Boolean) -> Unit = {}) {
        val target = state.value.photos.firstOrNull { it.id == id } ?: return completed(false)
        if (state.value.busy || mutable.value.committingAdjustments || mutable.value.draft != null ||
            mutable.value.operation != Operation.NONE
        ) return completed(false)
        onCommitAdjustments({ collections.validateForCommit(target) }) { outcome ->
            outcome.fold({
                if (mutable.value.photo?.identity?.value == id) {
                    collections.opened(id)
                    completed(true)
                } else {
                    onImportPhoto(Uri.parse(target.sourceUri), completed)
                }
            }, { error ->
                collections.failure(error.message)
                completed(false)
            })
        }
    }

    fun returnToCollection(completed: (Boolean) -> Unit = {}) {
        if (mutable.value.draft != null || mutable.value.operation != Operation.NONE || mutable.value.committingAdjustments) {
            return completed(false)
        }
        onCancelAdjustmentInteraction()
        if (mutable.value.photo == null) {
            collections.returnToCollection()
            collections.refresh()
            completed(true)
        } else {
            onRetrySave { accepted ->
                if (accepted) {
                    collections.returnToCollection()
                    collections.refresh()
                }
                completed(accepted)
            }
        }
    }

    fun captureSynchronization(scope: AdjustmentScope, completed: (CollectionSynchronization?) -> Unit) {
        val photo = mutable.value.photo
        if (photo == null) {
            collections.failure("Choose a source photo first")
            completed(null)
            return
        }
        val targets = state.value.synchronizationTargets(photo.identity.value).map { Uri.parse(it.sourceUri) }
        if (targets.isEmpty()) {
            collections.failure("No targets remain after excluding the source photo")
            completed(null)
            return
        }
        onCapturePresetAdjustments(scope) { result ->
            result.fold(
                { completed(CollectionSynchronization(photo.identity.value, photo.name, it, targets)) },
                { collections.failure(it.message); completed(null) },
            )
        }
    }

    fun prepareExport(skipping: Set<String>, format: ExportFormat, longEdge: Int?, destination: Uri?, completed: (CollectionExportReview?) -> Unit) =
        collections.prepare(skipping, format, longEdge, destination, completed)

    fun freezeExport(review: CollectionExportReview, completed: (Boolean) -> Unit) {
        freezeAndAttachExport(review, false, { true }) { _, attached -> completed(attached) }
    }

    fun cancelExport() {
        exportGeneration = UUID.randomUUID()
        mutableExport.value = mutableExport.value.copy(preparing = false, review = null)
    }

    fun startExport(skipping: Set<String>, format: ExportFormat, longEdge: Int?, destination: Uri?, completed: (Boolean) -> Unit = {}) {
        if (mutableExport.value.preparing || mutableExport.value.freezing || state.value.busy) return
        cancelExport()
        val generation = exportGeneration
        val source = mutable.value.photo
        val sourceVersion = currentSourceRevision()
        val revision = mutable.value.adjustmentRevision
        val selected = state.value.selected
        val current = {
            !isDisposed() &&
                generation == exportGeneration &&
                currentSourceRevision() == sourceVersion &&
                mutable.value.photo === source &&
                mutable.value.adjustmentRevision == revision &&
                state.value.selected == selected
        }
        mutableExport.value = CollectionExportFlow(preparing = true)
        collections.prepare(skipping, format, longEdge, destination) { review ->
            if (generation != exportGeneration) return@prepare
            if (!current()) {
                mutableExport.value = CollectionExportFlow()
                collections.failure("Review the selected photos again")
            } else if (review?.ready != true) {
                mutableExport.value = CollectionExportFlow(review = review)
            } else {
                mutableExport.value = CollectionExportFlow(preparing = true, freezing = true, review = review)
                freezeAndAttachExport(review, true, current) { job, _ ->
                    mutableExport.value = CollectionExportFlow()
                    if (job != null) completed(true)
                }
            }
        }
    }

    private fun freezeAndAttachExport(
        review: CollectionExportReview,
        automaticallyStart: Boolean,
        isCurrent: () -> Boolean,
        completed: (BatchJob?, Boolean) -> Unit,
    ) {
        if (hasActiveBatch()) {
            collections.failure("Close the current export task first")
            completed(null, false)
            return
        }
        collections.freeze(review, isCurrent) { job ->
            if (job == null) {
                completed(null, false)
            } else {
                retainBatch(job)
                releaseEditorRasterForBatch { released ->
                    if (released) resumeBatchJob(job, automaticallyStart && isCurrent())
                    else collections.failure(mutable.value.error)
                    completed(job, released)
                }
            }
        }
    }
}
