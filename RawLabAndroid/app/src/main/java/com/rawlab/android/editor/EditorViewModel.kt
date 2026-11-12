package com.rawlab.android.editor

import com.rawlab.android.settings.HslTargetState
import com.rawlab.android.settings.HslTargetRevision
import com.rawlab.android.settings.HslTargetInteraction
import com.rawlab.android.settings.HslTargetAvailability

import android.app.Application
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.distinctUntilChanged
import com.rawlab.android.photo.EditedPhotoPreviews
import kotlinx.coroutines.launch
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import com.rawlab.android.R
import com.rawlab.android.analytics.UsageEvent
import com.rawlab.android.analytics.setup.UsageAnalyticsRegistry
import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.BatchSourceSnapshot
import com.rawlab.android.editor.render.EditorRenderer
import com.rawlab.android.editor.render.LookResult
import com.rawlab.android.editor.render.LookWork
import com.rawlab.android.looks.LUTCompatibility
import com.rawlab.android.editor.render.SerialWorkQueue
import com.rawlab.android.editor.render.RenderQueue
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.editor.render.runLookWork
import com.rawlab.android.editor.render.discardOwnedInput
import com.rawlab.android.editor.render.discardPendingWork
import com.rawlab.android.editor.render.ExportDestinationCleanup
import com.rawlab.android.editor.render.isExportCancellation
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.ExportSize
import com.rawlab.android.geometry.GeometryRatio
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.looks.DcpFailureReason
import com.rawlab.android.looks.DcpImportChoices
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.canonicalZeros
import com.rawlab.android.settings.synchronizeHDR
import com.rawlab.android.settings.withHDRMode
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.ProcessingMigrationReceipt
import com.rawlab.android.settings.ProcessingMigrationStatus
import com.rawlab.android.settings.editingHsl
import com.rawlab.android.settings.withEditingHsl
import com.rawlab.android.editor.storage.EditorEditStore
import com.rawlab.android.editor.storage.EditSaveResult
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.geometry.uncropped
import com.rawlab.android.looks.MasterRecipe
import com.rawlab.android.looks.localizedName
import com.rawlab.android.adjustments.*
import com.rawlab.android.presets.AdjustmentPresetStore
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.AdjustmentNotReadyException
import com.rawlab.android.settings.AdjustmentOperationExpiredException
import com.rawlab.android.settings.LookChoice
import com.rawlab.android.format.PhotoInputKind
import java.util.UUID
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class SystemPhotoOpenRequest(val uris: List<Uri>, val id: UUID = UUID.randomUUID(),
    val externalRequestID: String? = null, val openAsCollection: Boolean = uris.size > 1)

private fun loadSystemPhotoRequestQueue(preferences: android.content.SharedPreferences): SystemPhotoRequestQueue {
    val pending = mutableListOf<DurableSystemPhotoRequest>()
    val processed = linkedSetOf<String>()
    runCatching {
        val values = org.json.JSONArray(preferences.getString("pending_requests", "[]"))
        for (index in 0 until values.length()) {
            val value = values.optJSONObject(index) ?: continue
            val id = value.optString("id").takeIf { it.isNotBlank() } ?: continue
            val uris = value.optJSONArray("uris")?.let { array ->
                List(array.length()) { array.getString(it) }.distinct()
            }.orEmpty()
            if (uris.isNotEmpty()) pending += DurableSystemPhotoRequest(id, uris)
        }
    }
    runCatching {
        val values = org.json.JSONArray(preferences.getString("processed_requests", "[]"))
        for (index in 0 until values.length()) processed += values.getString(index)
    }
    return SystemPhotoRequestQueue(pending, processed)
}

