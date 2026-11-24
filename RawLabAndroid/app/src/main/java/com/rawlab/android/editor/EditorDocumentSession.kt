package com.rawlab.android.editor

import android.net.Uri
import com.rawlab.android.R
import com.rawlab.android.adjustments.AdjustmentFailure
import com.rawlab.android.adjustments.AdjustmentPayload
import com.rawlab.android.adjustments.AdjustmentScope
import com.rawlab.android.adjustments.AdjustmentTransferException
import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.BatchTarget
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.render.SerialWorkQueue
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.editor.storage.EditSaveResult
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.File
import java.util.UUID

internal sealed interface EditorSessionEvent {
    data class SourceChanged(val revision: Long) : EditorSessionEvent
    data class EditRevisionChanged(val revision: Long) : EditorSessionEvent
    data class RenderSubmitted(val revision: Long, val work: Work) : EditorSessionEvent
    data class RenderResultReceived(val revision: Long, val result: Result<WorkResult>) : EditorSessionEvent
    data class PreviewAccepted(
        val request: Work.Preview,
        val edits: EditSettings,
        val sourceRevision: Long,
        val renderRevision: Long,
    ) : EditorSessionEvent
    data class DetailAccepted(val result: WorkResult.DetailPreview) : EditorSessionEvent
    data class ExportCompleted(val late: Boolean) : EditorSessionEvent
    data class BackgroundRequested(val active: Boolean) : EditorSessionEvent
    data object FadeSaveNoticeRequested : EditorSessionEvent
}

