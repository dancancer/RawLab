package com.rawlab.android.editor

import com.rawlab.android.editor.render.SerialWorkQueue
import com.rawlab.android.editor.storage.EditSaveResult
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.settings.AdjustmentOperationExpiredException
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.ProcessingMigrationReceipt
import com.rawlab.android.settings.ProcessingMigrationStatus
import java.util.UUID

internal class EditorProcessingMigrationStateHolder(
    private val session: EditorDocumentSession,
) {
    private val mutable get() = session.mutable
    private val storage get() = session.storage
    private val editStore get() = session.editStore
    private val adjustmentHistory get() = session.adjustmentHistory
    private val strings get() = session.strings
    private val mainDelivery get() = session.dependencies.mainDelivery
    private val processorFactory get() = session.dependencies.migrationProcessorFactory

    val queue = SerialWorkQueue(session.storageRelease.releaserFor("processingMigrationQueue"))
    @Volatile private var runId: UUID? = null
    @Volatile private var activeEngine: NativeProcessor? = null
    private var attemptSource: Long? = null
    private var deferredMigrationPreview = false
    internal var pendingResetMigrationClear: Pair<Long, EditSettings>? = null
        private set

    fun close() = queue.close()

    fun onSourceRevisionChanged() {
        cancel(skipCurrentSource = false)
        deferredMigrationPreview = false
        pendingResetMigrationClear = null
    }

    fun onEditRevisionChanged() {
        cancel(skipCurrentSource = false)
    }

    fun scheduleResetClear(source: Long, edits: EditSettings) {
        pendingResetMigrationClear = source to edits
    }

    fun clearPendingReset(source: Long? = null, synced: EditSettings? = null) {
        if (source == null || synced == null || pendingResetMigrationClear == (source to synced)) {
            pendingResetMigrationClear = null
        }
    }

    fun shouldClearOnPersist(source: Long, synced: EditSettings): Boolean =
        pendingResetMigrationClear == (source to synced)

    fun clearDeferredPreview() {
        deferredMigrationPreview = false
    }

    fun cancel(skipCurrentSource: Boolean = false) {
        if (skipCurrentSource) attemptSource = session.sourceRevision
        runId = null
        activeEngine?.cancelPreview()
        if (mutable.value.matchingProcessing) mutable.value = mutable.value.copy(matchingProcessing = false)
    }

    fun resumeDeferredPreviewIfReady() {
        val current = mutable.value
        if (!session.disposed && session.editorActive && deferredMigrationPreview && !current.committingAdjustments &&
            !current.rendering && current.operation == Operation.NONE && current.draft == null
        ) {
            session.actions.renderCommittedForNavigation()
        }
    }

    fun startIfNeeded() {
        val current = mutable.value
        val photo = current.photo ?: return
        val history = adjustmentHistory.snapshot()
        val expected = history.loaded ?: return
        val original = expected.settings ?: return
        val source = session.sourceRevision
        if (session.disposed || !session.editorActive || current.rendering || !current.exact || !current.controlsEnabled ||
            current.draft != null || current.saveState == EditSaveState.FAILED || current.edits.isHDREditing ||
            current.edits.recipeID != null || current.edits.processing.version >= 3 || history.interacting ||
            attemptSource == source
        ) return
        if (current.processingMigration?.shouldAttempt(original, original.processing.version) == false) return
        val validation = runCatching { history.committedValidation(photo, current.edits) }.getOrNull() ?: return
        val edit = session.editRevision
        val snapshot = current.edits
        val mode = session.gpuMode()
        val ticket = UUID.randomUUID()
        attemptSource = source
        runId = ticket
        mutable.value = current.copy(matchingProcessing = true)
        queue.submit({
            validation()
            if (runId != ticket) throw AdjustmentOperationExpiredException()
            processorFactory(mode, storage.lensDatabase()).use { engine ->
                val generation = engine.cancellationGeneration()
                activeEngine = engine
                try {
                    if (runId != ticket) throw AdjustmentOperationExpiredException()
                    val outcome = engine.migrateProcessing(photo.file, storage.lookPath(original), original, photo.inputKind, generation)
                    validation()
                    outcome
                } finally {
                    if (activeEngine === engine) activeEngine = null
                }
            }
        }) { result ->
            mainDelivery {
                if (runId == null && mutable.value.matchingProcessing) {
                    mutable.value = mutable.value.copy(matchingProcessing = false)
                }
                if (session.disposed || runId != ticket || session.sourceRevision != source || session.editRevision != edit ||
                    mutable.value.photo?.identity != photo.identity || mutable.value.edits != snapshot
                ) return@mainDelivery
                mutable.value = mutable.value.copy(matchingProcessing = false)
                val outcome = result.getOrNull() ?: return@mainDelivery
                val postHistory = adjustmentHistory.snapshot()
                if (mutable.value.committingAdjustments || postHistory.sourceToken != history.sourceToken || postHistory.interacting ||
                    mutable.value.draft != null || mutable.value.operation != Operation.NONE
                ) return@mainDelivery
                session.commitAdjustments({
                    if (runId != ticket || session.sourceRevision != source || session.editRevision != edit) {
                        throw AdjustmentOperationExpiredException()
                    }
                    validation()
                    val candidate = outcome.candidate(original)
                    val receipt = ProcessingMigrationReceipt(
                        if (candidate == null) ProcessingMigrationStatus.KEPT else ProcessingMigrationStatus.MIGRATED,
                        original,
                        outcome.quality,
                    )
                    val saved = editStore.commitProcessingMigration(expected, candidate, outcome.quality)
                    editStore.adjustmentSession?.adoptProcessingMigration(saved)
                    saved to receipt
                }, true) { committed ->
                    if (session.sourceRevision != source || session.editRevision != edit || mutable.value.edits != snapshot ||
                        mutable.value.photo?.identity != photo.identity || mutable.value.photo?.file != photo.file
                    ) return@commitAdjustments
                    committed.onSuccess { (saved, receipt) ->
                        // 成功返回即已落盘；取消可以阻止排队保存，不能丢弃已提交状态。
                        if (!adjustmentHistory.acceptSaved(photo, saved, history.sourceToken)) return@onSuccess
                        val migrated = receipt.status == ProcessingMigrationStatus.MIGRATED
                        session.incrementEditRevision()
                        if (migrated) {
                            session.actions.invalidateRender()
                            session.actions.cancelPreviewResize()
                            session.actions.clearDurableAndNavigationPreview()
                            deferredMigrationPreview = true
                        }
                        mutable.value = mutable.value.copy(
                            edits = if (migrated) saved.settings ?: snapshot else snapshot,
                            processingMigration = receipt,
                            rendering = if (migrated) false else mutable.value.rendering,
                            exact = if (migrated) false else mutable.value.exact,
                            previewResizePending = if (migrated) false else mutable.value.previewResizePending,
                            matchingProcessing = false,
                            saveState = EditSaveState.SAVED,
                            saveError = null,
                        )
                    }.onFailure { error ->
                        if (runId == ticket) {
                            mutable.value = mutable.value.copy(saveError = EditSaveResult(EditSaveState.FAILED, error).formatMessage(strings))
                        }
                    }
                }
            }
        }
    }

    fun rollback() {
        val current = mutable.value
        val photo = current.photo ?: return
        val history = adjustmentHistory.snapshot()
        val expected = history.loaded ?: return
        if (current.processingMigration?.status != ProcessingMigrationStatus.MIGRATED ||
            !current.controlsEnabled || current.draft != null || history.interacting
        ) return
        val validation = runCatching { history.committedValidation(photo, current.edits) }.getOrNull() ?: return
        cancel()
        val source = session.sourceRevision
        val edit = session.editRevision
        session.commitAdjustments({
            if (session.sourceRevision != source || session.editRevision != edit) throw AdjustmentOperationExpiredException()
            validation()
            val saved = editStore.rollbackProcessingMigration(expected)
            editStore.adjustmentSession?.adoptProcessingMigration(saved)
            saved to editStore.processingMigration(photo.identity)
        }, false) { result ->
            if (session.sourceRevision != source || mutable.value.photo?.identity != photo.identity) return@commitAdjustments
            result.onSuccess { (saved, receipt) ->
                if (!adjustmentHistory.acceptSaved(photo, saved, history.sourceToken)) return@onSuccess
                session.incrementEditRevision()
                mutable.value = mutable.value.copy(
                    edits = requireNotNull(saved.settings),
                    processingMigration = receipt,
                    saveState = EditSaveState.SAVED,
                    saveError = null,
                )
                session.actions.includeIndependentRecipeLook(requireNotNull(saved.settings))
                session.actions.renderCommittedForNavigation()
            }.onFailure { error ->
                mutable.value = mutable.value.copy(saveError = EditSaveResult(EditSaveState.FAILED, error).formatMessage(strings))
            }
        }
    }
}
