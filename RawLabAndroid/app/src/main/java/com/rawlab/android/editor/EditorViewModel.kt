package com.rawlab.android.editor

import android.app.Application
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.rawlab.android.R
import com.rawlab.android.adjustments.AdjustmentFailure
import com.rawlab.android.adjustments.AdjustmentHistoryTransaction
import com.rawlab.android.adjustments.AdjustmentOutcome
import com.rawlab.android.adjustments.AdjustmentPayload
import com.rawlab.android.adjustments.AdjustmentScope
import com.rawlab.android.adjustments.AdjustmentTransferException
import com.rawlab.android.adjustments.PreparedAdjustmentTransfer
import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.CollectionExportReview
import com.rawlab.android.editor.canvas.DetailTileKey
import com.rawlab.android.editor.canvas.DetailTileSpec
import com.rawlab.android.editor.canvas.ViewportRoiRequest
import com.rawlab.android.editor.canvas.detailTileSpecs
import com.rawlab.android.editor.render.EditorRenderer
import com.rawlab.android.editor.render.PreviewDetailOverlay
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.render.RenderQueue
import com.rawlab.android.editor.render.SerialWorkQueue
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.editor.render.canFinishPreviewBefore
import com.rawlab.android.editor.render.discardPendingWork
import com.rawlab.android.editor.render.isExportCancellation
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.geometry.GeometryRatio
import com.rawlab.android.looks.DcpImportChoices
import com.rawlab.android.looks.LUTCompatibility
import com.rawlab.android.looks.UnreadableLook
import com.rawlab.android.presets.AdjustmentPreset
import com.rawlab.android.presets.AdjustmentPresetStore
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.HDRCameraDevelopmentSettings
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import java.io.File
import java.util.UUID

private const val DETAIL_TILE_MAX_BYTES = 64L * 1024L * 1024L
private const val DETAIL_TILE_MAX_COUNT = 24

