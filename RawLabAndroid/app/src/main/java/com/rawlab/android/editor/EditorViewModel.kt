package com.rawlab.android.editor

import android.app.Application
import android.content.ComponentCallbacks2
import android.content.res.Configuration
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.rawlab.android.adjustments.AdjustmentHistoryTransaction
import com.rawlab.android.adjustments.AdjustmentOutcome
import com.rawlab.android.adjustments.AdjustmentPayload
import com.rawlab.android.adjustments.AdjustmentScope
import com.rawlab.android.adjustments.PreparedAdjustmentTransfer
import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.CollectionExportReview
import com.rawlab.android.editor.canvas.ViewportRoiRequest
import com.rawlab.android.editor.render.EditorRenderer
import com.rawlab.android.editor.render.ViewportRenderEngine
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.OutputSharpening
import com.rawlab.android.geometry.GeometryRatio
import com.rawlab.android.looks.DcpImportChoices
import com.rawlab.android.looks.LUTCompatibility
import com.rawlab.android.looks.UnreadableLook
import com.rawlab.android.presets.AdjustmentPreset
import com.rawlab.android.presets.AdjustmentPresetStore
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.HDRCameraDevelopmentSettings
import com.rawlab.android.settings.ToneCurveChannel
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import java.io.File
import java.util.UUID

