package com.rawlab.android.editor

import com.rawlab.android.editor.render.SerialWorkQueue
import com.rawlab.android.editor.storage.EditSaveResult
import com.rawlab.android.editor.storage.EditorEditStore
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.AdjustmentOperationExpiredException
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.ProcessingMigrationReceipt
import com.rawlab.android.settings.ProcessingMigrationStatus
import kotlinx.coroutines.flow.MutableStateFlow
import java.io.File
import java.util.UUID

internal class EditorProcessingMigrationStateHolder(
    private val mutable: MutableStateFlow<EditorState>,
    private val storage: PhotoStorage,
    private val editStore: EditorEditStore,
    private val adjustmentHistory: EditorAdjustmentHistory,
    private val strings: EditorStrings,
    private val mainDelivery: (() -> Unit) -> Unit,
    private val processorFactory: (Int, File?) -> NativeProcessor,
    onQueueReleased: () -> Unit,
    private val isDisposed: () -> Boolean,
    private val isEditorActive: () -> Boolean,
    private val currentSourceRevision: () -> Long,
    private val currentEditRevision: () -> Long,
    private val gpuMode: () -> Int,
    private val onCommitAdjustments: (work: () -> Any?, publishBeforeUnlock: Boolean, completed: (Result<Any?>) -> Unit) -> Unit,
    private val onIncrementEditRevision: () -> Unit,
    private val onInvalidateRender: () -> Unit,
    private val onCancelPreviewResize: () -> Unit,
    private val onClearDurableAndNavigationPreview: () -> Unit,
    private val onIncludeIndependentRecipeLook: (EditSettings) -> Unit,
    private val onRenderCommittedForNavigation: () -> Unit,
) {
    val queue = SerialWorkQueue(onQueueReleased)
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
        if (skipCurrentSource) attemptSource = currentSourceRevision()
        runId = null
        activeEngine?.cancelPreview()
        if (mutable.value.matchingProcessing) mutable.value = mutable.value.copy(matchingProcessing = false)
    }

    fun resumeDeferredPreviewIfReady() {
        val current = mutable.value
        if (!isDisposed() && isEditorActive() && deferredMigrationPreview && !current.committingAdjustments &&
            !current.rendering && current.operation == Operation.NONE && current.draft == null
        ) {
            onRenderCommittedForNavigation()
        }
    }

    fun startIfNeeded() {
        val current = mutable.value
        val photo = current.photo ?: return
        val history = adjustmentHistory.snapshot()
        val expected = history.loaded ?: return
        val original = expected.settings ?: return
        val source = currentSourceRevision()
        if (isDisposed() || !isEditorActive() || current.rendering || !current.exact || !current.controlsEnabled ||
            current.draft != null || current.saveState == EditSaveState.FAILED || current.edits.isHDREditing ||
            current.edits.recipeID != null || current.edits.processing.version >= 3 || history.interacting ||
            attemptSource == source
        ) return
        if (current.processingMigration?.shouldAttempt(original, original.processing.version) == false) return
        val validation = runCatching { history.committedValidation(photo, current.edits) }.getOrNull() ?: return
        val edit = currentEditRevision()
        val snapshot = current.edits
        val mode = gpuMode()
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
                if (isDisposed() || runId != ticket || currentSourceRevision() != source || currentEditRevision() != edit ||
                    mutable.value.photo?.identity != photo.identity || mutable.value.edits != snapshot
                ) return@mainDelivery
                mutable.value = mutable.value.copy(matchingProcessing = false)
                val outcome = result.getOrNull() ?: return@mainDelivery
                val postHistory = adjustmentHistory.snapshot()
                if (mutable.value.committingAdjustments || postHistory.sourceToken != history.sourceToken || postHistory.interacting ||
                    mutable.value.draft != null || mutable.value.operation != Operation.NONE
                ) return@mainDelivery
                onCommitAdjustments({
                    if (runId != ticket || currentSourceRevision() != source || currentEditRevision() != edit) {
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
                    if (currentSourceRevision() != source || currentEditRevision() != edit || mutable.value.edits != snapshot ||
                        mutable.value.photo?.identity != photo.identity || mutable.value.photo?.file != photo.file
                    ) return@onCommitAdjustments
                    committed.onSuccess { pair ->
                        @Suppress("UNCHECKED_CAST")
                        val outcomePair = pair as Pair<com.rawlab.android.settings.PhotoEditState, ProcessingMigrationReceipt>
                        val (saved, receipt) = outcomePair
                        // 成功返回即已落盘；取消可以阻止排队保存，不能丢弃已提交状态。
                        if (!adjustmentHistory.acceptSaved(photo, saved, history.sourceToken)) return@onSuccess
                        val migrated = receipt.status == ProcessingMigrationStatus.MIGRATED
                        onIncrementEditRevision()
                        if (migrated) {
                            onInvalidateRender()
                            onCancelPreviewResize()
                            onClearDurableAndNavigationPreview()
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
        val source = currentSourceRevision()
        val edit = currentEditRevision()
        onCommitAdjustments({
            if (currentSourceRevision() != source || currentEditRevision() != edit) throw AdjustmentOperationExpiredException()
            validation()
            val saved = editStore.rollbackProcessingMigration(expected)
            editStore.adjustmentSession?.adoptProcessingMigration(saved)
            saved to editStore.processingMigration(photo.identity)
        }, false) { result ->
            if (currentSourceRevision() != source || mutable.value.photo?.identity != photo.identity) return@onCommitAdjustments
            result.onSuccess { pair ->
                @Suppress("UNCHECKED_CAST")
                val outcomePair = pair as Pair<com.rawlab.android.settings.PhotoEditState, ProcessingMigrationReceipt?>
                val (saved, receipt) = outcomePair
                if (!adjustmentHistory.acceptSaved(photo, saved, history.sourceToken)) return@onSuccess
                onIncrementEditRevision()
                mutable.value = mutable.value.copy(
                    edits = requireNotNull(saved.settings),
                    processingMigration = receipt,
                    saveState = EditSaveState.SAVED,
                    saveError = null,
                )
                onIncludeIndependentRecipeLook(requireNotNull(saved.settings))
                onRenderCommittedForNavigation()
            }.onFailure { error ->
                mutable.value = mutable.value.copy(saveError = EditSaveResult(EditSaveState.FAILED, error).formatMessage(strings))
            }
        }
    }
}