class EditorViewModel @JvmOverloads constructor(
    application: Application,
    editStoreFactory: (File) -> EditStore = { EditStore(it) },
    private val batchProcessorFactory: (Int, File?) -> NativeProcessor = { mode, database -> NativeProcessor(mode, database) },
) : AndroidViewModel(application) {
    val storage = PhotoStorage(application)
    private val photoPreviews = EditedPhotoPreviews(application)
    private val photoPreviewOwner = UUID.randomUUID().toString()
    val presetStore = AdjustmentPresetStore(File(application.filesDir, "presets"))
    private val lookPreferences = application.getSharedPreferences("look-browser", android.content.Context.MODE_PRIVATE)
    private val recentLooks = com.rawlab.android.looks.RecentLooks(runCatching {
        val entries = org.json.JSONArray(lookPreferences.getString("recent", "[]"))
        List(entries.length()) { entries.getString(it) }
    }.getOrDefault(emptyList()))
    private val usage = UsageAnalyticsRegistry.get(application)
    private val editStore = EditorEditStore(File(application.filesDir, "edits"), editStoreFactory)
    private val draftStore = EditorDraftStore(File(application.filesDir, "editor-draft"))
    private val adjustmentHistory = EditorAdjustmentHistory(editStore)
    val adjustmentTransactions get() = adjustmentHistory.session?.transactions.orEmpty()
    val canUndoAdjustment get() = mutable.value.photo?.identity?.let { adjustmentHistory.session?.canUndoPhoto(it) } == true
    val canRedoAdjustment get() = mutable.value.photo?.identity?.let { adjustmentHistory.session?.canRedoPhoto(it) } == true
    val adjustmentClipboard get() = adjustmentHistory.session?.clipboard
    var adjustmentClipboardSourceName: String? = null
        private set
    private val mutableAdjustmentTransfer = MutableStateFlow(EditorAdjustmentTransferState())
    val adjustmentTransfer = mutableAdjustmentTransfer.asStateFlow()
    private val mutableQuickPreset = MutableStateFlow(EditorQuickPresetState())
    val quickPreset = mutableQuickPreset.asStateFlow()
    private var quickPresetGeneration = UUID.randomUUID()
    private var adjustmentOwnedFiles = emptyMap<String, File>()
    @Volatile private var adjustmentPreparationGeneration = UUID.randomUUID()
    private var adjustmentPreparations = 0
    private var adjustmentCloseRequested = false
    private val batches = EditorBatches(application, storage, viewModelScope, batchProcessorFactory, usage) { error ->
        mutable.value = mutable.value.copy(error = error)
    }
    private val collections = EditorCollections(storage, viewModelScope, File(application.filesDir, "RawLab/BatchJobs"),
        editStore::readState, { adjustmentHistory.session?.editGeneration(it) ?: 0L }, ::captureCollectionActiveValidation, canRelease = { photo ->
            mutable.value.photo?.file != photo.file && failedX3fImport?.retained?.file != photo.file &&
                failedUnusableImport?.first?.retained?.file != photo.file &&
                mutable.value.operation != Operation.IMPORT && adjustmentPreparations == 0 && !mutable.value.committingAdjustments
        })
    val collection = collections.state
    private val systemPhotoImportLock = Mutex()
    private val mutableSystemPhotoRequests = MutableStateFlow<List<SystemPhotoOpenRequest>>(emptyList())
    val systemPhotoRequests = mutableSystemPhotoRequests.asStateFlow()
    private val systemPhotoQueueLock = Any()
    private val systemPhotoQueuePreferences = application.getSharedPreferences("system-photo-requests", android.content.Context.MODE_PRIVATE)
    private val systemPhotoRequestQueue = loadSystemPhotoRequestQueue(systemPhotoQueuePreferences)

    fun receiveSystemPhotos(uris: List<Uri>, requestID: String = UUID.randomUUID().toString()) {
        if (uris.isEmpty()) return
        val durableID = requestID.ifBlank { UUID.randomUUID().toString() }
        val accepted = synchronized(systemPhotoQueueLock) {
            if (systemPhotoRequestQueue.isProcessed(durableID) || !systemPhotoRequestQueue.enqueue(durableID, uris.map(Uri::toString))) false
            else {
                saveSystemPhotoQueueLocked()
                true
            }
        }
        if (accepted) importSystemPhotos(durableID)
    }

    private fun restoreSystemPhotos() {
        val pending = synchronized(systemPhotoQueueLock) { systemPhotoRequestQueue.ids() }
        pending.forEach(::importSystemPhotos)
    }

    private fun importSystemPhotos(requestID: String) {
        viewModelScope.launch { systemPhotoImportLock.withLock {
            val uris = synchronized(systemPhotoQueueLock) {
                systemPhotoRequestQueue.uris(requestID).map(Uri::parse)
            }
            if (uris.isEmpty()) return@withLock
            val (retained, errors) = withContext(Dispatchers.IO) {
                val results = uris.distinct().map { uri -> runCatching {
                    if (storage.isRetainedSystemPhoto(uri)) uri else storage.retainSystemPhoto(uri)
                } }
                results.mapNotNull { it.getOrNull() }.distinct() to results.mapNotNull { it.exceptionOrNull() }
            }
            synchronized(systemPhotoQueueLock) {
                systemPhotoRequestQueue.replace(requestID, retained.map(Uri::toString))
                saveSystemPhotoQueueLocked()
            }
            if (retained.isNotEmpty()) mutableSystemPhotoRequests.value += SystemPhotoOpenRequest(retained,
                externalRequestID = requestID, openAsCollection = uris.size > 1)
            if (errors.isNotEmpty()) mutable.value = mutable.value.copy(error = failure(errors.first()))
        } }
    }

    fun consumeSystemPhotoRequest(request: SystemPhotoOpenRequest) {
        mutableSystemPhotoRequests.value = mutableSystemPhotoRequests.value.filterNot { it.id == request.id }
        request.externalRequestID?.let { requestID -> synchronized(systemPhotoQueueLock) {
            systemPhotoRequestQueue.consume(requestID)
            saveSystemPhotoQueueLocked()
        } }
    }

    private fun saveSystemPhotoQueueLocked() {
        val pending = org.json.JSONArray().apply {
            systemPhotoRequestQueue.pending().forEach { request ->
                val uris = org.json.JSONArray().apply { request.uris.forEach(::put) }
                put(org.json.JSONObject().put("id", request.id).put("uris", uris))
            }
        }
        val processed = org.json.JSONArray().apply { systemPhotoRequestQueue.processed().forEach(::put) }
        // 消费动作返回前同步落盘，进程若随后被杀也不会再次打开已消费输入。
        systemPhotoQueuePreferences.edit()
            .putString("pending_requests", pending.toString())
            .putString("processed_requests", processed.toString())
            .commit()
    }

    val batch = batches.active
    val pendingBatch = batches.pending
    private val mutableCollectionExport = MutableStateFlow(CollectionExportFlow())
    val collectionExport = mutableCollectionExport.asStateFlow()
    @Volatile private var collectionExportGeneration = UUID.randomUUID()
    private val mutableHslTarget = MutableStateFlow(HslTargetState())
    val hslTarget = mutableHslTarget.asStateFlow()
    private val hslInteraction = HslTargetInteraction()
    private var hslHistoryActive = false
    private var acceptedHslPreview: Work.Preview? = null
    private var acceptedHslSettings: EditSettings? = null
    private var acceptedHslRevision: HslTargetRevision? = null
    private var currentRevision = 0L
    private var cameraHDRPreflightPending = false
    @Volatile private var sourceRevision = 0L
        set(value) {
            if (field != value) { cancelProcessingMigration(); deferredMigrationPreview = false; pendingResetMigrationClear = null }
            field = value
        }
    private var pendingResetMigrationClear: Pair<Long, EditSettings>? = null
    private var pendingHDRLookImport: Triple<Long, Long, Long>? = null
    private var pendingHDRCameraProfileImport: Pair<Long, Long>? = null
    @Volatile private var editRevision = 0L
        set(value) { if (field != value) cancelProcessingMigration(); field = value }
    private var draftRevision = 0L
    private var durablePreview: EditorDurablePreview? = null
    private var failedDraftSave = false
    private var draftSaveBaseline: Pair<EditSaveState, String?>? = null
    private var navigationPreview: EditorDurablePreview? = null
    private var previewLongEdge = 1600
    private var requestedPreviewLongEdge = 1600
    private var previewResizeJob: Job? = null
    private val interactivePreviewSize = com.rawlab.android.editor.render.InteractivePreviewSize()
    private val pendingPhotoImport = PendingPhotoImport()
    private var failedX3fImport: Work.Import? = null
    private var failedUnusableImport: Pair<Work.Import, PhotoIdentity>? = null
    private var lookRevision = 0L
    private var lookImportSelectionContext: Pair<Long, Long>? = null
    private var editorActivationRevision = 0L
    private var releases = 0
    private val mutable = MutableStateFlow(EditorState(recentLookIds = recentLooks.ids))
    val state = mutable.asStateFlow()
    @Volatile private var disposed = false
    private val renderer = EditorRenderer(storage, { if (editStore.available) editStore.readState(it) else null },
        (application.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0)
    private val exportDestinationCleanup = ExportDestinationCleanup { destination, original ->
        storage.deleteIncompleteDocument(destination, original)
    }
    private val renderDelivery = android.os.Handler(android.os.Looper.getMainLooper())
    private val queue = RenderQueue<Work, WorkResult>(renderer::perform, { revision, result ->
        // 结果持有临时输入；即使 ViewModel scope 已取消，也要在主线程完成移交或释放。
        renderDelivery.post {
            if (!disposed && revision == currentRevision) accept(result)
            else result.getOrNull()?.discardOwnedInput()
        }
    }, { renderer.close(); releaseStorage() }, { it.discardOwnedInput() }, { work ->
        work.discardPendingWork(exportDestinationCleanup)
    })
    private val lookQueue = RenderQueue<LookWork, LookResult>({ runLookWork(storage, it) }, { revision, result ->
        viewModelScope.launch {
            if (!disposed && revision == lookRevision) acceptLook(result)
        }
    }, ::releaseStorage)
    private val adjustmentPreparation = EditorAdjustmentPreparation(application, storage, editStore)
    internal var prepareAdjustmentOperation: (AdjustmentPreparationWork, () -> Boolean) -> AdjustmentPreparationResult = adjustmentPreparation::prepare
    private val adjustmentQueue = SerialWorkQueue(::releaseStorage)
    private val adjustmentPreparationQueue = SerialWorkQueue(::releaseStorage)
    private val processingMigrationQueue = SerialWorkQueue(::releaseStorage)
    @Volatile private var processingMigrationRun: UUID? = null
    @Volatile private var processingMigrationEngine: NativeProcessor? = null
    private var processingMigrationAttemptSource: Long? = null
    private var editorActive = true
    private var deferredMigrationPreview = false

    private fun <T> commitAdjustments(work: () -> T, publishBeforeUnlock: Boolean = false, completed: (Result<T>) -> Unit) {
        if (disposed || mutable.value.committingAdjustments) {
            completed(Result.failure(AdjustmentTransferException(AdjustmentFailure.DRAFT))); return
        }
        mutable.value = mutable.value.copy(committingAdjustments = true)
        adjustmentQueue.submit(work) { result -> viewModelScope.launch {
            if (!disposed) {
                if (!publishBeforeUnlock) mutable.value = mutable.value.copy(committingAdjustments = false)
                try { completed(result) }
                finally {
                    if (publishBeforeUnlock) {
                        mutable.value = mutable.value.copy(committingAdjustments = false)
                        resumeDeferredMigrationPreview()
                    }
                    finishAdjustmentClose(); collections.releaseDeferred()
                }
            }
        } }
    }

    init {
        viewModelScope.launch {
            state.map { it.rendering || it.operation != Operation.NONE || it.committingAdjustments }
                .distinctUntilChanged().collect { EditedPhotoPreviews.setForegroundBusy(photoPreviewOwner, it) }
        }
        editStore.initialResult.let { mutable.value = mutable.value.copy(saveState = it.state, saveError = it.message) }
        lookRevision = lookQueue.submit(LookWork.Load)
        batches.refreshPending()
        restoreSystemPhotos()
    }


    private fun submitRender(work: Work): Long {
        // 新任务替换取色时，队列可能不再回调旧请求；这里同步清除等待状态。
        if (work !is Work.HslProbe && hslInteraction.waiting) clearHslTarget()
        cameraHDRPreflightPending = work is Work.CameraHDRPreflight
        return queue.submit(work)
    }

    fun setHslTargetEnabled(enabled: Boolean) {
        cancelHslTarget()
        mutableHslTarget.value = mutableHslTarget.value.copy(enabled = enabled && mutable.value.draft?.group == AdjustmentGroup.HSL)
    }
    fun setHslTargetAxis(axis: Int) {
        require(axis in 0..2)
        cancelHslTarget(); mutableHslTarget.value = mutableHslTarget.value.copy(axis = axis)
    }
    fun beginHslTarget(x: Float, y: Float, keyDelta: Float? = null) {
        cancelHslTarget()
        val current = mutable.value; val target = mutableHslTarget.value
        val preview = acceptedHslPreview; val revision = acceptedHslRevision
        if (!target.enabled || !current.controlsEnabled || current.rendering || current.previewResizePending || current.error != null || current.draft?.group != AdjustmentGroup.HSL ||
            preview == null || revision == null || revision.source != sourceRevision || current.visibleEdits != acceptedHslSettings ||
            current.photo?.identity != preview.photo.identity || current.photo?.file != preview.photo.file) {
            mutableHslTarget.value = target.copy(notice = HslTargetAvailability.STALE); return
        }
        val token = hslInteraction.begin(current.visibleEdits.editingHsl, target.axis, revision)
        mutableHslTarget.value = target.copy(x = x, y = y, sample = null, waiting = true, notice = null)
        if (keyDelta != null) { hslInteraction.move(keyDelta); hslInteraction.end() }
        currentRevision = submitRender(Work.HslProbe(preview, current.visibleEdits, revision, token, target.axis, x, y))
    }
    private fun acceptHslTarget(value: WorkResult.HslProbe) {
        val work = value.request
        if (!hslInteraction.matches(work.token)) return
        val current = mutable.value; val target = mutableHslTarget.value
        if (!target.enabled || target.axis != work.axis || current.visibleEdits != work.before || current.draft?.group != AdjustmentGroup.HSL ||
            sourceRevision != work.revision.source || current.photo?.identity != work.preview.photo.identity) {
            cancelHslTarget(); mutableHslTarget.value = mutableHslTarget.value.copy(notice = HslTargetAvailability.STALE); return
        }
        val next = hslInteraction.accept(value.sample, work.token, acceptedHslRevision)
        mutableHslTarget.value = target.copy(sample = hslInteraction.selection, waiting = false,
            notice = if (next == null) hslInteraction.selection?.availability ?: HslTargetAvailability.STALE else null)
        if (next == null) return
        changeHslDraft(current.visibleEdits.withEditingHsl(next), true)
        hslHistoryActive = mutable.value.draft?.interacting == true
        if (!hslHistoryActive) { clearHslTarget(); mutableHslTarget.value = target.copy(notice = HslTargetAvailability.FAILED); return }
        if (!hslInteraction.dragging) endHslTarget()
    }
    fun moveHslTarget(delta: Float) {
        val next = hslInteraction.move(delta) ?: return
        if (!hslHistoryActive) return
        changeHslDraft(mutable.value.visibleEdits.withEditingHsl(next), true)
    }
    fun endHslTarget() {
        hslInteraction.end()
        if (hslHistoryActive) {
            hslHistoryActive = false
            changeHslDraft(mutable.value.visibleEdits, false)
        }
    }
    private fun changeHslDraft(edits: EditSettings, interactive: Boolean) {
        if (mutable.value.draft?.group == AdjustmentGroup.HSL)
            changeDraft(edits.canonicalZeros().synchronizeHDR(), interactive)
    }
    private fun clearHslTarget(disable: Boolean = false) {
        hslInteraction.cancel(); hslHistoryActive = false
        mutableHslTarget.value = mutableHslTarget.value.copy(enabled = !disable && mutableHslTarget.value.enabled,
            x = null, y = null, sample = null, waiting = false, notice = null)
    }
    fun cancelHslTarget() {
        val active = hslHistoryActive
        clearHslTarget()
        val draft = mutable.value.draft
        if (active && draft?.group == AdjustmentGroup.HSL && draft.interacting && draft.canUndo) {
            draftRevision += 1
            mutable.value = mutable.value.copy(draft = draft.undo().copy(redoSteps = emptyList()))
            renderDraft(false)
        }
    }
    fun rejectHslTarget() { cancelHslTarget(); mutableHslTarget.value = mutableHslTarget.value.copy(notice = HslTargetAvailability.OUTSIDE) }
    fun keyHslTarget(delta: Float) {
        val target = mutableHslTarget.value
        if (hslInteraction.dragging || target.x == null || target.y == null) return
        if (hslInteraction.waiting) { hslInteraction.accumulateReleased(delta); return }
        beginHslTarget(target.x, target.y, delta)
    }

    private fun accept(result: Result<WorkResult>) {
        cameraHDRPreflightPending = false
        result.fold({ value ->
            when (value) {
                is WorkResult.X3fImportFailure -> {
                    clearX3fRecovery()
                    clearUnusableImportRecovery()
                    failedX3fImport = value.retry
                    pendingPhotoImport.clear()
                    mutable.value = EditorStateReducer.renderFinished(mutable.value).copy(
                        error = failure(value.error), retryLegacyX3f = true, recoverUnusableRecord = false)
                }
                is WorkResult.UnusableEditImportFailure -> {
                    clearX3fRecovery()
                    clearUnusableImportRecovery()
                    failedUnusableImport = value.retry to value.identity
                    pendingPhotoImport.clear()
                    val message = if (value.error is com.rawlab.android.settings.HDRModeError.InvalidSettings)
                        text(R.string.hdr_unsupported)
                    else EditSaveResult(EditSaveState.FAILED, value.error, reading = true).message ?: failure(value.error)
                    mutable.value = EditorStateReducer.renderFinished(mutable.value).copy(
                        error = message, retryLegacyX3f = false, recoverUnusableRecord = true)
                }
                is WorkResult.MissingLook -> {
                    releasePreviousPhoto(value.photo)
                    adjustmentHistory.acceptSource(value.photo, value.importedRecord)
                    collections.opened(value.photo.identity.value)
                    mutable.value = EditorStateReducer.renderFinished(mutable.value).copy(photo = value.photo,
                        edits = value.edits, preview = null, exact = false,
                        saveState = EditSaveState.RESTORED, error = text(R.string.look_unavailable),
                        processingMigration = runCatching { editStore.processingMigration(value.photo.identity) }.getOrNull())
                    includeIndependentRecipeLook(value.edits)
                    if (value.persistOnImport) persist(value.photo, value.edits) { saved ->
                        mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message)
                    }
                }
                is WorkResult.HslProbe -> acceptHslTarget(value)
                is WorkResult.CameraHDRPreflight -> {
                    val request = value.request
                    val current = mutable.value
                    if (current.photo?.identity == request.photo.identity && sourceRevision == request.sourceRevision &&
                        current.edits == request.before && current.operation == Operation.NONE && current.draft == null)
                        edit(request.edits)
                }
                is WorkResult.Preview -> {
                    val request = value.request
                    if (request.draft) {
                        val current = mutable.value
                        val draft = current.draft ?: return@fold
                        val refitted = draft.acceptGeometryCanvas(value.pair.comparisonWidth / value.pair.comparisonHeight)
                        if (refitted != draft) draftRevision += 1
                        mutable.value = EditorStateReducer.renderFinished(current)
                            .copy(draft = refitted, preview = value.pair, exact = !request.interactive, error = null)
                        acceptedHslPreview = request
                        acceptedHslSettings = refitted.project(current.edits)
                        acceptedHslRevision = HslTargetRevision(sourceRevision, currentRevision)
                        return@fold
                    }
                    val imported = pendingPhotoImport.complete(request.photo.identity)
                    if (request.importing) {
                        releasePreviousPhoto(request.photo)
                        adjustmentHistory.acceptSource(request.photo, request.importedRecord)
                        collections.opened(request.photo.identity.value)
                    }
                    if (imported) usage.record(UsageEvent.PhotoImported)
                    val settings = if (!request.edits.customWb && value.pair.temperature.isFinite())
                        request.edits.copy(temperature = value.pair.temperature.coerceIn(2000f, 50000f),
                            tint = if (request.edits.recipeID == null) value.pair.tint.coerceIn(-150f, 150f) else request.edits.tint)
                    else request.edits
                    val alreadyDurable = durablePreview?.matches(request.photo.identity,
                        request.photo.file.absolutePath, sourceRevision, currentRevision, settings) == true
                    durablePreview = null
                    val navigationOnly = navigationPreview?.matches(request.photo.identity,
                        request.photo.file.absolutePath, sourceRevision, currentRevision, settings) == true
                    navigationPreview = null
                    if (settings != mutable.value.edits) editRevision += 1
                    val saved = when {
                        navigationOnly -> null
                        alreadyDurable -> EditSaveResult(EditSaveState.SAVED)
                        request.importing -> if (!editStore.available) editStore.initialResult else
                            EditSaveResult(if (request.restored) EditSaveState.RESTORED else EditSaveState.NONE)
                        request.interactive -> null
                        // 编辑已在动作提交处保存；预览回调只更新像素和目标相机派生值。
                        else -> null
                    }
                    mutable.value = EditorStateReducer.renderFinished(mutable.value).copy(
                        photo = request.photo, edits = settings, preview = value.pair,
                        exact = !request.interactive, error = null,
                        saveState = if (request.restored && saved?.state == EditSaveState.SAVED) EditSaveState.RESTORED else saved?.state ?: mutable.value.saveState,
                        saveError = if (saved == null) mutable.value.saveError else saved.message)
                    acceptedHslPreview = request
                    acceptedHslSettings = settings
                    acceptedHslRevision = HslTargetRevision(sourceRevision, currentRevision)
                    if (!request.interactive) viewModelScope.launch {
                        runCatching { photoPreviews.accept(request.photo, request.edits, value.pair.result) }
                    }
                    includeIndependentRecipeLook(settings)
                    if (request.persistOnImport) persist(request.photo, settings) { saved ->
                        mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message)
                    }
                    if (request.importing) mutable.value = mutable.value.copy(
                        processingMigration = runCatching { editStore.processingMigration(request.photo.identity) }.getOrNull())
                    if (request.importing && mutable.value.draft == null) restoreEditorDraft()
                    startProcessingMigrationIfNeeded()
                }
                WorkResult.Export -> {
                    mutable.value = mutable.value.copy(operation = Operation.NONE, message = text(R.string.export_done))
                    usage.record(UsageEvent.ExportCompleted)
                }
                is WorkResult.AutoExposure -> {
                    val current = mutable.value
                    mutable.value = EditorStateReducer.renderFinished(current)
                    if (editorActive && value.request.sourceRevision == sourceRevision && value.request.draftRevision == draftRevision &&
                        value.request.activationRevision == editorActivationRevision &&
                        current.photo?.identity == value.request.photo.identity && current.visibleEdits == value.request.edits) {
                        mutable.value = EditorStateReducer.renderFinished(current)
                        if (current.visibleEdits.exposure == value.exposure)
                            mutable.value = EditorStateReducer.renderFinished(current)
                        else edit(current.visibleEdits.copy(exposure = value.exposure))
                    }
                }
            }
            fadeSaveNotice()
        }, { error ->
            if (mutable.value.operation == Operation.IMPORT) pendingPhotoImport.clear()
            val finished = EditorStateReducer.renderFinished(mutable.value)
            mutable.value = if (isExportCancellation(error)) finished else finished.copy(error = failure(error))
        })
        collections.releaseDeferred()
        updatePreviewSize(requestedPreviewLongEdge)
    }

    private fun acceptLook(result: Result<LookResult>) {
        if (mutable.value.committingAdjustments) {
            val revision = lookRevision
            viewModelScope.launch {
                state.first { !it.committingAdjustments }
                if (!disposed && revision == lookRevision) acceptLook(result)
            }
            return
        }
        result.fold(::acceptLookValue, { error ->
            mutable.value = mutable.value.copy(operation = if (mutable.value.pendingLookImports.isEmpty()) Operation.NONE else Operation.IMPORT_LOOK,
                lookImportPreparing = false,
                error = text(R.string.look_storage_error) + "\n" + (error.message ?: error.javaClass.simpleName))
        })
        updatePreviewSize(requestedPreviewLongEdge)
    }

    private fun acceptLookValue(result: LookResult) {
        when (result) {
            is LookResult.Loaded -> {
                mutable.value = EditorStateReducer.looksLoaded(mutable.value, result.looks)
                recentLooks.ids.filter { it.startsWith("recipe-lut:") }.forEach { includeIndependentRecipeLook(EditSettings(film = it)) }
                includeIndependentRecipeLook(mutable.value.edits)
                updateRecentLooks()
            }
            is LookResult.Imported -> {
                val mutation = result.imported.lastOrNull()?.takeIf { lookImportSelectionContext == (sourceRevision to draftRevision) }
                    ?.let { EditorStateReducer.lookImported(mutable.value, it) }
                    ?: EditorMutation(mutable.value.copy(operation = Operation.NONE), null)
                val report = if (result.failures.isEmpty()) null else
                    AppStrings.format(R.string.look_import_summary, result.imported.size, result.failures.size) +
                        result.failures.joinToString("\n") { failure ->
                            val colorMessage = when (failure.colorReason) {
                                0 -> text(R.string.lut_missing_color)
                                1 -> text(R.string.lut_missing_reference)
                                2 -> text(R.string.lut_unsupported_color)
                                3 -> text(R.string.lut_conflicting_color)
                                9 -> text(R.string.lut_compatibility_changed)
                                else -> null
                            }
                            val message = colorMessage ?: failure.dcpReason?.let(::dcpFailureText) ?: failure.message
                            if (failure.invalid && colorMessage == null) message + "\n" + text(R.string.look_invalid_file) else message
                        }
                val pending = mutable.value.pendingLookImports + result.pending
                mutable.value = mutation.state.copy(looks = result.looks,
                    pendingLookImports = pending,
                    lookImportPreparing = false,
                    operation = if (pending.isEmpty()) Operation.NONE else Operation.IMPORT_LOOK,
                    lookImportReport = listOfNotNull(mutable.value.lookImportReport, report).takeIf { it.isNotEmpty() }?.joinToString("\n"),
                    error = if (mutation.blockedRecipeSelection) text(R.string.editor_reset_unrepresentable) else mutation.state.error,
                    message = if (result.imported.isEmpty()) null else text(R.string.look_imported))
                scheduleLookPreview(mutation.preview)
            }
            is LookResult.Renamed -> {
                val mutation = EditorStateReducer.lookRenamed(mutable.value, result.look)
                mutable.value = mutation.state.copy(looks = result.looks)
            }
            is LookResult.Deleted -> {
                val mutation = EditorStateReducer.lookDeleted(mutable.value, result.id)
                mutable.value = mutation.state.copy(looks = result.looks)
                updateRecentLooks()
                scheduleLookPreview(mutation.preview)
            }
            is LookResult.Failed -> {
                if (result.reload) lookRevision = lookQueue.submit(LookWork.Load)
                val title = text(if (result.reload) R.string.look_error else R.string.look_storage_error)
                mutable.value = mutable.value.copy(operation = if (mutable.value.pendingLookImports.isEmpty()) Operation.NONE else Operation.IMPORT_LOOK,
                    lookImportPreparing = false,
                    error = title + "\n" + (result.error.message ?: result.error.javaClass.simpleName))
            }
        }
    }

    private fun scheduleLookPreview(edits: EditSettings?) {
        val photo = mutable.value.photo ?: return
        if (edits == null) return
        if (mutable.value.draft != null) { renderDraft(false); return }
        pendingResetMigrationClear = null
        persist(photo, edits) { saved ->
            mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message)
            editRevision += 1
            durablePreview = null
            currentRevision = submitRender(Work.Preview(photo, edits, false, gpuMode(), edge = previewLongEdge))
        }
    }

    private fun dcpFailureText(reason: DcpFailureReason): String = text(when (reason) {
        DcpFailureReason.MALFORMED -> R.string.dcp_malformed
        DcpFailureReason.TOO_LARGE -> R.string.dcp_too_large
        DcpFailureReason.INVALID_CALIBRATION -> R.string.dcp_invalid_calibration
        DcpFailureReason.MISSING_TONE_CURVE -> R.string.dcp_missing_tone_curve
        DcpFailureReason.AUTOMATIC_BLACK -> R.string.dcp_automatic_black
        DcpFailureReason.TRIPLE_ILLUMINANT -> R.string.dcp_triple_illuminant
        DcpFailureReason.UNSUPPORTED_STAGES -> R.string.dcp_unsupported_stages
        DcpFailureReason.INVALID_TABLE -> R.string.dcp_invalid_table
        DcpFailureReason.INVALID_TONE_CURVE -> R.string.dcp_invalid_tone_curve
        DcpFailureReason.INVALID_EXPOSURE -> R.string.dcp_invalid_exposure
    })

    fun importPhoto(uri: Uri?) = importPhoto(uri) {}
    fun importPhoto(uri: Uri?, completed: (Boolean) -> Unit) {
        if (mutable.value.committingAdjustments) return completed(false)
        if (uri == null) {
            pendingPhotoImport.clear()
            return completed(false)
        }
        if (mutable.value.operation != Operation.NONE || mutable.value.draft != null) return completed(false)
        cancelAdjustmentInteraction()
        val current = mutable.value
        if (current.photo != null) {
            persist(current.photo, current.edits) { saved ->
                if (saved.state == EditSaveState.FAILED) {
                    mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message); completed(false)
                } else { startPhotoImport(uri); completed(true) }
            }
        } else { startPhotoImport(uri); completed(true) }
    }
    private fun clearX3fRecovery() {
        failedX3fImport?.let { if (it.ownsRetained) it.retained?.file?.delete() }
        failedX3fImport = null
        collections.releaseDeferred()
    }

    private fun clearUnusableImportRecovery() {
        failedUnusableImport?.first?.discardOwnedInput()
        failedUnusableImport = null
        collections.releaseDeferred()
    }

    fun dismissUnusableImportRecovery() {
        clearUnusableImportRecovery()
        if (mutable.value.recoverUnusableRecord) {
            mutable.value = mutable.value.copy(recoverUnusableRecord = false)
        }
    }

    fun resetUnusableImportRecord() {
        val pending = failedUnusableImport ?: return
        if (disposed || mutable.value.committingAdjustments || mutable.value.operation != Operation.NONE) return
        val (retry, identity) = pending
        commitAdjustments({
            runCatching { draftStore.clear(identity) }
            editStore.resetToUnmodified(identity)
        }) { result ->
            result.fold({
                if (failedUnusableImport?.first === retry) {
                    startPhotoImport(retry.uri, retry)
                }
            }, { error ->
                clearUnusableImportRecovery()
                val saveResult = EditSaveResult(EditSaveState.FAILED, error)
                mutable.value = mutable.value.copy(
                    recoverUnusableRecord = false,
                    saveState = saveResult.state,
                    saveError = saveResult.message,
                    error = saveResult.message ?: failure(error),
                )
            })
        }
    }

    private fun startPhotoImport(uri: Uri, retry: Work.Import? = null) {
        closeQuickPresets()
        if (retry !== failedX3fImport) clearX3fRecovery()
        if (retry !== failedUnusableImport?.first) clearUnusableImportRecovery()
        sourceRevision += 1
        closeAdjustmentOperation()
        durablePreview = null
        pendingPhotoImport.begin(PhotoIdentity(uri.toString()))
        mutable.value = mutable.value.copy(operation = Operation.IMPORT, rendering = true, error = null,
            retryLegacyX3f = false, recoverUnusableRecord = false,
            hdrCameraDraft = null, processingMigration = null)
        // closeAdjustmentOperation 会释放延迟文件，先建立导入保护再移交恢复引用。
        failedX3fImport = null
        failedUnusableImport = null
        previewResizeJob?.cancel()
        previewResizeJob = null
        previewLongEdge = 1600
        requestedPreviewLongEdge = 1600
        mutable.value = mutable.value.copy(previewResizePending = false)
        val retained = collections.photo(uri.toString())
        currentRevision = submitRender(retry?.copy(gpuMode = gpuMode()) ?: Work.Import(uri, gpuMode(), retained))
    }

    fun importLook(uri: Uri?) {
        if (uri != null) importLooks(listOf(uri))
    }

    fun importLooks(uris: List<Uri>) {
        if (uris.isEmpty() || mutable.value.operation != Operation.NONE ||
            (mutable.value.draft != null && mutable.value.draft?.group != AdjustmentGroup.LOOK)) return
        mutable.value = mutable.value.copy(operation = Operation.IMPORT_LOOK, error = null, lookImportReport = null)
        lookImportSelectionContext = sourceRevision to draftRevision
        lookRevision = lookQueue.submit(LookWork.Import(uris.toList()))
    }

    fun beginHDRLookImport(): Boolean {
        val current = mutable.value
        if (!current.controlsEnabled || !current.edits.isHDREditing || (current.draft != null && current.draft.group != AdjustmentGroup.LOOK)) return false
        pendingHDRLookImport = Triple(sourceRevision, editRevision, draftRevision)
        return true
    }

    fun finishHDRLookImport(uri: Uri?) {
        val expected = pendingHDRLookImport
        pendingHDRLookImport = null
        if (uri == null || expected != Triple(sourceRevision, editRevision, draftRevision)) return
        applyHDRLook { _, target -> target.copy(hdr = target.hdr!!.withLook(storage.importHDRLook(uri))) }
    }

    fun applyHDRSilver(master: Boolean) = applyHDRLook { photo, target ->
        val look = storage.installHDRSilver()
        if (master) {
            val payload = storage.hdrSilverMaster()
            require(payload[AdjustmentField.HDR_LOOK]?.hdrLook() == look)
            AdjustmentTransfer.prepare(payload, target, AdjustmentTransferContext(photo.identity.value,
                photo.inputKind == PhotoInputKind.RAW, sourceSupportsCameraHDR = photo.isCameraRawHDR,
                sourceIsProRAW = photo.hdrSource?.isProRAW == true, hdrLookDirectory = storage.hdrLookDirectory))
        } else target.copy(hdr = target.hdr!!.withLook(look))
    }

    private fun applyHDRLook(prepare: (ImportedPhoto, EditSettings) -> EditSettings) {
        val current = mutable.value
        val photo = current.photo ?: return
        if (!current.controlsEnabled || !current.edits.isHDREditing || (current.draft != null && current.draft.group != AdjustmentGroup.LOOK)) return
        val expected = Triple(sourceRevision, editRevision, draftRevision)
        mutable.value = current.copy(operation = Operation.IMPORT_LOOK, error = null)
        viewModelScope.launch {
            val imported = try {
                Result.success(kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { prepare(photo,current.visibleEdits) })
            }
                catch (error: kotlinx.coroutines.CancellationException) { throw error }
                catch (error: Exception) { Result.failure(error) }
            if (disposed || expected != Triple(sourceRevision, editRevision, draftRevision) || mutable.value.operation != Operation.IMPORT_LOOK) return@launch
            val ready = mutable.value.copy(operation = Operation.NONE)
            mutable.value = ready
            imported.onSuccess { settings ->
                edit(settings)
            }.onFailure {
                mutable.value = ready.copy(error = text(R.string.collection_look_unavailable))
            }
        }
    }

    fun dismissLookImportReport() { mutable.value = mutable.value.copy(lookImportReport = null) }

    fun resolveLookCompatibility(draft: LUTCompatibility?) {
        if (mutable.value.lookImportPreparing) return
        val pending = mutable.value.pendingLookImports.firstOrNull() as? PendingLookCompatibility ?: return
        if (draft != null && (!draft.canImport || draft.sourceHash != pending.draft.sourceHash)) return
        resolveLookImport(draft?.let { LookWork.Import(listOf(pending.uri), compatibility = it) })
    }

    fun resolveDcpImport(choices: DcpImportChoices?) {
        if (mutable.value.lookImportPreparing) return
        val pending = mutable.value.pendingLookImports.firstOrNull() as? PendingDcpImport ?: return
        resolveLookImport(choices?.let { LookWork.Import(listOf(pending.uri), dcp = it) })
    }

    private fun resolveLookImport(work: LookWork.Import?) {
        val remaining = mutable.value.pendingLookImports.drop(1)
        mutable.value = mutable.value.copy(pendingLookImports = remaining,
            lookImportPreparing = work != null,
            operation = if (work != null || remaining.isNotEmpty()) Operation.IMPORT_LOOK else Operation.NONE)
        if (work != null) lookRevision = lookQueue.submit(work)
    }

    fun renameLook(id: String, name: String) {
        if (mutable.value.committingAdjustments || mutable.value.operation != Operation.NONE || mutable.value.draft != null) return
        mutable.value = mutable.value.copy(operation = Operation.IMPORT_LOOK, error = null)
        lookRevision = lookQueue.submit(LookWork.Rename(id, name))
    }

    fun deleteLook(id: String) {
        if (mutable.value.committingAdjustments || mutable.value.operation != Operation.NONE || mutable.value.draft != null) return
        mutable.value = mutable.value.copy(operation = Operation.IMPORT_LOOK, error = null)
        lookRevision = lookQueue.submit(LookWork.Delete(id))
    }

    fun selectFilm(id: String): Boolean {
        val current = mutable.value
        if (!current.controlsEnabled || (current.draft != null && current.draft.group !in listOf(AdjustmentGroup.LOOK, AdjustmentGroup.RECIPE))) return false
        val candidate = try {
            current.visibleEdits.selectFilm(id, current.preview?.tint, current.preview?.temperature, current.photo!!.inputKind)
        } catch (_: IllegalArgumentException) {
            mutable.value = current.copy(error = AppStrings.text(if (current.preview == null)
                R.string.editor_reset_missing_wb else R.string.editor_reset_unrepresentable))
            return false
        }
        edit(candidate, false)
        return mutable.value.visibleEdits == candidate
    }

    fun edit(requested: EditSettings, interactive: Boolean = false, clearProcessingMigration: Boolean = false) {
        val edits = requested.canonicalZeros().synchronizeHDR()
        cancelHslTarget()
        val current = mutable.value
        if (!current.controlsEnabled) return
        if (current.draft != null) { changeDraft(edits, interactive); return }
        if (mutableQuickPreset.value.phase == QuickPresetPhase.PREPARING) cancelQuickPreset()
        if (interactive) {
            val saved = adjustmentHistory.begin(current.photo!!, current.edits, sourceRevision)
            if (saved.state == EditSaveState.FAILED) {
                mutable.value = current.copy(saveState = saved.state, saveError = saved.message)
                return
            }
        } else if (!adjustmentHistory.finish(current.photo!!, sourceRevision)) return
        val look = current.looks.firstOrNull { it.id == edits.film }
        if (!edits.isHDREditing && look?.managed == true && !look.available) {
            mutable.value = current.copy(error = text(R.string.look_unavailable))
            return
        }
        if (!edits.denoise.enabled && previewResizeJob != null) {
            previewResizeJob?.cancel()
            previewResizeJob = null
            previewLongEdge = requestedPreviewLongEdge
        }
        durablePreview = null
        if (edits != current.edits) editRevision += 1
        pendingResetMigrationClear = if (!interactive && clearProcessingMigration) sourceRevision to edits else null
        mutable.value = current.copy(edits = edits, rendering = true, exact = false, error = null, matchingProcessing = false,
            previewResizePending = previewResizeJob != null,
            hdrCameraDraft = current.hdrCameraDraft?.retainedFor(edits.hdr?.cameraSettings))
        currentRevision = submitRender(Work.Preview(current.photo!!, edits, interactive, gpuMode(),
            edge = interactivePreviewSize.edge(previewLongEdge, interactive, android.os.SystemClock.uptimeMillis())))
        if (!interactive) persist(current.photo, edits, clearProcessingMigration = clearProcessingMigration) { saved ->
            mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message)
            fadeSaveNotice()
        }
    }

    fun updatePreviewSize(edge: Int) {
        var current = mutable.value
        if (disposed || current.photo == null || edge !in 1..1600) return
        if (current.draft != null) {
            if (current.draft?.group == AdjustmentGroup.HSL) cancelHslTarget()
            return
        }
        if (edge == requestedPreviewLongEdge && (edge == previewLongEdge || previewResizeJob != null)) return
        if (cameraHDRPreflightPending) {
            // 视口变化保留最新尺寸，不能用旧 SDR 预览替换尚未完成的 HDR 能力预检。
            requestedPreviewLongEdge = edge
            return
        }
        cancelHslTarget()
        current = mutable.value
        requestedPreviewLongEdge = edge
        if (!current.controlsEnabled) return
        previewResizeJob?.cancel()
        previewResizeJob = null
        mutable.value = current.copy(previewResizePending = false)
        if (edge == previewLongEdge) return
        if (!current.edits.denoise.enabled) {
            previewLongEdge = edge
            renderCommittedForNavigation()
            return
        }
        mutable.value = mutable.value.copy(previewResizePending = true)
        previewResizeJob = viewModelScope.launch {
            delay(200)
            previewResizeJob = null
            mutable.value = mutable.value.copy(previewResizePending = false)
            if (!mutable.value.controlsEnabled) return@launch
            previewLongEdge = requestedPreviewLongEdge
            renderCommittedForNavigation()
        }
    }

    fun beginDraft(group: AdjustmentGroup) {
        if (mutableQuickPreset.value.phase == QuickPresetPhase.PREPARING) cancelQuickPreset()
        val current = mutable.value
        if (!current.canExport) return
        previewResizeJob?.cancel()
        previewResizeJob = null
        val pair = current.preview ?: return
        draftRevision += 1
        failedDraftSave = false
        draftSaveBaseline = current.saveState to current.saveError
        mutable.value = current.copy(draft = AdjustmentDraft.begin(group, current.edits, pair.originalAspect,
            pair.comparisonWidth / pair.comparisonHeight), previewResizePending = false, error = null)
        if (group == AdjustmentGroup.GEOMETRY && current.edits.geometry != current.edits.geometry.uncropped()) renderDraft(false)
    }

    fun changeDraft(edits: EditSettings, interactive: Boolean = false) {
        val current = mutable.value
        val previous = current.draft ?: return
        if (!current.controlsEnabled) return
        val next = previous.update(edits, interactive)
        if (next == previous && (interactive || current.exact)) return
        draftRevision += 1
        mutable.value = current.copy(draft = next)
        // Crop-only edits are an overlay on the full transformed preview, not a RAW render.
        if (previous.group == AdjustmentGroup.GEOMETRY &&
            previous.value.geometry.uncropped() == next.value.geometry.uncropped() && (interactive || current.exact)) return
        renderDraft(interactive)
    }

    private fun renderDraft(interactive: Boolean) {
        val current = mutable.value
        val draft = current.draft ?: return
        val photo = current.photo ?: return
        val edits = draft.project(current.edits).let {
            if (draft.group == AdjustmentGroup.GEOMETRY) it.copy(geometry = it.geometry.uncropped()) else it
        }
        mutable.value = current.copy(rendering = true, exact = false, error = null)
        currentRevision = submitRender(Work.Preview(photo, edits, interactive, gpuMode(),
            edge = interactivePreviewSize.edge(1600, interactive, android.os.SystemClock.uptimeMillis()), draft = true))
    }

    fun undoDraft() = changeDraftHistory { it.undo() }
    fun redoDraft() = changeDraftHistory { it.redo() }

    private fun changeDraftHistory(change: (AdjustmentDraft) -> AdjustmentDraft) {
        val current = mutable.value
        val draft = current.draft ?: return
        if (!current.controlsEnabled) return
        val next = change(draft)
        if (next == draft) return
        draftRevision += 1
        mutable.value = current.copy(draft = next)
        renderDraft(false)
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
        if (disposed || !current.draftReady) return completed(false)
        if (current.draft?.changed != true) { discardDraft(); completed(true); return }
        val photo = current.photo ?: return completed(false)
        val edits = current.draft!!.project(current.edits)
        previewResizeJob?.cancel()
        previewResizeJob = null
        pendingResetMigrationClear = null
        persist(photo, edits) { saved ->
            if (saved.state == EditSaveState.FAILED) {
                failedDraftSave = true
                mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message)
                completed(false)
            } else {
                failedDraftSave = false; draftSaveBaseline = null
                if (current.draft.group == AdjustmentGroup.HSL) clearHslTarget(disable = true)
                runCatching { draftStore.clear(photo.identity) }
                editRevision += 1; draftRevision += 1
                mutable.value = mutable.value.copy(edits = edits, draft = null, rendering = true, exact = false,
                    previewResizePending = false, error = null, saveState = saved.state, saveError = saved.message)
                currentRevision = submitRender(Work.Preview(photo, edits, false, gpuMode(), edge = previewLongEdge))
                durablePreview = EditorDurablePreview(photo.identity, photo.file.absolutePath, sourceRevision, currentRevision, edits)
                completed(true)
            }
        }
    }

    fun discardDraft() {
        if (mutable.value.committingAdjustments) return
        val current = mutable.value
        val draft = current.draft ?: return
        if (draft.group == AdjustmentGroup.HSL) clearHslTarget(disable = true)
        current.photo?.let { runCatching { draftStore.clear(it.identity) } }
        val saved = draftSaveBaseline.takeIf { failedDraftSave }
        failedDraftSave = false
        draftSaveBaseline = null
        draftRevision += 1
        val committed = current.copy(draft = null, saveState = saved?.first ?: current.saveState,
            saveError = if (saved != null) saved.second else current.saveError)
        mutable.value = committed
        val shown = draft.project(current.edits).let {
            if (draft.group == AdjustmentGroup.GEOMETRY) it.copy(geometry = it.geometry.uncropped()) else it
        }
        // 草稿的裁切框可能只改覆盖层；只有实际预览不同或尚未收敛时才恢复提交预览。
        if (shown == current.edits && current.exact && !current.rendering && current.error == null) return
        renderCommittedForNavigation()
    }

    private fun renderCommittedForNavigation() {
        cancelHslTarget()
        val current = mutable.value
        val photo = current.photo ?: return
        deferredMigrationPreview = false
        mutable.value = current.copy(rendering = true, exact = false, error = null)
        currentRevision = submitRender(Work.Preview(photo, current.edits, false, gpuMode(), edge = previewLongEdge))
        navigationPreview = EditorDurablePreview(photo.identity, photo.file.absolutePath, sourceRevision,
            currentRevision, current.edits)
    }

    fun retry() {
        failedX3fImport?.let { startPhotoImport(it.uri, it); return }
        if (mutable.value.draft != null) renderDraft(false)
        else if (mutable.value.controlsEnabled) renderCommittedForNavigation()
    }
    fun autoExposure() {
        val current = mutable.value
        if (!current.controlsEnabled || current.preview == null || current.rendering ||
            (current.draft != null && current.draft.group != AdjustmentGroup.EXPOSURE)) return
        mutable.value = current.copy(rendering = true, error = null)
        currentRevision = submitRender(Work.AutoExposure(current.photo!!, current.visibleEdits, gpuMode(), sourceRevision, draftRevision, editorActivationRevision))
    }
    fun retrySave(completed: (Boolean) -> Unit = {}) {
        if (mutable.value.committingAdjustments) return completed(false)
        val photo = mutable.value.photo
        fun accept(saved: EditSaveResult) {
            mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message)
            fadeSaveNotice(); completed(saved.state != EditSaveState.FAILED)
        }
        if (photo != null && adjustmentHistory.snapshot().loaded == null) {
            val edits = mutable.value.edits
            commitAdjustments({ adjustmentHistory.recoverSource(photo) }) { result ->
                result.fold({ record ->
                    if (failedDraftSave && mutable.value.draft != null) { applyDraft(completed); return@fold }
                    if (AdjustmentTransfer.sameAdjustments(edits, photo.defaultEditSettings(), photo.inputKind == PhotoInputKind.RAW)) {
                        pendingResetMigrationClear = null
                        val restored = record.settings ?: photo.defaultEditSettings()
                        if (restored != edits) editRevision += 1
                        mutable.value = mutable.value.copy(edits = restored)
                        includeIndependentRecipeLook(restored)
                        renderCommittedForNavigation()
                        accept(EditSaveResult(if (record.settings == null) EditSaveState.NONE else EditSaveState.RESTORED))
                    } else persist(photo, edits, ::accept)
                }, { accept(EditSaveResult(EditSaveState.FAILED, it, reading = true)) })
            }
        } else if (failedDraftSave && mutable.value.draft != null) applyDraft(completed)
        else if (photo != null) persist(photo, mutable.value.edits, ::accept)
        else commitAdjustments(editStore::reopen) { accept(it.getOrElse { error -> EditSaveResult(EditSaveState.FAILED, error, reading = true) }) }
    }
    fun prepareReset(scope: EditorResetScope): EditorResetPreparation {
        val current = mutable.value
        val session = resetSession()
        if (disposed || session == null || !current.controlsEnabled || !current.exact ||
            current.rendering || current.previewResizePending || current.error != null) {
            return EditorResetPreparation(EditorResetResult.Blocked("The current preview is not ready"))
        }
        return EditorResetTransaction.prepare(scope, session)
    }

    fun commitReset(prepared: PreparedEditorReset): Boolean {
        val current = mutable.value
        val session = resetSession() ?: return false
        if (disposed || !current.controlsEnabled || !current.exact || current.rendering ||
            current.previewResizePending || current.error != null || !prepared.matches(session)) return false
        prepared.draftCandidate?.let { next ->
            if (next == current.draft) return false
            draftRevision += 1
            mutable.value = current.copy(draft = next)
            renderDraft(false)
            return true
        }
        val previousRequest = currentRevision
        edit(prepared.result.candidate, clearProcessingMigration = prepared.scope == EditorResetScope.All)
        if (currentRevision == previousRequest) return false
        return true
    }

    private val resetRecipeIds by lazy { MasterRecipe.load(getApplication()).map { it.id }.toSet() }

    private fun resetSession(): EditorResetSession? {
        val current = mutable.value
        val photo = current.photo ?: return null
        val shot = current.preview?.takeIf { it.temperature.isFinite() && it.tint.isFinite() }
            ?.let { AsShotWhiteBalance(it.temperature, it.tint) }
        val context = EditorResetContext(photo.inputKind, EditSettings().effectiveFor(photo.inputKind), shot, resetRecipeIds)
        return EditorResetSession(photo.identity, photo.file.absolutePath, sourceRevision, editRevision,
            current.edits, current.draft, draftRevision, context)
    }


    private var saveNotice: kotlinx.coroutines.Job? = null
    private fun fadeSaveNotice() {
        saveNotice?.cancel()
        if (mutable.value.saveState !in setOf(EditSaveState.SAVED, EditSaveState.RESTORED)) return
        saveNotice = viewModelScope.launch {
            kotlinx.coroutines.delay(3000)
            if (mutable.value.saveState in setOf(EditSaveState.SAVED, EditSaveState.RESTORED)) mutable.value = mutable.value.copy(saveState = EditSaveState.NONE)
        }
    }

    private fun cancelProcessingMigration(skipCurrentSource: Boolean = false) {
        if (skipCurrentSource) processingMigrationAttemptSource = sourceRevision
        processingMigrationRun = null
        processingMigrationEngine?.cancelPreview()
        if (mutable.value.matchingProcessing) mutable.value = mutable.value.copy(matchingProcessing = false)
    }

    fun setEditorActive(active: Boolean) {
        if (editorActive != active) editorActivationRevision += 1
        editorActive = active
        if (!active) cancelProcessingMigration(skipCurrentSource = true)
        else {
            resumeDeferredMigrationPreview()
            startProcessingMigrationIfNeeded()
        }
    }

    private fun resumeDeferredMigrationPreview() {
        val current = mutable.value
        if (!disposed && editorActive && deferredMigrationPreview && !current.committingAdjustments &&
            !current.rendering && current.operation == Operation.NONE && current.draft == null) {
            renderCommittedForNavigation()
        }
    }

    private fun startProcessingMigrationIfNeeded() {
        val current = mutable.value
        val photo = current.photo ?: return
        val history = adjustmentHistory.snapshot()
        val expected = history.loaded ?: return
        val original = expected.settings ?: return
        if (disposed || !editorActive || current.rendering || !current.exact || !current.controlsEnabled || current.draft != null ||
            current.saveState == EditSaveState.FAILED || current.edits.isHDREditing || current.edits.recipeID != null ||
            current.edits.processing.version >= 3 || history.interacting ||
            processingMigrationAttemptSource == sourceRevision) return
        if (current.processingMigration?.shouldAttempt(original, original.processing.version) == false) return
        val validation = runCatching { history.committedValidation(photo, current.edits) }.getOrNull() ?: return
        val source = sourceRevision; val edit = editRevision; val snapshot = current.edits
        val mode = gpuMode(); val ticket = UUID.randomUUID()
        processingMigrationAttemptSource = source
        processingMigrationRun = ticket
        mutable.value = current.copy(matchingProcessing = true)
        processingMigrationQueue.submit({
            validation()
            if (processingMigrationRun != ticket) throw AdjustmentOperationExpiredException()
            NativeProcessor(mode, storage.lensDatabase()).use { engine ->
                val generation = engine.cancellationGeneration()
                processingMigrationEngine = engine
                try {
                    if (processingMigrationRun != ticket) throw AdjustmentOperationExpiredException()
                    val outcome = engine.migrateProcessing(photo.file, storage.lookPath(original), original, photo.inputKind, generation)
                    validation()
                    outcome
                } finally { if (processingMigrationEngine === engine) processingMigrationEngine = null }
            }
        }) { result -> renderDelivery.post {
            if (processingMigrationRun == null && mutable.value.matchingProcessing)
                mutable.value = mutable.value.copy(matchingProcessing = false)
            if (disposed || processingMigrationRun != ticket || sourceRevision != source || editRevision != edit ||
                mutable.value.photo?.identity != photo.identity || mutable.value.edits != snapshot) return@post
            mutable.value = mutable.value.copy(matchingProcessing = false)
            val outcome = result.getOrNull() ?: return@post
            val postHistory = adjustmentHistory.snapshot()
            if (mutable.value.committingAdjustments || postHistory.sourceToken != history.sourceToken || postHistory.interacting ||
                mutable.value.draft != null || mutable.value.operation != Operation.NONE) return@post
            commitAdjustments({
                if (processingMigrationRun != ticket || sourceRevision != source || editRevision != edit)
                    throw AdjustmentOperationExpiredException()
                validation()
                val candidate = outcome.candidate(original)
                val receipt = ProcessingMigrationReceipt(
                    if (candidate == null) ProcessingMigrationStatus.KEPT else ProcessingMigrationStatus.MIGRATED,
                    original, outcome.quality)
                val saved = editStore.commitProcessingMigration(expected, candidate, outcome.quality)
                editStore.adjustmentSession?.adoptProcessingMigration(saved)
                saved to receipt
            }, publishBeforeUnlock = true) { committed ->
                if (sourceRevision != source || editRevision != edit || mutable.value.edits != snapshot ||
                    mutable.value.photo?.identity != photo.identity || mutable.value.photo?.file != photo.file) return@commitAdjustments
                committed.onSuccess { (saved, receipt) ->
                    // 成功返回即已落盘；取消可以阻止排队保存，不能丢弃已提交状态。
                    if (!adjustmentHistory.acceptSaved(photo, saved, history.sourceToken)) return@onSuccess
                    val migrated = receipt.status == ProcessingMigrationStatus.MIGRATED
                    editRevision += 1
                    if (migrated) {
                        currentRevision = queue.invalidate()
                        previewResizeJob?.cancel(); previewResizeJob = null
                        durablePreview = null; navigationPreview = null
                        deferredMigrationPreview = true
                    }
                    mutable.value = mutable.value.copy(edits = if (migrated) saved.settings ?: snapshot else snapshot,
                        processingMigration = receipt,
                        rendering = if (migrated) false else mutable.value.rendering,
                        exact = if (migrated) false else mutable.value.exact,
                        previewResizePending = if (migrated) false else mutable.value.previewResizePending,
                        matchingProcessing = false, saveState = EditSaveState.SAVED, saveError = null)
                }.onFailure { error ->
                    if (processingMigrationRun == ticket)
                        mutable.value = mutable.value.copy(saveError = EditSaveResult(EditSaveState.FAILED, error).message)
                }
            }
        } }
    }

    fun rollbackProcessingMigration() {
        val current = mutable.value
        val photo = current.photo ?: return
        val history = adjustmentHistory.snapshot()
        val expected = history.loaded ?: return
        if (current.processingMigration?.status != com.rawlab.android.settings.ProcessingMigrationStatus.MIGRATED ||
            !current.controlsEnabled || current.draft != null || history.interacting) return
        val validation = runCatching { history.committedValidation(photo, current.edits) }.getOrNull() ?: return
        cancelProcessingMigration()
        val source = sourceRevision; val edit = editRevision
        commitAdjustments({
            if (sourceRevision != source || editRevision != edit) throw AdjustmentOperationExpiredException()
            validation()
            val saved = editStore.rollbackProcessingMigration(expected)
            editStore.adjustmentSession?.adoptProcessingMigration(saved)
            saved to editStore.processingMigration(photo.identity)
        }) { result ->
            if (sourceRevision != source || mutable.value.photo?.identity != photo.identity) return@commitAdjustments
            result.onSuccess { (saved, receipt) ->
                if (!adjustmentHistory.acceptSaved(photo, saved, history.sourceToken)) return@onSuccess
                editRevision += 1
                mutable.value = mutable.value.copy(edits = requireNotNull(saved.settings), processingMigration = receipt,
                    saveState = EditSaveState.SAVED, saveError = null)
                renderCommittedForNavigation()
            }.onFailure { error -> mutable.value = mutable.value.copy(saveError = EditSaveResult(EditSaveState.FAILED, error).message) }
        }
    }

    private fun gpuMode() = if (mutable.value.gpuEnabled) NativeProcessor.AUTO else NativeProcessor.CPU

    private fun persist(photo: ImportedPhoto, edits: EditSettings, completed: (EditSaveResult) -> Unit) =
        persist(photo, edits, clearProcessingMigration = false, completed = completed)

    private fun persist(photo: ImportedPhoto, edits: EditSettings, clearProcessingMigration: Boolean,
        completed: (EditSaveResult) -> Unit) {
        val previousFilm = adjustmentHistory.snapshot().loaded?.settings?.film
        val source = sourceRevision
        val synced = edits.synchronizeHDR()
        val clearsMigration = clearProcessingMigration || pendingResetMigrationClear == (source to synced)
        if (!clearsMigration) pendingResetMigrationClear = null
        commitAdjustments({ adjustmentHistory.commit(photo, synced, clearProcessingMigration = clearsMigration) }) { result ->
            val saved = result.getOrElse { EditSaveResult(EditSaveState.FAILED, it) }
            if (saved.state == EditSaveState.SAVED) {
                if (clearsMigration && pendingResetMigrationClear == (source to synced)) pendingResetMigrationClear = null
                if (clearsMigration && source == sourceRevision && mutable.value.photo?.identity == photo.identity) {
                    mutable.value = mutable.value.copy(processingMigration = null)
                }
                if (source == sourceRevision && mutable.value.photo?.identity == photo.identity &&
                    mutable.value.edits.film == edits.film && edits.recipeID == null && previousFilm != edits.film) updateRecentLooks(edits.film)
            }
            completed(saved)
            if (saved.state == EditSaveState.SAVED && source == sourceRevision) cacheAcceptedPhotoPreview()
        }
    }

    private fun cacheAcceptedPhotoPreview() {
        val current = mutable.value
        val request = acceptedHslPreview ?: return
        val pair = current.preview ?: return
        if (!current.exact || current.draft != null || request.interactive || current.photo?.identity != request.photo.identity) return
        viewModelScope.launch { runCatching { photoPreviews.accept(request.photo, request.edits, pair.result) } }
    }

    private fun updateRecentLooks(applied: String? = null) {
        val available = mutable.value.looks.filter { it.available }.mapTo(mutableSetOf()) { it.id }
        if (applied == null) recentLooks.prune(available) else recentLooks.record(applied, available)
        if (mutable.value.recentLookIds == recentLooks.ids) return
        mutable.value = mutable.value.copy(recentLookIds = recentLooks.ids)
        lookPreferences.edit().putString("recent", org.json.JSONArray(recentLooks.ids).toString()).apply()
    }

    private fun releasePreviousPhoto(next: ImportedPhoto) {
        val previous = mutable.value.photo ?: return
        if (previous.file != next.file && !collections.owns(previous.file)) previous.file.delete()
    }

    fun cancelAdjustmentInteraction() {
        cancelProcessingMigration(skipCurrentSource = true)
        if (mutable.value.committingAdjustments) return
        clearHslTarget()
        val restored = adjustmentHistory.cancel(mutable.value.photo, sourceRevision) ?: return
        pendingResetMigrationClear = null
        editRevision += 1
        mutable.value = mutable.value.copy(edits = restored)
        renderCommittedForNavigation()
    }

    fun undoAdjustment(completed: (List<AdjustmentOutcome>) -> Unit = {}) = performAdjustmentHistory(undo = true, completed = completed)
    fun redoAdjustment(completed: (List<AdjustmentOutcome>) -> Unit = {}) = performAdjustmentHistory(undo = false, completed = completed)
    fun performAdjustmentHistory(undo: Boolean, transactionID: UUID? = null, wholeTransaction: Boolean = false,
        skipping: Set<String> = emptySet(), completed: (List<AdjustmentOutcome>) -> Unit = {}) {
        val session = adjustmentHistory.session ?: return completed(emptyList())
        val photo = mutable.value.photo ?: return completed(emptyList())
        val id = transactionID ?: session.photoHistoryID(photo.identity, undo) ?: return completed(emptyList())
        executeAdjustmentHistory(EditorAdjustmentHistoryRequest(id, if (wholeTransaction) null else photo.identity, undo), skipping, completed)
    }
    fun executeAdjustmentHistory(request: EditorAdjustmentHistoryRequest, skipping: Set<String> = emptySet(),
        completed: (List<AdjustmentOutcome>) -> Unit = {}) {
        val session = adjustmentHistory.session ?: return completed(emptyList())
        val expectedSourceToken = adjustmentHistory.snapshot().sourceToken
        commitAdjustments({
            val outcomes = if (request.photo == null) {
                if (request.undo) session.undoTransaction(request.transactionID, skipping, ::adjustmentTargetIsCurrent)
                else session.redoTransaction(request.transactionID, skipping, ::adjustmentTargetIsCurrent)
            } else if (request.undo) session.undoPhoto(request.photo, request.transactionID, ::adjustmentTargetIsCurrent)
            else session.redoPhoto(request.photo, request.transactionID, ::adjustmentTargetIsCurrent)
            outcomes
        }) { outcome ->
            val results = outcome.getOrElse { listOf(AdjustmentOutcome(request.photo?.value.orEmpty(), AdjustmentStatus.FAILED, error = it)) }
            val accepted = acceptAdjustmentOutcomes(results, expectedSourceToken = expectedSourceToken)
            mutableAdjustmentTransfer.value = mutableAdjustmentTransfer.value.copy(historyRequest = request, historyResults = accepted)
            completed(accepted)
        }
    }
    private fun adjustmentTargetIsCurrent(identity: String): Boolean =
        adjustmentTargetIsCurrent(identity, adjustmentHistory.snapshot())
    private fun adjustmentTargetIsCurrent(identity: String, history: EditorAdjustmentHistory.Snapshot): Boolean {
        val current = mutable.value
        if (current.photo?.identity?.value != identity) return true
        return current.operation == Operation.NONE && current.draft == null && !history.interacting &&
            current.saveState != EditSaveState.FAILED
    }
    internal fun acceptAdjustmentOutcomes(
        results: List<AdjustmentOutcome>,
        cachedTargets: Set<String> = emptySet(),
        expectedSourceToken: Long? = null,
    ): List<AdjustmentOutcome> {
        val current = mutable.value
        val photo = current.photo
        val history = adjustmentHistory.snapshot()
        var restored: EditSettings? = null
        if (photo != null && adjustmentTargetIsCurrent(photo.identity.value, history)) {
            val token = expectedSourceToken ?: history.sourceToken
            for (result in results) {
                val saved = result.saved ?: continue
                // 旧的成功回执不再接管当前照片；它可能已被用户撤销或继续编辑。
                if (result.targetID != photo.identity.value || result.targetID in cachedTargets ||
                    result.status !in setOf(AdjustmentStatus.APPLIED, AdjustmentStatus.UNCHANGED)) continue
                if (adjustmentHistory.acceptSaved(photo, saved, token)) restored = saved.settings ?: photo.defaultEditSettings()
            }
        }
        mutable.value = current.copy(adjustmentRevision = current.adjustmentRevision + 1)
        if (restored != null) {
            pendingResetMigrationClear = null
            if (!mutableQuickPreset.value.busy) {
                quickPresetGeneration = UUID.randomUUID()
                mutableQuickPreset.value = EditorQuickPresetState(visible = mutableQuickPreset.value.visible)
            }
            editRevision += 1
            mutable.value = mutable.value.copy(edits = restored, saveState = EditSaveState.SAVED, saveError = null, error = null,
                hdrCameraDraft = mutable.value.hdrCameraDraft?.retainedFor(restored.hdr?.cameraSettings))
            includeIndependentRecipeLook(restored)
            if (restored.recipeID == null && current.edits.film != restored.film) updateRecentLooks(restored.film)
            renderCommittedForNavigation()
        }
        return results
    }

    private fun includeIndependentRecipeLook(settings: EditSettings) {
        if (!settings.film.startsWith("recipe-lut:") || mutable.value.looks.any { it.id == settings.film }) return
        val id = settings.film.removePrefix("recipe-lut:")
        val recipe = MasterRecipe.load(getApplication()).firstOrNull { it.id == id } ?: return
        mutable.value = mutable.value.copy(looks = mutable.value.looks + LookChoice(settings.film, "${recipe.localizedName} LUT", managed = false))
    }

    fun copyAdjustments(scope: AdjustmentScope): AdjustmentPayload? {
        val current = mutable.value
        val photo = current.photo ?: return null
        if (!current.controlsEnabled || current.draft != null || adjustmentHistory.snapshot().interacting) return null
        if (current.saveState == EditSaveState.FAILED) return null
        return try {
            val captured = adjustmentHistory.session!!.copy(scope, current.edits,
                AdjustmentTransferContext(photo.identity.value, photo.inputKind == PhotoInputKind.RAW,
                    builtinLookIDs = storage.builtinLookIDs(), cameraTemperature = current.preview?.temperature,
                    cameraTint = current.preview?.tint, sourceSupportsCameraHDR = photo.isCameraRawHDR,
                    sourceIsProRAW = photo.hdrSource?.isProRAW == true))
            adjustmentClipboardSourceName = photo.name
            mutable.value = current.copy(adjustmentRevision = current.adjustmentRevision + 1)
            captured
        } catch (error: Exception) {
            mutableAdjustmentTransfer.value = mutableAdjustmentTransfer.value.copy(error = adjustmentErrorMessage(error))
            null
        }
    }

    fun capturePresetAdjustments(scope: AdjustmentScope, completed: (Result<AdjustmentPayload>) -> Unit) {
        val current = mutable.value
        val photo = current.photo
        if (disposed || current.committingAdjustments || photo == null || !adjustmentTargetIsCurrent(photo.identity.value) || adjustmentHistory.session == null) {
            completed(Result.failure(AdjustmentTransferException(AdjustmentFailure.DRAFT))); return
        }
        val context = AdjustmentTransferContext(photo.identity.value, photo.inputKind == PhotoInputKind.RAW,
            builtinLookIDs = storage.builtinLookIDs(), cameraTemperature = current.preview?.temperature,
            cameraTint = current.preview?.tint, sourceSupportsCameraHDR = photo.isCameraRawHDR,
            sourceIsProRAW = photo.hdrSource?.isProRAW == true)
        commitAdjustments({
            adjustmentHistory.snapshot().validateCommitted(photo, current.edits)
            AdjustmentTransfer.capture(scope, current.edits, context)
        }, completed = completed)
    }

    fun previewAdjustmentPayload(scope: AdjustmentScope): Result<AdjustmentPayload> = runCatching {
        val current = mutable.value
        val photo = current.photo ?: throw AdjustmentTransferException(AdjustmentFailure.DRAFT)
        val history = adjustmentHistory.snapshot()
        val record = history.loaded ?: throw AdjustmentTransferException(AdjustmentFailure.DRAFT)
        if (disposed || current.committingAdjustments || record.identity != photo.identity || !adjustmentTargetIsCurrent(photo.identity.value, history))
            throw AdjustmentTransferException(AdjustmentFailure.DRAFT)
        AdjustmentTransfer.previewCapture(scope, current.edits,
            record.settings ?: photo.defaultEditSettings(),
            AdjustmentTransferContext(photo.identity.value, photo.inputKind == PhotoInputKind.RAW,
                builtinLookIDs = storage.builtinLookIDs(), cameraTemperature = current.preview?.temperature,
                cameraTint = current.preview?.tint, sourceSupportsCameraHDR = photo.isCameraRawHDR,
                sourceIsProRAW = photo.hdrSource?.isProRAW == true))
    }

    fun adjustmentSummaryLookName(kind: String, id: String): String? {
        if (kind == "recipe" || kind == "recipe_lut")
            return MasterRecipe.load(getApplication()).firstOrNull { it.id == id }?.localizedName
        val localID = if (kind == "builtin") storage.builtinLookIDs()[id] ?: return null else id
        return mutable.value.looks.firstOrNull { it.id == localID && it.available }?.name
    }

    fun prepareAdjustmentPaste(payload: AdjustmentPayload, uris: List<Uri>,
        action: AdjustmentHistoryTransaction.Action = AdjustmentHistoryTransaction.Action.PASTE) {
        if (disposed || mutable.value.committingAdjustments) {
            mutableAdjustmentTransfer.value = mutableAdjustmentTransfer.value.copy(
                error = adjustmentErrorMessage(AdjustmentTransferException(AdjustmentFailure.DRAFT)))
            return
        }
        closeAdjustmentOperation()
        startAdjustmentPreparation(payload, uris, action)
    }
    private fun startAdjustmentPreparation(payload: AdjustmentPayload, uris: List<Uri>,
        action: AdjustmentHistoryTransaction.Action, completed: (Result<PreparedAdjustmentTransfer>) -> Unit = {}) {
        adjustmentCloseRequested = false
        val generation = UUID.randomUUID()
        adjustmentPreparationGeneration = generation
        mutableAdjustmentTransfer.value = EditorAdjustmentTransferState(preparing = true)
        val work = AdjustmentPreparationWork(generation, payload, uris.toList(), mutable.value.photo, ::adjustmentTargetIsCurrent, action,
            collectionPhotos = if (action == AdjustmentHistoryTransaction.Action.SYNCHRONIZE) uris.mapNotNull { uri ->
                collections.photo(uri.toString())?.let { uri.toString() to it } }.toMap() else emptyMap(),
            validateCollection = if (action == AdjustmentHistoryTransaction.Action.SYNCHRONIZE) { id ->
                collection.value.photos.firstOrNull { it.id == id }?.let(collections::validate)
                    ?: error("Photo left the collection")
            } else null)
        adjustmentPreparations += 1
        val prepare = prepareAdjustmentOperation
        adjustmentPreparationQueue.submit({ prepare(work) { generation != adjustmentPreparationGeneration } }) { result ->
            // viewModelScope 已取消时也必须释放工作结果，不能依赖一个不再执行的 UI 回调。
            if (disposed) result.getOrNull()?.ownedFiles?.values?.forEach(File::delete)
            else viewModelScope.launch {
                adjustmentPreparations -= 1
                result.fold({ value ->
                    if (!disposed && value.generation == adjustmentPreparationGeneration) {
                        adjustmentOwnedFiles = value.ownedFiles
                        mutableAdjustmentTransfer.value = mutableAdjustmentTransfer.value.copy(preparing = false, prepared = value.operation,
                            results = emptyList(), error = null)
                        completed(Result.success(value.operation))
                    } else value.ownedFiles.values.forEach(File::delete)
                }, { error ->
                    if (!disposed && generation == adjustmentPreparationGeneration) {
                        mutableAdjustmentTransfer.value = mutableAdjustmentTransfer.value.copy(preparing = false, error = adjustmentErrorMessage(error))
                        completed(Result.failure(error))
                    }
                })
                collections.releaseDeferred()
        } }
    }
    fun applyAdjustmentPaste(operation: PreparedAdjustmentTransfer, skipping: Set<String> = emptySet(),
        completed: (List<AdjustmentOutcome>) -> Unit = {}) {
        if (mutableAdjustmentTransfer.value.prepared?.id != operation.id) return completed(emptyList())
        val previous = mutableAdjustmentTransfer.value.results.filter { it.status in setOf(AdjustmentStatus.APPLIED,
            AdjustmentStatus.UNCHANGED, AdjustmentStatus.SKIPPED) }.map { it.targetID }.toSet()
        val session = adjustmentHistory.session ?: return completed(emptyList())
        val expectedSourceToken = adjustmentHistory.snapshot().sourceToken
        commitAdjustments({ session.apply(operation, skipping) }) { outcome ->
            val results = outcome.getOrElse { operation.targets.map { target -> AdjustmentOutcome(target.id, AdjustmentStatus.FAILED, error = it) } }
            val accepted = acceptAdjustmentOutcomes(results, previous, expectedSourceToken = expectedSourceToken)
            if (!adjustmentCloseRequested) mutableAdjustmentTransfer.value = mutableAdjustmentTransfer.value.copy(results = accepted)
            if (operation.action == AdjustmentHistoryTransaction.Action.SYNCHRONIZE)
                collections.synchronized(operation.id, accepted.any { it.status == AdjustmentStatus.APPLIED })
            completed(accepted)
        }
    }
    fun closeAdjustmentOperation() {
        quickPresetGeneration = UUID.randomUUID()
        mutableQuickPreset.value = EditorQuickPresetState(visible = mutableQuickPreset.value.visible)
        adjustmentPreparationGeneration = UUID.randomUUID()
        mutableAdjustmentTransfer.value = EditorAdjustmentTransferState()
        adjustmentCloseRequested = true
        finishAdjustmentClose()
        collections.releaseDeferred()
    }
    private fun finishAdjustmentClose() {
        if (!adjustmentCloseRequested || mutable.value.committingAdjustments) return
        adjustmentOwnedFiles.values.forEach(File::delete)
        adjustmentOwnedFiles = emptyMap()
        adjustmentCloseRequested = false
    }
    fun showQuickPresets() {
        if (mutable.value.photo != null && mutable.value.operation == Operation.NONE)
            mutableQuickPreset.value = mutableQuickPreset.value.copy(visible = true)
    }
    fun closeQuickPresets() {
        if (!mutableQuickPreset.value.visible && !mutableQuickPreset.value.busy) return
        closeAdjustmentOperation()
        mutableQuickPreset.value = EditorQuickPresetState()
    }
    fun cancelQuickPreset() { closeAdjustmentOperation() }

    fun applyPresetToCurrentPhoto(preset: com.rawlab.android.presets.AdjustmentPreset) {
        val current = mutable.value
        val photo = current.photo ?: return
        if (!mutableQuickPreset.value.visible || mutableQuickPreset.value.busy || !current.controlsEnabled || current.draft != null) return
        closeAdjustmentOperation()
        val generation = UUID.randomUUID()
        val source = sourceRevision
        val revision = editRevision
        quickPresetGeneration = generation
        mutableQuickPreset.value = EditorQuickPresetState(true, QuickPresetPhase.PREPARING, preset)
        fun active() = !disposed && quickPresetGeneration == generation && mutableQuickPreset.value.visible &&
            mutable.value.photo == photo && sourceRevision == source && editRevision == revision
        fun failed(error: Throwable?) {
            mutableQuickPreset.value = EditorQuickPresetState(true, QuickPresetPhase.FAILED, preset, message = quickPresetErrorMessage(error))
        }
        persist(photo, current.edits) { saved ->
            if (!active()) return@persist
            if (saved.state == EditSaveState.FAILED) {
                mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message)
                failed(saved.error); return@persist
            }
            mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message)
            val history = adjustmentHistory.snapshot()
            if (history.loaded?.identity != photo.identity || !adjustmentTargetIsCurrent(photo.identity.value, history)) {
                failed(AdjustmentTransferException(AdjustmentFailure.DRAFT)); return@persist
            }
            startAdjustmentPreparation(preset.payload, listOf(photo.uri), AdjustmentHistoryTransaction.Action.PRESET) { result ->
                if (!active()) { if (quickPresetGeneration == generation) cancelQuickPreset(); return@startAdjustmentPreparation }
                val operation = result.getOrElse { failed(it); return@startAdjustmentPreparation }
                val target = operation.targets.singleOrNull()
                if (target?.error != null) { failed(target.error); return@startAdjustmentPreparation }
                if (target == null) { failed(AdjustmentOperationExpiredException()); return@startAdjustmentPreparation }
                mutableQuickPreset.value = mutableQuickPreset.value.copy(phase = QuickPresetPhase.COMMITTING)
                applyAdjustmentPaste(operation) { outcomes ->
                    if (quickPresetGeneration != generation || !mutableQuickPreset.value.visible) return@applyAdjustmentPaste
                    val outcome = outcomes.singleOrNull()
                    if (outcome?.saved == null) { failed(outcome?.error); return@applyAdjustmentPaste }
                    val phase = when (outcome.status) {
                        AdjustmentStatus.APPLIED -> QuickPresetPhase.SAVED
                        AdjustmentStatus.UNCHANGED -> QuickPresetPhase.UNCHANGED
                        else -> { failed(outcome.error); return@applyAdjustmentPaste }
                    }
                    mutableQuickPreset.value = EditorQuickPresetState(true, phase, preset, operation.id)
                }
            }
        }
    }

    fun undoQuickPreset() {
        val quick = mutableQuickPreset.value
        val transaction = quick.transactionID ?: return
        if (quick.phase !in setOf(QuickPresetPhase.SAVED, QuickPresetPhase.UNDO_FAILED) || !mutable.value.controlsEnabled || mutable.value.draft != null) return
        val generation = quickPresetGeneration
        mutableQuickPreset.value = quick.copy(phase = QuickPresetPhase.COMMITTING, message = null)
        performAdjustmentHistory(true, transactionID = transaction) { outcomes ->
            if (quickPresetGeneration != generation || !mutableQuickPreset.value.visible) return@performAdjustmentHistory
            val outcome = outcomes.singleOrNull()
            mutableQuickPreset.value = if (outcome?.status == AdjustmentStatus.APPLIED && outcome.saved != null)
                quick.copy(phase = QuickPresetPhase.UNDONE, message = null)
            else quick.copy(phase = QuickPresetPhase.UNDO_FAILED, message = adjustmentErrorMessage(outcome?.error))
        }
    }

    fun setGpuEnabled(enabled: Boolean) {
        if (mutable.value.committingAdjustments || mutable.value.operation != Operation.NONE) return
        mutable.value = mutable.value.copy(gpuEnabled = enabled)
        if (mutable.value.draft != null) renderDraft(false)
        else if (mutable.value.photo != null) edit(mutable.value.edits)
    }

    fun setHDRMode(enabled: Boolean) {
        val current = mutable.value
        val photo = current.photo ?: return
        if (!photo.isHDRSource || !current.controlsEnabled || current.draft != null) return
        val candidate = runCatching { current.edits.withHDRMode(enabled, sourceIsHDR = !photo.isCameraRawHDR,
            cameraRaw = photo.isCameraRawHDR, proRAW = photo.hdrSource?.isProRAW == true) }
            .getOrElse { mutable.value = current.copy(error = text(R.string.hdr_unsupported)); return }
        if (enabled && photo.isCameraRawHDR) preflightHDRCamera(photo,current,candidate) else edit(candidate)
    }

    fun applyHDRCameraDevelopment(development: com.rawlab.android.settings.HDRCameraDevelopmentSettings) {
        val current = mutable.value
        val photo = current.photo ?: return
        val hdr = current.edits.hdr ?: return
        if (!current.edits.isHDREditing || !photo.isCameraRawHDR || photo.hdrSource?.isProRAW == true ||
            !current.controlsEnabled || current.draft != null || current.importingHDRCameraProfile ||
            cameraHDRPreflightPending || development == hdr.cameraSettings) return
        preflightHDRCamera(photo,current,current.edits.copy(hdr = hdr.withCameraDevelopment(development)))
    }

    fun changeHDRCameraDraft(settings: com.rawlab.android.settings.HDRCameraDevelopmentSettings) {
        val current = mutable.value
        val photo = current.photo ?: return
        val baseline = current.edits.hdr?.cameraSettings ?: return
        if (!current.controlsEnabled || current.importingHDRCameraProfile || !current.edits.isHDREditing) return
        mutable.value = current.copy(hdrCameraDraft = HDRCameraPanelDraft(photo.identity, baseline, settings))
    }

    fun beginHDRCameraProfileImport(): Boolean {
        val current = mutable.value
        if (!current.controlsEnabled || !current.edits.isHDREditing || current.draft != null || current.rendering ||
            current.importingHDRCameraProfile || pendingHDRCameraProfileImport != null ||
            current.photo?.isCameraRawHDR != true || current.photo.hdrSource?.isProRAW == true) return false
        pendingHDRCameraProfileImport = sourceRevision to editRevision
        return true
    }

    fun finishHDRCameraProfileImport(uri: Uri?) {
        val revision = pendingHDRCameraProfileImport
        pendingHDRCameraProfileImport = null
        if (uri == null || revision == null) return
        if (revision != (sourceRevision to editRevision)) {
            mutable.value = mutable.value.copy(message = text(R.string.hdr_camera_profile_changed))
            return
        }
        mutable.value = mutable.value.copy(importingHDRCameraProfile = true, error = null)
        viewModelScope.launch {
            try {
                val imported = readHDRCameraProfile({ withContext(Dispatchers.IO) { storage.importHDRCameraProfile(uri) } },
                    { revision == (sourceRevision to editRevision) && mutable.value.controlsEnabled })
                if (disposed) return@launch
                imported.onSuccess { profile ->
                    val current = mutable.value
                    val photo = current.photo ?: return@onSuccess
                    val baseline = current.edits.hdr?.cameraSettings ?: return@onSuccess
                    val draft = HDRCameraPanelDraft(photo.identity, baseline, current.hdrCameraDraftSettings ?: baseline)
                    mutable.value = current.copy(hdrCameraDraft = draft.withProfile(profile))
                }.onFailure {
                    if (it is AdjustmentOperationExpiredException)
                        mutable.value = mutable.value.copy(message = text(R.string.hdr_camera_profile_changed))
                    else mutable.value = mutable.value.copy(error = text(R.string.hdr_camera_profile_invalid))
                }
            } finally {
                if (!disposed) mutable.value = mutable.value.copy(importingHDRCameraProfile = false)
            }
        }
    }

    private fun preflightHDRCamera(photo: ImportedPhoto, current: EditorState, candidate: EditSettings) {
        // Preserve the committed frame and saved settings until decoding succeeds.
        mutable.value = current.copy(rendering = true, error = null)
        currentRevision = submitRender(Work.CameraHDRPreflight(photo, current.edits, candidate, gpuMode(), sourceRevision,
            previewLongEdge))
    }

    fun beginExport(completed: (Boolean) -> Unit = {}) {
        if (!mutable.value.canExport) return completed(false)
        val photo = mutable.value.photo ?: return completed(false)
        persist(photo, mutable.value.edits) { saved ->
            mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message)
            if (saved.state == EditSaveState.FAILED) completed(false)
            else { mutable.value = mutable.value.copy(operation = Operation.PICK_EXPORT, error = null); completed(true) }
        }
    }
    fun cancelExport() {
        val operation = mutable.value.operation
        if (operation == Operation.PICK_EXPORT) {
            mutable.value = mutable.value.copy(operation = Operation.NONE)
        } else if (operation == Operation.EXPORT) {
            currentRevision = queue.invalidate()
            mutable.value = EditorStateReducer.renderFinished(mutable.value)
            collections.releaseDeferred()
        }
        updatePreviewSize(requestedPreviewLongEdge)
    }
    fun export(destination: Uri?, format: ExportFormat, longEdge: Int? = null) {
        when (val submission = prepareExportSubmission(
            mutable.value, destination, format, longEdge, gpuMode(), exportDestinationCleanup, disposed,
        )) {
            is ExportSubmission.Rejected -> {
                val next = if (submission.errorKey != null) {
                    submission.state.copy(error = text(submission.errorKey))
                } else submission.state
                if (next != mutable.value) mutable.value = next
                if (submission.refreshPreviewSize) updatePreviewSize(requestedPreviewLongEdge)
            }
            is ExportSubmission.Ready -> {
                mutable.value = submission.state
                currentRevision = submitRender(submission.work)
            }
        }
    }
    fun dismissMessage() { mutable.value = mutable.value.copy(message = null) }

    fun addCollectionPhotos(uris: List<Uri>) = collections.add(uris, mutable.value.photo)
    fun retainCurrentInCollection() { mutable.value.photo?.let { collections.add(listOf(it.uri), it) } }
    fun selectCollectionPhoto(id: String, selected: Boolean) = collections.select(id, selected)
    fun selectCollectionAll(selected: Boolean) = collections.selectAll(selected)
    fun removeCollectionPhoto(id: String) = collections.remove(id)
    fun refreshCollection() = collections.refresh()
    fun collectionSupportsHDRExport(skipping: Set<String> = emptySet()) =
        collection.value.supportsHDRExport(editStore::readState, skipping)
    fun collectionDraftFailure(id: String): String? {
        val current = mutable.value
        val photo = current.photo?.takeIf { it.identity.value == id } ?: return null
        val history = adjustmentHistory.snapshot()
        if (!adjustmentTargetIsCurrent(id, history)) return current.saveError ?: "Apply, discard or skip this photo's draft"
        val record = history.loaded
        return if (record == null || !AdjustmentTransfer.sameAdjustments(record.settings ?:
            photo.defaultEditSettings(), current.edits,
                photo.inputKind == PhotoInputKind.RAW)) "Apply, discard or skip this photo's draft" else null
    }
    private fun captureCollectionActiveValidation(): (String) -> Unit {
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
                check(latest.photo?.identity == photo.identity && latest.edits == current.edits && latest.draft == null &&
                    latest.operation == Operation.NONE && !latest.committingAdjustments) { "Apply, discard or skip this photo's draft" }
                captured.getOrThrow()()
            }
        }
    }
    fun resolveCollectionDraft(apply: Boolean, completed: (Boolean) -> Unit = {}) {
        if (mutable.value.committingAdjustments) return completed(false)
        val history = adjustmentHistory.snapshot()
        if (apply) {
            if (history.interacting) {
                edit(mutable.value.edits, false)
                // 交互提交完成后，界面会解除忙状态；本次保留确认入口。
                return completed(false)
            }
            mutable.value.draft?.let { draft ->
                if (draft.changed) { applyDraft(completed); return }
                discardDraft(); completed(true); return
            }
            retrySave(completed)
        } else {
            val loaded = history.loaded
            if (mutable.value.photo != null && loaded == null) {
                val unavailable = EditSaveResult(EditSaveState.FAILED, AdjustmentNotReadyException(), reading = true)
                mutable.value = mutable.value.copy(saveState = unavailable.state, saveError = unavailable.message)
                completed(false)
                return
            }
            pendingResetMigrationClear = null
            cancelAdjustmentInteraction()
            mutable.value.draft?.let { discardDraft() }
            val current = mutable.value
            val photo = current.photo
            val restored = if (photo == null) null else loaded?.settings ?: photo.defaultEditSettings()
            if (photo != null && restored != null && current.edits != restored) {
                editRevision += 1
                mutable.value = current.copy(edits = restored, draft = null, saveState = EditSaveState.SAVED,
                    saveError = null, error = null, adjustmentRevision = current.adjustmentRevision + 1)
                includeIndependentRecipeLook(restored)
                renderCommittedForNavigation()
            } else if (photo != null && current.saveState == EditSaveState.FAILED) {
                mutable.value = current.copy(saveState = if (loaded?.settings == null) EditSaveState.NONE else EditSaveState.SAVED,
                    saveError = null, adjustmentRevision = current.adjustmentRevision + 1)
            }
            completed(photo != null)
        }
    }
    fun editCollectionPhoto(id: String, completed: (Boolean) -> Unit = {}) {
        val target = collection.value.photos.firstOrNull { it.id == id } ?: return completed(false)
        if (collection.value.busy || mutable.value.committingAdjustments || mutable.value.draft != null || mutable.value.operation != Operation.NONE)
            return completed(false)
        commitAdjustments({ collections.validateForCommit(target) }) { outcome ->
            outcome.fold({
                if (mutable.value.photo?.identity?.value == id) { collections.opened(id); completed(true) }
                else importPhoto(Uri.parse(target.sourceUri), completed)
            }, { error -> collections.failure(error.message); completed(false) })
        }
    }
    fun returnToCollection(completed: (Boolean) -> Unit = {}) {
        if (mutable.value.draft != null || mutable.value.operation != Operation.NONE || mutable.value.committingAdjustments) return completed(false)
        cancelAdjustmentInteraction()
        if (mutable.value.photo == null) { collections.returnToCollection(); collections.refresh(); completed(true) }
        else retrySave { accepted ->
            if (accepted) { collections.returnToCollection(); collections.refresh() }
            completed(accepted)
        }
    }
    fun captureCollectionSynchronization(scope: AdjustmentScope, completed: (CollectionSynchronization?) -> Unit) {
        val photo = mutable.value.photo
        if (photo == null) { collections.failure("Choose a source photo first"); completed(null); return }
        val targets = collection.value.synchronizationTargets(photo.identity.value).map { Uri.parse(it.sourceUri) }
        if (targets.isEmpty()) { collections.failure("No targets remain after excluding the source photo"); completed(null); return }
        capturePresetAdjustments(scope) { result ->
            result.fold({ completed(CollectionSynchronization(photo.identity.value, photo.name, it, targets)) },
                { collections.failure(it.message); completed(null) })
        }
    }

    fun prepareCollectionExport(skipping: Set<String>, format: ExportFormat, longEdge: Int?, destination: Uri?,
        completed: (com.rawlab.android.batch.CollectionExportReview?) -> Unit) =
        collections.prepare(skipping, format, longEdge, destination, completed)
    fun freezeCollectionExport(review: com.rawlab.android.batch.CollectionExportReview, completed: (Boolean) -> Unit) {
        freezeAndAttachCollectionExport(review, false, { true }) { _, attached -> completed(attached) }
    }

    fun cancelCollectionExport() {
        collectionExportGeneration = UUID.randomUUID()
        mutableCollectionExport.value = mutableCollectionExport.value.copy(preparing = false, review = null)
    }

    fun startCollectionExport(skipping: Set<String>, format: ExportFormat, longEdge: Int?, destination: Uri?,
        completed: (Boolean) -> Unit = {}) {
        if (mutableCollectionExport.value.preparing || mutableCollectionExport.value.freezing || collection.value.busy) return
        cancelCollectionExport()
        val generation = collectionExportGeneration
        val source = mutable.value.photo
        val sourceVersion = sourceRevision
        val revision = mutable.value.adjustmentRevision
        val selected = collection.value.selected
        val current = { !disposed && generation == collectionExportGeneration && sourceRevision == sourceVersion && mutable.value.photo === source &&
            mutable.value.adjustmentRevision == revision && collection.value.selected == selected }
        mutableCollectionExport.value = CollectionExportFlow(preparing = true)
        collections.prepare(skipping, format, longEdge, destination) { review ->
            if (generation != collectionExportGeneration) return@prepare
            if (!current()) {
                mutableCollectionExport.value = CollectionExportFlow()
                collections.failure("Review the selected photos again")
            } else if (review?.ready != true) {
                mutableCollectionExport.value = CollectionExportFlow(review = review)
            } else {
                mutableCollectionExport.value = CollectionExportFlow(preparing = true, freezing = true, review = review)
                freezeAndAttachCollectionExport(review, true, current) { job, _ ->
                    mutableCollectionExport.value = CollectionExportFlow()
                    if (job != null) completed(true)
                }
            }
        }
    }

    private fun freezeAndAttachCollectionExport(review: com.rawlab.android.batch.CollectionExportReview,
        automaticallyStart: Boolean, isCurrent: () -> Boolean, completed: (BatchJob?, Boolean) -> Unit) {
        if (batch.value != null || pendingBatch.value.isNotEmpty()) {
            collections.failure("Close the current export task first"); completed(null, false); return
        }
        collections.freeze(review, isCurrent) { job ->
            if (job == null) completed(null, false)
            else {
                batches.retain(job)
                releaseEditorRasterForBatch { released ->
                    if (released) batches.resume(job, gpuMode(), startAutomatically = automaticallyStart && isCurrent())
                    else collections.failure(mutable.value.error)
                    completed(job, released)
                }
            }
        }
    }

    fun beginBatch() {
        val current = mutable.value
        if (!current.canExport || batch.value != null) return
        val photo = current.photo ?: return
        val source = BatchSourceSnapshot(photo.identity, photo.file, current.edits, photo.name, inputKind = photo.inputKind)
        releaseEditorRasterForBatch { if (it) batches.begin(source, gpuMode()) }
    }

    fun resumeBatch(job: BatchJob) {
        if (batch.value != null || mutable.value.committingAdjustments || mutable.value.draft != null || mutable.value.operation != Operation.NONE) return
        releaseEditorRasterForBatch { if (it) batches.resume(job, gpuMode()) }
    }

    private fun releaseEditorRasterForBatch(completed: (Boolean) -> Unit) {
        if (disposed) { completed(false); return }
        cancelProcessingMigration(skipCurrentSource = true)
        if (mutable.value.committingAdjustments) {
            viewModelScope.launch {
                state.first { !it.committingAdjustments }
                releaseEditorRasterForBatch(completed)
            }
            return
        }
        // 页面切换沿用存储动作的输入门禁；只在渲染队列上释放完整解码图，保留仍在显示的预览。
        mutable.value = mutable.value.copy(committingAdjustments = true)
        queue.performAfterPending {
            val result = runCatching { releaseEditorRasterOperation() }
            viewModelScope.launch {
                if (!disposed) {
                    mutable.value = mutable.value.copy(committingAdjustments = false)
                    try {
                        result.exceptionOrNull()?.let { mutable.value = mutable.value.copy(error = failure(it)) }
                        completed(result.isSuccess)
                    } finally { finishAdjustmentClose(); collections.releaseDeferred() }
                }
            }
        }
    }
    internal var releaseEditorRasterOperation: () -> Unit = { renderer.releaseDecodedRaster() }
    fun closeBatch() = batches.close()

    private fun preserveEditorDraft() {
        val current = mutable.value
        val photo = current.photo ?: return
        val fingerprint = photo.sourceFingerprint ?: return
        val draft = current.draft ?: return
        runCatching { draftStore.save(photo.identity, fingerprint, draft.copy(interacting = false)) }
            .onFailure { mutable.value = mutable.value.copy(message = EditSaveResult(EditSaveState.FAILED, it).message) }
    }

    private fun restoreEditorDraft() {
        val current = mutable.value
        val photo = current.photo ?: return
        val fingerprint = photo.sourceFingerprint ?: return
        val draft = runCatching { draftStore.load(photo.identity, fingerprint, current.edits) }
            .getOrElse { mutable.value = current.copy(message = EditSaveResult(EditSaveState.FAILED, it).message); null } ?: return
        draftRevision += 1
        draftSaveBaseline = current.saveState to current.saveError
        mutable.value = current.copy(draft = draft.copy(interacting = false))
        renderDraft(false)
    }

    fun onBackground() {
        preserveEditorDraft()
        setEditorActive(false)
        cancelCollectionExport()
        if (mutable.value.committingAdjustments) { batches.cancelForBackground(); return }
        cancelAdjustmentInteraction()
        batches.cancelForBackground()
        mutable.value.photo?.let { photo ->
            persist(photo, mutable.value.edits) { saved ->
                if (saved.state == EditSaveState.FAILED) mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message)
            }
        }
    }
    private fun text(id: Int) = AppStrings.text(id)
    private fun failure(error: Throwable): String = if (error is OutOfMemoryError) text(R.string.memory_error)
        else text(R.string.process_error) + "\n" + (error.message ?: error.javaClass.simpleName)

    override fun onCleared() {
        preserveEditorDraft()
        EditedPhotoPreviews.setForegroundBusy(photoPreviewOwner, false)
        photoPreviews.close()
        cancelProcessingMigration()
        clearX3fRecovery()
        clearUnusableImportRecovery()
        disposed = true
        adjustmentPreparationGeneration = UUID.randomUUID()
        previewResizeJob?.cancel()
        batches.dispose()
        collections.close(::releaseStorage)
        lookQueue.close()
        queue.close()
        adjustmentQueue.close()
        adjustmentPreparationQueue.close()
        processingMigrationQueue.close()
    }

    private fun releaseStorage() {
        synchronized(this) {
            releases += 1
            if (releases == 6) storage.close()
        }
    }
}