class EditorViewModel internal constructor(
    application: Application,
    private val dependencies: EditorDependencies,
) : AndroidViewModel(application) {

    @JvmOverloads
    constructor(
        application: Application,
        editStoreFactory: (File) -> EditStore = { EditStore(it) },
        batchProcessorFactory: (Int, File?) -> NativeProcessor = { mode, database -> NativeProcessor(mode, database) },
    ) : this(application, EditorDependencies.production(application, editStoreFactory, batchProcessorFactory))

    private val scope = dependencies.scope ?: viewModelScope
    private val strings = dependencies.strings
    val storage = dependencies.storage
    private val renderer: EditorRenderer? = dependencies.renderer
    private val renderGateway = dependencies.renderGateway
    private val previewCache = dependencies.previewCache
    private val photoPreviewOwner = UUID.randomUUID().toString()
    val presetStore: AdjustmentPresetStore by lazy { dependencies.presetStoreFactory() }
    private val editStore = dependencies.editStore
    private val draftStore = dependencies.draftStore
    private val adjustmentHistory = EditorAdjustmentHistory(editStore, dependencies.sourceValidator)

    private val mutable = MutableStateFlow(EditorState())
    val state = mutable.asStateFlow()

    @Volatile private var disposed = false
    private var currentRevision = 0L
    private var latestRender: Work? = null
    private var progressivePreviewFloor = 0L
    @Volatile private var sourceRevision = 0L
        set(value) { if (field != value) processingMigrationHolder.onSourceRevisionChanged(); field = value }
    @Volatile private var editRevision = 0L
        set(value) { if (field != value) processingMigrationHolder.onEditRevisionChanged(); field = value }
    private var previewLongEdge = 1600
    private var editorActivationRevision = 0L
    private var editorActive = true
    private var detailDebounceJob: Job? = null
    private var lastDetailRequest: ViewportRoiRequest? = null
    private var detailNeedsBefore = false
    private var inFlightDetailTileKey: DetailTileKey? = null
    private var scheduledDetailTileKey: DetailTileKey? = null
    private val detailRevisions = HashSet<Long>()
    private val detailTileCache = LinkedHashMap<DetailTileKey, PreviewDetailOverlay>(32, 0.75f, true)
    private var detailTileCacheBytes = 0L
    private var detailTileSourceRevision = -1L
    private var detailTileEditRevision = -1L
    private val hdrDetailCache = ArrayList<PreviewDetailOverlay>(4)

    internal val storageRelease = StorageReleaseManifest(
        setOf("renderQueue", "lookQueue", "adjustmentQueue", "adjustmentPreparationQueue", "processingMigrationQueue", "collections"),
        storage::close,
    )

    private val queue = RenderQueue<Work, WorkResult>(
        renderGateway::perform,
        { revision, result ->
            // 结果持有临时输入；即使 ViewModel scope 已取消，也要在主线程完成移交或释放。
            dependencies.mainDelivery {
                val isDetail = detailRevisions.remove(revision)
                if (isDetail) {
                    if (revision == currentRevision) {
                        inFlightDetailTileKey = null
                        if (!disposed && result.isSuccess) {
                            previewCoordinator.accept(result)
                        }
                    }
                    return@mainDelivery
                }
                val preview = result.getOrNull() as? WorkResult.Preview
                if (!disposed && revision == currentRevision) previewCoordinator.accept(result)
                else if (!disposed && revision >= progressivePreviewFloor && preview != null &&
                    latestRender?.let(preview.request::canFinishPreviewBefore) == true
                ) {
                    mutable.value = mutable.value.copy(preview = preview.pair, exact = false)
                } else {
                    result.fold({ exportHolder.onLateExportCompleted(it) }, { error ->
                        if (!disposed && !isExportCancellation(error)) mutable.value = mutable.value.copy(error = failure(error))
                    })
                }
            }
        },
        { renderGateway.close(); storageRelease.release("renderQueue") },
        { exportHolder.onLateExportCompleted(it) },
        { work -> work.discardPendingWork(dependencies.exportCleanup) },
        canFinishInFlight = Work::canFinishPreviewBefore,
    )

    private val adjustmentQueue = SerialWorkQueue(storageRelease.releaserFor("adjustmentQueue"))

    private val systemPhotoHolder = EditorSystemPhotoStateHolder(
        storage, scope, dependencies.ioDispatcher, dependencies.systemPhotoPreferencesFactory,
        onError = { error -> mutable.value = mutable.value.copy(error = failure(error)) },
        parseUri = dependencies.parseSystemPhotoUri,
        retainUri = dependencies.retainSystemPhoto ?: { uri ->
            if (storage.isRetainedSystemPhoto(uri)) uri else storage.retainSystemPhoto(uri)
        },
    )

    private val lookHolder: EditorLookStateHolder = EditorLookStateHolder(
        mutable, scope, strings, dependencies.lookPreferencesFactory, dependencies.masterRecipesLoader,
        dependencies.lookWorkRunner, storageRelease.releaserFor("lookQueue"), { disposed }, { sourceRevision },
        { draftHolder.draftRevision }, { previewLongEdge }, { draftHolder.requestedPreviewLongEdge }, ::gpuMode,
        onEdit = { settings, interactive -> previewCoordinator.edit(settings, interactive) },
        onRenderDraft = { draftHolder.renderDraft(it) },
        onClearPendingResetMigration = { processingMigrationHolder.clearPendingReset() },
        onPersist = { photo, edits, completed -> previewCoordinator.persist(photo, edits, completed = completed) },
        onIncrementEditRevision = { editRevision += 1 },
        onClearDurablePreview = { draftHolder.clearDurablePreview() },
        onSubmitPreview = { work -> currentRevision = submitRender(work) },
        onUpdatePreviewSize = { draftHolder.updatePreviewSize(it) },
    )

    private val hslHolder: EditorHslEyedropperStateHolder = EditorHslEyedropperStateHolder(
        mutable, { sourceRevision }, { currentRevision }, { work -> currentRevision = submitRender(work) },
        { edits, interactive -> draftHolder.changeDraft(edits, interactive) },
        { draftHolder.incrementDraftRevision() }, { draftHolder.renderDraft(it) },
    )

    private val hdrHolder: EditorHdrStateHolder = EditorHdrStateHolder(
        mutable, scope, dependencies.ioDispatcher, strings, { storage.hdrLookDirectory },
        dependencies.hdrLookImporter, dependencies.hdrSilverInstaller, dependencies.hdrSilverMasterLoader,
        dependencies.hdrCameraProfileImporter, { disposed }, { sourceRevision }, { editRevision },
        { draftHolder.draftRevision }, { previewLongEdge }, ::gpuMode,
        onEdit = { previewCoordinator.edit(it) }, onSubmitPreflight = { work -> currentRevision = submitRender(work) },
    )

    private val exportHolder: EditorExportStateHolder = EditorExportStateHolder(
        mutable, dependencies.exportCleanup, strings, dependencies.mainDelivery, dependencies.recordUsage,
        { disposed }, ::gpuMode, { draftHolder.requestedPreviewLongEdge },
        onPersist = { photo, edits, completed -> previewCoordinator.persist(photo, edits, completed = completed) },
        onSubmitExport = { work -> currentRevision = submitRender(work) },
        onInvalidateRender = { currentRevision = invalidateRender() },
        onReleaseDeferredCollections = { collectionHolder.releaseDeferred() },
        onUpdatePreviewSize = { draftHolder.updatePreviewSize(it) },
    )

    private val processingMigrationHolder: EditorProcessingMigrationStateHolder = EditorProcessingMigrationStateHolder(
        mutable, storage, editStore, adjustmentHistory, strings, dependencies.mainDelivery,
        dependencies.migrationProcessorFactory, storageRelease.releaserFor("processingMigrationQueue"),
        { disposed }, { editorActive }, { sourceRevision }, { editRevision }, ::gpuMode,
        onCommitAdjustments = { work, publishBeforeUnlock, completed -> commitAdjustments(work, publishBeforeUnlock, completed) },
        onIncrementEditRevision = { editRevision += 1 },
        onInvalidateRender = { currentRevision = invalidateRender() },
        onCancelPreviewResize = { draftHolder.cancelResize() },
        onClearDurableAndNavigationPreview = { draftHolder.clearDurableAndNavigationPreview() },
        onIncludeIndependentRecipeLook = lookHolder::includeIndependentRecipeLook,
        onRenderCommittedForNavigation = { draftHolder.renderCommittedForNavigation() },
    )

    private val adjustmentTransferHolder: EditorAdjustmentTransferStateHolder = EditorAdjustmentTransferStateHolder(
        application, storage, editStore, adjustmentHistory, mutable, scope, strings,
        dependencies.masterRecipesLoader, dependencies.adjustmentPreparationRunner,
        storageRelease.releaserFor("adjustmentPreparationQueue"), { disposed }, { sourceRevision }, { editRevision },
        { id -> collectionHolder.photo(id) }, { collectionHolder.state.value.photos },
        { target -> collectionHolder.validate(target) }, { id, changed -> collectionHolder.synchronized(id, changed) },
        { collectionHolder.releaseDeferred() }, { work, completed -> commitAdjustments(work, completed = completed) },
        { photo, edits, completed -> previewCoordinator.persist(photo, edits, completed = completed) },
        { hslHolder.clear() }, { processingMigrationHolder.cancel(skipCurrentSource = true) },
        { processingMigrationHolder.clearPendingReset() }, { editRevision += 1 },
        lookHolder::includeIndependentRecipeLook, lookHolder::updateRecentLooks,
        { draftHolder.renderCommittedForNavigation() },
    )

    private val batchHolder: EditorBatchStateHolder = EditorBatchStateHolder(
        application, storage, scope, dependencies.batchProcessorFactory, dependencies.usageFactory, strings, mutable,
        { disposed }, ::gpuMode, ::failure, { processingMigrationHolder.cancel(skipCurrentSource = true) },
        queue::performAfterPending, adjustmentTransferHolder::finishClose, { collectionHolder.releaseDeferred() },
        renderGateway::releaseDecodedRaster,
    )

    private val collectionHolder: EditorCollectionStateHolder = EditorCollectionStateHolder(
        storage, scope, File(application.filesDir, "RawLab/BatchJobs"), mutable, editStore, adjustmentHistory,
        strings, { disposed }, { sourceRevision }, adjustmentTransferHolder::hasActivePreparations,
        { importRecoveryHolder.ownsFailedRecovery(it) }, adjustmentTransferHolder::targetIsCurrent,
        batchHolder::hasActiveOrPending, batchHolder::retain, batchHolder::resumeAttached,
        batchHolder::releaseEditorRasterForBatch, { work, completed -> commitAdjustments(work, completed = completed) },
        ::importPhoto, ::capturePresetAdjustments, adjustmentTransferHolder::cancelInteraction,
        { settings, interactive -> previewCoordinator.edit(settings, interactive) },
        ::applyDraft, ::discardDraft, ::retrySave, { processingMigrationHolder.clearPendingReset() },
        { editRevision += 1 }, lookHolder::includeIndependentRecipeLook,
        { draftHolder.renderCommittedForNavigation() },
    )

    private val importRecoveryHolder: EditorImportRecoveryStateHolder = EditorImportRecoveryStateHolder(
        mutable, editStore, draftStore, strings, { disposed }, ::gpuMode, ::failure,
        collectionHolder::photo, collectionHolder::owns, collectionHolder::releaseDeferred,
        adjustmentTransferHolder::cancelInteraction,
        { photo, edits, completed -> previewCoordinator.persist(photo, edits, completed = completed) },
        onBeforeStartImport = {
            adjustmentTransferHolder.closeQuickPresets()
            sourceRevision += 1
            adjustmentTransferHolder.closeOperation()
            draftHolder.resetForImport()
        },
        onSubmitImport = { work -> currentRevision = submitRender(work) },
        onAcceptHistorySource = adjustmentHistory::acceptSource,
        onCollectionOpened = collectionHolder::opened,
        onIncludeIndependentRecipeLook = lookHolder::includeIndependentRecipeLook,
        onCommitAdjustments = { work, completed -> commitAdjustments(work, completed = completed) },
    )

    private val draftHolder: EditorDraftStateHolder = EditorDraftStateHolder(
        mutable, draftStore, scope, strings, dependencies.uptimeMillis, dependencies.previewResizedDelayMs,
        dependencies.masterRecipesLoader, dependencies.uncroppedGeometrySize, { disposed },
        { sourceRevision }, { editRevision }, { currentRevision }, { previewLongEdge }, { previewLongEdge = it },
        ::gpuMode, { hdrHolder.cameraHDRPreflightPending }, { quickPreset.value.phase == QuickPresetPhase.PREPARING },
        adjustmentTransferHolder::cancelQuickPreset, hslHolder::cancel, hslHolder::clear,
        { processingMigrationHolder.clearPendingReset() }, { processingMigrationHolder.clearDeferredPreview() },
        { editRevision += 1 }, { work -> submitRender(work).also { currentRevision = it } },
        { photo, edits, completed -> previewCoordinator.persist(photo, edits, completed = completed) },
        { settings, interactive, clearMigration -> previewCoordinator.edit(settings, interactive, clearMigration) },
    )

    private val previewCoordinator: EditorPreviewCoordinator = EditorPreviewCoordinator(
        mutable, scope, strings, editStore, adjustmentHistory, previewCache, dependencies.saveNoticeFadeDelayMs,
        dependencies.recordUsage, { disposed }, { editorActive }, { editorActivationRevision },
        { sourceRevision }, { editRevision }, { currentRevision }, { previewLongEdge }, { previewLongEdge = it },
        { editRevision += 1 }, { work -> submitRender(work).also { currentRevision = it } },
        { work, completed -> commitAdjustments(work, completed = completed) },
        { work, completed -> commitAdjustments(work, completed = completed) },
        lookHolder, importRecoveryHolder, hslHolder, hdrHolder, exportHolder,
        processingMigrationHolder, adjustmentTransferHolder, collectionHolder, batchHolder, draftHolder, ::failure,
        { scheduleDetailIfNeeded() },
        ::handleDetailAccepted,
    )

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
        scope.launch {
            state.map { it.rendering || it.operation != Operation.NONE || it.committingAdjustments }
                .distinctUntilChanged().collect { previewCache.setForegroundBusy(photoPreviewOwner, it) }
        }
        editStore.initialResult.let {
            mutable.value = mutable.value.copy(saveState = it.state, saveError = it.formatMessage(strings))
        }
        renderGateway.setExportProgressListener { work, fraction ->
            dependencies.mainDelivery {
                val current = mutable.value
                if (!disposed && current.operation == Operation.EXPORT && work === latestRender) {
                    mutable.value = current.copy(exportProgress = fraction.coerceIn(0f, 1f))
                }
            }
        }
        lookHolder.loadInitial()
        batchHolder.refreshPending()
        systemPhotoHolder.restorePending()
    }

    // 提交期单槽契约（k161 定性，勿改为"completed 后再解锁"或计数队列）：
    private fun <T> commitAdjustments(work: () -> T, publishBeforeUnlock: Boolean = false, completed: (Result<T>) -> Unit) {
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
                            processingMigrationHolder.resumeDeferredPreviewIfReady()
                        }
                        adjustmentTransferHolder.finishClose()
                        collectionHolder.releaseDeferred()
                    }
                }
            }
        }
    }

    private fun submitRender(work: Work): Long {
        if (work !is Work.DetailPreview && work !is Work.HslProbe) {
            clearDetailState(keepRequest = work is Work.Preview && !work.importing)
        }
        if (work !is Work.DetailPreview) {
            if (work !is Work.HslProbe && hslHolder.isWaiting) hslHolder.clear()
            hdrHolder.onRenderSubmitted(work)
        }
        val continuesInteraction = latestRender?.canFinishPreviewBefore(work) == true
        if (work !is Work.DetailPreview && work !is Work.HslProbe) {
            latestRender = work
        }
        return queue.submit(work).also { submitted ->
            if (work is Work.DetailPreview) {
                inFlightDetailTileKey = work.tileKey
                detailRevisions.add(submitted)
                detailRevisions.removeAll { it < submitted - 32 }
            } else {
                inFlightDetailTileKey = null
            }
            if (!continuesInteraction && work !is Work.DetailPreview) progressivePreviewFloor = submitted
        }
    }

    private fun invalidateRender(): Long {
        clearDetailState(keepRequest = false)
        latestRender = null
        return queue.invalidate().also { progressivePreviewFloor = it }
    }

    private data class DetailTilePlan(
        val visible: List<DetailTileSpec>,
        val desired: List<DetailTileSpec>,
    )

    private fun detailTileBytes(overlay: PreviewDetailOverlay): Long {
        val single = overlay.pixelWidth.toLong().coerceAtLeast(1L) * overlay.pixelHeight.toLong().coerceAtLeast(1L) * 4L
        return if (overlay.neutral != null && overlay.neutral !== overlay.result) single * 2L else single
    }

    private fun estimatedDetailTileBytes(spec: DetailTileSpec, includeNeutral: Boolean): Long {
        val edge = spec.maxOutputLongEdge.toLong().coerceAtLeast(1L)
        val single = edge * edge * 4L
        return if (includeNeutral) single * 2L else single
    }

    private fun touchDetailTiles(orderedSpecs: List<DetailTileSpec>) {
        // 逆序访问以保证中心可见瓦片留在 access-order LinkedHashMap 尾部（最后被淘汰）。
        for (spec in orderedSpecs.asReversed()) {
            detailTileCache[spec.key]
        }
    }

    private fun planDetailTiles(request: ViewportRoiRequest, preview: PreviewPair): DetailTilePlan {
        val visible = detailTileSpecs(
            request.visibleRect,
            preview.nativeWidth,
            preview.nativeHeight,
            request.zoomScale,
            request.baseScale,
            overscanRing = 0,
        )
        if (visible.isEmpty()) return DetailTilePlan(emptyList(), emptyList())
        if (dependencies.detailOverscanRing <= 0) return DetailTilePlan(visible, visible)
        val all = detailTileSpecs(
            request.visibleRect,
            preview.nativeWidth,
            preview.nativeHeight,
            request.zoomScale,
            request.baseScale,
            overscanRing = dependencies.detailOverscanRing,
        )
        val visibleKeys = visible.mapTo(HashSet(visible.size)) { it.key }
        fun plannedTileBytes(spec: DetailTileSpec): Long {
            val estimated = estimatedDetailTileBytes(spec, detailNeedsBefore)
            val cached = detailTileCache[spec.key]?.let(::detailTileBytes) ?: 0L
            return maxOf(estimated, cached)
        }
        val desired = ArrayList<DetailTileSpec>(all.size)
        var plannedBytes = 0L
        for (spec in visible) {
            desired += spec
            plannedBytes += plannedTileBytes(spec)
        }
        for (spec in all) {
            if (spec.key in visibleKeys) continue
            val tileBytes = plannedTileBytes(spec)
            if (desired.size + 1 > DETAIL_TILE_MAX_COUNT || plannedBytes + tileBytes > DETAIL_TILE_MAX_BYTES) {
                break
            }
            desired += spec
            plannedBytes += tileBytes
        }
        return DetailTilePlan(visible, desired)
    }

    private fun syncDetailCacheRevision() {
        if (detailTileSourceRevision != sourceRevision || detailTileEditRevision != editRevision) {
            detailTileCache.clear()
            detailTileCacheBytes = 0L
            hdrDetailCache.clear()
            detailTileSourceRevision = sourceRevision
            detailTileEditRevision = editRevision
        }
    }

    private fun sortedCachedDetailTiles(): List<PreviewDetailOverlay> =
        detailTileCache.values.sortedWith(
            compareByDescending<PreviewDetailOverlay> { it.tileKey?.level ?: 0 }
                .thenBy { it.tileKey?.row ?: 0 }
                .thenBy { it.tileKey?.col ?: 0 },
        )

    private fun detailTilesMatch(lhs: List<PreviewDetailOverlay>, rhs: List<PreviewDetailOverlay>): Boolean {
        if (lhs.size != rhs.size) return false
        for (i in lhs.indices) {
            if (lhs[i].tileKey != rhs[i].tileKey ||
                lhs[i].sourceRevision != rhs[i].sourceRevision ||
                lhs[i].editRevision != rhs[i].editRevision ||
                lhs[i].result !== rhs[i].result ||
                lhs[i].neutral !== rhs[i].neutral
            ) {
                return false
            }
        }
        return true
    }

    private fun tileNeedsRender(key: DetailTileKey): Boolean {
        val cached = detailTileCache[key] ?: return true
        return detailNeedsBefore && cached.neutral == null
    }

    private fun storeDetailTile(overlay: PreviewDetailOverlay, plan: DetailTilePlan) {
        syncDetailCacheRevision()
        val key = overlay.tileKey ?: return
        detailTileCache.remove(key)?.let { old ->
            detailTileCacheBytes = (detailTileCacheBytes - detailTileBytes(old)).coerceAtLeast(0L)
        }
        detailTileCache[key] = overlay
        detailTileCacheBytes += detailTileBytes(overlay)

        touchDetailTiles(plan.desired)
        val visibleKeys = plan.visible.mapTo(HashSet(plan.visible.size)) { it.key }
        val desiredKeys = plan.desired.mapTo(HashSet(plan.desired.size)) { it.key }
        while (detailTileCacheBytes > DETAIL_TILE_MAX_BYTES || detailTileCache.size > DETAIL_TILE_MAX_COUNT) {
            val victimKey = detailTileCache.keys.firstOrNull { it !in desiredKeys }
                ?: detailTileCache.keys.firstOrNull { it !in visibleKeys }
                ?: break
            val removed = detailTileCache.remove(victimKey) ?: break
            detailTileCacheBytes = (detailTileCacheBytes - detailTileBytes(removed)).coerceAtLeast(0L)
        }
    }

    private fun storeHDRDetail(overlay: PreviewDetailOverlay) {
        syncDetailCacheRevision()
        hdrDetailCache.removeAll { it.normalizedRect == overlay.normalizedRect && it.pixelWidth == overlay.pixelWidth }
        hdrDetailCache.add(overlay)
        while (hdrDetailCache.size > 4) hdrDetailCache.removeAt(0)
    }

    private fun handleDetailAccepted(value: WorkResult.DetailPreview) {
        inFlightDetailTileKey = null
        val overlay = value.overlay ?: return
        val req = value.request
        if (req.sourceRevision != sourceRevision || req.editRevision != editRevision) return
        if (overlay.tileKey != null) {
            val activeRequest = lastDetailRequest
            val preview = mutable.value.preview
            val plan = if (activeRequest != null && preview != null) {
                planDetailTiles(activeRequest, preview)
            } else {
                DetailTilePlan(emptyList(), emptyList())
            }
            storeDetailTile(overlay, plan)
            if (activeRequest != null) {
                val sorted = sortedCachedDetailTiles()
                if (!detailTilesMatch(mutable.value.detailTiles, sorted) || mutable.value.detail !== overlay) {
                    mutable.value = mutable.value.copy(detailTiles = sorted, detail = overlay)
                }
                val remaining = if (preview != null && preview.hdr == null) {
                    plan.desired.firstOrNull { tileNeedsRender(it.key) }
                } else null
                if (remaining != null) {
                    scheduleDetailWork(activeRequest, remaining, delayMs = 0L)
                }
            }
            return
        }
        if (overlay.hdrResult != null) storeHDRDetail(overlay)
        if (lastDetailRequest != null) {
            mutable.value = mutable.value.copy(detail = overlay, detailTiles = emptyList())
        }
    }

    private fun clearDetailState(keepRequest: Boolean = false) {
        detailDebounceJob?.cancel()
        detailDebounceJob = null
        scheduledDetailTileKey = null
        inFlightDetailTileKey = null
        if (!keepRequest) lastDetailRequest = null
        detailTileCache.clear()
        detailTileCacheBytes = 0L
        hdrDetailCache.clear()
        if (mutable.value.detail != null || mutable.value.detailTiles.isNotEmpty()) {
            mutable.value = mutable.value.copy(detail = null, detailTiles = emptyList())
        }
    }

    fun setDetailNeedsBefore(needed: Boolean) {
        if (disposed || detailNeedsBefore == needed) return
        detailNeedsBefore = needed
        if (needed && lastDetailRequest != null) {
            updateDetailRequest(lastDetailRequest)
        }
    }

    private fun scheduleDetailIfNeeded() {
        val request = lastDetailRequest ?: return
        if (disposed) return
        val current = mutable.value
        val preview = current.preview
        if (preview != null && preview.hdr == null) {
            syncDetailCacheRevision()
            val plan = planDetailTiles(request, preview)
            if (plan.desired.isNotEmpty()) {
                val firstMissing = plan.desired.firstOrNull { tileNeedsRender(it.key) } ?: return
                scheduleDetailWork(request, firstMissing, dependencies.detailDebounceDelayMs)
                return
            }
        }
        scheduleDetailWork(request, tileSpec = null, delayMs = dependencies.detailDebounceDelayMs)
    }

    private fun scheduleDetailWork(
        request: ViewportRoiRequest,
        tileSpec: DetailTileSpec?,
        delayMs: Long,
    ) {
        if (disposed) return
        detailDebounceJob?.cancel()
        scheduledDetailTileKey = tileSpec?.key
        detailDebounceJob = scope.launch {
            if (delayMs > 0L) delay(delayMs)
            detailDebounceJob = null
            scheduledDetailTileKey = null
            if (disposed) return@launch
            val current = mutable.value
            val photo = current.photo ?: return@launch
            val preview = current.preview ?: return@launch
            if (!current.controlsEnabled || !current.exact || current.rendering ||
                current.previewResizePending || current.operation != Operation.NONE ||
                current.draft?.group == AdjustmentGroup.GEOMETRY || hslHolder.isWaiting
            ) {
                return@launch
            }
            val effectiveRoi = if (tileSpec != null) {
                request.copy(
                    visibleRect = tileSpec.rect,
                    overscanRect = tileSpec.rect,
                    maxOutputLongEdge = tileSpec.maxOutputLongEdge,
                )
            } else {
                val edgeLimit = if (preview.hdr != null) minOf(1280, request.maxOutputLongEdge) else request.maxOutputLongEdge
                if (hdrDetailCache.any {
                    it.sourceRevision == sourceRevision &&
                    it.editRevision == editRevision &&
                    it.covers(request.visibleRect, request.zoomScale, edgeLimit)
                }) {
                    return@launch
                }
                request
            }
            val baseResultHeadroom = preview.hdr?.result?.statistics?.headroom ?: 0f
            val baseNeutralHeadroom = preview.hdr?.neutral?.statistics?.headroom ?: 0f
            currentRevision = submitRender(
                Work.DetailPreview(
                    photo = photo,
                    edits = current.visibleEdits,
                    roi = effectiveRoi,
                    gpuMode = gpuMode(),
                    sourceRevision = sourceRevision,
                    editRevision = editRevision,
                    baseResultHeadroom = baseResultHeadroom,
                    baseNeutralHeadroom = baseNeutralHeadroom,
                    includeNeutral = detailNeedsBefore,
                    tileKey = tileSpec?.key,
                )
            )
        }
    }

    fun updateDetailRequest(request: ViewportRoiRequest?) {
        if (disposed) return
        if (request == null) {
            detailDebounceJob?.cancel()
            detailDebounceJob = null
            scheduledDetailTileKey = null
            lastDetailRequest = null
            if (mutable.value.detail != null || mutable.value.detailTiles.isNotEmpty()) {
                mutable.value = mutable.value.copy(detail = null, detailTiles = emptyList())
            }
            return
        }
        lastDetailRequest = request
        val current = mutable.value
        val preview = current.preview
        if (preview != null && preview.hdr == null) {
            syncDetailCacheRevision()
            if (com.rawlab.android.editor.canvas.detailTileLevel(request.zoomScale, request.baseScale) == null) {
                detailDebounceJob?.cancel()
                detailDebounceJob = null
                scheduledDetailTileKey = null
                return
            }
            val plan = planDetailTiles(request, preview)
            if (plan.desired.isNotEmpty()) {
                touchDetailTiles(plan.desired)
                val cached = sortedCachedDetailTiles()
                if (cached.isNotEmpty() && !detailTilesMatch(current.detailTiles, cached)) {
                    mutable.value = current.copy(detailTiles = cached, detail = cached.last())
                }
                val missing = plan.desired.filter { tileNeedsRender(it.key) }
                if (missing.isEmpty()) {
                    detailDebounceJob?.cancel()
                    detailDebounceJob = null
                    scheduledDetailTileKey = null
                    return
                }
                val missingKeys = missing.mapTo(HashSet()) { it.key }
                if (inFlightDetailTileKey != null && inFlightDetailTileKey in missingKeys) {
                    return
                }
                val nextSpec = missing.first()
                if (detailDebounceJob?.isActive == true && scheduledDetailTileKey == nextSpec.key) {
                    return
                }
                scheduleDetailWork(request, nextSpec, dependencies.detailDebounceDelayMs)
                return
            }
        }
        syncDetailCacheRevision()
        val edgeLimit = if (preview?.hdr != null) minOf(1280, request.maxOutputLongEdge) else request.maxOutputLongEdge
        val hitIdx = hdrDetailCache.indexOfLast {
            it.sourceRevision == sourceRevision &&
            it.editRevision == editRevision &&
            it.covers(request.visibleRect, request.zoomScale, edgeLimit)
        }
        if (hitIdx >= 0) {
            val hit = hdrDetailCache.removeAt(hitIdx)
            hdrDetailCache.add(hit)
            detailDebounceJob?.cancel()
            detailDebounceJob = null
            scheduledDetailTileKey = null
            if (current.detail !== hit || current.detailTiles.isNotEmpty()) {
                mutable.value = current.copy(detail = hit, detailTiles = emptyList())
            }
            return
        }
        scheduleDetailIfNeeded()
    }

    private fun gpuMode() = if (mutable.value.gpuEnabled) NativeProcessor.AUTO else NativeProcessor.CPU
    private fun failure(error: Throwable): String = when {
        error is OutOfMemoryError -> strings.text(R.string.memory_error)
        error is com.rawlab.android.engine.NativeProcessingException && error.isForceGpuUnsupported ->
            strings.text(R.string.force_gpu_unsupported)
        else -> strings.text(R.string.process_error) + "\n" + (error.message ?: error.javaClass.simpleName)
    }

    fun receiveSystemPhotos(uris: List<Uri>, requestID: String = UUID.randomUUID().toString()) = systemPhotoHolder.receive(uris, requestID)
    fun consumeSystemPhotoRequest(request: SystemPhotoOpenRequest) = systemPhotoHolder.consume(request)
    fun setHslTargetEnabled(enabled: Boolean) = hslHolder.setEnabled(enabled)
    fun setHslTargetAxis(axis: Int) = hslHolder.setAxis(axis)
    fun beginHslTarget(x: Float, y: Float, keyDelta: Float? = null) = hslHolder.begin(x, y, keyDelta)
    fun moveHslTarget(delta: Float) = hslHolder.move(delta)
    fun endHslTarget() = hslHolder.end()
    fun cancelHslTarget() = hslHolder.cancel()
    fun rejectHslTarget() = hslHolder.reject()
    fun keyHslTarget(delta: Float) = hslHolder.key(delta)

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
        if (editorActive != active) editorActivationRevision += 1
        editorActive = active
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
        adjustmentTransferHolder.capturePreset(scope, { work, done -> commitAdjustments(work, completed = done) }, completed)
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
    fun export(destination: Uri?, format: ExportFormat, longEdge: Int? = null) = exportHolder.export(destination, format, longEdge)
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
        completed: (CollectionExportReview?) -> Unit) = collectionHolder.prepareExport(skipping, format, longEdge, destination, completed)
    fun freezeCollectionExport(review: CollectionExportReview, completed: (Boolean) -> Unit) =
        collectionHolder.freezeExport(review, completed)
    fun cancelCollectionExport() = collectionHolder.cancelExport()
    fun startCollectionExport(skipping: Set<String>, format: ExportFormat, longEdge: Int?, destination: Uri?,
        completed: (Boolean) -> Unit = {}) = collectionHolder.startExport(skipping, format, longEdge, destination, completed)

    fun beginBatch() = batchHolder.beginBatch()
    fun resumeBatch(job: BatchJob) = batchHolder.resumeBatch(job)
    fun closeBatch() = batchHolder.closeBatch()
    fun onBackground() = previewCoordinator.onBackground(::setEditorActive)

    override fun onCleared() {
        draftHolder.preserveEditorDraft()
        previewCache.setForegroundBusy(photoPreviewOwner, false)
        previewCache.close()
        processingMigrationHolder.cancel()
        importRecoveryHolder.clearAll()
        disposed = true
        adjustmentTransferHolder.onDisposed()
        draftHolder.cancelResize()
        detailDebounceJob?.cancel()
        detailDebounceJob = null
        batchHolder.dispose()
        collectionHolder.close(storageRelease.releaserFor("collections"))
        lookHolder.close()
        queue.close()
        adjustmentQueue.close()
        adjustmentTransferHolder.close()
        processingMigrationHolder.close()
    }
}
