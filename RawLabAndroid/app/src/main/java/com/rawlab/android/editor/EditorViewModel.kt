package com.rawlab.android.editor

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

class EditorViewModel @JvmOverloads constructor(
    application: Application,
    private val batchProcessorFactory: (Int, File?) -> NativeProcessor = { mode, database -> NativeProcessor(mode, database) },
) : AndroidViewModel(application) {
    val storage = PhotoStorage(application)
    private val usage = UsageAnalyticsRegistry.get(application)
    private val editStore = EditorEditStore(File(application.filesDir, "edits"))
    private val batches = EditorBatches(application, storage, viewModelScope, batchProcessorFactory, usage) { error ->
        mutable.value = mutable.value.copy(error = error)
    }
    val batch = batches.active
    val pendingBatch = batches.pending
    private var currentRevision = 0L
    private var previewLongEdge = 1600
    private var requestedPreviewLongEdge = 1600
    private var previewResizeJob: Job? = null
    private val pendingPhotoImport = PendingPhotoImport()
    private var lookRevision = 0L
    private var releases = 0
    private val mutable = MutableStateFlow(EditorState())
    val state = mutable.asStateFlow()
    private var disposed = false
    private val renderer = EditorRenderer(storage, { editStore.load(it) },
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

    init {
        editStore.initialResult.let { mutable.value = mutable.value.copy(saveState = it.state, saveError = it.message) }
        lookRevision = lookQueue.submit(LookWork.Load)
        batches.refreshPending()
    }


    private fun accept(result: Result<WorkResult>) {
        result.fold({ value ->
            when (value) {
                is WorkResult.MissingLook -> {
                    mutable.value.photo?.file?.takeIf { it != value.photo.file }?.delete()
                    mutable.value = EditorStateReducer.renderFinished(mutable.value).copy(photo = value.photo,
                        edits = value.edits, preview = null, exact = false,
                        saveState = EditSaveState.RESTORED, error = text(R.string.look_unavailable))
                }
                is WorkResult.Preview -> {
                    val request = value.request
                    if (request.draft) {
                        val current = mutable.value
                        val draft = current.draft ?: return@fold
                        val refitted = draft.acceptGeometryCanvas(value.pair.comparisonWidth / value.pair.comparisonHeight)
                        mutable.value = EditorStateReducer.renderFinished(current)
                            .copy(draft = refitted, preview = value.pair, exact = !request.interactive, error = null)
                        return@fold
                    }
                    val imported = pendingPhotoImport.complete(request.photo.identity)
                    if (request.importing) {
                        mutable.value.photo?.file?.takeIf { it != request.photo.file }?.delete()
                    }
                    if (imported) usage.record(UsageEvent.PhotoImported)
                    val settings = if (!request.edits.customWb && value.pair.temperature.isFinite())
                        request.edits.copy(temperature = value.pair.temperature.coerceIn(2000f, 50000f),
                            tint = if (request.edits.recipeID == null) value.pair.tint.coerceIn(-150f, 150f) else request.edits.tint)
                    else request.edits
                    val saved = when {
                        request.importing -> if (!editStore.available) editStore.initialResult else
                            EditSaveResult(if (request.restored) EditSaveState.RESTORED else EditSaveState.NONE)
                        request.interactive -> null
                        else -> persist(request.photo, settings)
                    }
                    mutable.value = EditorStateReducer.renderFinished(mutable.value).copy(
                        photo = request.photo, edits = settings, preview = value.pair,
                        exact = !request.interactive, error = null,
                        saveState = if (request.restored && saved?.state == EditSaveState.SAVED) EditSaveState.RESTORED else saved?.state ?: mutable.value.saveState,
                        saveError = if (saved == null) mutable.value.saveError else saved.message)
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
            is LookResult.Loaded -> mutable.value = EditorStateReducer.looksLoaded(mutable.value, result.looks)
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
        currentRevision = queue.submit(Work.Preview(photo, edits, false, gpuMode(), edge = previewLongEdge))
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
        val current = mutable.value
        if (current.photo != null) {
            val saved = persist(current.photo, current.edits)
            if (saved.state == EditSaveState.FAILED) {
                mutable.value = current.copy(saveState = saved.state, saveError = saved.message)
                return
            }
        }
        pendingPhotoImport.begin(PhotoIdentity(uri.toString()))
        mutable.value = mutable.value.copy(operation = Operation.IMPORT, rendering = true, error = null)
        previewResizeJob?.cancel()
        previewResizeJob = null
        previewLongEdge = 1600
        requestedPreviewLongEdge = 1600
        mutable.value = mutable.value.copy(previewResizePending = false)
        currentRevision = queue.submit(Work.Import(uri, gpuMode()))
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
        val current = mutable.value
        if (!current.controlsEnabled || current.draft != null) return
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
        val saved = if (interactive) null else persist(current.photo!!, edits)
        mutable.value = current.copy(edits = edits, rendering = true, exact = false, error = null,
            saveState = saved?.state ?: current.saveState, saveError = if (saved == null) current.saveError else saved.message,
            previewResizePending = previewResizeJob != null)
        currentRevision = queue.submit(Work.Preview(current.photo!!, edits, interactive, gpuMode(), edge = previewLongEdge))
    }

    fun updatePreviewSize(edge: Int) {
        val current = mutable.value
        if (disposed || current.photo == null || current.draft != null || edge !in 1..1600 ||
            (edge == requestedPreviewLongEdge && (edge == previewLongEdge || previewResizeJob != null))) return
        requestedPreviewLongEdge = edge
        if (!current.controlsEnabled) return
        previewResizeJob?.cancel()
        previewResizeJob = null
        mutable.value = current.copy(previewResizePending = false)
        if (edge == previewLongEdge) return
        if (!current.edits.denoise.enabled) {
            previewLongEdge = edge
            edit(mutable.value.edits)
            return
        }
        mutable.value = mutable.value.copy(previewResizePending = true)
        previewResizeJob = viewModelScope.launch {
            delay(200)
            previewResizeJob = null
            mutable.value = mutable.value.copy(previewResizePending = false)
            if (!mutable.value.controlsEnabled) return@launch
            previewLongEdge = requestedPreviewLongEdge
            edit(mutable.value.edits)
        }
    }

    fun beginDraft(group: AdjustmentGroup) {
        val current = mutable.value
        if (!current.canExport) return
        previewResizeJob?.cancel()
        previewResizeJob = null
        val pair = current.preview ?: return
        mutable.value = current.copy(draft = AdjustmentDraft.begin(group, current.edits, pair.originalAspect,
            pair.comparisonWidth / pair.comparisonHeight), previewResizePending = false, error = null)
        if (group == AdjustmentGroup.GEOMETRY && current.edits.geometry != current.edits.geometry.uncropped()) renderDraft(false)
    }

    fun changeDraft(edits: EditSettings, interactive: Boolean = false) {
        val current = mutable.value
        val previous = current.draft ?: return
        if (!current.controlsEnabled) return
        val next = previous.update(edits)
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
        currentRevision = queue.submit(Work.Preview(photo, edits, interactive, gpuMode(), edge = 1600, draft = true))
    }

    fun chooseGeometryRatio(ratio: GeometryRatio, portrait: Boolean) {
        val current = mutable.value
        val draft = current.draft ?: return
        if (!current.controlsEnabled || (ratio != GeometryRatio.FREE && !current.canApplyDraft)) return
        mutable.value = current.copy(draft = draft.selectGeometryRatio(ratio, portrait))
    }

    fun applyDraft() {
        val current = mutable.value
        if (!current.canApplyDraft) return
        val edits = current.draft!!.project(current.edits)
        mutable.value = current.copy(draft = null)
        edit(edits)
    }

    fun discardDraft() {
        val current = mutable.value
        if (current.draft == null) return
        mutable.value = current.copy(draft = null)
        edit(current.edits)
    }

    fun retry() { if (mutable.value.draft != null) renderDraft(false) else edit(mutable.value.edits) }
    fun autoExposure() {
        val current = mutable.value
        if (!current.controlsEnabled || current.preview == null || current.rendering || current.draft != null) return
        mutable.value = current.copy(rendering = true, exact = false, error = null)
        currentRevision = queue.submit(Work.AutoExposure(current.photo!!, current.edits))
    }
    fun retrySave() {
        val photo = mutable.value.photo
        val saved = if (photo != null) persist(photo, mutable.value.edits) else editStore.reopen()
        mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message)
        fadeSaveNotice()
    }
    fun reset() { edit(mutable.value.edits.reset()) }

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

    private fun persist(photo: ImportedPhoto, edits: EditSettings) = editStore.save(photo.identity, edits)
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
        currentRevision = queue.submit(Work.Export(current.photo, current.edits, destination, format, longEdge, gpuMode()))
    }
    fun dismissMessage() { mutable.value = mutable.value.copy(message = null) }

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
        lookQueue.close()
        queue.close()
    }

    private fun releaseStorage() {
        synchronized(this) {
            releases += 1
            if (releases == 2) storage.close()
        }
    }
}