internal class SessionActions {
    var submitRender: (Work) -> Long = { 0L }
    var invalidateRender: () -> Long = { 0L }
    var performAfterPendingRender: (() -> Unit) -> Unit = { it() }
    var scheduleDetailIfNeeded: () -> Unit = {}
    var handleDetailAccepted: (WorkResult.DetailPreview) -> Unit = {}
    var edit: (EditSettings, Boolean, Boolean) -> Unit = { _, _, _ -> }
    var persist: (ImportedPhoto, EditSettings, Boolean, (EditSaveResult) -> Unit) -> Unit = { _, _, _, _ -> }
    var renderDraft: (Boolean) -> Unit = {}
    var renderCommittedForNavigation: () -> Unit = {}
    var updatePreviewSize: (Int) -> Unit = {}
    var cancelPreviewResize: () -> Unit = {}
    var clearDurablePreview: () -> Unit = {}
    var clearDurableAndNavigationPreview: () -> Unit = {}
    var fitGeometryDraft: (AdjustmentDraft, PreviewPair?) -> AdjustmentDraft = { d, _ -> d }
    var consumeDurableMatch: (ImportedPhoto, Long, Long, EditSettings) -> Boolean = { _, _, _, _ -> false }
    var consumeNavigationMatch: (ImportedPhoto, Long, Long, EditSettings) -> Boolean = { _, _, _, _ -> false }
    var restoreEditorDraft: () -> Unit = {}
    var resetDraftForImport: () -> Unit = {}
    var requestedPreviewLongEdge: () -> Int = { 1600 }
    var draftRevision: () -> Long = { 0L }
    var incrementDraftRevision: () -> Unit = {}
    var hasPreviewResizePending: () -> Boolean = { false }
    var interactiveEdge: (Int, Boolean) -> Int = { edge, _ -> edge }
    var changeDraft: (EditSettings, Boolean) -> Unit = { _, _ -> }
    var failedDraftSave: () -> Boolean = { false }
    var applyDraft: ((Boolean) -> Unit) -> Unit = { it(false) }
    var discardDraft: () -> Unit = {}
    var retrySave: ((Boolean) -> Unit) -> Unit = { it(false) }
    var preserveEditorDraft: () -> Unit = {}
    var includeIndependentRecipeLook: (EditSettings) -> Unit = {}
    var updateRecentLooks: (String?) -> Unit = {}
    var clearPendingResetMigration: (Long?, EditSettings?) -> Unit = { _, _ -> }
    var scheduleResetClear: (Long, EditSettings) -> Unit = { _, _ -> }
    var shouldClearMigrationOnPersist: (Long, EditSettings) -> Boolean = { _, _ -> false }
    var clearDeferredMigrationPreview: () -> Unit = {}
    var startMigrationIfNeeded: () -> Unit = {}
    var cancelMigration: (Boolean) -> Unit = {}
    var resumeDeferredMigrationPreviewIfReady: () -> Unit = {}
    var onSourceRevisionChanged: () -> Unit = {}
    var onEditRevisionChanged: () -> Unit = {}
    var cancelHslTarget: () -> Unit = {}
    var clearHslTarget: (Boolean) -> Unit = {}
    var recordHslAcceptedPreview: (Work.Preview, EditSettings, Long, Long) -> Unit = { _, _, _, _ -> }
    var acceptedHslPreviewRequest: () -> Work.Preview? = { null }
    var isHslWaiting: () -> Boolean = { false }
    var acceptHslProbe: (WorkResult.HslProbe) -> Unit = {}
    var cancelWbProbe: () -> Unit = {}
    var clearWbProbe: (Boolean) -> Unit = {}
    var recordWbAcceptedPreview: (Work.Preview, EditSettings, Long, Long) -> Unit = { _, _, _, _ -> }
    var isWbWaiting: () -> Boolean = { false }
    var acceptWbProbe: (WorkResult.WbProbe) -> Unit = {}
    var isEyedropperWaiting: () -> Boolean = { isHslWaiting() || isWbWaiting() }
    var cancelQuickPreset: () -> Unit = {}
    var closeQuickPresets: () -> Unit = {}
    var closeAdjustmentOperation: () -> Unit = {}
    var cancelAdjustmentInteraction: () -> Unit = {}
    var finishAdjustmentClose: () -> Unit = {}
    var isQuickPresetPreparing: () -> Boolean = { false }
    var hasActiveAdjustmentPreparations: () -> Boolean = { false }
    var adjustmentTargetIsCurrent: (String, EditorAdjustmentHistory.Snapshot) -> Boolean = { _, _ -> true }
    var collectionPhoto: (String) -> ImportedPhoto? = { null }
    var collectionTargets: () -> List<BatchTarget> = { emptyList() }
    var validateCollectionTarget: (BatchTarget) -> Unit = {}
    var onCollectionSynchronized: (UUID, Boolean) -> Unit = { _, _ -> }
    var collectionOpened: (String) -> Unit = {}
    var collectionOwns: (File) -> Boolean = { false }
    var releaseDeferredCollections: () -> Unit = {}
    var cancelCollectionExport: () -> Unit = {}
    var ownsFailedImportRecovery: (File) -> Boolean = { false }
    var hasActiveOrPendingBatch: () -> Boolean = { false }
    var retainBatch: (BatchJob) -> Unit = {}
    var resumeAttachedBatch: (BatchJob, Boolean) -> Unit = { _, _ -> }
    var releaseEditorRasterForBatch: ((Boolean) -> Unit) -> Unit = { it(false) }
    var cancelBatchForBackground: () -> Unit = {}
    var importPhoto: (Uri?, (Boolean) -> Unit) -> Unit = { _, done -> done(false) }
    var capturePresetAdjustments: (AdjustmentScope, (Result<AdjustmentPayload>) -> Unit) -> Unit = { _, _ -> }
    var isCameraHDRPreflightPending: () -> Boolean = { false }
    var onRenderSubmittedForHdr: (Work) -> Unit = {}
    var onRenderResultForHdr: () -> Unit = {}
    var onCameraHDRPreflight: (WorkResult.CameraHDRPreflight) -> Unit = {}
    var handleX3fFailure: (WorkResult.X3fImportFailure) -> Unit = {}
    var handleUnusableFailure: (WorkResult.UnusableEditImportFailure) -> Unit = {}
    var handleMissingLook: (WorkResult.MissingLook) -> Unit = {}
    var completePendingImport: (PhotoIdentity) -> Boolean = { false }
    var releasePreviousPhoto: (ImportedPhoto) -> Unit = {}
    var clearPendingImport: () -> Unit = {}
    var retryX3fIfPresent: () -> Boolean = { false }
    var onExportCompleted: () -> Unit = {}
    var onLateExportCompleted: (WorkResult) -> Unit = {}
    var fadeSaveNotice: () -> Unit = {}
    var setEditorActive: (Boolean) -> Unit = {}
}

