package com.rawlab.android.editor

import android.net.Uri
import com.rawlab.android.adjustments.AdjustmentScope
import com.rawlab.android.adjustments.AdjustmentTransfer
import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.CollectionExportReview
import com.rawlab.android.editor.storage.EditSaveResult
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.AdjustmentNotReadyException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import java.io.File
import java.util.UUID

internal class EditorCollectionStateHolder(
    private val session: EditorDocumentSession,
    journalRoot: File,
) {
    private val mutable get() = session.mutable
    private val editStore get() = session.editStore
    private val adjustmentHistory get() = session.adjustmentHistory
    private val strings get() = session.strings

    val collections = EditorCollections(
        session.storage,
        session.scope,
        journalRoot,
        editStore::readState,
        { adjustmentHistory.session?.editGeneration(it) ?: 0L },
        ::captureActiveValidation,
        awaitPendingEdits = { mutable.first { !it.committingAdjustments } },
        canRelease = { photo ->
            mutable.value.photo?.file != photo.file &&
                !session.actions.ownsFailedImportRecovery(photo.file) &&
                mutable.value.operation != Operation.IMPORT &&
                !session.actions.hasActiveAdjustmentPreparations() &&
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
        if (!session.actions.adjustmentTargetIsCurrent(id, history)) {
            return current.saveError ?: "Apply, discard or skip this photo's draft"
        }
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
            check(session.actions.adjustmentTargetIsCurrent(photo.identity.value, history)) {
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
                session.actions.edit(mutable.value.edits, false, false)
                return completed(false)
            }
            mutable.value.draft?.let { draft ->
                if (draft.changed) {
                    session.actions.applyDraft(completed)
                    return
                }
                session.actions.discardDraft()
                completed(true)
                return
            }
            session.actions.retrySave(completed)
        } else {
            val loaded = history.loaded
            if (mutable.value.photo != null && loaded == null) {
                val unavailable = EditSaveResult(EditSaveState.FAILED, AdjustmentNotReadyException(), reading = true)
                mutable.value = mutable.value.copy(saveState = unavailable.state, saveError = unavailable.formatMessage(strings))
                completed(false)
                return
            }
            session.actions.clearPendingResetMigration(null, null)
            session.actions.cancelAdjustmentInteraction()
            mutable.value.draft?.let { session.actions.discardDraft() }
            val current = mutable.value
            val photo = current.photo
            val restored = if (photo == null) null else loaded?.settings ?: photo.defaultEditSettings()
            if (photo != null && restored != null && current.edits != restored) {
                session.incrementEditRevision()
                mutable.value = current.copy(
                    edits = restored,
                    draft = null,
                    saveState = EditSaveState.SAVED,
                    saveError = null,
                    error = null,
                    adjustmentRevision = current.adjustmentRevision + 1,
                )
                session.actions.includeIndependentRecipeLook(restored)
                session.actions.renderCommittedForNavigation()
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
        session.commitAdjustments({ collections.validateForCommit(target) }, false) { outcome ->
            outcome.fold({
                if (mutable.value.photo?.identity?.value == id) {
                    collections.opened(id)
                    completed(true)
                } else {
                    session.actions.importPhoto(Uri.parse(target.sourceUri), completed)
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
        session.actions.cancelAdjustmentInteraction()
        if (mutable.value.photo == null) {
            collections.returnToCollection()
            collections.refresh()
            completed(true)
        } else {
            session.actions.retrySave { accepted ->
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
        session.actions.capturePresetAdjustments(scope) { result ->
            result.fold(
                { completed(CollectionSynchronization(photo.identity.value, photo.name, it, targets)) },
                { collections.failure(it.message); completed(null) },
            )
        }
    }

    fun prepareExport(
        skipping: Set<String>,
        format: ExportFormat,
        longEdge: Int?,
        destination: Uri?,
        completed: (CollectionExportReview?) -> Unit,
        outputSharpening: com.rawlab.android.format.OutputSharpening = com.rawlab.android.format.OutputSharpening.OFF,
    ) = collections.prepare(skipping, format, longEdge, destination, completed, outputSharpening)

    fun freezeExport(review: CollectionExportReview, completed: (Boolean) -> Unit) {
        freezeAndAttachExport(review, false, { true }) { _, attached -> completed(attached) }
    }

    fun cancelExport() {
        exportGeneration = UUID.randomUUID()
        mutableExport.value = mutableExport.value.copy(preparing = false, review = null)
    }

    fun startExport(
        skipping: Set<String>,
        format: ExportFormat,
        longEdge: Int?,
        destination: Uri?,
        outputSharpening: com.rawlab.android.format.OutputSharpening = com.rawlab.android.format.OutputSharpening.OFF,
        completed: (Boolean) -> Unit = {},
    ) {
        if (mutableExport.value.preparing || mutableExport.value.freezing || state.value.busy) return
        cancelExport()
        val generation = exportGeneration
        val source = mutable.value.photo
        val sourceVersion = session.sourceRevision
        val revision = mutable.value.adjustmentRevision
        val selected = state.value.selected
        val current = {
            !session.disposed &&
                generation == exportGeneration &&
                session.sourceRevision == sourceVersion &&
                mutable.value.photo === source &&
                mutable.value.adjustmentRevision == revision &&
                state.value.selected == selected
        }
        mutableExport.value = CollectionExportFlow(preparing = true)
        collections.prepare(skipping, format, longEdge, destination, { review ->
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
        }, outputSharpening)
    }

    private fun freezeAndAttachExport(
        review: CollectionExportReview,
        automaticallyStart: Boolean,
        isCurrent: () -> Boolean,
        completed: (BatchJob?, Boolean) -> Unit,
    ) {
        if (session.actions.hasActiveOrPendingBatch()) {
            collections.failure("Close the current export task first")
            completed(null, false)
            return
        }
        collections.freeze(review, isCurrent) { job ->
            if (job == null) {
                completed(null, false)
            } else {
                session.actions.retainBatch(job)
                session.actions.releaseEditorRasterForBatch { released ->
                    if (released) session.actions.resumeAttachedBatch(job, automaticallyStart && isCurrent())
                    else collections.failure(mutable.value.error)
                    completed(job, released)
                }
            }
        }
    }
}
