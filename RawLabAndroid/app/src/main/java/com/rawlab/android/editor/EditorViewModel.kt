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
import kotlinx.coroutines.launch
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import java.io.File
import com.rawlab.android.R
import com.rawlab.android.analytics.UsageEvent
import com.rawlab.android.analytics.setup.UsageAnalyticsRegistry
import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.BatchSourceSnapshot
import com.rawlab.android.editor.render.EditorRenderer
import com.rawlab.android.editor.render.LookResult
import com.rawlab.android.editor.render.LookWork
import com.rawlab.android.editor.render.RenderQueue
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.editor.render.runLookWork
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.ExportSize
import com.rawlab.android.geometry.GeometryRatio
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.looks.DcpFailureReason
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.editor.storage.EditorEditStore
import com.rawlab.android.editor.storage.EditSaveResult
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.geometry.uncropped
import com.rawlab.android.looks.MasterRecipe
import com.rawlab.android.looks.localizedName
import com.rawlab.android.adjustments.*
import com.rawlab.android.presets.AdjustmentPresetStore
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.EditPersistenceConflict
import com.rawlab.android.settings.LookChoice
import com.rawlab.android.format.PhotoInputKind
import java.util.UUID

class EditorViewModel @JvmOverloads constructor(
    application: Application,
    editStoreFactory: (File) -> EditStore = { EditStore(it) },
    private val batchProcessorFactory: (Int, File?) -> NativeProcessor = { mode, database -> NativeProcessor(mode, database) },
) : AndroidViewModel(application) {
    val storage = PhotoStorage(application)
    val presetStore = AdjustmentPresetStore(File(application.filesDir, "presets"))
    private val usage = UsageAnalyticsRegistry.get(application)
    private val editStore = EditorEditStore(File(application.filesDir, "edits"), editStoreFactory)
    private val adjustmentHistory = EditorAdjustmentHistory(editStore)
    val adjustmentTransactions get() = adjustmentHistory.session?.transactions.orEmpty()
    val adjustmentReloadRequired get() = adjustmentHistory.reloadRequired
    val canUndoAdjustment get() = mutable.value.photo?.identity?.let { adjustmentHistory.session?.canUndoPhoto(it) } == true
    val canRedoAdjustment get() = mutable.value.photo?.identity?.let { adjustmentHistory.session?.canRedoPhoto(it) } == true
    val adjustmentClipboard get() = adjustmentHistory.session?.clipboard
    var adjustmentClipboardSourceName: String? = null
        private set
    private val mutableAdjustmentTransfer = MutableStateFlow(EditorAdjustmentTransferState())
    val adjustmentTransfer = mutableAdjustmentTransfer.asStateFlow()
    private var adjustmentOwnedFiles = emptyMap<String, File>()
    private val adjustmentRetainedFiles = mutableMapOf<String, File>()
    private var adjustmentPreparationGeneration = UUID.randomUUID()
    private var adjustmentPreparationRevision = -1L
    private val batches = EditorBatches(application, storage, viewModelScope, batchProcessorFactory, usage) { error ->
        mutable.value = mutable.value.copy(error = error)
    }
    private val collections = EditorCollections(storage, viewModelScope, File(application.filesDir, "RawLab/BatchJobs"),
        editStore::versionedState, ::validateCollectionActive, canRelease = { photo ->
            mutable.value.photo?.file != photo.file && !mutableAdjustmentTransfer.value.preparing &&
                adjustmentHistory.session?.retainsSource(photo.identity) != true
        })
    val collection = collections.state
    val batch = batches.active
    val pendingBatch = batches.pending
    private val mutableHslTarget = MutableStateFlow(HslTargetState())
    val hslTarget = mutableHslTarget.asStateFlow()
    private val hslInteraction = HslTargetInteraction()
    private var hslHistoryActive = false
    private var applyingHslTarget = false
    private var acceptedHslPreview: Work.Preview? = null
    private var acceptedHslSettings: EditSettings? = null
    private var acceptedHslRevision: HslTargetRevision? = null
    private var currentRevision = 0L
    private var sourceRevision = 0L
    private var editRevision = 0L
    private var draftRevision = 0L
    private var durablePreview: EditorDurablePreview? = null
    private var failedDraftSave = false
    private var draftSaveBaseline: Pair<EditSaveState, String?>? = null
    private var navigationPreview: EditorDurablePreview? = null
    private var previewLongEdge = 1600
    private var requestedPreviewLongEdge = 1600
    private var previewResizeJob: Job? = null
    private val pendingPhotoImport = PendingPhotoImport()
    private var lookRevision = 0L
    private var releases = 0
    private val mutable = MutableStateFlow(EditorState())
    val state = mutable.asStateFlow()
    private var disposed = false
    private val renderer = EditorRenderer(storage, { if (editStore.available) editStore.versionedState(it) else null },
        (application.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0)
    private val queue = RenderQueue<Work, WorkResult>(renderer::perform, { revision, result ->
        viewModelScope.launch {
            if (!disposed && revision == currentRevision) accept(result)
        }
    }, { renderer.close(); releaseStorage() })
    private val lookQueue = RenderQueue<LookWork, LookResult>({ runLookWork(storage, it) }, { revision, result ->
        viewModelScope.launch {
            if (!disposed && revision == lookRevision) acceptLook(result)
        }
    }, ::releaseStorage)
    private val adjustmentPreparation = EditorAdjustmentPreparation(application, storage, editStore)
    private val adjustmentQueue = RenderQueue<AdjustmentPreparationWork, AdjustmentPreparationResult>(adjustmentPreparation::prepare,
        { revision, result -> viewModelScope.launch {
            result.fold({ value ->
                if (!disposed && revision == adjustmentPreparationRevision && value.generation == adjustmentPreparationGeneration) {
                    adjustmentOwnedFiles = value.ownedFiles
                    mutableAdjustmentTransfer.value = mutableAdjustmentTransfer.value.copy(preparing = false, prepared = value.operation,
                        results = emptyList(), error = null)
                } else value.ownedFiles.values.forEach(File::delete)
            }, { error ->
                if (!disposed && revision == adjustmentPreparationRevision && mutableAdjustmentTransfer.value.preparing)
                    mutableAdjustmentTransfer.value = mutableAdjustmentTransfer.value.copy(preparing = false, error = adjustmentErrorMessage(error))
            })
        } }, ::releaseStorage, { result -> result.ownedFiles.values.forEach(File::delete) })

    init {
        editStore.initialResult.let { mutable.value = mutable.value.copy(saveState = it.state, saveError = it.message) }
        lookRevision = lookQueue.submit(LookWork.Load)
        batches.refreshPending()
    }


    private fun submitRender(work: Work): Long {
        // 新任务替换取色时，队列可能不再回调旧请求；这里同步清除等待状态。
        if (work !is Work.HslProbe && hslInteraction.waiting) clearHslTarget()
        return queue.submit(work)
    }

    fun setHslTargetEnabled(enabled: Boolean) {
        cancelHslTarget(); mutableHslTarget.value = mutableHslTarget.value.copy(enabled = enabled)
    }
    fun setHslTargetAxis(axis: Int) {
        require(axis in 0..2)
        cancelHslTarget(); mutableHslTarget.value = mutableHslTarget.value.copy(axis = axis)
    }
    fun beginHslTarget(x: Float, y: Float, keyDelta: Float? = null) {
        cancelHslTarget()
        val current = mutable.value; val target = mutableHslTarget.value
        val preview = acceptedHslPreview; val revision = acceptedHslRevision
        if (!target.enabled || !current.controlsEnabled || current.rendering || current.previewResizePending || current.error != null || current.draft != null ||
            preview == null || revision == null || revision.source != sourceRevision || current.edits != acceptedHslSettings ||
            current.photo?.identity != preview.photo.identity || current.photo?.file != preview.photo.file) {
            mutableHslTarget.value = target.copy(notice = HslTargetAvailability.STALE); return
        }
        val token = hslInteraction.begin(current.edits.hsl, target.axis, revision)
        mutableHslTarget.value = target.copy(x = x, y = y, sample = null, waiting = true, notice = null)
        if (keyDelta != null) { hslInteraction.move(keyDelta); hslInteraction.end() }
        currentRevision = submitRender(Work.HslProbe(preview, current.edits, revision, token, target.axis, x, y))
    }
    private fun acceptHslTarget(value: WorkResult.HslProbe) {
        val work = value.request
        if (!hslInteraction.matches(work.token)) return
        val current = mutable.value; val target = mutableHslTarget.value
        if (!target.enabled || target.axis != work.axis || current.edits != work.before || current.draft != null ||
            sourceRevision != work.revision.source || current.photo?.identity != work.preview.photo.identity) {
            cancelHslTarget(); mutableHslTarget.value = mutableHslTarget.value.copy(notice = HslTargetAvailability.STALE); return
        }
        val next = hslInteraction.accept(value.sample, work.token, acceptedHslRevision)
        mutableHslTarget.value = target.copy(sample = hslInteraction.selection, waiting = false,
            notice = if (next == null) hslInteraction.selection?.availability ?: HslTargetAvailability.STALE else null)
        if (next == null) return
        applyingHslTarget = true
        try { edit(current.edits.copy(hsl = next), true) } finally { applyingHslTarget = false }
        hslHistoryActive = adjustmentHistory.interacting
        if (!hslHistoryActive) { clearHslTarget(); mutableHslTarget.value = target.copy(notice = HslTargetAvailability.FAILED); return }
        if (!hslInteraction.dragging) endHslTarget()
    }
    fun moveHslTarget(delta: Float) {
        val next = hslInteraction.move(delta) ?: return
        if (!hslHistoryActive) return
        applyingHslTarget = true
        try { edit(mutable.value.edits.copy(hsl = next), true) } finally { applyingHslTarget = false }
    }
    fun endHslTarget() {
        hslInteraction.end()
        if (hslHistoryActive) {
            hslHistoryActive = false; applyingHslTarget = true
            try { edit(mutable.value.edits, false) } finally { applyingHslTarget = false }
        }
    }
    private fun clearHslTarget() {
        hslInteraction.cancel(); hslHistoryActive = false
        mutableHslTarget.value = mutableHslTarget.value.copy(x = null, y = null, sample = null, waiting = false, notice = null)
    }
    fun cancelHslTarget() {
        val active = hslHistoryActive
        clearHslTarget()
        if (active) cancelAdjustmentInteraction()
    }
    fun rejectHslTarget() { cancelHslTarget(); mutableHslTarget.value = mutableHslTarget.value.copy(notice = HslTargetAvailability.OUTSIDE) }
    fun keyHslTarget(delta: Float) {
        val target = mutableHslTarget.value
        if (hslInteraction.dragging || target.x == null || target.y == null) return
        if (hslInteraction.waiting) { hslInteraction.accumulateReleased(delta); return }
        beginHslTarget(target.x, target.y, delta)
    }

    private fun accept(result: Result<WorkResult>) {
        result.fold({ value ->
            when (value) {
                is WorkResult.MissingLook -> {
                    releasePreviousPhoto(value.photo)
                    adjustmentHistory.acceptSource(value.photo, value.importedRecord)
                    collections.opened(value.photo.identity.value)
                    adjustmentRetainedFiles.remove(value.photo.identity.value)?.delete()
                    mutable.value = EditorStateReducer.renderFinished(mutable.value).copy(photo = value.photo,
                        edits = value.edits, preview = null, exact = false,
                        saveState = EditSaveState.RESTORED, error = text(R.string.look_unavailable))
                    includeIndependentRecipeLook(value.edits)
                }
                is WorkResult.HslProbe -> acceptHslTarget(value)
                is WorkResult.Preview -> {
                    val request = value.request
                    if (request.draft) {
                        val current = mutable.value
                        val draft = current.draft ?: return@fold
                        val refitted = draft.acceptGeometryCanvas(value.pair.comparisonWidth / value.pair.comparisonHeight)
                        if (refitted != draft) draftRevision += 1
                        mutable.value = EditorStateReducer.renderFinished(current)
                            .copy(draft = refitted, preview = value.pair, exact = !request.interactive, error = null)
                        return@fold
                    }
                    val imported = pendingPhotoImport.complete(request.photo.identity)
                    if (request.importing) {
                        releasePreviousPhoto(request.photo)
                        adjustmentHistory.acceptSource(request.photo, request.importedRecord)
                        collections.opened(request.photo.identity.value)
                        adjustmentRetainedFiles.remove(request.photo.identity.value)?.delete()
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
                    includeIndependentRecipeLook(settings)
                }
                WorkResult.Export -> {
                    mutable.value = mutable.value.copy(operation = Operation.NONE, message = text(R.string.export_done))
                    usage.record(UsageEvent.ExportCompleted)
                }
                is WorkResult.AutoExposure -> {
                    val current = mutable.value
                    if (current.photo?.identity == value.request.photo.identity && current.edits == value.request.edits) {
                        edit(current.edits.copy(exposure = value.exposure))
                    }
                }
            }
            fadeSaveNotice()
        }, { error ->
            if (mutable.value.operation == Operation.IMPORT) pendingPhotoImport.clear()
            mutable.value = EditorStateReducer.renderFinished(mutable.value).copy(error = failure(error))
        })
        updatePreviewSize(requestedPreviewLongEdge)
    }

    private fun acceptLook(result: Result<LookResult>) {
        result.fold(::acceptLookValue, { error ->
            mutable.value = mutable.value.copy(operation = Operation.NONE,
                error = text(R.string.look_storage_error) + "\n" + (error.message ?: error.javaClass.simpleName))
        })
        updatePreviewSize(requestedPreviewLongEdge)
    }

    private fun acceptLookValue(result: LookResult) {
        when (result) {
            is LookResult.Loaded -> {
                mutable.value = EditorStateReducer.looksLoaded(mutable.value, result.looks)
                includeIndependentRecipeLook(mutable.value.edits)
            }
            is LookResult.Imported -> {
                val mutation = result.imported.lastOrNull()?.let { EditorStateReducer.lookImported(mutable.value, it) }
                    ?: EditorMutation(mutable.value.copy(operation = Operation.NONE), null)
                val report = if (result.failures.isEmpty()) null else
                    AppStrings.format(R.string.look_import_summary, result.imported.size, result.failures.size) +
                        result.failures.joinToString("\n") { failure ->
                            val message = failure.dcpReason?.let(::dcpFailureText) ?: failure.message
                            if (failure.invalid) message + "\n" + text(R.string.look_invalid_file) else message
                        }
                mutable.value = mutation.state.copy(looks = result.looks, lookImportReport = report,
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
                scheduleLookPreview(mutation.preview)
            }
            is LookResult.Failed -> {
                if (result.reload) lookRevision = lookQueue.submit(LookWork.Load)
                val title = text(if (result.reload) R.string.look_error else R.string.look_storage_error)
                mutable.value = mutable.value.copy(operation = Operation.NONE,
                    error = title + "\n" + (result.error.message ?: result.error.javaClass.simpleName))
            }
        }
    }

    private fun scheduleLookPreview(edits: EditSettings?) {
        val photo = mutable.value.photo ?: return
        if (edits == null) return
        val saved = persist(photo, edits)
        mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message)
        editRevision += 1
        durablePreview = null
        currentRevision = submitRender(Work.Preview(photo, edits, false, gpuMode(), edge = previewLongEdge))
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

    fun importPhoto(uri: Uri?) {
        if (uri == null) {
            pendingPhotoImport.clear()
            return
        }
        if (mutable.value.operation != Operation.NONE || mutable.value.draft != null) return
        cancelAdjustmentInteraction()
        val current = mutable.value
        if (current.photo != null) {
            val saved = persist(current.photo, current.edits)
            if (saved.state == EditSaveState.FAILED) {
                mutable.value = current.copy(saveState = saved.state, saveError = saved.message)
                return
            }
        }
        sourceRevision += 1
        closeAdjustmentOperation()
        durablePreview = null
        pendingPhotoImport.begin(PhotoIdentity(uri.toString()))
        mutable.value = mutable.value.copy(operation = Operation.IMPORT, rendering = true, error = null)
        previewResizeJob?.cancel()
        previewResizeJob = null
        previewLongEdge = 1600
        requestedPreviewLongEdge = 1600
        mutable.value = mutable.value.copy(previewResizePending = false)
        val retained = collections.photo(uri.toString())
        currentRevision = submitRender(Work.Import(uri, gpuMode(), retained))
    }

    fun importLook(uri: Uri?) {
        if (uri != null) importLooks(listOf(uri))
    }

    fun importLooks(uris: List<Uri>) {
        if (uris.isEmpty() || mutable.value.operation != Operation.NONE || mutable.value.draft != null) return
        mutable.value = mutable.value.copy(operation = Operation.IMPORT_LOOK, error = null, lookImportReport = null)
        lookRevision = lookQueue.submit(LookWork.Import(uris.toList()))
    }

    fun dismissLookImportReport() { mutable.value = mutable.value.copy(lookImportReport = null) }

    fun renameLook(id: String, name: String) {
        if (mutable.value.operation != Operation.NONE || mutable.value.draft != null) return
        mutable.value = mutable.value.copy(operation = Operation.IMPORT_LOOK, error = null)
        lookRevision = lookQueue.submit(LookWork.Rename(id, name))
    }

    fun deleteLook(id: String) {
        if (mutable.value.operation != Operation.NONE || mutable.value.draft != null) return
        mutable.value = mutable.value.copy(operation = Operation.IMPORT_LOOK, error = null)
        lookRevision = lookQueue.submit(LookWork.Delete(id))
    }

    fun edit(edits: EditSettings, interactive: Boolean = false) {
        if (!applyingHslTarget) cancelHslTarget()
        val current = mutable.value
        if (!current.controlsEnabled || current.draft != null) return
        if (interactive && !adjustmentHistory.interacting) {
            val saved = adjustmentHistory.begin(current.photo!!, current.edits, sourceRevision)
            if (saved.state == EditSaveState.FAILED) {
                mutable.value = current.copy(saveState = saved.state, saveError = saved.message)
                return
            }
        } else if (!interactive && !adjustmentHistory.finish(current.photo!!, sourceRevision)) return
        val look = current.looks.firstOrNull { it.id == edits.film }
        if (look?.managed == true && !look.available) {
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
        val saved = if (interactive) null else persist(current.photo!!, edits)
        mutable.value = current.copy(edits = edits, rendering = true, exact = false, error = null,
            saveState = saved?.state ?: current.saveState, saveError = if (saved == null) current.saveError else saved.message,
            previewResizePending = previewResizeJob != null)
        currentRevision = submitRender(Work.Preview(current.photo!!, edits, interactive, gpuMode(), edge = previewLongEdge))
    }

    fun updatePreviewSize(edge: Int) {
        var current = mutable.value
        if (disposed || current.photo == null || current.draft != null || edge !in 1..1600 ||
            (edge == requestedPreviewLongEdge && (edge == previewLongEdge || previewResizeJob != null))) return
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
        val next = previous.update(edits)
        if (next == previous) return
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
        currentRevision = submitRender(Work.Preview(photo, edits, interactive, gpuMode(), edge = 1600, draft = true))
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

    fun applyDraft(): Boolean {
        val current = mutable.value
        if (disposed || !current.canApplyDraft) return false
        val photo = current.photo ?: return false
        val edits = current.draft!!.project(current.edits)
        previewResizeJob?.cancel()
        previewResizeJob = null
        val saved = persist(photo, edits)
        if (saved.state == EditSaveState.FAILED) {
            failedDraftSave = true
            mutable.value = current.copy(saveState = saved.state, saveError = saved.message)
            return false
        }
        failedDraftSave = false
        draftSaveBaseline = null
        editRevision += 1
        draftRevision += 1
        mutable.value = current.copy(edits = edits, draft = null, rendering = true, exact = false,
            previewResizePending = false, error = null, saveState = saved.state, saveError = saved.message)
        currentRevision = submitRender(Work.Preview(photo, edits, false, gpuMode(), edge = previewLongEdge))
        durablePreview = EditorDurablePreview(photo.identity, photo.file.absolutePath, sourceRevision, currentRevision, edits)
        return true
    }

    fun discardDraft() {
        val current = mutable.value
        val draft = current.draft ?: return
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
        mutable.value = current.copy(rendering = true, exact = false, error = null)
        currentRevision = submitRender(Work.Preview(photo, current.edits, false, gpuMode(), edge = previewLongEdge))
        navigationPreview = EditorDurablePreview(photo.identity, photo.file.absolutePath, sourceRevision,
            currentRevision, current.edits)
    }

    fun retry() {
        if (mutable.value.draft != null) renderDraft(false)
        else if (mutable.value.controlsEnabled) renderCommittedForNavigation()
    }
    fun autoExposure() {
        val current = mutable.value
        if (!current.controlsEnabled || current.preview == null || current.rendering || current.draft != null) return
        mutable.value = current.copy(rendering = true, exact = false, error = null)
        currentRevision = submitRender(Work.AutoExposure(current.photo!!, current.edits))
    }
    fun retrySave() {
        if (failedDraftSave && mutable.value.draft != null) { applyDraft(); return }
        val photo = mutable.value.photo
        val saved = if (photo != null) persist(photo, mutable.value.edits) else editStore.reopen()
        mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message)
        fadeSaveNotice()
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
        edit(prepared.result.candidate)
        if (currentRevision == previousRequest) return false
        if (mutable.value.saveState == EditSaveState.SAVED) {
            val photo = current.photo!!
            durablePreview = EditorDurablePreview(photo.identity, photo.file.absolutePath, sourceRevision,
                currentRevision, prepared.result.candidate)
        }
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

    private fun gpuMode() = if (mutable.value.gpuEnabled) NativeProcessor.AUTO else NativeProcessor.CPU

    private fun persist(photo: ImportedPhoto, edits: EditSettings) = adjustmentHistory.commit(photo, edits)

    private fun releasePreviousPhoto(next: ImportedPhoto) {
        val previous = mutable.value.photo ?: return
        if (previous.file != next.file && !collections.owns(previous.file) && adjustmentHistory.session?.retainsSource(previous.identity) != true) previous.file.delete()
    }

    fun cancelAdjustmentInteraction() {
        clearHslTarget()
        val restored = adjustmentHistory.cancel(mutable.value.photo, sourceRevision) ?: return
        editRevision += 1
        mutable.value = mutable.value.copy(edits = restored)
        renderCommittedForNavigation()
    }

    fun reloadSavedAdjustments(): Boolean {
        val current = mutable.value
        val photo = current.photo ?: return false
        if (!current.controlsEnabled) return false
        return try {
            val restored = adjustmentHistory.reload(photo)
            failedDraftSave = false; draftSaveBaseline = null
            editRevision += 1; draftRevision += 1
            mutable.value = current.copy(edits = restored, draft = null, saveState = EditSaveState.RESTORED,
                saveError = null, error = null, adjustmentRevision = current.adjustmentRevision + 1)
            includeIndependentRecipeLook(restored)
            renderCommittedForNavigation()
            true
        } catch (error: Exception) {
            val saved = EditSaveResult(EditSaveState.FAILED, error, reading = true)
            mutable.value = current.copy(saveState = saved.state, saveError = saved.message)
            false
        }
    }

    fun undoAdjustment() = performAdjustmentHistory(undo = true)
    fun redoAdjustment() = performAdjustmentHistory(undo = false)
    fun performAdjustmentHistory(undo: Boolean, transactionID: UUID? = null, wholeTransaction: Boolean = false,
        skipping: Set<String> = emptySet()): List<AdjustmentOutcome> {
        val session = adjustmentHistory.session ?: return emptyList()
        val photo = mutable.value.photo ?: return emptyList()
        val id = transactionID ?: session.photoHistoryID(photo.identity, undo) ?: return emptyList()
        return executeAdjustmentHistory(EditorAdjustmentHistoryRequest(id, if (wholeTransaction) null else photo.identity, undo), skipping)
    }
    fun executeAdjustmentHistory(request: EditorAdjustmentHistoryRequest, skipping: Set<String> = emptySet()): List<AdjustmentOutcome> {
        val session = adjustmentHistory.session ?: return emptyList()
        val results = if (request.photo == null) {
            if (request.undo) session.undoTransaction(request.transactionID, skipping, ::adjustmentTargetIsCurrent)
            else session.redoTransaction(request.transactionID, skipping, ::adjustmentTargetIsCurrent)
        } else if (request.undo) session.undoPhoto(request.photo, request.transactionID, ::adjustmentTargetIsCurrent)
        else session.redoPhoto(request.photo, request.transactionID, ::adjustmentTargetIsCurrent)
        val accepted = acceptAdjustmentOutcomes(results)
        mutableAdjustmentTransfer.value = mutableAdjustmentTransfer.value.copy(historyRequest = request, historyResults = accepted)
        return accepted
    }
    private fun adjustmentTargetIsCurrent(identity: String): Boolean {
        val current = mutable.value
        if (current.photo?.identity?.value != identity) return true
        return current.controlsEnabled && current.draft == null && !adjustmentHistory.interacting && current.saveState != EditSaveState.FAILED
    }
    internal fun acceptAdjustmentOutcomes(results: List<AdjustmentOutcome>, cachedTargets: Set<String> = emptySet()): List<AdjustmentOutcome> {
        val current = mutable.value
        val photo = current.photo
        var restored: EditSettings? = null
        var receiptError: Exception? = null
        if (photo != null && adjustmentTargetIsCurrent(photo.identity.value)) {
            for (result in results) {
                val saved = result.saved ?: continue
                // 旧的成功回执不再接管当前照片；它可能已被用户撤销或继续编辑。
                if (result.targetID != photo.identity.value || result.targetID in cachedTargets ||
                    result.status !in setOf(AdjustmentStatus.APPLIED, AdjustmentStatus.UNCHANGED)) continue
                try {
                    if (adjustmentHistory.acceptSaved(photo, saved)) restored = saved.settings ?: EditSettings()
                } catch (error: Exception) { receiptError = error }
            }
        }
        mutable.value = current.copy(adjustmentRevision = current.adjustmentRevision + 1)
        receiptError?.let { error ->
            mutable.value = mutable.value.copy(saveState = EditSaveState.FAILED, saveError = adjustmentErrorMessage(error))
            return results.map { if (it.targetID == photo?.identity?.value) it.copy(
                status = if (error is EditPersistenceConflict) AdjustmentStatus.CONFLICT else AdjustmentStatus.FAILED,
                saved = null, error = error) else it }
        }
        if (restored != null) {
            editRevision += 1
            mutable.value = mutable.value.copy(edits = restored, saveState = EditSaveState.SAVED, saveError = null, error = null)
            includeIndependentRecipeLook(restored)
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
        if (!current.controlsEnabled || current.draft != null || adjustmentHistory.interacting) return null
        val saved = persist(photo, current.edits)
        if (saved.state == EditSaveState.FAILED) {
            mutable.value = current.copy(saveState = saved.state, saveError = saved.message)
            mutableAdjustmentTransfer.value = mutableAdjustmentTransfer.value.copy(error = saved.message)
            return null
        }
        return try {
            val captured = adjustmentHistory.session!!.copy(scope, current.edits,
                AdjustmentTransferContext(photo.identity.value, photo.inputKind == PhotoInputKind.RAW,
                    builtinLookIDs = storage.builtinLookIDs(), cameraTemperature = current.preview?.temperature,
                    cameraTint = current.preview?.tint))
            adjustmentClipboardSourceName = photo.name
            mutable.value = current.copy(adjustmentRevision = current.adjustmentRevision + 1)
            captured
        } catch (error: Exception) {
            mutableAdjustmentTransfer.value = mutableAdjustmentTransfer.value.copy(error = adjustmentErrorMessage(error))
            null
        }
    }

    fun capturePresetAdjustments(scope: AdjustmentScope): AdjustmentPayload {
        val current = mutable.value
        val photo = current.photo ?: throw AdjustmentTransferException(AdjustmentFailure.DRAFT)
        if (!adjustmentTargetIsCurrent(photo.identity.value) || adjustmentHistory.session == null)
            throw AdjustmentTransferException(AdjustmentFailure.DRAFT)
        try { adjustmentHistory.validateCommitted(photo, current.edits) }
        catch (error: Exception) {
            mutable.value = current.copy(saveState = EditSaveState.FAILED, saveError = adjustmentErrorMessage(error))
            throw error
        }
        return AdjustmentTransfer.capture(scope, current.edits,
            AdjustmentTransferContext(photo.identity.value, photo.inputKind == PhotoInputKind.RAW,
                builtinLookIDs = storage.builtinLookIDs(), cameraTemperature = current.preview?.temperature,
                cameraTint = current.preview?.tint))
    }

    fun prepareAdjustmentPaste(payload: AdjustmentPayload, uris: List<Uri>,
        action: AdjustmentHistoryTransaction.Action = AdjustmentHistoryTransaction.Action.PASTE) {
        closeAdjustmentOperation()
        val generation = UUID.randomUUID()
        adjustmentPreparationGeneration = generation
        mutableAdjustmentTransfer.value = EditorAdjustmentTransferState(preparing = true)
        adjustmentPreparationRevision = adjustmentQueue.submit(AdjustmentPreparationWork(generation, payload, uris.toList(), mutable.value.photo, ::adjustmentTargetIsCurrent, action,
            collectionPhotos = if (action == AdjustmentHistoryTransaction.Action.SYNCHRONIZE) uris.mapNotNull { uri ->
                collections.photo(uri.toString())?.let { uri.toString() to it } }.toMap() else emptyMap(),
            validateCollection = if (action == AdjustmentHistoryTransaction.Action.SYNCHRONIZE) { id ->
                collection.value.photos.firstOrNull { it.id == id }?.let(collections::validate)
                    ?: error("Photo left the collection")
            } else null))
    }
    fun applyAdjustmentPaste(operation: PreparedAdjustmentTransfer, skipping: Set<String> = emptySet()): List<AdjustmentOutcome> {
        if (mutableAdjustmentTransfer.value.prepared?.id != operation.id) return emptyList()
        val completed = mutableAdjustmentTransfer.value.results.filter { it.status in setOf(AdjustmentStatus.APPLIED,
            AdjustmentStatus.UNCHANGED, AdjustmentStatus.SKIPPED) }.map { it.targetID }.toSet()
        val results = adjustmentHistory.session?.apply(operation, skipping).orEmpty()
        for (result in results.filter { it.status == AdjustmentStatus.APPLIED }) {
            adjustmentOwnedFiles[result.targetID]?.let { file ->
                adjustmentRetainedFiles.put(result.targetID, file)?.takeIf { it != file }?.delete()
            }
        }
        val accepted = acceptAdjustmentOutcomes(results, completed)
        mutableAdjustmentTransfer.value = mutableAdjustmentTransfer.value.copy(results = accepted)
        if (operation.action == AdjustmentHistoryTransaction.Action.SYNCHRONIZE)
            collections.synchronized(operation.id, accepted.any { it.status == AdjustmentStatus.APPLIED })
        return accepted
    }
    fun closeAdjustmentOperation() {
        adjustmentOwnedFiles.values.filter { it !in adjustmentRetainedFiles.values }.forEach(File::delete)
        adjustmentOwnedFiles = emptyMap()
        adjustmentPreparationGeneration = UUID.randomUUID()
        adjustmentPreparationRevision = -1L
        mutableAdjustmentTransfer.value = EditorAdjustmentTransferState()
    }
    fun setGpuEnabled(enabled: Boolean) {
        if (mutable.value.operation != Operation.NONE) return
        mutable.value = mutable.value.copy(gpuEnabled = enabled)
        if (mutable.value.draft != null) renderDraft(false)
        else if (mutable.value.photo != null) edit(mutable.value.edits)
    }

    fun beginExport(): Boolean {
        if (!mutable.value.canExport) return false
        val photo = mutable.value.photo ?: return false
        val saved = persist(photo, mutable.value.edits)
        if (saved.state == EditSaveState.FAILED) {
            mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message)
            return false
        }
        mutable.value = mutable.value.copy(operation = Operation.PICK_EXPORT, error = null)
        return true
    }
    fun cancelExport() {
        if (mutable.value.operation == Operation.PICK_EXPORT) mutable.value = mutable.value.copy(operation = Operation.NONE)
        updatePreviewSize(requestedPreviewLongEdge)
    }
    fun export(destination: Uri?, format: ExportFormat, longEdge: Int? = null) {
        val current = mutable.value
        if (current.operation != Operation.PICK_EXPORT || current.photo == null) return
        if (destination == null && !format.allowsGallery) {
            mutable.value = current.copy(operation = Operation.NONE, error = text(R.string.dng_file_only))
            return
        }
        if (!ExportSize.isValid(longEdge)) {
            mutable.value = current.copy(operation = Operation.NONE, error = text(R.string.output_size_error))
            updatePreviewSize(requestedPreviewLongEdge)
            return
        }
        mutable.value = current.copy(operation = Operation.EXPORT)
        currentRevision = submitRender(Work.Export(current.photo, current.edits, destination, format, longEdge, gpuMode()))
    }
    fun dismissMessage() { mutable.value = mutable.value.copy(message = null) }

    fun addCollectionPhotos(uris: List<Uri>) = collections.add(uris, mutable.value.photo)
    fun retainCurrentInCollection() { mutable.value.photo?.let { collections.add(listOf(it.uri), it) } }
    fun selectCollectionPhoto(id: String, selected: Boolean) = collections.select(id, selected)
    fun selectCollectionAll(selected: Boolean) = collections.selectAll(selected)
    fun removeCollectionPhoto(id: String) = collections.remove(id)
    fun refreshCollection() = collections.refresh()
    fun collectionDraftFailure(id: String): String? {
        val current = mutable.value
        val photo = current.photo?.takeIf { it.identity.value == id } ?: return null
        if (!adjustmentTargetIsCurrent(id) || adjustmentHistory.reloadRequired) return current.saveError ?: "Apply, discard or skip this photo's draft"
        val record = adjustmentHistory.loaded
        return if (record == null || !AdjustmentTransfer.sameAdjustments(record.settings ?: EditSettings(), current.edits,
                photo.inputKind == PhotoInputKind.RAW)) "Apply, discard or skip this photo's draft" else null
    }
    private fun validateCollectionActive(id: String) {
        val current = mutable.value
        val photo = current.photo?.takeIf { it.identity.value == id } ?: return
        check(adjustmentTargetIsCurrent(id) && !adjustmentHistory.reloadRequired) {
            current.saveError ?: "Apply, discard or skip this photo's draft"
        }
        adjustmentHistory.validateCommitted(photo, current.edits)
    }
    fun resolveCollectionDraft(apply: Boolean): Boolean {
        if (apply) {
            if (adjustmentHistory.interacting) edit(mutable.value.edits, false)
            mutable.value.draft?.let { draft ->
                if (draft.changed) return applyDraft()
                discardDraft(); return true
            }
            retrySave()
            return mutable.value.saveState != EditSaveState.FAILED
        }
        cancelAdjustmentInteraction()
        return reloadSavedAdjustments()
    }
    fun editCollectionPhoto(id: String): Boolean {
        val target = collection.value.photos.firstOrNull { it.id == id } ?: return false
        if (collection.value.busy || mutable.value.draft != null || mutable.value.operation != Operation.NONE) return false
        return try {
            collections.validate(target)
            if (mutable.value.photo?.identity?.value == id) { collections.opened(id); true }
            else { importPhoto(Uri.parse(target.sourceUri)); mutable.value.operation == Operation.IMPORT }
        } catch (error: Exception) { collections.failure(error.message); false }
    }
    fun returnToCollection(): Boolean {
        if (mutable.value.draft != null || mutable.value.operation != Operation.NONE) return false
        if (adjustmentHistory.interacting) edit(mutable.value.edits, false)
        mutable.value.photo?.let { retrySave(); if (mutable.value.saveState == EditSaveState.FAILED) return false }
        collections.returnToCollection(); collections.refresh(); return true
    }
    fun captureCollectionSynchronization(scope: AdjustmentScope): CollectionSynchronization? = try {
        val current = mutable.value
        val photo = current.photo ?: error("Choose a source photo first")
        val payload = capturePresetAdjustments(scope)
        val targets = collection.value.synchronizationTargets(photo.identity.value).map { Uri.parse(it.sourceUri) }
        check(targets.isNotEmpty()) { "No targets remain after excluding the source photo" }
        CollectionSynchronization(photo.identity.value, photo.name, payload, targets)
    } catch (error: Exception) { collections.failure(error.message); null }
    fun prepareCollectionExport(skipping: Set<String>, format: ExportFormat, longEdge: Int?, destination: Uri?,
        completed: (com.rawlab.android.batch.CollectionExportReview?) -> Unit) =
        collections.prepare(skipping, format, longEdge, destination, completed)
    fun freezeCollectionExport(review: com.rawlab.android.batch.CollectionExportReview, completed: (Boolean) -> Unit) {
        if (batch.value != null) { collections.failure("Close the current export task first"); completed(false); return }
        collections.freeze(review) { job ->
            if (job != null) batches.resume(job, gpuMode())
            completed(job != null)
        }
    }

    fun beginBatch() {
        val current = mutable.value
        if (!current.canExport || batch.value != null) return
        val photo = current.photo ?: return
        batches.begin(BatchSourceSnapshot(photo.identity, photo.file, current.edits, photo.name, inputKind = photo.inputKind), gpuMode())
    }

    fun resumeBatch(job: BatchJob) {
        if (batch.value != null || mutable.value.draft != null || mutable.value.operation != Operation.NONE) return
        batches.resume(job, gpuMode())
    }

    fun closeBatch() = batches.close()

    fun onBackground() {
        cancelAdjustmentInteraction()
        batches.cancelForBackground()
        mutable.value.photo?.let { photo ->
            val saved = persist(photo, mutable.value.edits)
            if (saved.state == EditSaveState.FAILED) mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message)
        }
    }
    private fun text(id: Int) = AppStrings.text(id)
    private fun failure(error: Throwable): String = if (error is OutOfMemoryError) text(R.string.memory_error)
        else text(R.string.process_error) + "\n" + (error.message ?: error.javaClass.simpleName)

    override fun onCleared() {
        disposed = true
        previewResizeJob?.cancel()
        batches.dispose()
        collections.close(::releaseStorage)
        lookQueue.close()
        queue.close()
        adjustmentQueue.close()
    }

    private fun releaseStorage() {
        synchronized(this) {
            releases += 1
            if (releases == 4) storage.close()
        }
    }
}