internal class EditorDocumentSession(
    val dependencies: EditorDependencies,
    val scope: CoroutineScope,
    val onSourceRevisionSynced: (Long) -> Unit = {},
    val onCurrentRevisionSynced: (Long) -> Unit = {},
) {
    val strings = dependencies.strings
    val storage = dependencies.storage
    val editStore = dependencies.editStore
    val draftStore = dependencies.draftStore
    val previewCache = dependencies.previewCache
    val adjustmentHistory = EditorAdjustmentHistory(editStore, dependencies.sourceValidator)

    val mutable = MutableStateFlow(EditorState())
    val state: StateFlow<EditorState> = mutable.asStateFlow()

    private val mutableEvents = MutableSharedFlow<EditorSessionEvent>(extraBufferCapacity = 64)
    val events: SharedFlow<EditorSessionEvent> = mutableEvents.asSharedFlow()

    val actions = SessionActions()

    val storageRelease = StorageReleaseManifest(
        setOf("renderQueue", "lookQueue", "adjustmentQueue", "adjustmentPreparationQueue", "processingMigrationQueue", "collections"),
        storage::close,
    )
    val adjustmentQueue = SerialWorkQueue(storageRelease.releaserFor("adjustmentQueue"))

    @Volatile var disposed: Boolean = false
    @Volatile var sourceRevision: Long = 0L
        private set
    @Volatile var editRevision: Long = 0L
        private set
    var currentRevision: Long = 0L
        private set
    var activationRevision: Long = 0L
    var editorActive: Boolean = true
    var previewLongEdge: Int = 1600

    fun emit(event: EditorSessionEvent) {
        mutableEvents.tryEmit(event)
    }

    fun incrementSourceRevision(): Long {
        val next = sourceRevision + 1L
        sourceRevision = next
        onSourceRevisionSynced(next)
        actions.onSourceRevisionChanged()
        emit(EditorSessionEvent.SourceChanged(next))
        return next
    }

    fun incrementEditRevision(): Long {
        val next = editRevision + 1L
        editRevision = next
        actions.onEditRevisionChanged()
        emit(EditorSessionEvent.EditRevisionChanged(next))
        return next
    }

    fun updateCurrentRevision(revision: Long) {
        currentRevision = revision
        onCurrentRevisionSynced(revision)
    }

    fun gpuMode(): Int = if (mutable.value.gpuEnabled) NativeProcessor.AUTO else NativeProcessor.CPU

    fun failure(error: Throwable): String {
        com.rawlab.android.diagnostics.DiagnosticRegistry.peek()?.recordError(
            operation = "editor",
            stage = "renderOrExportFailure",
            error = error,
        )
        return when {
            error is OutOfMemoryError -> strings.text(R.string.memory_error)
            error is com.rawlab.android.engine.NativeProcessingException && error.isForceGpuUnsupported ->
                strings.text(R.string.force_gpu_unsupported)
            else -> strings.text(R.string.process_error) + "\n" + (error.message ?: error.javaClass.simpleName)
        }
    }

    // 提交期单槽契约（k161 定性，勿改为"completed 后再解锁"或计数队列）：
    fun <T> commitAdjustments(
        work: () -> T,
        publishBeforeUnlock: Boolean = false,
        completed: (Result<T>) -> Unit,
    ) {
        if (disposed || mutable.value.committingAdjustments) {
            completed(Result.failure(AdjustmentTransferException(AdjustmentFailure.DRAFT)))
            return
        }
        mutable.value = mutable.value.copy(committingAdjustments = true)
        adjustmentQueue.submit(work) { result ->
            scope.launch {
                if (!disposed) {
                    if (!publishBeforeUnlock) mutable.value = mutable.value.copy(committingAdjustments = false)
                    try {
                        completed(result)
                    } finally {
                        if (publishBeforeUnlock) {
                            mutable.value = mutable.value.copy(committingAdjustments = false)
                            actions.resumeDeferredMigrationPreviewIfReady()
                        }
                        actions.finishAdjustmentClose()
                        actions.releaseDeferredCollections()
                    }
                }
            }
        }
    }
}