class EditorViewModel internal constructor(
    private val appContext: Application,
    private val dependencies: EditorDependencies,
) : AndroidViewModel(appContext) {

    @JvmOverloads
    constructor(
        application: Application,
        editStoreFactory: (File) -> EditStore = { EditStore(it) },
        batchProcessorFactory: (Int, File?) -> NativeProcessor = { mode, database -> NativeProcessor(mode, database) },
    ) : this(application, EditorDependencies.production(application, editStoreFactory, batchProcessorFactory))

    private val scope = dependencies.scope ?: viewModelScope
    val storage = dependencies.storage
    private val renderer: EditorRenderer? = dependencies.renderer
    private val previewCache = dependencies.previewCache
    private val photoPreviewOwner = UUID.randomUUID().toString()
    val presetStore: AdjustmentPresetStore by lazy { dependencies.presetStoreFactory() }

    @Volatile private var sourceRevision = 0L
    private var currentRevision = 0L

    internal val session = EditorDocumentSession(
        dependencies = dependencies,
        scope = scope,
        onSourceRevisionSynced = { sourceRevision = it },
        onCurrentRevisionSynced = { currentRevision = it },
    )
    private val mutable = session.mutable
    val state = session.state
    internal val storageRelease = session.storageRelease
    private val adjustmentQueue = session.adjustmentQueue
    private val adjustmentHistory = session.adjustmentHistory

    internal val viewport = ViewportRenderEngine(
        session = session,
        onPreviewAccepted = { result -> previewCoordinator.accept(result) },
        onLateExportCompleted = { result -> exportHolder.onLateExportCompleted(result) },
        onRenderSubmittedHook = { work ->
            if (work !is com.rawlab.android.editor.render.Work.HslProbe && hslHolder.isWaiting) hslHolder.clear()
            if (work !is com.rawlab.android.editor.render.Work.WbProbe && wbHolder.isWaiting) wbHolder.clear()
            hdrHolder.onRenderSubmitted(work)
        },
    )

    private val systemPhotoHolder: EditorSystemPhotoStateHolder = EditorSystemPhotoStateHolder(session)
    private val lookHolder: EditorLookStateHolder = EditorLookStateHolder(session)
    private val hslHolder: EditorHslEyedropperStateHolder = EditorHslEyedropperStateHolder(session)
    private val wbHolder: EditorWbEyedropperStateHolder = EditorWbEyedropperStateHolder(session)
    private val hdrHolder: EditorHdrStateHolder = EditorHdrStateHolder(session)
    private val exportHolder: EditorExportStateHolder = EditorExportStateHolder(session)
    private val processingMigrationHolder: EditorProcessingMigrationStateHolder = EditorProcessingMigrationStateHolder(session)
    private val adjustmentTransferHolder: EditorAdjustmentTransferStateHolder = EditorAdjustmentTransferStateHolder(appContext, session)
    private val batchHolder: EditorBatchStateHolder = EditorBatchStateHolder(appContext, session)
    private val collectionHolder: EditorCollectionStateHolder = EditorCollectionStateHolder(session, File(appContext.filesDir, "RawLab/BatchJobs"))
    private val importRecoveryHolder: EditorImportRecoveryStateHolder = EditorImportRecoveryStateHolder(session)
    private val draftHolder: EditorDraftStateHolder = EditorDraftStateHolder(session)
    private val previewCoordinator: EditorPreviewCoordinator = EditorPreviewCoordinator(session, viewport)

    private val memoryCallbacks = object : ComponentCallbacks2 {
        override fun onTrimMemory(level: Int) = viewport.reclaimMemory(level, keepLastRequest = true)
        override fun onConfigurationChanged(newConfig: Configuration) = Unit
        @Suppress("OVERRIDE_DEPRECATION", "DEPRECATION")
        override fun onLowMemory() = viewport.reclaimMemory(ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW, keepLastRequest = true)
    }

    val adjustmentTransactions get() = adjustmentHistory.session?.transactions.orEmpty()
    val canUndoAdjustment get() = mutable.value.photo?.identity?.let { adjustmentHistory.session?.canUndoPhoto(it) } == true
    val canRedoAdjustment get() = mutable.value.photo?.identity?.let { adjustmentHistory.session?.canRedoPhoto(it) } == true
    val adjustmentClipboard get() = adjustmentHistory.session?.clipboard
    val adjustmentClipboardSourceName get() = adjustmentTransferHolder.clipboardSourceName
    val adjustmentTransfer = adjustmentTransferHolder.transfer
    val quickPreset = adjustmentTransferHolder.quickPreset
    val collection = collectionHolder.state
    val systemPhotoRequests = systemPhotoHolder.requests
    val batch = batchHolder.active
    val pendingBatch = batchHolder.pending
    val collectionExport = collectionHolder.export
    val hslTarget = hslHolder.state
    val wbProbe = wbHolder.state

    // Internal test seams for androidTest and JVM unit tests.
    internal val lookQueue get() = lookHolder.queue
    internal val adjustmentPreparationQueue get() = adjustmentTransferHolder.preparationQueue
    internal val adjustmentOwnedFiles get() = adjustmentTransferHolder.ownedFiles
    internal val collections get() = collectionHolder.collections
    internal val processingMigrationQueue get() = processingMigrationHolder.queue
    internal val pendingResetMigrationClear get() = processingMigrationHolder.pendingResetMigrationClear
    internal var prepareAdjustmentOperation
        get() = adjustmentTransferHolder.prepareAdjustmentOperation
        set(value) { adjustmentTransferHolder.prepareAdjustmentOperation = value }
    internal var releaseEditorRasterOperation
        get() = batchHolder.releaseEditorRasterOperation
        set(value) { batchHolder.releaseEditorRasterOperation = value }

    init {
        wireSessionActions()
        appContext.registerComponentCallbacks(memoryCallbacks)
        scope.launch {
            state.map { it.rendering || it.operation != Operation.NONE || it.committingAdjustments }
                .distinctUntilChanged().collect { previewCache.setForegroundBusy(photoPreviewOwner, it) }
        }
        session.editStore.initialResult.let {
            mutable.value = mutable.value.copy(saveState = it.state, saveError = it.formatMessage(session.strings))
        }
        dependencies.renderGateway.setExportProgressListener { work, fraction ->
            dependencies.mainDelivery {
                val current = mutable.value
                if (!session.disposed && current.operation == Operation.EXPORT && work === viewport.latestRender) {
                    mutable.value = current.copy(exportProgress = fraction.coerceIn(0f, 1f))
                }
            }
        }
        lookHolder.loadInitial()
        batchHolder.refreshPending()
        systemPhotoHolder.restorePending()
    }

    private fun wireSessionActions() = session.actions.apply {
        submitRender = viewport::submitPreview
        invalidateRender = viewport::invalidate
        performAfterPendingRender = viewport::performAfterPending
        scheduleDetailIfNeeded = viewport::scheduleDetailIfNeeded
        handleDetailAccepted = viewport::handleDetailAccepted
        edit = previewCoordinator::edit
        persist = previewCoordinator::persist
        renderDraft = draftHolder::renderDraft
        renderCommittedForNavigation = draftHolder::renderCommittedForNavigation
        updatePreviewSize = draftHolder::updatePreviewSize
        cancelPreviewResize = draftHolder::cancelResize
        clearDurablePreview = draftHolder::clearDurablePreview
        clearDurableAndNavigationPreview = draftHolder::clearDurableAndNavigationPreview
        fitGeometryDraft = draftHolder::fitGeometryDraft
        consumeDurableMatch = draftHolder::consumeDurableMatch
        consumeNavigationMatch = draftHolder::consumeNavigationMatch
        restoreEditorDraft = draftHolder::restoreEditorDraft
        resetDraftForImport = draftHolder::resetForImport
        requestedPreviewLongEdge = draftHolder::requestedPreviewLongEdge
        draftRevision = draftHolder::draftRevision
        incrementDraftRevision = draftHolder::incrementDraftRevision
        hasPreviewResizePending = draftHolder::hasResizePending
        interactiveEdge = draftHolder::interactiveEdge
        changeDraft = draftHolder::changeDraft
        failedDraftSave = draftHolder::failedDraftSave
        applyDraft = draftHolder::applyDraft
        discardDraft = draftHolder::discardDraft
        retrySave = previewCoordinator::retrySave
        preserveEditorDraft = draftHolder::preserveEditorDraft
        includeIndependentRecipeLook = lookHolder::includeIndependentRecipeLook
        updateRecentLooks = lookHolder::updateRecentLooks
        clearPendingResetMigration = processingMigrationHolder::clearPendingReset
        scheduleResetClear = processingMigrationHolder::scheduleResetClear
        shouldClearMigrationOnPersist = processingMigrationHolder::shouldClearOnPersist
        clearDeferredMigrationPreview = processingMigrationHolder::clearDeferredPreview
        startMigrationIfNeeded = processingMigrationHolder::startIfNeeded
        cancelMigration = processingMigrationHolder::cancel
        resumeDeferredMigrationPreviewIfReady = processingMigrationHolder::resumeDeferredPreviewIfReady
        onSourceRevisionChanged = processingMigrationHolder::onSourceRevisionChanged
        onEditRevisionChanged = processingMigrationHolder::onEditRevisionChanged
        cancelHslTarget = hslHolder::cancel
        clearHslTarget = hslHolder::clear
        recordHslAcceptedPreview = hslHolder::recordAcceptedPreview
        acceptedHslPreviewRequest = hslHolder::acceptedPreviewRequest
        isHslWaiting = { hslHolder.isWaiting }
        acceptHslProbe = hslHolder::accept
        cancelWbProbe = wbHolder::cancel
        clearWbProbe = wbHolder::clear
        recordWbAcceptedPreview = wbHolder::recordAcceptedPreview
        isWbWaiting = { wbHolder.isWaiting }
        acceptWbProbe = wbHolder::accept
        cancelQuickPreset = adjustmentTransferHolder::cancelQuickPreset
        closeQuickPresets = adjustmentTransferHolder::closeQuickPresets
        closeAdjustmentOperation = adjustmentTransferHolder::closeOperation
        cancelAdjustmentInteraction = adjustmentTransferHolder::cancelInteraction
        finishAdjustmentClose = adjustmentTransferHolder::finishClose
        isQuickPresetPreparing = { quickPreset.value.phase == QuickPresetPhase.PREPARING }
        hasActiveAdjustmentPreparations = adjustmentTransferHolder::hasActivePreparations
        adjustmentTargetIsCurrent = adjustmentTransferHolder::targetIsCurrent
        collectionPhoto = collectionHolder::photo
        collectionTargets = { collectionHolder.state.value.photos }
        validateCollectionTarget = collectionHolder::validate
        onCollectionSynchronized = collectionHolder::synchronized
        collectionOpened = collectionHolder::opened
        collectionOwns = collectionHolder::owns
        releaseDeferredCollections = collectionHolder::releaseDeferred
        cancelCollectionExport = collectionHolder::cancelExport
        ownsFailedImportRecovery = importRecoveryHolder::ownsFailedRecovery
        hasActiveOrPendingBatch = batchHolder::hasActiveOrPending
        retainBatch = batchHolder::retain
        resumeAttachedBatch = batchHolder::resumeAttached
        releaseEditorRasterForBatch = batchHolder::releaseEditorRasterForBatch
        cancelBatchForBackground = batchHolder::cancelForBackground
        importPhoto = importRecoveryHolder::importPhoto
        capturePresetAdjustments = adjustmentTransferHolder::capturePreset
        isCameraHDRPreflightPending = { hdrHolder.cameraHDRPreflightPending }
        onRenderSubmittedForHdr = hdrHolder::onRenderSubmitted
        onRenderResultForHdr = hdrHolder::onRenderResult
        onCameraHDRPreflight = hdrHolder::onCameraHDRPreflight
        handleX3fFailure = importRecoveryHolder::handleX3fFailure
        handleUnusableFailure = importRecoveryHolder::handleUnusableFailure
        handleMissingLook = importRecoveryHolder::handleMissingLook
        completePendingImport = importRecoveryHolder::completePendingImport
        releasePreviousPhoto = importRecoveryHolder::releasePreviousPhoto
        clearPendingImport = importRecoveryHolder::clearPendingImport
        retryX3fIfPresent = importRecoveryHolder::retryX3fIfPresent
        onExportCompleted = exportHolder::onExportCompleted
        onLateExportCompleted = exportHolder::onLateExportCompleted
        fadeSaveNotice = previewCoordinator::fadeSaveNotice
        setEditorActive = ::setEditorActive
    }

    fun setDetailNeedsBefore(needed: Boolean) = viewport.setCompareBefore(needed)
    fun updateDetailRequest(request: ViewportRoiRequest?) = viewport.updateViewport(request)

    fun receiveSystemPhotos(uris: List<Uri>, requestID: String = UUID.randomUUID().toString()) = systemPhotoHolder.receive(uris, requestID)
    fun consumeSystemPhotoRequest(request: SystemPhotoOpenRequest) = systemPhotoHolder.consume(request)
    fun setHslTargetEnabled(enabled: Boolean) {
        if (enabled) wbHolder.setEnabled(false)
        hslHolder.setEnabled(enabled)
    }
    fun setHslTargetAxis(axis: Int) = hslHolder.setAxis(axis)
    fun setCurveTargetChannel(channel: ToneCurveChannel) = hslHolder.setCurveChannel(channel)
    fun beginHslTarget(x: Float, y: Float, keyDelta: Float? = null) = hslHolder.begin(x, y, keyDelta)
    fun moveHslTarget(delta: Float) = hslHolder.move(delta)
    fun endHslTarget() = hslHolder.end()
    fun cancelHslTarget() = hslHolder.cancel()
    fun rejectHslTarget() = hslHolder.reject()
    fun keyHslTarget(delta: Float) = hslHolder.key(delta)

    fun setWbProbeEnabled(enabled: Boolean) {
        if (enabled) hslHolder.setEnabled(false)
        wbHolder.setEnabled(enabled)
    }
    fun beginWbProbe(x: Float, y: Float) = wbHolder.begin(x, y)
    fun cancelWbProbe() = wbHolder.cancel()
    fun rejectWbProbe() = wbHolder.reject()

    fun importPhoto(uri: Uri?) = importRecoveryHolder.importPhoto(uri)
    fun importPhoto(uri: Uri?, completed: (Boolean) -> Unit) = importRecoveryHolder.importPhoto(uri, completed)
    fun dismissUnusableImportRecovery() = importRecoveryHolder.dismissUnusableImportRecovery()
    fun resetUnusableImportRecord() = importRecoveryHolder.resetUnusableImportRecord()

    fun importLook(uri: Uri?) = lookHolder.importLook(uri)
    fun importLooks(uris: List<Uri>) = lookHolder.importLooks(uris)
    fun dismissLookImportReport() = lookHolder.dismissLookImportReport()
    fun resolveLookCompatibility(draft: LUTCompatibility?) = lookHolder.resolveLookCompatibility(draft)
    fun resolveDcpImport(choices: DcpImportChoices?) = lookHolder.resolveDcpImport(choices)
    fun renameLook(id: String, name: String) = lookHolder.renameLook(id, name)
    fun deleteLook(id: String) = lookHolder.deleteLook(id)
    fun deleteUnreadableLook(entry: UnreadableLook) = lookHolder.deleteUnreadableLook(entry)
    fun selectFilm(id: String): Boolean = lookHolder.selectFilm(id)

    fun beginHDRLookImport(): Boolean = hdrHolder.beginHDRLookImport()
    fun finishHDRLookImport(uri: Uri?) = hdrHolder.finishHDRLookImport(uri)
    fun applyHDRSilver(master: Boolean) = hdrHolder.applyHDRSilver(master)
    fun cancelHDRLookImport() = hdrHolder.cancelHDRLookImport()
    fun setHDRMode(enabled: Boolean) = hdrHolder.setHDRMode(enabled)
    fun applyHDRCameraDevelopment(development: HDRCameraDevelopmentSettings) = hdrHolder.applyHDRCameraDevelopment(development)
    fun changeHDRCameraDraft(settings: HDRCameraDevelopmentSettings) = hdrHolder.changeHDRCameraDraft(settings)
    fun beginHDRCameraProfileImport(): Boolean = hdrHolder.beginHDRCameraProfileImport()
    fun finishHDRCameraProfileImport(uri: Uri?) = hdrHolder.finishHDRCameraProfileImport(uri)

    fun edit(requested: EditSettings, interactive: Boolean = false, clearProcessingMigration: Boolean = false) =
        previewCoordinator.edit(requested, interactive, clearProcessingMigration)
    fun updatePreviewSize(edge: Int) = draftHolder.updatePreviewSize(edge)
    fun beginDraft(group: AdjustmentGroup) = draftHolder.beginDraft(group)
    fun changeDraft(edits: EditSettings, interactive: Boolean = false) = draftHolder.changeDraft(edits, interactive)
    fun undoDraft() = draftHolder.undoDraft()
    fun redoDraft() = draftHolder.redoDraft()
    fun chooseGeometryRatio(ratio: GeometryRatio, portrait: Boolean) = draftHolder.chooseGeometryRatio(ratio, portrait)
    fun toggleGeometryLock() = draftHolder.toggleGeometryLock()
    fun swapGeometryRatio() = draftHolder.swapGeometryRatio()
    fun toggleGeometryGrid() = draftHolder.toggleGeometryGrid()
    fun applyDraft(completed: (Boolean) -> Unit = {}) = draftHolder.applyDraft(completed)
    fun discardDraft() = draftHolder.discardDraft()
    fun retry() = previewCoordinator.retry()
    fun autoExposure() = previewCoordinator.autoExposure()
    fun retrySave(completed: (Boolean) -> Unit = {}) = previewCoordinator.retrySave(completed)
    fun prepareReset(scope: EditorResetScope): EditorResetPreparation = draftHolder.prepareReset(scope)
    fun commitReset(prepared: PreparedEditorReset): Boolean = draftHolder.commitReset(prepared)
    fun setEditorActive(active: Boolean) {
        if (session.editorActive != active) session.activationRevision += 1
        session.editorActive = active
        if (!active) processingMigrationHolder.cancel(skipCurrentSource = true)
        else {
            processingMigrationHolder.resumeDeferredPreviewIfReady()
            processingMigrationHolder.startIfNeeded()
        }
    }
    fun rollbackProcessingMigration() = processingMigrationHolder.rollback()

    fun cancelAdjustmentInteraction() = adjustmentTransferHolder.cancelInteraction()
    fun undoAdjustment(completed: (List<AdjustmentOutcome>) -> Unit = {}) = adjustmentTransferHolder.undo(completed)
    fun redoAdjustment(completed: (List<AdjustmentOutcome>) -> Unit = {}) = adjustmentTransferHolder.redo(completed)
    fun performAdjustmentHistory(undo: Boolean, transactionID: UUID? = null, wholeTransaction: Boolean = false,
        skipping: Set<String> = emptySet(), completed: (List<AdjustmentOutcome>) -> Unit = {}) =
        adjustmentTransferHolder.performHistory(undo, transactionID, wholeTransaction, skipping, completed)
    fun executeAdjustmentHistory(request: EditorAdjustmentHistoryRequest, skipping: Set<String> = emptySet(),
        completed: (List<AdjustmentOutcome>) -> Unit = {}) =
        adjustmentTransferHolder.executeHistory(request, skipping, completed)
    internal fun acceptAdjustmentOutcomes(results: List<AdjustmentOutcome>, cachedTargets: Set<String> = emptySet(),
        expectedSourceToken: Long? = null): List<AdjustmentOutcome> =
        adjustmentTransferHolder.acceptOutcomes(results, cachedTargets, expectedSourceToken)
    fun copyAdjustments(scope: AdjustmentScope): AdjustmentPayload? = adjustmentTransferHolder.copy(scope)
    fun capturePresetAdjustments(scope: AdjustmentScope, completed: (Result<AdjustmentPayload>) -> Unit) =
        adjustmentTransferHolder.capturePreset(scope, completed)
    fun previewAdjustmentPayload(scope: AdjustmentScope): Result<AdjustmentPayload> = adjustmentTransferHolder.previewPayload(scope)
    fun adjustmentSummaryLookName(kind: String, id: String): String? = adjustmentTransferHolder.summaryLookName(kind, id)
    fun prepareAdjustmentPaste(payload: AdjustmentPayload, uris: List<Uri>,
        action: AdjustmentHistoryTransaction.Action = AdjustmentHistoryTransaction.Action.PASTE) =
        adjustmentTransferHolder.preparePaste(payload, uris, action)
    fun applyAdjustmentPaste(operation: PreparedAdjustmentTransfer, skipping: Set<String> = emptySet(),
        completed: (List<AdjustmentOutcome>) -> Unit = {}) =
        adjustmentTransferHolder.applyPaste(operation, skipping, completed)
    fun closeAdjustmentOperation() = adjustmentTransferHolder.closeOperation()
    fun showQuickPresets() = adjustmentTransferHolder.showQuickPresets()
    fun closeQuickPresets() = adjustmentTransferHolder.closeQuickPresets()
    fun cancelQuickPreset() = adjustmentTransferHolder.cancelQuickPreset()
    fun applyPresetToCurrentPhoto(preset: AdjustmentPreset) = adjustmentTransferHolder.applyPresetToCurrentPhoto(preset)
    fun undoQuickPreset() = adjustmentTransferHolder.undoQuickPreset()

    fun setGpuEnabled(enabled: Boolean) = previewCoordinator.setGpuEnabled(enabled)
    fun beginExport(completed: (Boolean) -> Unit = {}) = exportHolder.beginExport(completed)
    fun beginExportDestinationPick() = exportHolder.beginExportDestinationPick()
    fun returnToExportOptions() = exportHolder.returnToExportOptions()
    fun cancelExport() = exportHolder.cancelExport()
    fun export(destination: Uri?, format: ExportFormat, longEdge: Int? = null,
        outputSharpening: OutputSharpening = OutputSharpening.OFF) =
        exportHolder.export(destination, format, longEdge, outputSharpening)
    fun dismissMessage() { mutable.value = mutable.value.copy(message = null) }

    fun addCollectionPhotos(uris: List<Uri>) = collectionHolder.addPhotos(uris)
    fun retainCurrentInCollection() = collectionHolder.retainCurrent()
    fun selectCollectionPhoto(id: String, selected: Boolean) = collectionHolder.selectPhoto(id, selected)
    fun selectCollectionAll(selected: Boolean) = collectionHolder.selectAll(selected)
    fun removeCollectionPhoto(id: String) = collectionHolder.removePhoto(id)
    fun refreshCollection() = collectionHolder.refresh()
    fun collectionSupportsHDRExport(skipping: Set<String> = emptySet()) = collectionHolder.supportsHDRExport(skipping)
    fun collectionDraftFailure(id: String): String? = collectionHolder.draftFailure(id)
    fun resolveCollectionDraft(apply: Boolean, completed: (Boolean) -> Unit = {}) = collectionHolder.resolveDraft(apply, completed)
    fun editCollectionPhoto(id: String, completed: (Boolean) -> Unit = {}) = collectionHolder.editPhoto(id, completed)
    fun returnToCollection(completed: (Boolean) -> Unit = {}) = collectionHolder.returnToCollection(completed)
    fun captureCollectionSynchronization(scope: AdjustmentScope, completed: (CollectionSynchronization?) -> Unit) =
        collectionHolder.captureSynchronization(scope, completed)
    fun prepareCollectionExport(skipping: Set<String>, format: ExportFormat, longEdge: Int?, destination: Uri?,
        outputSharpening: OutputSharpening = OutputSharpening.OFF,
        completed: (CollectionExportReview?) -> Unit) = collectionHolder.prepareExport(skipping, format, longEdge, destination, completed, outputSharpening)
    fun freezeCollectionExport(review: CollectionExportReview, completed: (Boolean) -> Unit) =
        collectionHolder.freezeExport(review, completed)
    fun cancelCollectionExport() = collectionHolder.cancelExport()
    fun startCollectionExport(skipping: Set<String>, format: ExportFormat, longEdge: Int?, destination: Uri?,
        outputSharpening: OutputSharpening = OutputSharpening.OFF,
        completed: (Boolean) -> Unit = {}) = collectionHolder.startExport(skipping, format, longEdge, destination, outputSharpening, completed)

    fun beginBatch() = batchHolder.beginBatch()
    fun resumeBatch(job: BatchJob) = batchHolder.resumeBatch(job)
    fun closeBatch() = batchHolder.closeBatch()
    fun onBackground() = previewCoordinator.onBackground()

    override fun onCleared() {
        appContext.unregisterComponentCallbacks(memoryCallbacks)
        draftHolder.preserveEditorDraft()
        previewCache.setForegroundBusy(photoPreviewOwner, false)
        previewCache.close()
        processingMigrationHolder.cancel()
        importRecoveryHolder.clearAll()
        session.disposed = true
        adjustmentTransferHolder.onDisposed()
        draftHolder.cancelResize()
        batchHolder.dispose()
        collectionHolder.close(storageRelease.releaserFor("collections"))
        lookHolder.close()
        viewport.close()
        adjustmentQueue.close()
        adjustmentTransferHolder.close()
        processingMigrationHolder.close()
    }
}
